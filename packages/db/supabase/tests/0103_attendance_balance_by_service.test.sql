-- pgTAP: метка панели отметки с учётом услуги занятия (0103).
--
-- Жалоба KadamLogo: СМК-занятие рядом с остатком логопедического абонемента.
-- Р1 одна копия выбора: прогноз lesson_attendance_balances = абонемент,
-- который проставит отметка (несколько абонементов, заморозка, «любая
-- услуга», круг «пришёл → болел → пришёл»). Р2 виды меток. Р3 числа только
-- стойке. Р4 права. Р5 отмеченный ребёнок вне состава.
-- reset role не сбрасывает claims — tests_claims явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(35);


-- 1. Гранты ----------------------------------------------------------------------------------------

select ok(
  not has_function_privilege('anon', 'public.lesson_attendance_balances(uuid)', 'execute')
  and not has_function_privilege('public', 'public.lesson_attendance_balances(uuid)', 'execute')
  and has_function_privilege('authenticated', 'public.lesson_attendance_balances(uuid)', 'execute'),
  'lesson_attendance_balances: только authenticated');

select ok(
  not exists (
    select 1
      from unnest(array['public.attendance_subscription_candidates_unchecked(uuid,uuid,uuid,date)',
                        'public.attendance_pick_subscription_unchecked(uuid,uuid,uuid,date)']) f,
           unnest(array['public', 'anon', 'authenticated', 'service_role']) r
     where has_function_privilege(r, f, 'execute')),
  'Помощники выбора абонемента закрыты всем, включая service_role');


-- 2. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('01030000-0000-0000-0000-0000000000a' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0103@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 8) n;

insert into public.centers (id, name, slug, settings) values
  ('01030000-0000-0000-0000-0000000000c1', 'Центр 0103 А', 'centr-0103-a', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('01030000-0000-0000-0000-0000000000c2', 'Центр 0103 Б', 'centr-0103-b', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('01030000-0000-0000-0000-0000000000b1', '01030000-0000-0000-0000-0000000000c1', 'СМК 0103'),
  ('01030000-0000-0000-0000-0000000000b2', '01030000-0000-0000-0000-0000000000c1', 'Логопед 0103');

insert into public.payers (id, center_id, full_name, phone) values
  ('01030000-0000-0000-0000-0000000000d1', '01030000-0000-0000-0000-0000000000c1', 'П 0103', '+996700010301');

-- 1 owner · 2 admin · 3 registrar · 4 teacher b1 (ведёт занятия) · 5 finance · 6 parent · 7 owner Б · 8 teacher b2.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('01030000-0000-0000-0000-0000000000a1', '01030000-0000-0000-0000-0000000000c1', 'owner',     null, null),
  ('01030000-0000-0000-0000-0000000000a2', '01030000-0000-0000-0000-0000000000c1', 'admin',     null, null),
  ('01030000-0000-0000-0000-0000000000a3', '01030000-0000-0000-0000-0000000000c1', 'registrar', null, null),
  ('01030000-0000-0000-0000-0000000000a4', '01030000-0000-0000-0000-0000000000c1', 'teacher',   '01030000-0000-0000-0000-0000000000b1', null),
  ('01030000-0000-0000-0000-0000000000a5', '01030000-0000-0000-0000-0000000000c1', 'finance',   null, null),
  ('01030000-0000-0000-0000-0000000000a6', '01030000-0000-0000-0000-0000000000c1', 'parent',    null, '01030000-0000-0000-0000-0000000000d1'),
  ('01030000-0000-0000-0000-0000000000a7', '01030000-0000-0000-0000-0000000000c2', 'owner',     null, null),
  ('01030000-0000-0000-0000-0000000000a8', '01030000-0000-0000-0000-0000000000c1', 'teacher',   '01030000-0000-0000-0000-0000000000b2', null);

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('01030000-0000-0000-0000-0000000005e1', '01030000-0000-0000-0000-0000000000c1', 'Логопед 0103', 50000),
  ('01030000-0000-0000-0000-0000000005e2', '01030000-0000-0000-0000-0000000000c1', 'СМК 0103',     80000);

insert into public.subscription_types (id, center_id, name, service_id, kind, lessons_count, price_tiyin) values
  ('01030000-0000-0000-0000-0000000007a1', '01030000-0000-0000-0000-0000000000c1', 'Логопед 8 · 0103', '01030000-0000-0000-0000-0000000005e1', 'lessons', 8, 400000),
  ('01030000-0000-0000-0000-0000000007a2', '01030000-0000-0000-0000-0000000000c1', 'СМК 4 · 0103',     '01030000-0000-0000-0000-0000000005e2', 'lessons', 4, 320000),
  ('01030000-0000-0000-0000-0000000007a3', '01030000-0000-0000-0000-0000000000c1', 'Любая 4 · 0103',   null,                                    'lessons', 4, 200000);

-- e1 только логопед · e2 «любая услуга» на 1 занятие · e3 «любая» раньше кончается + СМК
-- · e4 «любая» заморожена + СМК · e5 только логопед, занятие без услуги · e6 только замороженный СМК.
insert into public.students (id, center_id, full_name, payer_id)
select ('01030000-0000-0000-0000-00000000ee0' || n)::uuid, '01030000-0000-0000-0000-0000000000c1',
       'Ребёнок ' || n || ' 0103', '01030000-0000-0000-0000-0000000000d1'
  from generate_series(1, 6) n;

-- Занятия СМК (кроме L5 — без услуги) двое суток назад, ведёт b1.
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at)
select ('01030000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid, '01030000-0000-0000-0000-0000000000c1',
       '01030000-0000-0000-0000-0000000000b1',
       case when n = 5 then null else '01030000-0000-0000-0000-0000000005e2'::uuid end,
       ('01030000-0000-0000-0000-00000000ee0' || n)::uuid, 'planned',
       date_trunc('hour', now()) - interval '2 days' + n * interval '1 hour',
       date_trunc('hour', now()) - interval '2 days' + n * interval '1 hour' + interval '45 minutes'
  from generate_series(1, 6) n;

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, allow_negative, lessons_used) values
  ('01030000-0000-0000-0000-0000000055a1', '01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-00000000ee01',
   '01030000-0000-0000-0000-0000000000d1', '01030000-0000-0000-0000-0000000007a1', 8, 400000, 50000, current_date - 10, current_date + 60, false, 0),
  ('01030000-0000-0000-0000-0000000055a2', '01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-00000000ee02',
   '01030000-0000-0000-0000-0000000000d1', '01030000-0000-0000-0000-0000000007a3', 1, 50000, 50000, current_date - 10, current_date + 60, false, 0),
  ('01030000-0000-0000-0000-0000000055a3', '01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-00000000ee03',
   '01030000-0000-0000-0000-0000000000d1', '01030000-0000-0000-0000-0000000007a2', 4, 320000, 80000, current_date - 10, current_date + 60, false, 0),
  ('01030000-0000-0000-0000-0000000055b3', '01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-00000000ee03',
   '01030000-0000-0000-0000-0000000000d1', '01030000-0000-0000-0000-0000000007a3', 4, 200000, 50000, current_date - 10, current_date + 20, false, 0),
  ('01030000-0000-0000-0000-0000000055a4', '01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-00000000ee04',
   '01030000-0000-0000-0000-0000000000d1', '01030000-0000-0000-0000-0000000007a2', 4, 320000, 80000, current_date - 10, current_date + 60, false, 0),
  ('01030000-0000-0000-0000-0000000055b4', '01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-00000000ee04',
   '01030000-0000-0000-0000-0000000000d1', '01030000-0000-0000-0000-0000000007a3', 4, 200000, 50000, current_date - 10, current_date + 20, false, 0),
  ('01030000-0000-0000-0000-0000000055a5', '01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-00000000ee05',
   '01030000-0000-0000-0000-0000000000d1', '01030000-0000-0000-0000-0000000007a1', 8, 400000, 50000, current_date - 10, current_date + 60, false, 0),
  ('01030000-0000-0000-0000-0000000055a6', '01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-00000000ee06',
   '01030000-0000-0000-0000-0000000000d1', '01030000-0000-0000-0000-0000000007a2', 4, 320000, 80000, current_date - 10, current_date + 60, false, 0);

insert into public.subscription_freezes (center_id, subscription_id, period) values
  ('01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-0000000055b4', daterange(current_date - 5, current_date + 5)),
  ('01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-0000000055a6', daterange(current_date - 5, current_date + 5));

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create or replace function public.tests_lesson(n integer)
  returns uuid language sql immutable as $$
  select ('01030000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid;
$$;

-- Метка ребёнка n на его занятии: (kind, lessons_left, price_tiyin).
create or replace function public.tests_label(n integer)
  returns text language sql as $$
  select row(b.kind, b.lessons_left, b.price_tiyin)::text
    from public.lesson_attendance_balances(public.tests_lesson(n)) b
   where b.student_id = ('01030000-0000-0000-0000-00000000ee0' || n)::uuid;
$$;

create or replace function public.tests_status(p_code text)
  returns uuid language sql as $$
  select s.id from public.attendance_statuses s
   where s.center_id = '01030000-0000-0000-0000-0000000000c1' and s.code = p_code;
$$;

create or replace function public.tests_mark(n integer, p_code text)
  returns void language sql as $$
  insert into public.attendance (center_id, lesson_id, student_id, status_id)
  values ('01030000-0000-0000-0000-0000000000c1', public.tests_lesson(n),
          ('01030000-0000-0000-0000-00000000ee0' || n)::uuid, public.tests_status(p_code))
  on conflict (lesson_id, student_id) do update set status_id = excluded.status_id;
$$;

create or replace function public.tests_charged(n integer)
  returns uuid language sql as $$
  select a.subscription_id from public.attendance a
   where a.lesson_id = public.tests_lesson(n) and a.student_id = ('01030000-0000-0000-0000-00000000ee0' || n)::uuid;
$$;

create or replace function public.tests_pick(n integer)
  returns uuid language sql as $$
  select p.id from public.attendance_pick_subscription_unchecked(
           '01030000-0000-0000-0000-0000000000c1', ('01030000-0000-0000-0000-00000000ee0' || n)::uuid,
           (select l.service_id from public.lessons l where l.id = public.tests_lesson(n)),
           ((select l.starts_at from public.lessons l where l.id = public.tests_lesson(n)) at time zone 'Asia/Bishkek')::date);
$$;

grant execute on function public.tests_label(integer), public.tests_lesson(integer) to authenticated;

create temporary table t_pick (n integer primary key, predicted uuid);
insert into t_pick select n, public.tests_pick(n) from generate_series(1, 6) n;


-- 3. Метки до отметки (owner) ---------------------------------------------------------------------

select public.tests_claims('01030000-0000-0000-0000-0000000000a1', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is(public.tests_label(1), '(no_subscription,,80000)',
  'Логопедический абонемент на СМК-занятии не показывается: «нет абонемента», цена услуги СМК');
select is(public.tests_label(2), '(subscription_low,1,)', '«Любая услуга» подходит СМК: остаток 1');
select is(public.tests_label(3), '(subscription,4,)', 'Два подходящих: показан тот, что кончается раньше');
select is(public.tests_label(4), '(subscription,4,)', 'Замороженный на дату занятия пропущен ради незамороженного');
select is(public.tests_label(5), '(no_service,,)', 'Занятие без услуги: логопедический не подходит — «у занятия нет услуги»');
select is(public.tests_label(6), '(frozen,,)', 'Единственный подходящий заморожен на дату занятия');

reset role;


-- 4. Прогноз = факт отметки ------------------------------------------------------------------------

select is(public.tests_pick(3), '01030000-0000-0000-0000-0000000055b3'::uuid, 'pick e3: «любая», кончается раньше');
select is(public.tests_pick(4), '01030000-0000-0000-0000-0000000055a4'::uuid, 'pick e4: незамороженный СМК');

select public.tests_mark(n, 'present') from generate_series(1, 5) n;

select is(
  (select count(*)::integer from t_pick t where t.n between 1 and 5
      and t.predicted is not distinct from public.tests_charged(t.n)),
  5, 'Для e1–e5 отметка проставила ровно спрогнозированный абонемент (или долг)');

select throws_ok($$ select public.tests_mark(6, 'present') $$, '22023', null,
  'Единственный кандидат заморожен — отметка отказывает, как и обещала метка');

select is(public.subscription_lessons_left('01030000-0000-0000-0000-0000000055a1'), 8,
  'СМК-отметка e1 не тронула логопедический абонемент');


-- 5. Метки после отметки ---------------------------------------------------------------------------

select public.tests_claims('01030000-0000-0000-0000-0000000000a1', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is(public.tests_label(1), '(debt,,)', 'Отмечено без абонемента — «в долг», суммы нет');
select is(public.tests_label(2), '(charged,0,)', 'Списано с «любой»: текущий остаток 0');
select is(public.tests_label(3), '(charged,3,)', 'Списано с «любой» e3');
select is(public.tests_label(5), '(free,,)', 'Занятие без услуги отмечено по цене 0 — «бесплатно», не «в долг»');
select is((select bool_and(b.numbers) from public.lesson_attendance_balances(public.tests_lesson(1)) b), true,
  'Стойке numbers = true');

reset role;

-- Круг «пришёл → болел → пришёл»: абонемент в отметке сохраняется.
select public.tests_mark(2, 'sick');
select public.tests_claims('01030000-0000-0000-0000-0000000000a1', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(public.tests_label(2), '(subscription_low,1,)',
  '«Болел» с абонементом в отметке: показан остаток этого абонемента, а не прогноз');
reset role;
select public.tests_mark(2, 'present');
select is(public.tests_charged(2), '01030000-0000-0000-0000-0000000055a2'::uuid,
  'Обратно «Пришёл» — списано с того же абонемента');

-- Покрытие долга СМК-абонементом (0088).
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, allow_negative, lessons_used) values
  ('01030000-0000-0000-0000-0000000055c1', '01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-00000000ee01',
   '01030000-0000-0000-0000-0000000000d1', '01030000-0000-0000-0000-0000000007a2', 4, 320000, 80000, current_date, null, false, 0);

select public.tests_claims('01030000-0000-0000-0000-0000000000a1', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok($$ select public.cover_lesson_debt('01030000-0000-0000-0000-0000000055c1', 1, 80000) $$,
  'Владелец покрывает СМК-долг e1 новым СМК-абонементом');
select is(public.tests_label(1), '(covered,,)', 'Покрытый долг не показывается как «в долг»');
reset role;

-- Ребёнок выпал из состава после отметки — строка остаётся.
alter table public.lesson_participants disable trigger user;
update public.lesson_participants set deleted_at = now()
 where lesson_id = public.tests_lesson(3) and student_id = '01030000-0000-0000-0000-00000000ee03';
alter table public.lesson_participants enable trigger user;

select public.tests_claims('01030000-0000-0000-0000-0000000000a1', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(public.tests_label(3), '(charged,3,)', 'Отмеченный ребёнок вне состава занятия — в выдаче');
reset role;


-- 6. Права ------------------------------------------------------------------------------------------

select public.tests_claims('01030000-0000-0000-0000-0000000000a2', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(public.tests_label(4), '(charged,3,)', 'admin видит числа');
reset role;

select public.tests_claims('01030000-0000-0000-0000-0000000000a3', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(public.tests_label(4), '(charged,3,)', 'registrar (стойка) видит числа');
reset role;

-- Свежее СМК-занятие e2 без отметки (абонемент e2 исчерпан) — цена у специалиста.
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at) values
  ('01030000-0000-0000-0000-000000000199', '01030000-0000-0000-0000-0000000000c1', '01030000-0000-0000-0000-0000000000b1',
   '01030000-0000-0000-0000-0000000005e2', '01030000-0000-0000-0000-00000000ee02', 'planned',
   date_trunc('hour', now()) - interval '1 day', date_trunc('hour', now()) - interval '1 day' + interval '45 minutes');

select public.tests_claims('01030000-0000-0000-0000-0000000000a4', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(public.tests_label(4), '(charged,,)', 'Специалист своего занятия: вид есть, числа нет');
select is(public.tests_label(2), '(charged,,)', 'Специалист: остаток абонемента числом не отдаётся');
select is(
  (select row(b.kind, b.lessons_left, b.price_tiyin)::text
     from public.lesson_attendance_balances('01030000-0000-0000-0000-000000000199') b),
  '(no_subscription,,)',
  'Специалист: абонемент исчерпан — «нет абонемента», цена услуги не отдаётся');
select is(public.tests_label(1), '(covered,,)', 'Специалист видит вид долга, без суммы');
select is((select bool_or(b.numbers) from public.lesson_attendance_balances(public.tests_lesson(1)) b), false,
  'Специалисту numbers = false: null — «скрыто», не «безлимит»');
reset role;

select public.tests_claims('01030000-0000-0000-0000-0000000000a8', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select * from public.lesson_attendance_balances(public.tests_lesson(1)) $$, '42501', null,
  'Специалист чужого занятия — отказ');
reset role;

select public.tests_claims('01030000-0000-0000-0000-0000000000a5', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select * from public.lesson_attendance_balances(public.tests_lesson(1)) $$, '42501', null,
  'finance — отказ');
reset role;

select public.tests_claims('01030000-0000-0000-0000-0000000000a6', '01030000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select * from public.lesson_attendance_balances(public.tests_lesson(1)) $$, '42501', null,
  'Родитель — отказ');
reset role;

select public.tests_claims('01030000-0000-0000-0000-0000000000a7', '01030000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_ok($$ select * from public.lesson_attendance_balances(public.tests_lesson(1)) $$, '42704', null,
  'Владелец другого центра — «занятие не найдено»');
reset role;

select public.tests_claims('01030000-0000-0000-0000-0000000000a1', '01030000-0000-0000-0000-0000000000c1');
update public.lessons set deleted_at = now() where id = '01030000-0000-0000-0000-000000000199';
set local role authenticated;
select throws_ok($$ select * from public.lesson_attendance_balances('01030000-0000-0000-0000-000000000199') $$, '42704', null,
  'Удалённое занятие — «занятие не найдено»');
reset role;

select * from finish();
rollback;
