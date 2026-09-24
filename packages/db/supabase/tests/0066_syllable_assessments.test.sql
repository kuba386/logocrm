-- pgTAP: слоговая структура — третий раздел речевой карты (0066).
--
-- Заборы (первыми, до любого set role): таблица под readonly guard, в
-- allow-list экспорта (и её грант authenticated не потерян при переиздании
-- в этом же файле), гранты authenticated только select, наличие
-- deleted_at (история, не профиль — обратная проверка 0065), имена CHECK,
-- триггеры, execute-гранты трёх новых функций.
-- Поведение: owner создаёт/читает/архивирует, архивная строка пропадает у
-- owner тоже; teacher с clinical_teacher_sees или primary_teacher_id —
-- симметрично читает и пишет, как в анамнезе/артикуляции; посторонний —
-- 42501 везде, включая правку чужой строки с created_by is null; teacher,
-- потерявший clinical_teacher_sees (занятие отменили) и не создававший
-- запись сам, — 0 строк и 42501; parent/registrar — 0 строк и 42501;
-- центр Б — 42704; архивирует только owner/admin; классы/типы ошибок вне
-- набора или сверх лимита — 23514 от CHECK (RPC не дублирует список);
-- дата вне диапазона — 23514; замок по updated_at — 22023; read-only
-- центр — PT402 на всех трёх RPC; архивация ребёнка НЕ прячет историю от
-- owner/admin (Р5 — сознательное отличие от профилей 0063/0065), но
-- прячет от teacher.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(56);


-- 1. Заборы по каталогу -------------------------------------------------------------------------

select ok(
  exists (select 1 from pg_trigger tg
           where tg.tgrelid = 'public.syllable_assessments'::regclass
             and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal),
  'syllable_assessments под readonly guard');

select set_eq(
  $$ select x.table_name from public.export_center_tables() x
      where x.table_name = 'syllable_assessments' $$,
  $$ values ('syllable_assessments') $$,
  'syllable_assessments в allow-list экспорта');

select ok(
  has_function_privilege('authenticated', 'public.export_center_tables()'::regprocedure, 'EXECUTE'),
  'export_center_tables() не потеряла грант authenticated при переиздании в этом файле');

select ok(
  has_table_privilege('authenticated', 'public.syllable_assessments'::regclass, 'SELECT')
  and not has_table_privilege('authenticated', 'public.syllable_assessments'::regclass, 'INSERT')
  and not has_table_privilege('authenticated', 'public.syllable_assessments'::regclass, 'UPDATE')
  and not has_table_privilege('authenticated', 'public.syllable_assessments'::regclass, 'DELETE')
  and not has_table_privilege('anon', 'public.syllable_assessments'::regclass, 'SELECT'),
  'authenticated — только select (Р11: не как у diagnostics), anon — ничего');

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public' and table_name = 'syllable_assessments' and column_name = 'deleted_at'), 1,
  'История — deleted_at есть (обратная проверка 0065: там его нет)');

select set_eq(
  $$ select conname from pg_constraint
      where conrelid = 'public.syllable_assessments'::regclass and contype = 'c' $$,
  $$ values ('syllable_assessments_date_check'), ('syllable_assessments_affected_classes_check'),
            ('syllable_assessments_error_types_check'), ('syllable_assessments_conclusion_check') $$,
  'Имена CHECK — ровно те, что зарегистрированы в apps/web/lib/errors.ts CHECK_MESSAGES');

select ok(
  (select bool_and(exists (
     select 1 from pg_trigger tg where tg.tgrelid = 'public.syllable_assessments'::regclass
       and tg.tgname = t and not tg.tgisinternal))
     from unnest(array['syllable_assessments_set_updated_at', 'syllable_assessments_audit']) t),
  'moddatetime и audit-триггер на месте');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.oid::regprocedure::text in (
        'record_syllable_assessment(uuid,date,uuid,text[],text[],text)',
        'update_syllable_assessment(uuid,date,text[],text[],text,timestamp with time zone)',
        'archive_syllable_assessment(uuid)')), 3,
  'Все три новые функции найдены по имени и сигнатуре (иначе следующая проверка молча схлопнется в пустую)');
select ok(
  (select bool_and(
       has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and not has_function_privilege('anon', p.oid, 'EXECUTE')
       and not has_function_privilege('public', p.oid, 'EXECUTE')
       and not has_function_privilege('service_role', p.oid, 'EXECUTE'))
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.oid::regprocedure::text in (
        'record_syllable_assessment(uuid,date,uuid,text[],text[],text)',
        'update_syllable_assessment(uuid,date,text[],text[],text,timestamp with time zone)',
        'archive_syllable_assessment(uuid)')),
  'Гранты новых функций: authenticated execute, anon/public/service_role — ничего');

-- Находка 2 ревью написанного SQL: политику легко удалить незаметно для
-- всех поведенческих тестов ниже (они защищают уже закрытые другим
-- основанием дырки) — забор ловит сам факт её существования как restrictive.
select ok(
  exists (select 1 from pg_policies
           where schemaname = 'public' and tablename = 'syllable_assessments'
             and policyname = 'syllable_assessments_visible' and permissive = 'RESTRICTIVE' and cmd = 'SELECT'),
  'syllable_assessments_visible существует как RESTRICTIVE SELECT-политика');


-- Фикстура ----------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0660000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0066@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0660000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-primary-0066@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0660000-0000-0000-0000-000000000003','authenticated','authenticated','teacher-sees-0066@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0660000-0000-0000-0000-000000000004','authenticated','authenticated','teacher-nobody-0066@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0660000-0000-0000-0000-000000000005','authenticated','authenticated','parent-0066@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0660000-0000-0000-0000-000000000006','authenticated','authenticated','registrar-0066@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0660000-0000-0000-0000-000000000007','authenticated','authenticated','owner-b-0066@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0660000-0000-0000-0000-000000000008','authenticated','authenticated','owner-c-0066@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0660000-0000-0000-0000-0000000000c1','Центр А 0066','centr-a-0066','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0660000-0000-0000-0000-0000000000c2','Центр Б 0066','centr-b-0066','{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, settings, trial_ends_at) values
  ('a0660000-0000-0000-0000-0000000000c3','Центр В 0066 (просрочен)','centr-c-0066','{"timezone":"Asia/Bishkek"}'::jsonb, now() - interval '2 days');

insert into public.payers (id, center_id, full_name, phone) values
  ('a0660000-0000-0000-0000-000000000030','a0660000-0000-0000-0000-0000000000c1','Родитель 0066','+996700006601'),
  ('a0660000-0000-0000-0000-000000000031','a0660000-0000-0000-0000-0000000000c3','Родитель В 0066','+996700006603');

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0660000-0000-0000-0000-000000000010','a0660000-0000-0000-0000-0000000000c1','Специалист-назначенный 0066','a0660000-0000-0000-0000-000000000002'),
  ('a0660000-0000-0000-0000-000000000011','a0660000-0000-0000-0000-0000000000c1','Специалист-с-занятием 0066','a0660000-0000-0000-0000-000000000003'),
  ('a0660000-0000-0000-0000-000000000012','a0660000-0000-0000-0000-0000000000c1','Специалист-посторонний 0066','a0660000-0000-0000-0000-000000000004');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('a0660000-0000-0000-0000-000000000020','a0660000-0000-0000-0000-0000000000c1','Логопед',45,70000);

-- Ребёнок А — занятие со специалистом «с занятием» (clinical_teacher_sees); можно отменить.
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0660000-0000-0000-0000-000000000040','a0660000-0000-0000-0000-0000000000c1','Ребёнок А 0066','a0660000-0000-0000-0000-000000000030');
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('a0660000-0000-0000-0000-000000000050','a0660000-0000-0000-0000-0000000000c1','a0660000-0000-0000-0000-000000000020',
   'a0660000-0000-0000-0000-000000000011','a0660000-0000-0000-0000-000000000040', now() + interval '1 day', now() + interval '1 day 45 minutes', 'planned');

-- Ребёнок Б — назначен специалисту-назначенному, занятия нет вовсе.
insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('a0660000-0000-0000-0000-000000000041','a0660000-0000-0000-0000-0000000000c1','Ребёнок Б 0066','a0660000-0000-0000-0000-000000000030','a0660000-0000-0000-0000-000000000010');

-- Ребёнок В — ничей.
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0660000-0000-0000-0000-000000000042','a0660000-0000-0000-0000-0000000000c1','Ребёнок В 0066','a0660000-0000-0000-0000-000000000030');

-- Ребёнок Г — центр В (просроченный trial).
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0660000-0000-0000-0000-000000000043','a0660000-0000-0000-0000-0000000000c3','Ребёнок Г 0066','a0660000-0000-0000-0000-000000000031');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0660000-0000-0000-0000-000000000001','a0660000-0000-0000-0000-0000000000c1','owner',     null, null),
  ('a0660000-0000-0000-0000-000000000002','a0660000-0000-0000-0000-0000000000c1','teacher',   'a0660000-0000-0000-0000-000000000010', null),
  ('a0660000-0000-0000-0000-000000000003','a0660000-0000-0000-0000-0000000000c1','teacher',   'a0660000-0000-0000-0000-000000000011', null),
  ('a0660000-0000-0000-0000-000000000004','a0660000-0000-0000-0000-0000000000c1','teacher',   'a0660000-0000-0000-0000-000000000012', null),
  ('a0660000-0000-0000-0000-000000000005','a0660000-0000-0000-0000-0000000000c1','parent',    null, 'a0660000-0000-0000-0000-000000000030'),
  ('a0660000-0000-0000-0000-000000000006','a0660000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('a0660000-0000-0000-0000-000000000007','a0660000-0000-0000-0000-0000000000c2','owner',     null, null),
  ('a0660000-0000-0000-0000-000000000008','a0660000-0000-0000-0000-0000000000c3','owner',     null, null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Запись под owner на ребёнке А -----------------------------------------------------------------

select public.tests_claims('a0660000-0000-0000-0000-000000000001','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;

select throws_ok(
  $q$ select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000040', null, null,
        array['not_a_class']) $q$,
  '23514', null, 'Недопустимый код класса — CHECK 23514, RPC список не дублирует (Р2/0065)');
select throws_ok(
  $q$ select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000040', null, null,
        null, array['not_a_type']) $q$,
  '23514', null, 'Недопустимый код типа ошибки — CHECK 23514');
select throws_ok(
  $q$ select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000040', null, null,
        array['1', null]) $q$,
  '23514', null, 'NULL-элемент в массиве классов — containment не считает NULL совпадением, 23514');
select throws_ok(
  $q$ select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000040',
        current_date + 10, null, array['1']) $q$,
  '23514', null, 'Дата за верхней границей — CHECK 23514 (с содержательным полем, иначе бьётся о находку 3)');
select throws_ok(
  $q$ select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000040', null, null,
        null, null, repeat('ф', 2001)) $q$,
  '23514', null, 'conclusion сверх 2000 символов — CHECK 23514');
select throws_ok(
  $q$ select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000040') $q$,
  '22023', null, 'Ни одного содержательного поля — 22023, не тихая запись «нарушений нет» (находка 3)');

create temporary table t0066_a as
  select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000040', null, null,
    array['10','2','2','10'], array['omission','cluster_simplification'], 'Первичное обследование') as id;
grant select on t0066_a to authenticated;

select is(
  (select affected_classes from public.syllable_assessments where id = (select id from t0066_a)),
  array['2','10'],
  'Дубли схлопнуты, порядок числовой — вход [10,2,2,10] даёт [2,10], не [10,2] (лексикографически «10» < «2», находка 4/5)');
select is(
  (select date from public.syllable_assessments where id = (select id from t0066_a)),
  public.center_today('a0660000-0000-0000-0000-0000000000c1'),
  'date по умолчанию — сегодня центра (Р7)');

select throws_ok(
  $q$ insert into public.syllable_assessments (center_id, student_id) values
      ('a0660000-0000-0000-0000-0000000000c1','a0660000-0000-0000-0000-000000000040') $q$,
  '42501', null, 'Прямой insert от owner — отказ грантом, только RPC (Р11)');

select throws_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_a), null, array['5']) $q$,
  '22023', null, 'p_expected_updated_at не передан — 22023 (Р10)');

select lives_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_a), null, array['5'], null, null,
        (select updated_at from public.syllable_assessments where id = (select id from t0066_a))) $q$,
  'Верный p_expected_updated_at проходит');
select is(
  (select affected_classes from public.syllable_assessments where id = (select id from t0066_a)),
  array['5'], 'Список заменён целиком, не слит со старым (Р6)');

select lives_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_a), null, '{}'::text[], null, null,
        (select updated_at from public.syllable_assessments where id = (select id from t0066_a))) $q$,
  'Пустой массив — валидная замена (улучшение), не «не трогать» (Р6)');
select is(
  (select affected_classes from public.syllable_assessments where id = (select id from t0066_a)),
  '{}'::text[], 'affected_classes очищен явной пустой заменой');
select is(
  (select error_types from public.syllable_assessments where id = (select id from t0066_a)),
  array['cluster_simplification','omission'], 'error_types не тронут (дедуп при создании отсортировал алфавитно)');

select lives_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_a), null, null, null, '',
        (select updated_at from public.syllable_assessments where id = (select id from t0066_a))) $q$,
  ''''' в conclusion снимает его (сентинел, находка 6)');
select is(
  (select conclusion from public.syllable_assessments where id = (select id from t0066_a)), null,
  'conclusion снят');
select lives_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_a), null, null, null, null,
        (select updated_at from public.syllable_assessments where id = (select id from t0066_a))) $q$,
  'null в conclusion не трогает (остаётся снятым)');
select is(
  (select conclusion from public.syllable_assessments where id = (select id from t0066_a)), null,
  'conclusion остался null после null-параметра');

reset role;

-- Р18: RPC дедуплицирует до insert — 15 элементов с одним дублем
-- схлопываются в 14 валидных до того, как cardinality-CHECK вообще
-- увидит массив, так что через RPC предел уже не достижим (кодов ровно
-- 14). CHECK всё равно держит границу — проверяем прямым insert от
-- postgres, мимо RPC-дедупа и мимо грантов (тот же обход, что и для
-- фактов существования CHECK в остальных заборах).
select throws_ok(
  $q$ insert into public.syllable_assessments (center_id, student_id, affected_classes) values
      ('a0660000-0000-0000-0000-0000000000c1','a0660000-0000-0000-0000-000000000040',
       array['1','2','3','4','5','6','7','8','9','10','11','12','13','14','1']) $q$,
  '23514', null, 'affected_classes сверх cardinality 14 мимо RPC-дедупа — CHECK всё равно держит (Р8/Р18)');


-- 3. Право доступа — симметрия чтения/записи ---------------------------------------------------

-- Специалист-назначенный (primary_teacher_id ребёнка Б, занятия нет) — создаёт.
select public.tests_claims('a0660000-0000-0000-0000-000000000002','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
create temporary table t0066_c as
  select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000041', null, null,
    array['3']) as id;
grant select on t0066_c to authenticated;
select is(
  (select count(*)::int from public.syllable_assessments where student_id = 'a0660000-0000-0000-0000-000000000041'), 1,
  'Автор видит созданную запись сразу же (Р3)');
reset role;

-- Специалист-посторонний — 42501 на создании.
select public.tests_claims('a0660000-0000-0000-0000-000000000004','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000042') $q$,
  '42501', null, 'Посторонний teacher — 42501 на создании (Р3)');
select is(
  (select count(*)::int from public.syllable_assessments where student_id = 'a0660000-0000-0000-0000-000000000042'), 0,
  'Посторонний teacher: 0 строк');
reset role;

-- Специалист-с-занятием читает и правит запись ребёнка А (созданную owner'ом).
select public.tests_claims('a0660000-0000-0000-0000-000000000003','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.syllable_assessments where student_id = 'a0660000-0000-0000-0000-000000000040'), 1,
  'Teacher со своим занятием видит запись ребёнка А, созданную owner''ом');
select lives_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_a), null, null, null, 'уточнение',
        (select updated_at from public.syllable_assessments where id = (select id from t0066_a))) $q$,
  'Teacher со своим занятием правит чужую (по авторству) запись — clinical_teacher_sees достаточно (Р3)');
reset role;

-- Посторонний — 42501 и на правке существующей чужой строки, даже когда created_by is null.
select public.tests_claims(null, null);
update public.syllable_assessments set created_by = null where id = (select id from t0066_a);
select public.tests_claims('a0660000-0000-0000-0000-000000000004','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.syllable_assessments where student_id = 'a0660000-0000-0000-0000-000000000040'), 0,
  'Посторонний teacher: 0 строк по записи ребёнка А');
select throws_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_a), null, null, null, 'x', now()) $q$,
  '42501', null, 'Посторонний teacher — 42501 на правке чужой строки, created_by is null не пропускает (Р2)');
reset role;

-- Специалист-с-занятием теряет clinical_teacher_sees (занятие отменили) — не создавал запись сам.
select public.tests_claims(null, null);
update public.lessons set status = 'cancelled' where id = 'a0660000-0000-0000-0000-000000000050';
select public.tests_claims('a0660000-0000-0000-0000-000000000003','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.syllable_assessments where student_id = 'a0660000-0000-0000-0000-000000000040'), 0,
  'Teacher без clinical_teacher_sees (занятие отменено), не автор и не primary_teacher_id — 0 строк (Р4)');
select throws_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_a), null, null, null, 'x', now()) $q$,
  '42501', null, 'Тот же teacher — 42501 на правке (потерял единственное основание доступа)');
reset role;


-- 4. Видимость по ролям и архивация ----------------------------------------------------------------

select public.tests_claims('a0660000-0000-0000-0000-000000000005','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.syllable_assessments), 0, 'Родитель: 0 строк прямым запросом');
select throws_ok(
  $q$ select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000040') $q$,
  '42501', null, 'Родитель: record_syllable_assessment — 42501');
reset role;

select public.tests_claims('a0660000-0000-0000-0000-000000000006','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.syllable_assessments), 0, 'Registrar: 0 строк');
select throws_ok(
  $q$ select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000040') $q$,
  '42501', null, 'Registrar: record_syllable_assessment — 42501');
reset role;

select public.tests_claims('a0660000-0000-0000-0000-000000000007','a0660000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is(
  (select count(*)::int from public.syllable_assessments), 0, 'Центр Б не видит записи центра А');
select throws_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_a), null, null, null, 'x', now()) $q$,
  '42704', null, 'Центр Б: чужая запись — 42704');
reset role;

-- Teacher не может архивировать — только owner/admin.
select public.tests_claims('a0660000-0000-0000-0000-000000000001','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
create temporary table t0066_b as
  select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000040', null, null, array['3']) as id;
grant select on t0066_b to authenticated;
reset role;

select public.tests_claims('a0660000-0000-0000-0000-000000000003','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.archive_syllable_assessment((select id from t0066_b)) $q$,
  '42501', null, 'Teacher не может архивировать — только owner/admin');
reset role;

-- История: два обследования на одного ребёнка, обе видны; архив одной не трогает вторую.
select public.tests_claims('a0660000-0000-0000-0000-000000000001','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.syllable_assessments where student_id = 'a0660000-0000-0000-0000-000000000040'), 2,
  'История: две записи на ребёнка А видны обе (не upsert)');
select ok(
  public.archive_syllable_assessment((select id from t0066_b)),
  'Архивация второй записи проходит');
select is(
  (select count(*)::int from public.syllable_assessments where student_id = 'a0660000-0000-0000-0000-000000000040'), 1,
  'После архива одной — вторая осталась видимой (архив не каскадом)');

-- Р13 (пересмотр Р5): student_alive в restrictive держит ВСЕХ, включая
-- owner/admin, — students.deleted_at выставлен мимо приложения (в
-- реальности archive_student его не трогает вовсе, но restrictive обязана
-- держать границу и на этот гипотетический путь, 0059 Р14).
select public.tests_claims(null, null);
update public.students set deleted_at = now() where id = 'a0660000-0000-0000-0000-000000000040';
select public.tests_claims('a0660000-0000-0000-0000-000000000001','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.syllable_assessments where student_id = 'a0660000-0000-0000-0000-000000000040'), 0,
  'student.deleted_at мимо приложения — owner тоже видит 0 (restrictive держит всех без исключения, Р13)');
reset role;

select public.tests_claims(null, null);
update public.students set deleted_at = null where id = 'a0660000-0000-0000-0000-000000000040';

-- Находка 2 ревью написанного SQL: единственный сценарий, где restrictive
-- и student_alive в update_ реально что-то решают, — автор-teacher БЕЗ
-- clinical_teacher_sees/primary_teacher_id (ребёнок Б, специалист-назначенный
-- t0066_c — уже автор записи из section 3). Без student_alive в этой
-- ветке все ассерты выше остаются зелёными и при полностью удалённой
-- restrictive-политике — она бы защищала уже закрытую другим основанием
-- дырку, а не эту.
select public.tests_claims(null, null);
update public.students set deleted_at = now() where id = 'a0660000-0000-0000-0000-000000000041';
select public.tests_claims('a0660000-0000-0000-0000-000000000002','a0660000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.syllable_assessments where student_id = 'a0660000-0000-0000-0000-000000000041'), 0,
  'Автор-teacher теряет видимость своей же записи, когда student_alive ложно (единственный вооружённый сценарий, находка 2)');
select throws_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_c), null, null, null, 'x', now()) $q$,
  '42501', null, 'update_ бьётся о student_alive в ветке teacher, даже с id на руках и через RPC (не 42704 — RPC видит строку мимо RLS, отказывает по правам)');
reset role;
select public.tests_claims(null, null);
update public.students set deleted_at = null where id = 'a0660000-0000-0000-0000-000000000041';


-- 5. Read-only центр — PT402 от guard на всех трёх RPC -----------------------------------------------

select public.tests_claims('a0660000-0000-0000-0000-000000000008','a0660000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $q$ select public.record_syllable_assessment('a0660000-0000-0000-0000-000000000043', null, null, array['3']) $q$,
  'PT402', null, 'Просроченный центр: record_syllable_assessment — PT402 от guard');
reset role;

-- Строка мимо guard (postgres, до просрочки не подступиться иначе — центр
-- заведён просроченным в фикстуре) — проверяет update_/archive_ отдельно.
select public.tests_claims(null, null);
create temporary table t0066_ro as
  insert into public.syllable_assessments (center_id, student_id, affected_classes)
    values ('a0660000-0000-0000-0000-0000000000c3','a0660000-0000-0000-0000-000000000043', array['3'])
    returning id;
grant select on t0066_ro to authenticated;

select public.tests_claims('a0660000-0000-0000-0000-000000000008','a0660000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $q$ select public.update_syllable_assessment((select id from t0066_ro), null, null, null, 'x', now()) $q$,
  'PT402', null, 'Просроченный центр: update_syllable_assessment — PT402 от guard');
select throws_ok(
  $q$ select public.archive_syllable_assessment((select id from t0066_ro)) $q$,
  'PT402', null, 'Просроченный центр: archive_syllable_assessment — PT402 от guard');
select lives_ok(
  $q$ select count(*) from public.syllable_assessments where student_id = 'a0660000-0000-0000-0000-000000000043' $q$,
  'select продолжает работать в read-only центре');
reset role;

select * from finish();
rollback;
