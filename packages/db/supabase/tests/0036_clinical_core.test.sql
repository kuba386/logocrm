-- pgTAP: клиническое ядро — видимость по ролям (0036).
--
-- Главное здесь не таблицы, а кто что видит. Клинические данные — самый
-- чувствительный класс в проекте: деньги пересчитываются, сказанное про
-- ребёнка — нет. Поэтому каждая из шести ролей проверяется отдельно, а
-- «родитель не видит рабочий материал» — по составу колонок функции, а не
-- по значению: колонки там нет физически (ADR-005).
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() перед каждым
-- блоком явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(34);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-own-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','teacher-other-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','88888888-8888-8888-8888-888888888888','authenticated','authenticated','parent-nopayer-cl@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-clin','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ведущий специалист'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Посторонний специалист');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Родитель','+996700000001');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',    null, null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001', null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000002', null),
  ('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a','parent',   null, 'dddddddd-0000-0000-0000-000000000001'),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a','registrar',null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','finance',  null, null),
  ('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-00000000000a','parent',   null, null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Свой ребёнок','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Чужой ребёнок','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Архивный ребёнок','dddddddd-0000-0000-0000-000000000001');

-- Ведущий специалист связан с ребёнком занятием — именно так работает
-- teacher_teaches_student (0006), через состав занятия.
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('ffffffff-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','planned', now() + interval '2 hours', now() + interval '2 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-000000000001','planned', now() + interval '4 hours', now() + interval '4 hours 45 minutes');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

-- Клинические данные заводит владелец (запись специалиста — RPC в 0037).
insert into public.diagnostics (center_id, student_id, teacher_id, conclusion, sounds, speech_areas) values
  ('cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
   'ОНР III уровня', '{"р": "искажение"}'::jsonb, '{"звукопроизношение": 3}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000002', null, 'Заключение чужого', '{}'::jsonb, '{}'::jsonb);

insert into public.goals (id, center_id, student_id, stage_id, title, sound, status) values
  ('bbbb0000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001',
   (select id from public.goal_stages where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'syllables'),
   'Автоматизация [р] в слогах', 'р', 'active');

insert into public.goal_progress (center_id, goal_id, lesson_id, score, note) values
  ('cccccccc-0000-0000-0000-00000000000a','bbbb0000-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001', 60,
   'Внутренняя пометка: мать торопит, ребёнок устаёт');

insert into public.lesson_notes (center_id, lesson_id, student_id, teacher_id, raw_transcript, soap, parent_summary, status) values
  ('cccccccc-0000-0000-0000-00000000000a','ffffffff-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001', 'расшифровка голосового со словами специалиста',
   '{"plan": "закрепить слоги"}'::jsonb, 'Сегодня хорошо получались слоги.', 'approved');

insert into public.lesson_notes (center_id, lesson_id, student_id, teacher_id, parent_summary, status) values
  ('cccccccc-0000-0000-0000-00000000000a','ffffffff-0000-0000-0000-000000000003','eeeeeeee-0000-0000-0000-000000000003',
   'aaaaaaaa-0000-0000-0000-000000000001', 'Черновик, родителю показывать рано', 'draft');

insert into public.exercise_library (id, center_id, title, sound, stage_code) values
  ('dddd0000-0000-0000-0000-000000000001', null, 'Упражнение платформы', 'р', 'syllables'),
  ('dddd0000-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-00000000000a', 'Упражнение центра', 'р', 'words');

insert into public.homework (id, center_id, student_id, lesson_id, free_text) values
  ('aaaa0000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001',
   'ffffffff-0000-0000-0000-000000000001','Повторять слоги пять минут в день');

-- Архивируем ребёнка после того, как завели ему заметку: специалист не
-- должен видеть клинику архивного.
update public.students set deleted_at = now() where id = 'eeeeeeee-0000-0000-0000-000000000003';


-- 1-5. Справочник этапов ------------------------------------------------------------------------

select is(
  (select count(*)::int from public.goal_stages where center_id = 'cccccccc-0000-0000-0000-00000000000a'),
  7, 'Новому центру этапы ставит триггер: семь штук');

select is(
  (select code from public.goal_stages
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' order by sort limit 1),
  'setting', 'Первый этап — постановка: её в промте не было, а с неё начинается половина случаев');

select is(
  (select code from public.goal_stages
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' order by sort desc limit 1),
  'differentiation', 'Последний — дифференциация, а не «автоматизирован»: достижение цели это статус');

select is(
  (select count(*)::int from public.goal_stages
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'automated'),
  0, '«Автоматизирован» из этапов убран — иначе два способа сказать одно и то же разъедутся');

select ok(
  (select bool_and(sort > 0) from public.goal_stages where center_id = 'cccccccc-0000-0000-0000-00000000000a'),
  'У каждого этапа есть порядок — он нужен прогресс-бару и подсказке «следующий этап»');


-- 6-13. Ведущий специалист видит своё и только своё ------------------------------------------------

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is((select count(*)::int from public.diagnostics), 1,
  'Ведущий специалист видит диагностику своего ребёнка и не видит чужого');
select is((select count(*)::int from public.goals), 1, 'И его цели');
select is((select count(*)::int from public.goal_progress), 1, 'И прогресс');
select is((select count(*)::int from public.lesson_notes), 1,
  'И заметку — но только по живому ребёнку: у архивного её не видно');
select is((select count(*)::int from public.homework), 1, 'И домашнее задание');
select is((select count(*)::int from public.goal_stages), 7, 'Справочник этапов читают все роли центра');
select is((select count(*)::int from public.exercise_library), 2,
  'Библиотека: своё упражнение и платформенное');
select throws_ok(
  $q$ insert into public.goals (center_id, student_id, stage_id, title)
      values ('cccccccc-0000-0000-0000-00000000000a', 'eeeeeeee-0000-0000-0000-000000000001',
              (select id from public.goal_stages where code = 'words' limit 1), 'Своя цель') $q$,
  '42501', null,
  'Специалист не пишет клинику напрямую — только через RPC (Р1)');
reset role;


-- 14-16. Посторонний специалист ---------------------------------------------------------------------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.diagnostics), 0,
  'Специалист без занятий с ребёнком не видит его диагностику');
select is((select count(*)::int from public.goals), 0, 'Ни целей');
select is((select count(*)::int from public.lesson_notes), 0, 'Ни заметок');
reset role;


-- 17-24. Родитель: только то, что для него -----------------------------------------------------------

select public.tests_claims('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is((select count(*)::int from public.diagnostics), 0,
  'Родителю таблица диагностики закрыта целиком — заключение отдаёт функция');
select is((select count(*)::int from public.lesson_notes), 0,
  'И таблица заметок: там расшифровка и SOAP');
select is((select count(*)::int from public.goal_progress), 0,
  'И прогресс: там внутренние пометки специалиста');
select is((select count(*)::int from public.homework), 1,
  'А домашнее задание видно: оно для него и написано');

select is(
  (select conclusion from public.student_diagnostics_brief('eeeeeeee-0000-0000-0000-000000000001')),
  'ОНР III уровня', 'Заключение родителю доступно');
select is(
  (select count(*)::int from public.student_notes_brief('eeeeeeee-0000-0000-0000-000000000001')), 1,
  'Утверждённое резюме занятия — доступно');
select is(
  (select count(*)::int from public.student_goals_brief('eeeeeeee-0000-0000-0000-000000000001')), 1,
  'Цели ребёнка — доступны');
select is(
  (select last_score from public.student_goals_brief('eeeeeeee-0000-0000-0000-000000000001')), 60,
  'Вместе с последней оценкой — но без пометки к ней');
reset role;


-- 25-28. Чего родитель не увидит ни при каких условиях ------------------------------------------------

select is(
  pg_get_function_result('public.student_diagnostics_brief(uuid)'::regprocedure),
  'TABLE(id uuid, date date, conclusion text, teacher_name text)',
  'В диагностике для родителя нет колонок sounds и speech_areas — физически');

select is(
  pg_get_function_result('public.student_notes_brief(uuid)'::regprocedure),
  'TABLE(id uuid, lesson_id uuid, lesson_at timestamp with time zone, parent_summary text)',
  'В резюме занятий нет raw_transcript и soap — физически');

select ok(
  pg_get_function_result('public.student_goals_brief(uuid)'::regprocedure) not like '%note%',
  'В целях для родителя нет пометки специалиста');

select public.tests_claims('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.student_goals_brief('eeeeeeee-0000-0000-0000-000000000001')), 0,
  'Родитель без плательщика в членстве не видит ничего — NULL в связке не открывает чужого ребёнка');
reset role;


-- 29-31. Стойке и бухгалтеру клиника не положена -------------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostics) + (select count(*)::int from public.goals)
  + (select count(*)::int from public.goal_progress) + (select count(*)::int from public.lesson_notes),
  0, 'Регистратор не видит ни одной клинической строки');
reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostics) + (select count(*)::int from public.goals)
  + (select count(*)::int from public.goal_progress) + (select count(*)::int from public.lesson_notes),
  0, 'Бухгалтер тоже: 0031 закрыл ему заметки о семье, клиника тем более');
select is(
  (select count(*)::int from public.student_goals_brief('eeeeeeee-0000-0000-0000-000000000001')), 0,
  'И через узкую функцию ничего не получает');
reset role;


-- 32-34. Упражнения в задании --------------------------------------------------------------------------

select public.tests_claims(null, null);

select lives_ok(
  $q$ insert into public.homework_exercises (homework_id, exercise_id, center_id)
      values ('aaaa0000-0000-0000-0000-000000000001', 'dddd0000-0000-0000-0000-000000000001',
              'cccccccc-0000-0000-0000-00000000000a') $q$,
  'Упражнение платформы добавляется в ДЗ — составной FK это бы запретил (Р7)');

select lives_ok(
  $q$ insert into public.homework_exercises (homework_id, exercise_id, center_id)
      values ('aaaa0000-0000-0000-0000-000000000001', 'dddd0000-0000-0000-0000-000000000002',
              'cccccccc-0000-0000-0000-00000000000a') $q$,
  'И упражнение своего центра');

-- Упражнение другого центра: заводим его напрямую и пробуем привязать.
insert into public.centers (id, name, slug) values
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-clin');
insert into public.exercise_library (id, center_id, title) values
  ('dddd0000-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000b','Упражнение чужого центра');

select throws_ok(
  $q$ insert into public.homework_exercises (homework_id, exercise_id, center_id)
      values ('aaaa0000-0000-0000-0000-000000000001', 'dddd0000-0000-0000-0000-000000000003',
              'cccccccc-0000-0000-0000-00000000000a') $q$,
  '42704', null,
  'Упражнение чужого центра отбивается триггером, а не проверкой в функции');

select * from finish();

rollback;
