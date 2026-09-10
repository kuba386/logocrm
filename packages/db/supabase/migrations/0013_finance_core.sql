-- =============================================================================
-- 0013_finance_core.sql — ядро денежного учёта (этап 5, часть 1 из 3)
--
--   1. Составные ключи: студент↔плательщик, абонемент↔студент — платёж не
--      сможет физически сослаться на абонемент чужого ребёнка или прийти от
--      плательщика, не привязанного к этому ребёнку.
--   2. payment_sources — справочник источников оплаты, по образцу
--      attendance_statuses: сид при create_center, архив через RPC.
--   3. payments — сам факт оплаты/возврата/корректировки. Без deleted_at:
--      ничего не редактируется и не удаляется, ошибку правит новая строка
--      с kind='correction'. Прямая запись закрыта совсем — только через
--      record_payment.
--   4. subscriptions.paid_tiyin — пересчитывается из payments, как
--      lessons_used пересчитывается из attendance (0009).
--   5. financial_periods — замок месяца. Один общий триггер на payments,
--      attendance и lessons.status (change), а не три копии одной проверки.
--   6. close_month/reopen_month.
--
-- Отдельно от промта этапа (docs/Roadmap/stages.md, "Этап 5"): installments,
-- teacher_rates, calc_salary, revenue-views и expenses — в 0014+, после того
-- как это ядро пройдёт pgTAP. Причины и весь разбор — архитект-ревью в
-- истории сессии, четыре продуктовых решения (плательщик не чужой,
-- корректировка не бэкдатируется, два понятия долга остаются раздельными,
-- замок распространяется и на lessons.status) подтверждены владельцем.
-- =============================================================================


-- 1. Составные ключи для FK -------------------------------------------------------

-- «Платёж — чужому ребёнку» и «оплата абонемента другим плательщиком,
-- не тем, что указан у ребёнка» должны быть невозможны физически, а не по
-- соглашению — тот же приём, что и составные (id, center_id) в 0008.
alter table public.students
  add constraint students_id_payer_center_key unique (id, payer_id, center_id);

alter table public.subscriptions
  add constraint subscriptions_id_student_center_key unique (id, student_id, center_id);


-- 2. payment_sources ---------------------------------------------------------------

create table if not exists public.payment_sources (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null default public.current_center()
                references public.centers (id) on delete cascade,
  code        text not null,
  name        text not null,
  is_active   boolean not null default true,
  sort        integer not null default 100,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  deleted_at  timestamptz,

  constraint payment_sources_id_center_key unique (id, center_id)
);

-- Код — для сверки в кассовых отчётах будущих миграций: переименование
-- источника («Mbank» → «MBank») не должно ломать группировку.
create unique index if not exists payment_sources_center_code_idx
  on public.payment_sources (center_id, code) where deleted_at is null;

drop trigger if exists payment_sources_set_updated_at on public.payment_sources;
create trigger payment_sources_set_updated_at before update on public.payment_sources
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('payment_sources');
call public.apply_audit('payment_sources');

-- Название источника нужно видеть везде, где виден сам платёж — в том числе
-- родителю в истории своих оплат. Без deleted_at is null: архивный источник
-- не должен терять название в истории уже прошедших платежей (тот же урок,
-- что attendance_statuses_read_all в 0012).
drop policy if exists payment_sources_read_all on public.payment_sources;
create policy payment_sources_read_all on public.payment_sources
  for select to authenticated
  using (center_id = public.current_center());

create or replace function public.seed_payment_sources(p_center_id uuid)
  returns void
  language sql
  security definer
  set search_path = ''
as $$
  insert into public.payment_sources (center_id, code, name, sort) values
    (p_center_id, 'cash',     'Наличные', 10),
    (p_center_id, 'mbank',    'Mbank',    20),
    (p_center_id, 'odengi',   'O!Dengi',  30),
    (p_center_id, 'elcart',   'Elcart',   40),
    (p_center_id, 'transfer', 'Перевод',  50)
  on conflict do nothing;
$$;

create or replace function public.centers_seed_payment_sources()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform public.seed_payment_sources(new.id);
  return null;
end;
$$;

drop trigger if exists centers_seed_payment_sources on public.centers;
create trigger centers_seed_payment_sources
  after insert on public.centers
  for each row execute function public.centers_seed_payment_sources();

-- Существующим центрам источники тоже нужны — staging не пустой.
do $$
declare v_id uuid;
begin
  for v_id in select id from public.centers where deleted_at is null loop
    perform public.seed_payment_sources(v_id);
  end loop;
end $$;

-- Прямая запись — только справочные поля; deleted_at меняют только RPC
-- ниже (тот же повод, что в 0012: PostgREST заворачивает update в RETURNING,
-- прямой архив либо не пройдёт RLS сам, либо пройдёт случайно и незаметно).
revoke update on public.payment_sources from authenticated;
grant update (code, name, is_active, sort) on public.payment_sources to authenticated;

create or replace function public.archive_payment_source(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.payment_sources
     set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Источник оплаты не найден' using errcode = '42704';
  end if;
end;
$$;

create or replace function public.restore_payment_source(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_code   text;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select code into v_code
    from public.payment_sources
   where id = p_id and center_id = v_center and deleted_at is not null;

  if not found then
    raise exception 'Источник оплаты не найден в архиве' using errcode = '42704';
  end if;

  begin
    update public.payment_sources
       set deleted_at = null
     where id = p_id and center_id = v_center;
  exception
    when unique_violation then
      raise exception 'Код «%» уже занят другим источником — переименуйте перед восстановлением', v_code
        using errcode = '22023';
  end;
end;
$$;


-- 3. payments ------------------------------------------------------------------------

create table if not exists public.payments (
  id               uuid primary key default gen_random_uuid(),
  center_id        uuid not null default public.current_center()
                     references public.centers (id) on delete cascade,
  payer_id         uuid not null,
  student_id       uuid,
  subscription_id  uuid,
  -- Знак — часть суммы, не отдельный флаг: sum(amount_tiyin) в любом отчёте
  -- всегда даёт правильную кассу без filter по kind.
  amount_tiyin     integer not null check (amount_tiyin <> 0),
  source_id        uuid,
  paid_at          timestamptz not null default now(),
  kind             text not null default 'payment'
                     check (kind in ('payment', 'refund', 'correction')),
  comment          text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),

  constraint payments_id_center_key unique (id, center_id),
  constraint payments_payer_fk
    foreign key (payer_id, center_id) references public.payers (id, center_id),
  -- Три колонки, не (student_id, center_id): students_id_payer_center_key
  -- уникален по id, значит у student_id есть ровно один настоящий payer_id
  -- — этот constraint по построению сильнее двухколоночного «ребёнок из
  -- своего центра» и отдельного рядом не нужно. MATCH SIMPLE: проверяется,
  -- только когда student_id заполнен — платёж без привязки к ребёнку
  -- (payer_id всё равно not null) этот constraint не трогает намеренно.
  constraint payments_student_payer_fk
    foreign key (student_id, payer_id, center_id)
    references public.students (id, payer_id, center_id),
  -- По той же причине без student_id constraint ниже не проверил бы вообще
  -- ничего — отдельный check заставляет его работать.
  constraint payments_subscription_fk
    foreign key (subscription_id, student_id, center_id)
    references public.subscriptions (id, student_id, center_id),
  constraint payments_subscription_needs_student
    check (subscription_id is null or student_id is not null),
  constraint payments_source_fk
    foreign key (source_id, center_id) references public.payment_sources (id, center_id),
  constraint payments_sign_matches_kind check (
    (kind = 'payment' and amount_tiyin > 0) or
    (kind = 'refund' and amount_tiyin < 0) or
    (kind = 'correction')
  )
);

create index if not exists payments_center_idx on public.payments (center_id);
create index if not exists payments_subscription_idx on public.payments (subscription_id);
create index if not exists payments_payer_idx on public.payments (payer_id);

drop trigger if exists payments_set_updated_at on public.payments;
create trigger payments_set_updated_at before update on public.payments
  for each row execute function extensions.moddatetime(updated_at);

-- Без deleted_at: apply_tenant_rls(tbl, false) — второй аргумент true
-- добавил бы `deleted_at is null` в using на несуществующую колонку и
-- уронил бы миграцию на CREATE POLICY.
call public.apply_tenant_rls('payments', false);
call public.apply_audit('payments');

drop policy if exists payments_parent_read on public.payments;
create policy payments_parent_read on public.payments
  for select to authenticated
  using (
    center_id = public.current_center()
    and coalesce(public.my_role(), '') = 'parent'
    and (payer_id = public.my_payer_id() or public.parent_of_student(student_id))
  );

-- teacher — ни одной политики: специалисту деньги не показываются, как и у
-- subscriptions (0008:696).

-- Ничего, кроме comment, не редактируется напрямую — ни insert, ни delete,
-- ни правка суммы/даты/привязки. Единственный путь записи — record_payment.
-- tenant_admin (apply_tenant_rls) без deleted_at покрыл бы DELETE тоже —
-- единственный барьер здесь это грант, поэтому revoke all явный, а не
-- «и так же ничего не выдано».
revoke all on public.payments from anon, authenticated;
grant select on public.payments to authenticated;
grant update (comment) on public.payments to authenticated;


-- 4. subscriptions.paid_tiyin --------------------------------------------------------

alter table public.subscriptions
  add column if not exists paid_tiyin integer not null default 0;

alter table public.subscriptions
  add constraint subscriptions_paid_not_negative check (paid_tiyin >= 0);

-- Бэкфилл: абонементы, проданные до этой миграции, не должны выглядеть
-- неоплаченными. Решение — «оплачено полностью на момент миграции» для
-- всех существующих строк; более точная история (кто сколько уже внёс)
-- этим релизом не восстанавливается — платежей до 0013 просто не было.
update public.subscriptions set paid_tiyin = price_tiyin where paid_tiyin = 0;

-- Прямая запись закрыта — колонки не было в гранте update ни разу (0008
-- 0009 выдавали update только на notes/allow_negative/deleted_at), поэтому
-- отдельный revoke не нужен: paid_tiyin никогда не был доступен на запись.

create or replace function public.recalc_subscription_paid(p_subscription_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_paid integer;
begin
  if p_subscription_id is null then
    return;
  end if;

  -- Блокировка строки абонемента — тот же приём, что recalc_subscription_usage
  -- (0009): без него два параллельных платежа читают один снимок и один из
  -- пересчётов проигрывает молча.
  perform 1 from public.subscriptions where id = p_subscription_id for update;
  if not found then
    return;
  end if;

  select coalesce(sum(amount_tiyin), 0) into v_paid
    from public.payments
   where subscription_id = p_subscription_id;

  update public.subscriptions set paid_tiyin = v_paid where id = p_subscription_id;
end;
$$;

create or replace function public.payments_recalc_trigger()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  -- И старая, и новая привязка: смена subscription_id у платежа (админ
  -- переносит ошибочно выбранный абонемент на верный) обязана пересчитать
  -- оба, иначе один абонемент навсегда «помнит» чужой платёж.
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.recalc_subscription_paid(old.subscription_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform public.recalc_subscription_paid(new.subscription_id);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists payments_recalc_paid on public.payments;
create trigger payments_recalc_paid
  after insert or update or delete on public.payments
  for each row execute function public.payments_recalc_trigger();


-- 5. financial_periods — замок месяца -------------------------------------------------

create table if not exists public.financial_periods (
  id         uuid primary key default gen_random_uuid(),
  center_id  uuid not null default public.current_center()
               references public.centers (id) on delete cascade,
  month      date not null,
  closed_at  timestamptz,
  closed_by  uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint financial_periods_month_is_first_of_month
    check (month = date_trunc('month', month)::date),
  constraint financial_periods_center_month_key unique (center_id, month)
);

drop trigger if exists financial_periods_set_updated_at on public.financial_periods;
create trigger financial_periods_set_updated_at before update on public.financial_periods
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('financial_periods', false);
call public.apply_audit('financial_periods');

-- Запись — только close_month/reopen_month. Замок, который открывается
-- обычным PATCH той же роли, что он должен сдерживать, не замок.
revoke all on public.financial_periods from anon, authenticated;
grant select on public.financial_periods to authenticated;

-- Один триггер на payments/attendance/lessons(status) вместо трёх копий
-- одной и той же проверки — иначе через полгода в одной из трёх забудут
-- добавить ветку при правке. Различает таблицу по tg_table_name.
--
-- Дата для payments — paid_at. Для attendance — дата ЗАНЯТИЯ (lessons.
-- starts_at), не marked_at: зарплата и выручка месяца считаются по факту
-- занятия, а не по дню, когда специалист успел отметить (тот же принцип,
-- что v_lesson_date в attendance_fill_and_check, 0010:801). Для lessons —
-- триггер стоит только на UPDATE OF status: перенос занятия или правка
-- заметки закрытый месяц не трогают, только смена статуса — то самое
-- действие, которое меняет прошлое списание/зарплату задним числом.
--
-- И old, и new: платёж, перенесённый ИЗ закрытого месяца в открытый, обязан
-- отказать так же, как перенесённый В закрытый — проверка только по new
-- пропустила бы ровно этот путь.
create or replace function public.financial_period_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid;
  v_old_date date;
  v_new_date date;
  v_blocked  date;
begin
  v_center := coalesce(new.center_id, old.center_id);

  if tg_table_name = 'payments' then
    if tg_op <> 'DELETE' then
      v_new_date := (new.paid_at at time zone public.center_timezone(v_center))::date;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := (old.paid_at at time zone public.center_timezone(v_center))::date;
    end if;

  elsif tg_table_name = 'attendance' then
    if tg_op <> 'DELETE' then
      select (l.starts_at at time zone public.center_timezone(v_center))::date into v_new_date
        from public.lessons l where l.id = new.lesson_id;
    end if;
    if tg_op <> 'INSERT' then
      select (l.starts_at at time zone public.center_timezone(v_center))::date into v_old_date
        from public.lessons l where l.id = old.lesson_id;
    end if;

  elsif tg_table_name = 'lessons' then
    v_new_date := (new.starts_at at time zone public.center_timezone(v_center))::date;
    v_old_date := (old.starts_at at time zone public.center_timezone(v_center))::date;
  end if;

  if v_new_date is not null and exists (
       select 1 from public.financial_periods fp
        where fp.center_id = v_center
          and fp.month = date_trunc('month', v_new_date)::date
          and fp.closed_at is not null
     ) then
    v_blocked := v_new_date;
  elsif v_old_date is not null and exists (
       select 1 from public.financial_periods fp
        where fp.center_id = v_center
          and fp.month = date_trunc('month', v_old_date)::date
          and fp.closed_at is not null
     ) then
    v_blocked := v_old_date;
  end if;

  if v_blocked is not null then
    raise exception 'Месяц % закрыт — операции с этой датой запрещены', to_char(v_blocked, 'FMMonth YYYY')
      using errcode = '22023';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists financial_period_guard_payments on public.payments;
create trigger financial_period_guard_payments
  before insert or update or delete on public.payments
  for each row execute function public.financial_period_guard();

drop trigger if exists financial_period_guard_attendance on public.attendance;
create trigger financial_period_guard_attendance
  before insert or update or delete on public.attendance
  for each row execute function public.financial_period_guard();

drop trigger if exists financial_period_guard_lessons on public.lessons;
create trigger financial_period_guard_lessons
  before update of status on public.lessons
  for each row execute function public.financial_period_guard();

create or replace function public.close_month(p_month date)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center     uuid := public.current_center();
  v_month      date := date_trunc('month', p_month)::date;
  v_open_count integer;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_month >= date_trunc('month', public.center_today(v_center))::date then
    raise exception 'Закрыть можно только полностью прошедший месяц' using errcode = '22023';
  end if;

  if exists (
       select 1 from public.financial_periods
        where center_id = v_center and month = v_month and closed_at is not null
     ) then
    raise exception 'Месяц % уже закрыт', to_char(v_month, 'FMMonth YYYY') using errcode = '22023';
  end if;

  -- Пересчитываем сами, не верим числу из предпросмотра: между открытием
  -- диалога и нажатием кнопки специалист мог доотметить занятия — тот же
  -- приём, что p_expected_tiyin в refund_subscription (0010:406-410).
  select count(*) into v_open_count
    from public.lessons l
   where l.center_id = v_center
     and l.deleted_at is null
     and l.status = 'planned'
     and (l.starts_at at time zone public.center_timezone(v_center))::date >= v_month
     and (l.starts_at at time zone public.center_timezone(v_center))::date < (v_month + interval '1 month')::date;

  if v_open_count > 0 then
    raise exception 'В месяце % занятий без отметки: %  — сначала отметьте или отмените',
      to_char(v_month, 'FMMonth YYYY'), v_open_count
      using errcode = '22023';
  end if;

  insert into public.financial_periods (center_id, month, closed_at, closed_by)
  values (v_center, v_month, now(), auth.uid())
  on conflict (center_id, month) do update
    set closed_at = excluded.closed_at, closed_by = excluded.closed_by;

  perform public.emit_event('period.closed',
    jsonb_build_object('center_id', v_center, 'month', v_month), v_center);
end;
$$;

-- Не из промта этапа: закрытую заморозку (0012-параллель, дефект этапа 4)
-- открывает unfreeze_subscription, а закрытый месяц — ничего. Без пути
-- назад одна опечатка в дате запирает центр на весь текущий месяц до
-- следующей миграции (файлы неизменяемы после мержа) — роль owner, не
-- admin: обратимость закрытия достаточно чувствительна, чтобы не давать
-- её всем администраторам по умолчанию.
create or replace function public.reopen_month(p_month date)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_month  date := date_trunc('month', p_month)::date;
begin
  if coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.financial_periods
     set closed_at = null, closed_by = null
   where center_id = v_center and month = v_month and closed_at is not null;

  if not found then
    raise exception 'Месяц % не закрыт', to_char(v_month, 'FMMonth YYYY') using errcode = '42704';
  end if;

  perform public.emit_event('period.reopened',
    jsonb_build_object('center_id', v_center, 'month', v_month), v_center);
end;
$$;


-- 6. record_payment ------------------------------------------------------------------

-- Единственный путь записи в payments. Знак суммы — забота вызывающего
-- (положительная для payment/correction-довнесения, отрицательная для
-- refund/correction-снятия); payments_sign_matches_kind проверяет payment
-- и refund жёстко, а не только доверяет параметру.
create or replace function public.record_payment(
  p_payer_id        uuid,
  p_amount_tiyin    integer,
  p_kind            text default 'payment',
  p_student_id      uuid default null,
  p_subscription_id uuid default null,
  p_source_id       uuid default null,
  p_paid_at         timestamptz default now(),
  p_comment         text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_id     uuid;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  insert into public.payments (
    center_id, payer_id, student_id, subscription_id,
    amount_tiyin, source_id, paid_at, kind, comment, created_by
  )
  values (
    v_center, p_payer_id, p_student_id, p_subscription_id,
    p_amount_tiyin, p_source_id, p_paid_at, p_kind, p_comment, auth.uid()
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


-- Гранты -------------------------------------------------------------------------

-- Триггерные функции закрыты совсем — вызываются только Postgres'ом.
revoke execute on function
  public.centers_seed_payment_sources(),
  public.payments_recalc_trigger(),
  public.financial_period_guard()
  from public, anon, authenticated;

revoke execute on function
  public.seed_payment_sources(uuid),
  public.archive_payment_source(uuid),
  public.restore_payment_source(uuid),
  public.recalc_subscription_paid(uuid),
  public.close_month(date),
  public.reopen_month(date),
  public.record_payment(uuid, integer, text, uuid, uuid, uuid, timestamptz, text)
  from public, anon, authenticated;

grant execute on function
  public.archive_payment_source(uuid),
  public.restore_payment_source(uuid),
  public.close_month(date),
  public.reopen_month(date),
  public.record_payment(uuid, integer, text, uuid, uuid, uuid, timestamptz, text)
  to authenticated;
