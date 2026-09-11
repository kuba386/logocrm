-- pgTAP: составные FK (id, center_id) на границах тенанта (миграция 0021).
--
-- Все новые FK — обычные, immediate (не deferred, см. шапку миграции, Р3):
-- нарушение всплывает сразу в момент insert/update, поэтому throws_ok ниже
-- не нуждается ни в каких обходах с SET CONSTRAINTS.
--
-- Отдельный блок (раздел «BEFORE-триггер») воспроизводит саму утечку, ради
-- которой писалась миграция: занятие центра А со student_id ребёнка центра Б,
-- у которого уже есть реальное занятие в центре Б на то же время. До 0021 это
-- дошло бы до AFTER-триггера lessons_sync_participants → exclusion_violation
-- → текст ошибки с ФИО чужого ребёнка. Проверяется и то, что ошибка теперь
-- читаемая (BEFORE-триггер раздела 3), и то, что в её тексте ФИО ребёнка Б
-- отсутствует.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(46);

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-b@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','ghost@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-fk','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-fk','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист А'),
  ('aaaaaaaa-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Специалист Б');

insert into public.rooms (id, center_id, name) values
  ('11111111-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Кабинет А'),
  ('11111111-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Кабинет Б');

insert into public.services (id, center_id, name, duration_min, kind) values
  ('f1111111-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Индивидуальное А',45,'individual'),
  ('f1111111-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Индивидуальное Б',45,'individual');

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик А','+996700000001'),
  ('dddddddd-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Плательщик Б','+996700000002');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок А','dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Ребёнок Б Уникальное Фамилия','dddddddd-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-00000000000b');

insert into public.groups (id, center_id, name, service_id, teacher_id, room_id) values
  ('99999999-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Группа А','f1111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000001'),
  ('99999999-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Группа Б','f1111111-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-00000000000b','11111111-0000-0000-0000-00000000000b');

insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner',null);

-- Реальное занятие ребёнка Б в его собственном центре — цель для probe'а
-- утечки ФИО ниже: без него exclusion_violation внутри rebuild_lesson_
-- participants не с чем было бы пересечься.
insert into public.lessons (id, center_id, teacher_id, student_id, starts_at, ends_at) values
  ('40000000-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-00000000000b','eeeeeeee-0000-0000-0000-00000000000b','2026-11-02 09:00+06','2026-11-02 09:45+06');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;


-- 1-5. groups: teacher/room/service чужого центра -------------------------------

select throws_ok(
  $q$ insert into public.groups (id, center_id, name, teacher_id)
      values ('30000000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Группа с чужим специалистом','aaaaaaaa-0000-0000-0000-00000000000b') $q$,
  '23503', null, 'groups_teacher_fk: специалист центра Б в группе центра А'
);

select throws_ok(
  $q$ insert into public.groups (id, center_id, name, room_id)
      values ('30000000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Группа с чужим кабинетом','11111111-0000-0000-0000-00000000000b') $q$,
  '23503', null, 'groups_room_fk: кабинет центра Б в группе центра А'
);

select throws_ok(
  $q$ insert into public.groups (id, center_id, name, service_id)
      values ('30000000-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Группа с чужой услугой','f1111111-0000-0000-0000-00000000000b') $q$,
  '23503', null, 'groups_service_fk: услуга центра Б в группе центра А'
);

select lives_ok(
  $q$ insert into public.groups (id, center_id, name, teacher_id, room_id, service_id)
      values ('30000000-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','Группа своя','aaaaaaaa-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000001','f1111111-0000-0000-0000-000000000001') $q$,
  'Группа со своими specialist/room/service проходит'
);

select lives_ok(
  $q$ insert into public.groups (id, center_id, name) values ('30000000-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-00000000000a','Группа без ссылок') $q$,
  'NULL в teacher_id/room_id/service_id группы — MATCH SIMPLE, не блокируется'
);


-- 6-8. students: primary_teacher_id/payer_id чужого центра -----------------------

select throws_ok(
  $q$ insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id)
      values ('e0000000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Чужой специалист','dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-00000000000b') $q$,
  '23503', null, 'students_primary_teacher_fk: специалист центра Б у ребёнка центра А'
);

select throws_ok(
  $q$ insert into public.students (id, center_id, full_name, payer_id)
      values ('e0000000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Чужой плательщик','dddddddd-0000-0000-0000-00000000000b') $q$,
  '23503', null, 'students_payer_fk: плательщик центра Б у ребёнка центра А'
);

select lives_ok(
  $q$ insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id)
      values ('e0000000-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Свой ребёнок','dddddddd-0000-0000-0000-000000000001',null) $q$,
  'NULL в primary_teacher_id ребёнка — MATCH SIMPLE, не блокируется'
);


-- 9-13. invitations: teacher_id/payer_id чужого центра ----------------------------

select throws_ok(
  $q$ insert into public.invitations (id, center_id, role, teacher_id)
      values ('30000000-0000-0000-0000-000000000006','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-00000000000b') $q$,
  '23503', null, 'invitations_teacher_fk: специалист центра Б в приглашении центра А'
);

select throws_ok(
  $q$ insert into public.invitations (id, center_id, role, payer_id)
      values ('30000000-0000-0000-0000-000000000007','cccccccc-0000-0000-0000-00000000000a','parent','dddddddd-0000-0000-0000-00000000000b') $q$,
  '23503', null, 'invitations_payer_fk: плательщик центра Б в приглашении центра А (FK не существовал до 0021)'
);

select lives_ok(
  $q$ insert into public.invitations (id, center_id, role, teacher_id)
      values ('30000000-0000-0000-0000-000000000008','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001') $q$,
  'Приглашение своего специалиста проходит'
);

select lives_ok(
  $q$ insert into public.invitations (id, center_id, role, payer_id)
      values ('30000000-0000-0000-0000-000000000009','cccccccc-0000-0000-0000-00000000000a','parent','dddddddd-0000-0000-0000-000000000001') $q$,
  'Приглашение со своим плательщиком проходит'
);

select lives_ok(
  $q$ insert into public.invitations (id, center_id, role) values ('3000000a-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','admin') $q$,
  'NULL в teacher_id/payer_id приглашения — MATCH SIMPLE, не блокируется'
);


-- 14-17. memberships: teacher_id/payer_id чужого центра, раньше не было FK -------

select throws_ok(
  $q$ insert into public.memberships (user_id, center_id, role, teacher_id)
      values ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-00000000000b') $q$,
  '23503', null, 'memberships_teacher_fk: специалист центра Б в членстве центра А (FK не существовал до 0021)'
);

select throws_ok(
  $q$ insert into public.memberships (user_id, center_id, role, payer_id)
      values ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','parent','dddddddd-0000-0000-0000-00000000000b') $q$,
  '23503', null, 'memberships_payer_fk: плательщик центра Б в членстве центра А (FK не существовал до 0021)'
);

select lives_ok(
  $q$ insert into public.memberships (user_id, center_id, role, teacher_id)
      values ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001') $q$,
  'Членство со своим специалистом проходит'
);

delete from public.memberships where user_id = '33333333-3333-3333-3333-333333333333';

select lives_ok(
  $q$ insert into public.memberships (user_id, center_id, role, payer_id)
      values ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','parent','dddddddd-0000-0000-0000-000000000001') $q$,
  'Членство со своим плательщиком проходит'
);

delete from public.memberships where user_id = '33333333-3333-3333-3333-333333333333';


-- 18-22. lessons: student/group/room/service чужого центра ------------------------
--
-- Ожидаем 42704 от BEFORE-триггера lessons_check_center_refs (раздел 3
-- миграции), не 23503 от составного FK: триггер всегда срабатывает раньше
-- на insert/update, FK за ним — вторая линия защиты (тест 41 ниже проверяет,
-- что констрейнты по-прежнему существуют).

select throws_ok(
  format($q$ insert into public.lessons (id, center_id, teacher_id, student_id, starts_at, ends_at)
      values ('40000000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b',%L,%L) $q$,
    '2026-11-03 09:00+06', '2026-11-03 09:45+06'),
  '42704', 'Ученик не найден в этом центре', 'lessons_check_center_refs: ребёнок центра Б в занятии центра А'
);

select throws_ok(
  format($q$ insert into public.lessons (id, center_id, teacher_id, group_id, starts_at, ends_at)
      values ('40000000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','99999999-0000-0000-0000-00000000000b',%L,%L) $q$,
    '2026-11-03 10:00+06', '2026-11-03 10:45+06'),
  '42704', 'Группа не найдена в этом центре', 'lessons_check_center_refs: группа центра Б в занятии центра А'
);

select throws_ok(
  format($q$ insert into public.lessons (id, center_id, teacher_id, student_id, room_id, starts_at, ends_at)
      values ('40000000-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','11111111-0000-0000-0000-00000000000b',%L,%L) $q$,
    '2026-11-03 11:00+06', '2026-11-03 11:45+06'),
  '42704', 'Кабинет не найден в этом центре', 'lessons_check_center_refs: кабинет центра Б в занятии центра А'
);

select throws_ok(
  format($q$ insert into public.lessons (id, center_id, teacher_id, student_id, service_id, starts_at, ends_at)
      values ('40000000-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','f1111111-0000-0000-0000-00000000000b',%L,%L) $q$,
    '2026-11-03 12:00+06', '2026-11-03 12:45+06'),
  '42704', 'Услуга не найдена в этом центре', 'lessons_check_center_refs: услуга центра Б в занятии центра А'
);

select lives_ok(
  format($q$ insert into public.lessons (id, center_id, teacher_id, student_id, room_id, service_id, starts_at, ends_at)
      values ('40000000-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000001','f1111111-0000-0000-0000-000000000001',%L,%L) $q$,
    '2026-11-03 13:00+06', '2026-11-03 13:45+06'),
  'Занятие со всеми ссылками своего центра проходит'
);


-- 23-25. group_students: group_id/student_id чужого центра -----------------------
--
-- Ожидаем 42704 от BEFORE-триггера group_students_check_center_refs
-- (раздел 3), не 23503 от составного FK — тот же порядок, что у lessons.

select throws_ok(
  $q$ insert into public.group_students (id, center_id, group_id, student_id)
      values ('50000000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-00000000000b','eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42704', 'Группа не найдена в этом центре', 'group_students_check_center_refs: группа центра Б в составе центра А'
);

select throws_ok(
  $q$ insert into public.group_students (id, center_id, group_id, student_id)
      values ('50000000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b') $q$,
  '42704', 'Ученик не найден в этом центре', 'group_students_check_center_refs: ребёнок центра Б в составе центра А'
);

select lives_ok(
  $q$ insert into public.group_students (id, center_id, group_id, student_id)
      values ('50000000-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001') $q$,
  'Состав группы своего центра проходит'
);


-- 26-27. lesson_participants: денормализация — тоже под составным FK -------------
-- Пишут только триггеры (grant select-only), но сама таблица должна быть
-- защищена от рассинхрона так же, как источники: lessons и students.
-- throws_like с именем констрейнта — у обеих вставок в принципе мог бы
-- сработать не тот FK, throws_ok('23503') этого не отличит.

select throws_like(
  $q$ insert into public.lesson_participants (lesson_id, student_id, center_id, starts_at, ends_at)
      values ('40000000-0000-0000-0000-000000000005','eeeeeeee-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','2026-11-03 13:00+06','2026-11-03 13:45+06') $q$,
  '%lesson_participants_lesson_fk%',
  'lesson_participants_lesson_fk: занятие центра А не существует с center_id центра Б'
);

select throws_like(
  $q$ insert into public.lesson_participants (lesson_id, student_id, center_id, starts_at, ends_at)
      values ('40000000-0000-0000-0000-000000000005','eeeeeeee-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000a','2026-11-04 13:00+06','2026-11-04 13:45+06') $q$,
  '%lesson_participants_student_fk%',
  'lesson_participants_student_fk: ребёнок центра Б записан на занятие центра А'
);


-- 28-29. memberships: грант insert/update/delete снят у authenticated -------------
-- Все реальные изменения (create_center/accept_invitation/change_member_role/
-- revoke_membership) — security definer и грантом на таблицу не пользуются.

select ok(
  not has_table_privilege('authenticated', 'public.memberships', 'INSERT')
  and not has_table_privilege('authenticated', 'public.memberships', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.memberships', 'DELETE'),
  'memberships: authenticated больше не может писать напрямую (insert/update/delete сняты)'
);

select ok(
  has_table_privilege('authenticated', 'public.memberships', 'SELECT'),
  'memberships: чтение осталось — старые select-запросы приложения не задеты'
);


-- 30-31. repair_center_scoped_refs — только для миграций, а не для клиента -------

select ok(
  not has_function_privilege('authenticated', 'public.repair_center_scoped_refs()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.repair_center_scoped_refs()', 'EXECUTE'),
  'repair_center_scoped_refs закрыт от authenticated/anon'
);

select lives_ok(
  $q$ select public.repair_center_scoped_refs() $q$,
  'repair_center_scoped_refs идемпотентна: повторный вызов на уже согласованных данных не падает'
);


-- 32-38. create_lesson_series: чужой центр — читаемая ошибка, свой центр — работает --

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_like(
  $q$ select * from public.create_lesson_series(jsonb_build_object(
        'teacher_id','aaaaaaaa-0000-0000-0000-00000000000b','student_id','eeeeeeee-0000-0000-0000-000000000001',
        'first_date','2026-11-09','until','2026-11-09','time','09:00','weekdays','[1]'::jsonb)) $q$,
  '%Специалист недоступен%',
  'create_lesson_series: специалист центра Б — читаемая ошибка вместо 23503'
);

select throws_like(
  $q$ select * from public.create_lesson_series(jsonb_build_object(
        'teacher_id','aaaaaaaa-0000-0000-0000-000000000001','room_id','11111111-0000-0000-0000-00000000000b',
        'student_id','eeeeeeee-0000-0000-0000-000000000001',
        'first_date','2026-11-09','until','2026-11-09','time','09:00','weekdays','[1]'::jsonb)) $q$,
  '%Кабинет недоступен%',
  'create_lesson_series: кабинет центра Б — читаемая ошибка вместо 23503'
);

select throws_like(
  $q$ select * from public.create_lesson_series(jsonb_build_object(
        'teacher_id','aaaaaaaa-0000-0000-0000-000000000001','service_id','f1111111-0000-0000-0000-00000000000b',
        'student_id','eeeeeeee-0000-0000-0000-000000000001',
        'first_date','2026-11-09','until','2026-11-09','time','09:00','weekdays','[1]'::jsonb)) $q$,
  '%Услуга недоступна%',
  'create_lesson_series: услуга центра Б — читаемая ошибка вместо 23503'
);

select throws_like(
  $q$ select * from public.create_lesson_series(jsonb_build_object(
        'teacher_id','aaaaaaaa-0000-0000-0000-000000000001','group_id','99999999-0000-0000-0000-00000000000b',
        'first_date','2026-11-09','until','2026-11-09','time','09:00','weekdays','[1]'::jsonb)) $q$,
  '%Группа недоступна%',
  'create_lesson_series: группа центра Б — читаемая ошибка вместо 23503'
);

select throws_like(
  $q$ select * from public.create_lesson_series(jsonb_build_object(
        'teacher_id','aaaaaaaa-0000-0000-0000-000000000001','student_id','eeeeeeee-0000-0000-0000-00000000000b',
        'first_date','2026-11-09','until','2026-11-09','time','09:00','weekdays','[1]'::jsonb)) $q$,
  '%Ученик недоступен%',
  'create_lesson_series: ученик центра Б — читаемая ошибка вместо 23503'
);

select is(
  (select count(*)::int from public.lessons where series_id is not null),
  0,
  'Ни одна из отбитых попыток create_lesson_series не создала занятие'
);

select lives_ok(
  $q$ select * from public.create_lesson_series(jsonb_build_object(
        'teacher_id','aaaaaaaa-0000-0000-0000-000000000001','student_id','eeeeeeee-0000-0000-0000-000000000001',
        'room_id','11111111-0000-0000-0000-000000000001','service_id','f1111111-0000-0000-0000-000000000001',
        'first_date','2026-11-16','until','2026-11-23','time','15:00','weekdays','[1]'::jsonb)) $q$,
  'create_lesson_series: серия из своих же teacher/room/service/student по-прежнему создаётся (happy path не сломан переопределением функции)'
);

select is(
  (select count(*)::int from public.lessons where series_id is not null),
  2,
  'Серия из двух дат создала ровно два занятия'
);

reset role;


-- 39-40. groups/rooms получили unique(id, center_id) — цель для FK выше ------------

select is(
  (select count(*)::int from pg_constraint
    where conname = 'groups_id_center_key' and contype = 'u' and connamespace = 'public'::regnamespace),
  1,
  'groups: unique(id, center_id) заведён'
);

select is(
  (select count(*)::int from pg_constraint
    where conname = 'rooms_id_center_key' and contype = 'u' and connamespace = 'public'::regnamespace),
  1,
  'rooms: unique(id, center_id) заведён'
);


-- 41. Все 17 новых составных FK на месте (15 из первой версии + payer_id у
--     memberships/invitations, найденные вторым раундом ревью) ------------------

select is(
  (select count(*)::int from pg_constraint
    where conname in (
      'groups_teacher_fk','groups_room_fk','groups_service_fk',
      'students_primary_teacher_fk','students_payer_fk',
      'invitations_teacher_fk','invitations_payer_fk',
      'memberships_teacher_fk','memberships_payer_fk',
      'lessons_student_fk','lessons_group_fk','lessons_room_fk','lessons_service_fk',
      'group_students_group_fk','group_students_student_fk',
      'lesson_participants_lesson_fk','lesson_participants_student_fk'
    )
    and connamespace = 'public'::regnamespace),
  17,
  'Все 17 новых составных FK на месте'
);


-- 42. Старые одноколоночные FK сняты — без этого PostgREST не резолвит
--     embedded-запросы (students(...,payers(...)) и т.п.): два FK между
--     одной парой таблиц дают PGRST201 "more than one relationship was
--     found", а не 42704 (Р6, шапка миграции). Первый прогон CI поймал это
--     на /app/students Playwright-тестом — здесь то же самое проверяется
--     на уровне метаданных, быстрее и без браузера.

select is(
  (select count(*)::int from pg_constraint
    where conname in (
      'groups_teacher_id_fkey','groups_room_id_fkey','groups_service_id_fkey',
      'students_primary_teacher_id_fkey','students_payer_id_fkey',
      'invitations_teacher_id_fkey',
      'lessons_teacher_id_fkey','lessons_substitute_teacher_id_fkey',
      'lessons_student_id_fkey','lessons_group_id_fkey','lessons_room_id_fkey','lessons_service_id_fkey',
      'group_students_group_id_fkey','group_students_student_id_fkey',
      'lesson_participants_lesson_id_fkey','lesson_participants_student_id_fkey'
    )
    and connamespace = 'public'::regnamespace),
  0,
  'Старые одноколоночные FK (включая два из 0017) сняты — ни один embed не увидит два пути к одной таблице'
);


-- 43-44. BEFORE-триггер закрывает саму утечку ФИО через exclusion_violation ------
--
-- До 0021 этот insert прошёл бы RLS/грант (owner центра А), дошёл до AFTER-
-- триггера lessons_sync_participants → rebuild_lesson_participants →
-- exclusion_violation с реальным занятием ребёнка Б (фикстура выше) →
-- текст ошибки с его ФИО. Составной FK (раздел 2) — даже немедленный — не
-- гарантирует, что сработает раньше AFTER-триггера той же таблицы; гарантию
-- даёт только BEFORE (раздел 3), и именно её проверяем: ошибка — читаемая
-- "Ученик не найден", а не текст с чужим ФИО.

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

do $probe$
declare
  v_msg text;
begin
  begin
    insert into public.lessons (id, center_id, teacher_id, student_id, starts_at, ends_at)
    values ('40000000-0000-0000-0000-00000000000c','cccccccc-0000-0000-0000-00000000000a',
            'aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b',
            '2026-11-02 09:00+06','2026-11-02 09:45+06');
    v_msg := '<no error — insert succeeded>';
  exception when others then
    v_msg := sqlerrm;
  end;
  perform set_config('test.leak_probe_msg', v_msg, true);
end;
$probe$;

reset role;

select ok(
  current_setting('test.leak_probe_msg', true) like '%Ученик не найден в этом центре%',
  'Прямой insert с чужим student_id отбивается BEFORE-триггером читаемым 42704, а не exclusion_violation'
);

select ok(
  current_setting('test.leak_probe_msg', true) not like '%Ребёнок Б Уникальное Фамилия%',
  'Текст ошибки не содержит ФИО ребёнка центра Б — утечка ПД между центрами закрыта'
);


-- 45. Занятие из probe-теста не осталось в базе (BEFORE-триггер откатил insert) ---

select is(
  (select count(*)::int from public.lessons where id = '40000000-0000-0000-0000-00000000000c'),
  0,
  'Отбитая попытка probe-теста не создала занятие'
);

select * from finish();

rollback;
