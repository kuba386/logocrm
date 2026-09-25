-- pgTAP: просодика — четвёртый раздел речевой карты (0067).
--
-- Заборы (первыми, до любого set role): таблица под readonly guard, в
-- allow-list экспорта (и её грант authenticated не потерян при переиздании
-- в этом же файле), гранты authenticated только select, наличие deleted_at
-- (история, не профиль), имена CHECK (девять — шесть категориальных полей +
-- дата + заключение + инвариант «не пусто»), список колонок у SET NULL
-- составного FK на teachers (Р5 — без него любой будущий reissue тихо
-- зануляет center_id), триггеры, execute-гранты трёх новых функций,
-- restrictive-политика существует.
-- Поведение: owner создаёт/читает/архивирует, архивная строка пропадает у
-- owner тоже; teacher с clinical_teacher_sees или primary_teacher_id —
-- симметрично читает и пишет, как в слоговой структуре; посторонний —
-- 42501 везде, включая правку чужой строки с created_by is null; teacher,
-- потерявший clinical_teacher_sees и не создававший запись сам, — 0 строк и
-- 42501; parent/registrar — 0 строк и 42501; центр Б — 42704; архивирует
-- только owner/admin; недопустимый код в любом из шести полей — 23514 от
-- CHECK; дата вне диапазона — 23514; полностью пустая запись — 22023 и от
-- record_, и (при обходе через update_) от именованного table-level CHECK;
-- '' в любом текстовом поле снимает его при правке, не трогает при create;
-- архивный специалист в p_teacher_id — 42704; read-only центр — PT402 на
-- всех трёх RPC; архивация ребёнка не прячет историю от owner/admin.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(68);


-- 1. Заборы по каталогу -------------------------------------------------------------------------

select ok(
  exists (select 1 from pg_trigger tg
           where tg.tgrelid = 'public.prosody_assessments'::regclass
             and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal),
  'prosody_assessments под readonly guard');

select set_eq(
  $$ select x.table_name from public.export_center_tables() x
      where x.table_name = 'prosody_assessments' $$,
  $$ values ('prosody_assessments') $$,
  'prosody_assessments в allow-list экспорта');

select ok(
  has_function_privilege('authenticated', 'public.export_center_tables()'::regprocedure, 'EXECUTE'),
  'export_center_tables() не потеряла грант authenticated при переиздании в этом файле');

select ok(
  has_table_privilege('authenticated', 'public.prosody_assessments'::regclass, 'SELECT')
  and not has_table_privilege('authenticated', 'public.prosody_assessments'::regclass, 'INSERT')
  and not has_table_privilege('authenticated', 'public.prosody_assessments'::regclass, 'UPDATE')
  and not has_table_privilege('authenticated', 'public.prosody_assessments'::regclass, 'DELETE')
  and not has_table_privilege('anon', 'public.prosody_assessments'::regclass, 'SELECT'),
  'authenticated — только select, anon — ничего');

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public' and table_name = 'prosody_assessments' and column_name = 'deleted_at'), 1,
  'История — deleted_at есть');

select set_eq(
  $$ select conname from pg_constraint
      where conrelid = 'public.prosody_assessments'::regclass and contype = 'c' $$,
  $$ values ('prosody_assessments_date_check'), ('prosody_assessments_tempo_check'),
            ('prosody_assessments_rhythm_check'), ('prosody_assessments_intonation_check'),
            ('prosody_assessments_breathing_check'), ('prosody_assessments_voice_check'),
            ('prosody_assessments_logical_stress_check'), ('prosody_assessments_conclusion_check'),
            ('prosody_assessments_not_empty') $$,
  'Имена CHECK — ровно те, что зарегистрированы в apps/web/lib/errors.ts CHECK_MESSAGES');

-- Р5: без списка колонок SET NULL зануляет весь составной FK, включая
-- center_id not null. Сверка именно с attnum teacher_id, не просто с
-- длиной массива (находка 4 ревью написанного SQL) — длина 1 с ошибочной
-- колонкой (например, center_id) тоже прошла бы наивный забор.
select is(
  (select confdelsetcols from pg_constraint where conname = 'prosody_assessments_teacher_fk'),
  (select array[a.attnum] from pg_attribute a
    where a.attrelid = 'public.prosody_assessments'::regclass and a.attname = 'teacher_id'),
  'FK на teachers — SET NULL именно у teacher_id, не у произвольной колонки той же длины (Р5)');

select ok(
  (select bool_and(exists (
     select 1 from pg_trigger tg where tg.tgrelid = 'public.prosody_assessments'::regclass
       and tg.tgname = t and not tg.tgisinternal))
     from unnest(array['prosody_assessments_set_updated_at', 'prosody_assessments_audit']) t),
  'moddatetime и audit-триггер на месте');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.oid::regprocedure::text in (
        'record_prosody_assessment(uuid,date,uuid,text,text,text,text,text,text,text)',
        'update_prosody_assessment(uuid,date,text,text,text,text,text,text,text,timestamp with time zone)',
        'archive_prosody_assessment(uuid)')), 3,
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
        'record_prosody_assessment(uuid,date,uuid,text,text,text,text,text,text,text)',
        'update_prosody_assessment(uuid,date,text,text,text,text,text,text,text,timestamp with time zone)',
        'archive_prosody_assessment(uuid)')),
  'Гранты новых функций: authenticated execute, anon/public/service_role — ничего');

select ok(
  exists (select 1 from pg_policies
           where schemaname = 'public' and tablename = 'prosody_assessments'
             and policyname = 'prosody_assessments_visible' and permissive = 'RESTRICTIVE' and cmd = 'SELECT'),
  'prosody_assessments_visible существует как RESTRICTIVE SELECT-политика');


-- Фикстура ----------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0670000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0067@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0670000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-primary-0067@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0670000-0000-0000-0000-000000000003','authenticated','authenticated','teacher-sees-0067@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0670000-0000-0000-0000-000000000004','authenticated','authenticated','teacher-nobody-0067@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0670000-0000-0000-0000-000000000005','authenticated','authenticated','parent-0067@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0670000-0000-0000-0000-000000000006','authenticated','authenticated','registrar-0067@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0670000-0000-0000-0000-000000000007','authenticated','authenticated','owner-b-0067@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0670000-0000-0000-0000-000000000008','authenticated','authenticated','owner-c-0067@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0670000-0000-0000-0000-000000000009','authenticated','authenticated','teacher-tobearchived-0067@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0670000-0000-0000-0000-0000000000c1','Центр А 0067','centr-a-0067','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0670000-0000-0000-0000-0000000000c2','Центр Б 0067','centr-b-0067','{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, settings, trial_ends_at) values
  ('a0670000-0000-0000-0000-0000000000c3','Центр В 0067 (просрочен)','centr-c-0067','{"timezone":"Asia/Bishkek"}'::jsonb, now() - interval '2 days');

insert into public.payers (id, center_id, full_name, phone) values
  ('a0670000-0000-0000-0000-000000000030','a0670000-0000-0000-0000-0000000000c1','Родитель 0067','+996700007601'),
  ('a0670000-0000-0000-0000-000000000031','a0670000-0000-0000-0000-0000000000c3','Родитель В 0067','+996700007603');

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0670000-0000-0000-0000-000000000010','a0670000-0000-0000-0000-0000000000c1','Специалист-назначенный 0067','a0670000-0000-0000-0000-000000000002'),
  ('a0670000-0000-0000-0000-000000000011','a0670000-0000-0000-0000-0000000000c1','Специалист-с-занятием 0067','a0670000-0000-0000-0000-000000000003'),
  ('a0670000-0000-0000-0000-000000000012','a0670000-0000-0000-0000-0000000000c1','Специалист-посторонний 0067','a0670000-0000-0000-0000-000000000004');
-- Уволенный специалист (Р6) — не привязан ни к одному membership, только
-- для проверки, что record_ отбивает архивного по id.
insert into public.teachers (id, center_id, full_name, deleted_at) values
  ('a0670000-0000-0000-0000-000000000013','a0670000-0000-0000-0000-0000000000c1','Специалист-уволенный 0067', now());
-- Специалист «скоро архивный» (Р6, ветка teacher) — живой membership и
-- занятие, только НЕ архивирован пока: архивируем прямым update ниже, между
-- двумя вызовами record_ от его же имени.
insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0670000-0000-0000-0000-000000000014','a0670000-0000-0000-0000-0000000000c1','Специалист-скоро-архивный 0067','a0670000-0000-0000-0000-000000000009');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('a0670000-0000-0000-0000-000000000020','a0670000-0000-0000-0000-0000000000c1','Логопед',45,70000);

-- Ребёнок А — занятие со специалистом «с занятием» (clinical_teacher_sees); можно отменить.
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0670000-0000-0000-0000-000000000040','a0670000-0000-0000-0000-0000000000c1','Ребёнок А 0067','a0670000-0000-0000-0000-000000000030');
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('a0670000-0000-0000-0000-000000000050','a0670000-0000-0000-0000-0000000000c1','a0670000-0000-0000-0000-000000000020',
   'a0670000-0000-0000-0000-000000000011','a0670000-0000-0000-0000-000000000040', now() + interval '1 day', now() + interval '1 day 45 minutes', 'planned');

-- Ребёнок Б — назначен специалисту-назначенному, занятия нет вовсе.
insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('a0670000-0000-0000-0000-000000000041','a0670000-0000-0000-0000-0000000000c1','Ребёнок Б 0067','a0670000-0000-0000-0000-000000000030','a0670000-0000-0000-0000-000000000010');

-- Ребёнок В — ничей.
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0670000-0000-0000-0000-000000000042','a0670000-0000-0000-0000-0000000000c1','Ребёнок В 0067','a0670000-0000-0000-0000-000000000030');

-- Ребёнок Г — центр В (просроченный trial).
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0670000-0000-0000-0000-000000000043','a0670000-0000-0000-0000-0000000000c3','Ребёнок Г 0067','a0670000-0000-0000-0000-000000000031');

-- Ребёнок Д — занятие со «скоро архивным» специалистом (Р6, ветка teacher).
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0670000-0000-0000-0000-000000000044','a0670000-0000-0000-0000-0000000000c1','Ребёнок Д 0067','a0670000-0000-0000-0000-000000000030');
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('a0670000-0000-0000-0000-000000000051','a0670000-0000-0000-0000-0000000000c1','a0670000-0000-0000-0000-000000000020',
   'a0670000-0000-0000-0000-000000000014','a0670000-0000-0000-0000-000000000044', now() + interval '1 day', now() + interval '1 day 45 minutes', 'planned');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0670000-0000-0000-0000-000000000001','a0670000-0000-0000-0000-0000000000c1','owner',     null, null),
  ('a0670000-0000-0000-0000-000000000002','a0670000-0000-0000-0000-0000000000c1','teacher',   'a0670000-0000-0000-0000-000000000010', null),
  ('a0670000-0000-0000-0000-000000000003','a0670000-0000-0000-0000-0000000000c1','teacher',   'a0670000-0000-0000-0000-000000000011', null),
  ('a0670000-0000-0000-0000-000000000004','a0670000-0000-0000-0000-0000000000c1','teacher',   'a0670000-0000-0000-0000-000000000012', null),
  ('a0670000-0000-0000-0000-000000000005','a0670000-0000-0000-0000-0000000000c1','parent',    null, 'a0670000-0000-0000-0000-000000000030'),
  ('a0670000-0000-0000-0000-000000000006','a0670000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('a0670000-0000-0000-0000-000000000007','a0670000-0000-0000-0000-0000000000c2','owner',     null, null),
  ('a0670000-0000-0000-0000-000000000008','a0670000-0000-0000-0000-0000000000c3','owner',     null, null),
  ('a0670000-0000-0000-0000-000000000009','a0670000-0000-0000-0000-0000000000c1','teacher',   'a0670000-0000-0000-0000-000000000014', null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Запись под owner на ребёнке А -----------------------------------------------------------------

select public.tests_claims('a0670000-0000-0000-0000-000000000001','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;

select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040', null, null,
        'not_a_tempo') $q$,
  '23514', null, 'Недопустимый код темпа — CHECK 23514, RPC список не дублирует');
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040', null, null,
        null, null, null, null, null, 'not_a_stress') $q$,
  '23514', null, 'Недопустимый код логического ударения — CHECK 23514');
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040',
        current_date + 10, null, 'normal') $q$,
  '23514', null, 'Дата за верхней границей — CHECK 23514 (с содержательным полем)');
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040', null, null,
        null, null, null, null, null, null, repeat('ф', 2001)) $q$,
  '23514', null, 'conclusion сверх 2000 символов — CHECK 23514');
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040') $q$,
  '22023', null, 'Ни одного содержательного поля — 22023, не тихая запись «нарушений нет»');
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040', null, null,
        '', '', '', '', '', '', '') $q$,
  '22023', null, 'Все поля — пустые строки (не null) — тоже 22023, сентинел нормализуется до guard''а');
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040', null, null,
        ' ', ' ', ' ', ' ', ' ', ' ', ' ') $q$,
  '22023', null, 'Все поля — голый пробел (не пустая строка) — тоже 22023, trim ловит и это (находка 2)');
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040', null,
        'a0670000-0000-0000-0000-000000000013', 'normal') $q$,
  '42704', null, 'Архивный специалист в p_teacher_id — 42704 (Р6)');

create temporary table t0067_a as
  select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040', null, null,
    'accelerated', 'disrupted', null, null, null, null, 'Первичное обследование') as id;
grant select on t0067_a to authenticated;

select is(
  (select tempo from public.prosody_assessments where id = (select id from t0067_a)), 'accelerated',
  'tempo сохранён как есть (Р2: не normal — реально ускорен)');
select is(
  (select intonation from public.prosody_assessments where id = (select id from t0067_a)), null,
  'intonation осталась NULL — не оценивалась, не «в норме» (Р2)');
select is(
  (select date from public.prosody_assessments where id = (select id from t0067_a)),
  public.center_today('a0670000-0000-0000-0000-0000000000c1'),
  'date по умолчанию — сегодня центра');

select throws_ok(
  $q$ insert into public.prosody_assessments (center_id, student_id, tempo) values
      ('a0670000-0000-0000-0000-0000000000c1','a0670000-0000-0000-0000-000000000040', 'normal') $q$,
  '42501', null, 'Прямой insert от owner — отказ грантом, только RPC');

select throws_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, 'slowed') $q$,
  '22023', null, 'p_expected_updated_at не передан — 22023');

select lives_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, 'slowed', null, 'normal',
        null, null, null, null,
        (select updated_at from public.prosody_assessments where id = (select id from t0067_a))) $q$,
  'Верный p_expected_updated_at проходит');
select is(
  (select tempo from public.prosody_assessments where id = (select id from t0067_a)), 'slowed',
  'tempo заменён (accelerated → slowed)');
select is(
  (select intonation from public.prosody_assessments where id = (select id from t0067_a)), 'normal',
  'intonation впервые проставлена как normal (была NULL)');
select is(
  (select rhythm from public.prosody_assessments where id = (select id from t0067_a)), 'disrupted',
  'rhythm не передан в этом вызове (null) — не тронут, остался прежним');

select lives_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, '', null, null,
        null, null, null, null,
        (select updated_at from public.prosody_assessments where id = (select id from t0067_a))) $q$,
  ''''' в tempo снимает его (сентинел)');
select is(
  (select tempo from public.prosody_assessments where id = (select id from t0067_a)), null,
  'tempo снят пустой строкой');
select is(
  (select rhythm from public.prosody_assessments where id = (select id from t0067_a)), 'disrupted',
  'rhythm по-прежнему не тронут — соседнее поле не пострадало');

select lives_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, null, null, null,
        null, null, null, '',
        (select updated_at from public.prosody_assessments where id = (select id from t0067_a))) $q$,
  ''''' в conclusion снимает его (сентинел)');
select is(
  (select conclusion from public.prosody_assessments where id = (select id from t0067_a)), null,
  'conclusion снят');
select lives_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, null, null, null,
        null, null, null, null,
        (select updated_at from public.prosody_assessments where id = (select id from t0067_a))) $q$,
  'null в conclusion не трогает (остаётся снятым)');
select is(
  (select conclusion from public.prosody_assessments where id = (select id from t0067_a)), null,
  'conclusion остался null после null-параметра');

-- Находка 3 ревью написанного SQL: тест на «не пусто» должен идти путём
-- формы (update_ со всеми семью ''), не только прямым update от postgres —
-- иначе будущий guard внутри update_ (например, дефолт 'normal' «чтобы не
-- падало») прошёл бы мимо этого забора незамеченным.
select throws_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, '', '', '',
        '', '', '', '',
        (select updated_at from public.prosody_assessments where id = (select id from t0067_a))) $q$,
  '23514', null, 'update_ всех семи полей в '''' — CHECK prosody_assessments_not_empty держит через RPC (находка 3)');
select throws_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, '', '', '',
        '', '', '', ' ',
        (select updated_at from public.prosody_assessments where id = (select id from t0067_a))) $q$,
  '23514', null, 'update_ шесть полей '''' + conclusion — один пробел — тоже 23514, пробел не обходит инвариант (находка 2)');

reset role;

-- Р4/находка 0066: инвариант «не пусто» — CHECK на таблице, не только RPC-
-- guard. Прямой update от postgres, обходя record_/update_, снимает всё
-- разом и должен упереться в именованный table-level constraint.
select throws_ok(
  $q$ update public.prosody_assessments set
        tempo = null, rhythm = null, intonation = null, breathing = null,
        voice = null, logical_stress = null, conclusion = null
      where id = (select id from t0067_a) $q$,
  '23514', null, 'Прямой update всех семи полей в NULL — CHECK prosody_assessments_not_empty держит (Р4)');


-- 3. Право доступа — симметрия чтения/записи ---------------------------------------------------

-- Специалист-назначенный (primary_teacher_id ребёнка Б, занятия нет) —
-- создаёт. p_teacher_id передан ЧУЖОЙ (специалист-посторонний, ...012) —
-- ветка teacher игнорирует параметр целиком и пишет my_teacher_id().
select public.tests_claims('a0670000-0000-0000-0000-000000000002','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
create temporary table t0067_c as
  select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000041',
    null, 'a0670000-0000-0000-0000-000000000012',
    'normal', 'normal', 'normal', 'normal', 'normal', 'normal') as id;
grant select on t0067_c to authenticated;
select is(
  (select teacher_id from public.prosody_assessments where id = (select id from t0067_c)),
  'a0670000-0000-0000-0000-000000000010'::uuid,
  'teacher_id — my_teacher_id() вызывающего (...010), переданный p_teacher_id (...012) проигнорирован');
select is(
  (select count(*)::int from public.prosody_assessments where student_id = 'a0670000-0000-0000-0000-000000000041'), 1,
  'Автор видит созданную запись сразу же');
reset role;

-- Специалист-посторонний — 42501 на создании.
select public.tests_claims('a0670000-0000-0000-0000-000000000004','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000042', null, null, 'normal') $q$,
  '42501', null, 'Посторонний teacher — 42501 на создании');
select is(
  (select count(*)::int from public.prosody_assessments where student_id = 'a0670000-0000-0000-0000-000000000042'), 0,
  'Посторонний teacher: 0 строк');
reset role;

-- Специалист-с-занятием читает и правит запись ребёнка А (созданную owner'ом).
select public.tests_claims('a0670000-0000-0000-0000-000000000003','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.prosody_assessments where student_id = 'a0670000-0000-0000-0000-000000000040'), 1,
  'Teacher со своим занятием видит запись ребёнка А, созданную owner''ом');
select lives_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, null, null, null,
        null, null, null, 'уточнение',
        (select updated_at from public.prosody_assessments where id = (select id from t0067_a))) $q$,
  'Teacher со своим занятием правит чужую (по авторству) запись — clinical_teacher_sees достаточно');
reset role;

-- Посторонний — 42501 и на правке существующей чужой строки, даже когда created_by is null.
select public.tests_claims(null, null);
update public.prosody_assessments set created_by = null where id = (select id from t0067_a);
select public.tests_claims('a0670000-0000-0000-0000-000000000004','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.prosody_assessments where student_id = 'a0670000-0000-0000-0000-000000000040'), 0,
  'Посторонний teacher: 0 строк по записи ребёнка А');
select throws_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  '42501', null, 'Посторонний teacher — 42501 на правке чужой строки, created_by is null не пропускает');
reset role;

-- Специалист-с-занятием теряет clinical_teacher_sees (занятие отменили) — не создавал запись сам.
select public.tests_claims(null, null);
update public.lessons set status = 'cancelled' where id = 'a0670000-0000-0000-0000-000000000050';
select public.tests_claims('a0670000-0000-0000-0000-000000000003','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.prosody_assessments where student_id = 'a0670000-0000-0000-0000-000000000040'), 0,
  'Teacher без clinical_teacher_sees (занятие отменено), не автор и не primary_teacher_id — 0 строк');
select throws_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  '42501', null, 'Тот же teacher — 42501 на правке (потерял единственное основание доступа)');
reset role;

-- Находка 1 ревью написанного SQL: Р6 закрывался только на пути
-- owner/admin (p_teacher_id) — путь teacher (my_teacher_id()) архивного
-- специалиста пропускал молча. До архивации — запись проходит нормально
-- (clinical_teacher_sees от неотменённого занятия); ПОСЛЕ прямой архивации
-- teachers.deleted_at (без отзыва membership отдельным действием — ровно
-- тот пробел, который Р6 описывает) — тот же вызов обязан 42704.
select public.tests_claims('a0670000-0000-0000-0000-000000000009','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000044', null, null, 'normal') $q$,
  'До архивации специалиста — запись проходит нормально (clinical_teacher_sees)');
reset role;

select public.tests_claims(null, null);
update public.teachers set deleted_at = now() where id = 'a0670000-0000-0000-0000-000000000014';
select public.tests_claims('a0670000-0000-0000-0000-000000000009','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000044', null, null, 'normal') $q$,
  '42704', null, 'После архивации специалиста (membership не тронут) — record_ отбивает по ветке teacher тоже (Р6, находка 1)');
reset role;


-- 4. Видимость по ролям и архивация ----------------------------------------------------------------

select public.tests_claims('a0670000-0000-0000-0000-000000000005','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.prosody_assessments), 0, 'Родитель: 0 строк прямым запросом');
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040', null, null, 'normal') $q$,
  '42501', null, 'Родитель: record_prosody_assessment — 42501');
reset role;

select public.tests_claims('a0670000-0000-0000-0000-000000000006','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.prosody_assessments), 0, 'Registrar: 0 строк');
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040', null, null, 'normal') $q$,
  '42501', null, 'Registrar: record_prosody_assessment — 42501');
reset role;

select public.tests_claims('a0670000-0000-0000-0000-000000000007','a0670000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is(
  (select count(*)::int from public.prosody_assessments), 0, 'Центр Б не видит записи центра А');
select throws_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  '42704', null, 'Центр Б: чужая запись — 42704');
reset role;

-- Teacher не может архивировать — только owner/admin.
select public.tests_claims('a0670000-0000-0000-0000-000000000001','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
create temporary table t0067_b as
  select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000040', null, null, 'normal') as id;
grant select on t0067_b to authenticated;
reset role;

select public.tests_claims('a0670000-0000-0000-0000-000000000003','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.archive_prosody_assessment((select id from t0067_b)) $q$,
  '42501', null, 'Teacher не может архивировать — только owner/admin');
reset role;

-- История: два обследования на одного ребёнка, обе видны; архив одной не трогает вторую.
select public.tests_claims('a0670000-0000-0000-0000-000000000001','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.prosody_assessments where student_id = 'a0670000-0000-0000-0000-000000000040'), 2,
  'История: две записи на ребёнка А видны обе (не upsert)');
select ok(
  public.archive_prosody_assessment((select id from t0067_b)),
  'Архивация второй записи проходит');
select is(
  (select count(*)::int from public.prosody_assessments where student_id = 'a0670000-0000-0000-0000-000000000040'), 1,
  'После архива одной — вторая осталась видимой (архив не каскадом)');
reset role;

-- student_alive в restrictive держит ВСЕХ, включая owner/admin (образец 0066 Р13).
select public.tests_claims(null, null);
update public.students set deleted_at = now() where id = 'a0670000-0000-0000-0000-000000000040';
select public.tests_claims('a0670000-0000-0000-0000-000000000001','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.prosody_assessments where student_id = 'a0670000-0000-0000-0000-000000000040'), 0,
  'student.deleted_at мимо приложения — owner тоже видит 0 (restrictive держит всех без исключения)');
select throws_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_a), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  '42704', null, 'update_ от owner на записи мёртвого ребёнка — тоже 42704: запись не шире чтения (Р10)');
reset role;

select public.tests_claims(null, null);
update public.students set deleted_at = null where id = 'a0670000-0000-0000-0000-000000000040';

-- Единственный сценарий, где restrictive и student_alive в update_ реально
-- что-то решают, — автор-teacher БЕЗ clinical_teacher_sees/primary_teacher_id
-- (ребёнок Б, специалист-назначенный t0067_c — уже автор записи из section 3).
select public.tests_claims(null, null);
update public.students set deleted_at = now() where id = 'a0670000-0000-0000-0000-000000000041';
select public.tests_claims('a0670000-0000-0000-0000-000000000002','a0670000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.prosody_assessments where student_id = 'a0670000-0000-0000-0000-000000000041'), 0,
  'Автор-teacher теряет видимость своей же записи, когда student_alive ложно (единственный вооружённый сценарий)');
select throws_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_c), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  '42501', null, 'update_ бьётся о student_alive в ветке teacher, даже с id на руках и через RPC (не 42704)');
reset role;
select public.tests_claims(null, null);
update public.students set deleted_at = null where id = 'a0670000-0000-0000-0000-000000000041';


-- 5. Read-only центр — PT402 от guard на всех трёх RPC -----------------------------------------------

select public.tests_claims('a0670000-0000-0000-0000-000000000008','a0670000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $q$ select public.record_prosody_assessment('a0670000-0000-0000-0000-000000000043', null, null, 'normal') $q$,
  'PT402', null, 'Просроченный центр: record_prosody_assessment — PT402 от guard');
reset role;

-- Строка мимо guard (postgres, через data-modifying CTE — CREATE TABLE AS
-- принимает только query, не голый INSERT) — проверяет update_/archive_ отдельно.
select public.tests_claims(null, null);
create temporary table t0067_ro as
  with ins as (
    insert into public.prosody_assessments (center_id, student_id, tempo)
      values ('a0670000-0000-0000-0000-0000000000c3','a0670000-0000-0000-0000-000000000043', 'normal')
      returning id
  )
  select id from ins;
grant select on t0067_ro to authenticated;

select public.tests_claims('a0670000-0000-0000-0000-000000000008','a0670000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $q$ select public.update_prosody_assessment((select id from t0067_ro), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  'PT402', null, 'Просроченный центр: update_prosody_assessment — PT402 от guard');
select throws_ok(
  $q$ select public.archive_prosody_assessment((select id from t0067_ro)) $q$,
  'PT402', null, 'Просроченный центр: archive_prosody_assessment — PT402 от guard');
select lives_ok(
  $q$ select count(*) from public.prosody_assessments where student_id = 'a0670000-0000-0000-0000-000000000043' $q$,
  'select продолжает работать в read-only центре');
reset role;

select * from finish();
rollback;
