-- =============================================================================
-- 0029_salary_runs_and_payment_date.sql — отмена снимка зарплаты, дата
-- платежа (этап 5, «Доработка» п.2, часть (а) — без продуктовых решений
-- владельца; возврат и переплата — 0030 после решений)
--
-- Architect-ревью плана: 15 находок, здесь учтены №3, 4, 7, 9, 11, 12, 13,
-- 15 (остальные — про 0030). Решения:
--
--   Р1. Отмена снимка зарплаты — ОТДЕЛЬНОЕ явное действие владельца
--       cancel_salary_run(p_teacher_id, p_month), не побочный эффект
--       reopen_month: «утверждено» и «закрыто» — независимые факты (0017);
--       правка одного платёжа за март не должна молча гасить снимки восьми
--       специалистов. reopen_month не меняется. Переутверждение после
--       отмены — обычный approve_salary: unique стал частичным по живым.
--   Р2. Снимок неизменяем триггером, а не отсутствием гранта:
--       salary_runs_immutable разрешает единственный переход
--       cancelled_at null → значение (плюс cancelled_by), любое другое
--       изменение и delete — отказ. Будущий grant update или политика
--       finance «на запись» снимок не откроют.
--   Р3. approved_salary_guard — `cancelled_at is null` в ОБЕИХ ветках (new
--       и old month): иначе после отмены снимка правка корректировки с
--       другим old.month продолжала бы отбиваться «уже утверждена».
--   Р4. salary_summary отдаёт живой снимок в approved_run_id и число
--       отменённых в cancelled_runs — «выплатили по одному числу, система
--       показывает другое» должно быть видно, а не спрятано. Сигнатура
--       возврата меняется → drop + create, гранты заново.
--   Р5. Дата платежа: record_payment получает p_paid_on date. Старая
--       8-параметровая перегрузка дропается (иначе PostgREST не выберет
--       кандидата). p_paid_at теперь без дефолта now(): переданы оба —
--       22023 (не молчаливый приоритет), ни одного — now(). p_paid_on в
--       будущем — 22023; старше года — 22023 (промах годом в календаре).
--       sell_subscription_paid переводится на p_paid_on — одна конвертация
--       «день по поясу центра → полночь», а не две. В apps/web вызовов
--       record_payment пока нет (экран /app/finance не написан) — параметр
--       въезжает мёртвым, это записано в отчёт, а не «выполнено».
--   Р6. Тела: approve_salary/salary_summary — из 0027 (can_finance),
--       record_payment/sell_subscription_paid — из 0026 (can_payments/
--       can_front_desk), approved_salary_guard — из 0017. Не 0013/0017 для
--       RPC: там ещё литералы owner/admin, копия откатила бы роли.
--   Р7. Событие salary.run_cancelled — одно на снимок; zod и список типов
--       в packages/contracts/src/events.ts, pgTAP — на точную строку.
-- =============================================================================


-- 1. salary_runs: cancelled_at, частичный unique, неизменяемость -------------------

-- cancelled_by — без FK на auth.users, как approved_by в 0017: on delete set
-- null был бы update отменённого снимка, который триггер ниже отбивает, и
-- удаление учётки сотрудника падало бы с текстом про снимок.
alter table public.salary_runs
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid;

comment on column public.salary_runs.cancelled_at is
  'Снимок отменён владельцем (cancel_salary_run) — единственное изменение, которое переживает salary_runs_immutable. Отменённый снимок остаётся историей: salary_summary считает их в cancelled_runs.';

alter table public.salary_runs drop constraint if exists salary_runs_teacher_month_key;
create unique index if not exists salary_runs_teacher_month_live_key
  on public.salary_runs (center_id, teacher_id, month)
  where cancelled_at is null;

create or replace function public.salary_runs_immutable()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Снимок зарплаты не удаляется — только отменяется (cancel_salary_run)' using errcode = '22023';
  end if;

  if old.cancelled_at is not null then
    raise exception 'Отменённый снимок зарплаты неизменяем' using errcode = '22023';
  end if;
  if new.cancelled_at is null then
    raise exception 'Снимок зарплаты неизменяем — переутверждение только через cancel_salary_run' using errcode = '22023';
  end if;
  -- Вся строка минус две колонки отмены, а не белый список: колонка,
  -- добавленная будущей миграцией, защищена по умолчанию, а «эту можно
  -- менять» — явная правка вычитаемого списка.
  if (to_jsonb(new) - 'cancelled_at' - 'cancelled_by') <> (to_jsonb(old) - 'cancelled_at' - 'cancelled_by') then
    raise exception 'Снимок зарплаты неизменяем — вместе с отменой ничего не правится' using errcode = '22023';
  end if;

  return new;
end;
$$;

revoke all on function public.salary_runs_immutable() from public, anon, authenticated;

drop trigger if exists salary_runs_immutable on public.salary_runs;
create trigger salary_runs_immutable
  before update or delete on public.salary_runs
  for each row execute function public.salary_runs_immutable();


-- 2. approved_salary_guard — только живые снимки (из 0017, Р3) ----------------------

create or replace function public.approved_salary_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_new_month date;
  v_old_month date;
  v_blocked   date;
begin
  if tg_table_name = 'teacher_rates' then
    v_new_month := date_trunc('month', new.valid_from)::date;

  elsif tg_table_name = 'salary_adjustments' then
    if tg_op <> 'DELETE' then
      v_new_month := new.month;
    end if;
    if tg_op <> 'INSERT' then
      v_old_month := old.month;
    end if;

  else
    raise exception 'approved_salary_guard: неизвестная таблица %', tg_table_name
      using errcode = '42704';
  end if;

  if v_new_month is not null and exists (
       select 1 from public.salary_runs sr
        where sr.center_id = new.center_id
          and sr.teacher_id = new.teacher_id
          and sr.month = v_new_month
          and sr.cancelled_at is null
     ) then
    v_blocked := v_new_month;
  elsif v_old_month is not null and exists (
       select 1 from public.salary_runs sr
        where sr.center_id = old.center_id
          and sr.teacher_id = old.teacher_id
          and sr.month = v_old_month
          and sr.cancelled_at is null
     ) then
    v_blocked := v_old_month;
  end if;

  if v_blocked is not null then
    raise exception 'Зарплата за % уже утверждена — изменения задним числом невозможны',
      public.ru_month_year(v_blocked)
      using errcode = '22023';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.approved_salary_guard() from public, anon, authenticated;


-- 3. cancel_salary_run — владелец ------------------------------------------------------

create or replace function public.cancel_salary_run(p_teacher_id uuid, p_month date)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_month  date := date_trunc('month', p_month)::date;
  v_id     uuid;
begin
  if auth.uid() is null or coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.salary_runs sr
     set cancelled_at = now(), cancelled_by = auth.uid()
   where sr.center_id = v_center and sr.teacher_id = p_teacher_id
     and sr.month = v_month and sr.cancelled_at is null
  returning sr.id into v_id;

  if v_id is null then
    raise exception 'Утверждённого снимка зарплаты за % нет', public.ru_month_year(v_month)
      using errcode = '42704';
  end if;

  perform public.emit_event('salary.run_cancelled',
    jsonb_build_object('center_id', v_center, 'salary_run_id', v_id,
                       'teacher_id', p_teacher_id, 'month', v_month),
    v_center);

  return v_id;
end;
$$;

revoke execute on function public.cancel_salary_run(uuid, date) from public, anon, authenticated;
grant execute on function public.cancel_salary_run(uuid, date) to authenticated;


-- 4. salary_summary — живой снимок + число отменённых (тело из 0027, Р4) ----------------

drop function if exists public.salary_summary(date);

create function public.salary_summary(p_month date)
  returns table (
    teacher_id        uuid,
    calc_tiyin        integer,
    adjustments_tiyin integer,
    total_tiyin       integer,
    approved_run_id   uuid,
    approved_at       timestamptz,
    cancelled_runs    integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_month  date := date_trunc('month', p_month)::date;
  v_role   text := coalesce(public.my_role(), '');
begin
  if not (public.can_finance() or v_role = 'teacher') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return query
  with scope as (
    select t.id as teacher_id
      from public.teachers t
     where t.center_id = v_center
       and t.deleted_at is null
       and (public.can_finance() or t.id = public.my_teacher_id())
  ),
  calc as (
    select s.teacher_id, coalesce(sum(c.amount_tiyin), 0)::integer as calc_tiyin
      from scope s
      left join lateral public.calc_salary(s.teacher_id, v_month) c on true
     group by s.teacher_id
  ),
  adj as (
    select s.teacher_id, coalesce(sum(sa.amount_tiyin), 0)::integer as adjustments_tiyin
      from scope s
      left join public.salary_adjustments sa
        on sa.teacher_id = s.teacher_id and sa.center_id = v_center and sa.month = v_month
     group by s.teacher_id
  ),
  run as (
    select sr.teacher_id, sr.id as approved_run_id, sr.approved_at, sr.total_tiyin
      from public.salary_runs sr
     where sr.center_id = v_center and sr.month = v_month and sr.cancelled_at is null
  ),
  cancelled as (
    select sr.teacher_id, count(*)::integer as cancelled_runs
      from public.salary_runs sr
     where sr.center_id = v_center and sr.month = v_month and sr.cancelled_at is not null
     group by sr.teacher_id
  )
  select
    s.teacher_id,
    c.calc_tiyin,
    a.adjustments_tiyin,
    coalesce(r.total_tiyin, c.calc_tiyin + a.adjustments_tiyin),
    r.approved_run_id,
    r.approved_at,
    coalesce(x.cancelled_runs, 0)
  from scope s
  join calc c on c.teacher_id = s.teacher_id
  join adj a on a.teacher_id = s.teacher_id
  left join run r on r.teacher_id = s.teacher_id
  left join cancelled x on x.teacher_id = s.teacher_id
  order by s.teacher_id;
end;
$$;

revoke execute on function public.salary_summary(date) from public, anon, authenticated;
grant execute on function public.salary_summary(date) to authenticated;


-- 5. record_payment — дата платежа (тело из 0026, Р5) ----------------------------------

drop function if exists public.record_payment(uuid, integer, text, uuid, uuid, uuid, timestamptz, text);

create function public.record_payment(
  p_payer_id        uuid,
  p_amount_tiyin    integer,
  p_kind            text default 'payment',
  p_student_id      uuid default null,
  p_subscription_id uuid default null,
  p_source_id       uuid default null,
  -- Момент (внутренние вызовы: pay_installment, корректировки) — либо
  -- день по поясу центра (формы). Оба сразу — отказ.
  p_paid_at         timestamptz default null,
  p_comment         text default null,
  p_paid_on         date default null
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
    amount_tiyin, source_id, paid_at, kind, comment, created_by
  )
  values (
    v_center, p_payer_id, p_student_id, p_subscription_id,
    p_amount_tiyin, p_source_id, v_paid_at, p_kind, p_comment, auth.uid()
  )
  returning id into v_id;

  perform public.emit_event(
    case when p_kind = 'refund' then 'payment.refunded' else 'payment.received' end,
    jsonb_build_object(
      'center_id', v_center, 'payment_id', v_id, 'payer_id', p_payer_id,
      'student_id', p_student_id, 'subscription_id', p_subscription_id,
      'amount_tiyin', p_amount_tiyin, 'kind', p_kind
    ),
    v_center
  );

  return v_id;
end;
$$;

revoke execute on function
  public.record_payment(uuid, integer, text, uuid, uuid, uuid, timestamptz, text, date)
  from public, anon, authenticated;
grant execute on function
  public.record_payment(uuid, integer, text, uuid, uuid, uuid, timestamptz, text, date)
  to authenticated;

-- из 0026_roles_registrar_rpc.sql (тело 0023); меняется только вызов
-- record_payment — день вместо самодельной полуночи
create or replace function public.sell_subscription_paid(
  p_type_id                  uuid,
  p_student_id               uuid,
  p_sale_key                 uuid,
  p_price_tiyin              integer  default null,
  p_starts_at                date     default null,
  p_paid_tiyin               integer  default null,
  p_source_id                uuid     default null,
  p_paid_on                  date     default null,
  p_installments             integer  default null,
  p_first_due                date     default null,
  p_step_months              smallint default 1,
  p_expected_remaining_tiyin integer  default null
)
  returns table (
    subscription_id uuid,
    payment_id      uuid,
    seq             smallint,
    due_date        date,
    amount_tiyin    integer
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_sub       public.subscriptions;
  v_id        uuid;
  v_payment   uuid;
  v_today     date;
  v_paid_on   date;
  v_paid      integer := coalesce(p_paid_tiyin, 0);
  v_remaining integer;
begin
  if auth.uid() is null or not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_sale_key is null then
    raise exception 'sell_subscription_paid: не передан ключ продажи' using errcode = '22004';
  end if;
  if v_paid < 0 then
    raise exception 'Внесённая сумма не может быть отрицательной' using errcode = '22023';
  end if;
  if v_paid > 0 and p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;
  if p_installments is not null and p_installments < 1 then
    raise exception 'Число платежей рассрочки — от 1; без рассрочки поле не передаётся' using errcode = '22023';
  end if;

  v_today   := public.center_today(v_center);
  v_paid_on := coalesce(p_paid_on, v_today);
  if v_paid_on > v_today then
    raise exception 'Дата оплаты не может быть в будущем' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_sale_key::text, 0));
  if exists (select 1 from public.subscriptions s where s.sale_key = p_sale_key) then
    raise exception 'Эта продажа уже проведена — обновите страницу' using errcode = '22023';
  end if;

  v_id := public.sell_subscription(p_type_id, p_student_id, p_price_tiyin, p_starts_at);

  update public.subscriptions s set sale_key = p_sale_key where s.id = v_id;
  select s.* into v_sub from public.subscriptions s where s.id = v_id;

  if v_paid > v_sub.price_tiyin then
    raise exception 'Оплата больше цены абонемента' using errcode = '22023';
  end if;

  v_remaining := v_sub.price_tiyin - v_paid;
  if p_expected_remaining_tiyin is not null and p_expected_remaining_tiyin <> v_remaining then
    raise exception 'Остаток изменился, пока готовили продажу: сейчас % тыйын. Проверьте суммы.', v_remaining
      using errcode = '23514';
  end if;

  if v_paid > 0 then
    v_payment := public.record_payment(
      v_sub.payer_id, v_paid, 'payment', p_student_id, v_id,
      p_source_id, null, 'Оплата при продаже абонемента', v_paid_on
    );
  end if;

  if p_installments is not null then
    return query
      select v_id, v_payment, v.seq, v.due_date, v.amount_tiyin
        from public.create_installment_plan(v_id, p_installments, p_first_due, p_step_months, v_remaining) v
       order by v.seq;
  else
    return query select v_id, v_payment, null::smallint, null::date, null::integer;
  end if;
end;
$$;

revoke execute on function
  public.sell_subscription_paid(uuid, uuid, uuid, integer, date, integer, uuid, date, integer, date, smallint, integer)
  from public, anon, authenticated;
grant execute on function
  public.sell_subscription_paid(uuid, uuid, uuid, integer, date, integer, uuid, date, integer, date, smallint, integer)
  to authenticated;
