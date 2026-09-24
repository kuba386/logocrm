-- pgTAP: артикуляционный аппарат — второй раздел речевой карты (0065).
--
-- Заборы (первыми, до любого set role): таблица под readonly guard, в
-- allow-list экспорта (и её грант authenticated не потерян при переиздании
-- в этом же файле — тот самый баг, что 0063 поймала только по CI), гранты
-- authenticated только select, PK/unique, отсутствие deleted_at, триггеры,
-- execute-гранты новых функций, имена CHECK-констрейнтов (иначе следующая
-- правка набора значений молча разводит 23514 с CHECK_MESSAGES).
-- Поведение: owner пишет/читает; teacher с clinical_teacher_sees читает и
-- правит; teacher, назначенный primary_teacher_id, — симметрично читает и
-- правит НЕЗАВИСИМО от того, кто создал строку (Р9, не только первое
-- заполнение); teacher без всякой связи — 42501 и на первом заполнении, и
-- на правке чужой существующей строки, даже если created_by у строки NULL
-- (Р8: сравнение с auth.uid() только через coalesce — голое «=» даёт NULL,
-- а plpgsql трактует NULL как «не сработало» и пропускает raise); автор
-- строки сохраняет доступ к ней дальше; parent/registrar — 0 строк и
-- 42501; центр Б — 42704; оптимистичная блокировка по updated_at;
-- неизвестный ключ/неверная форма значения — 22023; недопустимый код —
-- 23514 от CHECK (RPC коды не дублирует, Р2); restrictive-политика держит
-- видимость даже для owner при student.deleted_at мимо приложения;
-- read-only центр — PT402.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(55);


-- 1. Заборы по каталогу -------------------------------------------------------------------------

select ok(
  exists (select 1 from pg_trigger tg
           where tg.tgrelid = 'public.student_articulation'::regclass
             and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal),
  'student_articulation под readonly guard');

select set_eq(
  $$ select x.table_name from public.export_center_tables() x
      where x.table_name = 'student_articulation' $$,
  $$ values ('student_articulation') $$,
  'student_articulation в allow-list экспорта (Р6)');

select ok(
  has_function_privilege('authenticated', 'public.export_center_tables()'::regprocedure, 'EXECUTE'),
  'export_center_tables() не потеряла грант authenticated при переиздании в этом файле');

select ok(
  has_table_privilege('authenticated', 'public.student_articulation'::regclass, 'SELECT')
  and not has_table_privilege('authenticated', 'public.student_articulation'::regclass, 'INSERT')
  and not has_table_privilege('authenticated', 'public.student_articulation'::regclass, 'UPDATE')
  and not has_table_privilege('authenticated', 'public.student_articulation'::regclass, 'DELETE')
  and not has_table_privilege('anon', 'public.student_articulation'::regclass, 'SELECT'),
  'authenticated — только select, anon — ничего; запись только через RPC');

select ok(
  (select a.attname from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
     where i.indrelid = 'public.student_articulation'::regclass and i.indisprimary) = 'id',
  'PK — суррогатный id, не student_id');

select ok(
  exists (select 1 from pg_constraint where conname = 'student_articulation_student_key'
           and conrelid = 'public.student_articulation'::regclass and contype = 'u'),
  'unique(student_id) держит честный 1:1');

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public' and table_name = 'student_articulation' and column_name = 'deleted_at'), 0,
  'Профиль без deleted_at — apply_tenant_rls(..., false) соответствует');

select ok(
  (select bool_and(exists (
     select 1 from pg_trigger tg where tg.tgrelid = 'public.student_articulation'::regclass
       and tg.tgname = t and not tg.tgisinternal))
     from unnest(array['student_articulation_set_updated_at', 'student_articulation_audit']) t),
  'moddatetime и audit-триггер на месте');

-- Имена CHECK-констрейнтов — литералами (находка 3 ревью написанного SQL):
-- расходится с errors.ts молча, если следующая правка значений переименует
-- безымянный автоконстрейнт; забор ловит расхождение, а не человека.
select set_eq(
  $$ select conname from pg_constraint
      where conrelid = 'public.student_articulation'::regclass and contype = 'c' $$,
  $$ values ('student_articulation_collected_at_check'), ('student_articulation_lips_structure_check'),
            ('student_articulation_teeth_check'), ('student_articulation_soft_palate_check'),
            ('student_articulation_tongue_structure_check'), ('student_articulation_lips_mobility_check'),
            ('student_articulation_bite_check'), ('student_articulation_hard_palate_check'),
            ('student_articulation_tongue_mobility_check'), ('student_articulation_frenulum_check'),
            ('student_articulation_notes_check') $$,
  'Имена CHECK — ровно те, что зарегистрированы в apps/web/lib/errors.ts CHECK_MESSAGES');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.oid::regprocedure::text in (
        'student_primary_teacher(uuid)',
        'set_student_articulation(uuid,jsonb,timestamp with time zone)')), 2,
  'Обе новые функции найдены по имени и сигнатуре (иначе следующая проверка молча схлопнется в пустую)');
select ok(
  (select bool_and(
       has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and not has_function_privilege('anon', p.oid, 'EXECUTE')
       and not has_function_privilege('public', p.oid, 'EXECUTE'))
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.oid::regprocedure::text in (
        'student_primary_teacher(uuid)',
        'set_student_articulation(uuid,jsonb,timestamp with time zone)')),
  'Гранты новых функций: authenticated execute, anon/public — ничего');


-- Фикстура ----------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0650000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0065@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0650000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-primary-0065@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0650000-0000-0000-0000-000000000003','authenticated','authenticated','teacher-sees-0065@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0650000-0000-0000-0000-000000000004','authenticated','authenticated','teacher-nobody-0065@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0650000-0000-0000-0000-000000000005','authenticated','authenticated','parent-0065@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0650000-0000-0000-0000-000000000006','authenticated','authenticated','registrar-0065@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0650000-0000-0000-0000-000000000007','authenticated','authenticated','owner-b-0065@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0650000-0000-0000-0000-000000000008','authenticated','authenticated','owner-c-0065@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0650000-0000-0000-0000-0000000000c1','Центр А 0065','centr-a-0065','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0650000-0000-0000-0000-0000000000c2','Центр Б 0065','centr-b-0065','{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, settings, trial_ends_at) values
  ('a0650000-0000-0000-0000-0000000000c3','Центр В 0065 (просрочен)','centr-c-0065','{"timezone":"Asia/Bishkek"}'::jsonb, now() - interval '2 days');

insert into public.payers (id, center_id, full_name, phone) values
  ('a0650000-0000-0000-0000-000000000030','a0650000-0000-0000-0000-0000000000c1','Родитель 0065','+996700006501'),
  ('a0650000-0000-0000-0000-000000000031','a0650000-0000-0000-0000-0000000000c3','Родитель В 0065','+996700006503');

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0650000-0000-0000-0000-000000000010','a0650000-0000-0000-0000-0000000000c1','Специалист-назначенный 0065','a0650000-0000-0000-0000-000000000002'),
  ('a0650000-0000-0000-0000-000000000011','a0650000-0000-0000-0000-0000000000c1','Специалист-с-занятием 0065','a0650000-0000-0000-0000-000000000003'),
  ('a0650000-0000-0000-0000-000000000012','a0650000-0000-0000-0000-0000000000c1','Специалист-посторонний 0065','a0650000-0000-0000-0000-000000000004');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('a0650000-0000-0000-0000-000000000020','a0650000-0000-0000-0000-0000000000c1','Логопед',45,70000);

-- Ребёнок А — общая площадка owner'а; занятие со специалистом «с занятием» (clinical_teacher_sees).
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0650000-0000-0000-0000-000000000040','a0650000-0000-0000-0000-0000000000c1','Ребёнок А 0065','a0650000-0000-0000-0000-000000000030');
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('a0650000-0000-0000-0000-000000000050','a0650000-0000-0000-0000-0000000000c1','a0650000-0000-0000-0000-000000000020',
   'a0650000-0000-0000-0000-000000000011','a0650000-0000-0000-0000-000000000040', now() + interval '1 day', now() + interval '1 day 45 minutes', 'planned');

-- Ребёнок Б — назначен специалисту-назначенному, занятия ещё нет вовсе (Р4/Р9: первое заполнение по primary_teacher_id).
insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('a0650000-0000-0000-0000-000000000041','a0650000-0000-0000-0000-0000000000c1','Ребёнок Б 0065','a0650000-0000-0000-0000-000000000030','a0650000-0000-0000-0000-000000000010');

-- Ребёнок В — ничей: ни занятия, ни primary_teacher_id (Р4: посторонний — 42501 на первом заполнении).
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0650000-0000-0000-0000-000000000042','a0650000-0000-0000-0000-0000000000c1','Ребёнок В 0065','a0650000-0000-0000-0000-000000000030');

-- Ребёнок Д — центр В (просроченный trial).
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0650000-0000-0000-0000-000000000043','a0650000-0000-0000-0000-0000000000c3','Ребёнок Д 0065','a0650000-0000-0000-0000-000000000031');

-- Ребёнок Е — назначен специалисту-назначенному, но первую запись создаёт
-- OWNER (не сам назначенный) — проверка симметрии Р9: специалист обязан
-- видеть и править чужую-по-авторству запись через primary_teacher_id, не
-- только заполнять первым.
insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('a0650000-0000-0000-0000-000000000044','a0650000-0000-0000-0000-0000000000c1','Ребёнок Е 0065','a0650000-0000-0000-0000-000000000030','a0650000-0000-0000-0000-000000000010');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0650000-0000-0000-0000-000000000001','a0650000-0000-0000-0000-0000000000c1','owner',     null, null),
  ('a0650000-0000-0000-0000-000000000002','a0650000-0000-0000-0000-0000000000c1','teacher',   'a0650000-0000-0000-0000-000000000010', null),
  ('a0650000-0000-0000-0000-000000000003','a0650000-0000-0000-0000-0000000000c1','teacher',   'a0650000-0000-0000-0000-000000000011', null),
  ('a0650000-0000-0000-0000-000000000004','a0650000-0000-0000-0000-0000000000c1','teacher',   'a0650000-0000-0000-0000-000000000012', null),
  ('a0650000-0000-0000-0000-000000000005','a0650000-0000-0000-0000-0000000000c1','parent',    null, 'a0650000-0000-0000-0000-000000000030'),
  ('a0650000-0000-0000-0000-000000000006','a0650000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('a0650000-0000-0000-0000-000000000007','a0650000-0000-0000-0000-0000000000c2','owner',     null, null),
  ('a0650000-0000-0000-0000-000000000008','a0650000-0000-0000-0000-0000000000c3','owner',     null, null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Запись под owner на ребёнке А -----------------------------------------------------------------

select public.tests_claims('a0650000-0000-0000-0000-000000000001','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;

select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"неизвестное_поле":"x"}'::jsonb) $q$,
  '22023', null, 'Неизвестный ключ p_fields — 22023');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{}'::jsonb) $q$,
  '22023', null, 'Пустой p_fields — 22023');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"lips_structure":"normal"}'::jsonb) $q$,
  '22023', null, 'Скаляр вместо списка в text[]-поле — 22023 (форма значения)');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"bite":["normal"]}'::jsonb) $q$,
  '22023', null, 'Список вместо скаляра в одиночном поле — 22023');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"lips_structure":["not_a_code"]}'::jsonb) $q$,
  '23514', null, 'Недопустимый код в списке — CHECK 23514, RPC его не отбивает сам (Р2)');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"bite":"not_a_code"}'::jsonb) $q$,
  '23514', null, 'Недопустимый код в одиночном поле — CHECK 23514');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040',
        jsonb_build_object('collected_at', (current_date + 10)::text)) $q$,
  '23514', null, 'collected_at за верхней границей — CHECK 23514');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040',
        jsonb_build_object('notes', repeat('ф', 2001))) $q$,
  '23514', null, 'notes сверх 2000 символов — CHECK 23514');

create temporary table t0065_a as
  select public.set_student_articulation('a0650000-0000-0000-0000-000000000040',
    '{"lips_structure":["thick","asymmetric"],"lips_mobility":"normal","bite":"prognathia"}'::jsonb) as id;
grant select on t0065_a to authenticated;

select is(
  (select lips_structure from public.student_articulation where id = (select id from t0065_a)),
  array['thick','asymmetric'],
  'Список записан первым вызовом (порядок как в jsonb-массиве)');
select is(
  (select bite from public.student_articulation where id = (select id from t0065_a)),
  'prognathia', 'Одиночное поле записано');
select is(
  (select collected_at from public.student_articulation where id = (select id from t0065_a)),
  public.center_today('a0650000-0000-0000-0000-0000000000c1'),
  'collected_at по умолчанию — сегодня центра (Р7)');

select throws_ok(
  $q$ insert into public.student_articulation (center_id, student_id) values
      ('a0650000-0000-0000-0000-0000000000c1','a0650000-0000-0000-0000-000000000040') $q$,
  '42501', null, 'Прямой insert от owner — отказ грантом, только RPC');

select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"bite":"normal"}'::jsonb) $q$,
  '22023', null, 'p_expected_updated_at не передан при существующей строке — 22023');
select is(
  (select bite from public.student_articulation where id = (select id from t0065_a)),
  'prognathia', 'Значение не изменилось после отбитой попытки');

select lives_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"bite":"normal"}'::jsonb,
        (select updated_at from public.student_articulation where id = (select id from t0065_a))) $q$,
  'Верный p_expected_updated_at проходит');
select is(
  (select bite from public.student_articulation where id = (select id from t0065_a)), 'normal',
  'Значение обновилось');

select lives_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040',
        jsonb_build_object('lips_structure', '[]'::jsonb),
        (select updated_at from public.student_articulation where id = (select id from t0065_a))) $q$,
  'Пустой список снимает text[]-поле');
select is(
  (select lips_structure from public.student_articulation where id = (select id from t0065_a)), null,
  'lips_structure снят ([] -> NULL)');

select lives_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040',
        jsonb_build_object('teeth', jsonb_build_array('sparse', 'crooked'), 'hard_palate', null),
        (select updated_at from public.student_articulation where id = (select id from t0065_a))) $q$,
  'JSON null в одиночном поле снимает его так же, как []');
select is(
  (select teeth from public.student_articulation where id = (select id from t0065_a)),
  array['sparse','crooked'], 'teeth записан списком из двух кодов');
select is(
  (select hard_palate from public.student_articulation where id = (select id from t0065_a)), null,
  'hard_palate снят через JSON null');
select is(
  (select lips_mobility from public.student_articulation where id = (select id from t0065_a)), 'normal',
  'Поле, отсутствующее в p_fields, не тронуто');

-- Гонка первой вставки — второй set_student_articulation на child без
-- существующей строки: имитируем прямой insert-конфликт через повторную
-- вставку под postgres (RPC уже создал строку выше, поэтому здесь просто
-- фиксируем 23505 недостижим напрямую — гонка проверяется на ребёнке Б ниже).

reset role;


-- 3. Право записи — симметрия Р4/Р9 -----------------------------------------------------------------

-- Специалист-назначенный (primary_teacher_id ребёнка Б, занятия нет вовсе) — первое заполнение.
select public.tests_claims('a0650000-0000-0000-0000-000000000002','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000041', '{"frenulum":"shortened"}'::jsonb) $q$,
  'primary_teacher_id без занятия создаёт первую запись (Р4)');
select is(
  (select count(*)::int from public.student_articulation where student_id = 'a0650000-0000-0000-0000-000000000041'), 1,
  'Автор видит созданную запись сразу же');

-- Настоящая гонка двух транзакций (unique_violation -> дружелюбный 22023 в
-- обработчике exception) в однопоточном pgTAP не воспроизводится — вторая
-- попытка в той же сессии уже видит v_exists=true и просто упирается в
-- обычную блокировку по updated_at, не в ветку insert вовсе.
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000041', '{"frenulum":"normal"}'::jsonb) $q$,
  '22023', null, 'Повторный вызов без p_expected_updated_at на уже созданной строке — обычная блокировка (не обходит первое заполнение вторым разом)');
reset role;

-- Специалист-посторонний (ни занятия, ни primary_teacher_id) — 42501 даже на первом заполнении.
select public.tests_claims('a0650000-0000-0000-0000-000000000004','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000042', '{"frenulum":"normal"}'::jsonb) $q$,
  '42501', null, 'Посторонний teacher — 42501 даже на первом заполнении (Р4/Р8, не голое NULL-сравнение)');
select is(
  (select count(*)::int from public.student_articulation where student_id = 'a0650000-0000-0000-0000-000000000042'), 0,
  'Посторонний teacher: 0 строк на select');
reset role;

-- Специалист-с-занятием (clinical_teacher_sees ребёнка А, не primary_teacher_id) — читает и правит.
select public.tests_claims('a0650000-0000-0000-0000-000000000003','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_articulation where student_id = 'a0650000-0000-0000-0000-000000000040'), 1,
  'Teacher со своим занятием видит осмотр ребёнка А');
select lives_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"hard_palate":"gothic"}'::jsonb,
        (select updated_at from public.student_articulation where student_id = 'a0650000-0000-0000-0000-000000000040')) $q$,
  'Teacher со своим занятием правит осмотр');
reset role;

-- Специалист-посторонний — 42501 и на ПРАВКЕ уже существующей чужой строки (не только на первом заполнении).
select public.tests_claims('a0650000-0000-0000-0000-000000000004','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_articulation where student_id = 'a0650000-0000-0000-0000-000000000040'), 0,
  'Посторонний teacher: 0 строк на select по существующей записи ребёнка А');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"bite":"normal"}'::jsonb,
        now()) $q$,
  '42501', null, 'Посторонний teacher — 42501 на правке уже существующей чужой строки (главная половина Р4)');
reset role;

-- Р9: OWNER создаёт первую запись ребёнка Е, назначенный специалист без
-- занятия и без авторства всё равно ЧИТАЕТ и ПРАВИТ — симметрия с
-- clinical_teacher_sees, не только «кто зашёл первым».
select public.tests_claims('a0650000-0000-0000-0000-000000000001','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;
create temporary table t0065_e as
  select public.set_student_articulation('a0650000-0000-0000-0000-000000000044', '{"frenulum":"normal"}'::jsonb) as id;
grant select on t0065_e to authenticated;
reset role;

select public.tests_claims('a0650000-0000-0000-0000-000000000002','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_articulation where student_id = 'a0650000-0000-0000-0000-000000000044'), 1,
  'primary_teacher_id видит запись, созданную owner''ом (Р9 — не только первое заполнение)');
select lives_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000044', '{"frenulum":"shortened"}'::jsonb,
        (select updated_at from public.student_articulation where student_id = 'a0650000-0000-0000-0000-000000000044')) $q$,
  'primary_teacher_id правит запись, созданную owner''ом (Р9)');
reset role;

-- Р8-регрессия: created_by выставлен в NULL мимо приложения — посторонний
-- teacher всё равно 42501 (не проходит по голому NULL-сравнению).
select public.tests_claims(null, null);
update public.student_articulation set created_by = null where student_id = 'a0650000-0000-0000-0000-000000000044';
select public.tests_claims('a0650000-0000-0000-0000-000000000004','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000044', '{"frenulum":"normal"}'::jsonb,
        now()) $q$,
  '42501', null, 'created_by is null у существующей строки — посторонний teacher всё равно 42501 (Р8)');
reset role;


-- 4. Видимость по ролям ----------------------------------------------------------------------------

select public.tests_claims('a0650000-0000-0000-0000-000000000005','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_articulation), 0,
  'Родитель: 0 строк прямым запросом');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"bite":"normal"}'::jsonb) $q$,
  '42501', null, 'Родитель: set_student_articulation — 42501');
reset role;

select public.tests_claims('a0650000-0000-0000-0000-000000000006','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_articulation), 0,
  'Registrar: 0 строк');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"bite":"normal"}'::jsonb) $q$,
  '42501', null, 'Registrar: set_student_articulation — 42501');
reset role;

select public.tests_claims('a0650000-0000-0000-0000-000000000007','a0650000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is(
  (select count(*)::int from public.student_articulation), 0,
  'Центр Б не видит осмотр центра А');
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000040', '{"bite":"normal"}'::jsonb) $q$,
  '42704', null, 'Центр Б: чужой ученик — 42704');
reset role;

-- Restrictive держит видимость даже для owner при student.deleted_at мимо приложения (0059/0063 Р14).
select public.tests_claims(null, null);
update public.students set deleted_at = now() where id = 'a0650000-0000-0000-0000-000000000040';
select public.tests_claims('a0650000-0000-0000-0000-000000000001','a0650000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.student_articulation where student_id = 'a0650000-0000-0000-0000-000000000040'), 0,
  'student.deleted_at выставлен мимо приложения — owner всё равно видит 0');
reset role;
select public.tests_claims(null, null);
update public.students set deleted_at = null where id = 'a0650000-0000-0000-0000-000000000040';


-- 5. audit_log адресуется по суррогатному id (обоснование Р3 0063, унаследованное сюда) ------------

select ok(
  (select count(*)::int from public.audit_log
    where table_name = 'student_articulation' and row_id = (select id from t0065_a)) >= 2,
  'audit_log адресуется по суррогатному id (минимум insert + один update по нему найдены)');


-- 6. Read-only центр — PT402 от guard -----------------------------------------------------------------

select public.tests_claims('a0650000-0000-0000-0000-000000000008','a0650000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $q$ select public.set_student_articulation('a0650000-0000-0000-0000-000000000043', '{"bite":"normal"}'::jsonb) $q$,
  'PT402', null, 'Просроченный центр: set_student_articulation — PT402 от guard, не 42501');
select lives_ok(
  $q$ select count(*) from public.student_articulation where student_id = 'a0650000-0000-0000-0000-000000000043' $q$,
  'select продолжает работать в read-only центре');
reset role;

select * from finish();
rollback;
