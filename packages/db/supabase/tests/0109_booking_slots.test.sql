-- pgTAP: онлайн-запись по свободным окнам и лист ожидания (0109).
--
-- Заборы: новые таблицы — только SELECT у authenticated, под readonly guard,
-- в экспорте; booking_mode вне колоночного гранта; внутренние функции не
-- исполняет ни воркер, ни витрина. Режим и часы — только owner/admin,
-- пересечение — 23P01 с русским текстом. Настройки витрины держит триггер и
-- при прямой правке. Генератор: пояс центра, isodow, окно целиком в
-- интервале, DST, занятость (отмена и удаление освобождают, замена и группа
-- занимают), lead time, горизонт, удержание заявкой 24 часа. Подача: только
-- окно генератора, одна живая заявка с номера, единый отказ. Лист ожидания:
-- повтор — тот же ответ без строки, видимость только стойке, захват при
-- записи, конечные статусы неизменны, read-only. Дайджест — раз в день, в
-- окне часов центра; event_messages — только центр события.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(145);


-- 1. Заборы по каталогу -----------------------------------------------------------------------------

select ok(
  (select bool_and(has_table_privilege('authenticated', t, 'SELECT')
                   and not has_table_privilege('authenticated', t, 'INSERT')
                   and not has_table_privilege('authenticated', t, 'UPDATE')
                   and not has_table_privilege('authenticated', t, 'DELETE'))
     from unnest(array['public.teacher_work_hours', 'public.waitlist_entries', 'public.waitlist_digest_runs']) t),
  'teacher_work_hours, waitlist_entries, waitlist_digest_runs: у authenticated только SELECT — пишут только функции');

select ok(
  (select bool_and(not has_table_privilege(r, t, 'SELECT'))
     from unnest(array['public.teacher_work_hours', 'public.waitlist_entries', 'public.booking_modes']) t,
          unnest(array['anon', 'public_booking', 'bot_worker']) r),
  'anon, public_booking и bot_worker не читают новые таблицы напрямую');

select ok(
  not has_column_privilege('authenticated', 'public.teachers', 'booking_mode', 'UPDATE'),
  'teachers.booking_mode вне колоночного гранта update — только set_teacher_booking (Р1)');

select is(
  (select count(*)::int from pg_trigger tg
    where tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal
      and tg.tgrelid in ('public.teacher_work_hours'::regclass, 'public.waitlist_entries'::regclass)),
  2, 'teacher_work_hours и waitlist_entries под readonly guard');

select set_eq(
  $$ select x.table_name from public.export_center_tables() x
      where x.table_name in ('teacher_work_hours', 'waitlist_entries', 'waitlist_digest_runs') $$,
  $$ values ('teacher_work_hours'), ('waitlist_entries') $$,
  'Часы и лист ожидания — в экспорте центра; отметка дайджеста — нет');

select ok(
  exists (select 1 from public.export_center_excluded_tables() x where x.table_name = 'waitlist_digest_runs'),
  'waitlist_digest_runs — в исключениях экспорта с причиной');

select ok(
  (select bool_and(not has_function_privilege(r, f, 'EXECUTE'))
     from unnest(array['public.booking_slots_unchecked(uuid,uuid,uuid,date,date)',
                       'public.booking_settings_unchecked(uuid)',
                       'public.waitlist_digest_at(timestamptz)']) f,
          unnest(array['public_booking', 'bot_worker', 'authenticated', 'service_role']) r),
  'Генератор, читатель настроек и дайджест не исполняет никто из прикладных ролей');


-- Фикстура -------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a1090000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0109@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a1090000-0000-0000-0000-000000000002','authenticated','authenticated','registrar-0109@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a1090000-0000-0000-0000-000000000003','authenticated','authenticated','teacher-0109@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a1090000-0000-0000-0000-000000000004','authenticated','authenticated','finance-0109@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a1090000-0000-0000-0000-000000000005','authenticated','authenticated','parent-0109@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a1090000-0000-0000-0000-000000000006','authenticated','authenticated','owner-b-0109@test.kg','','','','','','','','');

-- Центр А — тариф center: шесть карточек специалистов не влезли бы в лимит trial (0049).
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('a1090000-0000-0000-0000-0000000000c1','Центр А 0109','centr-a-0109','center', now() + interval '1 year',
   '{"timezone":"Asia/Bishkek","booking_enabled":true}'::jsonb);
insert into public.centers (id, name, slug, settings) values
  ('a1090000-0000-0000-0000-0000000000c2','Центр Б 0109 (UTC+5)','centr-b-0109','{"timezone":"Asia/Tashkent","booking_enabled":true}'::jsonb),
  ('a1090000-0000-0000-0000-0000000000c3','Центр Д 0109 (DST)','centr-d-0109','{"timezone":"Europe/Berlin","booking_enabled":true}'::jsonb);
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('a1090000-0000-0000-0000-0000000000c4','Центр Р 0109 (просрочен)','centr-r-0109','solo', now() - interval '2 days',
   '{"timezone":"Asia/Bishkek","booking_enabled":true}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id, is_active, booking_mode) values
  ('a1090000-0000-0000-0000-000000000011','a1090000-0000-0000-0000-0000000000c1','Т1 по часам','a1090000-0000-0000-0000-000000000003', true, 'any'),
  ('a1090000-0000-0000-0000-000000000012','a1090000-0000-0000-0000-0000000000c1','Т2 любое время', null, true, 'any'),
  ('a1090000-0000-0000-0000-000000000013','a1090000-0000-0000-0000-0000000000c1','Т3 закрыта', null, true, 'closed'),
  ('a1090000-0000-0000-0000-000000000014','a1090000-0000-0000-0000-0000000000c1','Т4 в архиве', null, false, 'hours'),
  ('a1090000-0000-0000-0000-000000000015','a1090000-0000-0000-0000-0000000000c1','Т5 круглые сутки', null, true, 'any'),
  ('a1090000-0000-0000-0000-000000000016','a1090000-0000-0000-0000-0000000000c1','Т6 без часов', null, true, 'any'),
  ('a1090000-0000-0000-0000-000000000017','a1090000-0000-0000-0000-0000000000c2','ТБ понедельник', null, true, 'hours'),
  ('a1090000-0000-0000-0000-000000000018','a1090000-0000-0000-0000-0000000000c3','ТД Берлин', null, true, 'hours'),
  ('a1090000-0000-0000-0000-000000000019','a1090000-0000-0000-0000-0000000000c4','ТР просрочен', null, true, 'hours');

insert into public.services (id, center_id, name, duration_min, kind, is_active) values
  ('a1090000-0000-0000-0000-000000000021','a1090000-0000-0000-0000-0000000000c1','Логопед',45,'individual', true),
  ('a1090000-0000-0000-0000-000000000022','a1090000-0000-0000-0000-0000000000c1','Группа',45,'group', true),
  ('a1090000-0000-0000-0000-000000000023','a1090000-0000-0000-0000-0000000000c1','Архивная',45,'individual', false),
  ('a1090000-0000-0000-0000-000000000024','a1090000-0000-0000-0000-0000000000c2','Логопед Б',45,'individual', true),
  ('a1090000-0000-0000-0000-000000000025','a1090000-0000-0000-0000-0000000000c3','Логопед Д',45,'individual', true),
  ('a1090000-0000-0000-0000-000000000026','a1090000-0000-0000-0000-0000000000c4','Логопед Р',45,'individual', true);

insert into public.payers (id, center_id, full_name, phone) values
  ('a1090000-0000-0000-0000-000000000031','a1090000-0000-0000-0000-0000000000c1','Мама Айбека','+996700109201'),
  ('a1090000-0000-0000-0000-000000000032','a1090000-0000-0000-0000-0000000000c1','Родитель ученика','+996700109999');
insert into public.students (id, center_id, full_name, payer_id) values
  ('a1090000-0000-0000-0000-000000000041','a1090000-0000-0000-0000-0000000000c1','Ученик 0109','a1090000-0000-0000-0000-000000000032');
insert into public.groups (id, center_id, name, service_id, teacher_id) values
  ('a1090000-0000-0000-0000-000000000051','a1090000-0000-0000-0000-0000000000c1','Группа 0109',
   'a1090000-0000-0000-0000-000000000022','a1090000-0000-0000-0000-000000000011');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a1090000-0000-0000-0000-000000000001','a1090000-0000-0000-0000-0000000000c1','owner', null, null),
  ('a1090000-0000-0000-0000-000000000002','a1090000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('a1090000-0000-0000-0000-000000000003','a1090000-0000-0000-0000-0000000000c1','teacher','a1090000-0000-0000-0000-000000000011', null),
  ('a1090000-0000-0000-0000-000000000004','a1090000-0000-0000-0000-0000000000c1','finance', null, null),
  ('a1090000-0000-0000-0000-000000000005','a1090000-0000-0000-0000-0000000000c1','parent', null,'a1090000-0000-0000-0000-000000000032'),
  ('a1090000-0000-0000-0000-000000000006','a1090000-0000-0000-0000-0000000000c2','owner', null, null),
  ('a1090000-0000-0000-0000-000000000001','a1090000-0000-0000-0000-0000000000c4','owner', null, null);

-- Часы центров Б и Д — прямо (функция проверяется на центре А).
insert into public.teacher_work_hours (center_id, teacher_id, weekday, starts_at, ends_at) values
  ('a1090000-0000-0000-0000-0000000000c2','a1090000-0000-0000-0000-000000000017', 1, '09:00', '11:00'),
  ('a1090000-0000-0000-0000-0000000000c4','a1090000-0000-0000-0000-000000000019', 1, '09:00', '18:00');
insert into public.teacher_work_hours (center_id, teacher_id, weekday, starts_at, ends_at)
select 'a1090000-0000-0000-0000-0000000000c3','a1090000-0000-0000-0000-000000000018', d, '09:00', '10:00'
  from generate_series(1, 7) d;

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

-- Локальный момент центра: сегодня центра + p_days, время p_time.
create or replace function public.t0109_at(p_center uuid, p_days integer, p_time time)
  returns timestamptz language sql stable as $$
  select ((public.center_today(p_center) + p_days) + p_time) at time zone public.center_timezone(p_center);
$$;

create or replace function public.t0109_slots(p_slug text, p_service uuid, p_teacher uuid, p_from date, p_days integer)
  returns setof timestamptz language sql stable as $$
  select s.starts_at from public.booking_free_slots(p_slug, p_service, p_teacher, p_from, p_days) s;
$$;


-- 2. Режим и часы: set_teacher_booking (Р1, Р2) -----------------------------------------------------

select public.tests_claims('a1090000-0000-0000-0000-000000000001','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;

select lives_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000011', 'hours',
        (select jsonb_agg(jsonb_build_object('weekday', d, 'starts_at', h.s, 'ends_at', h.e))
           from generate_series(1, 7) d cross join (values ('09:00', '13:00'), ('14:00', '18:00')) h(s, e))) $q$,
  'Владелец ставит Т1 режим «по часам»: каждый день 9–13 и 14–18');
select lives_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000011', 'hours',
        (select jsonb_agg(jsonb_build_object('weekday', d, 'starts_at', h.s, 'ends_at', h.e))
           from generate_series(1, 7) d cross join (values ('14:00', '18:00'), ('09:00', '13:00')) h(s, e))) $q$,
  'Повтор тех же часов в другом порядке проходит');
select lives_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000015', 'hours',
        (select jsonb_agg(jsonb_build_object('weekday', d, 'starts_at', '00:00', 'ends_at', '23:45'))
           from generate_series(1, 7) d)) $q$,
  'Т5 — круглые сутки');

select throws_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000012', 'hours',
        '[{"weekday":1,"starts_at":"09:00","ends_at":"12:00"},{"weekday":1,"starts_at":"11:00","ends_at":"13:00"}]'::jsonb) $q$,
  '23P01', 'Рабочие интервалы одного дня пересекаются',
  'Пересекающиеся интервалы одного дня — 23P01 с русским текстом');
select throws_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000012', 'hours',
        '[{"weekday":8,"starts_at":"09:00","ends_at":"12:00"}]'::jsonb) $q$,
  '22023', null, 'День недели вне 1..7 — отказ');
select throws_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000012', 'hours',
        '[{"weekday":2,"starts_at":"12:00","ends_at":"09:00"}]'::jsonb) $q$,
  '22023', null, 'Конец раньше начала — отказ');
select throws_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000012', 'sometimes', null) $q$,
  '22023', null, 'Неизвестный режим — отказ');
select throws_ok(
  $q$ insert into public.teacher_work_hours (center_id, teacher_id, weekday, starts_at, ends_at)
      values ('a1090000-0000-0000-0000-0000000000c1','a1090000-0000-0000-0000-000000000012', 1, '09:00', '10:00') $q$,
  '42501', null, 'Прямой insert в teacher_work_hours — отказ прав');
select throws_ok(
  $q$ update public.teachers set booking_mode = 'closed' where id = 'a1090000-0000-0000-0000-000000000012' $q$,
  '42501', null, 'Прямой update teachers.booking_mode — отказ прав');
reset role;

select public.tests_claims('a1090000-0000-0000-0000-000000000002','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000012', 'closed', null) $q$,
  '42501', null, 'Регистратор режим записи не меняет');
reset role;

select public.tests_claims('a1090000-0000-0000-0000-000000000003','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000011', 'any', null) $q$,
  '42501', null, 'Специалист свой режим не меняет');
reset role;
select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.teacher_work_hours where teacher_id = 'a1090000-0000-0000-0000-000000000011'),
  14, 'У Т1 четырнадцать строк часов: повтор тех же часов строк не плодит');
select is(
  (select booking_mode from public.teachers where id = 'a1090000-0000-0000-0000-000000000011'),
  'hours', 'Режим Т1 — hours');
select throws_ok(
  $q$ insert into public.teacher_work_hours (center_id, teacher_id, weekday, starts_at, ends_at)
      values ('a1090000-0000-0000-0000-0000000000c1','a1090000-0000-0000-0000-000000000011', 1, '10:00', '11:00') $q$,
  '23P01', null, 'Пересечение с живым интервалом держит EXCLUDE и мимо функции');
select lives_ok(
  $q$ insert into public.teacher_work_hours (center_id, teacher_id, weekday, starts_at, ends_at)
      values ('a1090000-0000-0000-0000-0000000000c1','a1090000-0000-0000-0000-000000000011', 1, '13:00', '14:00') $q$,
  'Касание границ — не пересечение');
update public.teacher_work_hours set deleted_at = now()
 where teacher_id = 'a1090000-0000-0000-0000-000000000011' and starts_at = '13:00';


-- 3. Видимость часов --------------------------------------------------------------------------------

select public.tests_claims('a1090000-0000-0000-0000-000000000002','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.teacher_work_hours where teacher_id = 'a1090000-0000-0000-0000-000000000011'),
  14, 'Регистратор видит часы специалиста');
reset role;
select public.tests_claims('a1090000-0000-0000-0000-000000000003','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.teacher_work_hours), 14, 'Специалист видит только свои часы');
reset role;
select public.tests_claims('a1090000-0000-0000-0000-000000000004','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.teacher_work_hours), 0, 'Бухгалтер часов не видит');
reset role;
select public.tests_claims('a1090000-0000-0000-0000-000000000005','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.teacher_work_hours), 0, 'Родитель часов не видит');
reset role;
select public.tests_claims('a1090000-0000-0000-0000-000000000006','a1090000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is((select count(*)::int from public.teacher_work_hours where center_id = 'a1090000-0000-0000-0000-0000000000c1'),
  0, 'Владелец чужого центра часов центра А не видит');
reset role;


-- 4. Настройки витрины (Р3, Б2) ---------------------------------------------------------------------

select public.tests_claims('a1090000-0000-0000-0000-000000000001','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok($q$ select public.set_booking_settings(14, 30) $q$, 'Владелец задаёт горизонт 14 и шаг 30');
select throws_ok($q$ select public.set_booking_settings(5, 30) $q$, '22023', null, 'Горизонт 5 дней — отказ');
select throws_ok($q$ select public.set_booking_settings(14, 20) $q$, '22023', null, 'Шаг 20 минут — отказ');
reset role;
select public.tests_claims('a1090000-0000-0000-0000-000000000002','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($q$ select public.set_booking_settings(14, 30) $q$, '42501', null, 'Регистратор настройки витрины не меняет');
reset role;
select public.tests_claims(null, null);

select throws_ok(
  $q$ update public.centers set settings = settings || '{"booking_horizon_days":100000}'::jsonb
       where id = 'a1090000-0000-0000-0000-0000000000c1' $q$,
  '22023', null, 'Прямая правка горизонта 100 000 дней мимо функции — отказ триггера');
select throws_ok(
  $q$ update public.centers set settings = settings || '{"booking_step_min":1}'::jsonb
       where id = 'a1090000-0000-0000-0000-0000000000c1' $q$,
  '22023', null, 'Прямая правка шага 1 минута — отказ триггера');
select throws_ok(
  $q$ update public.centers set settings = settings || '{"booking_horizon_days":"14"}'::jsonb
       where id = 'a1090000-0000-0000-0000-0000000000c1' $q$,
  '22023', null, 'Горизонт строкой — отказ (только число)');
select lives_ok(
  $q$ update public.centers set name = name || ' ' where id = 'a1090000-0000-0000-0000-0000000000c1' $q$,
  'Правка центра, не трогающая ключи, проходит');

select results_eq(
  $q$ select horizon_days, step_min from public.booking_center_info('centr-a-0109') $q$,
  $q$ values (14, 30) $q$,
  'Витрина отдаёт горизонт и шаг');
select set_eq(
  $q$ select x ->> 'full_name' from public.booking_center_info('centr-a-0109') b, jsonb_array_elements(b.teachers) x $q$,
  $q$ values ('Т1 по часам'), ('Т2 любое время'), ('Т5 круглые сутки'), ('Т6 без часов') $q$,
  'На витрине нет специалиста в режиме closed и архивного');


-- 5. Генератор окон (Р4) ----------------------------------------------------------------------------

select is(
  (select count(*)::int from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1)),
  14, 'Т1 на день: 7 окон утром (9:00–12:00) и 7 после обеда (14:00–17:00), шаг 30, 45 минут');
select is(
  (select min(s) from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1)),
  public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '09:00'),
  'Первое окно — 9:00 по Бишкеку');
select ok(
  not exists (select 1 from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1) s
     where s = public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '12:30'))
  and exists (select 1 from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1) s
     where s = public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '12:00')),
  '12:00 есть, 12:30 нет — окно не влезает в конец интервала 9–13 (и стык 13:00 теряется)');

select results_eq(
  $q$ select count(*)::int, bool_and(extract(isodow from s at time zone 'Asia/Tashkent') = 1),
             min((s at time zone 'Asia/Tashkent')::time)
        from public.t0109_slots('centr-b-0109', 'a1090000-0000-0000-0000-000000000024',
               'a1090000-0000-0000-0000-000000000017', public.center_today('a1090000-0000-0000-0000-0000000000c2') + 1, 7) s $q$,
  $q$ values (3, true, time '09:00') $q$,
  'UTC+5: часы только по понедельникам 9–11 — за неделю ровно три окна, все в понедельник, первое в 9:00 по Ташкенту');
select ok(
  (select bool_and(extract(hour from (s at time zone 'UTC')) = 4)
     from public.t0109_slots('centr-b-0109', 'a1090000-0000-0000-0000-000000000024',
            'a1090000-0000-0000-0000-000000000017', public.center_today('a1090000-0000-0000-0000-0000000000c2') + 1, 7) s
    where (s at time zone 'Asia/Tashkent')::time = '09:00'),
  '9:00 в поясе UTC+5 — 04:00 UTC, а не 03:00, как было бы по Бишкеку');
select results_eq(
  $q$ select count(*) >= 13, bool_and((s at time zone 'Europe/Berlin')::time = '09:00')
        from public.t0109_slots('centr-d-0109', 'a1090000-0000-0000-0000-000000000025',
               'a1090000-0000-0000-0000-000000000018', public.center_today('a1090000-0000-0000-0000-0000000000c3') + 1, 14) s $q$,
  $q$ values (true, true) $q$,
  'DST-зона: окно всегда в 9:00 местного времени, через переход на зимнее время тоже');

-- Занятость: занятие, отмена, удаление, замена, группа.
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('a1090000-0000-0000-0000-000000000061','a1090000-0000-0000-0000-0000000000c1','a1090000-0000-0000-0000-000000000011',
   'a1090000-0000-0000-0000-000000000041','a1090000-0000-0000-0000-000000000021','planned',
   public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '10:00'), public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '10:45'));
select is(
  (select count(*)::int from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1)),
  11, 'Занятие 10:00–10:45 занимает три окна: 9:30, 10:00, 10:30');
update public.lessons set status = 'cancelled' where id = 'a1090000-0000-0000-0000-000000000061';
select is(
  (select count(*)::int from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1)),
  14, 'Отменённое занятие окна освобождает');
update public.lessons set status = 'planned', deleted_at = now() where id = 'a1090000-0000-0000-0000-000000000061';
select is(
  (select count(*)::int from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1)),
  14, 'Удалённое занятие окна освобождает');

insert into public.lessons (id, center_id, teacher_id, substitute_teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('a1090000-0000-0000-0000-000000000062','a1090000-0000-0000-0000-0000000000c1','a1090000-0000-0000-0000-000000000012',
   'a1090000-0000-0000-0000-000000000011','a1090000-0000-0000-0000-000000000041','a1090000-0000-0000-0000-000000000021','planned',
   public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '15:00'), public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '15:45'));
select is(
  (select count(*)::int from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1)),
  11, 'Замена занимает заменяющего: Т1 на чужом занятии 15:00 — минус 14:30, 15:00, 15:30');
insert into public.lessons (id, center_id, teacher_id, group_id, service_id, status, starts_at, ends_at) values
  ('a1090000-0000-0000-0000-000000000063','a1090000-0000-0000-0000-0000000000c1','a1090000-0000-0000-0000-000000000011',
   'a1090000-0000-0000-0000-000000000051','a1090000-0000-0000-0000-000000000022','planned',
   public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '16:30'), public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '17:15'));
select is(
  (select count(*)::int from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1)),
  8, 'Групповое занятие специалиста тоже занимает: минус 16:00, 16:30, 17:00');

select ok(
  (select coalesce(bool_and(s >= now() + interval '30 minutes'), true)
     from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
            'a1090000-0000-0000-0000-000000000015', public.center_today('a1090000-0000-0000-0000-0000000000c1'), 1) s),
  'Окно раньше now + 30 минут не отдаётся (Т5 работает круглые сутки)');
select ok(
  (select min(s) from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
            'a1090000-0000-0000-0000-000000000015', public.center_today('a1090000-0000-0000-0000-0000000000c1'), 2) s)
  < now() + interval '30 minutes' + interval '61 minutes',
  'Ближайшее окно круглосуточного специалиста — не позже часа после now + 30 минут (ночной зазор 23:00–00:00)');
select lives_ok(
  $q$ select * from public.booking_free_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
        'a1090000-0000-0000-0000-000000000015', null, 2147483647) $q$,
  'p_days = int max — зажимается до горизонта, а не переполняет дату');
select is(
  (select count(*)::int from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000015', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 15, 5)),
  0, 'За горизонтом (сегодня + 15 при горизонте 14) окон нет');
select ok(
  (select count(*) > 0 from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000015', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 14, 1)),
  'Последний день горизонта (сегодня + 14) ещё отдаётся');
select ok(
  (select count(*) > 0 and bool_and(s >= now() + interval '30 minutes')
     from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
            'a1090000-0000-0000-0000-000000000015', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 10, 3) s),
  'p_from в прошлом зажимается от сегодня: отдаются только будущие окна');

-- Единый отказ (0057 Р4).
select throws_ok(
  $q$ select * from public.booking_free_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000012') $q$,
  '22023', 'Запись сейчас недоступна', 'Специалист в режиме any — окон нет, единый отказ');
select throws_ok(
  $q$ select * from public.booking_free_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000013') $q$,
  '22023', 'Запись сейчас недоступна', 'Специалист в режиме closed — единый отказ');
select throws_ok(
  $q$ select * from public.booking_free_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000014') $q$,
  '22023', 'Запись сейчас недоступна', 'Архивный специалист — единый отказ');
select throws_ok(
  $q$ select * from public.booking_free_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000022', 'a1090000-0000-0000-0000-000000000011') $q$,
  '22023', 'Запись сейчас недоступна', 'Групповая услуга — единый отказ');
select throws_ok(
  $q$ select * from public.booking_free_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000023', 'a1090000-0000-0000-0000-000000000011') $q$,
  '22023', 'Запись сейчас недоступна', 'Архивная услуга — единый отказ');
select throws_ok(
  $q$ select * from public.booking_free_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000024', 'a1090000-0000-0000-0000-000000000017') $q$,
  '22023', 'Запись сейчас недоступна', 'Услуга и специалист чужого центра при своём slug — единый отказ');
select throws_ok(
  $q$ select * from public.booking_free_slots('net-takogo-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000011') $q$,
  '22023', 'Запись сейчас недоступна', 'Неизвестный slug — единый отказ');
select throws_ok(
  $q$ select * from public.booking_free_slots('centr-r-0109', 'a1090000-0000-0000-0000-000000000026', 'a1090000-0000-0000-0000-000000000019') $q$,
  '22023', 'Запись сейчас недоступна', 'Read-only центр — единый отказ');

select throws_ok(
  $q$ select public.tests_claims('a1090000-0000-0000-0000-000000000001', 'a1090000-0000-0000-0000-0000000000c1');
      select * from public.booking_free_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000011') $q$,
  '42501', null, 'booking_free_slots с живой сессией — отказ');
select throws_ok(
  $q$ select public.tests_claims('a1090000-0000-0000-0000-000000000001', 'a1090000-0000-0000-0000-0000000000c1');
      select * from public.booking_slots_unchecked('a1090000-0000-0000-0000-0000000000c1', 'a1090000-0000-0000-0000-000000000021',
        'a1090000-0000-0000-0000-000000000011', current_date, current_date + 3) $q$,
  '42501', null, 'Генератор с живой сессией — отказ');
select public.tests_claims(null, null);


-- 6. Подача заявки в режиме hours (Р5, Р6) ------------------------------------------------------------

select lives_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000011',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '09:00'), 'Ребёнок Х', 'Родитель Х', '0700109101') $q$,
  'Заявка на окно генератора проходит');
select is(
  (select count(*)::int from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1)),
  6, 'Заявка держит окно за весь интервал: минус 9:00 и 9:30');
select throws_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000011',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '09:00'), 'Другой', 'Другая', '0700109102') $q$,
  '22023', 'Это время уже заняли — выберите другое', 'Вторая заявка на то же окно — отказ');
select throws_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000011',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '09:30'), 'Другой', 'Другая', '0700109102') $q$,
  '22023', 'Это время уже заняли — выберите другое', 'Окно, пересекающее удерживаемое, — отказ');
select throws_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000011',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '11:10'), 'Другой', 'Другая', '0700109102') $q$,
  '22023', 'Это время уже заняли — выберите другое', 'Время вне сетки (11:10) — отказ');
select throws_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000015',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 15, '09:00'), 'Другой', 'Другая', '0700109102') $q$,
  '22023', 'Это время уже заняли — выберите другое', 'Подача на горизонт + 1 день — отказ');
select is(
  public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000011',
    public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '11:00'), ' ребёнок х ', 'Родитель Х', '+996 700 10-91-01'),
  (select id from public.booking_requests where parent_phone = '+996700109101'),
  'Повтор заявки на того же ребёнка с того же номера — тот же ответ, без отказа (Р5: отказ раскрыл бы обращение)');
select is(
  (select count(*)::int from public.booking_requests where parent_phone = '+996700109101'),
  1, 'Второй строки нет');
select lives_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000011',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 5, '11:00'), 'Брат Х', 'Родитель Х', '0700109101') $q$,
  'Второй ребёнок того же родителя подаёт свою заявку');
select is(
  (select count(*)::int from public.events where type = 'booking.requested'),
  2, 'Событий — по одному на новую заявку, повтор события не дал');
select throws_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000013',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '11:00'), 'Другой', 'Другая', '0700109103') $q$,
  '22023', 'Запись сейчас недоступна', 'Специалист в режиме closed — единый отказ');
select throws_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000022', 'a1090000-0000-0000-0000-000000000012',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '11:00'), 'Другой', 'Другая', '0700109103') $q$,
  '22023', 'Запись сейчас недоступна', 'Групповая услуга — единый отказ');
select throws_ok(
  $q$ select public.submit_booking_request('centr-r-0109', 'a1090000-0000-0000-0000-000000000026', 'a1090000-0000-0000-0000-000000000019',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c4', 3, '11:00'), 'Другой', 'Другая', '0700109103') $q$,
  '22023', 'Запись сейчас недоступна', 'Read-only центр — единый отказ на подаче');

update public.booking_requests set created_at = now() - interval '25 hours' where parent_phone = '+996700109101' and child_name = 'Ребёнок Х';
select is(
  (select count(*)::int from public.t0109_slots('centr-a-0109', 'a1090000-0000-0000-0000-000000000021',
     'a1090000-0000-0000-0000-000000000011', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3, 1)),
  8, 'Заявка старше 24 часов окно больше не держит');
select is(
  (select status from public.booking_requests where parent_phone = '+996700109101' and child_name = 'Ребёнок Х'),
  'new', 'Сама заявка при этом остаётся в очереди');

-- Очистка часов и closed не возвращают «любое время» (Б3).
select public.tests_claims('a1090000-0000-0000-0000-000000000001','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000016', 'hours', '[]'::jsonb) $q$,
  'Т6: режим hours без единого интервала');
select lives_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000011', 'closed', null) $q$,
  'Т1: запись закрыта, часы не тронуты');
reset role;
select public.tests_claims(null, null);

select throws_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000016',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '10:00'), 'Другой', 'Другая', '0700109104') $q$,
  '22023', 'Это время уже заняли — выберите другое', 'Без часов в режиме hours — не «любое время», а отказ');
select throws_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000011',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 3, '11:00'), 'Другой', 'Другая', '0700109104') $q$,
  '22023', 'Запись сейчас недоступна', 'closed — отказ, а не «любое время»');
select is(
  (select count(*)::int from public.teacher_work_hours where teacher_id = 'a1090000-0000-0000-0000-000000000011' and deleted_at is null),
  14, 'Закрытие записи часы не стирает');

select public.tests_claims('a1090000-0000-0000-0000-000000000001','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select jsonb_array_length(public.set_teacher_booking('a1090000-0000-0000-0000-000000000011', 'hours',
     '[{"weekday":1,"starts_at":"09:00","ends_at":"10:00"}]'::jsonb) -> 'requests')),
  case when extract(isodow from public.center_today('a1090000-0000-0000-0000-0000000000c1') + 3) = 1 then 0 else 1 end + 1,
  'Сужение часов возвращает выпавшие живые заявки (11:00 брата не влезает в 9–10 никогда), ничего не отменяя');
select lives_ok(
  $q$ select public.set_teacher_booking('a1090000-0000-0000-0000-000000000011', 'hours',
        (select jsonb_agg(jsonb_build_object('weekday', d, 'starts_at', h.s, 'ends_at', h.e))
           from generate_series(1, 7) d cross join (values ('09:00', '13:00'), ('14:00', '18:00')) h(s, e))) $q$,
  'Т1: часы возвращены');
reset role;
select public.tests_claims(null, null);
select is(
  (select status from public.booking_requests where parent_phone = '+996700109101' and child_name = 'Ребёнок Х'),
  'new', 'Выпавшая из часов заявка не отменена');


-- 7. Лист ожидания: подача (Р7, Р8) ------------------------------------------------------------------

select lives_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', null,
        'Айбек', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 2000, '{1,3}'::smallint[], '15:00', '18:00',
        'Мама Айбека', '0700109201', 'После садика') $q$,
  'Запись в лист ожидания проходит');
select results_eq(
  $q$ select count(*)::int, min(parent_phone), min(status) from public.waitlist_entries
       where center_id = 'a1090000-0000-0000-0000-0000000000c1' $q$,
  $q$ values (1, '+996700109201', 'waiting') $q$,
  'Одна строка, телефон нормализован, статус «ждёт»');
select is((select count(*)::int from public.events where type = 'waitlist.created'), 1, 'Одно событие waitlist.created');

select lives_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', null,
        '  айбек ', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 2000, null, null, null,
        'Мама', '+996 700 10-92-01', null) $q$,
  'Повтор того же ребёнка с того же номера — тот же успешный ответ (Б4)');
select is(
  (select count(*)::int from public.waitlist_entries where center_id = 'a1090000-0000-0000-0000-0000000000c1'),
  1, 'Второй строки нет');
select is((select count(*)::int from public.events where type = 'waitlist.created'), 1, 'Второго события нет');

select lives_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000012',
        'Бегимай', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 1500, '{}'::smallint[], null, null,
        'Папа Бегимай', '0700109202', null) $q$,
  'Запись с пустым выбором дней и конкретным специалистом проходит');
select is(
  (select preferred_weekdays from public.waitlist_entries where child_name = 'Бегимай'),
  null::smallint[], 'Пустой выбор дней хранится как null — «любой день»');

select throws_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', null,
        'Будущий', public.center_today('a1090000-0000-0000-0000-0000000000c1') + 1, null, null, null, 'Мама', '0700109203', null) $q$,
  '22023', 'Проверьте дату рождения ребёнка', 'Дата рождения в будущем — отказ');
select throws_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', null,
        'Взрослый', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 365 * 30, null, null, null, 'Мама', '0700109203', null) $q$,
  '22023', 'Проверьте дату рождения ребёнка', 'Дата рождения 30 лет назад — отказ');
select throws_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', null,
        'Тимур', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 1000, null, '15:00', null, 'Мама', '0700109203', null) $q$,
  '22023', null, 'Только «с» без «до» — отказ');
select throws_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000013',
        'Тимур', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 1000, null, null, null, 'Мама', '0700109203', null) $q$,
  '22023', 'Запись сейчас недоступна', 'Специалист в режиме closed — единый отказ');
select throws_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000022', null,
        'Тимур', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 1000, null, null, null, 'Мама', '0700109203', null) $q$,
  '22023', 'Запись сейчас недоступна', 'Групповая услуга — единый отказ');
select throws_ok(
  $q$ select public.submit_waitlist_entry('centr-r-0109', 'a1090000-0000-0000-0000-000000000026', null,
        'Тимур', public.center_today('a1090000-0000-0000-0000-0000000000c4') - 1000, null, null, null, 'Мама', '0700109203', null) $q$,
  '22023', 'Запись сейчас недоступна', 'Read-only центр — единый отказ на подаче');
select throws_ok(
  $q$ select public.tests_claims('a1090000-0000-0000-0000-000000000001', 'a1090000-0000-0000-0000-0000000000c1');
      select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', null,
        'Тимур', current_date - 1000, null, null, null, 'Мама', '0700109203', null) $q$,
  '42501', null, 'submit_waitlist_entry с живой сессией — отказ');
select public.tests_claims(null, null);


-- 8. Лист ожидания: видимость и прямая запись -------------------------------------------------------

select public.tests_claims('a1090000-0000-0000-0000-000000000002','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.waitlist_entries), 2, 'Регистратор видит лист ожидания');
reset role;
select public.tests_claims('a1090000-0000-0000-0000-000000000003','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.waitlist_entries), 0, 'Специалист лист ожидания не видит');
reset role;
select public.tests_claims('a1090000-0000-0000-0000-000000000004','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.waitlist_entries), 0, 'Бухгалтер лист ожидания не видит');
reset role;
select public.tests_claims('a1090000-0000-0000-0000-000000000005','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.waitlist_entries), 0, 'Родитель лист ожидания не видит');
reset role;
select public.tests_claims('a1090000-0000-0000-0000-000000000006','a1090000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is((select count(*)::int from public.waitlist_entries), 0, 'Владелец чужого центра лист ожидания центра А не видит');
reset role;

select public.tests_claims('a1090000-0000-0000-0000-000000000001','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ insert into public.waitlist_entries (center_id, service_id, child_name, child_birth_date, parent_name, parent_phone)
      values ('a1090000-0000-0000-0000-0000000000c1', 'a1090000-0000-0000-0000-000000000021', 'Х', current_date - 1000, 'Х', '+996700109299') $q$,
  '42501', null, 'Прямой insert в waitlist_entries — отказ прав');
select throws_ok(
  $q$ update public.waitlist_entries set status = 'withdrawn' where child_name = 'Айбек' $q$,
  '42501', null, 'Прямой update waitlist_entries — отказ прав');
reset role;


-- 9. Стойка: предложить, записать, отказ (Р9) --------------------------------------------------------

select public.tests_claims('a1090000-0000-0000-0000-000000000003','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.offer_waitlist_entry((select id from public.waitlist_entries limit 1)) $q$,
  '42501', null, 'Специалист лист ожидания не разбирает');
reset role;

select public.tests_claims('a1090000-0000-0000-0000-000000000002','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
create temporary table t0109_aibek as select id from public.waitlist_entries where child_name = 'Айбек';
create temporary table t0109_begimai as select id from public.waitlist_entries where child_name = 'Бегимай';

select lives_ok($q$ select public.offer_waitlist_entry((select id from t0109_aibek)) $q$, 'Регистратор: «Предложили время»');
select ok(
  (select status = 'offered' and offered_at is not null from public.waitlist_entries where id = (select id from t0109_aibek)),
  'Статус offered, время предложения записано');
reset role;

select public.tests_claims(null, null);
select lives_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', null,
        'АЙБЕК', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 2000, null, null, null,
        'Мама', '0700109201', null) $q$,
  'Повтор, пока запись в offered, — тот же успешный ответ');
select is(
  (select count(*)::int from public.waitlist_entries where center_id = 'a1090000-0000-0000-0000-0000000000c1'),
  2, 'И снова без второй строки');

select public.tests_claims('a1090000-0000-0000-0000-000000000002','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select set_eq(
  $q$ select payer_id from public.waitlist_entry_payer_match((select id from t0109_aibek)) $q$,
  $q$ values ('a1090000-0000-0000-0000-000000000031'::uuid) $q$,
  'Предпросмотр нашёл плательщика с тем же телефоном');
select throws_ok(
  $q$ select public.enroll_waitlist_entry((select id from t0109_aibek), null) $q$,
  '22023', 'По этому номеру уже есть плательщик — выберите его в списке совпадений и запишите заново',
  'Без выбора плательщика при совпадении телефона — понятная ошибка, без привязки');
select is(
  (select status from public.waitlist_entries where id = (select id from t0109_aibek)),
  'offered', 'После ошибки запись не тронута');

create temporary table t0109_enrolled as
  select public.enroll_waitlist_entry((select id from t0109_aibek), 'a1090000-0000-0000-0000-000000000031') as student_id;
select ok(
  (select w.status = 'enrolled' and w.converted_student_id = e.student_id and w.decided_at is not null
     from public.waitlist_entries w, t0109_enrolled e where w.id = (select id from t0109_aibek)),
  'Запись — enrolled, ученик привязан');
select results_eq(
  $q$ select s.payer_id, s.birth_date, s.funnel_stage, s.source from public.students s
       where s.id = (select student_id from t0109_enrolled) $q$,
  $q$ values ('a1090000-0000-0000-0000-000000000031'::uuid, public.center_today('a1090000-0000-0000-0000-0000000000c1') - 2000, 'lead', 'waitlist') $q$,
  'Ученик — с выбранным плательщиком, датой рождения из записи, этап lead');
select throws_ok(
  $q$ select public.enroll_waitlist_entry((select id from t0109_aibek), 'a1090000-0000-0000-0000-000000000031') $q$,
  '22023', 'Запись уже обработана', 'Повторная запись — «уже обработана», второго ученика нет');
select lives_ok($q$ select public.withdraw_waitlist_entry((select id from t0109_begimai), 'Нашли другой центр') $q$,
  'Регистратор: «Отказался»');
select ok(
  (select status = 'withdrawn' and decided_at is not null and withdraw_reason = 'Нашли другой центр'
     from public.waitlist_entries where id = (select id from t0109_begimai)),
  'Статус withdrawn с причиной');
select throws_ok($q$ select public.offer_waitlist_entry((select id from t0109_begimai)) $q$,
  '22023', 'Запись уже обработана', 'Закрытую запись не предложить');
reset role;
select public.tests_claims(null, null);

select throws_ok(
  $q$ update public.waitlist_entries set comment = 'правка' where id = (select id from t0109_aibek) $q$,
  '22023', 'Запись листа ожидания уже закрыта', 'Конечный статус неизменен и мимо функций');
insert into public.waitlist_entries (center_id, service_id, child_name, child_birth_date, parent_name, parent_phone, status, offered_at)
values ('a1090000-0000-0000-0000-0000000000c1', 'a1090000-0000-0000-0000-000000000021', 'Тимур',
        current_date - 1000, 'Мама Тимура', '+996700109203', 'offered', now());
select throws_ok(
  $q$ update public.waitlist_entries set status = 'waiting', offered_at = null where child_name = 'Тимур' $q$,
  '22023', null, 'Переход offered → waiting запрещён триггером');
select throws_ok(
  $q$ update public.waitlist_entries set status = 'enrolled', decided_at = now() where child_name = 'Тимур' $q$,
  '23514', null, 'enrolled без ученика — CHECK');
select throws_ok(
  $q$ insert into public.waitlist_entries (center_id, service_id, child_name, child_birth_date, parent_name, parent_phone, preferred_weekdays)
      values ('a1090000-0000-0000-0000-0000000000c1', 'a1090000-0000-0000-0000-000000000021', 'Пусто', current_date - 1000,
              'Мама', '+996700109204', '{}') $q$,
  '23514', null, 'Пустой массив дней — CHECK');
select throws_ok(
  $q$ insert into public.waitlist_entries (center_id, service_id, child_name, child_birth_date, parent_name, parent_phone)
      values ('a1090000-0000-0000-0000-0000000000c1', 'a1090000-0000-0000-0000-000000000021', 'Номер', current_date - 1000,
              'Мама', '0700109205') $q$,
  '23514', null, 'Ненормализованный телефон — CHECK');

-- Read-only центр: стойка получает PT402.
insert into public.waitlist_entries (id, center_id, service_id, child_name, child_birth_date, parent_name, parent_phone)
values ('a1090000-0000-0000-0000-000000000071', 'a1090000-0000-0000-0000-0000000000c4', 'a1090000-0000-0000-0000-000000000026',
        'Ребёнок Р', current_date - 1000, 'Мама Р', '+996700109401');
select public.tests_claims('a1090000-0000-0000-0000-000000000001','a1090000-0000-0000-0000-0000000000c4');
set local role authenticated;
select throws_ok(
  $q$ select public.offer_waitlist_entry('a1090000-0000-0000-0000-000000000071') $q$,
  'PT402', null, 'Read-only центр: стойка лист ожидания не разбирает (PT402)');
reset role;


-- 10. «Отклонить всё с этого номера» (Р11) ----------------------------------------------------------

select public.tests_claims(null, null);
select lives_ok(
  $q$ select public.submit_booking_request('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', 'a1090000-0000-0000-0000-000000000011',
        public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 4, '11:00'), 'Спам', 'Спам', '0700109301') $q$,
  'Заявка с номера для отклонения');
select lives_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', null,
        'Спам', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 1000, null, null, null, 'Спам', '0700109301', null) $q$,
  'Лист ожидания с того же номера');
select public.tests_claims('a1090000-0000-0000-0000-000000000002','a1090000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  public.decline_booking_phone((select id from public.booking_requests where parent_phone = '+996700109301'), null),
  2, 'Отклонено всё с номера: заявка и запись листа ожидания');
reset role;
select public.tests_claims(null, null);
select ok(
  (select r.status = 'declined' and w.status = 'withdrawn'
     from public.booking_requests r, public.waitlist_entries w
    where r.parent_phone = '+996700109301' and w.parent_phone = '+996700109301'),
  'Заявка — declined, лист ожидания — withdrawn');


-- 11. Дайджест и доставка (Р10, Б6) -----------------------------------------------------------------

select lives_ok(
  $q$ select public.submit_waitlist_entry('centr-a-0109', 'a1090000-0000-0000-0000-000000000021', null,
        'Дана', public.center_today('a1090000-0000-0000-0000-0000000000c1') - 1200, null, null, null,
        'Мама Даны', '0700109501', 'Подозрение на дизартрию') $q$,
  'Ожидающая запись для дайджеста');

select is(
  public.waitlist_digest_at(public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 0, '12:00')),
  1, 'Дайджест в 12:00 по часам центра — одно событие (только центр А: у остальных никто не ждёт)');
select is(
  public.waitlist_digest_at(public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 0, '15:00')),
  0, 'Второй вызов в тот же день — ноль: первичный ключ waitlist_digest_runs');
select is(
  public.waitlist_digest_at(public.t0109_at('a1090000-0000-0000-0000-0000000000c1', 1, '22:00')),
  0, 'Вне окна 10–20 — ноль');
select ok(
  (select count(*) = 1 and min((payload ->> 'free_slots')::int) > 0 and min((payload ->> 'waiting')::int) = 1
     from public.events where type = 'waitlist.digest'),
  'Одно событие waitlist.digest: ждёт одна Дана (Тимур в offered, остальные закрыты — не в счёт), окон больше нуля');

select set_eq(
  $q$ select recipient_user_id::text || ':' || channel
       from public.event_messages((select max(id) from public.events where type = 'waitlist.digest')) $q$,
  $$ values ('a1090000-0000-0000-0000-000000000001:whatsapp_link'), ('a1090000-0000-0000-0000-000000000002:whatsapp_link') $$,
  'Дайджест — владельцу и регистратору, не специалисту');
select ok(
  (select bool_and(message like '%В листе ожидания 1 ребёнок.%')
     from public.event_messages((select max(id) from public.events where type = 'waitlist.digest'))),
  '{waiting} со склонением: «1 ребёнок»');

select ok(
  (select bool_and(message like '%Дана%' and message like '%+996700109501%'
                   and message not like '%дизартрию%' and message not like '%' || to_char(public.center_today('a1090000-0000-0000-0000-0000000000c1') - 1200, 'DD.MM.YYYY') || '%')
     from public.event_messages((select max(id) from public.events
                                  where type = 'waitlist.created'
                                    and (payload ->> 'entry_id')::uuid = (select id from public.waitlist_entries where child_name = 'Дана')))),
  'waitlist.created: имя и телефон есть, комментария и даты рождения нет');
select is(
  (select count(*)::int from public.event_messages((select max(id) from public.events
                                  where type = 'waitlist.created'
                                    and (payload ->> 'entry_id')::uuid = (select id from t0109_begimai)))),
  0, 'Закрытая к доставке запись — пусто');

insert into public.events (center_id, type, payload)
values ('a1090000-0000-0000-0000-0000000000c2', 'waitlist.created',
        jsonb_build_object('entry_id', (select id from public.waitlist_entries where child_name = 'Дана')));
select is(
  (select count(*)::int from public.event_messages((select max(id) from public.events
                                  where type = 'waitlist.created' and center_id = 'a1090000-0000-0000-0000-0000000000c2'))),
  0, 'Событие чужого центра с payload на запись центра А — пусто');

-- Удаление сотрудника, разбиравшего лист ожидания: каскад decided_by → null
-- проходит через триггер конечных статусов, остальное в записи не меняется.
select lives_ok(
  $q$ delete from auth.users where id = 'a1090000-0000-0000-0000-000000000002' $q$,
  'Регистратор, записавший и закрывший записи листа ожидания, удаляется');
select ok(
  (select status = 'enrolled' and decided_by is null and decided_at is not null and converted_student_id is not null
     from public.waitlist_entries where id = (select id from t0109_aibek)),
  'Запись осталась enrolled с учеником, decided_by — null');

select * from finish();
rollback;
