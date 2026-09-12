-- =============================================================================
-- 0028_roles_policies.sql — роли registrar/finance, шаг 3 из 3: политики,
-- витрины, лестница назначений (этап 5, «Доработка» п.1)
--
-- После этой миграции роли существуют по-настоящему: их можно назначить и
-- пригласить, у них есть чтение таблиц по явному списку. RPC — 0026/0027.
--
-- Решения:
--   Р1. tenant_admin не расширяется. Новые роли получают отдельные политики
--       tenant_<role>_select / _insert / _update через apply_role_rls; таблица
--       без вызова закрыта для роли — этап 7 (диагностика, цели, ДЗ,
--       lesson_notes) бухгалтеру не достанется по умолчанию. pgTAP держит
--       забор: таблица с tenant_admin без решения по новым ролям роняет тест.
--   Р2. for all не выдаётся никогда: DELETE нельзя открыть опечаткой в
--       аргументе; delete в проекте есть только в revoke_membership. Дефолтов
--       у процедуры нет — 12 таблиц каталога без deleted_at, пропуск флага
--       виден в дифе, а не в CI.
--   Р3. registrar: запись (select/insert/update) — students, payers, groups,
--       group_students, lessons, attendance; чтение — teachers, rooms,
--       services, subscription_types, subscriptions (notes/allow_negative/
--       deleted_at — решение о деньгах, остаётся owner/admin),
--       subscription_freezes, payments, installment_plans, installments,
--       student_payers (append-only, кладёт триггер), financial_periods
--       (видеть замок месяца), lesson_participants (иначе состав группы на
--       экране пуст — lesson_participants_read перечисляет роли). Нет:
--       expenses, expense_categories, teacher_rates, salary_*, invitations,
--       audit_log, events.
--   Р4. finance (список Р8 из 0027 — «RPC есть, таблицы нет»): запись —
--       teacher_rates (ставка — прямая запись под approved_salary_guard/
--       financial_period_guard, RPC нет), expense_categories, payment_sources
--       (создание статьи/источника — прямой insert, RPC только
--       archive/restore); чтение — payments, expenses, financial_periods,
--       salary_adjustments, salary_runs, teachers, payers, student_payers,
--       students, subscriptions, subscription_freezes, subscription_types,
--       installment_plans, installments, attendance, lessons. Нет: groups,
--       group_students, rooms, services, invitations, audit_log, events,
--       lesson_participants.
--   Р5. Отступление от ТЗ («finance не видит заметок к занятиям»): lessons.notes,
--       attendance.comment, students.notes бухгалтер читает прямым запросом.
--       Колоночного разделения по роли в Postgres нет (ADR-005); без политики
--       на lessons витрины выручки (security_invoker, join lessons) отдавали
--       бы «выручка 0», а student_balance — пусто. Честный путь — вынос
--       заметок в отдельные таблицы (этап 7 заводит lesson_notes); решение
--       за владельцем, зафиксировано в reports/stage-5.md и явным pgTAP.
--   Р6. Витрины с ролью в теле: revenue_by_month/teacher/service, cash_by_source
--       — can_finance(); student_balance — can_payments();
--       expense_categories_read_archived — can_finance().
--   Р7. Лестница: owner назначает любую роль; admin — teacher, registrar,
--       finance (не owner/admin, и не трогает owner/admin). create_invitation:
--       admin не приглашает admin, owner не приглашается никем. Заодно
--       coalesce(my_role(), '') в change_member_role, create_invitation,
--       revoke_membership: NULL-роль там держал только откат emit_event
--       (0011 их не перевыпускала).
-- =============================================================================


-- 1. apply_role_rls -------------------------------------------------------------------

create or replace procedure public.apply_role_rls(
  tbl           text,
  p_role        text,
  p_write       boolean,
  p_soft_delete boolean
)
  language plpgsql
  set search_path = ''
as $$
declare
  v_tenant text;
  v_using  text;
begin
  if p_role not in ('registrar', 'finance') then
    raise exception 'apply_role_rls: роль % не из списка отдельных политик', p_role;
  end if;

  v_tenant := format('center_id = public.current_center() and public.my_role() = %L', p_role);
  v_using  := case when p_soft_delete then v_tenant || ' and deleted_at is null' else v_tenant end;

  execute format('alter table public.%I enable row level security', tbl);

  execute format('drop policy if exists tenant_%s_select on public.%I', p_role, tbl);
  execute format('drop policy if exists tenant_%s_insert on public.%I', p_role, tbl);
  execute format('drop policy if exists tenant_%s_update on public.%I', p_role, tbl);

  execute format(
    'create policy tenant_%s_select on public.%I for select to authenticated using (%s)',
    p_role, tbl, v_using);

  if p_write then
    execute format(
      'create policy tenant_%s_insert on public.%I for insert to authenticated with check (%s)',
      p_role, tbl, v_tenant);
    execute format(
      'create policy tenant_%s_update on public.%I for update to authenticated using (%s) with check (%s)',
      p_role, tbl, v_using, v_tenant);
  end if;
end;
$$;

comment on procedure public.apply_role_rls(text, text, boolean, boolean) is
  'call apply_role_rls(''students'', ''registrar'', true, true) — select (+ insert/update при p_write) для одной из новых ролей. DELETE не выдаётся никогда. Флаг deleted_at обязателен: без дефолта.';

revoke execute on procedure public.apply_role_rls(text, text, boolean, boolean) from public, anon, authenticated;


-- 2. registrar -------------------------------------------------------------------------

call public.apply_role_rls('students',            'registrar', true,  true);
call public.apply_role_rls('payers',              'registrar', true,  true);
call public.apply_role_rls('groups',              'registrar', true,  true);
call public.apply_role_rls('group_students',      'registrar', true,  true);
call public.apply_role_rls('lessons',             'registrar', true,  true);
call public.apply_role_rls('attendance',          'registrar', true,  false);

call public.apply_role_rls('teachers',            'registrar', false, true);
call public.apply_role_rls('rooms',               'registrar', false, true);
call public.apply_role_rls('services',            'registrar', false, true);
call public.apply_role_rls('subscription_types',  'registrar', false, true);
call public.apply_role_rls('subscriptions',       'registrar', false, true);
call public.apply_role_rls('subscription_freezes','registrar', false, false);
call public.apply_role_rls('payments',            'registrar', false, false);
call public.apply_role_rls('installment_plans',   'registrar', false, false);
call public.apply_role_rls('installments',        'registrar', false, false);
call public.apply_role_rls('student_payers',      'registrar', false, false);
call public.apply_role_rls('financial_periods',   'registrar', false, false);
call public.apply_role_rls('lesson_participants', 'registrar', false, true);


-- 3. finance ----------------------------------------------------------------------------

call public.apply_role_rls('teacher_rates',       'finance', true,  false);
call public.apply_role_rls('expense_categories',  'finance', true,  true);
call public.apply_role_rls('payment_sources',     'finance', true,  true);

call public.apply_role_rls('payments',            'finance', false, false);
call public.apply_role_rls('expenses',            'finance', false, false);
call public.apply_role_rls('financial_periods',   'finance', false, false);
call public.apply_role_rls('salary_adjustments',  'finance', false, false);
call public.apply_role_rls('salary_runs',         'finance', false, false);
call public.apply_role_rls('teachers',            'finance', false, true);
call public.apply_role_rls('payers',              'finance', false, true);
call public.apply_role_rls('student_payers',      'finance', false, false);
call public.apply_role_rls('students',            'finance', false, true);
call public.apply_role_rls('subscriptions',       'finance', false, true);
call public.apply_role_rls('subscription_freezes','finance', false, false);
call public.apply_role_rls('subscription_types',  'finance', false, true);
call public.apply_role_rls('installment_plans',   'finance', false, false);
call public.apply_role_rls('installments',        'finance', false, false);
call public.apply_role_rls('attendance',          'finance', false, false);
call public.apply_role_rls('lessons',             'finance', false, true);

-- Архивные статьи расхода: политика 0016 с литералом owner/admin.
drop policy if exists expense_categories_read_archived on public.expense_categories;
create policy expense_categories_read_archived on public.expense_categories
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.can_finance()
    and deleted_at is not null
  );


-- 4. Витрины с ролью в теле --------------------------------------------------------------

-- из 0021_revenue_views.sql; меняется только фильтр роли
create or replace view public.revenue_by_month
  with (security_invoker = true)
as
with tz as (
  select public.center_timezone(public.current_center()) as tz
),
base as (
  select a.center_id, a.lesson_id, a.price_tiyin, a.subscription_id,
         date_trunc('month', (l.starts_at at time zone t.tz))::date as month
    from public.attendance a
    join public.lessons l on l.id = a.lesson_id
    cross join tz t
   where a.center_id = public.current_center()
     and public.can_finance()
     and a.deducted
     and l.status = 'done'
     and l.deleted_at is null
)
select b.center_id,
       b.month,
       count(*)::integer                                   as visits,
       count(distinct b.lesson_id)::integer                as lessons,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is not null))::integer as unlimited_visits,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is null))::integer     as unpriced_visits,
       coalesce(sum(b.price_tiyin), 0)::bigint             as revenue_tiyin
  from base b
 group by b.center_id, b.month;

create or replace view public.revenue_by_teacher
  with (security_invoker = true)
as
with tz as (
  select public.center_timezone(public.current_center()) as tz
),
base as (
  select a.center_id, a.lesson_id, a.price_tiyin, a.subscription_id, a.paid_teacher_id,
         date_trunc('month', (l.starts_at at time zone t.tz))::date as month
    from public.attendance a
    join public.lessons l on l.id = a.lesson_id
    cross join tz t
   where a.center_id = public.current_center()
     and public.can_finance()
     and a.deducted
     and l.status = 'done'
     and l.deleted_at is null
)
select b.center_id,
       b.month,
       b.paid_teacher_id                                   as teacher_id,
       count(*)::integer                                   as visits,
       count(distinct b.lesson_id)::integer                as lessons,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is not null))::integer as unlimited_visits,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is null))::integer     as unpriced_visits,
       coalesce(sum(b.price_tiyin), 0)::bigint             as revenue_tiyin
  from base b
 group by b.center_id, b.month, b.paid_teacher_id;

create or replace view public.revenue_by_service
  with (security_invoker = true)
as
with tz as (
  select public.center_timezone(public.current_center()) as tz
),
base as (
  select a.center_id, a.lesson_id, a.price_tiyin, a.subscription_id, l.service_id,
         date_trunc('month', (l.starts_at at time zone t.tz))::date as month
    from public.attendance a
    join public.lessons l on l.id = a.lesson_id
    cross join tz t
   where a.center_id = public.current_center()
     and public.can_finance()
     and a.deducted
     and l.status = 'done'
     and l.deleted_at is null
)
select b.center_id,
       b.month,
       b.service_id,
       count(*)::integer                                   as visits,
       count(distinct b.lesson_id)::integer                as lessons,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is not null))::integer as unlimited_visits,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is null))::integer     as unpriced_visits,
       coalesce(sum(b.price_tiyin), 0)::bigint             as revenue_tiyin
  from base b
 group by b.center_id, b.month, b.service_id;

create or replace view public.cash_by_source
  with (security_invoker = true)
as
with tz as (
  select public.center_timezone(public.current_center()) as tz
),
flows as (
  select p.center_id, p.source_id, p.kind,
         p.amount_tiyin::bigint                                   as delta,
         date_trunc('month', (p.paid_at at time zone t.tz))::date as month,
         'payment'                                                as src
    from public.payments p
    cross join tz t
   where p.center_id = public.current_center()
     and public.can_finance()
  union all
  select e.center_id, e.source_id, e.kind,
         -(e.amount_tiyin::bigint),
         date_trunc('month', (e.paid_at at time zone t.tz))::date,
         'expense'
    from public.expenses e
    cross join tz t
   where e.center_id = public.current_center()
     and public.can_finance()
)
select f.center_id,
       f.month,
       f.source_id,
       coalesce(sum(f.delta) filter (where f.src = 'payment' and f.kind = 'payment'),    0)::bigint as received_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'payment' and f.kind = 'refund'),     0)::bigint as refunded_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'payment' and f.kind = 'correction'), 0)::bigint as corrections_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'expense'
                                       and f.kind in ('expense', 'refund', 'correction')),  0)::bigint as spent_tiyin,
       coalesce(sum(f.delta) filter (where (f.src = 'payment' and f.kind not in ('payment', 'refund', 'correction'))
                                        or (f.src = 'expense' and f.kind not in ('expense', 'refund', 'correction'))),
                0)::bigint as other_tiyin,
       coalesce(sum(f.delta), 0)::bigint                                                            as total_tiyin
  from flows f
 group by f.center_id, f.month, f.source_id;

-- из 0010_stage4_hardening.sql; меняется только фильтр роли
create or replace view public.student_balance
  with (security_invoker = true)
as
  select
    s.id                                        as student_id,
    s.center_id,
    sub.id                                      as active_subscription_id,
    public.subscription_lessons_left(sub.id)    as lessons_left,
    sub.ends_at,
    coalesce((
      select sum(a.price_tiyin) from public.attendance a
       where a.student_id = s.id and a.subscription_id is null and a.deducted
    ), 0)::integer                              as debt_tiyin,
    (greatest(-coalesce(public.subscription_lessons_left(sub.id), 0), 0)
      * coalesce(sub.lesson_price_tiyin, 0))::integer as overdrawn_tiyin
  from public.students s
  left join lateral (
    select s2.* from public.subscriptions s2
     where s2.student_id = s.id
       and s2.deleted_at is null
       and s2.status = 'active'
       and public.subscription_state(s2.id) in ('active', 'exhausted')
     order by s2.ends_at asc nulls last, s2.created_at, s2.id
     limit 1
  ) sub on true
  where s.deleted_at is null
    and (
      public.can_payments()
      or (public.my_role() = 'parent' and public.parent_of_student(s.id))
    );

revoke all on table
  public.revenue_by_month, public.revenue_by_teacher, public.revenue_by_service,
  public.cash_by_source, public.student_balance
  from public, anon, authenticated;
grant select on
  public.revenue_by_month, public.revenue_by_teacher, public.revenue_by_service,
  public.cash_by_source, public.student_balance
  to authenticated;


-- 5. Лестница назначений ------------------------------------------------------------------

-- из 0004_staff.sql
create or replace function public.change_member_role(p_user_id uuid, p_role text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_actor  text := coalesce(public.my_role(), '');
  v_target public.memberships;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_actor not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_role not in ('owner', 'admin', 'teacher', 'parent', 'registrar', 'finance') then
    raise exception 'Неизвестная роль %', p_role using errcode = '22023';
  end if;

  -- Администратор не может ни назначить owner/admin, ни трогать их самих:
  -- иначе он повышает себя до владельца через подставного пользователя.
  if v_actor = 'admin' and p_role in ('owner', 'admin') then
    raise exception 'Администратор может назначать только роли специалиста, регистратора и бухгалтера' using errcode = '42501';
  end if;

  select * into v_target
    from public.memberships
   where user_id = p_user_id and center_id = v_center;

  if not found then
    raise exception 'Участник не найден в этом центре' using errcode = '42704';
  end if;

  if v_actor = 'admin' and v_target.role in ('owner', 'admin') then
    raise exception 'Администратор не может менять роль владельца или администратора' using errcode = '42501';
  end if;

  if v_target.role = 'owner' and p_role <> 'owner'
     and (select count(*) from public.memberships
           where center_id = v_center and role = 'owner') <= 1 then
    raise exception 'Нельзя понизить последнего владельца центра' using errcode = '23514';
  end if;

  update public.memberships
     set role = p_role,
         teacher_id = case when p_role = 'teacher' then teacher_id else null end
   where user_id = p_user_id and center_id = v_center;

  perform public.emit_event(
    'membership.role_changed',
    jsonb_build_object('center_id', v_center, 'user_id', p_user_id,
                       'role', p_role, 'previous_role', v_target.role),
    v_center
  );
end;
$$;

-- из 0004_staff.sql
create or replace function public.create_invitation(
  p_role       text,
  p_full_name  text default null,
  p_phone      text default null,
  p_email      text default null,
  p_teacher_id uuid default null
)
  returns table (invitation_id uuid, token text, teacher_id uuid)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_actor   text := coalesce(public.my_role(), '');
  v_teacher uuid := p_teacher_id;
  v_id      uuid;
  v_token   text;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_actor not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_role not in ('admin', 'teacher', 'parent', 'registrar', 'finance') then
    raise exception 'Неизвестная роль %', p_role using errcode = '22023';
  end if;

  if v_actor = 'admin' and p_role = 'admin' then
    raise exception 'Администратор не может приглашать администраторов' using errcode = '42501';
  end if;

  if p_role = 'teacher' then
    if v_teacher is null then
      if coalesce(trim(p_full_name), '') = '' then
        raise exception 'Укажите ФИО специалиста' using errcode = '22004';
      end if;

      insert into public.teachers (center_id, full_name, phone, is_active)
      values (v_center, trim(p_full_name), p_phone, false)
      returning id into v_teacher;
    else
      if not exists (
        select 1 from public.teachers t
         where t.id = v_teacher and t.center_id = v_center and t.deleted_at is null
      ) then
        raise exception 'Карточка специалиста не найдена в этом центре' using errcode = '42704';
      end if;
    end if;
  else
    v_teacher := null;
  end if;

  insert into public.invitations (center_id, role, teacher_id, phone, email)
  values (v_center, p_role, v_teacher, p_phone, p_email)
  returning id, invitations.token into v_id, v_token;

  perform public.emit_event(
    'invitation.created',
    jsonb_build_object('center_id', v_center, 'invitation_id', v_id,
                       'role', p_role, 'teacher_id', v_teacher),
    v_center
  );

  return query select v_id, v_token, v_teacher;
end;
$$;

-- из 0004_staff.sql; меняется только coalesce (Р7)
create or replace function public.revoke_membership(p_user_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_actor  text := coalesce(public.my_role(), '');
  v_target public.memberships;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_actor not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_target
    from public.memberships
   where user_id = p_user_id and center_id = v_center;

  if not found then
    raise exception 'Участник не найден в этом центре' using errcode = '42704';
  end if;

  if v_target.role = 'owner' then
    if v_actor <> 'owner' then
      raise exception 'Только владелец может отключить другого владельца' using errcode = '42501';
    end if;

    if (select count(*) from public.memberships
         where center_id = v_center and role = 'owner') <= 1 then
      raise exception 'Нельзя отключить последнего владельца центра' using errcode = '23514';
    end if;
  end if;

  delete from public.memberships where user_id = p_user_id and center_id = v_center;

  if v_target.teacher_id is not null then
    update public.teachers
       set is_active = false, profile_id = null
     where id = v_target.teacher_id and center_id = v_center;
  end if;

  perform public.emit_event(
    'membership.revoked',
    jsonb_build_object('center_id', v_center, 'user_id', p_user_id, 'role', v_target.role),
    v_center
  );
end;
$$;

revoke execute on function
  public.change_member_role(uuid, text),
  public.create_invitation(text, text, text, text, uuid),
  public.revoke_membership(uuid)
  from public, anon, authenticated;
grant execute on function
  public.change_member_role(uuid, text),
  public.create_invitation(text, text, text, text, uuid),
  public.revoke_membership(uuid)
  to authenticated;
