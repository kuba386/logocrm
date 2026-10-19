-- pgTAP: тип центра, модули и словарь (0104, ADR-013).
--
-- Р1 тип центра и его гард; Р2 модули: засев триггером, backfill, история
-- выключений; Р3 гард записи (с сессией и без, каскад set null — пропуск,
-- goal_stages — без гарда); Р6 видимость: restrictive-политики и definer-
-- функции клиники для teacher/parent; Р7 create_center без перегрузки.
-- reset role не сбрасывает claims — tests_claims явно перед каждым блоком.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(55);


-- 1. Справочники и заборы каталога ----------------------------------------------------------------

select is(
  (select string_agg(code, ',' order by sort) from public.center_kinds), 'speech,education',
  'Типы центров: speech, education');
select is(
  (select string_agg(kind_code || '>' || module_code, ',' order by kind_code) from public.center_kind_modules),
  'education>academic,speech>clinic', 'Стартовые модули по типу — данными');

select is(
  (select count(*)::int from public.centers c
    where not exists (select 1 from public.center_modules m
                       where m.center_id = c.id and m.module_code = 'clinic' and m.disabled_at is null)),
  0, 'Backfill: у каждого существующего центра включена «Клиника»');

select is_empty(
  $$ select g.table_name from public.module_guarded_tables() g
      where not exists (select 1 from pg_trigger t
                         where t.tgrelid = ('public.' || g.table_name)::regclass
                           and t.tgname = 'a01_module_guard' and not t.tgisinternal) $$,
  'Забор: на каждой таблице модуля стоит a01_module_guard');
select ok(
  not exists (select 1 from pg_trigger t where t.tgrelid = 'public.goal_stages'::regclass and t.tgname = 'a01_module_guard'),
  'goal_stages без гарда: этапы засеваются всем центрам раньше модулей');
select is_empty(
  $$ select g.table_name from public.module_guarded_tables() g
      where g.table_name <> 'lesson_voice_requests'
        and not exists (select 1 from pg_policies p
                         where p.schemaname = 'public' and p.tablename = g.table_name
                           and p.policyname = g.table_name || '_module_visible'
                           and p.permissive = 'RESTRICTIVE' and p.cmd = 'SELECT') $$,
  'Забор: на каждой читаемой таблице модуля — restrictive _module_visible');

select is(
  (select count(*)::int from pg_proc where proname = 'create_center' and pronamespace = 'public'::regnamespace),
  1, 'create_center без перегрузки');
select is(
  (select count(*)::int from pg_proc where proname = 'platform_create_center' and pronamespace = 'public'::regnamespace),
  1, 'platform_create_center без перегрузки');

select ok(
  not has_function_privilege('authenticated', 'public.center_has_module(uuid,text)', 'execute')
  and not has_function_privilege('anon', 'public.has_module(text)', 'execute')
  and has_function_privilege('authenticated', 'public.module_visible(text)', 'execute'),
  'center_has_module без грантов; has_module анониму закрыта; module_visible — authenticated');
select ok(
  not has_table_privilege('service_role', 'public.center_modules', 'INSERT')
  and not has_table_privilege('service_role', 'public.center_modules', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.center_modules', 'INSERT')
  and not has_table_privilege('authenticated', 'public.center_modules', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.center_modules', 'DELETE'),
  'center_modules пишут только функции: у authenticated и service_role записи нет');


-- 2. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('01040000-0000-0000-0000-0000000000a' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0104@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 9) n;

insert into public.centers (id, name, slug, settings) values
  ('01040000-0000-0000-0000-0000000000c1', 'Центр 0104 А', 'centr-0104-a', '{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, settings, kind) values
  ('01040000-0000-0000-0000-0000000000c2', 'Школа 0104 Б', 'centr-0104-b', '{"timezone":"Asia/Bishkek"}'::jsonb, 'education');
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('01040000-0000-0000-0000-0000000000c3', 'Центр 0104 В', 'centr-0104-c', 'solo', now() - interval '2 days',
   '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('01040000-0000-0000-0000-0000000000b1', '01040000-0000-0000-0000-0000000000c1', 'Специалист 0104'),
  ('01040000-0000-0000-0000-0000000000b2', '01040000-0000-0000-0000-0000000000c1', 'Уволенный 0104');
insert into public.payers (id, center_id, full_name, phone) values
  ('01040000-0000-0000-0000-0000000000d1', '01040000-0000-0000-0000-0000000000c1', 'Мама 0104', '+996700010401');
insert into public.students (id, center_id, full_name, payer_id) values
  ('01040000-0000-0000-0000-000000000e01', '01040000-0000-0000-0000-0000000000c1', 'Ребёнок 0104', '01040000-0000-0000-0000-0000000000d1'),
  ('01040000-0000-0000-0000-000000000e02', '01040000-0000-0000-0000-0000000000c1', 'Другой 0104', '01040000-0000-0000-0000-0000000000d1');

-- 1 owner А · 2 admin А · 3 teacher А · 4 parent А · 5 owner Б · 6 owner В (readonly) · 7 registrar А.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('01040000-0000-0000-0000-0000000000a1', '01040000-0000-0000-0000-0000000000c1', 'owner',     null, null),
  ('01040000-0000-0000-0000-0000000000a2', '01040000-0000-0000-0000-0000000000c1', 'admin',     null, null),
  ('01040000-0000-0000-0000-0000000000a3', '01040000-0000-0000-0000-0000000000c1', 'teacher',   '01040000-0000-0000-0000-0000000000b1', null),
  ('01040000-0000-0000-0000-0000000000a4', '01040000-0000-0000-0000-0000000000c1', 'parent',    null, '01040000-0000-0000-0000-0000000000d1'),
  ('01040000-0000-0000-0000-0000000000a5', '01040000-0000-0000-0000-0000000000c2', 'owner',     null, null),
  ('01040000-0000-0000-0000-0000000000a6', '01040000-0000-0000-0000-0000000000c3', 'owner',     null, null),
  ('01040000-0000-0000-0000-0000000000a7', '01040000-0000-0000-0000-0000000000c1', 'registrar', null, null);

-- Занятие специалиста с ребёнком — clinical_teacher_sees = true.
insert into public.lessons (id, center_id, teacher_id, student_id, status, starts_at, ends_at) values
  ('01040000-0000-0000-0000-000000000101', '01040000-0000-0000-0000-0000000000c1', '01040000-0000-0000-0000-0000000000b1',
   '01040000-0000-0000-0000-000000000e01', 'planned',
   date_trunc('hour', now()) - interval '2 days', date_trunc('hour', now()) - interval '2 days' + interval '45 minutes');

insert into public.diagnostics (id, center_id, student_id, teacher_id, conclusion) values
  ('01040000-0000-0000-0000-000000000d01', '01040000-0000-0000-0000-0000000000c1', '01040000-0000-0000-0000-000000000e01',
   '01040000-0000-0000-0000-0000000000b1', 'ОНР III уровня'),
  -- d02 ссылается только на b2 — для настоящего каскада on delete set null.
  ('01040000-0000-0000-0000-000000000d02', '01040000-0000-0000-0000-0000000000c1', '01040000-0000-0000-0000-000000000e02',
   '01040000-0000-0000-0000-0000000000b2', null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create or replace function public.tests_live_modules(p_center uuid)
  returns text language sql as $$
  select coalesce(string_agg(module_code, ',' order by module_code), '')
    from public.center_modules where center_id = p_center and disabled_at is null;
$$;


-- 3. Засев модулей и создание центра --------------------------------------------------------------

select is(public.tests_live_modules('01040000-0000-0000-0000-0000000000c1'), 'clinic', 'Прямой insert speech-центра → «Клиника»');
select is(public.tests_live_modules('01040000-0000-0000-0000-0000000000c2'), 'academic', 'Прямой insert education-центра → «Учёба», без «Клиники»');
select ok(
  (select count(*) from public.goal_stages where center_id = '01040000-0000-0000-0000-0000000000c2') > 0,
  'Этапы целей засеяны и учебному центру — включённая позже «Клиника» сможет создать цель');

-- Новые пользователи без членств: второй пробный центр владельцу запрещён
-- (memberships_one_trial_per_owner, 0052/0083).
create temporary table t_new (name text primary key, id uuid);
grant select, insert on t_new to authenticated;

select public.tests_claims('01040000-0000-0000-0000-0000000000a8', null);
set local role authenticated;
select throws_ok($$ select public.create_center('Ошибка 0104', null, 'gym') $$, '22023', 'Неизвестный тип центра',
  'Неизвестный тип центра — 22023 по-русски');
insert into t_new values ('school', public.create_center('Языковая школа 0104', 'Бишкек', 'education'));
reset role;

select public.tests_claims('01040000-0000-0000-0000-0000000000a9', null);
set local role authenticated;
insert into t_new values ('speech', public.create_center(p_name => 'Логоцентр 0104', p_city => null));
reset role;

select is(
  (select c.kind || ':' || public.tests_live_modules(c.id) from public.centers c where c.id = (select id from t_new where name = 'school')),
  'education:academic', 'create_center с типом education → «Учёба»');
select is(
  (select c.kind || ':' || public.tests_live_modules(c.id) from public.centers c where c.id = (select id from t_new where name = 'speech')),
  'speech:clinic', 'create_center с двумя аргументами по имени → speech, «Клиника»');
select is(
  (select e.payload ->> 'kind' from public.events e
    where e.type = 'center.created' and e.center_id = (select id from t_new where name = 'school')),
  'education', 'center.created несёт kind');


-- 4. set_center_module ----------------------------------------------------------------------------

select public.tests_claims('01040000-0000-0000-0000-0000000000a2', '01040000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.set_center_module('clinic', false) $$, '42501', null, 'admin не выключает модуль');
select throws_ok($$ insert into public.center_modules (center_id, module_code) values ('01040000-0000-0000-0000-0000000000c1', 'academic') $$,
  '42501', null, 'admin не пишет center_modules напрямую');
reset role;

select public.tests_claims('01040000-0000-0000-0000-0000000000a3', '01040000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.set_center_module('clinic', false) $$, '42501', null, 'Специалист не выключает модуль');
select is((select count(*)::int from public.diagnostics), 1, 'Специалист при включённой «Клинике» видит диагностику');
select ok(public.has_module('clinic'), 'has_module(clinic) = true у участника центра');
reset role;

select public.tests_claims('01040000-0000-0000-0000-0000000000a1', '01040000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.set_center_module('chess', true) $$, '42704', 'Модуль не найден', 'Несуществующий модуль — 42704');
select lives_ok($$ select public.set_center_module('clinic', false) $$, 'Владелец выключает «Клинику»');
select lives_ok($$ select public.set_center_module('clinic', false) $$, 'Повторное выключение — холостой ход');
select is((select count(*)::int from public.diagnostics), 2, 'Владелец при выключенной «Клинике» видит диагностику');
reset role;

select is(
  (select count(*)::int from public.events e
    where e.type = 'center.module_changed' and e.center_id = '01040000-0000-0000-0000-0000000000c1'),
  1, 'Два выключения подряд — одно событие');
select is(public.tests_live_modules('01040000-0000-0000-0000-0000000000c1'), '', 'Живой строки «Клиники» нет');
select ok(
  (select disabled_by = '01040000-0000-0000-0000-0000000000a1' from public.center_modules
    where center_id = '01040000-0000-0000-0000-0000000000c1' and module_code = 'clinic'),
  'Выключение — disabled_at и disabled_by, строка не удалена');


-- 5. Выключенная «Клиника»: видимость (Р6) и гард записи (Р3) -------------------------------------

select public.tests_claims('01040000-0000-0000-0000-0000000000a3', '01040000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.diagnostics), 0, 'Специалист при выключенной «Клинике» не видит диагностику');
select is((select count(*)::int from public.student_diagnostics_brief('01040000-0000-0000-0000-000000000e01')), 0,
  'student_diagnostics_brief специалисту — пусто');
select is((select count(*)::int from public.student_conclusions()), 0, 'student_conclusions специалисту — пусто');
select is((select count(*)::int from public.goal_suggestions('01040000-0000-0000-0000-000000000d01')), 0,
  'goal_suggestions специалисту — пусто');
select is((select count(*)::int from public.student_goal_dynamics_brief('01040000-0000-0000-0000-000000000e01', current_date - 30, current_date)), 0,
  'student_goal_dynamics_brief специалисту — пусто');
select ok(not public.has_module('clinic'), 'has_module(clinic) = false');
select throws_ok(
  $$ insert into public.diagnostics (center_id, student_id, teacher_id) values
       ('01040000-0000-0000-0000-0000000000c1', '01040000-0000-0000-0000-000000000e01', '01040000-0000-0000-0000-0000000000b1') $$,
  null, null, 'Специалист не пишет диагностику при выключенной «Клинике» (RLS или гард — записи нет)');
reset role;

select public.tests_claims('01040000-0000-0000-0000-0000000000a4', '01040000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.student_goals_brief('01040000-0000-0000-0000-000000000e01')), 0,
  'student_goals_brief родителю — пусто');
select throws_ok($$ select public.student_monthly_report('01040000-0000-0000-0000-000000000e01', current_date) $$,
  'PT403', null, 'student_monthly_report родителю — отказ целиком');
reset role;

-- Гард без сессии (контур бота) и под владельцем.
select public.tests_claims(null, null);
select throws_ok(
  $$ insert into public.diagnostics (center_id, student_id) values
       ('01040000-0000-0000-0000-0000000000c1', '01040000-0000-0000-0000-000000000e01') $$,
  'PT403', null, 'Гард без сессии: вставка диагностики — PT403');
select throws_ok(
  $$ update public.diagnostics set deleted_at = now() where id = '01040000-0000-0000-0000-000000000d01' $$,
  'PT403', null, 'Гард: архивация при выключенном модуле — PT403');
select throws_ok(
  $$ update public.diagnostics set conclusion = null where id = '01040000-0000-0000-0000-000000000d01' $$,
  'PT403', null, 'Прямое обнуление поля (не каскад) при выключенном модуле — PT403');
select lives_ok(
  $$ delete from public.teachers where id = '01040000-0000-0000-0000-0000000000b2' $$,
  'Настоящий каскад on delete set null при выключенном модуле — проходит');
select is(
  (select teacher_id from public.diagnostics where id = '01040000-0000-0000-0000-000000000d02'), null,
  'Каскад обнулил teacher_id у диагностики');

select public.tests_claims('01040000-0000-0000-0000-0000000000a1', '01040000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.record_diagnostic('01040000-0000-0000-0000-000000000e01', null, '{}'::jsonb, '{}'::jsonb, null, null, null, null, null) $$,
  'PT403', null, 'Владелец: RPC клиники при выключенном модуле — PT403 от гарда');
select lives_ok($$ select public.set_center_module('clinic', true) $$, 'Владелец включает «Клинику» обратно');
reset role;

select public.tests_claims('01040000-0000-0000-0000-0000000000a6', '01040000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok($$ select public.set_center_module('clinic', false) $$, 'PT402', null, 'Центр только для чтения не выключает модуль');
reset role;

select is(
  (select count(*)::int from public.center_modules where center_id = '01040000-0000-0000-0000-0000000000c1' and module_code = 'clinic'),
  2, 'История: выключенная строка и новая живая');

select public.tests_claims('01040000-0000-0000-0000-0000000000a3', '01040000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.diagnostics), 1, 'После включения специалист снова видит диагностику');
reset role;


-- 6. Тип центра -----------------------------------------------------------------------------------

select public.tests_claims('01040000-0000-0000-0000-0000000000a2', '01040000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.set_center_kind('education') $$, '42501', null, 'admin не меняет тип центра');
reset role;

select public.tests_claims('01040000-0000-0000-0000-0000000000a1', '01040000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok($$ select public.set_center_kind('education') $$, 'Владелец меняет тип центра');
select throws_ok($$ select public.set_center_kind('gym') $$, '22023', 'Неизвестный тип центра', 'Неизвестный тип — 22023');
select is((public.export_center_info() ->> 'kind'), 'education', 'export_center_info отдаёт kind');
reset role;

select is(
  (select kind || ':' || public.tests_live_modules(id) from public.centers where id = '01040000-0000-0000-0000-0000000000c1'),
  'education:clinic', 'Смена типа не трогает модули и данные');
select is(
  (select count(*)::int from public.events e
    where e.type = 'center.kind_changed' and e.center_id = '01040000-0000-0000-0000-0000000000c1'
      and e.payload ->> 'from' = 'speech' and e.payload ->> 'to' = 'education'),
  1, 'Смена типа — одно событие center.kind_changed');

select public.tests_claims('01040000-0000-0000-0000-0000000000a6', '01040000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok($$ select public.set_center_kind('education') $$, 'PT402', null, 'Центр только для чтения не меняет тип');
reset role;

select * from finish();
rollback;
