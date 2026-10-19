-- pgTAP: отработки пропусков (0105, этап 14).
--
-- Р1 политика; Р2 статус «Пропуск с отработкой» и check; Р3 выдача, отмена,
-- лимит, «туда-обратно» без 23505; Р4 запись: окно, своя группа, места,
-- права; Р5 изменения занятий; Р7 состав и клиника; Р8 отметка на отработке
-- без списания; Р9 удаление отметки; Р10 метка панели; Р11 видимость.
--
-- В одной транзакции now() постоянен: запись на прошедшее занятие-цель для
-- сценария отметки вставляется от postgres с выключенным гардом записи.
-- reset role не сбрасывает claims — tests_claims явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(52);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('01050000-0000-0000-0000-0000000000a' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0105@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 8) n;

insert into public.centers (id, name, slug, settings) values
  ('01050000-0000-0000-0000-0000000000c1', 'Школа 0105', 'centr-0105', '{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('01050000-0000-0000-0000-0000000000c3', 'Школа 0105 В', 'centr-0105-c', 'solo', now() - interval '2 days',
   '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('01050000-0000-0000-0000-0000000000b1', '01050000-0000-0000-0000-0000000000c1', 'Преподаватель А'),
  ('01050000-0000-0000-0000-0000000000b2', '01050000-0000-0000-0000-0000000000c1', 'Преподаватель Б');
insert into public.payers (id, center_id, full_name, phone) values
  ('01050000-0000-0000-0000-0000000000d1', '01050000-0000-0000-0000-0000000000c1', 'Мама 0105', '+996700010501');
insert into public.students (id, center_id, full_name, payer_id) values
  ('01050000-0000-0000-0000-000000000e01', '01050000-0000-0000-0000-0000000000c1', 'Аня 0105',  '01050000-0000-0000-0000-0000000000d1'),
  ('01050000-0000-0000-0000-000000000e02', '01050000-0000-0000-0000-0000000000c1', 'Боря 0105', '01050000-0000-0000-0000-0000000000d1'),
  ('01050000-0000-0000-0000-000000000e03', '01050000-0000-0000-0000-0000000000c1', 'Вика 0105', '01050000-0000-0000-0000-0000000000d1');

-- 1 owner · 2 admin · 3 registrar · 4 teacher А · 5 teacher Б · 6 parent · 7 finance · 8 owner readonly.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('01050000-0000-0000-0000-0000000000a1', '01050000-0000-0000-0000-0000000000c1', 'owner',     null, null),
  ('01050000-0000-0000-0000-0000000000a2', '01050000-0000-0000-0000-0000000000c1', 'admin',     null, null),
  ('01050000-0000-0000-0000-0000000000a3', '01050000-0000-0000-0000-0000000000c1', 'registrar', null, null),
  ('01050000-0000-0000-0000-0000000000a4', '01050000-0000-0000-0000-0000000000c1', 'teacher',   '01050000-0000-0000-0000-0000000000b1', null),
  ('01050000-0000-0000-0000-0000000000a5', '01050000-0000-0000-0000-0000000000c1', 'teacher',   '01050000-0000-0000-0000-0000000000b2', null),
  ('01050000-0000-0000-0000-0000000000a6', '01050000-0000-0000-0000-0000000000c1', 'parent',    null, '01050000-0000-0000-0000-0000000000d1'),
  ('01050000-0000-0000-0000-0000000000a7', '01050000-0000-0000-0000-0000000000c1', 'finance',   null, null),
  ('01050000-0000-0000-0000-0000000000a8', '01050000-0000-0000-0000-0000000000c3', 'owner',     null, null);

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('01050000-0000-0000-0000-0000000005e1', '01050000-0000-0000-0000-0000000000c1', 'Английский 0105', 50000);
insert into public.subscription_types (id, center_id, name, service_id, kind, lessons_count, price_tiyin) values
  ('01050000-0000-0000-0000-0000000007a1', '01050000-0000-0000-0000-0000000000c1', 'Английский 8', '01050000-0000-0000-0000-0000000005e1', 'lessons', 8, 400000);

-- Группа А (Аня) и группа Б (Боря, максимум 2 места).
insert into public.groups (id, center_id, name, service_id, teacher_id, max_students) values
  ('01050000-0000-0000-0000-00000000f001', '01050000-0000-0000-0000-0000000000c1', 'Группа А', '01050000-0000-0000-0000-0000000005e1', '01050000-0000-0000-0000-0000000000b1', 5),
  ('01050000-0000-0000-0000-00000000f002', '01050000-0000-0000-0000-0000000000c1', 'Группа Б', '01050000-0000-0000-0000-0000000005e1', '01050000-0000-0000-0000-0000000000b2', 2);
insert into public.group_students (center_id, group_id, student_id, joined_at) values
  ('01050000-0000-0000-0000-0000000000c1', '01050000-0000-0000-0000-00000000f001', '01050000-0000-0000-0000-000000000e01', current_date - 60),
  ('01050000-0000-0000-0000-0000000000c1', '01050000-0000-0000-0000-00000000f001', '01050000-0000-0000-0000-000000000e03', current_date - 60),
  ('01050000-0000-0000-0000-0000000000c1', '01050000-0000-0000-0000-00000000f002', '01050000-0000-0000-0000-000000000e02', current_date - 60);

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, allow_negative, lessons_used) values
  ('01050000-0000-0000-0000-0000000055a1', '01050000-0000-0000-0000-0000000000c1', '01050000-0000-0000-0000-000000000e01',
   '01050000-0000-0000-0000-0000000000d1', '01050000-0000-0000-0000-0000000007a1', 8, 400000, 50000, current_date - 30, current_date + 60, false, 0),
  ('01050000-0000-0000-0000-0000000055a3', '01050000-0000-0000-0000-0000000000c1', '01050000-0000-0000-0000-000000000e03',
   '01050000-0000-0000-0000-0000000000d1', '01050000-0000-0000-0000-0000000007a1', 8, 400000, 50000, current_date - 30, current_date + 60, false, 0);

-- Занятия: g1 — исходные пропуски в прошлом (S1..S4), своё будущее (OWN);
-- g2 — цель в прошлом для отметки (TP), цель в будущем (TF), вне срока (TX).
insert into public.lessons (id, center_id, teacher_id, service_id, group_id, status, starts_at, ends_at)
select x.id::uuid, '01050000-0000-0000-0000-0000000000c1', x.teacher::uuid, '01050000-0000-0000-0000-0000000005e1', x.grp::uuid, 'planned',
       date_trunc('hour', now()) + x.shift, date_trunc('hour', now()) + x.shift + interval '45 minutes'
  from (values
    ('01050000-0000-0000-0000-000000000101', '01050000-0000-0000-0000-0000000000b1', '01050000-0000-0000-0000-00000000f001', interval '-5 days'),
    ('01050000-0000-0000-0000-000000000102', '01050000-0000-0000-0000-0000000000b1', '01050000-0000-0000-0000-00000000f001', interval '-4 days'),
    ('01050000-0000-0000-0000-000000000103', '01050000-0000-0000-0000-0000000000b1', '01050000-0000-0000-0000-00000000f001', interval '-3 days'),
    ('01050000-0000-0000-0000-000000000104', '01050000-0000-0000-0000-0000000000b1', '01050000-0000-0000-0000-00000000f001', interval '-6 days'),
    ('01050000-0000-0000-0000-000000000105', '01050000-0000-0000-0000-0000000000b1', '01050000-0000-0000-0000-00000000f001', interval '3 days'),
    ('01050000-0000-0000-0000-000000000201', '01050000-0000-0000-0000-0000000000b2', '01050000-0000-0000-0000-00000000f002', interval '-1 day'),
    ('01050000-0000-0000-0000-000000000202', '01050000-0000-0000-0000-0000000000b2', '01050000-0000-0000-0000-00000000f002', interval '2 days'),
    ('01050000-0000-0000-0000-000000000203', '01050000-0000-0000-0000-0000000000b2', '01050000-0000-0000-0000-00000000f002', interval '40 days')
  ) as x(id, teacher, grp, shift);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create or replace function public.tests_mark(p_lesson uuid, p_student uuid, p_code text)
  returns void language sql as $$
  insert into public.attendance (center_id, lesson_id, student_id, status_id)
  values ('01050000-0000-0000-0000-0000000000c1', p_lesson, p_student,
          (select s.id from public.attendance_statuses s
            where s.center_id = '01050000-0000-0000-0000-0000000000c1' and s.code = p_code))
  on conflict (lesson_id, student_id) do update set status_id = excluded.status_id;
$$;

create or replace function public.tests_credit(p_lesson uuid)
  returns public.makeup_credits language sql as $$
  select c.* from public.makeup_credits c
    join public.attendance a on a.id = c.source_attendance_id
   where a.lesson_id = p_lesson and a.student_id = '01050000-0000-0000-0000-000000000e01' and c.cancelled_at is null;
$$;

create temporary table t_ids (name text primary key, id uuid);
grant select, insert on t_ids to authenticated;


-- 2. Статус и политика (Р1, Р2) -------------------------------------------------------------------

select ok(
  (select grants_makeup and deducts_lesson and not is_present from public.attendance_statuses
    where center_id = '01050000-0000-0000-0000-0000000000c1' and code = 'absent_makeup'),
  'Новому центру засеян «Пропуск с отработкой»: списывает, без присутствия, даёт право');
select ok(
  not (select grants_makeup from public.attendance_statuses
        where center_id = '01050000-0000-0000-0000-0000000000c1' and code = 'sick'),
  '«Болел» права на отработку не даёт');
select throws_ok(
  $$ update public.attendance_statuses set grants_makeup = true
      where center_id = '01050000-0000-0000-0000-0000000000c1' and code = 'present' $$,
  '23514', null, 'Присутствие с правом на отработку запрещено check');

select ok(
  (select deleted_at is not null from public.attendance_statuses
    where center_id = '01050000-0000-0000-0000-0000000000c1' and code = 'absent_makeup'),
  'Пока отработки выключены, «Пропуск с отработкой» в архиве — в панели отметки его нет');

select public.tests_claims('01050000-0000-0000-0000-0000000000a3', '01050000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.set_makeup_policy(14, 2) $$, '42501', null, 'Регистратор не настраивает отработки');
reset role;

select public.tests_claims('01050000-0000-0000-0000-0000000000a1', '01050000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.set_makeup_policy(0) $$, '22023', null, 'Срок 0 дней — отказ');
select lives_ok($$ select public.set_makeup_policy(14, 2) $$, 'Владелец включает отработки: 14 дней, 2 на абонемент');
reset role;
select ok(
  (select deleted_at is null from public.attendance_statuses
    where center_id = '01050000-0000-0000-0000-0000000000c1' and code = 'absent_makeup'),
  'Включение отработок достаёт статус из архива');


-- 3. Выдача и отмена права (Р3) -------------------------------------------------------------------

select public.tests_mark('01050000-0000-0000-0000-000000000101', '01050000-0000-0000-0000-000000000e01', 'absent_makeup');
select ok(
  (select c.expires_on = c.missed_on + 14 and c.subscription_id = '01050000-0000-0000-0000-0000000055a1'
          and c.price_tiyin = 50000 and c.service_id = '01050000-0000-0000-0000-0000000005e1'
     from public.tests_credit('01050000-0000-0000-0000-000000000101') c),
  'Пропуск с отработкой → право: срок +14, абонемент и цена пропуска, услуга занятия');

select public.tests_mark('01050000-0000-0000-0000-000000000101', '01050000-0000-0000-0000-000000000e01', 'present');
select is((select count(*)::int from public.makeup_credits where cancelled_at is null), 0,
  'Статус сменили на «Пришёл» — право отменено');
select lives_ok(
  $$ select public.tests_mark('01050000-0000-0000-0000-000000000101', '01050000-0000-0000-0000-000000000e01', 'absent_makeup') $$,
  'Обратно «Пропуск с отработкой» — без 23505');
select is((select count(*)::int from public.makeup_credits where cancelled_at is null), 1, 'Живое право одно');

-- Лимит 2 на абонемент: S1 (живое) + S2 = 2, S3 — без права, отметка не падает.
select public.tests_mark('01050000-0000-0000-0000-000000000102', '01050000-0000-0000-0000-000000000e01', 'absent_makeup');
select lives_ok(
  $$ select public.tests_mark('01050000-0000-0000-0000-000000000103', '01050000-0000-0000-0000-000000000e01', 'absent_makeup') $$,
  'Лимит исчерпан — отметка проходит');
select is((select count(*)::int from public.makeup_credits where cancelled_at is null), 2,
  'Лимит 2 на абонемент: третье право не выдано');

insert into t_ids select 'c1', id from public.tests_credit('01050000-0000-0000-0000-000000000101');
insert into t_ids select 'c2', id from public.tests_credit('01050000-0000-0000-0000-000000000102');


-- 4. Запись на отработку (Р4) ---------------------------------------------------------------------

select public.tests_claims('01050000-0000-0000-0000-0000000000a4', '01050000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.book_makeup((select id from t_ids where name = 'c1'), '01050000-0000-0000-0000-000000000202') $$,
  '42501', null, 'Специалист не записывает на отработку');
select is((select count(*)::int from public.makeup_credits), 0, 'Специалист не видит права на отработку');
reset role;

select public.tests_claims('01050000-0000-0000-0000-0000000000a3', '01050000-0000-0000-0000-0000000000c1');
set local role authenticated;
select ok((select count(*) from public.makeup_credits) >= 2, 'Регистратор видит права на отработку');
select ok(
  exists (select 1 from public.makeup_lesson_options((select id from t_ids where name = 'c1'))
           where lesson_id = '01050000-0000-0000-0000-000000000202')
  and not exists (select 1 from public.makeup_lesson_options((select id from t_ids where name = 'c1'))
                   where lesson_id in ('01050000-0000-0000-0000-000000000203', '01050000-0000-0000-0000-000000000105',
                                       '01050000-0000-0000-0000-000000000201')),
  'Варианты: будущий урок другой группы в сроке; без своей группы, прошлого и вне срока');
select throws_ok($$ select public.book_makeup((select id from t_ids where name = 'c1'), '01050000-0000-0000-0000-000000000203') $$,
  '22023', null, 'Занятие вне срока — отказ');
select throws_ok($$ select public.book_makeup((select id from t_ids where name = 'c1'), '01050000-0000-0000-0000-000000000201') $$,
  '22023', null, 'Прошедшее занятие — отказ');
select throws_ok($$ select public.book_makeup((select id from t_ids where name = 'c1'), '01050000-0000-0000-0000-000000000105') $$,
  '22023', 'Ученик и так в составе этого занятия', 'Своя группа — отказ');
select lives_ok($$ insert into t_ids values ('b1', public.book_makeup((select id from t_ids where name = 'c1'), '01050000-0000-0000-0000-000000000202')) $$,
  'Регистратор записывает на урок другой группы');
select throws_ok($$ select public.book_makeup((select id from t_ids where name = 'c1'), '01050000-0000-0000-0000-000000000202') $$,
  '22023', 'Эта отработка уже записана на занятие', 'Второй раз то же право — понятный отказ');
select throws_ok($$ select public.book_makeup((select id from t_ids where name = 'c2'), '01050000-0000-0000-0000-000000000202') $$,
  '22023', 'В группе нет свободных мест', 'Группа Б заполнена (Боря + запись) — отказ');
select is((select status from public.student_makeups('01050000-0000-0000-0000-000000000e01') where credit_id = (select id from t_ids where name = 'c1')),
  'booked', 'student_makeups: записанное право — booked');
reset role;

select ok(
  (select via_makeup from public.lesson_participants
    where lesson_id = '01050000-0000-0000-0000-000000000202' and student_id = '01050000-0000-0000-0000-000000000e01'),
  'Записанный — в составе урока-цели с признаком via_makeup');
select ok(
  not public.clinical_teacher_taught('01050000-0000-0000-0000-0000000000b2', '01050000-0000-0000-0000-000000000e01'),
  'Запись в чужую группу не открывает её специалисту клинику ребёнка');

select public.tests_claims('01050000-0000-0000-0000-0000000000a1', '01050000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select b.kind from public.lesson_attendance_balances('01050000-0000-0000-0000-000000000202') b
    where b.student_id = '01050000-0000-0000-0000-000000000e01'),
  'makeup', 'Метка панели — «отработка»');
select throws_ok(
  $$ insert into public.makeup_credits (center_id, student_id, source_attendance_id, missed_on, expires_on)
     values ('01050000-0000-0000-0000-0000000000c1', '01050000-0000-0000-0000-000000000e02',
             (select id from public.attendance limit 1), current_date, current_date) $$,
  '42501', null, 'Владелец не пишет права напрямую');
reset role;


-- 5. Изменение занятия-цели закрывает запись (Р5) -------------------------------------------------

update public.lessons set starts_at = starts_at + interval '1 hour', ends_at = ends_at + interval '1 hour'
 where id = '01050000-0000-0000-0000-000000000202';
select is((select closed_reason from public.makeup_bookings where id = (select id from t_ids where name = 'b1')),
  'lesson_changed', 'Перенос урока-цели закрывает запись');
select ok(
  not exists (select 1 from public.lesson_participants
               where lesson_id = '01050000-0000-0000-0000-000000000202' and student_id = '01050000-0000-0000-0000-000000000e01'),
  'После закрытия записи ребёнка нет в составе');


-- 6. Отметка на отработке без списания (Р8) -------------------------------------------------------

-- Запись на прошедший урок TP — от postgres без гарда (now() в транзакции постоянен).
alter table public.makeup_bookings disable trigger makeup_bookings_guard;
insert into public.makeup_bookings (center_id, credit_id, lesson_id, student_id)
values ('01050000-0000-0000-0000-0000000000c1', (select id from t_ids where name = 'c1'),
        '01050000-0000-0000-0000-000000000201', '01050000-0000-0000-0000-000000000e01');
alter table public.makeup_bookings enable trigger makeup_bookings_guard;

create temporary table t_used as select lessons_used from public.subscriptions where id = '01050000-0000-0000-0000-0000000055a1';

select public.tests_mark('01050000-0000-0000-0000-000000000201', '01050000-0000-0000-0000-000000000e01', 'present');
select ok(
  (select a.makeup_credit_id = (select id from t_ids where name = 'c1') and not a.deducted
          and a.subscription_id is null and a.price_tiyin = 50000
     from public.attendance a
    where a.lesson_id = '01050000-0000-0000-0000-000000000201' and a.student_id = '01050000-0000-0000-0000-000000000e01'),
  'Отметка на отработке: признак отработки, без списания, цена пропуска');
select is((select lessons_used from public.subscriptions where id = '01050000-0000-0000-0000-0000000055a1'),
  (select lessons_used from t_used), 'Абонемент не списан');
select ok((select used_attendance_id is not null from public.makeup_credits where id = (select id from t_ids where name = 'c1')),
  '«Пришёл» на отработке использует право');

select public.tests_mark('01050000-0000-0000-0000-000000000201', '01050000-0000-0000-0000-000000000e01', 'sick');
select ok((select used_attendance_id is not null from public.makeup_credits where id = (select id from t_ids where name = 'c1')),
  'Любая отметка на отработке её расходует — «Болел» не возвращает право');
select is((select count(*)::int from public.makeup_credits c
            join public.attendance a on a.id = c.source_attendance_id
           where a.lesson_id = '01050000-0000-0000-0000-000000000201'), 0,
  'Отметка на отработке нового права не выдаёт');
select public.tests_mark('01050000-0000-0000-0000-000000000201', '01050000-0000-0000-0000-000000000e01', 'present');
select ok(
  (select not a.deducted and a.subscription_id is null from public.attendance a
    where a.lesson_id = '01050000-0000-0000-0000-000000000201' and a.student_id = '01050000-0000-0000-0000-000000000e01'),
  '«Пришёл → Болел → Пришёл» на отработке — по-прежнему без списания');

select throws_ok(
  $$ select public.tests_mark('01050000-0000-0000-0000-000000000101', '01050000-0000-0000-0000-000000000e01', 'present') $$,
  '22023', null, 'Исходный пропуск с использованной отработкой не переписать');
select public.tests_claims(null, null);
select throws_ok(
  $$ delete from public.attendance where lesson_id = '01050000-0000-0000-0000-000000000201'
       and student_id = '01050000-0000-0000-0000-000000000e01' $$,
  '22023', null, 'Отметку на отработке не удалить');


-- 7. Отмена исходного занятия и архив ученика (Р5, Р6) --------------------------------------------

select throws_ok(
  $$ update public.lessons set status = 'cancelled' where id = '01050000-0000-0000-0000-000000000101' $$,
  '22023', null, 'Исходное занятие с пройденной отработкой не отменить');

update public.lessons set status = 'cancelled' where id = '01050000-0000-0000-0000-000000000201';
select ok(
  (select used_attendance_id is null from public.makeup_credits where id = (select id from t_ids where name = 'c1'))
  and not exists (select 1 from public.makeup_bookings where credit_id = (select id from t_ids where name = 'c1') and closed_at is null),
  'Отмена занятия-отработки возвращает право и закрывает запись');

update public.lessons set status = 'cancelled' where id = '01050000-0000-0000-0000-000000000102';
select is((select cancel_reason from public.makeup_credits where id = (select id from t_ids where name = 'c2')),
  'lesson_cancelled', 'Отмена исходного занятия отменяет неиспользованное право');

select public.tests_mark('01050000-0000-0000-0000-000000000104', '01050000-0000-0000-0000-000000000e03', 'absent_makeup');
update public.students set deleted_at = now() where id = '01050000-0000-0000-0000-000000000e03';
select is((select cancel_reason from public.makeup_credits c
            join public.attendance a on a.id = c.source_attendance_id
           where a.student_id = '01050000-0000-0000-0000-000000000e03'),
  'student_archived', 'Архив ученика отменяет его права');


-- 8. Права и заборы (Р11) -------------------------------------------------------------------------

-- Вступление в группу закрывает запись на её занятия.
select public.tests_claims('01050000-0000-0000-0000-0000000000a3', '01050000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_ids values ('b2', public.book_makeup((select id from t_ids where name = 'c1'), '01050000-0000-0000-0000-000000000202'));
reset role;
insert into public.group_students (center_id, group_id, student_id, joined_at) values
  ('01050000-0000-0000-0000-0000000000c1', '01050000-0000-0000-0000-00000000f002', '01050000-0000-0000-0000-000000000e01', current_date);
select is((select closed_reason from public.makeup_bookings where id = (select id from t_ids where name = 'b2')),
  'joined_group', 'Ребёнок вступил в группу — запись на её занятие закрыта');

select public.tests_claims('01050000-0000-0000-0000-0000000000a6', '01050000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.makeup_credits), 0, 'Родитель прав на отработку не видит');
reset role;

select public.tests_claims('01050000-0000-0000-0000-0000000000a7', '01050000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.makeup_bookings), 0, 'Бухгалтер записей на отработку не видит');
reset role;

select public.tests_claims('01050000-0000-0000-0000-0000000000a8', '01050000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok($$ select public.set_makeup_policy(14) $$, 'PT402', null, 'Центр только для чтения не включает отработки');
select throws_ok($$ select public.book_makeup((select id from t_ids where name = 'c1'), '01050000-0000-0000-0000-000000000202') $$,
  '42704', null, 'Чужой центр не записывает по праву центра А');
reset role;

select ok(
  not exists (
    select 1 from unnest(array['public.makeup_policies', 'public.makeup_credits', 'public.makeup_bookings']) t,
                  unnest(array['INSERT', 'UPDATE', 'DELETE']) p,
                  unnest(array['authenticated', 'service_role']) r
     where has_table_privilege(r, t, p)),
  'Три таблицы отработок пишут только функции: у authenticated и service_role записи нет');

select public.tests_claims('01050000-0000-0000-0000-0000000000a1', '01050000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok($$ select public.set_makeup_policy(null) $$, 'Владелец выключает отработки');
reset role;
select is((select count(*)::int from public.makeup_policies where disabled_at is null), 0, 'Живой политики нет');

select public.tests_claims('01050000-0000-0000-0000-0000000000a1', '01050000-0000-0000-0000-0000000000c1');
select public.tests_mark('01050000-0000-0000-0000-000000000103', '01050000-0000-0000-0000-000000000e01', 'present');
select throws_ok(
  $$ select public.tests_mark('01050000-0000-0000-0000-000000000103', '01050000-0000-0000-0000-000000000e01', 'absent_makeup') $$,
  '22023', 'Отработки выключены в настройках центра — выберите другой статус',
  'При выключенных отработках статус с правом не принимается');

select * from finish();
rollback;
