-- pgTAP: бухгалтер не читает заметок (0031, отменяет Р5 из 0028).
-- Забор по pg_policies — полный ожидаемый набор tenant_registrar_*/
-- tenant_finance_* — переехал сюда из 0028: один call apply_role_rls
-- ('students', 'finance', …) в будущей миграции роняет его. Проверки
-- видимости таблиц — is(count, 0), не throws: отсутствующая политика даёт
-- ноль строк. Функции проверяются по каждой роли отдельно, не «прочие»,
-- и отдельно — по роли parent БЕЗ payer_id в членстве: на этом NULL
-- первая редакция миграции отдавала долг любого ребёнка.
-- reset role не сбрасывает request.jwt.claims — tests_claims() перед
-- каждым блоком явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(92);


-- 1-2. Забор по каталогу политик --------------------------------------------------------

select set_eq(
  $$ select tablename || ':' || policyname from pg_policies
      where schemaname = 'public'
        and (policyname like 'tenant_registrar%' or policyname like 'tenant_finance%') $$,
  $$ values
    ('students:tenant_registrar_select'), ('students:tenant_registrar_insert'), ('students:tenant_registrar_update'),
    ('payers:tenant_registrar_select'), ('payers:tenant_registrar_insert'), ('payers:tenant_registrar_update'),
    ('groups:tenant_registrar_select'), ('groups:tenant_registrar_insert'), ('groups:tenant_registrar_update'),
    ('group_students:tenant_registrar_select'), ('group_students:tenant_registrar_insert'), ('group_students:tenant_registrar_update'),
    ('lessons:tenant_registrar_select'), ('lessons:tenant_registrar_insert'), ('lessons:tenant_registrar_update'),
    ('attendance:tenant_registrar_select'), ('attendance:tenant_registrar_insert'), ('attendance:tenant_registrar_update'),
    ('teachers:tenant_registrar_select'), ('rooms:tenant_registrar_select'), ('services:tenant_registrar_select'),
    ('subscription_types:tenant_registrar_select'), ('subscriptions:tenant_registrar_select'),
    ('subscription_freezes:tenant_registrar_select'), ('payments:tenant_registrar_select'),
    ('installment_plans:tenant_registrar_select'), ('installments:tenant_registrar_select'),
    ('student_payers:tenant_registrar_select'), ('financial_periods:tenant_registrar_select'),
    ('lesson_participants:tenant_registrar_select'), ('booking_requests:tenant_registrar_select'),
    ('teacher_rates:tenant_finance_select'), ('teacher_rates:tenant_finance_insert'),
    ('expense_categories:tenant_finance_select'), ('expense_categories:tenant_finance_insert'), ('expense_categories:tenant_finance_update'),
    ('payment_sources:tenant_finance_select'), ('payment_sources:tenant_finance_insert'), ('payment_sources:tenant_finance_update'),
    ('payments:tenant_finance_select'), ('expenses:tenant_finance_select'), ('financial_periods:tenant_finance_select'),
    ('salary_adjustments:tenant_finance_select'), ('salary_runs:tenant_finance_select'),
    ('teachers:tenant_finance_select'), ('student_payers:tenant_finance_select'),
    ('subscriptions:tenant_finance_select'),
    ('subscription_freezes:tenant_finance_select'), ('subscription_types:tenant_finance_select'),
    ('installment_plans:tenant_finance_select'), ('installments:tenant_finance_select')
  $$,
  'Политики новых ролей — ровно ожидаемый набор: у finance нет students/lessons/attendance/payers (0031), остальное как в 0028'
);
select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and policyname = 'tenant_finance_select'
      and tablename in ('students', 'lessons', 'attendance', 'payers')),
  0, 'tenant_finance_select снята ровно с четырёх таблиц со свободным текстом'
);


-- Фикстура ----------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','nobody@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-ab@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','88888888-8888-8888-8888-888888888888','authenticated','authenticated','parent-nopayer@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-notes','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-notes','{}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист А');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Логопед',70000);

-- Группа без состава — ради ветки «занятие без участников» в счётчике
-- незакрытых занятий.
insert into public.groups (id, center_id, name) values
  ('9a9a9a9a-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Группа без детей');

-- Заметка о семье — свободный текст, который стойка пишет про родителей.
insert into public.payers (id, center_id, full_name, phone, notes) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик А','+996700000001','звонить только бабушке'),
  ('dddddddd-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000b','Плательщик Б','+996700000002',null);

-- Родитель 7777 состоит в двух центрах: проверка, что definer-функции держат
-- границу центра сами, а не «доберёт RLS». Родитель 8888 — parent без
-- payer_id: обычное состояние после change_member_role, которая payer_id не
-- требует и не заполняет.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner', null, null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a','registrar', null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','finance', null, null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001', null),
  ('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000001'),
  ('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000b','parent', null, 'dddddddd-0000-0000-0000-000000000002'),
  ('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-00000000000a','parent', null, null);

insert into public.students (id, center_id, full_name, payer_id, notes, custom_fields) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок 1','dddddddd-0000-0000-0000-000000000001','заметка приёма','{"диагноз":"ОНР"}'::jsonb),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Ребёнок 2','dddddddd-0000-0000-0000-000000000001', null, '{}'::jsonb),
  ('eeeeeeee-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000b','Ребёнок Б','dddddddd-0000-0000-0000-000000000002', null, '{}'::jsonb);

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','8 занятий','lessons',8,400000);

-- Август: L1 — проведено с отметкой по абонементу (выручка 50000);
--         L2 — проведено с отметкой без абонемента (долг 70000 по цене услуги);
--         L4 — проведено БЕЗ отметки (ветка «участник без отметки»);
--         L5 — групповое, проведено, состав пуст (ветка lp.student_id is null);
--         L6 — отменено без отметок (в счётчик не входит).
-- Сентябрь: L3 — 1 сентября 01:30 по Бишкеку = 31 августа 19:30 UTC: граница
--           месяца считается по поясу центра, не по UTC.
insert into public.lessons (id, center_id, teacher_id, student_id, group_id, service_id, status, starts_at, ends_at, notes) values
  ('ffffffff-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',null,'bbbbbbbb-0000-0000-0000-000000000001','planned','2026-08-10 10:00+06','2026-08-10 10:45+06','заметка занятия'),
  ('ffffffff-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000002',null,'bbbbbbbb-0000-0000-0000-000000000001','planned','2026-08-12 10:00+06','2026-08-12 10:45+06',null),
  ('ffffffff-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',null,'bbbbbbbb-0000-0000-0000-000000000001','planned','2026-09-01 01:30+06','2026-09-01 02:15+06',null),
  ('ffffffff-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',null,'bbbbbbbb-0000-0000-0000-000000000001','planned','2026-08-20 10:00+06','2026-08-20 10:45+06',null),
  ('ffffffff-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001',null,'9a9a9a9a-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','done','2026-08-21 10:00+06','2026-08-21 10:45+06',null),
  ('ffffffff-0000-0000-0000-000000000006','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000002',null,'bbbbbbbb-0000-0000-0000-000000000001','cancelled','2026-08-22 10:00+06','2026-08-22 10:45+06',null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_ins (name text primary key, id uuid);
create temporary table t_owner_rev (
  month date, visits integer, lessons integer, unlimited_visits integer, unpriced_visits integer, revenue_tiyin bigint);
create temporary table t_owner_bal (
  student_id uuid, active_subscription_id uuid, lessons_left integer, debt_tiyin integer, overdrawn_tiyin integer, state text);
create temporary table t_ids (role_name text, id uuid);
grant select, insert on t_ins, t_owner_rev, t_owner_bal, t_ids to authenticated;

-- Данные — руками владельца через RPC, как в приложении.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
insert into t_ins values ('sub1', public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', null, '2026-08-01'));
select public.mark_attendance('ffffffff-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', null, 'комментарий отметки');
select public.mark_lesson_status('ffffffff-0000-0000-0000-000000000001', 'done');
select public.mark_attendance('ffffffff-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000002');
select public.mark_lesson_status('ffffffff-0000-0000-0000-000000000002', 'done');
select public.mark_lesson_status('ffffffff-0000-0000-0000-000000000004', 'done');
-- Эталон владельца — до любых проверок бухгалтера.
insert into t_owner_rev select month, visits, lessons, unlimited_visits, unpriced_visits, revenue_tiyin from public.revenue_by_month;
insert into t_owner_bal select student_id, active_subscription_id, lessons_left, debt_tiyin, overdrawn_tiyin, state from public.student_balance;
insert into t_ids select 'owner', id from public.students;
reset role;


-- 3-6. Фикстура собрана как задумано (от postgres, без RLS) -----------------------------------

select is((select count(*)::int from public.attendance), 2, 'Фикстура: две отметки (L1 по абонементу, L2 без)');
select is(
  (select price_tiyin from public.attendance where lesson_id = 'ffffffff-0000-0000-0000-000000000002'), 70000,
  'Фикстура: отметка без абонемента заморозила цену услуги — есть что показывать в долге');
select is(
  (select revenue_tiyin from t_owner_rev where month = '2026-08-01'), 120000::bigint,
  'Эталон владельца: выручка августа 50000 + 70000');
select is(
  (select debt_tiyin from t_owner_bal where student_id = 'eeeeeeee-0000-0000-0000-000000000002'), 70000,
  'Эталон владельца: долг Ребёнка 2 — 70000');


-- 7-33. finance: таблицы закрыты, функции и витрины отдают то же, что владельцу ---------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is((select count(*)::int from public.students), 0, 'finance: students — 0 строк, не ошибка');
select is((select count(*)::int from public.lessons), 0, 'finance: lessons — 0 строк');
select is((select count(*)::int from public.attendance), 0, 'finance: attendance — 0 строк');
select is((select count(*)::int from public.payers), 0, 'finance: payers — 0 строк (payers.notes — та же заметка о семье)');
select is_empty(
  $q$ select notes from public.students where id = 'eeeeeeee-0000-0000-0000-000000000001' $q$,
  'finance не читает students.notes');
select is_empty(
  $q$ select notes from public.lessons where id = 'ffffffff-0000-0000-0000-000000000001' $q$,
  'finance не читает lessons.notes');
select is_empty(
  $q$ select comment from public.attendance where lesson_id = 'ffffffff-0000-0000-0000-000000000001' $q$,
  'finance не читает attendance.comment');
select is_empty(
  $q$ select notes from public.payers where id = 'dddddddd-0000-0000-0000-000000000001' $q$,
  'finance не читает payers.notes');
select is((select count(*)::int from public.students_teacher_view), 0,
  'finance: students_teacher_view (invoker, с notes) пуста — прежняя ветка карточки ученика больше не источник');
select is((select count(*)::int from public.payers_with_stats), 0,
  'finance: payers_with_stats (invoker, с notes) пуста — принято явно (0031 Р7)');

select is((select count(*)::int from public.students_brief()), 2, 'finance: students_brief — оба ученика центра');
select throws_ok(
  $q$ select notes from public.students_brief() $q$,
  '42703', null, 'students_brief: колонки notes нет физически, не «скрыта»');
select throws_ok(
  $q$ select custom_fields from public.students_brief() $q$,
  '42703', null, 'students_brief: колонки custom_fields нет физически');
select is(
  (select phone from public.payers_brief() where id = 'dddddddd-0000-0000-0000-000000000001'), '+996700000001',
  'finance: payers_brief отдаёт телефон — WhatsApp по рассрочке работает');
select throws_ok(
  $q$ select notes from public.payers_brief() $q$,
  '42703', null, 'payers_brief: колонки notes нет физически');

select is(
  (select revenue_tiyin from public.revenue_by_month where month = '2026-08-01'),
  (select revenue_tiyin from t_owner_rev where month = '2026-08-01'),
  'revenue_by_month у finance равна владельцу — не «выручка 0» без политики на lessons');
select is(
  (select visits from public.revenue_by_month where month = '2026-08-01'), 2,
  'revenue_by_month у finance: посещений 2 — обе отметки, включая без абонемента');
select is(
  (select count(*)::int from public.revenue_by_service where service_id = 'bbbbbbbb-0000-0000-0000-000000000001'), 1,
  'revenue_by_service у finance: service_id из lessons пришёл через revenue_facts');
select is(
  (select count(*)::int from public.revenue_by_teacher where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 1,
  'revenue_by_teacher у finance непуста');
select set_eq(
  $q$ select student_id, active_subscription_id, lessons_left, debt_tiyin, overdrawn_tiyin, state from public.student_balance $q$,
  $q$ select student_id, active_subscription_id, lessons_left, debt_tiyin, overdrawn_tiyin, state from t_owner_bal $q$,
  'student_balance у finance построчно равна владельцу (строки — students_brief, долг — student_debts)');
select is(
  (select debt_tiyin from public.student_balance where student_id = 'eeeeeeee-0000-0000-0000-000000000002'), 70000,
  'student_balance.debt_tiyin у finance — 70000, число не уехало при переносе подзапроса в definer');
select is(
  (select debt_tiyin from public.student_debts() where student_id = 'eeeeeeee-0000-0000-0000-000000000002'), 70000,
  'student_debts у finance — 70000 по Ребёнку 2');
select is(
  (select count(*)::int from public.student_debts()), 1,
  'student_debts — строка только у того, у кого долг есть (ребёнок с абонементом в набор не попадает)');
select is_empty(
  $q$ select debt_tiyin from public.student_debts() where student_id = 'eeeeeeee-0000-0000-0000-000000000003' $q$,
  'student_debts: ребёнка другого центра в наборе нет — спросить «долг по uuid» нельзя, форма не та');

select is(public.month_open_lessons_count('2026-08-01'), 2,
  'month_open_lessons_count: август — L4 (проведено без отметки) и L5 (пустой состав); отменённое L6 не считается');
select is(public.month_open_lessons_count('2026-09-01'), 1,
  'month_open_lessons_count: сентябрь — L3 в 01:30 по Бишкеку (31 августа по UTC) попал в сентябрь');
select throws_ok(
  $q$ select public.close_month('2026-08-01') $q$,
  '22023', null, 'close_month отказывает ровно тогда, когда счётчик > 0');
reset role;


-- 34-38. Владелец закрывает оба хвоста — счётчик 0, месяц закрывается ------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.mark_attendance('ffffffff-0000-0000-0000-000000000004', 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  'owner отмечает L4');
select is(public.month_open_lessons_count('2026-08-01'), 1,
  'month_open_lessons_count: после отметки L4 остаётся L5 — «или отмените» не пустые слова');
select lives_ok(
  $q$ select public.mark_lesson_status('ffffffff-0000-0000-0000-000000000005', 'cancelled') $q$,
  'owner отменяет групповое занятие без состава');
select is(public.month_open_lessons_count('2026-08-01'), 0, 'month_open_lessons_count: после отмены L5 — 0');
select lives_ok(
  $q$ select public.close_month('2026-08-01') $q$,
  'close_month проходит ровно тогда, когда счётчик 0 — одна копия условия');
reset role;


-- 39-47. registrar: ничего не изменилось --------------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.students), 2, 'registrar видит учеников');
select is(
  (select notes from public.students where id = 'eeeeeeee-0000-0000-0000-000000000001'), 'заметка приёма',
  'registrar читает students.notes — снятие политик касается только finance');
select is((select count(*)::int from public.lessons), 6, 'registrar видит занятия');
select is((select count(*)::int from public.attendance), 3, 'registrar видит отметки');
select is((select count(*)::int from public.payers), 1, 'registrar видит плательщиков');
select is((select count(*)::int from public.students_brief()), 2, 'registrar: students_brief работает (can_payments)');
select is(
  (select debt_tiyin from public.student_debts() where student_id = 'eeeeeeee-0000-0000-0000-000000000002'), 70000,
  'registrar: student_debts — тот же долг (стойка звонит по долгам)');
select throws_ok(
  $q$ select public.month_open_lessons_count('2026-08-01') $q$,
  '42501', null, 'registrar: month_open_lessons_count — 42501, замок месяца не его');
select is((select count(*)::int from public.revenue_by_month), 0,
  'registrar: revenue_by_month пуста — revenue_facts без can_finance отдаёт пусто, не ошибку');
insert into t_ids select 'registrar', id from public.students;
reset role;


-- 48-54. teacher: пусто там, где раньше было пусто ------------------------------------------------

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.students_brief()), 0,
  'teacher: students_brief пуста — ученики специалиста в students_teacher_view');
select is((select count(*)::int from public.payers_brief()), 0, 'teacher: payers_brief пуста');
select is((select count(*)::int from public.student_debts()), 0, 'teacher: student_debts пуст — долги не его дело');
select is((select count(*)::int from public.revenue_facts()), 0, 'teacher: revenue_facts пуста');
select is((select count(*)::int from public.revenue_by_month), 0, 'teacher: revenue_by_month пуста, как раньше');
select is((select count(*)::int from public.student_balance), 0,
  'teacher: student_balance пуст, как раньше (панель отметки читает её без ошибки)');
select throws_ok(
  $q$ select public.month_open_lessons_count('2026-08-01') $q$,
  '42501', null, 'teacher: month_open_lessons_count — 42501');
reset role;


-- 55-63. parent в двух центрах: только свои дети текущего центра -------------------------------

select public.tests_claims('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select set_eq(
  $q$ select id from public.students_brief() $q$,
  array['eeeeeeee-0000-0000-0000-000000000001'::uuid, 'eeeeeeee-0000-0000-0000-000000000002'::uuid],
  'parent в центре А: students_brief — двое своих детей центра А');
select is(
  (select debt_tiyin from public.student_debts() where student_id = 'eeeeeeee-0000-0000-0000-000000000002'), 70000,
  'parent: student_debts — долг своего ребёнка');
select is_empty(
  $q$ select debt_tiyin from public.student_debts() where student_id = 'eeeeeeee-0000-0000-0000-000000000003' $q$,
  'parent в центре А: ребёнка из центра Б в наборе нет, хотя платит за него тот же родитель');
select is(
  (select debt_tiyin from public.student_balance where student_id = 'eeeeeeee-0000-0000-0000-000000000002'), 70000,
  'parent: student_balance — долг своего ребёнка виден числом');
select is((select count(*)::int from public.student_balance), 2, 'parent: student_balance — только свои дети');
select is((select count(*)::int from public.payers_brief()), 0,
  'parent: payers_brief пуста — своя карточка читается из таблицы (payers_read_self)');
select is((select count(*)::int from public.revenue_by_month), 0, 'parent: revenue_by_month пуста');
insert into t_ids select 'parent', id from public.students;
reset role;

select public.tests_claims('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select set_eq(
  $q$ select id from public.students_brief() $q$,
  array['eeeeeeee-0000-0000-0000-000000000003'::uuid],
  'parent, переключившись на центр Б: только ребёнок центра Б');
select is_empty(
  $q$ select debt_tiyin from public.student_debts() where student_id = 'eeeeeeee-0000-0000-0000-000000000002' $q$,
  'parent в центре Б: ребёнка центра А в наборе долгов нет');
reset role;


-- 64-66. parent БЕЗ payer_id в членстве — тот самый NULL ------------------------------------------

-- Первая редакция 0031 имела скалярный student_debt_tiyin(uuid) с проверкой
-- `not (can_payments() or (role = 'parent' and v_payer = my_payer_id()))`.
-- При payer_id = null сравнение даёт NULL, `not NULL` — NULL, `if NULL` не
-- срабатывает, и функция отдавала долг любого ребёнка центра по uuid.
select public.tests_claims('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.students_brief()), 0,
  'parent без payer_id: students_brief пуста');
select is((select count(*)::int from public.student_debts()), 0,
  'parent без payer_id: student_debts пуст — NULL в сравнении не открывает чужие долги');
select is((select count(*)::int from public.student_balance), 0,
  'parent без payer_id: student_balance пуст');
reset role;


-- 67-70. Без членства в центре из claims ------------------------------------------------------

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.students_brief()), 0, 'без членства: students_brief пуста');
select is((select count(*)::int from public.student_debts()), 0, 'без членства: student_debts пуст');
select is((select count(*)::int from public.revenue_facts()), 0, 'без членства: revenue_facts пуста');
select throws_ok(
  $q$ select public.month_open_lessons_count('2026-08-01') $q$,
  '42501', null, 'без членства: month_open_lessons_count — 42501');
reset role;


-- 71-77. Без auth.uid(): источники строк пусты, вью не падают -------------------------------------

-- Ровно то поведение, что было у вью до 0031 (ролевой фильтр предикатом в
-- теле): ноль строк, а не исключение. cash_by_source, чьё тело не менялось,
-- ведёт себя так же — забор 0021 это фиксирует.
select public.tests_claims(null, null);
set local role authenticated;
select is((select count(*)::int from public.students_brief()), 0, 'students_brief без auth.uid() — пусто, не 42501');
select is((select count(*)::int from public.payers_brief()), 0, 'payers_brief без auth.uid() — пусто');
select is((select count(*)::int from public.student_debts()), 0, 'student_debts без auth.uid() — пусто');
select is((select count(*)::int from public.revenue_facts()), 0, 'revenue_facts без auth.uid() — пусто');
select is((select count(*)::int from public.revenue_by_month), 0, 'revenue_by_month без auth.uid() — ноль строк, вью не падает');
select is((select count(*)::int from public.student_balance), 0, 'student_balance без auth.uid() — ноль строк, вью не падает');
select throws_ok(
  $q$ select public.month_open_lessons_count('2026-08-01') $q$,
  '42501', null, 'month_open_lessons_count без auth.uid() — 42501: «0 незакрытых» значит «можно закрывать», молчать нельзя');
reset role;


-- 78-80. Зеркало RLS: students_brief не расходится с политиками -----------------------------------

-- students_brief дублирует предикат политик students для ролей, которые её
-- читают. Забор по именам политик этого не ловит: сузят политику — функция
-- продолжит отдавать старый набор. Сравниваем множества id.
-- finance в списке нет намеренно: у него политики на students нет вовсе,
-- расхождение там и есть смысл миграции.
select set_eq(
  $q$ select id from t_ids where role_name = 'owner' $q$,
  $q$ select 'eeeeeeee-0000-0000-0000-000000000001'::uuid union all select 'eeeeeeee-0000-0000-0000-000000000002'::uuid $q$,
  'Зеркало: под owner select from students отдаёт тех же двоих, что students_brief');
select set_eq(
  $q$ select id from t_ids where role_name = 'registrar' $q$,
  $q$ select id from t_ids where role_name = 'owner' $q$,
  'Зеркало: под registrar набор id тот же, что под owner — политика и функция не разошлись');
select set_eq(
  $q$ select id from t_ids where role_name = 'parent' $q$,
  $q$ select id from t_ids where role_name = 'owner' $q$,
  'Зеркало: под parent select from students = students_brief (оба ребёнка его)');


-- 81-83. Ребёнок, помеченный удалённым, уходит отовсюду --------------------------------------------

-- deleted_at, не status: archive_student пишет status = 'archived' (0026), а
-- из выборок ребёнка убирает именно deleted_at (политики и students_brief).
update public.students set deleted_at = now() where id = 'eeeeeeee-0000-0000-0000-000000000002';

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.students_brief()), 1, 'finance: удалённый ребёнок ушёл из students_brief');
select is((select count(*)::int from public.student_debts()), 0,
  'finance: его долг ушёл из student_debts — иначе сумма висела бы там, где ребёнка уже нет');
select is((select count(*)::int from public.student_balance), 1, 'finance: и из student_balance');
reset role;


-- 84-92. Каталог: колонки, гранты, индекс, одна копия условия, итог -------------------------------

select is(
  pg_get_function_result('public.students_brief()'::regprocedure),
  'TABLE(id uuid, center_id uuid, full_name text, birth_date date, status text, payer_id uuid, primary_teacher_id uuid, created_at timestamp with time zone)',
  'students_brief: ровно эти колонки — без notes, custom_fields, source, gender');
select is(
  pg_get_function_result('public.payers_brief()'::regprocedure),
  'TABLE(id uuid, center_id uuid, full_name text, phone text, phone_alt text, email text, relation text, created_at timestamp with time zone)',
  'payers_brief: ровно эти колонки — без notes и custom_fields');
select is(
  pg_get_function_result('public.student_debts()'::regprocedure),
  'TABLE(student_id uuid, debt_tiyin integer)',
  'student_debts: набор строк, не скаляр по uuid — спросить про чужого ребёнка нечем');
select ok(
  (select bool_and(coalesce(array_to_string(c.reloptions, ','), '') like '%security_invoker=true%')
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'),
  'Все вью public остались security_invoker (для revenue_* и student_balance это теперь значит только «EXECUTE definer-источника проверяется у вызывающего»)');
select ok(
  not has_function_privilege('anon', 'public.students_brief()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.payers_brief()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.student_debts()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.revenue_facts()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.month_open_lessons_count(date)', 'EXECUTE'),
  'anon не исполняет ни одну из пяти новых функций');
select ok(
  has_function_privilege('authenticated', 'public.students_brief()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.payers_brief()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.student_debts()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.revenue_facts()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.month_open_lessons_count(date)', 'EXECUTE'),
  'authenticated исполняет все пять — иначе invoker-витрины падали бы на внутреннем вызове');
select ok(
  (select prosrc like '%month_open_lessons_count%' from pg_proc where proname = 'close_month'),
  'close_month считает открытые занятия через month_open_lessons_count — одна копия условия, не зеркало');
select is(
  (select count(*)::int from pg_indexes
    where schemaname = 'public' and indexname = 'attendance_center_deducted_idx'),
  1, 'Индекс под revenue_facts и student_debts заведён: обе не инлайнятся и читают attendance по центру');
select is(
  (select count(*)::int from public.financial_periods
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and month = '2026-08-01' and closed_at is not null),
  1, 'Август закрыт — замок лёг после отметки L4 и отмены L5');

select * from finish();

rollback;
