-- pgTAP: расписание.
-- Главное здесь — что накладки ловит база, а не интерфейс: девять проверок
-- занятости плюс переходы статусов, запрет записи в служебную таблицу и
-- часовой пояс серий.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(16);

-- Фикстуры --------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings)
values ('cccccccc-cccc-cccc-cccc-cccccccccccc','Центр А','centr-a','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Препод А'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-cccc-cccc-cccc-cccccccccccc','Препод Б');

insert into public.payers (id, center_id, full_name, phone) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Иванова А.','+996700111222'),
  ('bbbbbbbb-0000-0000-0000-000000000002','cccccccc-cccc-cccc-cccc-cccccccccccc','Петрова Б.','+996700333444');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Данияр','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-cccc-cccc-cccc-cccccccccccc','Айлин','bbbbbbbb-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002');

insert into public.rooms (id, center_id, name)
values ('11111111-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Кабинет 1');

insert into public.services (id, center_id, name, duration_min)
values ('99999999-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Индивидуальное',45);

insert into public.groups (id, center_id, name)
values ('33333333-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Группа 1');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-cccc-cccc-cccc-cccccccccccc','owner',null,null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-cccc-cccc-cccc-cccccccccccc','teacher','aaaaaaaa-0000-0000-0000-000000000001',null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-cccc-cccc-cccc-cccccccccccc','parent',null,'bbbbbbbb-0000-0000-0000-000000000001');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

-- Базовое занятие: Препод А, пн 10:00–10:45.
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at)
values ('44444444-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc',
        '99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-000000000001','2026-10-05 10:00+06','2026-10-05 10:45+06');


-- 1–5. Занятость специалиста, кабинета, замена -------------------------------

select throws_ok(
  $q$ insert into public.lessons (center_id, teacher_id, student_id, starts_at, ends_at)
      values ('cccccccc-cccc-cccc-cccc-cccccccccccc','aaaaaaaa-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000002','2026-10-05 10:30+06','2026-10-05 11:15+06') $q$,
  '23P01', null, 'Специалист не может вести два занятия внахлёст'
);

select lives_ok(
  $q$ insert into public.lessons (center_id, teacher_id, student_id, starts_at, ends_at)
      values ('cccccccc-cccc-cccc-cccc-cccccccccccc','aaaaaaaa-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000002','2026-10-05 10:45+06','2026-10-05 11:30+06') $q$,
  'Занятие впритык (10:45 после 10:00–10:45) не считается накладкой'
);

insert into public.lessons (id, center_id, teacher_id, student_id, room_id, starts_at, ends_at)
values ('44444444-0000-0000-0000-000000000002','cccccccc-cccc-cccc-cccc-cccccccccccc',
        'aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '11111111-0000-0000-0000-000000000001','2026-10-06 10:00+06','2026-10-06 10:45+06');

select throws_ok(
  $q$ insert into public.lessons (center_id, teacher_id, student_id, room_id, starts_at, ends_at)
      values ('cccccccc-cccc-cccc-cccc-cccccccccccc','aaaaaaaa-0000-0000-0000-000000000002',
              'eeeeeeee-0000-0000-0000-000000000002','11111111-0000-0000-0000-000000000001',
              '2026-10-06 10:15+06','2026-10-06 11:00+06') $q$,
  '23P01', null, 'Кабинет не может быть занят дважды'
);

update public.lessons set status = 'cancelled' where id = '44444444-0000-0000-0000-000000000002';

select lives_ok(
  $q$ insert into public.lessons (center_id, teacher_id, student_id, room_id, starts_at, ends_at)
      values ('cccccccc-cccc-cccc-cccc-cccccccccccc','aaaaaaaa-0000-0000-0000-000000000002',
              'eeeeeeee-0000-0000-0000-000000000002','11111111-0000-0000-0000-000000000001',
              '2026-10-06 10:15+06','2026-10-06 11:00+06') $q$,
  'Отменённое занятие освобождает кабинет'
);

insert into public.lessons (id, center_id, teacher_id, student_id, starts_at, ends_at)
values ('44444444-0000-0000-0000-000000000003','cccccccc-cccc-cccc-cccc-cccccccccccc',
        'aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002',
        '2026-10-07 09:00+06','2026-10-07 09:45+06');
insert into public.lessons (id, center_id, teacher_id, student_id, starts_at, ends_at)
values ('44444444-0000-0000-0000-000000000004','cccccccc-cccc-cccc-cccc-cccccccccccc',
        'aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '2026-10-07 09:00+06','2026-10-07 09:45+06');

select throws_ok(
  $q$ update public.lessons set substitute_teacher_id = 'aaaaaaaa-0000-0000-0000-000000000002'
       where id = '44444444-0000-0000-0000-000000000004' $q$,
  '23P01', null, 'Заменой нельзя поставить уже занятого специалиста'
);


-- 6–9. Групповые занятия и состав --------------------------------------------

insert into public.group_students (center_id, group_id, student_id, joined_at)
values ('cccccccc-cccc-cccc-cccc-cccccccccccc','33333333-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-000000000001','2026-01-01');

insert into public.lessons (id, center_id, teacher_id, group_id, starts_at, ends_at)
values ('44444444-0000-0000-0000-000000000005','cccccccc-cccc-cccc-cccc-cccccccccccc',
        'aaaaaaaa-0000-0000-0000-000000000001','33333333-0000-0000-0000-000000000001',
        '2026-10-08 10:00+06','2026-10-08 10:45+06');

select is(
  (select count(*)::int from public.lesson_participants
    where lesson_id = '44444444-0000-0000-0000-000000000005'),
  1,
  'Триггер раскрыл состав группы в lesson_participants'
);

select throws_ok(
  $q$ insert into public.lessons (center_id, teacher_id, student_id, starts_at, ends_at)
      values ('cccccccc-cccc-cccc-cccc-cccccccccccc','aaaaaaaa-0000-0000-0000-000000000002',
              'eeeeeeee-0000-0000-0000-000000000001','2026-10-08 10:15+06','2026-10-08 11:00+06') $q$,
  '23P01', null, 'Ребёнок из группы не может взять индивидуальное внахлёст'
);

insert into public.lessons (id, center_id, teacher_id, student_id, starts_at, ends_at)
values ('44444444-0000-0000-0000-000000000006','cccccccc-cccc-cccc-cccc-cccccccccccc',
        'aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002',
        '2026-10-08 10:00+06','2026-10-08 10:45+06');

select throws_ok(
  $q$ insert into public.group_students (center_id, group_id, student_id, joined_at)
      values ('cccccccc-cccc-cccc-cccc-cccccccccccc','33333333-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000002','2026-01-01') $q$,
  '23P01', null, 'Нельзя добавить в группу ребёнка, у которого слот уже занят'
);

update public.lessons set status = 'cancelled' where id = '44444444-0000-0000-0000-000000000006';

select lives_ok(
  $q$ insert into public.group_students (center_id, group_id, student_id, joined_at)
      values ('cccccccc-cccc-cccc-cccc-cccccccccccc','33333333-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000002','2026-01-01') $q$,
  'Отмена занятия освобождает слот для добавления в группу'
);


-- 10. Служебная таблица закрыта на запись ------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-cccc-cccc-cccc-cccccccccccc');
set local role authenticated;

select throws_ok(
  $q$ insert into public.lesson_participants (lesson_id, student_id, center_id, starts_at, ends_at)
      values ('44444444-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000002',
              'cccccccc-cccc-cccc-cccc-cccccccccccc','2026-11-01 10:00+06','2026-11-01 10:45+06') $q$,
  '42501', null, 'В lesson_participants не может писать даже владелец центра'
);


-- 11–12. Серия целиком или никак ---------------------------------------------

select is(
  (select count(*)::int from public.create_lesson_series_preview(
     jsonb_build_object(
       'service_id','99999999-0000-0000-0000-000000000001',
       'teacher_id','aaaaaaaa-0000-0000-0000-000000000001',
       'student_id','eeeeeeee-0000-0000-0000-000000000001',
       'first_date','2026-10-05','until','2026-10-05','time','10:00','weekdays', '[1]'::jsonb))
   where jsonb_array_length(conflicts) > 0),
  1,
  'Предпросмотр серии показывает занятый слот'
);

select throws_ok(
  $q$ select * from public.create_lesson_series(
        jsonb_build_object(
          'service_id','99999999-0000-0000-0000-000000000001',
          'teacher_id','aaaaaaaa-0000-0000-0000-000000000001',
          'student_id','eeeeeeee-0000-0000-0000-000000000001',
          'first_date','2026-10-05','until','2026-10-12','time','10:00','weekdays','[1]'::jsonb)) $q$,
  '23P01', null, 'Серия с конфликтом не создаётся целиком'
);

reset role;

select is(
  (select count(*)::int from public.lessons where series_id is not null),
  0,
  'После неудачной серии не осталось ни одного занятия'
);


-- 13–14. Переходы статусов у специалиста -------------------------------------

update public.lessons set status = 'done' where id = '44444444-0000-0000-0000-000000000001';

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-cccc-cccc-cccc-cccccccccccc');
set local role authenticated;

select throws_ok(
  $q$ select public.mark_lesson_status('44444444-0000-0000-0000-000000000001','planned') $q$,
  '42501', null, 'Специалист не может переоткрыть закрытое занятие'
);

select throws_ok(
  $q$ insert into public.lessons (center_id, teacher_id, student_id, starts_at, ends_at)
      values ('cccccccc-cccc-cccc-cccc-cccccccccccc','aaaaaaaa-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000001','2026-12-01 10:00+06','2026-12-01 10:45+06') $q$,
  '42501', null, 'Специалист не может создать занятие'
);

reset role;


-- 15. Родитель видит только занятия своих детей ------------------------------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-cccc-cccc-cccc-cccccccccccc');
set local role authenticated;

select is(
  (select count(*)::int from public.lessons l
    join public.lesson_participants lp on lp.lesson_id = l.id
   where lp.student_id = 'eeeeeeee-0000-0000-0000-000000000002'),
  0,
  'Родитель не видит занятий чужого ребёнка'
);

reset role;


-- 16. Часовой пояс серии ------------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-cccc-cccc-cccc-cccccccccccc');
set local role authenticated;

select isnt(
  (select starts_at from public.series_dates(
     jsonb_build_object('first_date','2026-11-02','until','2026-11-02','time','10:00',
                        'weekdays','[1]'::jsonb,'timezone','Asia/Bishkek')) limit 1),
  (select starts_at from public.series_dates(
     jsonb_build_object('first_date','2026-11-02','until','2026-11-02','time','10:00',
                        'weekdays','[1]'::jsonb,'timezone','Europe/Moscow')) limit 1),
  'Одно локальное время в разных поясах даёт разные моменты UTC'
);

reset role;

select * from finish();

rollback;
