-- pgTAP: «Провести занятие» одним вызовом (0039).
--
-- Фикстура — групповое занятие с двумя детьми (у обоих живой абонемент),
-- второй центр для межцентровой проверки. Одно занятие используется для
-- happy path (лист 1) и один раз становится 'done' — навсегда, поэтому
-- для всех отрицательных сценариев заведено отдельное «занятие-неудачник»
-- (лист 2): каждый его провал откатывает всё целиком, и лист 2 остаётся
-- пустым 'planned' для следующей проверки — так фикстура меньше, а не
-- потому что порядок тестов важен сам по себе.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(32);

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
  ('00000000-0000-0000-0000-000000000000','31111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-cl2@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','34444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-with-cl2@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','35555555-5555-5555-5555-555555555555','authenticated','authenticated','teacher-without-cl2@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','32222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-cl2@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','39999999-9999-9999-9999-999999999999','authenticated','authenticated','owner-b-cl2@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('3ccccccc-0000-0000-0000-00000000000a','Центр А (занятие)','centr-a-lesson','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('3ccccccc-0000-0000-0000-00000000000b','Центр Б (занятие)','centr-b-lesson','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('3aaaaaaa-0000-0000-0000-000000000001','3ccccccc-0000-0000-0000-00000000000a','Ведущий специалист'),
  ('3aaaaaaa-0000-0000-0000-000000000002','3ccccccc-0000-0000-0000-00000000000a','Другой специалист');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('3bbbbbbb-0000-0000-0000-000000000001','3ccccccc-0000-0000-0000-00000000000a','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('3ddddddd-0000-0000-0000-000000000001','3ccccccc-0000-0000-0000-00000000000a','Родитель первого','+996700000201'),
  ('3ddddddd-0000-0000-0000-000000000002','3ccccccc-0000-0000-0000-00000000000a','Родитель второго','+996700000202'),
  ('3ddddddd-0000-0000-0000-000000000003','3ccccccc-0000-0000-0000-00000000000b','Родитель центра Б','+996700000203');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('31111111-1111-1111-1111-111111111111','3ccccccc-0000-0000-0000-00000000000a','owner',    null, null),
  ('34444444-4444-4444-4444-444444444444','3ccccccc-0000-0000-0000-00000000000a','teacher','3aaaaaaa-0000-0000-0000-000000000001', null),
  ('35555555-5555-5555-5555-555555555555','3ccccccc-0000-0000-0000-00000000000a','teacher','3aaaaaaa-0000-0000-0000-000000000002', null),
  ('32222222-2222-2222-2222-222222222222','3ccccccc-0000-0000-0000-00000000000a','registrar',null, null),
  ('39999999-9999-9999-9999-999999999999','3ccccccc-0000-0000-0000-00000000000b','owner',    null, null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('3eeeeeee-0000-0000-0000-000000000001','3ccccccc-0000-0000-0000-00000000000a','Ребёнок один','3ddddddd-0000-0000-0000-000000000001'),
  ('3eeeeeee-0000-0000-0000-000000000002','3ccccccc-0000-0000-0000-00000000000a','Ребёнок два','3ddddddd-0000-0000-0000-000000000002'),
  ('3eeeeeee-0000-0000-0000-000000000003','3ccccccc-0000-0000-0000-00000000000b','Ребёнок центра Б','3ddddddd-0000-0000-0000-000000000003');

insert into public.groups (id, center_id, name, service_id, teacher_id) values
  ('3bcbcbcb-0000-0000-0000-000000000001','3ccccccc-0000-0000-0000-00000000000a','Группа','3bbbbbbb-0000-0000-0000-000000000001','3aaaaaaa-0000-0000-0000-000000000001');

-- joined_at закреплён явно, не default current_date: занятия ниже берут
-- starts_at от now() с отрицательным интервалом, и CI, стартовавший между
-- 00:00 и 02:00 UTC, сдвигает starts_at::date на вчера, а joined_at
-- остался бы today — «вошёл позже своего же занятия», ребёнок молча
-- выпадает из lesson_participants (rebuild_lesson_participants, 0007).
insert into public.group_students (center_id, group_id, student_id, joined_at) values
  ('3ccccccc-0000-0000-0000-00000000000a','3bcbcbcb-0000-0000-0000-000000000001','3eeeeeee-0000-0000-0000-000000000001', current_date - 7),
  ('3ccccccc-0000-0000-0000-00000000000a','3bcbcbcb-0000-0000-0000-000000000001','3eeeeeee-0000-0000-0000-000000000002', current_date - 7);

-- Занятие 1 — для happy path и повторного вызова (лист 1). Занятие 2 —
-- «неудачник»: каждый отрицательный сценарий откатывает его целиком, и
-- оно остаётся planned/пустым для следующего. Оба в прошлом — иначе
-- «занятие ещё не началось» отобьёт даже корректный вызов.
-- group_id и student_id — исключающее «или» (0006): у групповых 1/2 —
-- group_id, у 4/5 (одиночных, до статусов) — student_id. Занятия 1 и 2 не
-- пересекаются по времени: у одних и тех же детей в один и тот же час —
-- lesson_participants_no_overlap (0006) отбил бы вставку самого занятия 2.
insert into public.lessons (id, center_id, teacher_id, group_id, student_id, status, starts_at, ends_at) values
  ('3fffffff-0000-0000-0000-000000000001','3ccccccc-0000-0000-0000-00000000000a','3aaaaaaa-0000-0000-0000-000000000001','3bcbcbcb-0000-0000-0000-000000000001', null, 'planned', now() - interval '2 hours', now() - interval '1 hour 15 minutes'),
  ('3fffffff-0000-0000-0000-000000000002','3ccccccc-0000-0000-0000-00000000000a','3aaaaaaa-0000-0000-0000-000000000001','3bcbcbcb-0000-0000-0000-000000000001', null, 'planned', now() - interval '1 hour', now() - interval '15 minutes'),
  ('3fffffff-0000-0000-0000-000000000004','3ccccccc-0000-0000-0000-00000000000a','3aaaaaaa-0000-0000-0000-000000000001', null, '3eeeeeee-0000-0000-0000-000000000001','cancelled', now() - interval '1 hour', now() - interval '15 minutes'),
  ('3fffffff-0000-0000-0000-000000000005','3ccccccc-0000-0000-0000-00000000000a','3aaaaaaa-0000-0000-0000-000000000001', null, '3eeeeeee-0000-0000-0000-000000000001','planned', now() + interval '1 hour', now() + interval '1 hour 45 minutes');

select public.tests_claims('31111111-1111-1111-1111-111111111111','3ccccccc-0000-0000-0000-00000000000a');

insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, lessons_used, price_tiyin, lesson_price_tiyin, starts_at) values
  ('3cb00000-0000-0000-0000-000000000001','3ccccccc-0000-0000-0000-00000000000a','3eeeeeee-0000-0000-0000-000000000001','3ddddddd-0000-0000-0000-000000000001', 10, 0, 70000, 7000, current_date - 30),
  ('3cb00000-0000-0000-0000-000000000002','3ccccccc-0000-0000-0000-00000000000a','3eeeeeee-0000-0000-0000-000000000002','3ddddddd-0000-0000-0000-000000000002', 10, 0, 70000, 7000, current_date - 30);

insert into public.goals (id, center_id, student_id, stage_id, title, status) values
  ('3bd00000-0000-0000-0000-000000000001','3ccccccc-0000-0000-0000-00000000000a','3eeeeeee-0000-0000-0000-000000000001',
   (select id from public.goal_stages where center_id = '3ccccccc-0000-0000-0000-00000000000a' and code = 'setting'),
   'Постановка [р]', 'active');

insert into public.exercise_library (id, center_id, title) values
  ('3ec00000-0000-0000-0000-000000000001', null, 'Упражнение платформы'),
  ('3ec00000-0000-0000-0000-000000000002', '3ccccccc-0000-0000-0000-00000000000a', 'Упражнение центра А'),
  ('3ec00000-0000-0000-0000-000000000003', '3ccccccc-0000-0000-0000-00000000000b', 'Упражнение центра Б');


-- 1. Happy path одним вызовом ------------------------------------------------------------------------

select public.tests_claims('34444444-4444-4444-4444-444444444444','3ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select lives_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000001', $j$
    {
      "attendance": [{"student_id":"3eeeeeee-0000-0000-0000-000000000001"},
                      {"student_id":"3eeeeeee-0000-0000-0000-000000000002"}],
      "progress":   [{"goal_id":"3bd00000-0000-0000-0000-000000000001","score":70,"note":"хорошо"}],
      "notes":      [{"student_id":"3eeeeeee-0000-0000-0000-000000000001","soap":{"plan":"закрепить"},"parent_summary":"Занимались хорошо"}],
      "homework":   [{"student_id":"3eeeeeee-0000-0000-0000-000000000001","free_text":"Повторить",
                      "exercise_ids":["3ec00000-0000-0000-0000-000000000001","3ec00000-0000-0000-0000-000000000002"],
                      "due_in_days":2}]
    }
  $j$::jsonb) $q$,
  'Один вызов проводит занятие целиком');

reset role;

select is((select count(*)::int from public.attendance where lesson_id = '3fffffff-0000-0000-0000-000000000001'), 2,
  'Посещение отмечено обоим участникам группы');
select is((select count(*)::int from public.goal_progress where lesson_id = '3fffffff-0000-0000-0000-000000000001'), 1,
  'Прогресс по цели записан');
select is((select score from public.goal_progress where lesson_id = '3fffffff-0000-0000-0000-000000000001'), 70,
  'С тем же score, что пришёл');
select is((select count(*)::int from public.lesson_notes where lesson_id = '3fffffff-0000-0000-0000-000000000001'), 1,
  'Заметка занятия записана');
select is(
  (select count(*)::int from public.homework h
    where h.lesson_id = '3fffffff-0000-0000-0000-000000000001' and h.student_id = '3eeeeeee-0000-0000-0000-000000000001'),
  1, 'Домашнее задание записано');
select is(
  (select count(*)::int from public.homework_exercises he
    join public.homework h on h.id = he.homework_id
   where h.lesson_id = '3fffffff-0000-0000-0000-000000000001'),
  2, 'Состав задания — оба упражнения');
select is((select status from public.lessons where id = '3fffffff-0000-0000-0000-000000000001'), 'done',
  'Занятие закрыто');
select is((select lessons_used from public.subscriptions where id = '3cb00000-0000-0000-0000-000000000001'), 1,
  'Абонемент первого ребёнка списан на одно занятие');
select is((select lessons_used from public.subscriptions where id = '3cb00000-0000-0000-0000-000000000002'), 1,
  'И второго — тоже, независимо от первого');
select is(
  (select count(*)::int from public.events
    where type = 'lesson.completed' and payload ->> 'lesson_id' = '3fffffff-0000-0000-0000-000000000001'),
  1, 'Событие lesson.completed ровно одно');


-- 2. Повторный вызов — идемпотентность (Р1) ----------------------------------------------------------

select public.tests_claims('34444444-4444-4444-4444-444444444444','3ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000001', '{}'::jsonb) $q$,
  '23514', null, 'Повторный вызов на уже проведённом занятии — явный отказ');
reset role;

select is((select lessons_used from public.subscriptions where id = '3cb00000-0000-0000-0000-000000000001'), 1,
  'Повтор не списал абонемент второй раз');
select is(
  (select count(*)::int from public.events
    where type = 'lesson.completed' and payload ->> 'lesson_id' = '3fffffff-0000-0000-0000-000000000001'),
  1, 'И второго события не появилось');


-- 3. «Занятие-неудачник»: каждый провал откатывает всё и ничего не портит --------------------------

select public.tests_claims('34444444-4444-4444-4444-444444444444','3ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000002', '{"homeworks": []}'::jsonb) $q$,
  '22023', null, 'Неизвестный ключ верхнего уровня — отказ с его именем');

select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000002', '{"attendance": {}}'::jsonb) $q$,
  '22023', null, 'attendance не массивом — отказ');

select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000002', $j$
    {"progress": [{"goal_id":"3bd00000-0000-0000-0000-000000000001","score":40},
                   {"goal_id":"3bd00000-0000-0000-0000-000000000001","score":60}]}
  $j$::jsonb) $q$,
  '23514', null, 'Повтор одной цели в progress за одно занятие — отказ, а не тихое схлопывание (Р3)');

select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000002', $j$
    {"homework": [{"student_id":"3eeeeeee-0000-0000-0000-000000000001","free_text":"a"},
                  {"student_id":"3eeeeeee-0000-0000-0000-000000000001","free_text":"b"}]}
  $j$::jsonb) $q$,
  '23514', null, 'Повтор одного ребёнка в homework за одно занятие — отказ (Р3)');

-- Полный откат: посещение обоих участников и заметка есть, а задание
-- ссылается на упражнение центра Б — падает вся транзакция целиком.
select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000002', $j$
    {
      "attendance": [{"student_id":"3eeeeeee-0000-0000-0000-000000000001"},
                      {"student_id":"3eeeeeee-0000-0000-0000-000000000002"}],
      "notes":      [{"student_id":"3eeeeeee-0000-0000-0000-000000000001","parent_summary":"x"}],
      "homework":   [{"student_id":"3eeeeeee-0000-0000-0000-000000000001",
                      "exercise_ids":["3ec00000-0000-0000-0000-000000000001","3ec00000-0000-0000-0000-000000000003"]}]
    }
  $j$::jsonb) $q$,
  '42704', null, 'Упражнение чужого центра в ДЗ — откатывает всё занятие целиком (Р5)');

-- Неполное покрытие: отмечен один из двух участников группы.
select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000002',
        '{"attendance": [{"student_id":"3eeeeeee-0000-0000-0000-000000000001"}]}'::jsonb) $q$,
  '23514', null, 'Не все участники группы отмечены — отказ, а не наполовину проведённое занятие (Р2)');

-- Пустой payload на занятии с участниками — тот же отказ, а не «проведено».
select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000002', '{}'::jsonb) $q$,
  '23514', null, 'Пустой payload на занятии с участниками не проводит его молча');

reset role;

-- Проверки состояния — от postgres, не под authenticated: RLS учителя на
-- attendance/subscriptions уже, чем видимость клиники, и «0 строк» должно
-- значить «правда ноль», а не «не видно этой роли».
select is((select count(*)::int from public.attendance where lesson_id = '3fffffff-0000-0000-0000-000000000002'), 0,
  'Ни одна из провальных попыток не оставила посещения — включая ту, что успела вставиться до отказа покрытия');
select is((select count(*)::int from public.lesson_notes where lesson_id = '3fffffff-0000-0000-0000-000000000002'), 0,
  'И заметки нет');
select is((select status from public.lessons where id = '3fffffff-0000-0000-0000-000000000002'), 'planned',
  'Занятие осталось не проведённым');
select is((select lessons_used from public.subscriptions where id = '3cb00000-0000-0000-0000-000000000001'), 1,
  'Абонемент первого ребёнка не тронут ни одной из провальных попыток — как был после листа 1');


-- 4. Роли и границы -----------------------------------------------------------------------------------

select public.tests_claims('35555555-5555-5555-5555-555555555555','3ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000002', '{}'::jsonb) $q$,
  '42501', null, 'Другой специалист не проводит чужое занятие');
reset role;

select public.tests_claims('32222222-2222-2222-2222-222222222222','3ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000002', '{}'::jsonb) $q$,
  '42501', null, 'Регистратору complete_lesson не положен вовсе (Р9)');
reset role;

select public.tests_claims('39999999-9999-9999-9999-999999999999','3ccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000001', '{}'::jsonb) $q$,
  '42704', null, 'Владелец центра Б не находит занятие центра А');
reset role;

-- И после всех отрицательных сценариев занятие-неудачник по-прежнему
-- чистое — ни одна из проверок его не тронула.
select is((select count(*)::int from public.attendance where lesson_id = '3fffffff-0000-0000-0000-000000000002'), 0,
  'Занятие-неудачник осталось пустым после всех отказов');
select is((select status from public.lessons where id = '3fffffff-0000-0000-0000-000000000002'), 'planned',
  'И не проведённым');


-- 5. Статусы занятия -----------------------------------------------------------------------------------

select public.tests_claims('34444444-4444-4444-4444-444444444444','3ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000004', '{}'::jsonb) $q$,
  '23514', null, 'Отменённое занятие нельзя провести');
select throws_ok(
  $q$ select public.complete_lesson('3fffffff-0000-0000-0000-000000000005', '{}'::jsonb) $q$,
  '22023', null, 'Занятие из будущего нельзя провести раньше времени (Р8)');
reset role;

select * from finish();

rollback;
