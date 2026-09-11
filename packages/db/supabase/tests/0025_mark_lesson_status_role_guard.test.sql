-- pgTAP: mark_lesson_status при отозванном членстве (миграция 0025).
--
-- Продолжение 0011_role_guards.test.sql: там те же проверки для девяти RPC,
-- а mark_lesson_status в тот список не попала. Отличие от остальных девяти —
-- у неё нет второго рубежа: emit_event стоит под `if p_status = 'cancelled'`,
-- поэтому 'done' и 'planned' сохранялись молча, без отката.
--
-- Ключевая проверка — не только «пришло 42501», но и «занятие не изменилось»:
-- до 0025 исключения не было вовсе, и по одному errcode регрессия не видна.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(8);

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-0025@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher-0025@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','revoked-0025@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings)
values ('cccccccc-0025-0000-0000-00000000000a','Центр 0025','centr-0025','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0025-0000-0000-000000000001','cccccccc-0025-0000-0000-00000000000a','Препод А'),
  ('aaaaaaaa-0025-0000-0000-000000000002','cccccccc-0025-0000-0000-00000000000a','Препод Б');

insert into public.payers (id, center_id, full_name, phone)
values ('bbbbbbbb-0025-0000-0000-000000000001','cccccccc-0025-0000-0000-00000000000a','Иванова А.','+996700250001');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id)
values ('eeeeeeee-0025-0000-0000-000000000001','cccccccc-0025-0000-0000-00000000000a','Данияр',
        'bbbbbbbb-0025-0000-0000-000000000001','aaaaaaaa-0025-0000-0000-000000000001');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin)
values ('99999999-0025-0000-0000-000000000001','cccccccc-0025-0000-0000-00000000000a','Индивидуальное',45,50000);

-- Членство есть у владельца и специалиста. Отозванный (6666) — без строки:
-- JWT живой, center_id в нём остался, прав нет.
insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0025-0000-0000-00000000000a','owner',   null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0025-0000-0000-00000000000a','teacher','aaaaaaaa-0025-0000-0000-000000000001');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

-- Три занятия завтра, время разное: lessons_teacher_no_overlap не даёт
-- поставить одному преподу два пересекающихся. L1 и L2 — препода А (его ведёт
-- specialist 3333), L3 — препода Б, он для проверки «чужое занятие».
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at) values
  ('44444444-0025-0000-0000-000000000001','cccccccc-0025-0000-0000-00000000000a',
   '99999999-0025-0000-0000-000000000001','aaaaaaaa-0025-0000-0000-000000000001',
   'eeeeeeee-0025-0000-0000-000000000001', now() + interval '1 day', now() + interval '1 day' + interval '45 min'),
  ('44444444-0025-0000-0000-000000000002','cccccccc-0025-0000-0000-00000000000a',
   '99999999-0025-0000-0000-000000000001','aaaaaaaa-0025-0000-0000-000000000001',
   'eeeeeeee-0025-0000-0000-000000000001', now() + interval '1 day 2 hours', now() + interval '1 day 2 hours' + interval '45 min'),
  ('44444444-0025-0000-0000-000000000003','cccccccc-0025-0000-0000-00000000000a',
   '99999999-0025-0000-0000-000000000001','aaaaaaaa-0025-0000-0000-000000000002',
   'eeeeeeee-0025-0000-0000-000000000001', now() + interval '1 day 4 hours', now() + interval '1 day 4 hours' + interval '45 min');


-- 1-4. Отозванное членство при живом JWT ---------------------------------------

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0025-0000-0000-00000000000a');
set local role authenticated;

-- 1. 'done' — до 0025 проходило молча: ветка teacher не срабатывала (NULL =
-- 'teacher' это NULL), elsif тоже (NULL not in (...) это NULL), а emit_event,
-- который откатил бы транзакцию, для 'done' не вызывается.
select throws_ok(
  $q$ select public.mark_lesson_status('44444444-0025-0000-0000-000000000001','done') $q$,
  '42501', 'Недостаточно прав',
  'mark_lesson_status: отозванный получает 42501 на done');

-- 2. 'planned' — тот же путь, тоже без emit_event.
select throws_ok(
  $q$ select public.mark_lesson_status('44444444-0025-0000-0000-000000000002','planned') $q$,
  '42501', 'Недостаточно прав',
  'mark_lesson_status: отозванный получает 42501 на planned');

-- 3. 'cancelled' раньше тоже отбивался, но через emit_event и с чужим текстом
-- («Нет доступа к центру»). Теперь — 42501 первой строкой, как у девяти RPC 0011.
select throws_ok(
  $q$ select public.mark_lesson_status('44444444-0025-0000-0000-000000000002','cancelled') $q$,
  '42501', 'Недостаточно прав',
  'mark_lesson_status: отозванный получает 42501 на cancelled, а не ошибку emit_event');

reset role;

-- 4. Занятия не тронуты. Проверяется ПОСЛЕ reset role: у отозванного нет
-- членства, RLS на lessons не отдаёт ему ни строки, и тот же select из-под
-- его claims вернул бы NULL — тест «прошёл бы» по неправильной причине.
-- Без этой проверки регрессия «исключение есть, но update всё равно прошёл»
-- по одному errcode не видна.
select is(
  (select string_agg(status, ',' order by id) from public.lessons
    where id in ('44444444-0025-0000-0000-000000000001',
                 '44444444-0025-0000-0000-000000000002')),
  'planned,planned',
  'Оба занятия остались planned — отозванный ничего не закрыл');


-- 5-7. Специалист: правило не сломалось -----------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0025-0000-0000-00000000000a');
set local role authenticated;

-- 5. Своё занятие закрыть может.
select lives_ok(
  $q$ select public.mark_lesson_status('44444444-0025-0000-0000-000000000001','done') $q$,
  'Специалист закрывает своё занятие');

-- 6. Вернуть в planned — нет: это работа администратора (0006:964-967).
select throws_ok(
  $q$ select public.mark_lesson_status('44444444-0025-0000-0000-000000000002','planned') $q$,
  '42501', 'Специалист может только провести или отменить занятие',
  'Специалист не возвращает занятие в planned');

-- 7. Чужое занятие — нет.
select throws_ok(
  $q$ select public.mark_lesson_status('44444444-0025-0000-0000-000000000003','done') $q$,
  '42501', 'Это занятие ведёт другой специалист',
  'Специалист не закрывает занятие чужого препода');

reset role;


-- 8. Владелец: контроль, что проверка не задела рабочий путь ---------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0025-0000-0000-00000000000a');
set local role authenticated;

select lives_ok(
  $q$ select public.mark_lesson_status('44444444-0025-0000-0000-000000000003','done') $q$,
  'Владелец закрывает любое занятие своего центра');

reset role;

select * from finish();

rollback;
