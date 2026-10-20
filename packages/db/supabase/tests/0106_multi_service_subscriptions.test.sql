-- pgTAP: абонемент на несколько услуг (0106, этап 15).
--
-- Р2 одна копия правила (covers без NULL); Р3 RPC набора: права, порядок не
-- важен, дедупликация, NULL-элементы, «любая»; Р4 порядок выбора — самый узкий;
-- Р5 инварианты: проданный тип, основная против дополнительных, прямая запись;
-- Р6 видимость. Гонку продажи и правки набора одной транзакцией не
-- воспроизвести — проверяется наличие блокировки в определении функции.
-- reset role не сбрасывает claims — tests_claims явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(38);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('01060000-0000-0000-0000-0000000000a' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0106@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 5) n;

insert into public.centers (id, name, slug, settings) values
  ('01060000-0000-0000-0000-0000000000c1', 'Центр 0106', 'centr-0106', '{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('01060000-0000-0000-0000-0000000000c2', 'Центр 0106 Б', 'centr-0106-b', 'solo', now() - interval '2 days',
   '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('01060000-0000-0000-0000-0000000000b1', '01060000-0000-0000-0000-0000000000c1', 'Специалист 0106');
insert into public.payers (id, center_id, full_name, phone) values
  ('01060000-0000-0000-0000-0000000000d1', '01060000-0000-0000-0000-0000000000c1', 'Мама 0106', '+996700010601');
insert into public.students (id, center_id, full_name, payer_id) values
  ('01060000-0000-0000-0000-000000000e01', '01060000-0000-0000-0000-0000000000c1', 'Ребёнок 0106', '01060000-0000-0000-0000-0000000000d1');

-- 1 owner · 2 registrar · 3 teacher · 4 owner readonly-центра.
insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('01060000-0000-0000-0000-0000000000a1', '01060000-0000-0000-0000-0000000000c1', 'owner',     null),
  ('01060000-0000-0000-0000-0000000000a2', '01060000-0000-0000-0000-0000000000c1', 'registrar', null),
  ('01060000-0000-0000-0000-0000000000a3', '01060000-0000-0000-0000-0000000000c1', 'teacher',   '01060000-0000-0000-0000-0000000000b1'),
  ('01060000-0000-0000-0000-0000000000a4', '01060000-0000-0000-0000-0000000000c2', 'owner',     null),
  ('01060000-0000-0000-0000-0000000000a5', '01060000-0000-0000-0000-0000000000c1', 'admin',     null);

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('01060000-0000-0000-0000-0000000005e1', '01060000-0000-0000-0000-0000000000c1', 'Логопед 0106', 50000),
  ('01060000-0000-0000-0000-0000000005e2', '01060000-0000-0000-0000-0000000000c1', 'СМК 0106',     80000),
  ('01060000-0000-0000-0000-0000000005e3', '01060000-0000-0000-0000-0000000000c1', 'Музыка 0106',  60000),
  ('01060000-0000-0000-0000-0000000005e4', '01060000-0000-0000-0000-0000000000c1', 'Архивная 0106', 60000),
  ('01060000-0000-0000-0000-0000000005e9', '01060000-0000-0000-0000-0000000000c2', 'Чужая 0106',    60000);
update public.services set deleted_at = now() where id = '01060000-0000-0000-0000-0000000005e4';

-- T1 «Логопед+СМК» (наберём RPC), T2 «Логопед», T3 «Любая», T4 — для инвариантов.
insert into public.subscription_types (id, center_id, name, service_id, kind, lessons_count, price_tiyin) values
  ('01060000-0000-0000-0000-0000000007a1', '01060000-0000-0000-0000-0000000000c1', 'Логопед+СМК 8', '01060000-0000-0000-0000-0000000005e1', 'lessons', 8, 400000),
  ('01060000-0000-0000-0000-0000000007a2', '01060000-0000-0000-0000-0000000000c1', 'Логопед 8',     '01060000-0000-0000-0000-0000000005e1', 'lessons', 8, 400000),
  ('01060000-0000-0000-0000-0000000007a3', '01060000-0000-0000-0000-0000000000c1', 'Любая 8',       '01060000-0000-0000-0000-0000000005e1', 'lessons', 8, 400000),
  ('01060000-0000-0000-0000-0000000007a4', '01060000-0000-0000-0000-0000000000c1', 'Проба 4',       '01060000-0000-0000-0000-0000000005e1', 'lessons', 4, 200000),
  ('01060000-0000-0000-0000-0000000007a5', '01060000-0000-0000-0000-0000000000c1', 'Универсальный', null,                                    'lessons', 4, 200000);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create or replace function public.tests_extras(p_type uuid)
  returns text language sql as $$
  select coalesce(string_agg(sv.name, ',' order by sv.name), '')
    from public.subscription_type_extra_services e join public.services sv on sv.id = e.service_id
   where e.type_id = p_type and e.deleted_at is null;
$$;

create or replace function public.tests_primary(p_type uuid)
  returns text language sql as $$
  select coalesce((select sv.name from public.subscription_types t join public.services sv on sv.id = t.service_id
                    where t.id = p_type), 'любая');
$$;


-- 2. RPC набора (Р3) ------------------------------------------------------------------------------

select public.tests_claims('01060000-0000-0000-0000-0000000000a2', '01060000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a1',
  array['01060000-0000-0000-0000-0000000005e1', '01060000-0000-0000-0000-0000000005e2']::uuid[]) $$,
  '42501', null, 'Регистратор не меняет набор услуг');
reset role;

select public.tests_claims('01060000-0000-0000-0000-0000000000a1', '01060000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a1',
  array['01060000-0000-0000-0000-0000000005e1', '01060000-0000-0000-0000-0000000005e2']::uuid[]) $$,
  'Владелец задаёт набор «Логопед + СМК»');
select is(public.tests_primary('01060000-0000-0000-0000-0000000007a1') || '|' || public.tests_extras('01060000-0000-0000-0000-0000000007a1'),
  'Логопед 0106|СМК 0106', 'Основная — Логопед, дополнительная — СМК');
select lives_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a1',
  array['01060000-0000-0000-0000-0000000005e2', '01060000-0000-0000-0000-0000000005e1', '01060000-0000-0000-0000-0000000005e2']::uuid[]) $$,
  'Тот же набор в другом порядке и с дублем — без ошибки');
select is(public.tests_primary('01060000-0000-0000-0000-0000000007a1') || '|' || public.tests_extras('01060000-0000-0000-0000-0000000007a1'),
  'Логопед 0106|СМК 0106', 'Тот же набор — основная не сменилась, дубля нет');
select throws_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a1',
  array['01060000-0000-0000-0000-0000000005e1', null]::uuid[]) $$,
  '22023', 'Пустая услуга в наборе', 'Пустой элемент набора — отказ');
select lives_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a3', '{}') $$,
  'Пустой набор — «любая услуга»');
select is(public.tests_primary('01060000-0000-0000-0000-0000000007a3'), 'любая', 'Тип без услуг — любая');
select throws_ok($$ insert into public.subscription_type_extra_services (center_id, type_id, service_id)
  values ('01060000-0000-0000-0000-0000000000c1', '01060000-0000-0000-0000-0000000007a2', '01060000-0000-0000-0000-0000000005e2') $$,
  '42501', null, 'Владелец не пишет дополнительные услуги напрямую');

select throws_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a4',
  array['01060000-0000-0000-0000-0000000005e1', '01060000-0000-0000-0000-0000000005e9']::uuid[]) $$,
  '42704', 'Услуга не найдена', 'Услуга чужого центра — 42704');
select throws_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a4',
  array['01060000-0000-0000-0000-0000000005e1', '01060000-0000-0000-0000-0000000005e4']::uuid[]) $$,
  '22023', 'Услуга в архиве — добавить её в набор нельзя', 'Архивную услугу в набор не добавить');
select is((select count(*)::int from public.services where id = '01060000-0000-0000-0000-0000000005e4'), 1,
  'Владелец видит архивную услугу (форма типа не снимет её молча)');

-- Смена набора у непроданного T4: {Логопед, СМК} → {СМК, Музыка} — основная СМК.
select lives_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a4',
  array['01060000-0000-0000-0000-0000000005e1', '01060000-0000-0000-0000-0000000005e2']::uuid[]) $$,
  'T4: Логопед + СМК');
select lives_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a4',
  array['01060000-0000-0000-0000-0000000005e2', '01060000-0000-0000-0000-0000000005e3']::uuid[]) $$,
  'T4: смена набора — основная уходит, СМК становится основной');
select is(public.tests_primary('01060000-0000-0000-0000-0000000007a4') || '|' || public.tests_extras('01060000-0000-0000-0000-0000000007a4'),
  'СМК 0106|Музыка 0106', 'Основная сменилась без ошибки собственных триггеров');

-- Прямой PATCH основной (грант update(service_id) остаётся).
select throws_ok($$ update public.subscription_types set service_id = '01060000-0000-0000-0000-0000000005e3'
  where id = '01060000-0000-0000-0000-0000000007a4' $$, '22023', null, 'Основная не может стать одной из дополнительных');
select throws_ok($$ update public.subscription_types set service_id = null
  where id = '01060000-0000-0000-0000-0000000007a4' $$, '22023', null, 'Основную не снять при живых дополнительных');
reset role;


select public.tests_claims('01060000-0000-0000-0000-0000000000a5', '01060000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a2',
  array['01060000-0000-0000-0000-0000000005e1']::uuid[]) $$, 'Админ тоже задаёт набор (тот же — без изменений)');
reset role;


-- 3. Видимость (Р6) -------------------------------------------------------------------------------

select public.tests_claims('01060000-0000-0000-0000-0000000000a2', '01060000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.subscription_type_extra_services where deleted_at is null), 2,
  'Регистратор видит дополнительные услуги типов');
reset role;

select public.tests_claims('01060000-0000-0000-0000-0000000000a3', '01060000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.subscription_type_extra_services), 0, 'Специалист их не видит');
reset role;


-- 4. Правило услуги (Р2) --------------------------------------------------------------------------

select ok(public.subscription_type_covers('01060000-0000-0000-0000-0000000007a1', '01060000-0000-0000-0000-0000000005e2'),
  'Логопед+СМК покрывает СМК');
select is(public.subscription_type_covers('01060000-0000-0000-0000-0000000007a1', '01060000-0000-0000-0000-0000000005e3'), false,
  'Логопед+СМК не покрывает Музыку');
select is(public.subscription_type_covers('01060000-0000-0000-0000-0000000007a1', null), false,
  'Ограниченный тип и занятие без услуги — false, не NULL');
select is(public.subscription_type_covers(gen_random_uuid(), '01060000-0000-0000-0000-0000000005e1'), false,
  'Несуществующий тип — false');
select ok(public.subscription_type_covers('01060000-0000-0000-0000-0000000007a3', null), 'Тип «любая» — и для занятия без услуги');
update public.services set deleted_at = now() where id = '01060000-0000-0000-0000-0000000005e2';
select ok(public.subscription_type_covers('01060000-0000-0000-0000-0000000007a1', '01060000-0000-0000-0000-0000000005e2'),
  'Архив услуги покрытие не снимает');
update public.services set deleted_at = null where id = '01060000-0000-0000-0000-0000000005e2';


select public.tests_claims('01060000-0000-0000-0000-0000000000a1', '01060000-0000-0000-0000-0000000000c1');
select throws_ok($$ insert into public.subscription_type_extra_services (center_id, type_id, service_id)
  values ('01060000-0000-0000-0000-0000000000c1', '01060000-0000-0000-0000-0000000007a5', '01060000-0000-0000-0000-0000000005e2') $$,
  '22023', 'Дополнительные услуги — только у типа с основной услугой', 'Гард: дополнительная у типа «любая» — отказ');
select throws_ok($$ insert into public.subscription_type_extra_services (center_id, type_id, service_id)
  values ('01060000-0000-0000-0000-0000000000c1', '01060000-0000-0000-0000-0000000007a2', '01060000-0000-0000-0000-0000000005e1') $$,
  '22023', 'Дополнительная услуга совпадает с основной', 'Гард: дополнительная равна основной — отказ');


-- 5. Продажа и порядок выбора (Р4, Р5) ------------------------------------------------------------

-- А — «Логопед+СМК» раньше, Б — «Логопед» позже; оба без срока.
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, allow_negative, lessons_used, created_at) values
  ('01060000-0000-0000-0000-0000000055a1', '01060000-0000-0000-0000-0000000000c1', '01060000-0000-0000-0000-000000000e01',
   '01060000-0000-0000-0000-0000000000d1', '01060000-0000-0000-0000-0000000007a1', 8, 400000, 50000, current_date - 30, null, false, 0, now() - interval '20 days'),
  ('01060000-0000-0000-0000-0000000055b1', '01060000-0000-0000-0000-0000000000c1', '01060000-0000-0000-0000-000000000e01',
   '01060000-0000-0000-0000-0000000000d1', '01060000-0000-0000-0000-0000000007a2', 8, 400000, 50000, current_date - 10, null, false, 0, now() - interval '5 days');

-- Второй ребёнок: «Универсальный» раньше, «Логопед» позже — Логопед со второго (Р8).
insert into public.students (id, center_id, full_name, payer_id) values
  ('01060000-0000-0000-0000-000000000e02', '01060000-0000-0000-0000-0000000000c1', 'Второй 0106', '01060000-0000-0000-0000-0000000000d1');
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, allow_negative, lessons_used, created_at) values
  ('01060000-0000-0000-0000-0000000055c1', '01060000-0000-0000-0000-0000000000c1', '01060000-0000-0000-0000-000000000e02',
   '01060000-0000-0000-0000-0000000000d1', '01060000-0000-0000-0000-0000000007a5', 4, 200000, 50000, current_date - 30, null, false, 0, now() - interval '20 days'),
  ('01060000-0000-0000-0000-0000000055c2', '01060000-0000-0000-0000-0000000000c1', '01060000-0000-0000-0000-000000000e02',
   '01060000-0000-0000-0000-0000000000d1', '01060000-0000-0000-0000-0000000007a2', 8, 400000, 50000, current_date - 10, null, false, 0, now() - interval '5 days');
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at) values
  ('01060000-0000-0000-0000-000000000201', '01060000-0000-0000-0000-0000000000c1', '01060000-0000-0000-0000-0000000000b1',
   '01060000-0000-0000-0000-0000000005e1', '01060000-0000-0000-0000-000000000e02', 'planned',
   date_trunc('hour', now()) - interval '2 days' + interval '5 hours', date_trunc('hour', now()) - interval '2 days' + interval '5 hours 45 minutes');
insert into public.attendance (center_id, lesson_id, student_id, status_id)
values ('01060000-0000-0000-0000-0000000000c1', '01060000-0000-0000-0000-000000000201', '01060000-0000-0000-0000-000000000e02',
        (select s.id from public.attendance_statuses s where s.center_id = '01060000-0000-0000-0000-0000000000c1' and s.code = 'present'));

insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at)
select x.id::uuid, '01060000-0000-0000-0000-0000000000c1', '01060000-0000-0000-0000-0000000000b1', x.svc::uuid,
       '01060000-0000-0000-0000-000000000e01', 'planned',
       date_trunc('hour', now()) - interval '2 days' + x.h * interval '1 hour',
       date_trunc('hour', now()) - interval '2 days' + x.h * interval '1 hour' + interval '45 minutes'
  from (values ('01060000-0000-0000-0000-000000000101', '01060000-0000-0000-0000-0000000005e1', 1),
               ('01060000-0000-0000-0000-000000000102', '01060000-0000-0000-0000-0000000005e2', 2),
               ('01060000-0000-0000-0000-000000000103', '01060000-0000-0000-0000-0000000005e3', 3)) x(id, svc, h);

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select '01060000-0000-0000-0000-0000000000c1', l.id, '01060000-0000-0000-0000-000000000e01',
       (select s.id from public.attendance_statuses s
         where s.center_id = '01060000-0000-0000-0000-0000000000c1' and s.code = 'present')
  from public.lessons l where l.id::text like '01060000-0000-0000-0000-00000000010_' order by l.starts_at;

select is((select subscription_id from public.attendance where lesson_id = '01060000-0000-0000-0000-000000000101'),
  '01060000-0000-0000-0000-0000000055b1'::uuid, 'Логопед списан с узкого «Логопед», а не с более раннего мульти');
select is((select subscription_id from public.attendance where lesson_id = '01060000-0000-0000-0000-000000000102'),
  '01060000-0000-0000-0000-0000000055a1'::uuid, 'СМК списан с «Логопед+СМК»');
select ok((select subscription_id is null and deducted from public.attendance where lesson_id = '01060000-0000-0000-0000-000000000103'),
  'Музыка — вне набора, в долг');
select is((select subscription_id from public.attendance where lesson_id = '01060000-0000-0000-0000-000000000201'),
  '01060000-0000-0000-0000-0000000055c2'::uuid, '«Универсальный» раньше, «Логопед» позже — списан узкий (смена порядка, Р8)');
select is((select count(*)::int from public.lesson_debt_cover_plan('01060000-0000-0000-0000-0000000055a1')), 0,
  'Покрытие долга мульти-абонементом не берёт занятие вне набора (Музыка)');

select public.tests_claims('01060000-0000-0000-0000-0000000000a1', '01060000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a1',
  array['01060000-0000-0000-0000-0000000005e1']::uuid[]) $$, '22023', null, 'У проданного типа набор не меняется');
select lives_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a1',
  array['01060000-0000-0000-0000-0000000005e2', '01060000-0000-0000-0000-0000000005e1']::uuid[]) $$,
  'Проданный тип, тот же набор в другом порядке — без ошибки (правка цены не падает)');
reset role;

select throws_ok($$ update public.subscription_type_extra_services set deleted_at = now()
  where type_id = '01060000-0000-0000-0000-0000000007a1' $$, '22023', null,
  'У проданного типа дополнительную не снять и от владельца базы');

select public.tests_claims('01060000-0000-0000-0000-0000000000a4', '01060000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_ok($$ select public.set_subscription_type_services('01060000-0000-0000-0000-0000000007a1', '{}') $$,
  'PT402', null, 'Центр только для чтения — отказ');
reset role;

select ok(
  exists (select 1 from pg_trigger t where t.tgrelid = 'public.subscriptions'::regclass
           and t.tgname = 'subscriptions_lock_type' and t.tgenabled <> 'D' and (t.tgtype & 2) = 2 and (t.tgtype & 4) = 4)
  and exists (select 1 from pg_trigger t where t.tgrelid = 'public.subscription_type_extra_services'::regclass
           and t.tgname = 'b01_extra_services_guard' and t.tgenabled <> 'D' and (t.tgtype & 2) = 2),
  'Продажа берёт блокировку типа BEFORE INSERT; гард набора — BEFORE');

select * from finish();
rollback;
