-- pgTAP: клиническое ядро — точечные RPC записи (0038).
--
-- 0036 доказал видимость (кто что читает). Здесь — запись: каждый RPC,
-- адресующий строку по id, должен сам отбить чужой центр и чужую роль,
-- а не полагаться на то, что параметр пришёл честный. Отдельная фикстура,
-- а не фикстура 0036: подсчёт событий должен быть точным, а не «плюс то,
-- что уже эмитила фикстура соседнего файла».

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(56);


create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','21111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-w@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','24444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-with-w@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','25555555-5555-5555-5555-555555555555','authenticated','authenticated','teacher-without-w@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','27777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-w@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-w@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','29999999-9999-9999-9999-999999999999','authenticated','authenticated','owner-b-w@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('2ccccccc-0000-0000-0000-00000000000a','Центр А (запись)','centr-a-write','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('2ccccccc-0000-0000-0000-00000000000b','Центр Б (запись)','centr-b-write','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('2aaaaaaa-0000-0000-0000-000000000001','2ccccccc-0000-0000-0000-00000000000a','Ведущий специалист'),
  ('2aaaaaaa-0000-0000-0000-000000000002','2ccccccc-0000-0000-0000-00000000000a','Другой специалист');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('2bbbbbbb-0000-0000-0000-000000000001','2ccccccc-0000-0000-0000-00000000000a','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('2ddddddd-0000-0000-0000-000000000001','2ccccccc-0000-0000-0000-00000000000a','Родитель','+996700000101');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('21111111-1111-1111-1111-111111111111','2ccccccc-0000-0000-0000-00000000000a','owner',    null, null),
  ('24444444-4444-4444-4444-444444444444','2ccccccc-0000-0000-0000-00000000000a','teacher','2aaaaaaa-0000-0000-0000-000000000001', null),
  ('25555555-5555-5555-5555-555555555555','2ccccccc-0000-0000-0000-00000000000a','teacher','2aaaaaaa-0000-0000-0000-000000000002', null),
  ('27777777-7777-7777-7777-777777777777','2ccccccc-0000-0000-0000-00000000000a','parent',   null, '2ddddddd-0000-0000-0000-000000000001'),
  ('22222222-2222-2222-2222-222222222222','2ccccccc-0000-0000-0000-00000000000a','registrar',null, null),
  ('29999999-9999-9999-9999-999999999999','2ccccccc-0000-0000-0000-00000000000b','owner',    null, null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('2eeeeeee-0000-0000-0000-000000000001','2ccccccc-0000-0000-0000-00000000000a','Ребёнок','2ddddddd-0000-0000-0000-000000000001'),
  ('2eeeeeee-0000-0000-0000-000000000002','2ccccccc-0000-0000-0000-00000000000a','Ребёнок с отменённым занятием','2ddddddd-0000-0000-0000-000000000001'),
  ('2eeeeeee-0000-0000-0000-000000000003','2ccccccc-0000-0000-0000-00000000000b','Ребёнок центра Б', null);

insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('2fffffff-0000-0000-0000-000000000001','2ccccccc-0000-0000-0000-00000000000a','2aaaaaaa-0000-0000-0000-000000000001','2eeeeeee-0000-0000-0000-000000000001','2bbbbbbb-0000-0000-0000-000000000001','planned',   now() + interval '1 hour', now() + interval '1 hour 45 minutes'),
  ('2fffffff-0000-0000-0000-000000000002','2ccccccc-0000-0000-0000-00000000000a','2aaaaaaa-0000-0000-0000-000000000001','2eeeeeee-0000-0000-0000-000000000002','2bbbbbbb-0000-0000-0000-000000000001','cancelled', now() + interval '2 hour', now() + interval '2 hour 45 minutes');

select public.tests_claims('21111111-1111-1111-1111-111111111111','2ccccccc-0000-0000-0000-00000000000a');

insert into public.goals (id, center_id, student_id, stage_id, title, status) values
  ('2bbbb000-0000-0000-0000-000000000001','2ccccccc-0000-0000-0000-00000000000a','2eeeeeee-0000-0000-0000-000000000001',
   (select id from public.goal_stages where center_id = '2ccccccc-0000-0000-0000-00000000000a' and code = 'setting'),
   'Постановка [р]', 'active'),
  ('2bbbb000-0000-0000-0000-000000000002','2ccccccc-0000-0000-0000-00000000000b','2eeeeeee-0000-0000-0000-000000000003',
   (select id from public.goal_stages where center_id = '2ccccccc-0000-0000-0000-00000000000b' and code = 'setting'),
   'Цель центра Б', 'active');

insert into public.diagnostics (id, center_id, student_id, conclusion) values
  ('2d000000-0000-0000-0000-000000000001','2ccccccc-0000-0000-0000-00000000000a','2eeeeeee-0000-0000-0000-000000000001','Черновой диагноз'),
  ('2d000000-0000-0000-0000-000000000002','2ccccccc-0000-0000-0000-00000000000b','2eeeeeee-0000-0000-0000-000000000003','Диагноз центра Б');

insert into public.goal_progress (id, center_id, goal_id, score, created_by) values
  ('2p000000-0000-0000-0000-000000000001','2ccccccc-0000-0000-0000-00000000000a','2bbbb000-0000-0000-0000-000000000001', 50, '21111111-1111-1111-1111-111111111111');

insert into public.exercise_library (id, center_id, title) values
  ('2ex00000-0000-0000-0000-000000000001', null, 'Упражнение платформы'),
  ('2ex00000-0000-0000-0000-000000000002', '2ccccccc-0000-0000-0000-00000000000a', 'Упражнение центра А'),
  ('2ex00000-0000-0000-0000-000000000003', '2ccccccc-0000-0000-0000-00000000000b', 'Упражнение центра Б');

insert into public.homework (id, center_id, student_id, free_text) values
  ('2h000000-0000-0000-0000-000000000001','2ccccccc-0000-0000-0000-00000000000a','2eeeeeee-0000-0000-0000-000000000001','Существующее задание'),
  ('2h000000-0000-0000-0000-000000000002','2ccccccc-0000-0000-0000-00000000000b','2eeeeeee-0000-0000-0000-000000000003','Задание центра Б');

-- created_by — сам ведущий специалист, а не владелец (клеймы фикстуры на
-- этот момент): иначе «автор правит черновик» ниже доказывал бы то же,
-- что уже доказано у update_goal, но на чужих данных.
insert into public.lesson_notes (id, center_id, lesson_id, student_id, status, created_by) values
  ('2n000000-0000-0000-0000-000000000001','2ccccccc-0000-0000-0000-00000000000a','2fffffff-0000-0000-0000-000000000001','2eeeeeee-0000-0000-0000-000000000001','draft','24444444-4444-4444-4444-444444444444');


-- 1. Прямая запись во все шесть таблиц закрыта (Р9) --------------------------------------------

set local role authenticated;

select throws_ok(
  $q$ insert into public.diagnostics (center_id, student_id, conclusion)
      values ('2ccccccc-0000-0000-0000-00000000000a','2eeeeeee-0000-0000-0000-000000000001','x') $q$,
  '42501', null, 'diagnostics: прямой insert закрыт даже владельцу');
select throws_ok(
  $q$ update public.diagnostics set conclusion = 'x' where id = '2d000000-0000-0000-0000-000000000001' $q$,
  '42501', null, 'diagnostics: прямой update закрыт');
select throws_ok(
  $q$ insert into public.goals (center_id, student_id, stage_id, title)
      values ('2ccccccc-0000-0000-0000-00000000000a','2eeeeeee-0000-0000-0000-000000000001',
              (select id from public.goal_stages where code = 'setting' limit 1), 'x') $q$,
  '42501', null, 'goals: прямой insert закрыт');
select throws_ok(
  $q$ update public.goal_progress set score = 10 where id = '2p000000-0000-0000-0000-000000000001' $q$,
  '42501', null, 'goal_progress: прямой update закрыт');
select throws_ok(
  $q$ update public.homework set free_text = 'x' where id = '2h000000-0000-0000-0000-000000000001' $q$,
  '42501', null, 'homework: прямой update закрыт');
select throws_ok(
  $q$ insert into public.homework_exercises (homework_id, exercise_id)
      values ('2h000000-0000-0000-0000-000000000001','2ex00000-0000-0000-0000-000000000001') $q$,
  '42501', null, 'homework_exercises: прямой insert закрыт');
select throws_ok(
  $q$ update public.lesson_notes set parent_summary = 'x' where id = '2n000000-0000-0000-0000-000000000001' $q$,
  '42501', null, 'lesson_notes: прямой update закрыт');
select is((select count(*)::int from public.diagnostics), 1,
  'select при этом жив: политика видимости не пострадала');

reset role;


-- 2. Диагностика: видимость записи = видимости чтения (Р5, без изменений) -----------------------

select public.tests_claims('24444444-4444-4444-4444-444444444444','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select isnt(
  (select public.record_diagnostic('2eeeeeee-0000-0000-0000-000000000001', 'ОНР II уровня')),
  null, 'Ведущий специалист (живое занятие) заводит диагностику');

-- Р10 доказывается тем же специалистом, который в этой отменённой записи
-- значится teacher_id: иначе отказ объяснялся бы просто отсутствием какой
-- бы то ни было связи с ребёнком, а не тем, что отменённое занятие в счёт
-- не идёт.
select throws_ok(
  $q$ select public.record_diagnostic('2eeeeeee-0000-0000-0000-000000000002', 'через отменённое') $q$,
  '42501', null,
  'Отменённое занятие доступа на запись не даёт даже своему учителю — то же правило, что и на чтение (Р10)');
reset role;

-- events читает только owner/admin (0001) — вне блока authenticated, от
-- postgres, иначе подсчёт молча обнулился бы политикой, а не багом кода.
select is(
  (select count(*)::int from public.events where type = 'diagnostic.created'), 1,
  'Событие diagnostic.created ровно одно');

select public.tests_claims('25555555-5555-5555-5555-555555555555','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.record_diagnostic('2eeeeeee-0000-0000-0000-000000000001', 'без занятия') $q$,
  '42501', null, 'Специалист без какой-либо связи с этим ребёнком — отказ');
reset role;

select public.tests_claims('22222222-2222-2222-2222-222222222222','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.record_diagnostic('2eeeeeee-0000-0000-0000-000000000001', 'регистратору нельзя') $q$,
  '42501', null, 'Регистратору клиника не положена вообще');
reset role;

select public.tests_claims('21111111-1111-1111-1111-111111111111','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.update_diagnostic('2d000000-0000-0000-0000-000000000002', 'чужой центр') $q$,
  '42704', null, 'update_diagnostic по чужому центру — не найдена, а не «нет прав» (id не палит существование)');
reset role;


-- 3. Цели: create/update без status, set_goal_status — отдельно (Р3) ----------------------------

select public.tests_claims('24444444-4444-4444-4444-444444444444','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select isnt(
  (select public.create_goal('2eeeeeee-0000-0000-0000-000000000001',
     (select id from public.goal_stages where center_id = '2ccccccc-0000-0000-0000-00000000000a' and code = 'setting'),
     'Новая цель')),
  null, 'Специалист заводит цель своему ребёнку');

select throws_ok(
  $q$ select public.create_goal('2eeeeeee-0000-0000-0000-000000000001', gen_random_uuid(), 'плохой этап') $q$,
  '42704', null, 'Несуществующий этап — понятная ошибка, а не голый FK');

-- Автор — сам специалист (эту цель он только что завёл), не фикстура:
-- иначе «автор правит» и «не автор не правит» ниже доказывали бы одно и
-- то же на чужих данных.
select lives_ok(
  $q$ select public.update_goal(
        (select id from public.goals where title = 'Новая цель' and created_by = '24444444-4444-4444-4444-444444444444'),
        'Переименовали') $q$,
  'Автор цели правит её (Р2)');
select is(
  (select status from public.goals where title = 'Переименовали'), 'active',
  'update_goal не трогает статус ни при каких параметрах — его нет в сигнатуре');

select lives_ok(
  $q$ select public.set_goal_status('2bbbb000-0000-0000-0000-000000000001', 'achieved') $q$,
  'Достижение цели — отдельное действие, доступное любому специалисту, ведущему ребёнка сейчас (не только автору)');
select ok(
  (select achieved_at is not null from public.goals where id = '2bbbb000-0000-0000-0000-000000000001'),
  'Метку достижения по-прежнему ставит триггер 0036, а не RPC');

reset role;

-- events читает только owner/admin — вне блока authenticated.
select is(
  (select count(*)::int from public.events where type = 'goal.achieved'), 1,
  'Событие goal.achieved ровно одно — эмитит триггер, а не RPC (Р4)');

select public.tests_claims('25555555-5555-5555-5555-555555555555','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.update_goal('2bbbb000-0000-0000-0000-000000000001', 'Чужая правка') $q$,
  '42501', null, 'Не автор (цель фикстуры — от владельца) и не owner/admin — отказ, даже если ребёнка видит (Р2)');
reset role;

select public.tests_claims('21111111-1111-1111-1111-111111111111','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.update_goal('2bbbb000-0000-0000-0000-000000000002', 'чужой центр') $q$,
  '42704', null, 'update_goal по цели чужого центра — не найдена');
reset role;


-- 4. Прогресс по цели: идемпотентность conduct_key -----------------------------------------------

select public.tests_claims('24444444-4444-4444-4444-444444444444','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select public.record_goal_progress('2bbbb000-0000-0000-0000-000000000001', 70, null, null, null,
     '33333333-0000-0000-0000-000000000001')),
  (select public.record_goal_progress('2bbbb000-0000-0000-0000-000000000001', 70, null, null, null,
     '33333333-0000-0000-0000-000000000001')),
  'Повтор с тем же conduct_key возвращает тот же id, а не вторую точку на графике');
select is(
  (select count(*)::int from public.goal_progress
    where goal_id = '2bbbb000-0000-0000-0000-000000000001' and conduct_key = '33333333-0000-0000-0000-000000000001'),
  1, 'И в базе строка ровно одна');

reset role;

select public.tests_claims('25555555-5555-5555-5555-555555555555','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.update_goal_progress('2p000000-0000-0000-0000-000000000001', 99) $q$,
  '42501', null, 'update_goal_progress: не автор — отказ');
reset role;

-- archive_goal — последнее использование этой цели в файле: правки и
-- прогресс по ней проверены выше, дальше она никому не нужна живой.
select public.tests_claims('21111111-1111-1111-1111-111111111111','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.archive_goal('2bbbb000-0000-0000-0000-000000000001') $q$,
  'archive_goal владельцу доступен');
reset role;


-- 5. Домашнее задание: дедуп, атомарный откат, идемпотентность, переходы статуса -----------------

select public.tests_claims('21111111-1111-1111-1111-111111111111','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.homework_exercises he
    join public.assign_homework('2eeeeeee-0000-0000-0000-000000000001', 'Дубли', array[
      '2ex00000-0000-0000-0000-000000000001','2ex00000-0000-0000-0000-000000000001',
      '2ex00000-0000-0000-0000-000000000002']::uuid[]) as hw(id) on he.homework_id = hw.id),
  2, 'Повтор exercise_id в списке схлопывается в одну строку (Р7)');

select throws_ok(
  $q$ select public.assign_homework('2eeeeeee-0000-0000-0000-000000000001', 'чужой центр', array[
      '2ex00000-0000-0000-0000-000000000001','2ex00000-0000-0000-0000-000000000003']::uuid[]) $q$,
  '42704', null, 'Упражнение чужого центра где угодно в списке — вся вставка падает');
select is(
  (select count(*)::int from public.homework where student_id = '2eeeeeee-0000-0000-0000-000000000001'
    and free_text = 'чужой центр'),
  0, 'И само задание из упавшей вставки не остаётся сиротой без состава');

select is(
  (select public.assign_homework('2eeeeeee-0000-0000-0000-000000000001', 'повтор', '{}'::uuid[], null, null,
     '44444444-0000-0000-0000-000000000001')),
  (select public.assign_homework('2eeeeeee-0000-0000-0000-000000000001', 'повтор', '{}'::uuid[], null, null,
     '44444444-0000-0000-0000-000000000001')),
  'Повтор с тем же conduct_key — то же задание, а не второе');

select lives_ok(
  $q$ select public.update_homework('2h000000-0000-0000-0000-000000000001', null, 'Поправили состав',
        array['2ex00000-0000-0000-0000-000000000002']::uuid[]) $q$,
  'Замена состава ДЗ живёт, пока задание не увидел родитель');

reset role;

select public.tests_claims('27777777-7777-7777-7777-777777777777','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.submit_homework('2h000000-0000-0000-0000-000000000001', 'Сделали') $q$,
  'Родитель сдаёт своё задание');
select throws_ok(
  $q$ select public.submit_homework('2h000000-0000-0000-0000-000000000001', 'ещё раз') $q$,
  '23514', null, 'Повторная сдача уже сданного — явная ошибка, а не тихий перезаход');
reset role;

select is((select count(*)::int from public.events where type = 'homework.submitted'), 1,
  'Событие homework.submitted ровно одно — эмитит триггер (Р4)');

select public.tests_claims('24444444-4444-4444-4444-444444444444','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
-- Право на update_homework у специалиста есть (Р2), но статус уже не
-- «выдано» — тот же забор, что видел родитель выше, но теперь у того,
-- у кого прав достаточно, иначе непонятно, какая из двух причин отказа
-- сработала.
select throws_ok(
  $q$ select public.update_homework('2h000000-0000-0000-0000-000000000001', null, 'поздно') $q$,
  '23514', null, 'Состав уже увиденного родителем задания не меняется');
select throws_ok(
  $q$ select public.review_homework('2p000000-0000-0000-0000-000000000001', 'не то ДЗ') $q$,
  '42704', null, 'review_homework по несуществующему в этой таблице id — не найдено');
select lives_ok(
  $q$ select public.review_homework('2h000000-0000-0000-0000-000000000001', 'Молодец') $q$,
  'Специалист проверяет сданное задание');
reset role;

select public.tests_claims('22222222-2222-2222-2222-222222222222','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.assign_homework('2eeeeeee-0000-0000-0000-000000000001', 'регистратору нельзя') $q$,
  '42501', null, 'Регистратор не выдаёт домашние задания');
reset role;


-- 6. Заметка занятия: create=update по ключу, утверждённое неприкосновенно, событие один раз -----

select public.tests_claims('24444444-4444-4444-4444-444444444444','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select public.write_lesson_note('2fffffff-0000-0000-0000-000000000001', '2eeeeeee-0000-0000-0000-000000000001',
     '{"plan":"a"}'::jsonb)),
  '2n000000-0000-0000-0000-000000000001'::uuid,
  'write_lesson_note на существующий (lesson_id, student_id) правит ту же строку, а не заводит вторую');

select is(
  (select count(*)::int from public.lesson_notes
    where lesson_id = '2fffffff-0000-0000-0000-000000000001' and student_id = '2eeeeeee-0000-0000-0000-000000000001'),
  1, 'Строка по-прежнему одна');

select lives_ok(
  $q$ select public.approve_lesson_note('2n000000-0000-0000-0000-000000000001') $q$,
  'Утверждение заметки');
select lives_ok(
  $q$ select public.approve_lesson_note('2n000000-0000-0000-0000-000000000001') $q$,
  'Повторное утверждение — холостой ход, а не ошибка');

select throws_ok(
  $q$ select public.write_lesson_note('2fffffff-0000-0000-0000-000000000001', '2eeeeeee-0000-0000-0000-000000000001',
        '{"plan":"переписали задним числом"}'::jsonb) $q$,
  '23514', null, 'Утверждённую заметку не изменить через RPC — предпроверка');

reset role;

-- events читает только owner/admin — вне блока authenticated.
select is(
  (select count(*)::int from public.events where type = 'lesson.note_approved'), 1,
  'Но событие ровно одно — повторное утверждение не эмитит второе (Р4)');

-- Второй рубеж — триггер, а не только предпроверка функции: от имени
-- postgres, в обход RPC, тем же приёмом, что 0036 доказывает approved→draft.
select throws_ok(
  $q$ update public.lesson_notes set soap = '{"plan":"прямой patch администратора"}'::jsonb
       where id = '2n000000-0000-0000-0000-000000000001' $q$,
  '23514', null,
  'И прямой PATCH мимо RPC тоже падает — держит триггер lesson_notes_lock_approved_content, а не функция');

select public.tests_claims('25555555-5555-5555-5555-555555555555','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.write_lesson_note('2fffffff-0000-0000-0000-000000000001', '2eeeeeee-0000-0000-0000-000000000001',
        '{}'::jsonb) $q$,
  '23514', null,
  'Специалист без своего авторства на уже утверждённую строку тоже получает «нельзя изменить», а не «нет прав» — так честнее: причина отказа одна и та же для всех');
reset role;

select public.tests_claims('21111111-1111-1111-1111-111111111111','2ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select isnt(
  (select public.archive_lesson_note('2n000000-0000-0000-0000-000000000001')), null,
  'archive_lesson_note владельцу доступен даже для утверждённой заметки — архив не то же самое, что правка содержимого');
reset role;


-- 7. Межцентровая защита на каждом id-адресуемом RPC (Р1) — сводный забор ------------------------

select public.tests_claims('29999999-9999-9999-9999-999999999999','2ccccccc-0000-0000-0000-00000000000b');
set local role authenticated;

select throws_ok(
  $q$ select public.update_diagnostic('2d000000-0000-0000-0000-000000000001', 'из чужого центра') $q$,
  '42704', null, 'update_diagnostic не находит запись центра А из центра Б');
select throws_ok(
  $q$ select public.set_goal_status('2bbbb000-0000-0000-0000-000000000001', 'paused') $q$,
  '42704', null, 'set_goal_status не находит цель центра А из центра Б');
select throws_ok(
  $q$ select public.update_goal_progress('2p000000-0000-0000-0000-000000000001', 1) $q$,
  '42704', null, 'update_goal_progress не находит запись центра А из центра Б');
select throws_ok(
  $q$ select public.update_homework('2h000000-0000-0000-0000-000000000001', null, 'x') $q$,
  '42704', null, 'update_homework не находит задание центра А из центра Б');
select throws_ok(
  $q$ select public.submit_homework('2h000000-0000-0000-0000-000000000001') $q$,
  '42704', null, 'submit_homework не находит задание центра А из центра Б');
select throws_ok(
  $q$ select public.review_homework('2h000000-0000-0000-0000-000000000001') $q$,
  '42704', null, 'review_homework не находит задание центра А из центра Б');
select throws_ok(
  $q$ select public.approve_lesson_note('2n000000-0000-0000-0000-000000000001') $q$,
  '42704', null, 'approve_lesson_note не находит заметку центра А из центра Б');
select is(
  (select public.archive_diagnostic('2d000000-0000-0000-0000-000000000001')), false,
  'archive_* по чужому центру возвращает false, а не архивирует чужую запись — молчаливо, не исключением');

reset role;

select * from finish();

rollback;
