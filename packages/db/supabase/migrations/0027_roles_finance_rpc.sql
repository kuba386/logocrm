-- =============================================================================
-- 0027_roles_finance_rpc.sql — роли registrar/finance, шаг 2 из 3: RPC денег
-- сотрудников и периодов (этап 5, «Доработка» п.1)
--
-- Продолжение 0026: тот же приём — тело каждой функции дословно из последнего
-- определения (файл в заголовке), меняется только гейт. Предикаты из 0026.
--
-- Решения:
--   Р1. can_finance (owner/admin/finance): record_expense, archive/restore_
--       expense_category, archive/restore_payment_source, close_month,
--       calc_salary (ветка owner/admin), approve_salary,
--       record_salary_adjustment, salary_summary (верхний список И фильтр
--       в CTE scope — без второго бухгалтер получал бы пустую таблицу вместо
--       отказа). reopen_month — только owner, как раньше.
--   Р2. Не получает finance: archive/restore_teacher (персонал — owner/admin),
--       user_email, всё расписание и ученики (0026, can_front_desk).
--   Р3. Долг 0011, который 0026 перевыпустила как есть: cancel_series_from,
--       teacher_vacation и teacher_vacation_preview приводили p_from к
--       timestamptz в поясе СЕССИИ (`p_from::timestamptz`), а не центра.
--       PostgREST/CI — UTC, значит для Бишкека (+06) «с 5 октября» начиналось
--       в 06:00 5 октября: занятие в 02:00 в отмену не попадало, а занятие
--       в 02:00 следующего за p_to дня — попадало. Граница теперь
--       (p_from::timestamp) at time zone center_timezone(центр) — так же, как
--       у record_expense и sell_subscription_paid.
-- =============================================================================


-- 1. Расходы и справочники (can_finance) ------------------------------------------

-- из 0016_expenses.sql
create or replace function public.record_expense(
  p_category_id uuid,
  p_amount_tiyin integer,
  p_kind        text default 'expense',
  p_source_id   uuid default null,
  p_paid_on     date default null,
  p_comment     text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_paid_on date;
  v_id      uuid;
begin
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_paid_on := coalesce(p_paid_on, public.center_today(v_center));

  insert into public.expenses (
    center_id, category_id, source_id, amount_tiyin, paid_at, kind, comment, created_by
  )
  values (
    v_center, p_category_id, p_source_id, p_amount_tiyin,
    (v_paid_on::timestamp) at time zone public.center_timezone(v_center),
    p_kind, p_comment, auth.uid()
  )
  returning id into v_id;

  perform public.emit_event('expense.recorded',
    jsonb_build_object(
      'center_id', v_center, 'expense_id', v_id, 'category_id', p_category_id,
      'amount_tiyin', p_amount_tiyin, 'kind', p_kind
    ),
    v_center
  );

  return v_id;
end;
$$;

-- из 0016_expenses.sql
create or replace function public.archive_expense_category(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.expense_categories
     set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Статья расхода не найдена' using errcode = '42704';
  end if;

  perform public.emit_event('expense_category.archived',
    jsonb_build_object('center_id', v_center, 'category_id', p_id), v_center);
end;
$$;

-- из 0016_expenses.sql
create or replace function public.restore_expense_category(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_code   text;
begin
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select code into v_code
    from public.expense_categories
   where id = p_id and center_id = v_center and deleted_at is not null;

  if not found then
    raise exception 'Статья расхода не найдена в архиве' using errcode = '42704';
  end if;

  begin
    update public.expense_categories
       set deleted_at = null
     where id = p_id and center_id = v_center;
  exception
    when unique_violation then
      raise exception 'Код «%» уже занят другой статьёй — переименуйте перед восстановлением', v_code
        using errcode = '22023';
  end;

  perform public.emit_event('expense_category.restored',
    jsonb_build_object('center_id', v_center, 'category_id', p_id), v_center);
end;
$$;

-- из 0014_finance_core_fixes.sql
create or replace function public.archive_payment_source(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.payment_sources
     set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Источник оплаты не найден' using errcode = '42704';
  end if;

  perform public.emit_event('payment_source.archived',
    jsonb_build_object('center_id', v_center, 'source_id', p_id), v_center);
end;
$$;

-- из 0014_finance_core_fixes.sql
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
  if not public.can_finance() then
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

  perform public.emit_event('payment_source.restored',
    jsonb_build_object('center_id', v_center, 'source_id', p_id), v_center);
end;
$$;


-- 2. Периоды (can_finance; reopen — owner) ------------------------------------------

-- из 0014_finance_core_fixes.sql; почему так — 0014, раздел 7 (left join
-- состава, count(distinct), атомарный upsert против гонки)
create or replace function public.close_month(p_month date)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center      uuid := public.current_center();
  v_month       date := date_trunc('month', p_month)::date;
  v_open_count  integer;
  v_period_id   uuid;
begin
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_month >= date_trunc('month', public.center_today(v_center))::date then
    raise exception 'Закрыть можно только полностью прошедший месяц' using errcode = '22023';
  end if;

  select count(distinct l.id) into v_open_count
    from public.lessons l
    left join public.lesson_participants lp on lp.lesson_id = l.id
   where l.center_id = v_center
     and l.deleted_at is null
     and l.status <> 'cancelled'
     and (l.starts_at at time zone public.center_timezone(v_center))::date >= v_month
     and (l.starts_at at time zone public.center_timezone(v_center))::date < (v_month + interval '1 month')::date
     and (
           l.status = 'planned'
           or lp.student_id is null
           or not exists (
                select 1 from public.attendance a
                 where a.lesson_id = l.id and a.student_id = lp.student_id
              )
         );

  if v_open_count > 0 then
    raise exception '%: занятий с неотмеченными участниками — %, сначала отметьте или отмените',
      public.ru_month_year(v_month), v_open_count
      using errcode = '22023';
  end if;

  insert into public.financial_periods (center_id, month, closed_at, closed_by)
  values (v_center, v_month, now(), auth.uid())
  on conflict (center_id, month) do update
    set closed_at = excluded.closed_at, closed_by = excluded.closed_by
  where public.financial_periods.closed_at is null
  returning id into v_period_id;

  if v_period_id is null then
    raise exception 'Месяц % уже закрыт', public.ru_month_year(v_month) using errcode = '22023';
  end if;

  perform public.emit_event('period.closed',
    jsonb_build_object('center_id', v_center, 'month', v_month), v_center);
end;
$$;


-- 3. Зарплата (can_finance) -------------------------------------------------------------

-- из 0017_teacher_rates_and_salary.sql
create or replace function public.record_salary_adjustment(
  p_teacher_id  uuid,
  p_month       date,
  p_amount_tiyin integer,
  p_reason      text
)
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
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.center_id = v_center) then
    raise exception 'Специалист не найден' using errcode = '42704';
  end if;

  insert into public.salary_adjustments (center_id, teacher_id, month, amount_tiyin, reason, created_by)
  values (v_center, p_teacher_id, v_month, p_amount_tiyin, p_reason, auth.uid())
  returning id into v_id;

  perform public.emit_event('salary.adjustment_recorded',
    jsonb_build_object(
      'center_id', v_center, 'adjustment_id', v_id, 'teacher_id', p_teacher_id,
      'month', v_month, 'amount_tiyin', p_amount_tiyin
    ),
    v_center
  );

  return v_id;
end;
$$;

-- из 0017_teacher_rates_and_salary.sql; почему так — 0017 (rn_in_lesson:
-- платящая строка занятия одна; bigint в умножениях; цена скрыта от
-- специалиста вне его процента)
create or replace function public.calc_salary(p_teacher_id uuid, p_month date)
  returns table (
    attendance_id      uuid,
    lesson_id          uuid,
    lesson_date        date,
    student_id         uuid,
    model              text,
    lesson_price_tiyin integer,
    amount_tiyin       integer,
    note               text
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center      uuid := public.current_center();
  v_month       date := date_trunc('month', p_month)::date;
  v_is_teacher  boolean := false;
begin
  if public.can_finance() then
    if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.center_id = v_center) then
      raise exception 'Специалист не найден' using errcode = '42704';
    end if;
  elsif coalesce(public.my_role(), '') = 'teacher'
        and p_teacher_id = public.my_teacher_id() then
    v_is_teacher := true;
  else
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.teacher_rates tr
     where tr.teacher_id = p_teacher_id and tr.center_id = v_center
       and tr.model not in ('per_lesson', 'per_hour', 'percent_payment', 'per_student')
  ) then
    raise exception 'calc_salary: у специалиста есть ставка с неизвестной моделью' using errcode = '22023';
  end if;

  return query
  with lesson_scope as (
    select distinct a.lesson_id
      from public.attendance a
      join public.lessons l on l.id = a.lesson_id
     where a.center_id = v_center
       and a.paid_teacher_id = p_teacher_id
       and l.deleted_at is null
       and (l.starts_at at time zone public.center_timezone(v_center))::date >= v_month
       and (l.starts_at at time zone public.center_timezone(v_center))::date < (v_month + interval '1 month')::date
  ),
  candidate as (
    select a.id as attendance_id, a.lesson_id, a.student_id, a.pays_teacher, a.price_tiyin,
           a.paid_teacher_id,
           (l.starts_at at time zone public.center_timezone(v_center))::date as lesson_date,
           l.starts_at, l.ends_at, l.service_id, l.status as lesson_status
      from public.attendance a
      join public.lessons l on l.id = a.lesson_id
     where a.center_id = v_center
       and a.lesson_id in (select ls.lesson_id from lesson_scope ls)
  ),
  rated as (
    select c.*,
           r.model, r.value,
           row_number() over (
             partition by c.lesson_id
             order by (not c.pays_teacher), c.student_id
           ) as rn_in_lesson
      from candidate c
      left join lateral (
        select tr.model, tr.value
          from public.teacher_rates tr
         where tr.teacher_id = p_teacher_id
           and tr.center_id = v_center
           and (tr.service_id = c.service_id or tr.service_id is null)
           and tr.valid_from <= c.lesson_date
         order by (tr.service_id is null) asc, tr.valid_from desc
         limit 1
      ) r on true
  )
  select
    r.attendance_id, r.lesson_id, r.lesson_date, r.student_id,
    r.model,
    case when v_is_teacher and r.model is distinct from 'percent_payment' then null
         else r.price_tiyin end as lesson_price_tiyin,
    case
      when r.lesson_status <> 'done' then 0
      when not r.pays_teacher then 0
      when r.model is null then 0
      when r.model = 'per_lesson' then (case when r.rn_in_lesson = 1 then r.value else 0 end)
      when r.model = 'per_student' then r.value
      when r.model = 'per_hour' then
        (case when r.rn_in_lesson = 1
              then ((r.value::bigint * extract(epoch from (r.ends_at - r.starts_at))::bigint + 1800) / 3600)::integer
              else 0 end)
      when r.model = 'percent_payment' then
        ((r.price_tiyin::bigint * r.value + 5000) / 10000)::integer
      else 0
    end as amount_tiyin,
    case
      when r.lesson_status <> 'done' then 'занятие не проведено'
      when not r.pays_teacher then 'статус не оплачивается'
      when r.model is null then 'ставка не задана'
      when r.model in ('per_lesson', 'per_hour') and r.rn_in_lesson <> 1 then 'оплачено в другой строке занятия'
      else null
    end as note
  from rated r
  where r.paid_teacher_id = p_teacher_id
  order by r.lesson_date, r.lesson_id, r.student_id;
end;
$$;

-- из 0017_teacher_rates_and_salary.sql
create or replace function public.approve_salary(p_teacher_id uuid, p_month date)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center      uuid := public.current_center();
  v_month       date := date_trunc('month', p_month)::date;
  v_calc_total  integer;
  v_adjustments integer;
  v_total       integer;
  v_lines       jsonb;
  v_id          uuid;
begin
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_month >= date_trunc('month', public.center_today(v_center))::date then
    raise exception 'Утвердить зарплату можно только за полностью прошедший месяц' using errcode = '22023';
  end if;

  select coalesce(sum(c.amount_tiyin), 0), coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
    into v_calc_total, v_lines
    from public.calc_salary(p_teacher_id, v_month) c;

  select coalesce(sum(sa.amount_tiyin), 0) into v_adjustments
    from public.salary_adjustments sa
   where sa.teacher_id = p_teacher_id and sa.center_id = v_center and sa.month = v_month;

  v_total := v_calc_total + v_adjustments;

  insert into public.salary_runs (center_id, teacher_id, month, total_tiyin, lines, approved_by)
  values (v_center, p_teacher_id, v_month, v_total, v_lines, auth.uid())
  returning id into v_id;

  perform public.emit_event('salary.calculated',
    jsonb_build_object(
      'center_id', v_center, 'salary_run_id', v_id, 'teacher_id', p_teacher_id,
      'month', v_month, 'total_tiyin', v_total
    ),
    v_center
  );

  return v_id;
end;
$$;

-- из 0017_teacher_rates_and_salary.sql (гейт и фильтр scope — оба)
create or replace function public.salary_summary(p_month date)
  returns table (
    teacher_id        uuid,
    calc_tiyin        integer,
    adjustments_tiyin integer,
    total_tiyin       integer,
    approved_run_id   uuid,
    approved_at       timestamptz
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
     where sr.center_id = v_center and sr.month = v_month
  )
  select
    s.teacher_id,
    c.calc_tiyin,
    a.adjustments_tiyin,
    coalesce(r.total_tiyin, c.calc_tiyin + a.adjustments_tiyin),
    r.approved_run_id,
    r.approved_at
  from scope s
  join calc c on c.teacher_id = s.teacher_id
  join adj a on a.teacher_id = s.teacher_id
  left join run r on r.teacher_id = s.teacher_id
  order by s.teacher_id;
end;
$$;


-- 4. Р3: граница дня — по поясу центра, не сессии -----------------------------------------

-- из 0026_roles_registrar_rpc.sql (тело 0011); меняются только приведения дат
create or replace function public.cancel_series_from(
  p_series_id uuid, p_from date, p_reason text default null
)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_from   timestamptz;
  v_count  int;
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_from := (p_from::timestamp) at time zone public.center_timezone(v_center);

  with cancelled as (
    update public.lessons
       set status = 'cancelled', cancel_reason = p_reason
     where series_id = p_series_id and center_id = v_center and deleted_at is null
       and status = 'planned' and starts_at >= v_from
    returning id
  )
  select count(*) into v_count from cancelled;

  perform public.emit_event('lesson.cancelled',
    jsonb_build_object('center_id', v_center, 'series_id', p_series_id,
                       'from', p_from, 'reason', p_reason, 'count', v_count), v_center);
  return v_count;
end;
$$;

-- из 0026_roles_registrar_rpc.sql (тело 0006)
create or replace function public.teacher_vacation_preview(
  p_teacher_id uuid, p_from date, p_to date
)
  returns table (lesson_id uuid, starts_at timestamptz, as_substitute boolean)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select l.id, l.starts_at, l.substitute_teacher_id = p_teacher_id
    from public.lessons l
   where l.center_id = public.current_center()
     and public.can_front_desk()
     and l.deleted_at is null and l.status = 'planned'
     and l.starts_at >= (p_from::timestamp) at time zone public.center_timezone(public.current_center())
     and l.starts_at <  ((p_to + 1)::timestamp) at time zone public.center_timezone(public.current_center())
     and (l.teacher_id = p_teacher_id or l.substitute_teacher_id = p_teacher_id)
   order by l.starts_at;
$$;

-- из 0026_roles_registrar_rpc.sql (тело 0011)
create or replace function public.teacher_vacation(
  p_teacher_id uuid, p_from date, p_to date
)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_tz     text := public.center_timezone(public.current_center());
  v_count  int;
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_to < p_from then
    raise exception 'Дата окончания раньше даты начала' using errcode = '22023';
  end if;

  with cancelled as (
    update public.lessons
       set status = 'cancelled', cancel_reason = 'vacation'
     where center_id = v_center and deleted_at is null and status = 'planned'
       and starts_at >= (p_from::timestamp) at time zone v_tz
       and starts_at <  ((p_to + 1)::timestamp) at time zone v_tz
       -- И там, где он ведёт, и там, где подменяет: иначе отпускник
       -- остаётся стоять в замене.
       and (teacher_id = p_teacher_id or substitute_teacher_id = p_teacher_id)
    returning id
  )
  select count(*) into v_count from cancelled;

  perform public.emit_event('teacher.vacation',
    jsonb_build_object('center_id', v_center, 'teacher_id', p_teacher_id,
                       'from', p_from, 'to', p_to, 'cancelled', v_count), v_center);
  return v_count;
end;
$$;


-- Гранты — заново, явно ----------------------------------------------------------------------

revoke execute on function
  public.record_expense(uuid, integer, text, uuid, date, text),
  public.archive_expense_category(uuid),
  public.restore_expense_category(uuid),
  public.archive_payment_source(uuid),
  public.restore_payment_source(uuid),
  public.close_month(date),
  public.record_salary_adjustment(uuid, date, integer, text),
  public.calc_salary(uuid, date),
  public.approve_salary(uuid, date),
  public.salary_summary(date),
  public.cancel_series_from(uuid, date, text),
  public.teacher_vacation_preview(uuid, date, date),
  public.teacher_vacation(uuid, date, date)
  from public, anon, authenticated;

grant execute on function
  public.record_expense(uuid, integer, text, uuid, date, text),
  public.archive_expense_category(uuid),
  public.restore_expense_category(uuid),
  public.archive_payment_source(uuid),
  public.restore_payment_source(uuid),
  public.close_month(date),
  public.record_salary_adjustment(uuid, date, integer, text),
  public.calc_salary(uuid, date),
  public.approve_salary(uuid, date),
  public.salary_summary(date),
  public.cancel_series_from(uuid, date, text),
  public.teacher_vacation_preview(uuid, date, date),
  public.teacher_vacation(uuid, date, date)
  to authenticated;
