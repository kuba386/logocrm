-- pgTAP: анамнез — первый раздел речевой карты (0063).
--
-- Заборы (первыми, до любого set role): таблица под readonly guard, в
-- allow-list экспорта (и её грант authenticated не потерян при переиздании
-- функции в этом же файле — сам здесь словил этот баг), гранты authenticated
-- только select, PK/unique, триггеры, execute-гранты новых функций.
-- Поведение: owner пишет/читает; teacher с clinical_teacher_sees читает и
-- правит; teacher БЕЗ clinical_teacher_sees может создать анамнез, которого
-- ещё нет (первичка до первого занятия), и сохраняет доступ к СВОЕЙ записи
-- дальше (Р10, приём 0038/0059 Р18) — но не к чужой; parent/registrar —
-- 0 строк и 42501 от RPC; центр Б — 42704; оптимистичная блокировка по
-- updated_at; неизвестный ключ и неверный тип значения в p_fields — 22023
-- с понятным текстом, не голый каст; пустой p_fields — 22023; CHECK на
-- диапазон/длину/дату; restrictive-политика держит видимость даже для
-- owner, когда student.deleted_at выставлен мимо приложения; read-only
-- центр — PT402.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(42);


-- 1. Заборы по каталогу -------------------------------------------------------------------------

select ok(
  exists (select 1 from pg_trigger tg
           where tg.tgrelid = 'public.student_anamnesis'::regclass
             and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal),
  'student_anamnesis под readonly guard (Р8)');

select set_eq(
  $$ select x.table_name from public.export_center_tables() x
      where x.table_name = 'student_anamnesis' $$,
  $$ values ('student_anamnesis') $$,
  'student_anamnesis в allow-list экспорта (Р9)');

select ok(
  has_function_privilege('authenticated', 'public.export_center_tables()'::regprocedure, 'EXECUTE'),
  'export_center_tables() не потеряла грант authenticated при переиздании в этом файле (сам словил здесь этот баг)');

select ok(
  has_table_privilege('authenticated', 'public.student_anamnesis'::regclass, 'SELECT')
  and not has_table_privilege('authenticated', 'public.student_anamnesis'::regclass, 'INSERT')
  and not has_table_privilege('authenticated', 'public.student_anamnesis'::regclass, 'UPDATE')
  and not has_table_privilege('authenticated', 'public.student_anamnesis'::regclass, 'DELETE')
  and not has_table_privilege('anon', 'public.student_anamnesis'::regclass, 'SELECT'),
  'authenticated — только select, anon — ничего; запись только через RPC');

select ok(
  (select a.attname from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
     where i.indrelid = 'public.student_anamnesis'::regclass and i.indisprimary) = 'id',
  'PK — суррогатный id, не student_id (Р3: audit_trigger адресует по id)');

select ok(
  exists (select 1 from pg_constraint where conname = 'student_anamnesis_student_key'
           and conrelid = 'public.student_anamnesis'::regclass and contype = 'u'),
  'unique(student_id) держит честный 1:1 без PK по student_id');

select ok(
  (select bool_and(exists (
     select 1 from pg_trigger tg where tg.tgrelid = 'public.student_anamnesis'::regclass
       and tg.tgname = t and not tg.tgisinternal))
     from unnest(array['student_anamnesis_set_updated_at', 'student_anamnesis_audit']) t),
  'moddatetime и audit-триггер на месте');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.oid::regprocedure::text in (
        'student_alive(uuid)',
        'clinical_student_visible(uuid)',
        'set_student_anamnesis(uuid,jsonb,timestamp with time zone)')), 3,
  'Все три новые функции найдены по имени и сигнатуре (иначе следующая проверка молча схлопнется в пустую)');
select ok(
  (select bool_and(
       has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and not has_function_privilege('anon', p.oid, 'EXECUTE')
       and not has_function_privilege('public', p.oid, 'EXECUTE'))
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.oid::regprocedure::text in (
        'student_alive(uuid)',
        'clinical_student_visible(uuid)',
        'set_student_anamnesis(uuid,jsonb,timestamp with time zone)')),
  'Гранты новых функций: authenticated execute, anon/public — ничего');


-- Фикстура ----------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0620000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0063@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0620000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-0063@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0620000-0000-0000-0000-000000000003','authenticated','authenticated','teacher2-0063@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0620000-0000-0000-0000-000000000004','authenticated','authenticated','parent-0063@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0620000-0000-0000-0000-000000000005','authenticated','authenticated','registrar-0063@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0620000-0000-0000-0000-000000000006','authenticated','authenticated','owner-b-0063@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0620000-0000-0000-0000-000000000007','authenticated','authenticated','owner-c-0063@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0620000-0000-0000-0000-0000000000c1','Центр А 0063','centr-a-0063','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0620000-0000-0000-0000-0000000000c2','Центр Б 0063','centr-b-0063','{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, settings, trial_ends_at) values
  ('a0620000-0000-0000-0000-0000000000c3','Центр В 0063 (просрочен)','centr-c-0063','{"timezone":"Asia/Bishkek"}'::jsonb, now() - interval '2 days');

insert into public.payers (id, center_id, full_name, phone) values
  ('a0620000-0000-0000-0000-000000000030','a0620000-0000-0000-0000-0000000000c1','Родитель 0063','+996700006301'),
  ('a0620000-0000-0000-0000-000000000031','a0620000-0000-0000-0000-0000000000c3','Родитель В 0063','+996700006303');

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0620000-0000-0000-0000-000000000010','a0620000-0000-0000-0000-0000000000c1','Специалист 0063','a0620000-0000-0000-0000-000000000002'),
  ('a0620000-0000-0000-0000-000000000011','a0620000-0000-0000-0000-0000000000c1','Специалист-2 0063','a0620000-0000-0000-0000-000000000003');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('a0620000-0000-0000-0000-000000000020','a0620000-0000-0000-0000-0000000000c1','Логопед',45,70000);

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('a0620000-0000-0000-0000-000000000040','a0620000-0000-0000-0000-0000000000c1','Ребёнок 0063','a0620000-0000-0000-0000-000000000030','a0620000-0000-0000-0000-000000000010');
-- Второй ребёнок центра А — ни у одного специалиста нет занятия с ним (Р4: первое заполнение).
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0620000-0000-0000-0000-000000000042','a0620000-0000-0000-0000-0000000000c1','Ребёнок-2 0063','a0620000-0000-0000-0000-000000000030');
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0620000-0000-0000-0000-000000000041','a0620000-0000-0000-0000-0000000000c3','Ребёнок В 0063','a0620000-0000-0000-0000-000000000031');

-- Живое занятие — граница clinical_teacher_sees для специалиста-1.
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('a0620000-0000-0000-0000-000000000050','a0620000-0000-0000-0000-0000000000c1','a0620000-0000-0000-0000-000000000020',
   'a0620000-0000-0000-0000-000000000010','a0620000-0000-0000-0000-000000000040', now() + interval '1 day', now() + interval '1 day 45 minutes', 'planned');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0620000-0000-0000-0000-000000000001','a0620000-0000-0000-0000-0000000000c1','owner',     null, null),
  ('a0620000-0000-0000-0000-000000000002','a0620000-0000-0000-0000-0000000000c1','teacher',   'a0620000-0000-0000-0000-000000000010', null),
  ('a0620000-0000-0000-0000-000000000003','a0620000-0000-0000-0000-0000000000c1','teacher',   'a0620000-0000-0000-0000-000000000011', null),
  ('a0620000-0000-0000-0000-000000000004','a0620000-0000-0000-0000-0000000000c1','parent',    null, 'a0620000-0000-0000-0000-000000000030'),
  ('a0620000-0000-0000-0000-000000000005','a0620000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('a0620000-0000-0000-0000-000000000006','a0620000-0000-0000-0000-0000000000c2','owner',     null, null),
  ('a0620000-0000-0000-0000-000000000007','a0620000-0000-0000-0000-0000000000c3','owner',     null, null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Запись под owner -----------------------------------------------------------------------------

select public.tests_claims('a0620000-0000-0000-0000-000000000001','a0620000-0000-0000-0000-0000000000c1');
set local role authenticated;

select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{"неизвестное_поле":"x"}'::jsonb) $q$,
  '22023', null, 'Неизвестный ключ p_fields — 22023');

select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{"pregnancy_number":0}'::jsonb) $q$,
  '23514', null, 'pregnancy_number=0 вне диапазона 1..20 — CHECK 23514');

select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040',
        jsonb_build_object('heredity', repeat('ф', 2001))) $q$,
  '23514', null, 'Текст сверх лимита длины — CHECK 23514');

select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{"pregnancy_number":"не помню"}'::jsonb) $q$,
  '22023', null, 'Нечисловая строка в pregnancy_number — понятная 22023, не голый 22P02 (Р13)');
select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{"heredity":{"a":1}}'::jsonb) $q$,
  '22023', null, 'Вложенный объект в текстовом поле — 22023, не тихая запись JSON-текста (Р13)');
select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{"collected_at":"вчера"}'::jsonb) $q$,
  '22023', null, 'collected_at не в формате ГГГГ-ММ-ДД — 22023 (Р13)');
select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{}'::jsonb) $q$,
  '22023', null, 'Пустой p_fields — 22023, не бесполезный update (Р14)');

create temporary table t0063_a as
  select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040',
    '{"pregnancy_number":1,"birth_number":1,"heredity":"без особенностей","cooing_age":"2 мес"}'::jsonb) as id;
grant select on t0063_a to authenticated;

select is(
  (select heredity from public.student_anamnesis where id = (select id from t0063_a)),
  'без особенностей', 'Поля записаны первым вызовом');
select is(
  (select collected_at from public.student_anamnesis where id = (select id from t0063_a)),
  public.center_today('a0620000-0000-0000-0000-0000000000c1'),
  'collected_at по умолчанию — сегодня центра, не передан явно (Р7)');

-- Прямая запись закрыта грантом.
select throws_ok(
  $q$ insert into public.student_anamnesis (center_id, student_id) values
      ('a0620000-0000-0000-0000-0000000000c1','a0620000-0000-0000-0000-000000000040') $q$,
  '42501', null, 'Прямой insert от owner — отказ грантом, только RPC');

-- Оптимистичная блокировка (Р2).
select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{"heredity":"подмена"}'::jsonb) $q$,
  '22023', null, 'p_expected_updated_at не передан (null) при существующей строке — расхождение, 22023');
select is(
  (select heredity from public.student_anamnesis where id = (select id from t0063_a)),
  'без особенностей', 'Значение не изменилось после отбитой попытки');

select lives_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040',
        '{"heredity":"уточнено на повторном приёме"}'::jsonb,
        (select updated_at from public.student_anamnesis where id = (select id from t0063_a))) $q$,
  'Верный p_expected_updated_at проходит');
select is(
  (select heredity from public.student_anamnesis where id = (select id from t0063_a)),
  'уточнено на повторном приёме', 'Значение обновилось');

-- null/'' в jsonb снимает поле; отсутствие ключа не трогает.
select lives_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040',
        jsonb_build_object('cooing_age', null),
        (select updated_at from public.student_anamnesis where id = (select id from t0063_a))) $q$,
  'Ключ с JSON null снимает поле');
select is(
  (select cooing_age from public.student_anamnesis where id = (select id from t0063_a)), null,
  'cooing_age снят');
select is(
  (select heredity from public.student_anamnesis where id = (select id from t0063_a)),
  'уточнено на повторном приёме', 'Поле, отсутствующее в p_fields, не тронуто');

reset role;


-- 3. Право записи — teacher: своя видимость, авторство или первое заполнение (Р4/Р10) -------------

-- Специалист-2 БЕЗ занятия с ребёнком-2 — анамнеза ещё нет, первое заполнение разрешено.
select public.tests_claims('a0620000-0000-0000-0000-000000000003','a0620000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000042', '{"heredity":"первичка"}'::jsonb) $q$,
  'Teacher без clinical_teacher_sees создаёт анамнез, которого ещё нет (Р4)');
select is(
  (select count(*)::int from public.student_anamnesis where student_id = 'a0620000-0000-0000-0000-000000000042'), 1,
  'Автор видит созданную запись сразу же (Р10) — иначе форма после сохранения читалась бы пустой');
select lives_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000042', '{"heredity":"уточнение автора"}'::jsonb,
        (select updated_at from public.student_anamnesis where student_id = 'a0620000-0000-0000-0000-000000000042')) $q$,
  'Автор правит свою же запись дальше без clinical_teacher_sees (Р10)');
reset role;

-- Специалист-1 не создавал эту запись и не видел этого ребёнка (его занятие — с ребёнком-1).
select public.tests_claims('a0620000-0000-0000-0000-000000000002','a0620000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_anamnesis where student_id = 'a0620000-0000-0000-0000-000000000042'), 0,
  'Чужой (не автор, нет clinical_teacher_sees) teacher — 0 строк по ребёнку-2');
select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000042', '{"heredity":"правка"}'::jsonb,
        (select updated_at from public.student_anamnesis where student_id = 'a0620000-0000-0000-0000-000000000042')) $q$,
  '42501', null, 'Чужой teacher правит существующую запись — отказ (не автор, нет clinical_teacher_sees, Р4)');
reset role;

-- Специалист-1 с занятием — читает и правит ребёнка-1.
select public.tests_claims('a0620000-0000-0000-0000-000000000002','a0620000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_anamnesis where student_id = 'a0620000-0000-0000-0000-000000000040'), 1,
  'Teacher со своим занятием видит анамнез ребёнка');
select lives_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{"vision_note":"без особенностей"}'::jsonb,
        (select updated_at from public.student_anamnesis where student_id = 'a0620000-0000-0000-0000-000000000040')) $q$,
  'Teacher со своим занятием правит анамнез');
reset role;


-- 4. Видимость по ролям ----------------------------------------------------------------------------

select public.tests_claims('a0620000-0000-0000-0000-000000000004','a0620000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_anamnesis), 0,
  'Родитель: 0 строк прямым запросом (ADR-005 — тот же класс, что sounds/speech_areas)');
select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{"heredity":"x"}'::jsonb) $q$,
  '42501', null, 'Родитель: set_student_anamnesis — 42501');
reset role;

select public.tests_claims('a0620000-0000-0000-0000-000000000005','a0620000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_anamnesis), 0,
  'Registrar: 0 строк (роль проверяется в definer-функции, не грантом)');
select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{"heredity":"x"}'::jsonb) $q$,
  '42501', null, 'Registrar: set_student_anamnesis — 42501');
reset role;

select public.tests_claims('a0620000-0000-0000-0000-000000000006','a0620000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is(
  (select count(*)::int from public.student_anamnesis), 0,
  'Центр Б не видит анамнез центра А');
select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000040', '{"heredity":"x"}'::jsonb) $q$,
  '42704', null, 'Центр Б: чужой ученик — «не найдена» (42704, не 42501, как 0038/0059)');
reset role;

-- Р14-класс регрессия: student.deleted_at выставлен мимо приложения —
-- restrictive-политика держит видимость даже для owner, tenant_admin один
-- этого не проверяет (0059 Р14, тот же класс дыры).
select public.tests_claims(null, null);
update public.students set deleted_at = now() where id = 'a0620000-0000-0000-0000-000000000040';
select public.tests_claims('a0620000-0000-0000-0000-000000000001','a0620000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_anamnesis where student_id = 'a0620000-0000-0000-0000-000000000040'), 0,
  'student.deleted_at выставлен мимо приложения — owner всё равно видит 0 (restrictive держит, не только роль)');
reset role;
select public.tests_claims(null, null);
update public.students set deleted_at = null where id = 'a0620000-0000-0000-0000-000000000040';


-- 5. Read-only центр — PT402 от guard, не 42501 -----------------------------------------------------

select public.tests_claims('a0620000-0000-0000-0000-000000000007','a0620000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $q$ select public.set_student_anamnesis('a0620000-0000-0000-0000-000000000041', '{"heredity":"x"}'::jsonb) $q$,
  'PT402', null, 'Просроченный центр: set_student_anamnesis — PT402 от guard, не 42501');
select lives_ok(
  $q$ select count(*) from public.student_anamnesis where student_id = 'a0620000-0000-0000-0000-000000000041' $q$,
  'select продолжает работать в read-only центре');
reset role;

select * from finish();
rollback;
