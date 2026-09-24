-- pgTAP: экспорт данных центра и заявка на удаление (0056).
--
-- Забор в начале: каждая базовая таблица public с center_id — либо в
-- export_center_tables(), либо в export_center_excluded_tables(), не в
-- обоих сразу; ни одной вью. export_center_table/export_center_audit —
-- роль, allow-list, изоляция по центру, секреты (invitations/
-- lesson_voice_requests) вычеркнуты из аудита. request_center_deletion —
-- owner, подтверждение именем, идемпотентность, событие;
-- cancel_center_deletion — снимает deleted_at; center_deletion_state —
-- глазок в RLS для owner/admin. Прямой PATCH centers.deleted_at — отказ
-- (РЛС-дыра, закрытая этой миграцией). PT402 различает «истёк»/«удалён».
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(53);


-- 1. Заборы по каталогу (до любого tests_claims()/set role, Р13) -------------------------------------------

select is_empty(
  $$ select c.table_name
       from information_schema.columns c
       join information_schema.tables t
         on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
      where c.table_schema = 'public' and c.column_name = 'center_id'
        and c.table_name not in (select x.table_name from public.export_center_tables() x)
        and c.table_name not in (select x.table_name from public.export_center_excluded_tables() x) $$,
  'Каждая базовая таблица public с center_id — либо в export_center_tables(), либо в export_center_excluded_tables() (Р1)');

select is_empty(
  $$ select x.table_name from public.export_center_tables() x
      where x.table_name in (select y.table_name from public.export_center_excluded_tables() y) $$,
  'allow и deny не пересекаются');

select is_empty(
  $$ select x.table_name from public.export_center_tables() x
      where not exists (
        select 1 from information_schema.tables t
         where t.table_schema = 'public' and t.table_name = x.table_name and t.table_type = 'BASE TABLE') $$,
  'export_center_tables() не протух: все таблицы существуют и являются базовыми (не вью)');

select is_empty(
  $$ select x.table_name from public.export_center_excluded_tables() x
      where not exists (
        select 1 from information_schema.tables t where t.table_schema = 'public' and t.table_name = x.table_name) $$,
  'export_center_excluded_tables() не протух');

select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('center_write_state','export_center_excluded_tables')
        and (has_function_privilege('public', p.oid, 'EXECUTE')
             or has_function_privilege('anon', p.oid, 'EXECUTE')
             or has_function_privilege('authenticated', p.oid, 'EXECUTE')
             or has_function_privilege('service_role', p.oid, 'EXECUTE')) $$,
  'Внутренние функции 0056 без единого гранта');


-- Фикстура -----------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0560000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0056@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0560000-0000-0000-0000-000000000002','authenticated','authenticated','admin-0056@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0560000-0000-0000-0000-000000000003','authenticated','authenticated','teacher-0056@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0560000-0000-0000-0000-000000000004','authenticated','authenticated','parent-0056@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0560000-0000-0000-0000-000000000005','authenticated','authenticated','owner-b-0056@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0560000-0000-0000-0000-0000000000c1','Центр А 0056','centr-a-0056','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0560000-0000-0000-0000-0000000000c2','Центр Б 0056','centr-b-0056','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0560000-0000-0000-0000-000000000010','a0560000-0000-0000-0000-0000000000c1','Специалист 0056','a0560000-0000-0000-0000-000000000003');

insert into public.payers (id, center_id, full_name, phone) values
  ('a0560000-0000-0000-0000-000000000030','a0560000-0000-0000-0000-0000000000c1','Родитель 0056','+996700005601'),
  ('a0560000-0000-0000-0000-000000000031','a0560000-0000-0000-0000-0000000000c2','Родитель Б 0056','+996700005602');

insert into public.students (id, center_id, full_name, payer_id) values
  ('a0560000-0000-0000-0000-000000000040','a0560000-0000-0000-0000-0000000000c1','Ребёнок А 0056','a0560000-0000-0000-0000-000000000030'),
  ('a0560000-0000-0000-0000-000000000041','a0560000-0000-0000-0000-0000000000c2','Ребёнок Б 0056','a0560000-0000-0000-0000-000000000031');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0560000-0000-0000-0000-000000000001','a0560000-0000-0000-0000-0000000000c1','owner',    null, null),
  ('a0560000-0000-0000-0000-000000000002','a0560000-0000-0000-0000-0000000000c1','admin',    null, null),
  ('a0560000-0000-0000-0000-000000000003','a0560000-0000-0000-0000-0000000000c1','teacher','a0560000-0000-0000-0000-000000000010', null),
  ('a0560000-0000-0000-0000-000000000004','a0560000-0000-0000-0000-0000000000c1','parent',    null, 'a0560000-0000-0000-0000-000000000030'),
  ('a0560000-0000-0000-0000-000000000005','a0560000-0000-0000-0000-0000000000c2','owner',    null, null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. export_center_table (Р3, Р4) -------------------------------------------------------------------

select public.tests_claims('a0560000-0000-0000-0000-000000000003','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.export_center_table('students') $q$,
  '42501', null, 'teacher не вызывает export_center_table (owner/admin only)');
reset role;

select public.tests_claims('a0560000-0000-0000-0000-000000000004','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.export_center_table('students') $q$,
  '42501', null, 'parent не вызывает export_center_table');
reset role;

select public.tests_claims('a0560000-0000-0000-0000-000000000001','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.export_center_table('invitations') $q$,
  '42501', null, 'Таблица вне allow-list (invitations) — отказ, даже owner (Р1/Р2)');
select throws_ok(
  $q$ select public.export_center_table('audit_log') $q$,
  '42501', null, 'audit_log вне allow-list — своя функция export_center_audit()');
select throws_ok(
  $q$ select public.export_center_table('no_such_table') $q$,
  '42501', null, 'Несуществующая таблица — тот же отказ, не 42P01');
select is(
  jsonb_array_length(public.export_center_table('students')),
  1, 'export_center_table(students) от owner центра А — одна строка (Ребёнок А)');
select ok(
  (public.export_center_table('students') -> 0 ->> 'full_name') = 'Ребёнок А 0056',
  'Содержимое строки верное');
reset role;

select public.tests_claims('a0560000-0000-0000-0000-000000000002','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  jsonb_array_length(public.export_center_table('students')),
  1, 'admin тоже может (не только owner)');
reset role;

-- Изоляция: owner центра Б не видит ребёнка центра А — current_center()
-- строго из своей сессии, параметра p_center_id в функции нет вовсе (Р3).
select public.tests_claims('a0560000-0000-0000-0000-000000000005','a0560000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is(
  jsonb_array_length(public.export_center_table('students')),
  1, 'owner центра Б получает свою одну строку (Ребёнок Б)');
select ok(
  (public.export_center_table('students') -> 0 ->> 'full_name') = 'Ребёнок Б 0056',
  'Не строку центра А — изоляция по current_center()');
reset role;


-- 3. export_center_audit (Р2, Р4) -------------------------------------------------------------------

select public.tests_claims(null, null);
insert into public.audit_log (center_id, table_name, row_id, action, old_data, new_data, user_id, at) values
  ('a0560000-0000-0000-0000-0000000000c1', 'students', 'a0560000-0000-0000-0000-000000000040', 'UPDATE',
   '{}'::jsonb, '{"full_name":"Ребёнок А 0056"}'::jsonb, 'a0560000-0000-0000-0000-000000000001', now() - interval '5 days'),
  ('a0560000-0000-0000-0000-0000000000c1', 'invitations', null, 'INSERT',
   null, jsonb_build_object('token', 'secret-token-0056'), 'a0560000-0000-0000-0000-000000000001', now() - interval '5 days'),
  ('a0560000-0000-0000-0000-0000000000c1', 'students', 'a0560000-0000-0000-0000-000000000040', 'UPDATE',
   '{}'::jsonb, '{}'::jsonb, 'a0560000-0000-0000-0000-000000000001', now() - interval '40 days');

select public.tests_claims('a0560000-0000-0000-0000-000000000003','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.export_center_audit(current_date - 30, current_date) $q$,
  '42501', null, 'teacher не вызывает export_center_audit');
reset role;

select public.tests_claims('a0560000-0000-0000-0000-000000000001','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.export_center_audit(current_date + 1, current_date) $q$,
  '22023', null, 'from > to отбивается');
-- Верхняя граница — вчера, не today: весь фикстур-сетап файла тоже пишет
-- audit_log (apply_audit) с at = now(), и current_date как верхняя граница
-- захватывал бы этот шум наравне с намеренно вставленными строками.
create temporary table t0056_audit as
  select public.export_center_audit(current_date - 10, current_date - 1) as a;
select is(
  jsonb_array_length((select a from t0056_audit)), 1,
  'export_center_audit за период: одна строка (students), invitations вычеркнута (Р2), 40-дневная — вне периода, сегодняшний фикстур-шум — тоже');
select is(
  (select a from t0056_audit) -> 0 ->> 'table_name', 'students',
  'Оставшаяся строка — именно students, не invitations');
reset role;


-- 4. record_center_export (Р11) ----------------------------------------------------------------------

select public.tests_claims('a0560000-0000-0000-0000-000000000003','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.record_center_export() $q$,
  '42501', null, 'teacher не вызывает record_center_export');
reset role;

select public.tests_claims('a0560000-0000-0000-0000-000000000001','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.record_center_export() $q$,
  'owner может отметить факт экспорта');
reset role;
select is(
  (select count(*)::int from public.events
    where center_id = 'a0560000-0000-0000-0000-0000000000c1' and type = 'center.exported'),
  1, 'Событие center.exported записано ровно один раз');


-- 5. request_center_deletion / cancel_center_deletion (Р8, Р9) ---------------------------------------

select public.tests_claims('a0560000-0000-0000-0000-000000000002','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.request_center_deletion('Центр А 0056') $q$,
  '42501', null, 'admin не может удалить центр — только owner (Р8)');
reset role;

select public.tests_claims('a0560000-0000-0000-0000-000000000001','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.request_center_deletion('Неверное имя') $q$,
  '22023', null, 'Несовпадение имени — отказ, deleted_at не тронут');
select is(
  (select deleted_at from public.centers where id = 'a0560000-0000-0000-0000-0000000000c1'),
  null, 'После отбитой попытки центр по-прежнему жив');
select lives_ok(
  $q$ select public.request_center_deletion('Центр А 0056') $q$,
  'Точное имя — заявка проходит');
-- Строка centers спрятана RLS уже здесь (centers_select_members требует
-- deleted_at is null) — читаем через center_deletion_state(), не сырым
-- select (ревью написанного SQL, находка 1: тест на прошлой версии падал
-- бы здесь, потому что подзапрос возвращал NULL, а не false).
select ok(
  (public.center_deletion_state() ->> 'deleted')::boolean,
  'deleted_at проставлен (center_deletion_state — обычный select строку уже не покажет)');
select is(
  (select count(*)::int from public.events
    where center_id = 'a0560000-0000-0000-0000-0000000000c1' and type = 'center.deletion_requested'),
  1, 'Событие center.deletion_requested — ровно одно');

-- Идемпотентность: повтор не двигает deleted_at и не плодит событий (Р8).
-- Снимок и сравнение — тем же center_deletion_state(), не сырым select
-- спрятанной строки (находка 3: сравнение NULL с NULL раньше проходило
-- бы, не проверяя ничего).
create temporary table t0056_deletion_snapshot as
  select public.center_deletion_state() ->> 'deleted_at' as deleted_at;
select throws_ok(
  $q$ select public.request_center_deletion('Центр А 0056') $q$,
  '23514', null, 'Повторная заявка — явный отказ, а не молчаливый успех');
select isnt(
  (select deleted_at from t0056_deletion_snapshot), null, 'Снимок для сравнения не пуст — проверка не тривиальна');
select is(
  (public.center_deletion_state() ->> 'deleted_at'),
  (select deleted_at from t0056_deletion_snapshot), 'deleted_at не изменился повторным вызовом');
select is(
  (select count(*)::int from public.events
    where center_id = 'a0560000-0000-0000-0000-0000000000c1' and type = 'center.deletion_requested'),
  1, 'И событие по-прежнему одно');
reset role;

-- Прямой PATCH в обход RPC — 42501 (Р6: РЛС-дыра закрыта в этой же миграции).
select public.tests_claims('a0560000-0000-0000-0000-000000000005','a0560000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_ok(
  $q$ update public.centers set deleted_at = now() where id = 'a0560000-0000-0000-0000-0000000000c2' $q$,
  '42501', null, 'Прямой PATCH centers.deleted_at от owner — отказ (Р6)');
select is(
  (select deleted_at from public.centers where id = 'a0560000-0000-0000-0000-0000000000c2'),
  null, 'Центр Б по-прежнему жив — прямой PATCH не прошёл');
reset role;

-- center_deletion_state — глазок в спрятанную RLS строку (Р10).
select public.tests_claims('a0560000-0000-0000-0000-000000000003','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.center_deletion_state() $q$,
  '42501', null, 'teacher не вызывает center_deletion_state');
reset role;

select public.tests_claims('a0560000-0000-0000-0000-000000000002','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select ok(
  (public.center_deletion_state() ->> 'deleted')::boolean,
  'admin (не только owner) видит, что центр помечен на удаление, хотя обычный select его не покажет');
select is(
  (select count(*)::int from public.centers where id = 'a0560000-0000-0000-0000-0000000000c1'),
  0, 'Контрольная проверка: обычный select .from(centers) саму строку не отдаёт — RLS прячет её и от admin');
reset role;

select public.tests_claims('a0560000-0000-0000-0000-000000000002','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.cancel_center_deletion() $q$,
  '42501', null, 'admin не может отменить удаление — только owner (Р9)');
reset role;

select public.tests_claims('a0560000-0000-0000-0000-000000000001','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.cancel_center_deletion() $q$,
  'owner отменяет удаление');
select is(
  (select deleted_at from public.centers where id = 'a0560000-0000-0000-0000-0000000000c1'),
  null, 'deleted_at снова null');
select is(
  (select count(*)::int from public.events
    where center_id = 'a0560000-0000-0000-0000-0000000000c1' and type = 'center.deletion_cancelled'),
  1, 'Событие center.deletion_cancelled записано');
select throws_ok(
  $q$ select public.cancel_center_deletion() $q$,
  '23514', null, 'Повторная отмена — отказ, центр и так не удалён');
reset role;


-- 5б. submit_platform_payment отказывает для удалённого центра (Р14, находка 5) ------------------------

select public.tests_claims('a0560000-0000-0000-0000-000000000001','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.request_center_deletion('Центр А 0056') $q$,
  'Снова помечаем центр А на удаление — для проверки submit_platform_payment');
select throws_like(
  $q$ select public.submit_platform_payment('solo', 1, 'mbank') $q$,
  '%удал%', 'submit_platform_payment отказывает для удалённого центра — платить некуда (находка 5)');
select lives_ok(
  $q$ select public.cancel_center_deletion() $q$,
  'Возвращаем центр А в рабочее состояние для дальнейших тестов');
reset role;


-- 5в. Обязательное уведомление об удалении нельзя выключить (Р12, находка 6) ---------------------------

select public.tests_claims('a0560000-0000-0000-0000-000000000001','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_like(
  $q$ select public.upsert_message_template('center.deletion_requested', 'telegram', 'текст', false) $q$,
  '%нельзя выключить%', 'center.deletion_requested — mandatory, is_active=false отбивается (находка 6)');
reset role;


-- 5г. my_memberships() показывает удалённый центр его же владельцу (Р15, находка 4) ----------------------

select public.tests_claims('a0560000-0000-0000-0000-000000000001','a0560000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.request_center_deletion('Центр А 0056') $q$,
  'И снова помечаем на удаление — для проверки my_memberships()');
select ok(
  exists (select 1 from public.my_memberships() m where m.center_id = 'a0560000-0000-0000-0000-0000000000c1' and m.deleted),
  'my_memberships() отдаёт удалённый центр с deleted=true — окно отсрочки есть чем открыть (находка 4)');
select lives_ok(
  $q$ select public.cancel_center_deletion() $q$,
  'Возвращаем центр А в рабочее состояние');
reset role;


-- 6. center_write_state / center_readonly_guard — PT402 различает причину (Р7) -----------------------

select public.tests_claims(null, null);
update public.centers set deleted_at = now() where id = 'a0560000-0000-0000-0000-0000000000c2';

select is(
  public.center_write_state('a0560000-0000-0000-0000-0000000000c2'), 'deleted',
  'center_write_state — deleted, не expired');
select is(public.center_writable('a0560000-0000-0000-0000-0000000000c2'), false,
  'center_writable по-прежнему false — обёртка сохраняет поведение 0050');

select public.tests_claims('a0560000-0000-0000-0000-000000000005','a0560000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_like(
  $q$ update public.payers set full_name = 'x' where id = 'a0560000-0000-0000-0000-000000000031' $q$,
  '%удал%', 'Owner удалённого центра получает текст про удаление, не «оплатите» (Р7, находка 9 ревью)');
select ok(
  (public.center_limits() ->> 'state') = 'deleted',
  'center_limits().state = deleted');
reset role;

select public.tests_claims(null, null);
update public.centers set deleted_at = null where id = 'a0560000-0000-0000-0000-0000000000c2';


select * from finish();

rollback;
