-- pgTAP: чтение-письмо — пятый, последний раздел речевой карты (0068).
--
-- Заборы (первыми, до любого set role): таблица под readonly guard, в
-- allow-list экспорта (грант authenticated не потерян при переиздании в
-- этом же файле), гранты authenticated только select, наличие deleted_at
-- (история), имена CHECK (девять — пять скаляров + два массива + дата +
-- заключение + инвариант «не пусто»), список колонок у SET NULL составного
-- FK на teachers, триггеры, execute-гранты трёх новых функций,
-- restrictive-политика существует.
-- Поведение: owner создаёт/читает/архивирует, архивная строка пропадает у
-- owner тоже; teacher с clinical_teacher_sees или primary_teacher_id —
-- симметрично читает и пишет; посторонний — 42501 везде, включая правку
-- чужой строки с created_by is null; teacher, потерявший
-- clinical_teacher_sees и не создававший запись сам, — 0 строк и 42501;
-- parent/registrar — 0 строк и 42501; центр Б — 42704; архивирует только
-- owner/admin; недопустимый код в любом из пяти скаляров ИЛИ чужой код в
-- одном из двух массивов — 23514 от CHECK; дата вне диапазона — 23514;
-- полностью пустая запись — 22023 от record_ и 23514 от table-level CHECK
-- через update_ (не только прямым update от postgres — находка 3 ревью
-- 0067, здесь заранее); '' /пробел в скаляре и '{}' в массиве снимают поле
-- при правке, не трогают при создании; архивный специалист — 42704 и на
-- пути owner/admin (p_teacher_id), и на пути teacher (my_teacher_id(),
-- живой membership) — второй путь 0067 пропустил в первой редакции;
-- read-only центр — PT402 на всех трёх RPC; архивация ребёнка не прячет
-- историю от owner/admin, но update_ на ней — 42704 для всех ролей.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(89);


-- 1. Заборы по каталогу -------------------------------------------------------------------------

select ok(
  exists (select 1 from pg_trigger tg
           where tg.tgrelid = 'public.reading_writing_assessments'::regclass
             and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal),
  'reading_writing_assessments под readonly guard');

select set_eq(
  $$ select x.table_name from public.export_center_tables() x
      where x.table_name = 'reading_writing_assessments' $$,
  $$ values ('reading_writing_assessments') $$,
  'reading_writing_assessments в allow-list экспорта');

select ok(
  has_function_privilege('authenticated', 'public.export_center_tables()'::regprocedure, 'EXECUTE'),
  'export_center_tables() не потеряла грант authenticated при переиздании в этом файле');

select ok(
  has_table_privilege('authenticated', 'public.reading_writing_assessments'::regclass, 'SELECT')
  and not has_table_privilege('authenticated', 'public.reading_writing_assessments'::regclass, 'INSERT')
  and not has_table_privilege('authenticated', 'public.reading_writing_assessments'::regclass, 'UPDATE')
  and not has_table_privilege('authenticated', 'public.reading_writing_assessments'::regclass, 'DELETE')
  and not has_table_privilege('anon', 'public.reading_writing_assessments'::regclass, 'SELECT'),
  'authenticated — только select, anon — ничего');

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public' and table_name = 'reading_writing_assessments' and column_name = 'deleted_at'), 1,
  'История — deleted_at есть');

select set_eq(
  $$ select conname from pg_constraint
      where conrelid = 'public.reading_writing_assessments'::regclass and contype = 'c' $$,
  $$ values ('reading_writing_assessments_date_check'), ('reading_writing_assessments_reading_method_check'),
            ('reading_writing_assessments_reading_pace_check'), ('reading_writing_assessments_reading_comprehension_check'),
            ('reading_writing_assessments_reading_errors_check'), ('reading_writing_assessments_writing_quality_check'),
            ('reading_writing_assessments_writing_errors_check'), ('reading_writing_assessments_conclusion_check'),
            ('reading_writing_assessments_not_empty'), ('reading_writing_assessments_writing_consistency') $$,
  'Имена CHECK — ровно те, что зарегистрированы в apps/web/lib/errors.ts CHECK_MESSAGES');

select is(
  (select confdelsetcols from pg_constraint where conname = 'reading_writing_assessments_teacher_fk'),
  (select array[a.attnum] from pg_attribute a
    where a.attrelid = 'public.reading_writing_assessments'::regclass and a.attname = 'teacher_id'),
  'FK на teachers — SET NULL именно у teacher_id, не у произвольной колонки той же длины');

select ok(
  (select bool_and(exists (
     select 1 from pg_trigger tg where tg.tgrelid = 'public.reading_writing_assessments'::regclass
       and tg.tgname = t and not tg.tgisinternal))
     from unnest(array['reading_writing_assessments_set_updated_at', 'reading_writing_assessments_audit']) t),
  'moddatetime и audit-триггер на месте');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.oid::regprocedure::text in (
        'record_reading_writing_assessment(uuid,date,uuid,text,text,text,text[],text,text[],text)',
        'update_reading_writing_assessment(uuid,date,text,text,text,text[],text,text[],text,timestamp with time zone)',
        'archive_reading_writing_assessment(uuid)')), 3,
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
        'record_reading_writing_assessment(uuid,date,uuid,text,text,text,text[],text,text[],text)',
        'update_reading_writing_assessment(uuid,date,text,text,text,text[],text,text[],text,timestamp with time zone)',
        'archive_reading_writing_assessment(uuid)')),
  'Гранты новых функций: authenticated execute, anon/public/service_role — ничего');

select ok(
  exists (select 1 from pg_policies
           where schemaname = 'public' and tablename = 'reading_writing_assessments'
             and policyname = 'reading_writing_assessments_visible' and permissive = 'RESTRICTIVE' and cmd = 'SELECT'),
  'reading_writing_assessments_visible существует как RESTRICTIVE SELECT-политика');

-- Находка 2 ревью написанного SQL: контракт Р4 («reading_method выведен из
-- оси нормы») держался только на комментарии — забор проверяет CHECK
-- напрямую, а не полагается на то, что его не тронут молча.
select ok(
  (select bool_and(pg_get_constraintdef(oid) like '%''normal''%')
     from pg_constraint
    where conname in ('reading_writing_assessments_reading_pace_check',
                       'reading_writing_assessments_reading_comprehension_check',
                       'reading_writing_assessments_writing_quality_check')),
  '''normal'' есть в CHECK всех трёх осей нормы (reading_pace/reading_comprehension/writing_quality)');
select ok(
  not (select pg_get_constraintdef(oid) like '%''normal''%'
     from pg_constraint where conname = 'reading_writing_assessments_reading_method_check'),
  '''normal'' отсутствует в CHECK reading_method — описательная шкала, не ось нормы (Р4)');

-- Находка 6: верхние границы cardinality должны совпадать с числом кодов
-- в своих же <@ списках — самосогласованный забор, не «на глаз».
select is(
  (select (regexp_match(pg_get_constraintdef(oid), 'cardinality\(reading_errors\) <= (\d+)'))[1]::int
     from pg_constraint where conname = 'reading_writing_assessments_reading_errors_check'),
  6, 'cardinality-кап reading_errors (6) равен числу кодов в <@ списке');
select is(
  (select (regexp_match(pg_get_constraintdef(oid), 'cardinality\(writing_errors\) <= (\d+)'))[1]::int
     from pg_constraint where conname = 'reading_writing_assessments_writing_errors_check'),
  8, 'cardinality-кап writing_errors (8) равен числу кодов в <@ списке');


-- Фикстура ----------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0680000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0068@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0680000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-primary-0068@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0680000-0000-0000-0000-000000000003','authenticated','authenticated','teacher-sees-0068@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0680000-0000-0000-0000-000000000004','authenticated','authenticated','teacher-nobody-0068@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0680000-0000-0000-0000-000000000005','authenticated','authenticated','parent-0068@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0680000-0000-0000-0000-000000000006','authenticated','authenticated','registrar-0068@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0680000-0000-0000-0000-000000000007','authenticated','authenticated','owner-b-0068@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0680000-0000-0000-0000-000000000008','authenticated','authenticated','owner-c-0068@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0680000-0000-0000-0000-000000000009','authenticated','authenticated','teacher-tobearchived-0068@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0680000-0000-0000-0000-0000000000c1','Центр А 0068','centr-a-0068','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0680000-0000-0000-0000-0000000000c2','Центр Б 0068','centr-b-0068','{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, settings, trial_ends_at) values
  ('a0680000-0000-0000-0000-0000000000c3','Центр В 0068 (просрочен)','centr-c-0068','{"timezone":"Asia/Bishkek"}'::jsonb, now() - interval '2 days');

insert into public.payers (id, center_id, full_name, phone) values
  ('a0680000-0000-0000-0000-000000000030','a0680000-0000-0000-0000-0000000000c1','Родитель 0068','+996700008601'),
  ('a0680000-0000-0000-0000-000000000031','a0680000-0000-0000-0000-0000000000c3','Родитель В 0068','+996700008603');

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0680000-0000-0000-0000-000000000010','a0680000-0000-0000-0000-0000000000c1','Специалист-назначенный 0068','a0680000-0000-0000-0000-000000000002'),
  ('a0680000-0000-0000-0000-000000000011','a0680000-0000-0000-0000-0000000000c1','Специалист-с-занятием 0068','a0680000-0000-0000-0000-000000000003'),
  ('a0680000-0000-0000-0000-000000000012','a0680000-0000-0000-0000-0000000000c1','Специалист-посторонний 0068','a0680000-0000-0000-0000-000000000004');
-- Уволенный специалист — не привязан ни к одному membership, только для
-- проверки, что record_ отбивает архивного по id (путь owner/admin).
insert into public.teachers (id, center_id, full_name, deleted_at) values
  ('a0680000-0000-0000-0000-000000000013','a0680000-0000-0000-0000-0000000000c1','Специалист-уволенный 0068', now());
-- Специалист «скоро архивный» — живой membership и занятие (путь teacher,
-- находка 1 ревью 0067 — проверка должна ловить оба пути).
insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0680000-0000-0000-0000-000000000014','a0680000-0000-0000-0000-0000000000c1','Специалист-скоро-архивный 0068','a0680000-0000-0000-0000-000000000009');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('a0680000-0000-0000-0000-000000000020','a0680000-0000-0000-0000-0000000000c1','Логопед',45,70000);

-- Ребёнок А — занятие со специалистом «с занятием» (clinical_teacher_sees); можно отменить.
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0680000-0000-0000-0000-000000000040','a0680000-0000-0000-0000-0000000000c1','Ребёнок А 0068','a0680000-0000-0000-0000-000000000030');
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('a0680000-0000-0000-0000-000000000050','a0680000-0000-0000-0000-0000000000c1','a0680000-0000-0000-0000-000000000020',
   'a0680000-0000-0000-0000-000000000011','a0680000-0000-0000-0000-000000000040', now() + interval '1 day', now() + interval '1 day 45 minutes', 'planned');

-- Ребёнок Б — назначен специалисту-назначенному, занятия нет вовсе.
insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('a0680000-0000-0000-0000-000000000041','a0680000-0000-0000-0000-0000000000c1','Ребёнок Б 0068','a0680000-0000-0000-0000-000000000030','a0680000-0000-0000-0000-000000000010');

-- Ребёнок В — ничей.
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0680000-0000-0000-0000-000000000042','a0680000-0000-0000-0000-0000000000c1','Ребёнок В 0068','a0680000-0000-0000-0000-000000000030');

-- Ребёнок Г — центр В (просроченный trial).
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0680000-0000-0000-0000-000000000043','a0680000-0000-0000-0000-0000000000c3','Ребёнок Г 0068','a0680000-0000-0000-0000-000000000031');

-- Ребёнок Д — занятие со «скоро архивным» специалистом.
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0680000-0000-0000-0000-000000000044','a0680000-0000-0000-0000-0000000000c1','Ребёнок Д 0068','a0680000-0000-0000-0000-000000000030');
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('a0680000-0000-0000-0000-000000000051','a0680000-0000-0000-0000-0000000000c1','a0680000-0000-0000-0000-000000000020',
   'a0680000-0000-0000-0000-000000000014','a0680000-0000-0000-0000-000000000044', now() + interval '1 day', now() + interval '1 day 45 minutes', 'planned');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0680000-0000-0000-0000-000000000001','a0680000-0000-0000-0000-0000000000c1','owner',     null, null),
  ('a0680000-0000-0000-0000-000000000002','a0680000-0000-0000-0000-0000000000c1','teacher',   'a0680000-0000-0000-0000-000000000010', null),
  ('a0680000-0000-0000-0000-000000000003','a0680000-0000-0000-0000-0000000000c1','teacher',   'a0680000-0000-0000-0000-000000000011', null),
  ('a0680000-0000-0000-0000-000000000004','a0680000-0000-0000-0000-0000000000c1','teacher',   'a0680000-0000-0000-0000-000000000012', null),
  ('a0680000-0000-0000-0000-000000000005','a0680000-0000-0000-0000-0000000000c1','parent',    null, 'a0680000-0000-0000-0000-000000000030'),
  ('a0680000-0000-0000-0000-000000000006','a0680000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('a0680000-0000-0000-0000-000000000007','a0680000-0000-0000-0000-0000000000c2','owner',     null, null),
  ('a0680000-0000-0000-0000-000000000008','a0680000-0000-0000-0000-0000000000c3','owner',     null, null),
  ('a0680000-0000-0000-0000-000000000009','a0680000-0000-0000-0000-0000000000c1','teacher',   'a0680000-0000-0000-0000-000000000014', null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Запись под owner на ребёнке А -----------------------------------------------------------------

select public.tests_claims('a0680000-0000-0000-0000-000000000001','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;

select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        'not_a_method') $q$,
  '23514', null, 'Недопустимый код способа чтения — CHECK 23514');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        null, 'not_a_pace') $q$,
  '23514', null, 'Недопустимый код темпа чтения — CHECK 23514');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        null, null, 'not_a_comprehension') $q$,
  '23514', null, 'Недопустимый код понимания прочитанного — CHECK 23514');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        null, null, null, array['not_a_reading_error']) $q$,
  '23514', null, 'Недопустимый код ошибки чтения — CHECK 23514');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        null, null, null, null, 'not_a_quality') $q$,
  '23514', null, 'Недопустимый код качества письма — CHECK 23514');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        null, null, null, null, null, array['not_a_writing_error']) $q$,
  '23514', null, 'Недопустимый код ошибки письма — CHECK 23514');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        null, null, null, null, null, array['guessing']) $q$,
  '23514', null, 'Код чтения (guessing) в поле ошибок письма — своё множество, чужой код тоже 23514');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        null, null, null, array['acoustic_substitution']) $q$,
  '23514', null, 'Код письма (acoustic_substitution) в поле ошибок чтения — 23514');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        null, null, null, array['substitution', null]) $q$,
  '23514', null, 'NULL-элемент в массиве ошибок чтения — 23514');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040',
        current_date + 10, null, 'whole_word') $q$,
  '23514', null, 'Дата за верхней границей — CHECK 23514 (с содержательным полем)');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        null, null, null, null, null, null, repeat('ф', 2001)) $q$,
  '23514', null, 'conclusion сверх 2000 символов — CHECK 23514');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040') $q$,
  '22023', null, 'Ни одного содержательного поля — 22023, не тихая запись «нарушений нет»');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        '', '', '', '{}'::text[], '', '{}'::text[], '') $q$,
  '22023', null, 'Все скаляры — пустые строки, оба массива — пустые — тоже 22023, сентинел нормализуется до guard''а');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        ' ', ' ', ' ', '{}'::text[], ' ', '{}'::text[], ' ') $q$,
  '22023', null, 'Все скаляры — голый пробел — тоже 22023, trim ловит и это');
select lives_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000042', null, null,
        null, null, null, null, null, array['omission']) $q$,
  'Позитивный контроль: только writing_errors заполнен — успех (ребёнок В, отдельно от основного сценария)');
select lives_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000042', null, null,
        null, null, null,
        array['substitution', 'omission', 'permutation', 'guessing', 'repetition', 'stumbling']) $q$,
  'Все шесть кодов reading_errors разом — не упирается в cardinality-кап (находка 6, поведенческая проверка)');
select lives_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000042', null, null,
        null, null, null, null, null,
        array['acoustic_substitution', 'optical_substitution', 'omission', 'permutation',
              'word_boundary', 'mirror_writing', 'agrammatism', 'incomplete_elements']) $q$,
  'Все восемь кодов writing_errors разом — не упирается в cardinality-кап (находка 6, поведенческая проверка)');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null,
        'a0680000-0000-0000-0000-000000000013', 'whole_word') $q$,
  '42704', null, 'Архивный специалист в p_teacher_id — 42704 (путь owner/admin)');

create temporary table t0068_a as
  select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
    'syllable_by_syllable', 'slowed', 'impaired', array['omission', 'omission', 'guessing'],
    'impaired', array['optical_substitution'], 'Первичное обследование') as id;
grant select on t0068_a to authenticated;

select is(
  (select reading_errors from public.reading_writing_assessments where id = (select id from t0068_a)),
  array['guessing', 'omission'],
  'reading_errors: дубль схлопнут, алфавитный порядок (guessing < omission)');
select is(
  (select writing_errors from public.reading_writing_assessments where id = (select id from t0068_a)),
  array['optical_substitution'],
  'writing_errors сохранён');
select is(
  (select reading_method from public.reading_writing_assessments where id = (select id from t0068_a)),
  'syllable_by_syllable', 'reading_method сохранён (Р4: без normal — это не ось нормы)');
select is(
  (select date from public.reading_writing_assessments where id = (select id from t0068_a)),
  public.center_today('a0680000-0000-0000-0000-0000000000c1'),
  'date по умолчанию — сегодня центра');

select throws_ok(
  $q$ insert into public.reading_writing_assessments (center_id, student_id, reading_pace) values
      ('a0680000-0000-0000-0000-0000000000c1','a0680000-0000-0000-0000-000000000040', 'normal') $q$,
  '42501', null, 'Прямой insert от owner — отказ грантом, только RPC');

-- Находка 1 ревью написанного SQL: writing_quality='normal' одновременно
-- с непустым writing_errors — CHECK reading_writing_assessments_writing_
-- consistency (Р11), проверено и через record_, и через update_ (на
-- t0068_a, где writing_errors=['optical_substitution'] ещё не тронут).
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null,
        null, null, null, null, 'normal', array['omission']) $q$,
  '23514', null, 'record_: writing_quality=normal + непустой writing_errors — 23514 (Р11)');
select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, null, null,
        null, 'normal', null, null,
        (select updated_at from public.reading_writing_assessments where id = (select id from t0068_a))) $q$,
  '23514', null, 'update_: writing_quality=normal поверх уже непустого writing_errors — 23514 (Р11)');

-- Позитивный контроль Р3: NULL и 'normal' у writing_quality с пустым
-- writing_errors — различимые состояния («не оценивалось» vs «оценено,
-- ошибок нет»), ради которых колонка и вводилась.
create temporary table t0068_wq_null as
  select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000042', null, null,
    'whole_word') as id;
grant select on t0068_wq_null to authenticated;
create temporary table t0068_wq_normal as
  select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000042', null, null,
    'whole_word', null, null, null, 'normal') as id;
grant select on t0068_wq_normal to authenticated;
select is(
  (select writing_quality from public.reading_writing_assessments where id = (select id from t0068_wq_null)),
  null, 'writing_quality NULL — «не оценивалось» (Р3)');
select is(
  (select writing_quality from public.reading_writing_assessments where id = (select id from t0068_wq_normal)),
  'normal', 'writing_quality normal — «оценено, ошибок нет», различимо от NULL (Р3)');

select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, 'normal') $q$,
  '22023', null, 'p_expected_updated_at не передан — 22023');

-- Находка 3 ревью: отрицательная ветка замка проверялась только null'ом
-- (совпадающие значения через now()/подзапрос неотличимы внутри одной
-- транзакции — now() = updated_at любой только что изменённой строки).
-- Явно устаревшее НЕ-null значение — отдельный, самостоятельный случай.
select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, 'normal', null,
        null, null, null, null,
        (select updated_at - interval '1 second' from public.reading_writing_assessments where id = (select id from t0068_a))) $q$,
  '22023', null, 'Заведомо устаревший (не-null) p_expected_updated_at — тоже 22023, не только null-случай');

select lives_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, 'normal', null,
        null, null, null, null,
        (select updated_at from public.reading_writing_assessments where id = (select id from t0068_a))) $q$,
  'Верный p_expected_updated_at проходит');
select is(
  (select reading_pace from public.reading_writing_assessments where id = (select id from t0068_a)), 'normal',
  'reading_pace заменён (slowed → normal)');
select is(
  (select reading_comprehension from public.reading_writing_assessments where id = (select id from t0068_a)), 'impaired',
  'reading_comprehension не передан в этом вызове (null) — не тронут, остался прежним');

select lives_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, '', null,
        null, null, null, null,
        (select updated_at from public.reading_writing_assessments where id = (select id from t0068_a))) $q$,
  ''''' в reading_pace снимает его (сентинел)');
select is(
  (select reading_pace from public.reading_writing_assessments where id = (select id from t0068_a)), null,
  'reading_pace снят пустой строкой');

select lives_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, null, null,
        '{}'::text[], null, null, null,
        (select updated_at from public.reading_writing_assessments where id = (select id from t0068_a))) $q$,
  'Пустой массив в reading_errors — валидная замена (улучшение), не «не трогать»');
select is(
  (select reading_errors from public.reading_writing_assessments where id = (select id from t0068_a)),
  '{}'::text[], 'reading_errors очищен явной пустой заменой');
select is(
  (select writing_errors from public.reading_writing_assessments where id = (select id from t0068_a)),
  array['optical_substitution'], 'writing_errors не тронут — не передан в этом вызове');

select lives_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, null, null,
        null, null, null, '',
        (select updated_at from public.reading_writing_assessments where id = (select id from t0068_a))) $q$,
  ''''' в conclusion снимает его (сентинел)');
select is(
  (select conclusion from public.reading_writing_assessments where id = (select id from t0068_a)), null,
  'conclusion снят');
select lives_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, null, null,
        null, null, null, null,
        (select updated_at from public.reading_writing_assessments where id = (select id from t0068_a))) $q$,
  'null в conclusion не трогает (остаётся снятым)');
select is(
  (select conclusion from public.reading_writing_assessments where id = (select id from t0068_a)), null,
  'conclusion остался null после null-параметра');

-- Находка 3 ревью 0067 (перенесённая заранее): тест на «не пусто» должен
-- идти путём формы (update_ со всеми полями пустыми), не только прямым
-- update от postgres — иначе будущий guard внутри update_ прошёл бы мимо
-- этого забора незамеченным. Находка 4 ревью написанного SQL: предпосылка
-- «что именно ещё держит not_empty живым» должна быть проверяемым
-- ассертом, не описанием в комментарии — снимок ниже фиксирует, что на
-- этот момент реально живы reading_method и writing_errors (не
-- reading_comprehension/writing_quality, как утверждала прежняя версия
-- этого комментария).
select is(
  (select to_jsonb(t) - 'id' - 'center_id' - 'student_id' - 'teacher_id' - 'date'
                      - 'created_at' - 'updated_at' - 'created_by' - 'deleted_at'
     from public.reading_writing_assessments t where t.id = (select id from t0068_a)),
  '{"reading_method":"syllable_by_syllable","reading_pace":null,"reading_comprehension":"impaired","reading_errors":[],"writing_quality":"impaired","writing_errors":["optical_substitution"],"conclusion":null}'::jsonb,
  'Снимок строки перед проверкой «не пусто»: not_empty сейчас держат reading_method и writing_errors');
select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, '', '', '',
        '{}'::text[], '', '{}'::text[], '',
        (select updated_at from public.reading_writing_assessments where id = (select id from t0068_a))) $q$,
  '23514', null, 'update_ всех полей в пустое значение — CHECK reading_writing_assessments_not_empty держит через RPC');
select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, '', '', '',
        '{}'::text[], '', '{}'::text[], ' ',
        (select updated_at from public.reading_writing_assessments where id = (select id from t0068_a))) $q$,
  '23514', null, 'То же с conclusion — один пробел — тоже 23514, пробел не обходит инвариант');

reset role;

-- Р2/находка 0067: инвариант «не пусто» — CHECK на таблице, не только
-- RPC-guard. Прямой update от postgres, обходя record_/update_, снимает
-- всё разом и должен упереться в именованный table-level constraint.
select throws_ok(
  $q$ update public.reading_writing_assessments set
        reading_method = null, reading_pace = null, reading_comprehension = null, reading_errors = '{}',
        writing_quality = null, writing_errors = '{}', conclusion = null
      where id = (select id from t0068_a) $q$,
  '23514', null, 'Прямой update всех полей в пусто — CHECK reading_writing_assessments_not_empty держит');


-- 3. Право доступа — симметрия чтения/записи ---------------------------------------------------

-- Специалист-назначенный (primary_teacher_id ребёнка Б, занятия нет) —
-- создаёт. p_teacher_id передан ЧУЖОЙ (специалист-посторонний, ...012) —
-- ветка teacher игнорирует параметр целиком и пишет my_teacher_id().
select public.tests_claims('a0680000-0000-0000-0000-000000000002','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
create temporary table t0068_c as
  select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000041',
    null, 'a0680000-0000-0000-0000-000000000012',
    'whole_word', 'normal', 'normal', null, 'normal') as id;
grant select on t0068_c to authenticated;
select is(
  (select teacher_id from public.reading_writing_assessments where id = (select id from t0068_c)),
  'a0680000-0000-0000-0000-000000000010'::uuid,
  'teacher_id — my_teacher_id() вызывающего (...010), переданный p_teacher_id (...012) проигнорирован');
select is(
  (select count(*)::int from public.reading_writing_assessments where student_id = 'a0680000-0000-0000-0000-000000000041'), 1,
  'Автор видит созданную запись сразу же');
reset role;

-- Специалист-посторонний — 42501 на создании.
select public.tests_claims('a0680000-0000-0000-0000-000000000004','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000042', null, null, 'whole_word') $q$,
  '42501', null, 'Посторонний teacher — 42501 на создании');
reset role;

-- Специалист-с-занятием читает и правит запись ребёнка А (созданную owner'ом).
select public.tests_claims('a0680000-0000-0000-0000-000000000003','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.reading_writing_assessments where student_id = 'a0680000-0000-0000-0000-000000000040'), 1,
  'Teacher со своим занятием видит запись ребёнка А, созданную owner''ом');
select lives_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, null, null,
        null, null, null, 'уточнение',
        (select updated_at from public.reading_writing_assessments where id = (select id from t0068_a))) $q$,
  'Teacher со своим занятием правит чужую (по авторству) запись — clinical_teacher_sees достаточно');
reset role;

-- Посторонний — 42501 и на правке существующей чужой строки, даже когда created_by is null.
select public.tests_claims(null, null);
update public.reading_writing_assessments set created_by = null where id = (select id from t0068_a);
select public.tests_claims('a0680000-0000-0000-0000-000000000004','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.reading_writing_assessments where student_id = 'a0680000-0000-0000-0000-000000000040'), 0,
  'Посторонний teacher: 0 строк по записи ребёнка А');
select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  '42501', null, 'Посторонний teacher — 42501 на правке чужой строки, created_by is null не пропускает');
reset role;

-- Специалист-с-занятием теряет clinical_teacher_sees (занятие отменили) — не создавал запись сам.
select public.tests_claims(null, null);
update public.lessons set status = 'cancelled' where id = 'a0680000-0000-0000-0000-000000000050';
select public.tests_claims('a0680000-0000-0000-0000-000000000003','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.reading_writing_assessments where student_id = 'a0680000-0000-0000-0000-000000000040'), 0,
  'Teacher без clinical_teacher_sees (занятие отменено), не автор и не primary_teacher_id — 0 строк');
select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  '42501', null, 'Тот же teacher — 42501 на правке (потерял единственное основание доступа)');
reset role;

-- Находка 1 ревью 0067: Р8 закрывался только на пути owner/admin —
-- проверка ветки teacher (my_teacher_id()) переносится сюда заранее. До
-- архивации — запись проходит; после прямой архивации teachers.deleted_at
-- (membership не тронут) — тот же вызов обязан 42704.
select public.tests_claims('a0680000-0000-0000-0000-000000000009','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000044', null, null, 'whole_word') $q$,
  'До архивации специалиста — запись проходит нормально (clinical_teacher_sees)');
reset role;

select public.tests_claims(null, null);
update public.teachers set deleted_at = now() where id = 'a0680000-0000-0000-0000-000000000014';
select public.tests_claims('a0680000-0000-0000-0000-000000000009','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000044', null, null, 'whole_word') $q$,
  '42704', null, 'После архивации специалиста (membership не тронут) — record_ отбивает по ветке teacher тоже');
reset role;


-- 4. Видимость по ролям и архивация ----------------------------------------------------------------

select public.tests_claims('a0680000-0000-0000-0000-000000000005','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.reading_writing_assessments), 0, 'Родитель: 0 строк прямым запросом');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null, 'whole_word') $q$,
  '42501', null, 'Родитель: record_reading_writing_assessment — 42501');
reset role;

select public.tests_claims('a0680000-0000-0000-0000-000000000006','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.reading_writing_assessments), 0, 'Registrar: 0 строк');
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null, 'whole_word') $q$,
  '42501', null, 'Registrar: record_reading_writing_assessment — 42501');
reset role;

select public.tests_claims('a0680000-0000-0000-0000-000000000007','a0680000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is(
  (select count(*)::int from public.reading_writing_assessments), 0, 'Центр Б не видит записи центра А');
select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  '42704', null, 'Центр Б: чужая запись — 42704');
reset role;

-- Teacher не может архивировать — только owner/admin.
select public.tests_claims('a0680000-0000-0000-0000-000000000001','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
create temporary table t0068_b as
  select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000040', null, null, 'whole_word') as id;
grant select on t0068_b to authenticated;
reset role;

select public.tests_claims('a0680000-0000-0000-0000-000000000003','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.archive_reading_writing_assessment((select id from t0068_b)) $q$,
  '42501', null, 'Teacher не может архивировать — только owner/admin');
reset role;

-- История: два обследования на одного ребёнка, обе видны; архив одной не трогает вторую.
select public.tests_claims('a0680000-0000-0000-0000-000000000001','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.reading_writing_assessments where student_id = 'a0680000-0000-0000-0000-000000000040'), 2,
  'История: две записи на ребёнка А видны обе (не upsert)');
select ok(
  public.archive_reading_writing_assessment((select id from t0068_b)),
  'Архивация второй записи проходит');
select is(
  (select count(*)::int from public.reading_writing_assessments where student_id = 'a0680000-0000-0000-0000-000000000040'), 1,
  'После архива одной — вторая осталась видимой (архив не каскадом)');
reset role;

-- student_alive в restrictive держит ВСЕХ, включая owner/admin.
select public.tests_claims(null, null);
update public.students set deleted_at = now() where id = 'a0680000-0000-0000-0000-000000000040';
select public.tests_claims('a0680000-0000-0000-0000-000000000001','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.reading_writing_assessments where student_id = 'a0680000-0000-0000-0000-000000000040'), 0,
  'student.deleted_at мимо приложения — owner тоже видит 0 (restrictive держит всех без исключения)');
select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_a), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  '42704', null, 'update_ от owner на записи мёртвого ребёнка — тоже 42704: запись не шире чтения');
reset role;

select public.tests_claims(null, null);
update public.students set deleted_at = null where id = 'a0680000-0000-0000-0000-000000000040';

-- Автор-teacher без clinical_teacher_sees/primary_teacher_id (ребёнок Б,
-- специалист-назначенный t0068_c — уже автор записи из section 3):
-- student_alive — общее предусловие ДО ветвления по ролям, update_
-- отбивает 42704, тем же кодом, что и у owner/admin.
select public.tests_claims(null, null);
update public.students set deleted_at = now() where id = 'a0680000-0000-0000-0000-000000000041';
select public.tests_claims('a0680000-0000-0000-0000-000000000002','a0680000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.reading_writing_assessments where student_id = 'a0680000-0000-0000-0000-000000000041'), 0,
  'Автор-teacher теряет видимость своей же записи, когда student_alive ложно');
select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_c), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  '42704', null, 'update_ бьётся о student_alive до ветвления по ролям — 42704, тот же код, что у owner/admin');
reset role;
select public.tests_claims(null, null);
update public.students set deleted_at = null where id = 'a0680000-0000-0000-0000-000000000041';


-- 5. Read-only центр — PT402 от guard на всех трёх RPC -----------------------------------------------

select public.tests_claims('a0680000-0000-0000-0000-000000000008','a0680000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $q$ select public.record_reading_writing_assessment('a0680000-0000-0000-0000-000000000043', null, null, 'whole_word') $q$,
  'PT402', null, 'Просроченный центр: record_reading_writing_assessment — PT402 от guard');
reset role;

-- Строка мимо guard (postgres, через data-modifying CTE — CREATE TABLE AS
-- принимает только query, не голый INSERT) — проверяет update_/archive_ отдельно.
select public.tests_claims(null, null);
create temporary table t0068_ro as
  with ins as (
    insert into public.reading_writing_assessments (center_id, student_id, reading_pace)
      values ('a0680000-0000-0000-0000-0000000000c3','a0680000-0000-0000-0000-000000000043', 'normal')
      returning id
  )
  select id from ins;
grant select on t0068_ro to authenticated;

select public.tests_claims('a0680000-0000-0000-0000-000000000008','a0680000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $q$ select public.update_reading_writing_assessment((select id from t0068_ro), null, null, null, null,
        null, null, null, 'x', now()) $q$,
  'PT402', null, 'Просроченный центр: update_reading_writing_assessment — PT402 от guard');
select throws_ok(
  $q$ select public.archive_reading_writing_assessment((select id from t0068_ro)) $q$,
  'PT402', null, 'Просроченный центр: archive_reading_writing_assessment — PT402 от guard');
select lives_ok(
  $q$ select count(*) from public.reading_writing_assessments where student_id = 'a0680000-0000-0000-0000-000000000043' $q$,
  'select продолжает работать в read-only центре');
reset role;

select * from finish();
rollback;
