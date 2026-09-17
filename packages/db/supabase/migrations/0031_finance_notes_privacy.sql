-- =============================================================================
-- 0031_finance_notes_privacy.sql — бухгалтер не читает заметок (этап 5,
-- закрытие отступления Р5 из 0028 по решению владельца 17.09.2026)
--
-- Отменяет Р5 из 0028_roles_policies.sql. Там бухгалтер получил students,
-- lessons и attendance целиком, потому что витрины выручки и student_balance
-- — security_invoker с join к этим таблицам, а колоночных прав по роли в
-- Postgres нет (ADR-005). Здесь тот же приём, что ADR-005 применил к
-- специалисту: таблицы закрываются политикой, а то, что бухгалтеру
-- действительно нужно, отдают узкие definer-функции, в результате которых
-- колонок со свободным текстом нет физически.
--
-- Решения:
--   Р1. Правило — не «три колонки», а «свободный текст о семье и о занятии»:
--       students.notes/custom_fields, lessons.notes/cancel_reason/custom_fields,
--       attendance.comment, payers.notes/custom_fields. Первые семь закрываются
--       снятием tenant_finance_select с students/lessons/attendance; ради
--       последних снимается и с payers — иначе «бухгалтер не видит заметок»
--       было бы неправдой при зелёном pgTAP (ревью плана, п.2).
--   Р2. Один источник строк «какого ребёнка видит роль» — students_brief():
--       can_payments → весь центр, parent → свои дети, остальным пусто. Его
--       читают и student_balance, и экраны. Это зеркало RLS students для этих
--       ролей: меняешь политику — меняешь здесь (ревью, п.3).
--   Р3. Семантика отказа. Источники строк (students_brief, payers_brief,
--       student_debts, revenue_facts) отдают пусто и без прав, и без
--       auth.uid(): они читаются из вью, а вью обязана вести себя как раньше
--       — ноль строк, не исключение (так же ведёт себя cash_by_source, чей
--       ролевой фильтр остался предикатом в теле). Исключение 42501 —
--       только у скалярного month_open_lessons_count: там ответ «0» значит
--       «можно закрывать» и молчать нельзя.
--       Долг сознательно НЕ скаляр по uuid. Первая редакция имела
--       student_debt_tiyin(uuid) с проверкой вида
--       `not (can_payments() or (role='parent' and v_payer = my_payer_id()))`:
--       у родителя без membership.payer_id сравнение даёт NULL, `not NULL` —
--       NULL, `if NULL` не срабатывает, и функция отдавала долг любого
--       ребёнка центра по uuid (ревью написанного кода). Набор строк такой
--       формы не имеет: не отдаётся то, что не выбрано запросом.
--   Р4. Фильтр центра — в теле каждой функции, а не «доберёт RLS»: definer
--       RLS не применяет. parent_of_student (0006) центра не проверяет, поэтому
--       ветка родителя в students_brief сравнивает payer_id = my_payer_id() и
--       center_id = current_center() сама — родитель с членством в двух
--       центрах не увидит ребёнка из второго (ревью, п.4).
--   Р5. Счётчик незакрытых занятий для вкладки «Периоды» — тот же запрос, что
--       проверяет close_month, вынесен в month_open_lessons_count; close_month
--       перевыпущена и вызывает его. До этого экран считал только planned и
--       обещал «можно закрывать» там, где close_month отказывал по
--       неотмеченным участникам (ревью, п.1).
--   Р6. security definer set-returning не инлайнится планировщиком: фильтр по
--       месяцу из витрин выручки до attendance не доходит, revenue_facts
--       собирает все списанные отметки центра, витрина агрегирует. Принято
--       сознательно, но не на пустом месте: индекса по attendance(center_id)
--       в схеме не было (0009 завёл только lesson/student/subscription), без
--       него каждый рендер дашборда бухгалтера давал seq scan всей таблицы.
--       Частичный индекс заведён ниже и обслуживает обе новые функции —
--       revenue_facts и student_debts.
--       Забор 0021 «каждая вью — security_invoker» остаётся зелёным, но для
--       revenue_* и student_balance больше не значит «RLS нижележащих таблиц
--       применяется»: их источник — definer. Построчные проверки по ролям —
--       в tests/0031.
--   Р7. Побочные следствия для finance, принятые явно: payers_with_stats и
--       students_teacher_view (invoker) отдают ему ноль строк — на его экранах
--       не используются; /app/schedule ему закрыт (сноска ¹⁵ матрицы
--       объясняла доступ только нуждой витрин в lessons — нужды больше нет).
-- =============================================================================


-- 1. Политики ------------------------------------------------------------------------------

-- Список политик tenant_registrar_*/tenant_finance_* — забор, а не декорация:
-- полный ожидаемый набор держит tests/0031 (переехал из 0028). Один
-- call apply_role_rls('students', 'finance', …) в будущей миграции вернёт
-- заметки целиком — и уронит этот тест.
drop policy if exists tenant_finance_select on public.students;
drop policy if exists tenant_finance_select on public.lessons;
drop policy if exists tenant_finance_select on public.attendance;
drop policy if exists tenant_finance_select on public.payers;


-- 2. students_brief — ученики без свободного текста -----------------------------------------

create or replace function public.students_brief()
  returns table (
    id                 uuid,
    center_id          uuid,
    full_name          text,
    birth_date         date,
    status             text,
    payer_id           uuid,
    primary_teacher_id uuid,
    created_at         timestamptz
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  -- Пусто, а не 42501: функция — источник строк student_balance, и вью
  -- обязана отдавать ноль строк там, где раньше их резал предикат (Р3).
  if auth.uid() is null then
    return;
  end if;

  if public.can_payments() then
    return query
      select s.id, s.center_id, s.full_name, s.birth_date, s.status,
             s.payer_id, s.primary_teacher_id, s.created_at
        from public.students s
       where s.center_id = v_center
         and s.deleted_at is null;
  elsif coalesce(public.my_role(), '') = 'parent' then
    return query
      select s.id, s.center_id, s.full_name, s.birth_date, s.status,
             s.payer_id, s.primary_teacher_id, s.created_at
        from public.students s
       where s.center_id = v_center
         and s.payer_id = public.my_payer_id()
         and s.deleted_at is null;
  end if;
  -- teacher и все прочие — пусто: специалисту ученики отдаёт students_teacher_view.
end;
$$;

comment on function public.students_brief() is
  'Ученики текущего центра без notes/custom_fields/source/gender: owner/admin/registrar/finance — весь центр, parent — свои дети, остальным пусто. Зеркало RLS students для этих ролей (0031 Р2): меняешь политику — меняешь здесь. Источник строк student_balance.';

revoke execute on function public.students_brief() from public, anon;
grant execute on function public.students_brief() to authenticated;


-- 3. payers_brief — плательщики без заметок ----------------------------------------------------

create or replace function public.payers_brief()
  returns table (
    id         uuid,
    center_id  uuid,
    full_name  text,
    phone      text,
    phone_alt  text,
    email      text,
    relation   text,
    created_at timestamptz
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null then
    return;
  end if;

  if public.can_payments() then
    return query
      select p.id, p.center_id, p.full_name, p.phone, p.phone_alt, p.email, p.relation, p.created_at
        from public.payers p
       where p.center_id = v_center
         and p.deleted_at is null;
  end if;
  -- parent свою карточку читает из таблицы (payers_read_self), teacher — ничего.
end;
$$;

comment on function public.payers_brief() is
  'Плательщики текущего центра без notes/custom_fields: owner/admin/registrar/finance, остальным пусто (0031 Р1). Контакты для формы платежа и WhatsApp-напоминаний по рассрочке.';

revoke execute on function public.payers_brief() from public, anon;
grant execute on function public.payers_brief() to authenticated;


-- 4. student_debts — долги по занятиям без абонемента ---------------------------------------------

-- Из подзапроса student_balance (0015:939): те же условия плюс явный центр и
-- явный отсев архивных. Набор строк, не скаляр по uuid (Р3): один вызов на
-- запрос вместо вызова на строку и ни одного способа спросить про ребёнка,
-- которого вызывающему не отдал бы обычный select.
create or replace function public.student_debts()
  returns table (student_id uuid, debt_tiyin integer)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_payer  uuid;
begin
  if auth.uid() is null then
    return;
  end if;

  if public.can_payments() then
    return query
      select a.student_id, coalesce(sum(a.price_tiyin), 0)::integer
        from public.attendance a
        join public.students s on s.id = a.student_id and s.center_id = a.center_id
       where a.center_id = v_center
         and a.subscription_id is null
         and a.deducted
         and s.deleted_at is null
       group by a.student_id;

  elsif coalesce(public.my_role(), '') = 'parent' then
    v_payer := public.my_payer_id();
    -- Отдельным if, а не частью предиката: `payer_id = my_payer_id()` при
    -- NULL даёт NULL, и проверка прав, построенная на `not (...)`, молча не
    -- срабатывает. Роль parent без payer_id в membership заводится обычной
    -- сменой роли (change_member_role payer_id не требует).
    if v_payer is null then
      return;
    end if;

    return query
      select a.student_id, coalesce(sum(a.price_tiyin), 0)::integer
        from public.attendance a
        join public.students s on s.id = a.student_id and s.center_id = a.center_id
       where a.center_id = v_center
         and a.subscription_id is null
         and a.deducted
         and s.deleted_at is null
         and s.payer_id = v_payer
       group by a.student_id;
  end if;
end;
$$;

comment on function public.student_debts() is
  'Долг по отметкам deducted без абонемента, строка на ребёнка текущего центра: owner/admin/registrar/finance — весь центр, parent — свои дети, остальным пусто (0031 Р3). Источник debt_tiyin в student_balance.';

revoke execute on function public.student_debts() from public, anon;
grant execute on function public.student_debts() to authenticated;


-- Индекс под оба новых источника: обе функции читают attendance по центру
-- с фильтром deducted, и обе не инлайнятся (Р6).
create index if not exists attendance_center_deducted_idx
  on public.attendance (center_id) where deducted;


-- 5. revenue_facts — источник строк витрин выручки -----------------------------------------------

create or replace function public.revenue_facts()
  returns table (
    center_id       uuid,
    lesson_id       uuid,
    price_tiyin     integer,
    subscription_id uuid,
    paid_teacher_id uuid,
    service_id      uuid,
    starts_at       timestamptz
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  -- Пусто, а не 42501: раньше `select from revenue_by_month` без claims
  -- отдавал ноль строк (предикат в теле вью), и забор 0021 это фиксирует
  -- для cash_by_source, чьё тело не менялось.
  if auth.uid() is null or not public.can_finance() then
    return;
  end if;

  return query
    select a.center_id, a.lesson_id, a.price_tiyin, a.subscription_id,
           a.paid_teacher_id, l.service_id, l.starts_at
      from public.attendance a
      join public.lessons l on l.id = a.lesson_id and l.center_id = a.center_id
     where a.center_id = v_center
       and a.deducted
       and l.status = 'done'
       and l.deleted_at is null;
end;
$$;

comment on function public.revenue_facts() is
  'Списанные отметки проведённых занятий текущего центра — источник revenue_by_month/teacher/service. owner/admin/finance; остальным пусто (0031 Р3). Не инлайнится: фильтр витрины по месяцу до attendance не доходит (Р6).';

revoke execute on function public.revenue_facts() from public, anon;
grant execute on function public.revenue_facts() to authenticated;


-- 6. Витрины выручки на revenue_facts -----------------------------------------------------------

-- из 0028_roles_policies.sql; меняется только источник базового CTE
create or replace view public.revenue_by_month
  with (security_invoker = true)
as
with tz as (
  select public.center_timezone(public.current_center()) as tz
),
base as (
  select a.center_id, a.lesson_id, a.price_tiyin, a.subscription_id,
         date_trunc('month', (a.starts_at at time zone t.tz))::date as month
    from public.revenue_facts() a
    cross join tz t
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
         date_trunc('month', (a.starts_at at time zone t.tz))::date as month
    from public.revenue_facts() a
    cross join tz t
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
  select a.center_id, a.lesson_id, a.price_tiyin, a.subscription_id, a.service_id,
         date_trunc('month', (a.starts_at at time zone t.tz))::date as month
    from public.revenue_facts() a
    cross join tz t
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


-- 7. student_balance на students_brief + student_debts -------------------------------------------

-- из 0028_roles_policies.sql (тело 0015); ролевой where ушёл в students_brief,
-- подзапрос долга — в student_debts. student_balance_pick (invoker, 0015) не
-- тронут: subscriptions/subscription_freezes у finance и registrar открыты
-- политиками, у родителя — *_parent_read.
--
-- student_debts присоединяется обычным left join, а не вызывается на строку:
-- definer-функция на строку — это role_in() + lookup + агрегат на каждого
-- ребёнка центра, а вью читают дашборд и /app/debts целиком.
create or replace view public.student_balance
  with (security_invoker = true)
as
  select
    s.id                                        as student_id,
    s.center_id,
    b.subscription_id                           as active_subscription_id,
    public.subscription_lessons_left(b.subscription_id) as lessons_left,
    b.ends_at,
    coalesce(d.debt_tiyin, 0)::integer          as debt_tiyin,
    (greatest(-coalesce(public.subscription_lessons_left(b.subscription_id), 0), 0)
      * coalesce(b.lesson_price_tiyin, 0))::integer as overdrawn_tiyin,
    b.state
  from public.students_brief() s
  left join lateral public.student_balance_pick(s.id) b on true
  left join public.student_debts() d on d.student_id = s.id;

-- create or replace сохраняет ACL; повторяем явно (правило 0010).
revoke all on table
  public.revenue_by_month, public.revenue_by_teacher, public.revenue_by_service,
  public.student_balance
  from public, anon, authenticated;
grant select on
  public.revenue_by_month, public.revenue_by_teacher, public.revenue_by_service,
  public.student_balance
  to authenticated;


-- 8. month_open_lessons_count + close_month ----------------------------------------------------

-- Ровно то условие, по которому close_month отказывает (0014, раздел 7):
-- не отменённое занятие месяца, которое либо planned, либо без состава,
-- либо с участником без отметки.
create or replace function public.month_open_lessons_count(p_month date)
  returns integer
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_month  date := date_trunc('month', p_month)::date;
  v_tz     text;
  v_count  integer;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_tz := public.center_timezone(v_center);

  select count(distinct l.id) into v_count
    from public.lessons l
    left join public.lesson_participants lp on lp.lesson_id = l.id
   where l.center_id = v_center
     and l.deleted_at is null
     and l.status <> 'cancelled'
     and (l.starts_at at time zone v_tz)::date >= v_month
     and (l.starts_at at time zone v_tz)::date < (v_month + interval '1 month')::date
     and (
           l.status = 'planned'
           or lp.student_id is null
           or not exists (
                select 1 from public.attendance a
                 where a.lesson_id = l.id and a.student_id = lp.student_id
              )
         );

  return v_count;
end;
$$;

comment on function public.month_open_lessons_count(date) is
  'Сколько занятий месяца мешают close_month: planned, без состава или с неотмеченным участником. Тот же запрос, что в close_month (0031 Р5). owner/admin/finance, иначе 42501.';

revoke execute on function public.month_open_lessons_count(date) from public, anon;
grant execute on function public.month_open_lessons_count(date) to authenticated;

-- из 0027_roles_finance_rpc.sql; подсчёт открытых занятий — через
-- month_open_lessons_count, остальное без изменений
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

  v_open_count := public.month_open_lessons_count(v_month);

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

revoke execute on function public.close_month(date) from public, anon;
grant execute on function public.close_month(date) to authenticated;
