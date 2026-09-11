-- pgTAP: роли registrar/finance, шаг 2 — RPC денег сотрудников и периодов
-- (0027), плюс граница дня по поясу центра в cancel_series_from /
-- teacher_vacation / teacher_vacation_preview.
-- Членства с новыми ролями — от postgres (лестница до 0028). Пояс сессии
-- принудительно UTC: только так виден дефект «граница в поясе сессии».
-- Занятия Р3 — октябрь 2027: далеко от скользящего окна close_month (m2 =
-- позапрошлый месяц от сегодня); ассерт на это есть, чтобы перенос дат не
-- наступил на те же грабли (fix/0010-freeze-test-timezone-flake).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
set local time zone 'UTC';

select plan(53);

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
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','admin-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','nobody@test.kg','','','','','','','','');

-- Asia/Bishkek — +06, без перевода: 02:00 местного = 20:00 UTC накануне.
insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-fin','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист А'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Специалист Б');

insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner', null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a','registrar', null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','finance', null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001'),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','admin', null);

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик А','+996700000001');
insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок 1','dddddddd-0000-0000-0000-000000000001');

-- Занятия на краях и в середине шестичасовой зоны, где пояс сессии (UTC)
-- и пояс центра (+06) дают разные дни:
--   L4 05.10 00:00, L1 05.10 02:00, L5 05.10 23:15 — день p_from/p_to целиком;
--   L6 06.10 00:00 — первая секунда дня p_to + 1; L2 06.10 02:00 — серия;
--   L3 07.10 02:00 — в поясе сессии попало бы в «5–6 октября».
insert into public.lessons (id, center_id, teacher_id, student_id, starts_at, ends_at, series_id) values
  ('ffffffff-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2027-10-05 00:00+06','2027-10-05 00:45+06', null),
  ('ffffffff-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2027-10-05 02:00+06','2027-10-05 02:45+06', null),
  ('ffffffff-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2027-10-05 23:15+06','2027-10-05 23:59+06', null),
  ('ffffffff-0000-0000-0000-000000000006','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2027-10-06 00:00+06','2027-10-06 00:45+06', null),
  ('ffffffff-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2027-10-06 02:00+06','2027-10-06 02:45+06', '99990000-0000-0000-0000-000000000001'),
  ('ffffffff-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2027-10-07 02:00+06','2027-10-07 02:45+06', null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_src as
  select id from public.payment_sources
   where center_id = 'cccccccc-0000-0000-0000-00000000000a' order by sort, code limit 1;
create temporary table t_cat as
  select id from public.expense_categories
   where center_id = 'cccccccc-0000-0000-0000-00000000000a' order by sort, code limit 1;
create temporary table t_month as
  select (date_trunc('month', public.center_today('cccccccc-0000-0000-0000-00000000000a')) - interval '1 month')::date as m1,
         (date_trunc('month', public.center_today('cccccccc-0000-0000-0000-00000000000a')) - interval '2 months')::date as m2;
grant select on t_src, t_cat, t_month to authenticated;

select ok(
  (select m1 from t_month) <> date '2027-10-01' and (select m2 from t_month) <> date '2027-10-01'
  and (select m2 from t_month) < date '2027-10-01',
  'Фикстура Р3 (октябрь 2027) вне скользящего окна close_month — при переносе дат сверить заново'
);


-- 2-13. finance: расходы, справочники, периоды, зарплата ---------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select lives_ok(
  $q$ select public.record_expense((select id from t_cat), 150000, 'expense', (select id from t_src)) $q$,
  'record_expense — finance');
select lives_ok(
  $q$ select public.archive_expense_category((select id from t_cat)) $q$,
  'archive_expense_category — finance');
select lives_ok(
  $q$ select public.restore_expense_category((select id from t_cat)) $q$,
  'restore_expense_category — finance');
select lives_ok(
  $q$ select public.archive_payment_source((select id from t_src)) $q$,
  'archive_payment_source — finance');
select lives_ok(
  $q$ select public.restore_payment_source((select id from t_src)) $q$,
  'restore_payment_source — finance');
select lives_ok(
  $q$ select public.close_month((select m2 from t_month)) $q$,
  'close_month — finance');
select throws_ok(
  $q$ select public.reopen_month((select m2 from t_month)) $q$,
  '42501', null, 'reopen_month — только owner, finance нет');
select lives_ok(
  $q$ select public.record_salary_adjustment('aaaaaaaa-0000-0000-0000-000000000001', (select m1 from t_month), 20000, 'бонус') $q$,
  'record_salary_adjustment — finance');
select is(
  (select count(*)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000001', (select m1 from t_month))),
  0, 'calc_salary — finance (ветка owner/admin; занятий нет — ноль строк)');
select is(
  (select array_agg(teacher_id order by teacher_id) from public.salary_summary((select m1 from t_month))),
  array['aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002']::uuid[],
  'salary_summary — finance видит обоих специалистов (фильтр scope тоже перевыпущен)');
select is(
  (select adjustments_tiyin from public.salary_summary((select m1 from t_month))
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  20000, 'salary_summary — корректировка finance в итоге');
select lives_ok(
  $q$ select public.approve_salary('aaaaaaaa-0000-0000-0000-000000000001', (select m1 from t_month)) $q$,
  'approve_salary — finance');
select throws_ok(
  $q$ select public.archive_teacher('aaaaaaaa-0000-0000-0000-000000000001') $q$,
  '42501', null, 'archive_teacher — персонал не бухгалтеру');

reset role;


-- 14-20. admin: как owner (предикат перечисляет его литералом — страховка от сужения) ------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.record_expense((select id from t_cat), 1000, 'expense', (select id from t_src)) $q$,
  'record_expense — admin');
select lives_ok(
  $q$ select public.archive_expense_category((select id from t_cat)) $q$,
  'archive_expense_category — admin');
select lives_ok(
  $q$ select public.restore_expense_category((select id from t_cat)) $q$,
  'restore_expense_category — admin');
select lives_ok(
  $q$ select * from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000002', (select m1 from t_month)) $q$,
  'calc_salary — admin');
select lives_ok(
  $q$ select public.record_salary_adjustment('aaaaaaaa-0000-0000-0000-000000000002', (select m1 from t_month), 5000, 'бонус') $q$,
  'record_salary_adjustment — admin');
select lives_ok(
  $q$ select public.approve_salary('aaaaaaaa-0000-0000-0000-000000000002', (select m1 from t_month)) $q$,
  'approve_salary — admin');
select throws_ok(
  $q$ select public.reopen_month((select m2 from t_month)) $q$,
  '42501', null, 'reopen_month — admin нет, только owner');
reset role;


-- 21-27. registrar: ничего из денег сотрудников -------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.record_expense((select id from t_cat), 1000, 'expense', (select id from t_src)) $q$,
  '42501', null, 'record_expense — registrar нет');
select throws_ok(
  $q$ select public.archive_expense_category((select id from t_cat)) $q$,
  '42501', null, 'archive_expense_category — registrar нет');
select throws_ok(
  $q$ select public.archive_payment_source((select id from t_src)) $q$,
  '42501', null, 'archive_payment_source — registrar нет');
select throws_ok(
  $q$ select public.close_month((select m1 from t_month)) $q$,
  '42501', null, 'close_month — registrar нет');
select throws_ok(
  $q$ select public.record_salary_adjustment('aaaaaaaa-0000-0000-0000-000000000001', (select m1 from t_month), 1, 'x') $q$,
  '42501', null, 'record_salary_adjustment — registrar нет');
select throws_ok(
  $q$ select * from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000001', (select m1 from t_month)) $q$,
  '42501', null, 'calc_salary — registrar нет');
select throws_ok(
  $q$ select * from public.salary_summary((select m1 from t_month)) $q$,
  '42501', null, 'salary_summary — registrar нет');

reset role;


-- 28-31. teacher и NULL-роль: как раньше -----------------------------------------------------

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select array_agg(teacher_id) from public.salary_summary((select m1 from t_month))),
  array['aaaaaaaa-0000-0000-0000-000000000001']::uuid[],
  'salary_summary — teacher видит только свою строку из двух специалистов');
select lives_ok(
  $q$ select * from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000001', (select m1 from t_month)) $q$,
  'calc_salary своих строк — teacher по-прежнему может');
reset role;

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select * from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000001', (select m1 from t_month)) $q$,
  '42501', null, 'calc_salary без членства — отказ');
select throws_ok(
  $q$ select public.record_expense((select id from t_cat), 1000, 'expense', (select id from t_src)) $q$,
  '42501', null, 'record_expense без членства — отказ');
reset role;


-- 32-33. owner: reopen и повторное закрытие --------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.reopen_month((select m2 from t_month)) $q$,
  'reopen_month — owner');
select lives_ok(
  $q$ select public.close_month((select m2 from t_month)) $q$,
  'close_month повторно после reopen — owner');
reset role;


-- 34-49. Р3: граница дня — по поясу центра, края и середина зоны -----------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

create temporary table t_preview as
  select lesson_id from public.teacher_vacation_preview('aaaaaaaa-0000-0000-0000-000000000001', '2027-10-05', '2027-10-05');

select set_eq(
  $$ select lesson_id from t_preview $$,
  $$ values ('ffffffff-0000-0000-0000-000000000004'::uuid), ('ffffffff-0000-0000-0000-000000000001'::uuid), ('ffffffff-0000-0000-0000-000000000005'::uuid) $$,
  'preview «5 октября»: 00:00, 02:00 и 23:15 местного — все три (в поясе сессии — только 23:15)');
select ok(
  not exists (select 1 from t_preview where lesson_id = 'ffffffff-0000-0000-0000-000000000006'),
  'preview «5 октября»: 00:00 6 октября — первая секунда следующего дня — не входит');
select is(
  (select count(*)::int from public.teacher_vacation_preview('aaaaaaaa-0000-0000-0000-000000000001', '2027-10-05', '2027-10-06')),
  5, 'preview «5–6 октября»: пять, 02:00 7 октября не входит (в поясе сессии входило бы)');
select is(
  public.teacher_vacation('aaaaaaaa-0000-0000-0000-000000000001', '2027-10-05', '2027-10-05'),
  3, 'teacher_vacation «5 октября»: отменено ровно три — по поясу центра');
select is(
  public.cancel_series_from('99990000-0000-0000-0000-000000000001', '2027-10-06'),
  1, 'cancel_series_from: занятие серии в 02:00 местного 6 октября попадает в «с 6 октября»');

reset role;

select set_eq(
  $$ select id from public.lessons where cancel_reason = 'vacation' $$,
  $$ select lesson_id from t_preview $$,
  'Отпуск отменил ровно тот набор, что показывал предпросмотр — две границы (preview и vacation) не разошлись');
select is(
  (select status from public.lessons where id = 'ffffffff-0000-0000-0000-000000000004'), 'cancelled',
  'L4 (5 окт, 00:00 — первая секунда p_from) отменено');
select is(
  (select status from public.lessons where id = 'ffffffff-0000-0000-0000-000000000005'), 'cancelled',
  'L5 (5 окт, 23:15 — конец p_to) отменено');
select is(
  (select status from public.lessons where id = 'ffffffff-0000-0000-0000-000000000006'), 'planned',
  'L6 (6 окт, 00:00 — первая секунда p_to + 1) не тронуто');
select is(
  (select status from public.lessons where id = 'ffffffff-0000-0000-0000-000000000002'), 'cancelled',
  'L2 (6 окт, серия) отменено cancel_series_from');
select is(
  (select status from public.lessons where id = 'ffffffff-0000-0000-0000-000000000003'), 'planned',
  'L3 (7 окт, 02:00) не тронуто');
select ok(
  (select prosrc like '%center_timezone%' from pg_proc where proname = 'cancel_series_from'),
  'cancel_series_from считает границу через center_timezone — правка не откатится молча');
select ok(
  (select prosrc like '%center_timezone%' from pg_proc where proname = 'teacher_vacation'),
  '…teacher_vacation тоже');
select ok(
  (select prosrc like '%center_timezone%' from pg_proc where proname = 'teacher_vacation_preview'),
  '…и teacher_vacation_preview');
select ok(
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.prosrc like '%p_from::timestamptz%'),
  'Приведения p_from::timestamptz (пояс сессии) в public больше нет ни у кого');
select is(
  (select count(*)::int from public.events where type = 'lesson.cancelled'), 1,
  'Одно lesson.cancelled — от cancel_series_from; отпуск пишет teacher.vacation');


-- 50-52. Гранты и снимки ------------------------------------------------------------------------

select ok(
  has_function_privilege('authenticated', 'public.close_month(date)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.salary_summary(date)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.teacher_vacation(uuid,date,date)', 'EXECUTE'),
  'Перевыпущенные функции исполняет authenticated'
);
select ok(
  not has_function_privilege('anon', 'public.close_month(date)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.calc_salary(uuid,date)', 'EXECUTE'),
  'anon — нет'
);
select is(
  (select count(*)::int from public.salary_runs), 2,
  'Два снимка зарплаты: от finance и от admin, по одному на специалиста'
);

select * from finish();

rollback;
