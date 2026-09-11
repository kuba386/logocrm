-- =============================================================================
-- 0020_installment_plans.sql — план рассрочки как сущность; находки второго
-- раунда architect-ревью по коду 0018 (13 находок; №1 закрыта 0019)
--
-- 0018 после мержа неизменяема — правки здесь. Решения:
--
--   Р7. installment_plans — отдельная таблица: base_paid_tiyin и cancelled_at
--       — факты ПЛАНА, не строки (в 0018 дублировались в каждой строке).
--       «Один живой план на абонемент» теперь хранимый инвариант —
--       частичный unique-индекс installment_plans_one_live_key, а не if в
--       plpgsql. Отмена плана — отмена плана целиком: оплаченные строки
--       мёртвого плана в 0018 оставались «живыми», смешивались с новым
--       планом в витрине и воскресали в overdue после возврата.
--   Р8. Архив ученика (students.status = 'archived') НЕ гасит план: долг
--       остаётся виден в subscription_payment_summary — центр вправе
--       его собрать. Гасятся только уведомления (0019).
--   Р9. installments_notify: «сегодня платёж» — только день в день; если
--       планировщик пропустил день, придёт одно «просрочено». Просрочка
--       старше 30 дней не уведомляется вовсе — иначе первый запуск cron в
--       этапе 6 даст залп по всей истории. Сегодняшняя дата считается один
--       раз на центр, предикат по (center_id, due_date) индексируемый.
--   Р10. service_role: emit_event_unchecked и внутренние функции закрыты
--       и от него (обратная проверка auth.uid() для service_role
--       проходит — uid у него null); installments_notify открыта
--       service_role сознательно — это вход планировщика этапа 6.
--   Р11. События installment_plan.created / installment_plan.cancelled —
--       только из RPC (emit_event, uid есть). Отмена триггером при отмене
--       абонемента событие не пишет: у пути возврата/переноса свои события,
--       а из контекста без uid emit_event не позвать.
--   Р12. Порядок захвата строк везде один: сначала subscriptions, потом
--       строки рассрочки/плана — иначе pay_installment и возврат абонемента
--       взаимоблокируются (0018 брала их в обратном порядке).
--   Р13. Если появится RPC «перенести срок / изменить сумму строки»,
--       решение «installments вне financial_period_guard» (0018 Р2)
--       пересматривается: появится дата, которую можно двигать по закрытым
--       месяцам.
-- =============================================================================


-- 1. installment_plans ------------------------------------------------------------

create table if not exists public.installment_plans (
  id              uuid primary key default gen_random_uuid(),
  center_id       uuid not null default public.current_center()
                    references public.centers (id) on delete cascade,
  subscription_id uuid not null,
  student_id      uuid not null,
  payer_id        uuid not null,
  -- Оплачено на момент создания плана — точка отсчёта нарастающего итога.
  base_paid_tiyin integer not null,
  cancelled_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),

  constraint installment_plans_id_center_key unique (id, center_id),
  constraint installment_plans_subscription_fk
    foreign key (subscription_id, student_id, center_id)
    references public.subscriptions (id, student_id, center_id),
  constraint installment_plans_student_payer_fk
    foreign key (student_id, payer_id, center_id)
    references public.student_payers (student_id, payer_id, center_id),
  constraint installment_plans_base_not_negative check (base_paid_tiyin >= 0)
);

-- Бэкфилл из строк 0018 (plan_id/base были на каждой строке). Отменённые
-- в 0018 строки — «неоплаченный хвост» плана: план считается отменённым.
insert into public.installment_plans
  (id, center_id, subscription_id, student_id, payer_id, base_paid_tiyin, cancelled_at, created_at, created_by)
select i.plan_id, i.center_id, i.subscription_id, i.student_id, i.payer_id, i.base_paid_tiyin,
       max(i.cancelled_at), min(i.created_at), (array_agg(i.created_by))[1]
  from public.installments i
 group by i.plan_id, i.center_id, i.subscription_id, i.student_id, i.payer_id, i.base_paid_tiyin;

-- В 0018 оплаченный целиком старый план оставался «живым» рядом с новым —
-- до частичного индекса такие старые планы гасятся: живым остаётся самый
-- поздний.
update public.installment_plans p
   set cancelled_at = now()
 where p.cancelled_at is null
   and exists (
     select 1 from public.installment_plans q
      where q.subscription_id = p.subscription_id
        and q.cancelled_at is null
        and q.created_at > p.created_at
   );

-- Хранимый инвариант «один живой план на абонемент» (Р7).
create unique index if not exists installment_plans_one_live_key
  on public.installment_plans (subscription_id) where cancelled_at is null;

create index if not exists installment_plans_center_idx on public.installment_plans (center_id);
create index if not exists installment_plans_subscription_idx on public.installment_plans (subscription_id);

drop trigger if exists installment_plans_set_updated_at on public.installment_plans;
create trigger installment_plans_set_updated_at before update on public.installment_plans
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('installment_plans', false);
call public.apply_audit('installment_plans');

drop policy if exists installment_plans_parent_read on public.installment_plans;
create policy installment_plans_parent_read on public.installment_plans
  for select to authenticated
  using (
    center_id = public.current_center()
    and coalesce(public.my_role(), '') = 'parent'
    and (payer_id = public.my_payer_id() or public.parent_of_student(student_id))
  );

revoke all on public.installment_plans from anon, authenticated;
grant select on public.installment_plans to authenticated;


-- 2. installments — ссылка на план, лишние колонки долой --------------------------

-- Вью зависит от снимаемых колонок — пересоздаётся ниже.
drop view if exists public.installments_view;

alter table public.installments
  add constraint installments_plan_fk
  foreign key (plan_id, center_id) references public.installment_plans (id, center_id);

-- Частичный индекс 0018 зависел от cancelled_at.
drop index if exists public.installments_center_due_idx;
create index if not exists installments_center_due_idx
  on public.installments (center_id, due_date);

create index if not exists installments_plan_idx on public.installments (plan_id);

alter table public.installments drop column if exists base_paid_tiyin;
alter table public.installments drop column if exists cancelled_at;


-- 3. installments_view — состояние из плана ---------------------------------------

create or replace view public.installments_view
  with (security_invoker = true)
as
select i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id, i.plan_id,
       p.base_paid_tiyin, p.cancelled_at,
       i.seq, i.due_date, i.amount_tiyin,
       i.due_notified_at, i.overdue_notified_at, i.created_at, i.updated_at,
       s.price_tiyin, s.paid_tiyin,
       c.cumulative_tiyin,
       case
         when p.cancelled_at is not null then 'cancelled'
         when s.paid_tiyin >= p.base_paid_tiyin + c.cumulative_tiyin then 'paid'
         when i.due_date > public.center_today(i.center_id) then 'upcoming'
         when i.due_date = public.center_today(i.center_id) then 'due'
         else 'overdue'
       end as state
  from public.installments i
  join public.installment_plans p on p.id = i.plan_id
  join public.subscriptions s on s.id = i.subscription_id
  join lateral (
    select coalesce(sum(j.amount_tiyin), 0)::integer as cumulative_tiyin
      from public.installments j
     where j.plan_id = i.plan_id and j.seq <= i.seq
  ) c on true;

revoke all on public.installments_view from anon, authenticated;
grant select on public.installments_view to authenticated;


-- 4. Отмена плана: внутреннее ядро, RPC, триггер ---------------------------------

drop function if exists public.installments_cancel_unpaid(uuid);

-- Гасит ВСЕ живые планы абонемента (Р7). Без грантов ни у кого, включая
-- service_role: зовётся только из definer-функций ниже.
create or replace function public.installment_plans_cancel_live(p_subscription_id uuid)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.installment_plans p
     set cancelled_at = now()
   where p.subscription_id = p_subscription_id
     and p.cancelled_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.installment_plans_cancel_live(uuid) from public, anon, authenticated, service_role;

create or replace function public.cancel_installment_plan(p_subscription_id uuid)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_plan   public.installment_plans;
  v_rows   integer;
  v_unpaid integer;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Порядок захвата (Р12): абонемент, затем план.
  perform 1 from public.subscriptions s
    where s.id = p_subscription_id and s.center_id = v_center and s.deleted_at is null
    for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  select * into v_plan from public.installment_plans p
   where p.subscription_id = p_subscription_id and p.cancelled_at is null
   for update;
  if not found then
    raise exception 'По абонементу нет живой рассрочки' using errcode = '22023';
  end if;

  select count(*), count(*) filter (where v.state in ('upcoming', 'due', 'overdue'))
    into v_rows, v_unpaid
    from public.installments_view v where v.plan_id = v_plan.id;
  if v_unpaid = 0 then
    raise exception 'Рассрочка оплачена целиком — отменять нечего' using errcode = '22023';
  end if;

  perform public.installment_plans_cancel_live(p_subscription_id);

  perform public.emit_event('installment_plan.cancelled',
    jsonb_build_object(
      'center_id', v_center, 'plan_id', v_plan.id, 'subscription_id', p_subscription_id,
      'student_id', v_plan.student_id, 'payer_id', v_plan.payer_id
    ),
    v_center);

  return v_rows;
end;
$$;

-- Р4 из 0018 остаётся: отмена/удаление абонемента любым путём гасит план.
-- Событие не пишется (Р11).
create or replace function public.subscriptions_cancel_installments()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if (new.status = 'cancelled' and old.status is distinct from 'cancelled')
     or (new.deleted_at is not null and old.deleted_at is null) then
    perform public.installment_plans_cancel_live(new.id);
  end if;
  return new;
end;
$$;

revoke all on function public.subscriptions_cancel_installments() from public, anon, authenticated, service_role;
-- Триггер из 0018 остаётся привязанным к этой же функции.


-- 5. create_installment_plan — ожидаемый остаток, строки в ответ, событие ---------

-- Смена сигнатуры и типа возврата: drop + create, гранты ниже заново.
drop function if exists public.create_installment_plan(uuid, integer, date, smallint);

create or replace function public.create_installment_plan(
  p_subscription_id          uuid,
  p_n                        integer,
  p_first_due                date     default null,
  p_step_months              smallint default 1,
  -- Остаток, который видел администратор в предпросмотре: изменился —
  -- 23514, как refund_subscription(p_expected_tiyin). null — без сверки.
  p_expected_remaining_tiyin integer  default null
)
  returns setof public.installments_view
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_sub       public.subscriptions;
  v_plan      uuid;
  v_today     date;
  v_first_due date;
  v_remaining integer;
  v_base      integer;
  v_extra     integer;
  i           integer;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_n is null or p_n < 1 or p_n > 24 then
    raise exception 'Число платежей — от 1 до 24' using errcode = '22023';
  end if;
  if p_step_months is null or p_step_months < 1 then
    raise exception 'Шаг рассрочки — целое число месяцев, не меньше одного' using errcode = '22023';
  end if;

  select * into v_sub from public.subscriptions
   where id = p_subscription_id and center_id = v_center and deleted_at is null
   for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;
  if v_sub.status = 'cancelled' then
    raise exception 'Абонемент отменён — рассрочка невозможна' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.installment_plans p
     where p.subscription_id = v_sub.id and p.cancelled_at is null
  ) then
    raise exception 'По абонементу уже есть рассрочка — сначала отмените её' using errcode = '22023';
  end if;

  v_remaining := v_sub.price_tiyin - v_sub.paid_tiyin;
  if v_remaining <= 0 then
    raise exception 'Абонемент оплачен — рассрочивать нечего' using errcode = '22023';
  end if;
  if p_expected_remaining_tiyin is not null and p_expected_remaining_tiyin <> v_remaining then
    raise exception 'Остаток изменился, пока готовили рассрочку: сейчас % тыйын. Проверьте расчёт.', v_remaining
      using errcode = '23514';
  end if;
  if p_n > v_remaining then
    raise exception 'Платежей больше, чем тыйынов в остатке' using errcode = '22023';
  end if;

  v_today     := public.center_today(v_center);
  v_first_due := coalesce(p_first_due, v_today);
  if v_first_due < v_today then
    raise exception 'Первый платёж рассрочки не может быть в прошлом' using errcode = '22023';
  end if;

  insert into public.installment_plans
    (center_id, subscription_id, student_id, payer_id, base_paid_tiyin, created_by)
  values (v_center, v_sub.id, v_sub.student_id, v_sub.payer_id, v_sub.paid_tiyin, auth.uid())
  returning id into v_plan;

  v_base  := v_remaining / p_n;
  v_extra := v_remaining % p_n;

  for i in 1..p_n loop
    insert into public.installments
      (center_id, subscription_id, student_id, payer_id, plan_id, seq, due_date, amount_tiyin, created_by)
    values
      (v_center, v_sub.id, v_sub.student_id, v_sub.payer_id, v_plan, i,
       (v_first_due + make_interval(months => (i - 1) * p_step_months))::date,
       v_base + (case when i <= v_extra then 1 else 0 end),
       auth.uid());
  end loop;

  perform public.emit_event('installment_plan.created',
    jsonb_build_object(
      'center_id', v_center, 'plan_id', v_plan, 'subscription_id', v_sub.id,
      'student_id', v_sub.student_id, 'payer_id', v_sub.payer_id,
      'installments', p_n, 'total_tiyin', v_remaining, 'first_due', v_first_due
    ),
    v_center);

  -- Строки — в ответ: интерфейс перерисовывается по ответу сервера, не по
  -- предпросмотру из браузера.
  return query
    select * from public.installments_view v
     where v.plan_id = v_plan
     order by v.seq;
end;
$$;


-- 6. pay_installment — порядок захвата, null-дата, план ---------------------------

create or replace function public.pay_installment(
  p_installment_id uuid,
  p_source_id      uuid        default null,
  p_paid_at        timestamptz default now(),
  p_comment        text        default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center     uuid := public.current_center();
  v_inst       public.installments;
  v_sub        public.subscriptions;
  v_plan       public.installment_plans;
  v_cumulative integer;
  v_amount     integer;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_inst from public.installments
   where id = p_installment_id and center_id = v_center;
  if not found then
    raise exception 'Платёж рассрочки не найден' using errcode = '42704';
  end if;

  -- Р12: сначала абонемент, затем строка — тот же порядок, что у отмены
  -- абонемента (update subscriptions → триггер → installment_plans).
  select * into v_sub from public.subscriptions
   where id = v_inst.subscription_id
   for update;
  if v_sub.deleted_at is not null or v_sub.status = 'cancelled' then
    raise exception 'Абонемент отменён — платёж по рассрочке невозможен' using errcode = '22023';
  end if;

  select * into v_inst from public.installments where id = p_installment_id for update;
  select * into v_plan from public.installment_plans where id = v_inst.plan_id;
  if v_plan.cancelled_at is not null then
    raise exception 'Рассрочка отменена' using errcode = '22023';
  end if;

  select coalesce(sum(x.amount_tiyin), 0) into v_cumulative
    from public.installments x
   where x.plan_id = v_inst.plan_id and x.seq <= v_inst.seq;

  v_amount := v_plan.base_paid_tiyin + v_cumulative - v_sub.paid_tiyin;
  if v_amount <= 0 then
    raise exception 'Этот платёж рассрочки уже оплачен' using errcode = '22023';
  end if;

  return public.record_payment(
    v_inst.payer_id, v_amount, 'payment', v_inst.student_id,
    v_inst.subscription_id, p_source_id, coalesce(p_paid_at, now()), p_comment
  );
end;
$$;


-- 7. installments_notify — дата на центр один раз, окно просрочки ----------------

create or replace function public.installments_notify()
  returns table (due_count integer, overdue_count integer)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_due     integer := 0;
  v_overdue integer := 0;
  r         record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    with today as (
      select c.id as center_id, public.center_today(c.id) as d from public.centers c
    )
    update public.installments i
       set due_notified_at = now()
      from today t,
           public.installments_view v
           join public.subscriptions s on s.id = v.subscription_id
           join public.students st on st.id = v.student_id
     where i.id = v.id
       and i.center_id = t.center_id and i.due_date = t.d
       and v.state = 'due'
       and i.due_notified_at is null
       and s.deleted_at is null and s.status <> 'cancelled'
       and st.deleted_at is null and st.status <> 'archived'
     returning i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id,
               i.seq, i.due_date, i.amount_tiyin
  loop
    perform public.emit_event_unchecked('installment.due',
      jsonb_build_object(
        'center_id', r.center_id, 'installment_id', r.id,
        'subscription_id', r.subscription_id, 'student_id', r.student_id,
        'payer_id', r.payer_id, 'seq', r.seq, 'due_date', r.due_date,
        'amount_tiyin', r.amount_tiyin
      ),
      r.center_id);
    v_due := v_due + 1;
  end loop;

  for r in
    with today as (
      select c.id as center_id, public.center_today(c.id) as d from public.centers c
    )
    update public.installments i
       set overdue_notified_at = now()
      from today t,
           public.installments_view v
           join public.subscriptions s on s.id = v.subscription_id
           join public.students st on st.id = v.student_id
     where i.id = v.id
       and i.center_id = t.center_id
       -- Окно 30 дней (Р9): первый запуск планировщика не даёт залп по истории.
       and i.due_date < t.d and i.due_date >= t.d - 30
       and v.state = 'overdue'
       and i.overdue_notified_at is null
       and s.deleted_at is null and s.status <> 'cancelled'
       and st.deleted_at is null and st.status <> 'archived'
     returning i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id,
               i.seq, i.due_date, i.amount_tiyin
  loop
    perform public.emit_event_unchecked('installment.overdue',
      jsonb_build_object(
        'center_id', r.center_id, 'installment_id', r.id,
        'subscription_id', r.subscription_id, 'student_id', r.student_id,
        'payer_id', r.payer_id, 'seq', r.seq, 'due_date', r.due_date,
        'amount_tiyin', r.amount_tiyin
      ),
      r.center_id);
    v_overdue := v_overdue + 1;
  end loop;

  return query select v_due, v_overdue;
end;
$$;


-- Гранты -------------------------------------------------------------------------

-- Р10: outbox без гейта и внутренние функции — закрыты и от service_role.
revoke all on function public.emit_event_unchecked(text, jsonb, uuid) from public, anon, authenticated, service_role;
-- installments_notify: вход планировщика — service_role остаётся (Р10).
revoke all on function public.installments_notify() from public, anon, authenticated;

revoke execute on function
  public.create_installment_plan(uuid, integer, date, smallint, integer),
  public.pay_installment(uuid, uuid, timestamptz, text),
  public.cancel_installment_plan(uuid)
  from public, anon, authenticated;

grant execute on function
  public.create_installment_plan(uuid, integer, date, smallint, integer),
  public.pay_installment(uuid, uuid, timestamptz, text),
  public.cancel_installment_plan(uuid)
  to authenticated;
