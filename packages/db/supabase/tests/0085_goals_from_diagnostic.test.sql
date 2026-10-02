-- pgTAP: цели из диагностики и след печати речевой карты (0085, этап 9).
--
-- Предложения: нарушенные звуки → «Постановка», «норма» не предлагается,
-- порядок р л ш ж с з ц ч щ, ключи нормализуются. Создание: выбранные через
-- create_goal, повтор — 0 без исключения, звук не из предложений и пустой
-- выбор — 22023. Индекс: второй активный дубль (регистр, пробелы) — 23505, на
-- паузе — можно; снять с паузы при живом дубле — 23505 (старый путь
-- set_goal_status). Цель по звуку на другом этапе — existing_*, не блок.
-- Права: owner, специалист ученика — да; чужой специалист, родитель,
-- бухгалтер, регистратор — 42501; чужой центр, архивный ученик — 42704.
-- След печати — событие с student_id/by/role. Центр без живого этапа
-- «Постановка» — пустой набор и 22023 на создание.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(29);


-- Фикстура ---------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('85000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0085@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 8) n;

insert into public.centers (id, name, slug, settings) values
  ('85000000-0000-0000-0000-0000000000c1','Центр А 0085','centr-a-0085','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('85000000-0000-0000-0000-0000000000c2','Центр Б 0085','centr-b-0085','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('85000000-0000-0000-0000-0000000000a1','85000000-0000-0000-0000-0000000000c1','Специалист 0085',  '85000000-0000-0000-0000-000000000002'),
  ('85000000-0000-0000-0000-0000000000a2','85000000-0000-0000-0000-0000000000c1','Специалист 2 0085','85000000-0000-0000-0000-000000000003');

insert into public.payers (id, center_id, full_name, phone) values
  ('85000000-0000-0000-0000-0000000000d1','85000000-0000-0000-0000-0000000000c1','Плательщик 0085','+996700008501'),
  ('85000000-0000-0000-0000-0000000000db','85000000-0000-0000-0000-0000000000c2','Плательщик Б 0085','+996700008502');

-- 1 owner А · 2 teacher (ведёт ребёнка 1) · 3 teacher (без занятий) · 4 parent ·
-- 5 finance · 6 registrar · 7 owner Б.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('85000000-0000-0000-0000-000000000001','85000000-0000-0000-0000-0000000000c1','owner',     null, null),
  ('85000000-0000-0000-0000-000000000002','85000000-0000-0000-0000-0000000000c1','teacher',   '85000000-0000-0000-0000-0000000000a1', null),
  ('85000000-0000-0000-0000-000000000003','85000000-0000-0000-0000-0000000000c1','teacher',   '85000000-0000-0000-0000-0000000000a2', null),
  ('85000000-0000-0000-0000-000000000004','85000000-0000-0000-0000-0000000000c1','parent',    null, '85000000-0000-0000-0000-0000000000d1'),
  ('85000000-0000-0000-0000-000000000005','85000000-0000-0000-0000-0000000000c1','finance',   null, null),
  ('85000000-0000-0000-0000-000000000006','85000000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('85000000-0000-0000-0000-000000000007','85000000-0000-0000-0000-0000000000c2','owner',     null, null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('85000000-0000-0000-0000-0000000000e1','85000000-0000-0000-0000-0000000000c1','Ребёнок 0085','85000000-0000-0000-0000-0000000000d1'),
  ('85000000-0000-0000-0000-0000000000e2','85000000-0000-0000-0000-0000000000c1','Архивный 0085','85000000-0000-0000-0000-0000000000d1'),
  ('85000000-0000-0000-0000-0000000000eb','85000000-0000-0000-0000-0000000000c2','Ребёнок Б 0085','85000000-0000-0000-0000-0000000000db');

insert into public.services (id, center_id, name) values
  ('85000000-0000-0000-0000-000000000020','85000000-0000-0000-0000-0000000000c1','Логопед 0085');
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('85000000-0000-0000-0000-000000000050','85000000-0000-0000-0000-0000000000c1','85000000-0000-0000-0000-0000000000a1',
   '85000000-0000-0000-0000-0000000000e1','85000000-0000-0000-0000-000000000020','planned',
   now() + interval '1 day', now() + interval '1 day 45 minutes');

insert into public.diagnostics (id, center_id, student_id, sounds) values
  ('85000000-0000-0000-0000-000000000101','85000000-0000-0000-0000-0000000000c1','85000000-0000-0000-0000-0000000000e1',
   '{"р":"искажение","л":"","ш":"замена","С ":"отсутствие"}'::jsonb),
  ('85000000-0000-0000-0000-000000000102','85000000-0000-0000-0000-0000000000c1','85000000-0000-0000-0000-0000000000e2',
   '{"р":"искажение"}'::jsonb),
  ('85000000-0000-0000-0000-000000000109','85000000-0000-0000-0000-0000000000c2','85000000-0000-0000-0000-0000000000eb',
   '{"р":"искажение"}'::jsonb),
  ('85000000-0000-0000-0000-000000000103','85000000-0000-0000-0000-0000000000c1','85000000-0000-0000-0000-0000000000e1',
   '{"ж":"замена"}'::jsonb),
  ('85000000-0000-0000-0000-000000000104','85000000-0000-0000-0000-0000000000c1','85000000-0000-0000-0000-0000000000e1',
   '{"р":"искажение"}'::jsonb);

update public.diagnostics set deleted_at = now() where id = '85000000-0000-0000-0000-000000000104';

update public.students set deleted_at = now() where id = '85000000-0000-0000-0000-0000000000e2';

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 1. Предложения (owner) -------------------------------------------------------------------------

select public.tests_claims('85000000-0000-0000-0000-000000000001', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is(
  (select array_agg(sound) from public.goal_suggestions('85000000-0000-0000-0000-000000000101')),
  array['р', 'ш', 'с'],
  'Нарушенные р, ш, «С » → р ш с по порядку; «норма» (л) не предлагается');
select ok(
  (select bool_and(stage_title = 'Постановка' and title = 'Звук ' || sound || ': постановка')
     from public.goal_suggestions('85000000-0000-0000-0000-000000000101')),
  'Все предложения — этап «Постановка», формулировка по шаблону');

select is(
  public.create_goals_from_diagnostic('85000000-0000-0000-0000-000000000101', array['р', 'Ш', ' р ']),
  2, 'Создано две цели: р и ш (дубли и регистр в выборе схлопываются)');
reset role;

select is(
  (select count(*)::int from public.goals g join public.goal_stages gs on gs.id = g.stage_id
    where g.student_id = '85000000-0000-0000-0000-0000000000e1' and g.status = 'active'
      and g.area = 'звукопроизношение' and gs.code = 'setting' and g.sound in ('р', 'ш')),
  2, 'Цели активны, область «звукопроизношение», этап setting');

set local role authenticated;
select is(
  public.create_goals_from_diagnostic('85000000-0000-0000-0000-000000000101', array['р']),
  0, 'Повтор по уже активной цели — 0, без исключения');
select ok(
  (select already_active from public.goal_suggestions('85000000-0000-0000-0000-000000000101') where sound = 'р'),
  'После создания р помечен already_active');
select throws_ok(
  $q$ select public.create_goals_from_diagnostic('85000000-0000-0000-0000-000000000101', array['л']) $q$,
  '22023', null,
  'Звук с «нормой» не предложен — 22023');
select throws_ok(
  $q$ select public.create_goals_from_diagnostic('85000000-0000-0000-0000-000000000101', array[]::text[]) $q$,
  '22023', null,
  'Пустой выбор — 22023');
reset role;


-- 2. Индекс и старые пути ------------------------------------------------------------------------

select throws_ok(
  $q$ insert into public.goals (center_id, student_id, stage_id, title, sound)
      select '85000000-0000-0000-0000-0000000000c1', '85000000-0000-0000-0000-0000000000e1', gs.id, 'Дубль', ' Р '
        from public.goal_stages gs where gs.center_id = '85000000-0000-0000-0000-0000000000c1' and gs.code = 'setting' $q$,
  '23505', null,
  'Вторая активная цель «Р» на том же этапе — 23505 (регистр и пробелы не спасают)');
select lives_ok(
  $q$ insert into public.goals (id, center_id, student_id, stage_id, title, sound, status)
      select '85000000-0000-0000-0000-000000000201', '85000000-0000-0000-0000-0000000000c1',
             '85000000-0000-0000-0000-0000000000e1', gs.id, 'На паузе', 'р', 'paused'
        from public.goal_stages gs where gs.center_id = '85000000-0000-0000-0000-0000000000c1' and gs.code = 'setting' $q$,
  'Такая же цель на паузе — можно');

select public.tests_claims('85000000-0000-0000-0000-000000000001', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.set_goal_status('85000000-0000-0000-0000-000000000201', 'active') $q$,
  '23505', null,
  'Снять с паузы при живой такой же цели — 23505 (set_goal_status, 0038)');
reset role;

insert into public.goals (center_id, student_id, stage_id, title, sound)
select '85000000-0000-0000-0000-0000000000c1', '85000000-0000-0000-0000-0000000000e1', gs.id, 'С изолированно', 'с'
  from public.goal_stages gs where gs.center_id = '85000000-0000-0000-0000-0000000000c1' and gs.code = 'isolated';

set local role authenticated;
select ok(
  (select not already_active and existing_stage_title = 'Изолированно' and existing_status = 'active'
     from public.goal_suggestions('85000000-0000-0000-0000-000000000101') where sound = 'с'),
  'Цель по «с» на другом этапе — предупреждение existing_*, не блок');
reset role;

-- «ш» на этапе «Изолированно» и перевод его на занятую «Постановку» — старый путь update_goal.
insert into public.goals (id, center_id, student_id, stage_id, title, sound)
select '85000000-0000-0000-0000-000000000202', '85000000-0000-0000-0000-0000000000c1',
       '85000000-0000-0000-0000-0000000000e1', gs.id, 'Ш изолированно', 'ш'
  from public.goal_stages gs where gs.center_id = '85000000-0000-0000-0000-0000000000c1' and gs.code = 'isolated';
-- «ж» только на паузе на «Постановке».
insert into public.goals (center_id, student_id, stage_id, title, sound, status)
select '85000000-0000-0000-0000-0000000000c1', '85000000-0000-0000-0000-0000000000e1', gs.id, 'Ж на паузе', 'ж', 'paused'
  from public.goal_stages gs where gs.center_id = '85000000-0000-0000-0000-0000000000c1' and gs.code = 'setting';

select public.tests_claims('85000000-0000-0000-0000-000000000001', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.update_goal(
        p_id := '85000000-0000-0000-0000-000000000202',
        p_stage_id := (select gs.id from public.goal_stages gs
                        where gs.center_id = '85000000-0000-0000-0000-0000000000c1' and gs.code = 'setting')) $q$,
  '23505', null,
  'Перевести «ш» на этап, где уже есть активная «ш», — 23505 (update_goal, 0038)');
select ok(
  (select not already_active and existing_status = 'paused' and existing_stage_title = 'Постановка'
     from public.goal_suggestions('85000000-0000-0000-0000-000000000103') where sound = 'ж'),
  'Такая же цель только на паузе — не already_active, предупреждение «на паузе»');
reset role;


-- 3. Права -------------------------------------------------------------------------------------------

select public.tests_claims('85000000-0000-0000-0000-000000000002', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select ok(
  (select count(*) > 0 from public.goal_suggestions('85000000-0000-0000-0000-000000000101')),
  'Специалист ученика видит предложения');
select is(
  public.create_goals_from_diagnostic('85000000-0000-0000-0000-000000000103', array['ж']),
  1, 'Специалист ученика создаёт цель (вложенный create_goal под ролью teacher); пауза не мешает');
reset role;

select public.tests_claims('85000000-0000-0000-0000-000000000003', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select * from public.goal_suggestions('85000000-0000-0000-0000-000000000101') $q$,
  '42501', null, 'Чужой специалист — 42501');
reset role;

select public.tests_claims('85000000-0000-0000-0000-000000000004', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select * from public.goal_suggestions('85000000-0000-0000-0000-000000000101') $q$,
  '42501', null, 'Родитель — 42501');
reset role;

select public.tests_claims('85000000-0000-0000-0000-000000000005', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select * from public.goal_suggestions('85000000-0000-0000-0000-000000000101') $q$,
  '42501', null, 'Бухгалтер — 42501');
reset role;

select public.tests_claims('85000000-0000-0000-0000-000000000006', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.create_goals_from_diagnostic('85000000-0000-0000-0000-000000000101', array['р']) $q$,
  '42501', null, 'Регистратор не создаёт цели — 42501');
reset role;

select public.tests_claims('85000000-0000-0000-0000-000000000001', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select * from public.goal_suggestions('85000000-0000-0000-0000-000000000109') $q$,
  '42704', null, 'Диагностика чужого центра — 42704');
select throws_ok(
  $q$ select * from public.goal_suggestions('85000000-0000-0000-0000-000000000102') $q$,
  '42704', null, 'Диагностика архивного ученика — 42704');
select throws_ok(
  $q$ select public.create_goals_from_diagnostic('85000000-0000-0000-0000-000000000104', array['р']) $q$,
  '42704', null, 'Удалённая диагностика — 42704');
reset role;


-- 4. След печати ---------------------------------------------------------------------------------

select public.tests_claims('85000000-0000-0000-0000-000000000002', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.log_speech_card_opened('85000000-0000-0000-0000-0000000000e1') $q$,
  'Специалист ученика открывает речевую карту для печати');
reset role;
select tests_claims(null, null);
select ok(
  (select e.payload->>'student_id' = '85000000-0000-0000-0000-0000000000e1'
          and e.payload->>'by' = '85000000-0000-0000-0000-000000000002'
          and e.payload->>'role' = 'teacher'
     from public.events e
    where e.type = 'student.speech_card_opened' and e.center_id = '85000000-0000-0000-0000-0000000000c1'),
  'Событие student.speech_card_opened: кто, в какой роли, чью карту');

select public.tests_claims('85000000-0000-0000-0000-000000000004', '85000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.log_speech_card_opened('85000000-0000-0000-0000-0000000000e1') $q$,
  '42501', null, 'Родитель речевую карту не печатает — 42501');
reset role;


-- 5. Центр без этапа «Постановка» --------------------------------------------------------------------

select tests_claims(null, null);
update public.goal_stages set deleted_at = now()
 where center_id = '85000000-0000-0000-0000-0000000000c2' and code = 'setting';

select public.tests_claims('85000000-0000-0000-0000-000000000007', '85000000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is_empty(
  $q$ select * from public.goal_suggestions('85000000-0000-0000-0000-000000000109') $q$,
  'Нет живого этапа «Постановка» — предложений нет');
select throws_ok(
  $q$ select public.create_goals_from_diagnostic('85000000-0000-0000-0000-000000000109', array['р']) $q$,
  '22023', null, 'Нет этапа — создать нечего, 22023');
reset role;


-- 6. Аноним ------------------------------------------------------------------------------------------

select ok(
  not has_function_privilege('anon', 'public.goal_suggestions(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.create_goals_from_diagnostic(uuid, text[])', 'execute')
  and not has_function_privilege('anon', 'public.log_speech_card_opened(uuid)', 'execute'),
  'anon не исполняет ни одну из трёх функций');

select * from finish();
rollback;
