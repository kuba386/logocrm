-- pgTAP: тренд по цели за последние 3 занятия (0046).
--
-- Три вещи проверяются отдельно, потому что каждую можно сломать, не
-- задев другие: (1) сами правила регресс/застой/рост/stable и явный
-- приоритет между ними на пограничных триплетах; (2) что null означает
-- ТОЛЬКО «меньше 3 записей», а не «паттерн не подошёл»; (3) что trend
-- видит только персонал — родителю всегда null, даже когда у ребёнка
-- реальный регресс.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(22);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0460000-0000-0000-0000-000000000001','authenticated','authenticated','owner-trend@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0460000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-trend@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0460000-0000-0000-0000-000000000003','authenticated','authenticated','parent-trend@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0460000-0000-0000-0000-000000000004','authenticated','authenticated','registrar-trend@test.kg','','','','','','','','');

insert into public.centers (id, name, slug) values
  ('a0460000-0000-0000-0000-0000000000c1','Центр тренда','centr-trend-0046');

insert into public.teachers (id, center_id, full_name) values
  ('a0460000-0000-0000-0000-0000000000t1','a0460000-0000-0000-0000-0000000000c1','Ведущий');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('a0460000-0000-0000-0000-0000000000s1','a0460000-0000-0000-0000-0000000000c1','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('a0460000-0000-0000-0000-0000000000p1','a0460000-0000-0000-0000-0000000000c1','Родитель','+996700000602');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0460000-0000-0000-0000-000000000001','a0460000-0000-0000-0000-0000000000c1','owner',     null, null),
  ('a0460000-0000-0000-0000-000000000002','a0460000-0000-0000-0000-0000000000c1','teacher','a0460000-0000-0000-0000-0000000000t1', null),
  ('a0460000-0000-0000-0000-000000000003','a0460000-0000-0000-0000-0000000000c1','parent',    null, 'a0460000-0000-0000-0000-0000000000p1'),
  ('a0460000-0000-0000-0000-000000000004','a0460000-0000-0000-0000-0000000000c1','registrar', null, null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('a0460000-0000-0000-0000-0000000000e1','a0460000-0000-0000-0000-0000000000c1','Ребёнок','a0460000-0000-0000-0000-0000000000p1');

-- Неотменённое занятие с ведущим специалистом — без него clinical_teacher_sees
-- не пустит специалиста даже с трендом никак не связанным.
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('a0460000-0000-0000-0000-0000000000l1','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-0000000000t1','a0460000-0000-0000-0000-0000000000e1','a0460000-0000-0000-0000-0000000000s1','done','2026-09-10 10:00+00','2026-09-10 10:45+00');

-- Шесть целей — по одной на каждый сценарий правила, плюс отдельная под
-- детерминированность и отдельная под мягкое удаление.
insert into public.goals (id, center_id, student_id, stage_id, title, status) values
  ('a0460000-0000-0000-0000-00000000g001','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-0000000000e1',
   (select id from public.goal_stages where center_id = 'a0460000-0000-0000-0000-0000000000c1' order by sort limit 1),'Регресс','active'),
  ('a0460000-0000-0000-0000-00000000g002','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-0000000000e1',
   (select id from public.goal_stages where center_id = 'a0460000-0000-0000-0000-0000000000c1' order by sort limit 1),'Застой','active'),
  ('a0460000-0000-0000-0000-00000000g003','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-0000000000e1',
   (select id from public.goal_stages where center_id = 'a0460000-0000-0000-0000-0000000000c1' order by sort limit 1),'Рост','active'),
  ('a0460000-0000-0000-0000-00000000g004','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-0000000000e1',
   (select id from public.goal_stages where center_id = 'a0460000-0000-0000-0000-0000000000c1' order by sort limit 1),'Стабильно','active'),
  ('a0460000-0000-0000-0000-00000000g005','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-0000000000e1',
   (select id from public.goal_stages where center_id = 'a0460000-0000-0000-0000-0000000000c1' order by sort limit 1),'Мало данных','active'),
  ('a0460000-0000-0000-0000-00000000g006','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-0000000000e1',
   (select id from public.goal_stages where center_id = 'a0460000-0000-0000-0000-0000000000c1' order by sort limit 1),'Спорный триплет','active'),
  ('a0460000-0000-0000-0000-00000000g007','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-0000000000e1',
   (select id from public.goal_stages where center_id = 'a0460000-0000-0000-0000-0000000000c1' order by sort limit 1),'Архивная точка','active'),
  ('a0460000-0000-0000-0000-00000000g008','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-0000000000e1',
   (select id from public.goal_stages where center_id = 'a0460000-0000-0000-0000-0000000000c1' order by sort limit 1),'Детерминизм','active');

-- Регресс: 40 → 60 → 45. Последняя ниже предыдущей на 15 (>=10), хотя
-- выше самой старой на 5 — правило смотрит на s1-s2, не на s1-s3.
insert into public.goal_progress (center_id, goal_id, date, score) values
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g001','2026-09-01',40),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g001','2026-09-08',60),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g001','2026-09-15',45);

-- Застой: 50 → 52 → 51, разброс 2 (<=5).
insert into public.goal_progress (center_id, goal_id, date, score) values
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g002','2026-09-01',50),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g002','2026-09-08',52),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g002','2026-09-15',51);

-- Рост: 30 → 45 → 55. s1-s3 = 25 (>=10), не регресс и не застой.
insert into public.goal_progress (center_id, goal_id, date, score) values
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g003','2026-09-01',30),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g003','2026-09-08',45),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g003','2026-09-15',55);

-- Стабильно: 40 → 53 → 44. s1-s2 = -9 (не регресс, порог -10), разброс
-- 13 (не застой, порог 5), s1-s3 = 4 (не рост, порог 10) — ни одно
-- правило не сработало, должно быть 'stable', не null.
insert into public.goal_progress (center_id, goal_id, date, score) values
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g004','2026-09-01',40),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g004','2026-09-08',53),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g004','2026-09-15',44);

-- Мало данных: всего 2 точки.
insert into public.goal_progress (center_id, goal_id, date, score) values
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g005','2026-09-01',40),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g005','2026-09-08',50);

-- Спорный триплет: s3=0, s2=30, s1=20. Подходит и под «упала на 10
-- относительно предыдущей», и под «выросла на 20 относительно самой
-- старой» — приоритет обязан отдать regress, не growth.
insert into public.goal_progress (center_id, goal_id, date, score) values
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g006','2026-09-01',0),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g006','2026-09-08',30),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g006','2026-09-15',20);

-- Архивная точка: те же три значения, что «Регресс», но самая новая
-- точка (единственная, что делает регресс регрессом) будет мягко
-- удалена ниже — должно остаться 2 живые точки и null, а не регресс.
insert into public.goal_progress (id, center_id, goal_id, date, score) values
  ('a0460000-0000-0000-0000-0000000000pr1','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g007','2026-09-01',40),
  ('a0460000-0000-0000-0000-0000000000pr2','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g007','2026-09-08',60),
  ('a0460000-0000-0000-0000-0000000000pr3','a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g007','2026-09-15',45);

update public.goal_progress set deleted_at = now() where id = 'a0460000-0000-0000-0000-0000000000pr3';

-- Детерминизм: одна дата, один statement — created_at у обеих в одной
-- транзакции совпадает (complete_lesson, 0039, пишет так же).
insert into public.goal_progress (center_id, goal_id, date, score) values
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g008','2026-09-15',70),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g008','2026-09-15',72),
  ('a0460000-0000-0000-0000-0000000000c1','a0460000-0000-0000-0000-00000000g008','2026-09-15',71);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 1. Каталог: состав колонок и гранты --------------------------------------------------------------

select is(
  pg_get_function_result('public.student_goals_brief(uuid)'::regprocedure),
  'TABLE(id uuid, title text, area text, sound text, stage_title text, stage_sort integer, status text, target_date date, last_score integer, trend text)',
  'Состав колонок student_goals_brief после 0046 — trend восьмой, не потерялась при drop+create');

select ok(
  pg_get_function_result('public.student_goals_brief(uuid)'::regprocedure) not like '%note%',
  'note специалиста по-прежнему не в RPC');

select ok(
  not has_function_privilege('anon', 'public.student_goals_brief(uuid)', 'EXECUTE'),
  'anon не исполняет student_goals_brief — drop+create не оставил дефолтный грант Postgres');

select ok(
  not has_function_privilege('public', 'public.student_goals_brief(uuid)', 'EXECUTE'),
  'Роль PUBLIC тоже не исполняет — снят и второй слой (Postgres выдаёт PUBLIC, Supabase — anon/authenticated)');


-- 2. Правила и приоритет, от лица владельца --------------------------------------------------------

select public.tests_claims('a0460000-0000-0000-0000-000000000001','a0460000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Регресс'),
  'regress', 'Регресс: 40→60→45, падение на 15 от предыдущей');

select is(
  (select last_score from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Регресс'),
  45, 'last_score — та же самая свежая точка, что участвует в расчёте тренда');

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Застой'),
  'stagnant', 'Застой: разброс 2 в пределах порога 5');

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Рост'),
  'growth', 'Рост: 30→45→55, +25 от самой старой из трёх');

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Стабильно'),
  'stable', 'Ни один порог не сработал (−9/13/+4) — явное ''stable'', не null');

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Мало данных'),
  null, 'Меньше 3 точек — null, единственный законный случай null');

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Спорный триплет'),
  'regress', 'Триплет 0/30/20 подходит и под growth, и под regress — приоритет обязан отдать regress');

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Архивная точка'),
  null, 'Мягко удалённая самая свежая точка убрала регресс — осталось 2 живые точки, null, а не regress');

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Детерминизм'),
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Детерминизм'),
  'Два подряд вызова на записях с одинаковыми date/created_at дают одинаковый trend — третий ключ сортировки держит порядок');

select is(
  (select last_score from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Детерминизм'),
  (select last_score from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Детерминизм'),
  'И last_score детерминирован так же');

reset role;


-- 3. Видимость: специалист видит trend, если ведёт ребёнка сейчас ----------------------------------

select public.tests_claims('a0460000-0000-0000-0000-000000000002','a0460000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Регресс'),
  'regress', 'Ведущий специалист видит настоящий тренд, не null');

select is(
  (select count(*)::int from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1')),
  8, 'И видит все 8 целей ребёнка, которого ведёт');

reset role;


-- 4. Видимость: родителю всегда null, даже при настоящем регрессе ----------------------------------

select public.tests_claims('a0460000-0000-0000-0000-000000000003','a0460000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Регресс'),
  null, 'Родителю trend всегда null — даже на цели, где у персонала явный regress');

select is(
  (select trend from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Рост'),
  null, 'И на явном росте тоже null — правило не зависит от знака тренда');

select is(
  (select last_score from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1') where title = 'Регресс'),
  45, 'Но last_score родитель по-прежнему видит как раньше (0036) — сужается только новая колонка');

select is(
  (select count(*)::int from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1')),
  8, 'Сами цели родителю видны все — сужается trend, не список целей');

reset role;


-- 5. Регистратору клиника не положена ----------------------------------------------------------------

select public.tests_claims('a0460000-0000-0000-0000-000000000004','a0460000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is(
  (select count(*)::int from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1')),
  0, 'Регистратору — пустой список, ни целей, ни тренда (clinical_visible_to_caller)');

reset role;


-- 6. Чужой центр --------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values ('00000000-0000-0000-0000-000000000000','a0460000-0000-0000-0000-000000000009','authenticated','authenticated','owner-b-trend@test.kg','','','','','','','','');

insert into public.centers (id, name, slug) values
  ('a0460000-0000-0000-0000-0000000000c2','Центр Б','centr-b-trend-0046');
insert into public.memberships (user_id, center_id, role) values
  ('a0460000-0000-0000-0000-000000000009','a0460000-0000-0000-0000-0000000000c2','owner');

select public.tests_claims('a0460000-0000-0000-0000-000000000009','a0460000-0000-0000-0000-0000000000c2');
set local role authenticated;

select is(
  (select count(*)::int from public.student_goals_brief('a0460000-0000-0000-0000-0000000000e1')),
  0, 'Владелец чужого центра не видит целей и тренда чужого ребёнка');

reset role;

select * from finish();

rollback;
