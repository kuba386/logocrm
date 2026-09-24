-- pgTAP: логопедическое заключение как справочник (0059).
--
-- Заборы (первыми, до любого set role): unique (id, center_id) на
-- diagnostics; junction под readonly-guard, справочники — в исключениях;
-- junction в allow-list экспорта; authenticated на них — только select,
-- anon — ничего; старые сигнатуры record/update_diagnostic сняты;
-- student_diagnostics_brief физически без форм/направлений.
-- Поведение: родитель не видит junction ни прямым запросом, ни через бриф
-- (только conclusion_name); registrar/finance — 0 строк; специалист видит
-- формы своего ученика и не видит чужого; центр Б — 42704; update с null
-- не трогает, с '{}' гасит; повтор идемпотентен; возврат снятой формы —
-- вторая строка, живая одна; дубль схлопывается; неизвестный код — 22023;
-- прямой insert — отказ грантом; архив прячет; read-only центр — PT402.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(53);


-- 1. Заборы по каталогу ---------------------------------------------------------------------------

select ok(
  exists (select 1 from pg_constraint where conname = 'diagnostics_id_center_key' and conrelid = 'public.diagnostics'::regclass),
  'unique (id, center_id) на diagnostics — иначе составной FK junction не создаётся (Р6)');

select ok(
  (select bool_and(exists (
     select 1 from pg_trigger tg where tg.tgrelid = ('public.' || t)::regclass and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal))
     from unnest(array['diagnostic_clinical_forms', 'diagnostic_referrals']) t),
  'Обе junction под readonly guard');

select set_eq(
  $$ select x.table_name from public.readonly_guard_exempt_tables() x
      where x.table_name in ('speech_conclusions', 'clinical_forms', 'referral_targets') $$,
  $$ values ('speech_conclusions'), ('clinical_forms'), ('referral_targets') $$,
  'Три справочника — в списке исключений guard с причиной (Р1)');

select set_eq(
  $$ select x.table_name from public.export_center_tables() x
      where x.table_name in ('diagnostic_clinical_forms', 'diagnostic_referrals', 'booking_requests') $$,
  $$ values ('diagnostic_clinical_forms'), ('diagnostic_referrals'), ('booking_requests') $$,
  'Junction в allow-list экспорта, booking_requests (0057) не потеряна при переиздании (Р9)');

select ok(
  (select bool_and(
       has_table_privilege('authenticated', ('public.' || t)::regclass, 'SELECT')
       and not has_table_privilege('authenticated', ('public.' || t)::regclass, 'INSERT')
       and not has_table_privilege('authenticated', ('public.' || t)::regclass, 'UPDATE')
       and not has_table_privilege('authenticated', ('public.' || t)::regclass, 'DELETE')
       and not has_table_privilege('anon', ('public.' || t)::regclass, 'SELECT'))
     from unnest(array['diagnostic_clinical_forms', 'diagnostic_referrals',
                       'speech_conclusions', 'clinical_forms', 'referral_targets']) t),
  'Junction и справочники: authenticated только SELECT, anon — ничего');

select is_empty(
  $$ select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.oid::regprocedure::text in ('record_diagnostic(uuid,text,jsonb,jsonb,date,uuid)',
                                          'update_diagnostic(uuid,text,jsonb,jsonb,date)') $$,
  'Старые сигнатуры record/update_diagnostic сняты — перегрузки нет (Р13)');

select is(
  pg_get_function_result('public.student_diagnostics_brief(uuid)'::regprocedure),
  'TABLE(id uuid, date date, conclusion text, teacher_name text, conclusion_name text)',
  'Бриф родителя: плюс conclusion_name, физически без форм и направлений (Р4)');

select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'diagnostic_set_details'
        and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE')) $$,
  'diagnostic_set_details — внутренняя, без единого гранта');


-- Фикстура -------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0590000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0059@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0590000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-0059@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0590000-0000-0000-0000-000000000003','authenticated','authenticated','teacher2-0059@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0590000-0000-0000-0000-000000000004','authenticated','authenticated','parent-0059@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0590000-0000-0000-0000-000000000005','authenticated','authenticated','registrar-0059@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0590000-0000-0000-0000-000000000006','authenticated','authenticated','owner-b-0059@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0590000-0000-0000-0000-000000000007','authenticated','authenticated','owner-c-0059@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0590000-0000-0000-0000-0000000000c1','Центр А 0059','centr-a-0059','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0590000-0000-0000-0000-0000000000c2','Центр Б 0059','centr-b-0059','{"timezone":"Asia/Bishkek"}'::jsonb);
-- Центр В — просроченный trial с рождения (раздел 5).
insert into public.centers (id, name, slug, settings, trial_ends_at) values
  ('a0590000-0000-0000-0000-0000000000c3','Центр В 0059 (просрочен)','centr-c-0059','{"timezone":"Asia/Bishkek"}'::jsonb, now() - interval '2 days');

insert into public.payers (id, center_id, full_name, phone) values
  ('a0590000-0000-0000-0000-000000000031','a0590000-0000-0000-0000-0000000000c3','Родитель В 0059','+996700005803');
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0590000-0000-0000-0000-000000000041','a0590000-0000-0000-0000-0000000000c3','Ребёнок В 0059','a0590000-0000-0000-0000-000000000031');

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0590000-0000-0000-0000-000000000010','a0590000-0000-0000-0000-0000000000c1','Специалист 0059','a0590000-0000-0000-0000-000000000002'),
  ('a0590000-0000-0000-0000-000000000011','a0590000-0000-0000-0000-0000000000c1','Специалист-2 0059','a0590000-0000-0000-0000-000000000003');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('a0590000-0000-0000-0000-000000000020','a0590000-0000-0000-0000-0000000000c1','Логопед',45,70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('a0590000-0000-0000-0000-000000000030','a0590000-0000-0000-0000-0000000000c1','Родитель 0059','+996700005801');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('a0590000-0000-0000-0000-000000000040','a0590000-0000-0000-0000-0000000000c1','Ребёнок 0059','a0590000-0000-0000-0000-000000000030','a0590000-0000-0000-0000-000000000010');

-- Живое занятие — граница clinical_teacher_sees для специалиста-1.
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('a0590000-0000-0000-0000-000000000050','a0590000-0000-0000-0000-0000000000c1','a0590000-0000-0000-0000-000000000020',
   'a0590000-0000-0000-0000-000000000010','a0590000-0000-0000-0000-000000000040', now() + interval '1 day', now() + interval '1 day 45 minutes', 'planned');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0590000-0000-0000-0000-000000000001','a0590000-0000-0000-0000-0000000000c1','owner',     null, null),
  ('a0590000-0000-0000-0000-000000000002','a0590000-0000-0000-0000-0000000000c1','teacher',   'a0590000-0000-0000-0000-000000000010', null),
  ('a0590000-0000-0000-0000-000000000003','a0590000-0000-0000-0000-0000000000c1','teacher',   'a0590000-0000-0000-0000-000000000011', null),
  ('a0590000-0000-0000-0000-000000000004','a0590000-0000-0000-0000-0000000000c1','parent',    null, 'a0590000-0000-0000-0000-000000000030'),
  ('a0590000-0000-0000-0000-000000000005','a0590000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('a0590000-0000-0000-0000-000000000006','a0590000-0000-0000-0000-0000000000c2','owner',     null, null),
  ('a0590000-0000-0000-0000-000000000007','a0590000-0000-0000-0000-0000000000c3','owner',     null, null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Запись под owner: заключение, формы, направления ----------------------------------------------

select public.tests_claims('a0590000-0000-0000-0000-000000000001','a0590000-0000-0000-0000-0000000000c1');
set local role authenticated;

select throws_ok(
  $q$ select public.record_diagnostic('a0590000-0000-0000-0000-000000000040', 'x', '{}', '{}', null, null, 'onr_9') $q$,
  '22023', null, 'Неизвестное заключение — 22023 с русским текстом, не FK');
select throws_ok(
  $q$ select public.record_diagnostic('a0590000-0000-0000-0000-000000000040', 'x', '{}', '{}', null, null, 'onr_3', array['nosuch']) $q$,
  '22023', null, 'Неизвестная форма — 22023');
select throws_ok(
  $q$ select public.record_diagnostic('a0590000-0000-0000-0000-000000000040', 'x', '{}', '{}', null, null, 'onr_3', null, '{"target":"audiologist"}'::jsonb) $q$,
  '22023', null, 'Направления не списком — 22023');

create temporary table t0059_d as
  select public.record_diagnostic(
    'a0590000-0000-0000-0000-000000000040', 'ОНР III, стёртая дизартрия', '{"р":"искажение"}', '{"звукопроизношение":2}', null, null,
    'onr_3', array['dysarthria_erased', 'stuttering', 'dysarthria_erased'],
    '[{"target":"audiologist","note":"не отзывается на имя"},{"target":"audiologist"}]'::jsonb
  ) as id;
grant select on t0059_d to authenticated;

select is(
  (select conclusion_code from public.diagnostics where id = (select id from t0059_d)), 'onr_3',
  'conclusion_code записан');
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d) and deleted_at is null), 2,
  'Дубликат формы в массиве схлопнут — две живые строки, не три (Р8)');
select is(
  (select count(*)::int from public.diagnostic_referrals where diagnostic_id = (select id from t0059_d) and deleted_at is null), 1,
  'Дубликат направления схлопнут; note первого сохранён');
select is(
  (select note from public.diagnostic_referrals where diagnostic_id = (select id from t0059_d) and deleted_at is null), 'не отзывается на имя',
  'note направления записан');

-- Прямая запись закрыта грантом (не политикой).
select throws_ok(
  $q$ insert into public.diagnostic_clinical_forms (center_id, diagnostic_id, form_code)
      values ('a0590000-0000-0000-0000-0000000000c1', (select id from t0059_d), 'dyslalia') $q$,
  '42501', null, 'Прямой insert в junction от owner — отказ (грант снят), только RPC');

-- update: null не трогает, '{}' гасит, повтор идемпотентен.
select lives_ok(
  $q$ select public.update_diagnostic((select id from t0059_d), null, null, null, null, null, null, null) $q$,
  'update с null во всех новых параметрах проходит');
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d) and deleted_at is null), 2,
  'null = не передано — набор форм не тронут');

select lives_ok(
  $q$ select public.update_diagnostic((select id from t0059_d), null, null, null, null, null, array['dysarthria_erased', 'stuttering'], null) $q$,
  'Повтор того же набора проходит');
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d)), 2,
  'Повтор идемпотентен — новых строк нет вовсе (ни живых, ни погашенных)');

select lives_ok(
  $q$ select public.update_diagnostic((select id from t0059_d), null, null, null, null, null, array['dysarthria_erased'], null) $q$,
  'Снятие заикания проходит');
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d) and deleted_at is null), 1,
  'Снятая форма погашена, живая одна');

-- Погашенная строка физически на месте, но обе permissive-политики
-- (tenant_admin из apply_tenant_rls, *_teacher_read) фильтруют deleted_at is
-- null — authenticated её не увидит даже как owner; читаем как postgres.
reset role;
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d)), 2,
  '«Ничего не удаляется» — строка осталась с deleted_at');
select public.tests_claims('a0590000-0000-0000-0000-000000000001','a0590000-0000-0000-0000-0000000000c1');
set local role authenticated;

select lives_ok(
  $q$ select public.update_diagnostic((select id from t0059_d), null, null, null, null, null, array['dysarthria_erased', 'stuttering'], null) $q$,
  'Возврат снятой формы проходит (частичный unique, не 23505)');
reset role;
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d) and form_code = 'stuttering'), 2,
  'Возвращённая форма — вторая строка, история сохранена (Р2)');
select public.tests_claims('a0590000-0000-0000-0000-000000000001','a0590000-0000-0000-0000-0000000000c1');
set local role authenticated;

select lives_ok(
  $q$ select public.update_diagnostic((select id from t0059_d), null, null, null, null, null, '{}'::text[], '[]'::jsonb) $q$,
  '{} / [] — очистить');
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d) and deleted_at is null)
  + (select count(*)::int from public.diagnostic_referrals where diagnostic_id = (select id from t0059_d) and deleted_at is null), 0,
  'После очистки живых форм и направлений нет');

select lives_ok(
  $q$ select public.update_diagnostic((select id from t0059_d), null, null, null, null, 'ffnr', array['dyslalia'], '[{"target":"neurologist","note":"тонус"}]'::jsonb) $q$,
  'Смена заключения и набора');
select is(
  (select conclusion_code from public.diagnostics where id = (select id from t0059_d)), 'ffnr',
  'conclusion_code обновлён');

reset role;


-- 3. Видимость по ролям ------------------------------------------------------------------------------

-- Родитель: бриф — conclusion_name, junction — 0 прямым запросом.
select public.tests_claims('a0590000-0000-0000-0000-000000000004','a0590000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select conclusion_name from public.student_diagnostics_brief('a0590000-0000-0000-0000-000000000040') limit 1),
  'ФФНР — фонетико-фонематическое недоразвитие речи',
  'Родитель видит формулировку заключения через бриф (Р4)');
select is(
  (select count(*)::int from public.diagnostic_clinical_forms)
  + (select count(*)::int from public.diagnostic_referrals), 0,
  'Родитель: формы и направления — 0 строк прямым запросом (Р3/Р4)');
select is(
  (select count(*)::int from public.student_conclusions()), 0,
  'Родитель: student_conclusions() — пусто');
reset role;

-- Registrar: 0 строк, RPC — 42501.
select public.tests_claims('a0590000-0000-0000-0000-000000000005','a0590000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostic_clinical_forms)
  + (select count(*)::int from public.diagnostic_referrals), 0,
  'Registrar: junction — 0 строк (роль проверяется в definer-функции, не грантом)');
select is(
  (select count(*)::int from public.student_conclusions()), 0,
  'Registrar: student_conclusions() — пусто (0031 Р2)');
reset role;

-- Специалист-1 (есть занятие) видит; специалист-2 (нет) — нет.
select public.tests_claims('a0590000-0000-0000-0000-000000000002','a0590000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where deleted_at is null), 1,
  'Специалист своего ученика видит живые формы');
select is(
  (select conclusion_code from public.student_conclusions() where student_id = 'a0590000-0000-0000-0000-000000000040'), 'ffnr',
  'student_conclusions() отдаёт специалисту последнее заключение своего ученика');
reset role;

select public.tests_claims('a0590000-0000-0000-0000-000000000003','a0590000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostic_clinical_forms), 0,
  'Специалист без занятия с ребёнком — 0 строк');
select is(
  (select count(*)::int from public.student_conclusions()), 0,
  'student_conclusions() для чужого специалиста — пусто');
reset role;

-- Центр Б: не видит и не правит.
select public.tests_claims('a0590000-0000-0000-0000-000000000006','a0590000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostic_clinical_forms), 0,
  'Центр Б не видит junction центра А');
select throws_ok(
  $q$ select public.update_diagnostic((select id from t0059_d), null, null, null, null, 'onr_1', null, null) $q$,
  '42704', null, 'Центр Б: update_diagnostic чужой записи — «не найдена» (42704, не 42501 — как 0038)');
reset role;


-- 4. Архив прячет, строки остаются; owner в списке видит заключение ------------------------------------

select public.tests_claims('a0590000-0000-0000-0000-000000000001','a0590000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select conclusion_name from public.student_conclusions() where student_id = 'a0590000-0000-0000-0000-000000000040'),
  'ФФНР — фонетико-фонематическое недоразвитие речи',
  'Owner: student_conclusions() — последнее заключение с названием');

-- Р17: новая диагностика без кода (дата позже) не стирает прошлый диагноз.
create temporary table t0059_d2 as
  select public.record_diagnostic(
    'a0590000-0000-0000-0000-000000000040', 'повторный осмотр', '{}', '{}',
    public.center_today('a0590000-0000-0000-0000-0000000000c1') + 1, null,
    null, array['dyslalia'], null
  ) as id;
grant select on t0059_d2 to authenticated;
select is(
  (select conclusion_code from public.student_conclusions() where student_id = 'a0590000-0000-0000-0000-000000000040'), 'ffnr',
  'Новая диагностика без кода — в списке по-прежнему последнее ПОСТАВЛЕННОЕ заключение (Р17)');

-- Р16: сентинел '' снимает код; null — не трогает.
select lives_ok(
  $q$ select public.update_diagnostic((select id from t0059_d), null, null, null, null, '', null, null) $q$,
  'update с пустой строкой в p_conclusion_code проходит');
select is(
  (select conclusion_code from public.diagnostics where id = (select id from t0059_d)), null,
  'Пустая строка снимает код (Р16)');
select lives_ok(
  $q$ select public.update_diagnostic((select id from t0059_d), null, null, null, null, 'ffnr', null, null) $q$,
  'Код возвращён');

-- Р14: осиротевшая связка (диагностика погашена мимо RPC) не видна owner —
-- держит restrictive-политика, а не каскад archive_diagnostic.
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d2)), 1,
  'Owner видит форму живой второй диагностики');
reset role;
select public.tests_claims(null, null);
update public.diagnostics set deleted_at = now() where id = (select id from t0059_d2);
select public.tests_claims('a0590000-0000-0000-0000-000000000001','a0590000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d2)), 0,
  'Диагностика погашена мимо RPC, связка жива — owner всё равно видит 0 (restrictive, Р14)');

select ok(public.archive_diagnostic((select id from t0059_d)), 'Архив диагностики');
select is(
  (select count(*)::int from public.diagnostic_clinical_forms), 0,
  'После архива формы не видны даже owner — archive_diagnostic гасит связки каскадом');
select is(
  (select count(*)::int from public.student_conclusions()), 0,
  'Архивная диагностика не даёт заключения в списке');
reset role;

select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d)), 4,
  'Строки junction физически на месте после архива (без сессии, мимо RLS): 2 + возврат заикания + дислалия');
select is(
  (select count(*)::int from public.diagnostic_clinical_forms where diagnostic_id = (select id from t0059_d) and deleted_at is null), 0,
  '…и все погашены каскадом архива');


-- 5. Read-only центр — PT402 от guard, не 42501 ----------------------------------------------------------
-- Центр В заведён просроченным в фикстуре (insert не под centers_protect_plan;
-- update срока потребовал бы claims платформы, как в 0050).

select public.tests_claims('a0590000-0000-0000-0000-000000000007','a0590000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $q$ select public.record_diagnostic('a0590000-0000-0000-0000-000000000041', 'x', '{}', '{}', null, null, 'norm', array['dyslalia'], null) $q$,
  'PT402', null, 'Просроченный центр: record_diagnostic — PT402 от guard на diagnostics (junction под guard — каталожная проверка в начале файла; поведенческого пути до неё нет: diagnostics пишется первой)');
reset role;


select * from finish();
rollback;
