-- =============================================================================
-- 0087_lesson_debt_settlement.sql — долг за занятия наконец можно погасить
--
-- Ошибка в логике денег (аудит финансов 5.10.2026). «Долг за занятия»
-- (student_debts, 0031) — сумма price_tiyin отметок deducted без абонемента,
-- и НИЧТО его не уменьшало: ни платёж, ни продажа абонемента. Перерасход
-- (overdrawn_tiyin, 0070) — то же самое в занятиях. Спека этапа 4 описала
-- только начисление. Долг рос с каждой отметкой и висел навсегда: на /app/debts,
-- на дашборде, в боте /debts, в сводке, в WhatsApp-напоминаниях.
--
-- Решения владельца 5.10.2026: долг закрывается оплатой (здесь, часть A) и
-- абонементом (следующая миграция, часть B); перерасход гасится как долг;
-- «Списать долг» — только owner, с причиной; /app/debts — всем can_payments.
--
-- Решения:
--   Р1. Гасит долг только ЯВНО помеченный платёж (payments.covers_lesson_debt).
--       На prod 3.10.2026 лежит платёж 6 400 «за 8 занятий» без абонемента у
--       ребёнка с долгом 2 400: неявная схема («любой платёж без абонемента
--       гасит долг») обнулила бы долг и дала аванс 4 000 — молча, задним
--       числом. Флаг ставит только accept_lesson_debt_payment /
--       refund_lesson_debt_credit через record_payment_core; record_payment
--       (форма /app/finance) всегда пишет false.
--   Р2. Счёт занятий ребёнка считает одна функция
--       lesson_debt_accounts_unchecked(center, student?) — её зовут триггеры
--       (без сессии) и публичная lesson_debt_account() (с ролями).
--         accrued — Σ price отметок deducted без абонемента у ЖИВЫХ занятий
--                   (тот же предикат, что recalc_subscription_usage: отменённое
--                   занятие абонемента возвращается, долг за него — тоже);
--         over    — валовой перерасход по ВСЕМ неудалённым пакетам ребёнка, а не
--                   по выбранному student_balance_pick: выбор отбрасывает
--                   expired, и перерасход «забывался», а оплата перерасхода
--                   становилась бы ложным авансом;
--         paid    — greatest(Σ помеченных платежей и возвратов, 0);
--         written_off — Σ живых списаний.
--       Показ: сначала гасится долг за занятия, потом перерасход;
--       debt + overdrawn = greatest(accrued + over − paid − written_off, 0) —
--       ровно usage_tiyin из 0076. Аванс — только из денег: списание никогда
--       не становится предоплатой (отменили занятие после списания — аванса нет).
--   Р3. Границы — триггеры под advisory-блокировкой по ребёнку, не проверки в
--       RPC (CLAUDE.md): возврат помеченных денег — не больше аванса (иначе
--       возврат создавал бы долг из ничего); списание — не больше остатка.
--       Прямой insert из-под postgres или service_role упирается в те же
--       границы. Триггерные функции — definer (конвенция 0007 разд. 3): они
--       зовут lesson_debt_lock/_unchecked без грантов, а у service_role
--       insert на payments есть — invoker упал бы голым «permission denied».
--   Р4. Две оплаты одного долга (две вкладки, два администратора): RPC берёт
--       ту же блокировку, пересчитывает и сверяет p_expected_* — при
--       расхождении 23514 со свежей суммой, без автоповтора (как
--       sell_subscription_paid). payer_id — из students, не с клиента.
--   Р5. student_debts() — та же сигнатура (её читает export_debts, 0058),
--       обёртка над lesson_debt_account(). student_balance — первые десять
--       колонок дословно как в 0070, debt/overdrawn из счёта, одиннадцатая
--       колонка lesson_credit_tiyin (аванс).
--   Р6. lesson_debt_writeoffs — только select-политика (без apply_tenant_rls:
--       её for all открыла бы запись в обход границы), аудит, readonly guard,
--       export allow-list. financial_period_guard не вешается: у списания нет
--       даты в прошлом, оно не меняет ни кассу, ни выручку.
--   Р7. daily_digest (0032) не переиздаётся: payload.debt_tiyin с 0077 никто
--       не читает (помечено в contracts/events.ts), {debt} считает
--       digest_debt_text поверх student_balance — уже новый счёт.
--
-- Побочная находка, НЕ здесь: refund_subscription (0030) на абонементе с
-- отрицательным остатком добавляет к lessons_written_off отрицательное число —
-- либо 23514 на check (>= 0), либо стёртый перерасход. В долги.
-- =============================================================================


-- 1. Флаг на платеже (Р1) -------------------------------------------------------------------------

alter table public.payments
  add column if not exists covers_lesson_debt boolean not null default false;

alter table public.payments drop constraint if exists payments_lesson_debt_shape;
alter table public.payments add constraint payments_lesson_debt_shape check (
  not covers_lesson_debt
  or (subscription_id is null and student_id is not null and kind in ('payment', 'refund'))
);

comment on column public.payments.covers_lesson_debt is
  'Оплата (или возврат аванса) долга за занятия без абонемента и перерасхода — гасит долг в lesson_debt_account (0087 Р1). Ставит только record_payment_core из accept_lesson_debt_payment/refund_lesson_debt_credit; в grant update (comment) не входит.';

create index if not exists payments_lesson_debt_idx
  on public.payments (center_id, student_id) where covers_lesson_debt;


-- 2. Блокировка по ребёнку (Р3, Р4) ---------------------------------------------------------------

create or replace function public.lesson_debt_lock(p_student_id uuid)
  returns void
  language sql
  volatile
  set search_path = ''
as $$
  select pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('lesson_debt:' || p_student_id::text, 0));
$$;
comment on function public.lesson_debt_lock(uuid) is
  'Транзакционная блокировка счёта занятий ребёнка (0087 Р3/Р4): берут RPC оплаты/возврата/списания и триггеры-границы — две операции по одному ребёнку идут по очереди.';

revoke all on function public.lesson_debt_lock(uuid) from public, anon, authenticated, service_role;


-- 3. Списания долга (Р6) --------------------------------------------------------------------------

create table if not exists public.lesson_debt_writeoffs (
  id           uuid primary key default gen_random_uuid(),
  center_id    uuid not null default public.current_center()
                 references public.centers (id) on delete cascade,
  student_id   uuid not null,
  amount_tiyin integer not null check (amount_tiyin > 0),
  reason       text not null check (length(btrim(reason)) between 1 and 500),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  deleted_at   timestamptz,

  constraint lesson_debt_writeoffs_id_center_key unique (id, center_id),
  constraint lesson_debt_writeoffs_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id)
);
comment on table public.lesson_debt_writeoffs is
  'Списание долга за занятия/перерасхода без денег (0087): только owner через write_off_lesson_debt, причина обязательна. Запись — только RPC: политик на запись нет, граница «не больше остатка» — триггер.';

-- Не частичный: частичный индекс не засчитывается покрытием FK (unindexed_foreign_keys,
-- урок 0069). Префикс (center_id, student_id) покрывает и FK на students, и на centers.
create index if not exists lesson_debt_writeoffs_student_idx
  on public.lesson_debt_writeoffs (center_id, student_id);

drop trigger if exists lesson_debt_writeoffs_set_updated_at on public.lesson_debt_writeoffs;
create trigger lesson_debt_writeoffs_set_updated_at
  before update on public.lesson_debt_writeoffs
  for each row execute function extensions.moddatetime(updated_at);

alter table public.lesson_debt_writeoffs enable row level security;

-- Только чтение финансовым ролям своего центра. Родителю — нет: причина
-- списания может быть чувствительной. apply_tenant_rls намеренно не
-- применяется (Р6).
drop policy if exists lesson_debt_writeoffs_select on public.lesson_debt_writeoffs;
create policy lesson_debt_writeoffs_select on public.lesson_debt_writeoffs
  for select to authenticated
  using (center_id = public.current_center() and public.can_payments());

revoke all on table public.lesson_debt_writeoffs from public, anon, authenticated, service_role;
grant select on public.lesson_debt_writeoffs to authenticated;

call public.apply_audit('lesson_debt_writeoffs');
call public.apply_readonly_guard('lesson_debt_writeoffs');


-- 4. Счёт занятий ребёнка (Р2) — один источник для триггеров и экранов ------------------------------

create or replace function public.lesson_debt_accounts_unchecked(p_center_id uuid, p_student_id uuid default null)
  returns table (
    student_id          uuid,
    accrued_tiyin       integer,
    overdrawn_gross_tiyin integer,
    paid_tiyin          integer,
    written_off_tiyin   integer,
    debt_tiyin          integer,
    overdrawn_tiyin     integer,
    credit_tiyin        integer,
    remaining_tiyin     integer
  )
  language sql
  stable
  security definer
  set search_path = ''
as $$
  with acc as (
    select a.student_id, sum(a.price_tiyin)::bigint as v
      from public.attendance a
      join public.lessons l on l.id = a.lesson_id
     where a.center_id = p_center_id
       and (p_student_id is null or a.student_id = p_student_id)
       and a.subscription_id is null
       and a.deducted
       and l.deleted_at is null
       and l.status <> 'cancelled'
     group by a.student_id
  ),
  ov as (
    select s.student_id,
           sum(greatest(s.lessons_used + s.lessons_written_off - s.lessons_total, 0)::bigint
               * coalesce(s.lesson_price_tiyin, 0))::bigint as v
      from public.subscriptions s
     where s.center_id = p_center_id
       and (p_student_id is null or s.student_id = p_student_id)
       and s.deleted_at is null
       and s.lessons_total is not null
     group by s.student_id
  ),
  pd as (
    select p.student_id, sum(p.amount_tiyin)::bigint as v
      from public.payments p
     where p.center_id = p_center_id
       and (p_student_id is null or p.student_id = p_student_id)
       and p.covers_lesson_debt
     group by p.student_id
  ),
  wo as (
    select w.student_id, sum(w.amount_tiyin)::bigint as v
      from public.lesson_debt_writeoffs w
     where w.center_id = p_center_id
       and (p_student_id is null or w.student_id = p_student_id)
       and w.deleted_at is null
     group by w.student_id
  ),
  ids as (
    select acc.student_id from acc
    union select ov.student_id from ov
    union select pd.student_id from pd
    union select wo.student_id from wo
  ),
  base as (
    select i.student_id,
           coalesce(acc.v, 0)              as accrued,
           coalesce(ov.v, 0)               as over_gross,
           greatest(coalesce(pd.v, 0), 0)  as paid,
           coalesce(wo.v, 0)               as written_off
      from ids i
      join public.students st on st.id = i.student_id and st.center_id = p_center_id and st.deleted_at is null
      left join acc on acc.student_id = i.student_id
      left join ov  on ov.student_id  = i.student_id
      left join pd  on pd.student_id  = i.student_id
      left join wo  on wo.student_id  = i.student_id
  )
  select b.student_id,
         b.accrued::integer,
         b.over_gross::integer,
         b.paid::integer,
         b.written_off::integer,
         greatest(b.accrued - (b.paid + b.written_off), 0)::integer,
         greatest(b.over_gross - greatest(b.paid + b.written_off - b.accrued, 0), 0)::integer,
         greatest(b.paid - (b.accrued + b.over_gross), 0)::integer,
         greatest(b.accrued + b.over_gross - (b.paid + b.written_off), 0)::integer
    from base b;
$$;
comment on function public.lesson_debt_accounts_unchecked(uuid, uuid) is
  'Счёт занятий детей центра (0087 Р2): начислено (отметки без абонемента у живых занятий), валовой перерасход по всем пакетам, оплачено (только covers_lesson_debt), списано → долг, перерасход, аванс, остаток. Без проверки сессии — для триггеров и обёрток; грантов нет.';

revoke all on function public.lesson_debt_accounts_unchecked(uuid, uuid) from public, anon, authenticated, service_role;


create or replace function public.lesson_debt_account()
  returns table (
    student_id          uuid,
    accrued_tiyin       integer,
    overdrawn_gross_tiyin integer,
    paid_tiyin          integer,
    written_off_tiyin   integer,
    debt_tiyin          integer,
    overdrawn_tiyin     integer,
    credit_tiyin        integer,
    remaining_tiyin     integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_payer  uuid;
begin
  if auth.uid() is null or v_center is null then
    return;
  end if;

  if public.can_payments() then
    return query select x.* from public.lesson_debt_accounts_unchecked(v_center) x;

  elsif coalesce(public.my_role(), '') = 'parent' then
    v_payer := public.my_payer_id();
    if v_payer is null then
      return;
    end if;
    -- Свои дети — по текущему плательщику ребёнка; сам счёт — по ребёнку,
    -- без фильтра payments.payer_id: после смены плательщика родитель видит
    -- ту же сумму, что стойка.
    return query
      select x.*
        from public.lesson_debt_accounts_unchecked(v_center) x
        join public.students s on s.id = x.student_id and s.center_id = v_center
       where s.payer_id = v_payer;
  end if;
end;
$$;
comment on function public.lesson_debt_account() is
  'Счёт занятий детей текущего центра (0087): owner/admin/registrar/finance — весь центр, parent — дети своего плательщика, остальным и без сессии — пусто. Источник debt/overdrawn/аванса в student_balance.';

revoke all on function public.lesson_debt_account() from public, anon;
grant execute on function public.lesson_debt_account() to authenticated;


-- 5. student_debts — та же сигнатура, обёртка (Р5) -------------------------------------------------

create or replace function public.student_debts()
  returns table (student_id uuid, debt_tiyin integer)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  return query
    select a.student_id, a.debt_tiyin
      from public.lesson_debt_account() a
     where a.debt_tiyin > 0;
end;
$$;
comment on function public.student_debts() is
  'Долг за занятия без абонемента ПОСЛЕ оплат и списаний (с 0087 — обёртка над lesson_debt_account), строка на ребёнка с долгом. Права — как у lesson_debt_account. Читает export_debts (0058); student_balance с 0087 берёт счёт напрямую.';

revoke all on function public.student_debts() from public, anon;
grant execute on function public.student_debts() to authenticated;


-- 6. Границы — триггеры (Р3) ----------------------------------------------------------------------

create or replace function public.payments_lesson_debt_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_credit integer;
begin
  perform public.lesson_debt_lock(new.student_id);

  if new.kind = 'refund' then
    select coalesce(max(x.credit_tiyin), 0) into v_credit
      from public.lesson_debt_accounts_unchecked(new.center_id, new.student_id) x;
    if -new.amount_tiyin > v_credit then
      raise exception 'Вернуть можно только аванс: сейчас %', public.format_som(v_credit)
        using errcode = '22023';
    end if;
  end if;
  -- Оплату не ограничиваем: переплата — аванс. От двойного нажатия защищает
  -- p_expected_remaining_tiyin в RPC. UPDATE не проверяется: флаг, сумма и
  -- вид в grant update (comment) не входят.
  return new;
end;
$$;
comment on function public.payments_lesson_debt_guard() is
  'Граница 0087 Р3: возврат помеченных денег — не больше аванса (иначе возврат создавал бы долг из ничего). Под блокировкой по ребёнку.';
revoke all on function public.payments_lesson_debt_guard() from public, anon, authenticated, service_role;

drop trigger if exists payments_lesson_debt_guard on public.payments;
create trigger payments_lesson_debt_guard
  before insert on public.payments
  for each row
  when (new.covers_lesson_debt)
  execute function public.payments_lesson_debt_guard();


create or replace function public.lesson_debt_writeoffs_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_remaining integer;
begin
  perform public.lesson_debt_lock(new.student_id);

  select coalesce(max(x.remaining_tiyin), 0) into v_remaining
    from public.lesson_debt_accounts_unchecked(new.center_id, new.student_id) x;
  if new.amount_tiyin > v_remaining then
    raise exception 'Списать можно не больше долга: сейчас %', public.format_som(v_remaining)
      using errcode = '22023';
  end if;
  return new;
end;
$$;
comment on function public.lesson_debt_writeoffs_guard() is
  'Граница 0087 Р3: списание — не больше остатка долга за занятия и перерасхода. Под блокировкой по ребёнку.';
revoke all on function public.lesson_debt_writeoffs_guard() from public, anon, authenticated, service_role;

drop trigger if exists lesson_debt_writeoffs_guard on public.lesson_debt_writeoffs;
create trigger lesson_debt_writeoffs_guard
  before insert on public.lesson_debt_writeoffs
  for each row execute function public.lesson_debt_writeoffs_guard();


-- 7. record_payment_core — тело record_payment (0029) плюс флаг (Р1) --------------------------------

create or replace function public.record_payment_core(
  p_payer_id           uuid,
  p_amount_tiyin       integer,
  p_kind               text,
  p_student_id         uuid,
  p_subscription_id    uuid,
  p_source_id          uuid,
  p_paid_at            timestamptz,
  p_comment            text,
  p_paid_on            date,
  p_covers_lesson_debt boolean
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_today   date;
  v_paid_at timestamptz;
  v_id      uuid;
begin
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_paid_at is not null and p_paid_on is not null then
    raise exception 'record_payment: передайте либо момент, либо день оплаты, не оба' using errcode = '22023';
  end if;

  if p_paid_on is not null then
    v_today := public.center_today(v_center);
    if p_paid_on > v_today then
      raise exception 'Дата оплаты не может быть в будущем' using errcode = '22023';
    end if;
    if p_paid_on < v_today - interval '1 year' then
      raise exception 'Дата оплаты старше года — проверьте год' using errcode = '22023';
    end if;
    v_paid_at := (p_paid_on::timestamp) at time zone public.center_timezone(v_center);
  else
    v_paid_at := coalesce(p_paid_at, now());
  end if;

  insert into public.payments (
    center_id, payer_id, student_id, subscription_id,
    amount_tiyin, source_id, paid_at, kind, comment, created_by, covers_lesson_debt
  )
  values (
    v_center, p_payer_id, p_student_id, p_subscription_id,
    p_amount_tiyin, p_source_id, v_paid_at, p_kind, p_comment, auth.uid(), coalesce(p_covers_lesson_debt, false)
  )
  returning id into v_id;

  perform public.emit_event(
    case when p_kind = 'refund' then 'payment.refunded' else 'payment.received' end,
    jsonb_build_object(
      'center_id', v_center, 'payment_id', v_id, 'payer_id', p_payer_id,
      'student_id', p_student_id, 'subscription_id', p_subscription_id,
      'amount_tiyin', p_amount_tiyin, 'kind', p_kind,
      'covers_lesson_debt', coalesce(p_covers_lesson_debt, false)
    ),
    v_center
  );

  return v_id;
end;
$$;
comment on function public.record_payment_core(uuid, integer, text, uuid, uuid, uuid, timestamptz, text, date, boolean) is
  'Тело record_payment (0029) плюс covers_lesson_debt (0087 Р1). Грантов нет: флаг ставят только RPC долга после сверки p_expected_*.';

revoke all on function public.record_payment_core(uuid, integer, text, uuid, uuid, uuid, timestamptz, text, date, boolean)
  from public, anon, authenticated, service_role;


-- Та же сигнатура (9 аргументов, 0029) — без новой перегрузки (PGRST203).
create or replace function public.record_payment(
  p_payer_id        uuid,
  p_amount_tiyin    integer,
  p_kind            text default 'payment',
  p_student_id      uuid default null,
  p_subscription_id uuid default null,
  p_source_id       uuid default null,
  p_paid_at         timestamptz default null,
  p_comment         text default null,
  p_paid_on         date default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  -- Флаг долга отсюда не ставится никогда: иначе любой can_payments гасил бы
  -- долг мимо сверки p_expected_remaining_tiyin (0087 Р1/Р4).
  return public.record_payment_core(
    p_payer_id, p_amount_tiyin, p_kind, p_student_id, p_subscription_id,
    p_source_id, p_paid_at, p_comment, p_paid_on, false
  );
end;
$$;

revoke execute on function
  public.record_payment(uuid, integer, text, uuid, uuid, uuid, timestamptz, text, date)
  from public, anon, authenticated;
grant execute on function
  public.record_payment(uuid, integer, text, uuid, uuid, uuid, timestamptz, text, date)
  to authenticated;


-- 8. RPC: принять оплату долга, вернуть аванс, списать (Р4) -------------------------------------------

create or replace function public.accept_lesson_debt_payment(
  p_student_id               uuid,
  p_amount_tiyin             integer,
  p_source_id                uuid,
  p_paid_on                  date,
  p_expected_remaining_tiyin integer,
  p_comment                  text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_payer     uuid;
  v_remaining integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_amount_tiyin is null or p_amount_tiyin <= 0 then
    raise exception 'Сумма должна быть больше нуля' using errcode = '22023';
  end if;
  if p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;

  select s.payer_id into v_payer
    from public.students s
   where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null;
  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;
  if v_payer is null then
    raise exception 'У ученика нет плательщика — привяжите его в карточке ученика' using errcode = '22023';
  end if;

  perform public.lesson_debt_lock(p_student_id);

  select coalesce(max(x.remaining_tiyin), 0) into v_remaining
    from public.lesson_debt_accounts_unchecked(v_center, p_student_id) x;

  if v_remaining = 0 then
    raise exception 'Долга нет — принимать нечего' using errcode = '22023';
  end if;
  if p_expected_remaining_tiyin is distinct from v_remaining then
    raise exception 'Долг изменился, пока открывали форму: сейчас %. Проверьте сумму.', public.format_som(v_remaining)
      using errcode = '23514';
  end if;

  return public.record_payment_core(
    v_payer, p_amount_tiyin, 'payment', p_student_id, null, p_source_id,
    null, coalesce(nullif(btrim(p_comment), ''), 'Оплата долга за занятия'),
    coalesce(p_paid_on, public.center_today(v_center)), true
  );
end;
$$;
comment on function public.accept_lesson_debt_payment(uuid, integer, uuid, date, integer, text) is
  'Оплата долга за занятия и перерасхода (0087): can_payments, блокировка по ребёнку, сверка p_expected_remaining_tiyin (23514 со свежей суммой), плательщик — из students. Переплата становится авансом.';

revoke all on function public.accept_lesson_debt_payment(uuid, integer, uuid, date, integer, text) from public, anon;
grant execute on function public.accept_lesson_debt_payment(uuid, integer, uuid, date, integer, text) to authenticated;


create or replace function public.refund_lesson_debt_credit(
  p_student_id            uuid,
  p_amount_tiyin          integer,
  p_source_id             uuid,
  p_paid_on               date,
  p_expected_credit_tiyin integer
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_payer  uuid;
  v_credit integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_amount_tiyin is null or p_amount_tiyin <= 0 then
    raise exception 'Сумма должна быть больше нуля' using errcode = '22023';
  end if;
  if p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;

  select s.payer_id into v_payer
    from public.students s
   where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null;
  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;
  if v_payer is null then
    raise exception 'У ученика нет плательщика — привяжите его в карточке ученика' using errcode = '22023';
  end if;

  perform public.lesson_debt_lock(p_student_id);

  select coalesce(max(x.credit_tiyin), 0) into v_credit
    from public.lesson_debt_accounts_unchecked(v_center, p_student_id) x;
  if p_expected_credit_tiyin is distinct from v_credit then
    raise exception 'Аванс изменился, пока открывали форму: сейчас %. Проверьте сумму.', public.format_som(v_credit)
      using errcode = '23514';
  end if;

  -- Граница «не больше аванса» — в триггере payments_lesson_debt_guard.
  return public.record_payment_core(
    v_payer, -p_amount_tiyin, 'refund', p_student_id, null, p_source_id,
    null, 'Возврат аванса за занятия', coalesce(p_paid_on, public.center_today(v_center)), true
  );
end;
$$;
comment on function public.refund_lesson_debt_credit(uuid, integer, uuid, date, integer) is
  'Возврат аванса за занятия (0087): can_payments, блокировка, сверка p_expected_credit_tiyin; больше аванса не пустит триггер.';

revoke all on function public.refund_lesson_debt_credit(uuid, integer, uuid, date, integer) from public, anon;
grant execute on function public.refund_lesson_debt_credit(uuid, integer, uuid, date, integer) to authenticated;


create or replace function public.write_off_lesson_debt(
  p_student_id               uuid,
  p_amount_tiyin             integer,
  p_reason                   text,
  p_expected_remaining_tiyin integer
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_remaining integer;
  v_id        uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.role_in(v_center), '') <> 'owner' then
    raise exception 'Списать долг может только владелец центра' using errcode = '42501';
  end if;
  if p_amount_tiyin is null or p_amount_tiyin <= 0 then
    raise exception 'Сумма должна быть больше нуля' using errcode = '22023';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Укажите причину списания' using errcode = '22023';
  end if;

  perform 1 from public.students s
   where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null;
  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  perform public.lesson_debt_lock(p_student_id);

  select coalesce(max(x.remaining_tiyin), 0) into v_remaining
    from public.lesson_debt_accounts_unchecked(v_center, p_student_id) x;
  if p_expected_remaining_tiyin is distinct from v_remaining then
    raise exception 'Долг изменился, пока открывали форму: сейчас %. Проверьте сумму.', public.format_som(v_remaining)
      using errcode = '23514';
  end if;

  -- Граница «не больше остатка» — в триггере lesson_debt_writeoffs_guard.
  insert into public.lesson_debt_writeoffs (center_id, student_id, amount_tiyin, reason)
  values (v_center, p_student_id, p_amount_tiyin, btrim(p_reason))
  returning id into v_id;

  -- Причина в payload не кладётся: outbox уходит наружу.
  perform public.emit_event('lesson_debt.written_off', jsonb_build_object('center_id', v_center, 'writeoff_id', v_id, 'student_id', p_student_id, 'amount_tiyin', p_amount_tiyin), v_center);

  return v_id;
end;
$$;
comment on function public.write_off_lesson_debt(uuid, integer, text, integer) is
  'Списание долга за занятия/перерасхода без денег (0087): только owner, причина обязательна, сверка p_expected_remaining_tiyin, граница — триггер.';

revoke all on function public.write_off_lesson_debt(uuid, integer, text, integer) from public, anon;
grant execute on function public.write_off_lesson_debt(uuid, integer, text, integer) to authenticated;


-- 9. student_balance — первые десять колонок как в 0070, плюс аванс (Р5) -----------------------------

create or replace view public.student_balance
  with (security_invoker = true)
as
  select
    s.id                                        as student_id,
    s.center_id,
    b.subscription_id                           as active_subscription_id,
    public.subscription_lessons_left(b.subscription_id) as lessons_left,
    b.ends_at,
    coalesce(a.debt_tiyin, 0)::integer          as debt_tiyin,
    coalesce(a.overdrawn_tiyin, 0)::integer     as overdrawn_tiyin,
    b.state,
    coalesce(o.overdue_tiyin, 0)::integer       as subscription_overdue_tiyin,
    o.payer_id                                  as subscription_overdue_payer_id,
    coalesce(a.credit_tiyin, 0)::integer        as lesson_credit_tiyin
  from public.students_brief() s
  left join lateral public.student_balance_pick(s.id) b on true
  left join public.lesson_debt_account() a on a.student_id = s.id
  left join public.student_subscriptions_overdue() o on o.student_id = s.id;

-- create or replace сохраняет ACL; повторяем явно (правило 0010).
revoke all on table public.student_balance from public, anon, authenticated;
grant select on table public.student_balance to authenticated;


-- 10. Экспорт центра — allow-list из 0068 плюс списания (Р6) -----------------------------------------

create or replace function public.export_center_tables()
  returns table (table_name text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('attendance'), ('attendance_statuses'), ('booking_requests'), ('diagnostic_clinical_forms'),
    ('diagnostic_referrals'), ('diagnostics'), ('exercise_library'),
    ('expense_categories'), ('expenses'), ('financial_periods'), ('funnel_events'),
    ('goal_progress'), ('goal_stages'), ('goals'), ('group_students'), ('groups'),
    ('homework'), ('homework_exercises'), ('installment_plans'), ('installments'),
    ('lesson_debt_writeoffs'),
    ('lesson_note_goal_scores'), ('lesson_notes'), ('lesson_participants'), ('lessons'),
    ('memberships'), ('message_templates'), ('monthly_reports'), ('payers'),
    ('payment_sources'), ('payments'), ('platform_payments'), ('prosody_assessments'),
    ('reading_writing_assessments'), ('rooms'),
    ('salary_adjustments'), ('salary_runs'), ('services'), ('student_anamnesis'),
    ('student_articulation'), ('student_payers'), ('students'), ('subscription_freezes'),
    ('subscription_types'), ('subscriptions'), ('syllable_assessments'), ('teacher_rates'), ('teachers')
$$;
comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. 0087: lesson_debt_writeoffs. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
