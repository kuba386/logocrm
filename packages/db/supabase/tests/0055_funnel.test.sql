-- pgTAP: воронка учеников (0055).
--
-- Заборы: funnel_stages/funnel_events RLS+гранты, guard/history/transition
-- функции без грантов, is_present засеян верно (не deducted, не обратное
-- counts_absence), exempt-список и guard на funnel_events. create_student_
-- with_payer: дефолт lead + событие, явный этап, неизвестный/completed —
-- отказ. Граф set_funnel_stage: шаг вперёд, шаг назад на любой ранний,
-- пропуск вперёд отбивается, X→X без события, архивный — отказ, роль.
-- Прямой PATCH funnel_stage — 42501. Автопереход: продажа абонемента,
-- первое присутствие; «Прогул» (is_present=false, deducts=true) не
-- переводит; paused/archived не трогает; повтор не дублирует событие;
-- completed→active (реактивация) разрешён. Автопереход под РЕАЛЬНОЙ
-- сессией (не auth.uid() is null) — sell_subscription и прямая attendance
-- под registrar; transfer_remaining метит перенос is_service=true, не
-- продажу. Архив/восстановление не трогают funnel_stage и не пишут
-- историю. Видимость funnel_events по ролям и центрам. funnel_summary/
-- funnel_stuck — роль, счёт, пояс, avg_days_on_stage реагирует на период.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(63);


-- 1. Заборы ----------------------------------------------------------------------------------------------

select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('funnel_stage_rank','students_funnel_stage_guard','students_funnel_events',
                           'subscriptions_funnel_transition','attendance_funnel_transition')
        and (has_function_privilege('public', p.oid, 'EXECUTE')
             or has_function_privilege('anon', p.oid, 'EXECUTE')
             or has_function_privilege('authenticated', p.oid, 'EXECUTE')
             or has_function_privilege('service_role', p.oid, 'EXECUTE')
             or has_function_privilege('bot_worker', p.oid, 'EXECUTE')) $$,
  'Внутренние функции воронки без единого гранта');

select set_eq(
  $$ select grantee || ':' || privilege_type from information_schema.role_table_grants
      where grantee in ('anon', 'authenticated') and table_schema = 'public' and table_name = 'funnel_stages' $$,
  $$ values ('authenticated:SELECT') $$,
  'funnel_stages: только SELECT у authenticated, anon — ничего');

select set_eq(
  $$ select grantee || ':' || privilege_type from information_schema.role_table_grants
      where grantee in ('anon', 'authenticated') and table_schema = 'public' and table_name = 'funnel_events' $$,
  $$ values ('authenticated:SELECT') $$,
  'funnel_events: только SELECT у authenticated, anon — ничего; пишет только триггер');

select ok(
  exists (select 1 from public.readonly_guard_exempt_tables() x where x.table_name = 'funnel_stages'),
  'funnel_stages в списке исключений guard (А)');
select ok(
  exists (select 1 from pg_trigger tg
           where tg.tgrelid = 'public.funnel_events'::regclass and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal),
  'funnel_events под readonly guard — обычная таблица центра');


-- Фикстура ------------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0550000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0055@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0550000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-0055@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0550000-0000-0000-0000-000000000003','authenticated','authenticated','registrar-0055@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0550000-0000-0000-0000-000000000004','authenticated','authenticated','finance-0055@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0550000-0000-0000-0000-000000000005','authenticated','authenticated','parent-0055@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0550000-0000-0000-0000-0000000000c1','Центр А 0055','centr-a-0055','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0550000-0000-0000-0000-0000000000c2','Центр Б 0055','centr-b-0055','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0550000-0000-0000-0000-000000000010','a0550000-0000-0000-0000-0000000000c1','Специалист 0055','a0550000-0000-0000-0000-000000000002');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('a0550000-0000-0000-0000-000000000020','a0550000-0000-0000-0000-0000000000c1','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('a0550000-0000-0000-0000-000000000030','a0550000-0000-0000-0000-0000000000c1','Родитель 0055','+996700005501');

-- Для sell_subscription (реальный путь продажи, не прямой insert) в разделе 6б.
insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('a0550000-0000-0000-0000-000000000040','a0550000-0000-0000-0000-0000000000c1','Пакет 8 занятий','lessons',8,700000);

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0550000-0000-0000-0000-000000000001','a0550000-0000-0000-0000-0000000000c1','owner',    null, null),
  ('a0550000-0000-0000-0000-000000000002','a0550000-0000-0000-0000-0000000000c1','teacher','a0550000-0000-0000-0000-000000000010', null),
  ('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('a0550000-0000-0000-0000-000000000004','a0550000-0000-0000-0000-0000000000c1','finance',   null, null),
  ('a0550000-0000-0000-0000-000000000005','a0550000-0000-0000-0000-0000000000c1','parent',    null, 'a0550000-0000-0000-0000-000000000030'),
  -- Тот же человек — registrar и в центре Б: тест кросс-тенанта ловит именно
  -- фильтр по center_id в политике, а не отсутствие роли в чужом центре.
  ('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c2','registrar', null, null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

select is(
  (select array_agg(code order by code) from public.attendance_statuses
    where center_id = 'a0550000-0000-0000-0000-0000000000c1' and is_present),
  array['late','present'],
  'is_present засеян: present/late true, по одному центру (Д, Р1) — centers_seed_statuses ставит их каждому центру заново');
select is(
  (select array_agg(code order by code) from public.attendance_statuses
    where center_id = 'a0550000-0000-0000-0000-0000000000c1' and not is_present),
  array['absent','sick'],
  'sick/absent — не присутствие; «Прогул» списывает занятие, но is_present у него false (Д)');


-- 2. create_student_with_payer (Б) ------------------------------------------------------------------------

select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.create_student_with_payer('Лид 0055', null, 'Родитель Лида', '+996700005502', 'мама') $q$,
  'Без явного этапа — дефолт lead');
reset role;

select is(
  (select funnel_stage from public.students where full_name = 'Лид 0055'), 'lead', 'Действительно lead');
select is(
  (select count(*)::int from public.funnel_events fe join public.students s on s.id = fe.student_id
    where s.full_name = 'Лид 0055' and fe.from_stage is null and fe.to_stage = 'lead'),
  1, 'Событие входа в воронку с from_stage null');

select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.create_student_with_payer('Клиент 0055', 'a0550000-0000-0000-0000-000000000030', null, null, null, null, null, null, null, null, 'active') $q$,
  'С явным этапом active — кассир заводит уже действующего клиента (Б)');
select throws_ok(
  $q$ select public.create_student_with_payer('Плохой 0055', 'a0550000-0000-0000-0000-000000000030', null, null, null, null, null, null, null, null, 'completed') $q$,
  '22023', null,
  'Завести сразу с completed нельзя');
select throws_ok(
  $q$ select public.create_student_with_payer('Плохой2 0055', 'a0550000-0000-0000-0000-000000000030', null, null, null, null, null, null, null, null, 'no-such-stage') $q$,
  '22023', null,
  'Неизвестный этап отбивается');
reset role;
select is((select funnel_stage from public.students where full_name = 'Клиент 0055'), 'active', 'Клиент действительно active');


-- Основной ученик для графа и автоперехода: свежесозданный лид.
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.create_student_with_payer('Граф 0055', 'a0550000-0000-0000-0000-000000000030');
reset role;

create temporary table t0055_student as
  select id from public.students where full_name = 'Граф 0055';
grant select on t0055_student to authenticated;


-- 3. Граф переходов: ручной путь (Р3, Р4) -----------------------------------------------------------------

select public.tests_claims('a0550000-0000-0000-0000-000000000002','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.set_funnel_stage((select id from t0055_student), 'contacted') $q$,
  '42501', null,
  'teacher не может менять этап воронки (can_front_desk)');
reset role;

select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.set_funnel_stage((select id from t0055_student), 'contacted') $q$,
  'Шаг вперёд на непосредственно следующий этап проходит');
select throws_ok(
  $q$ select public.set_funnel_stage((select id from t0055_student), 'trial') $q$,
  '23514', null,
  'Пропуск вперёд (contacted→trial, минуя consultation/assessment) отбивается');
select lives_ok(
  $q$ select public.set_funnel_stage((select id from t0055_student), 'consultation') $q$,
  'Ещё шаг вперёд — на следующий этап');
select lives_ok(
  $q$ select public.set_funnel_stage((select id from t0055_student), 'lead') $q$,
  'Назад — на ЛЮБОЙ более ранний этап (не только на непосредственно предыдущий)');
select lives_ok(
  $q$ select public.set_funnel_stage((select id from t0055_student), 'lead') $q$,
  'X→X — no-op, проходит');
reset role;
select is(
  (select count(*)::int from public.funnel_events fe join public.students s on s.id = fe.student_id
    where s.id = (select id from t0055_student) and fe.from_stage = 'lead' and fe.to_stage = 'lead'),
  0, 'X→X не создало событие (ранний выход в обоих триггерах)');

-- Прямой PATCH без RPC — 42501, независимо от роли.
select public.tests_claims('a0550000-0000-0000-0000-000000000001','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ update public.students set funnel_stage = 'contacted' where id = (select id from t0055_student) $q$,
  '42501', null,
  'Прямой PATCH funnel_stage от owner — отказ: только через set_funnel_stage (находка 2)');
reset role;
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ update public.students set funnel_stage = 'contacted' where id = (select id from t0055_student) $q$,
  '42501', null,
  'И от registrar — apply_role_rls даёт update, но не даёт обойти граф (находка 2)');
reset role;

-- cause/is_service доезжают до строки.
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.set_funnel_stage((select id from t0055_student), 'contacted', 'перезвонили сами', false);
reset role;
-- order by at, id: at одинаков внутри одной транзакции (весь файл — один
-- begin/rollback), id — единственный надёжный тай-брейк (тот же приём,
-- что уже документирован в funnel_summary, header Р10).
select ok(
  (select fe.cause = 'перезвонили сами' and fe.is_service = false and fe.by = 'a0550000-0000-0000-0000-000000000003'
     from public.funnel_events fe where fe.student_id = (select id from t0055_student) and fe.to_stage = 'contacted'
    order by fe.at desc, fe.id desc limit 1),
  'cause/is_service/by записаны верно (В)');

-- Коррекция ошибки оператора — is_service=true, отдельно от обычного шага.
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.set_funnel_stage((select id from t0055_student), 'consultation', 'опечатка при вводе', true);
reset role;
select ok(
  (select fe.is_service = true and fe.cause = 'опечатка при вводе'
     from public.funnel_events fe where fe.student_id = (select id from t0055_student) and fe.to_stage = 'consultation'
    order by fe.at desc, fe.id desc limit 1),
  'p_is_service=true доезжает до строки — коррекция, а не обычный шаг (Р10 её исключает из funnel_summary.transitions)');


-- 4. Архивный студент и статус (Р4, Р7) --------------------------------------------------------------------

select public.tests_claims(null, null);
update public.students set status = 'archived' where id = (select id from t0055_student);
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.set_funnel_stage((select id from t0055_student), 'assessment') $q$,
  '22023', null,
  'Архивного не ведут по воронке — сначала restore_student');
reset role;
select public.tests_claims(null, null);
update public.students set status = 'active' where id = (select id from t0055_student);


-- 5. Архив/восстановление не трогают funnel_stage (Г) --------------------------------------------------------
-- К этому моменту у t0055_student шесть событий: создание (null→lead),
-- lead→contacted, contacted→consultation, consultation→lead (назад),
-- lead→contacted (с cause), contacted→consultation (коррекция, is_service=
-- true). Фиксируем число до архива и сравниваем после архив→восстановление.

create temporary table t0055_before_archive as
  select funnel_stage from public.students where id = (select id from t0055_student);
create temporary table t0055_events_before as
  select count(*)::int as n from public.funnel_events where student_id = (select id from t0055_student);
select is((select n from t0055_events_before), 6, 'До архива у студента шесть событий из раздела 3');

select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.archive_student((select id from t0055_student));
select public.restore_student((select id from t0055_student));
reset role;

select is(
  (select funnel_stage from public.students where id = (select id from t0055_student)),
  (select funnel_stage from t0055_before_archive),
  'funnel_stage не изменился через цикл архив→восстановление (Г)');
select is(
  (select count(*)::int from public.funnel_events where student_id = (select id from t0055_student)),
  (select n from t0055_events_before),
  'Число событий не выросло — архив/восстановление funnel_events не пишут (Г)');


-- 6. Автопереход (Р5, Р9) ------------------------------------------------------------------------------------

-- Отдельный студент для чистого автоперехода.
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.create_student_with_payer('Продажа 0055', 'a0550000-0000-0000-0000-000000000030');
reset role;
create temporary table t0055_sale as select id from public.students where full_name = 'Продажа 0055';
grant select on t0055_sale to authenticated;

select public.tests_claims(null, null);
insert into public.subscriptions (center_id, student_id, payer_id, price_tiyin, starts_at)
values ('a0550000-0000-0000-0000-0000000000c1', (select id from t0055_sale),
        'a0550000-0000-0000-0000-000000000030', 700000, current_date);

select is((select funnel_stage from public.students where id = (select id from t0055_sale)), 'active',
  'Продажа абонемента переводит lead → active автоматически (Р5)');
select is(
  (select count(*)::int from public.funnel_events where student_id = (select id from t0055_sale) and to_stage = 'active' and is_service = false),
  1, 'Событие конверсии — is_service=false (реальная, не служебная)');

-- Повторная продажа тому же студенту не дублирует переход.
select public.tests_claims(null, null);
insert into public.subscriptions (center_id, student_id, payer_id, price_tiyin, starts_at)
values ('a0550000-0000-0000-0000-0000000000c1', (select id from t0055_sale),
        'a0550000-0000-0000-0000-000000000030', 700000, current_date);
select is(
  (select count(*)::int from public.funnel_events where student_id = (select id from t0055_sale) and to_stage = 'active'),
  1, 'Вторая продажа не создала второе событие — студент уже active');

-- Посещение: студент для теста «Прогул» не переводит, а «Пришёл» — переводит.
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.create_student_with_payer('Посещение 0055', 'a0550000-0000-0000-0000-000000000030');
reset role;
create temporary table t0055_att as select id from public.students where full_name = 'Посещение 0055';
grant select on t0055_att to authenticated;

insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('a0550000-0000-0000-0000-000000000060','a0550000-0000-0000-0000-0000000000c1','a0550000-0000-0000-0000-000000000010',
   (select id from t0055_att),'a0550000-0000-0000-0000-000000000020','planned',
   now() - interval '2 hours', now() - interval '1 hour 15 minutes'),
  ('a0550000-0000-0000-0000-000000000061','a0550000-0000-0000-0000-0000000000c1','a0550000-0000-0000-0000-000000000010',
   (select id from t0055_att),'a0550000-0000-0000-0000-000000000020','planned',
   now() - interval '1 hour', now() - interval '15 minutes');

-- Реальная сессия, не tests_claims(null,null): attendance_recalc_trigger
-- (0010) безусловно зовёт emit_event('attendance.marked', ...) на каждый
-- insert, а emit_event (0002) с этой миграции требует auth.uid() — без
-- сессии сама вставка падает раньше, чем что-либо про воронку.
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into public.attendance (center_id, lesson_id, student_id, status_id)
values ('a0550000-0000-0000-0000-0000000000c1', 'a0550000-0000-0000-0000-000000000060', (select id from t0055_att),
        (select id from public.attendance_statuses where center_id = 'a0550000-0000-0000-0000-0000000000c1' and code = 'absent'));
reset role;

select is((select funnel_stage from public.students where id = (select id from t0055_att)), 'lead',
  'Отметка «Прогул» (deducts_lesson=true, is_present=false) НЕ переводит в active — deducted не годится критерием (Д)');

select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into public.attendance (center_id, lesson_id, student_id, status_id)
values ('a0550000-0000-0000-0000-0000000000c1', 'a0550000-0000-0000-0000-000000000061', (select id from t0055_att),
        (select id from public.attendance_statuses where center_id = 'a0550000-0000-0000-0000-0000000000c1' and code = 'present'));
reset role;

select is((select funnel_stage from public.students where id = (select id from t0055_att)), 'active',
  'Отметка «Пришёл» (is_present=true) переводит в active (Р5)');


-- paused/archived не трогает автопереход; completed→active (реактивация) разрешён.
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.create_student_with_payer('Пауза 0055', 'a0550000-0000-0000-0000-000000000030');
reset role;
create temporary table t0055_paused as select id from public.students where full_name = 'Пауза 0055';
select public.tests_claims(null, null);
update public.students set status = 'paused' where id = (select id from t0055_paused);
insert into public.subscriptions (center_id, student_id, payer_id, price_tiyin, starts_at)
values ('a0550000-0000-0000-0000-0000000000c1', (select id from t0055_paused),
        'a0550000-0000-0000-0000-000000000030', 700000, current_date);
select is((select funnel_stage from public.students where id = (select id from t0055_paused)), 'lead',
  'Приостановленный студент не реактивируется продажей абонемента (Р5)');


-- Реактивация: completed → active автопереходом разрешён (Р9).
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.set_funnel_stage((select id from t0055_sale), 'completed');
reset role;
select is((select funnel_stage from public.students where id = (select id from t0055_sale)), 'completed',
  'Продажа 0055 доведена до completed вручную для теста реактивации');

select public.tests_claims(null, null);
insert into public.subscriptions (center_id, student_id, payer_id, price_tiyin, starts_at)
values ('a0550000-0000-0000-0000-0000000000c1', (select id from t0055_sale),
        'a0550000-0000-0000-0000-000000000030', 700000, current_date);
select is((select funnel_stage from public.students where id = (select id from t0055_sale)), 'active',
  'Новая продажа вернувшемуся клиенту из completed переводит в active — реактивация (Р9)');
select is(
  (select count(*)::int from public.funnel_events where student_id = (select id from t0055_sale) and from_stage = 'completed' and to_stage = 'active'),
  1, 'Реактивация оставила событие completed→active');


-- 6б. Автопереход под реальной сессией (Р5, находка 2) ---------------------------------------------------
--
-- Раздел 6 выше вставляет subscriptions/attendance под tests_claims(null,
-- null) — auth.uid() is null, и students_funnel_stage_guard выходит на
-- границе 0050 Р1 ДО чтения logocrm.funnel_auto. В проде продажу делает
-- кассир (auth.uid() не null) — это другая ветка того же триггера, и её
-- раздел 6 не проверял вовсе.

select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.create_student_with_payer('СессияПродажа 0055', 'a0550000-0000-0000-0000-000000000030');
create temporary table t0055_sess_sale as select id from public.students where full_name = 'СессияПродажа 0055';
select public.sell_subscription('a0550000-0000-0000-0000-000000000040', (select id from t0055_sess_sale));
reset role;

select is((select funnel_stage from public.students where id = (select id from t0055_sess_sale)), 'active',
  'sell_subscription под реальной сессией registrar тоже переводит в active — ветка funnel_auto, не auth.uid() is null (находка 2)');
select is(
  (select count(*)::int from public.funnel_events where student_id = (select id from t0055_sess_sale) and to_stage = 'active' and is_service = false),
  1, 'Событие конверсии под сессией — is_service=false');

select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.create_student_with_payer('СессияПосещение 0055', 'a0550000-0000-0000-0000-000000000030');
create temporary table t0055_sess_att as select id from public.students where full_name = 'СессияПосещение 0055';

-- Не now()-1h/-15m: тот же слот у того же специалиста уже занят лесс. 061
-- в разделе 6 (lessons_teacher_no_overlap отбил бы вставку).
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('a0550000-0000-0000-0000-000000000062','a0550000-0000-0000-0000-0000000000c1','a0550000-0000-0000-0000-000000000010',
   (select id from t0055_sess_att),'a0550000-0000-0000-0000-000000000020','planned',
   now() - interval '3 hours', now() - interval '2 hours 15 minutes');

-- registrar пишет attendance напрямую (apply_role_rls 'write', 0028) —
-- тот же путь, что учитель использует на экране расписания.
insert into public.attendance (center_id, lesson_id, student_id, status_id)
values ('a0550000-0000-0000-0000-0000000000c1', 'a0550000-0000-0000-0000-000000000062', (select id from t0055_sess_att),
        (select id from public.attendance_statuses where center_id = 'a0550000-0000-0000-0000-0000000000c1' and code = 'present'));
reset role;

select is((select funnel_stage from public.students where id = (select id from t0055_sess_att)), 'active',
  'Отметка «Пришёл» под реальной сессией тоже переводит в active (находка 2)');
select is(
  (select count(*)::int from public.funnel_events where student_id = (select id from t0055_sess_att) and to_stage = 'active' and is_service = false),
  1, 'Событие присутствия под сессией — is_service=false');

-- Перенос остатка (transfer_remaining, 0026) — служебный автопереход,
-- не продажа: не должен засчитываться конверсией (Р12б, находка 8).
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.create_student_with_payer('ДонорПереноса 0055', 'a0550000-0000-0000-0000-000000000030');
create temporary table t0055_donor as select id from public.students where full_name = 'ДонорПереноса 0055';
select public.sell_subscription('a0550000-0000-0000-0000-000000000040', (select id from t0055_donor));
create temporary table t0055_donor_sub as
  select id from public.subscriptions where student_id = (select id from t0055_donor) order by created_at desc limit 1;

select public.create_student_with_payer('ПолучательПереноса 0055', 'a0550000-0000-0000-0000-000000000030');
create temporary table t0055_receiver as select id from public.students where full_name = 'ПолучательПереноса 0055';
select public.transfer_remaining((select id from t0055_donor_sub), (select id from t0055_receiver));
reset role;

select is((select funnel_stage from public.students where id = (select id from t0055_receiver)), 'active',
  'Перенос остатка переводит получателя в active — у него появился абонемент');
select is(
  (select count(*)::int from public.funnel_events where student_id = (select id from t0055_receiver) and to_stage = 'active' and is_service = true),
  1, 'Но событие — is_service=true (Р12б): перенос не продажа, funnel_summary.conversion его не считает');
select is(
  (select count(*)::int from public.funnel_events where student_id = (select id from t0055_receiver) and to_stage = 'active' and is_service = false),
  0, 'И ни одного is_service=false события у получателя — двойного счёта конверсии нет');


-- 7. Видимость funnel_events по ролям и центрам (Р6) ------------------------------------------------------

select public.tests_claims('a0550000-0000-0000-0000-000000000002','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.funnel_events), 0, 'teacher не видит funnel_events своего центра вовсе');
reset role;

select public.tests_claims('a0550000-0000-0000-0000-000000000004','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.funnel_events), 0, 'finance не видит funnel_events — коммерческая история, can_finance ≠ can_front_desk');
reset role;

select public.tests_claims('a0550000-0000-0000-0000-000000000005','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.funnel_events), 0, 'parent не видит funnel_events вовсе');
reset role;

select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select ok((select count(*)::int from public.funnel_events) > 0, 'registrar своего центра видит funnel_events (can_front_desk)');
reset role;

-- Кросс-тенант: тот же registrar, тем же can_front_desk()=true, но в JWT
-- центр Б — политика обязана фильтровать по center_id, не только по роли.
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is((select count(*)::int from public.funnel_events), 0,
  'registrar с ролью в центре Б (can_front_desk истинно) не видит funnel_events центра А (Р6)');
reset role;
select public.tests_claims(null, null);


-- 8. funnel_summary / funnel_stuck (Р10) --------------------------------------------------------------------

select public.tests_claims('a0550000-0000-0000-0000-000000000002','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.funnel_summary(current_date - 30, current_date) $q$,
  '42501', null,
  'teacher не вызывает funnel_summary (owner/admin only)');
reset role;
select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.funnel_summary(current_date - 30, current_date) $q$,
  '42501', null,
  'registrar тоже не вызывает funnel_summary — бизнес-аналитика уже, операционных ролей');
reset role;

select public.tests_claims('a0550000-0000-0000-0000-000000000001','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.funnel_summary(current_date + 1, current_date) $q$,
  '22023', null,
  'from > to отбивается');

-- center_today(), не current_date: сессия CI — в UTC, а funnel_summary
-- переводит границы периода в пояс центра (Asia/Bishkek, +6) — вечером по
-- UTC «сегодня» в Бишкеке уже следующий день, и current_date снаружи не
-- совпадал бы с той датой, которую функция считает «сегодня» внутри.
create temporary table t0055_summary as
  select public.funnel_summary(
    public.center_today('a0550000-0000-0000-0000-0000000000c1') - 30,
    public.center_today('a0550000-0000-0000-0000-0000000000c1')
  ) as s;

select ok(
  (select count(*)::int from jsonb_array_elements((select s from t0055_summary) -> 'current') x
    where (x ->> 'stage') = 'active' and (x ->> 'count')::int >= 2) > 0,
  'funnel_summary.current: минимум двое active сейчас (Продажа 0055, Посещение 0055)');
select ok(
  (select count(*)::int from jsonb_array_elements((select s from t0055_summary) -> 'transitions') x
    where (x ->> 'from_stage') is null and (x ->> 'to_stage') = 'lead' and (x ->> 'count')::int >= 4) > 0,
  'funnel_summary.transitions: входов в воронку (null→lead) за период не меньше числа заведённых учеников');
select ok(
  ((select s from t0055_summary) -> 'conversion' ->> 'entered')::int >= 4
  and ((select s from t0055_summary) -> 'conversion' ->> 'converted')::int >= 2,
  'funnel_summary.conversion: считает по ученикам (вошёл в период → достиг active когда-либо после)');
select is(jsonb_typeof((select s from t0055_summary) -> 'avg_days_on_stage'), 'array', 'avg_days_on_stage — массив');
select is(jsonb_typeof((select s from t0055_summary) -> 'sources'), 'array', 'sources — массив');

-- avg_days_on_stage обязан отвечать на период, а не быть за всё время
-- (находка 3): за окно, где нет вообще никаких событий, массив пуст.
select is(
  (select public.funnel_summary('1990-01-01'::date, '1990-01-02'::date) -> 'avg_days_on_stage'),
  '[]'::jsonb,
  'avg_days_on_stage за период без единого события — пустой массив, не «за всё время» (находка 3)');
select ok(
  jsonb_array_length((select s from t0055_summary) -> 'avg_days_on_stage') > 0,
  'а за период с реальными событиями (30 дней) — не пуст: подтверждает, что фильтр именно по периоду, не сломан вовсе');
reset role;
select public.tests_claims(null, null);

-- funnel_stuck: роль и содержимое.
select public.tests_claims('a0550000-0000-0000-0000-000000000004','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select * from public.funnel_stuck(14) $q$,
  '42501', null,
  'finance не вызывает funnel_stuck (can_front_desk)');
reset role;

-- Событие «Граф 0055» стоит на contacted давно (создано в этом же прогоне,
-- но искусственно состарим последнее событие, чтобы попасть в застрявшие).
select public.tests_claims(null, null);
update public.funnel_events set at = now() - interval '20 days'
 where student_id = (select id from t0055_student)
   and at = (select max(at) from public.funnel_events where student_id = (select id from t0055_student));

select public.tests_claims('a0550000-0000-0000-0000-000000000003','a0550000-0000-0000-0000-0000000000c1');
set local role authenticated;
select ok(
  exists (select 1 from public.funnel_stuck(14) fs where fs.student_id = (select id from t0055_student)),
  'Студент без движения 20 дней (порог 14) попадает в застрявшие');
select ok(
  not exists (select 1 from public.funnel_stuck(14) fs where fs.student_id = (select id from t0055_sale)),
  'active-студент (Продажа 0055) не входит в застрявшие — funnel_stage not in (active, completed)');
reset role;
select public.tests_claims(null, null);

select * from finish();

rollback;
