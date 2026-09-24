-- pgTAP: AI-ассистент (0064) — тарифный лимит, горловина assistant_begin
-- (роль, PT402, квота с резервом, дата из базы, карта намерений), закрытие
-- assistant_finish (своя попытка, всегда закрывает, цена по справочнику,
-- clamp токенов, вердикт по карте роли), витрины, заборы.
--
-- centers.plan/subscription_until меняет только администратор платформы
-- (centers_protect_plan, 0049) — каждый такой update идёт под claims
-- платформенного пользователя (шов из 0001/0050).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select * from no_plan();


-- Заборы ------------------------------------------------------------------------------------------

select ok(
  (select bool_and(limits ? 'ai_questions_month') from public.plans),
  'У КАЖДОЙ строки plans есть ключ ai_questions_month (Р11), не у четырёх поимённо');
select is(
  (select jsonb_object_agg(code, limits->'ai_questions_month') from public.plans where code in ('trial','solo','studio','center')),
  '{"trial": 300, "solo": 100, "studio": 500, "center": 2000}'::jsonb,
  'Значения по решению владельца (В2)');

select is_empty(
  $$ select grantee from information_schema.role_table_grants
      where table_schema = 'public' and table_name in ('ai_usage', 'assistant_requests')
        and privilege_type in ('INSERT', 'UPDATE', 'DELETE')
        and grantee in ('public', 'anon', 'authenticated', 'service_role', 'bot_worker') $$,
  'ai_usage и assistant_requests без insert/update/delete у прикладных ролей — пишут только функции (Р1, Р13)');
select is_empty(
  $$ select grantee from information_schema.role_table_grants
      where table_schema = 'public' and table_name = 'assistant_requests' and privilege_type = 'SELECT'
        and grantee in ('public', 'anon', 'authenticated', 'service_role', 'bot_worker') $$,
  'assistant_requests не читает никто напрямую — журнал «кто что спрашивал» не заказан (Р7)');
select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('ai_model_rates','assistant_intents_for','center_ai_questions_used','assistant_questions_reserved')
        and (has_function_privilege('public', p.oid, 'EXECUTE')
             or has_function_privilege('anon', p.oid, 'EXECUTE')
             or has_function_privilege('authenticated', p.oid, 'EXECUTE')
             or has_function_privilege('service_role', p.oid, 'EXECUTE')) $$,
  'Внутренние функции без единого гранта — зовутся только изнутри definer');
select ok(
  has_function_privilege('authenticated', 'public.assistant_begin()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.assistant_finish(uuid,text,text,text,integer,integer,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.assistant_quota()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.assistant_begin()', 'EXECUTE'),
  'begin/finish/quota — authenticated, anon нет');
select set_eq(
  $$ select tg.tgrelid::regclass::text from pg_trigger tg
      where tg.tgname = 'a00_readonly_guard' and tg.tgtype & 4 > 0 and not (tg.tgtype & 16 > 0) and not (tg.tgtype & 8 > 0) $$,
  $$ values ('memberships'), ('invitations'), ('assistant_requests') $$,
  'Guard только на insert — ровно у трёх таблиц: закрытие начатой попытки идёт всегда (Р4)');
select ok(
  exists (select 1 from public.export_center_excluded_tables() x where x.table_name = 'assistant_requests'),
  'assistant_requests — в списке исключений экспорта центра с причиной (забор 0056)');

-- Карта намерений (Р3)
select is(public.assistant_intents_for('owner'),     array['lessons_on','debtors','expiring_subscriptions','student_info','payments_summary'], 'owner — все пять');
select is(public.assistant_intents_for('finance'),   array['debtors','expiring_subscriptions'], 'finance — без занятий, поиска и кассы (lessons/global_search/payments ей не читаемы)');
select is(public.assistant_intents_for('teacher'),   array['lessons_on','student_info'], 'teacher — без долгов, абонементов и кассы');
select is(public.assistant_intents_for('registrar'), array['lessons_on','debtors','expiring_subscriptions','student_info'], 'registrar — без кассы (payments — только tenant_admin)');
select is(public.assistant_intents_for('parent'),    array[]::text[], 'parent — ничего (В3)');


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0640000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0064@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0640000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-0064@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0640000-0000-0000-0000-000000000003','authenticated','authenticated','parent-0064@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0640000-0000-0000-0000-000000000004','authenticated','authenticated','finance-0064@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0640000-0000-0000-0000-000000000005','authenticated','authenticated','owner-b-0064@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0640000-0000-0000-0000-000000000006','authenticated','authenticated','owner-c-0064@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0640000-0000-0000-0000-000000000009','authenticated','authenticated','platform-0064@test.kg','','','','','','','','');
update auth.users set email_confirmed_at = now() where id = 'a0640000-0000-0000-0000-000000000009';
insert into public.platform_admins (email) values ('platform-0064@test.kg');

-- А — solo (лимит 100), Б — solo, чужой; В — истёкшая подписка (PT402), пояс UTC+14.
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('a0640000-0000-0000-0000-0000000000c1','Центр А 0064','centr-a-0064','solo', now() + interval '30 days', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0640000-0000-0000-0000-0000000000c2','Центр Б 0064','centr-b-0064','solo', now() + interval '30 days', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0640000-0000-0000-0000-0000000000c3','Центр В 0064','centr-c-0064','solo', now() - interval '1 day',   '{"timezone":"Pacific/Kiritimati"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0640000-0000-0000-0000-000000000010','a0640000-0000-0000-0000-0000000000c1','Специалист 0064','a0640000-0000-0000-0000-000000000002');
insert into public.payers (id, center_id, full_name, phone) values
  ('a0640000-0000-0000-0000-000000000030','a0640000-0000-0000-0000-0000000000c1','Родитель 0064','+996700006401');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0640000-0000-0000-0000-000000000001','a0640000-0000-0000-0000-0000000000c1','owner',   null, null),
  ('a0640000-0000-0000-0000-000000000002','a0640000-0000-0000-0000-0000000000c1','teacher', 'a0640000-0000-0000-0000-000000000010', null),
  ('a0640000-0000-0000-0000-000000000003','a0640000-0000-0000-0000-0000000000c1','parent',  null, 'a0640000-0000-0000-0000-000000000030'),
  ('a0640000-0000-0000-0000-000000000004','a0640000-0000-0000-0000-0000000000c1','finance', null, null),
  ('a0640000-0000-0000-0000-000000000005','a0640000-0000-0000-0000-0000000000c2','owner',   null, null),
  ('a0640000-0000-0000-0000-000000000006','a0640000-0000-0000-0000-0000000000c3','owner',   null, null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_ins (name text primary key, id uuid);
grant select, insert on t_ins to authenticated;
create temporary table t_out (name text primary key, j jsonb);
grant select, insert on t_out to authenticated;


-- Гейт горловины ----------------------------------------------------------------------------------

select throws_ok($q$ select public.assistant_begin() $q$, '42501', null, 'Без сессии — 42501');

select public.tests_claims('a0640000-0000-0000-0000-000000000003','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($q$ select public.assistant_begin() $q$, '42501', 'Недостаточно прав', 'parent — 42501 (В3)');
select throws_ok($q$ select public.assistant_quota() $q$, '42501', null, 'parent — и витрины квоты нет');
reset role;

select public.tests_claims('a0640000-0000-0000-0000-000000000006','a0640000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok($q$ select public.assistant_begin() $q$, 'PT402', null, 'Истёкшая подписка — PT402 в горловине, не расход платформы (Р4)');
reset role;

-- Дата — из базы, в поясе центра (Р12): центр В на Kiritimati (UTC+14).
select public.tests_claims('a0640000-0000-0000-0000-000000000009', null);
update public.centers set subscription_until = now() + interval '30 days' where id = 'a0640000-0000-0000-0000-0000000000c3';
select public.tests_claims('a0640000-0000-0000-0000-000000000006','a0640000-0000-0000-0000-0000000000c3');
set local role authenticated;
select is(
  (select (public.assistant_begin())->>'today')::date,
  (now() at time zone 'Pacific/Kiritimati')::date,
  'today — по поясу центра, не сервера (Р12)');
reset role;


-- Владелец: попытка, карта, закрытие (Р15: всегда закрывает) -----------------------------------------

select public.tests_claims('a0640000-0000-0000-0000-000000000001','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_out values ('begin', public.assistant_begin());
insert into t_ins values ('r1', ((select j from t_out where name = 'begin')->>'request_id')::uuid);

select is((select j->>'timezone' from t_out where name = 'begin'), 'Asia/Bishkek', 'timezone в ответе');
select is(
  (select j->'intents' from t_out where name = 'begin'),
  '["lessons_on","debtors","expiring_subscriptions","student_info","payments_summary"]'::jsonb,
  'Владелец получает все намерения (Р3)');
select is((select (public.assistant_quota())->>'used')::int, 0, 'quota: пока 0 оплаченных');
select is((select (public.assistant_quota())->>'limit')::int, 100, 'quota: лимит solo — 100');
select is((select (public.assistant_quota())->>'plan_name'), 'Solo', 'quota: имя тарифа — владельцу');

select throws_ok(
  $q$ select public.assistant_finish((select id from t_ins where name = 'r1'), 'weird') $q$,
  '22023', null, 'Неизвестный статус — отказ до денег');
-- r1: незнакомая модель → попытка ЗАКРЫТА как failed, расхода нет (Р15).
insert into t_out values ('fin1', public.assistant_finish((select id from t_ins where name = 'r1'), 'done', 'payments_summary', 'gpt-5-turbo', 100, 10));
select is((select j->>'status' from t_out where name = 'fin1'), 'failed', 'Незнакомая модель — failed значением, не исключение (Р15)');
select throws_ok(
  $q$ select public.assistant_finish((select id from t_ins where name = 'r1'), 'done', 'payments_summary', 'gpt-4o-mini', 1000, 100) $q$,
  '22023', 'Попытка уже закрыта', 'Повторное закрытие — 22023');

-- r1b: токены сверх потолка — clamp, не отказ.
insert into t_ins values ('r1b', ((public.assistant_begin())->>'request_id')::uuid);
insert into t_out values ('fin1b', public.assistant_finish((select id from t_ins where name = 'r1b'), 'done', 'debtors', 'gpt-4o-mini', 99999999, 10));
select is((select j->>'status' from t_out where name = 'fin1b'), 'done', 'Неправдоподобные токены — clamp, попытка done');

-- r1c: обычное закрытие — цена по справочнику.
insert into t_ins values ('r1c', ((public.assistant_begin())->>'request_id')::uuid);
insert into t_out values ('fin1c', public.assistant_finish((select id from t_ins where name = 'r1c'), 'done', 'payments_summary', 'gpt-4o-mini', 1000, 100));
select is((select (j->>'allowed')::boolean from t_out where name = 'fin1c'), true, 'Намерение по карте — allowed');
select is((select (public.assistant_quota())->>'used')::int, 2, 'quota: две оплаченные (r1b, r1c); failed не считается');
reset role;

select is(
  (select status || ':' || coalesce(intent, '-') || ':' || (usage_id is null)::text from public.assistant_requests where id = (select id from t_ins where name = 'r1')),
  'failed:payments_summary:true', 'r1 закрыта: failed, намерение (что разобрала модель) записано, расхода нет');
select alike(
  (select error from public.assistant_requests where id = (select id from t_ins where name = 'r1')),
  'Неизвестная модель ассистента: gpt-5-turbo%', '…причина записана');
select is(
  (select tokens_in from public.ai_usage where id = (select usage_id from public.assistant_requests where id = (select id from t_ins where name = 'r1b'))),
  20000, 'r1b: токены зажаты потолком 20000 (Р2)');
select is(
  (select cost_tiyin from public.ai_usage where id = (select usage_id from public.assistant_requests where id = (select id from t_ins where name = 'r1c'))),
  2, 'Цена считается в SQL: ceil((1000·1300 + 100·5200)/1e6) = 2 тыйына, не параметр вызова (Р2)');
select is(
  (select event_id from public.ai_usage where id = (select usage_id from public.assistant_requests where id = (select id from t_ins where name = 'r1c'))),
  null::bigint, 'У строки вопроса нет события');
select is(
  (select status || ':' || intent from public.assistant_requests where id = (select id from t_ins where name = 'r1c')),
  'done:payments_summary', 'Попытка закрыта с намерением');


-- Вердикт по карте роли (Р3/Р6): finance с payments_summary --------------------------------------------

select public.tests_claims('a0640000-0000-0000-0000-000000000004','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select (public.assistant_quota())->>'plan_name'), null::text, 'Сотруднику имя тарифа не отдаётся (Р10)');
select is((select (public.assistant_quota())->'intents'), '["debtors","expiring_subscriptions"]'::jsonb, 'finance: два намерения');
insert into t_ins values ('rf1', ((public.assistant_begin())->>'request_id')::uuid);
insert into t_out values ('finf1', public.assistant_finish((select id from t_ins where name = 'rf1'), 'done', 'payments_summary', 'gpt-4o-mini', 100, 10));
select is((select (j->>'allowed')::boolean from t_out where name = 'finf1'), false,
  'Намерение вне карты роли — allowed=false значением; расход записан, попытка закрыта (Р15)');
insert into t_ins values ('rf2', ((public.assistant_begin())->>'request_id')::uuid);
select lives_ok(
  $q$ select public.assistant_finish((select id from t_ins where name = 'rf2'), 'failed', null, null, 0, 0, 'Провайдер не ответил за 15 секунд') $q$,
  'failed — закрывается без расхода (Р8)');
reset role;
select is(
  (select status || ':' || coalesce(intent, '-') || ':' || (usage_id is not null)::text from public.assistant_requests where id = (select id from t_ins where name = 'rf1')),
  'done:-:true', 'rf1: done, намерение не записано (вне карты), расход есть — деньги уплачены');
select is(
  (select count(*)::int from public.ai_usage where kind = 'question' and center_id = 'a0640000-0000-0000-0000-0000000000c1'),
  3, 'Три оплаченные строки (r1b, r1c, rf1); failed расход не создал');
select is(
  (select error from public.assistant_requests where id = (select id from t_ins where name = 'rf2')),
  'Провайдер не ответил за 15 секунд', '…но причина failed записана');
select is(
  (select count(*)::int from public.assistant_requests where center_id = 'a0640000-0000-0000-0000-0000000000c1' and status = 'running'),
  0, 'Ни одной попытки не осталось running после ответа провайдера (Р15)');


-- Чужой центр ------------------------------------------------------------------------------------------

select public.tests_claims('a0640000-0000-0000-0000-000000000001','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_ins values ('r2', ((public.assistant_begin())->>'request_id')::uuid);
reset role;
select public.tests_claims('a0640000-0000-0000-0000-000000000005','a0640000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_ok(
  $q$ select public.assistant_finish((select id from t_ins where name = 'r2'), 'done', 'debtors', 'gpt-4o-mini', 10, 1) $q$,
  '42704', null, 'Попытка центра А не закрывается владельцем центра Б (Р6, ADR-002)');
select is((select (public.assistant_quota())->>'used')::int, 0, 'Счётчик центра Б не видит расход центра А');
reset role;
select public.tests_claims('a0640000-0000-0000-0000-000000000002','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.assistant_finish((select id from t_ins where name = 'r2'), 'done', 'lessons_on', 'gpt-4o-mini', 10, 1) $q$,
  '42704', null, 'Чужая попытка своего центра — тот же 42704 (created_by)');
reset role;


-- Квота с резервом (Р9) -------------------------------------------------------------------------------

-- r2 — running, свежая: занимает место. 3 оплаченных + 96 = 99 + 1 running = 100.
insert into public.ai_usage (center_id, kind, model, tokens_in, tokens_out, cost_tiyin)
select 'a0640000-0000-0000-0000-0000000000c1', 'question', 'gpt-4o-mini', 10, 1, 1
  from generate_series(1, 96);

select public.tests_claims('a0640000-0000-0000-0000-000000000001','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.assistant_begin() $q$,
  '23514', 'Лимит вопросов ассистенту на этот месяц исчерпан: 100 из 100 по тарифу Solo. Подайте заявку на другой тариф на экране «Тариф и оплата» или подождите до следующего месяца',
  'Лимит с учётом running-резерва: 99 оплаченных + 1 в полёте = 100 — владельцу текст с тарифом');
reset role;
select public.tests_claims('a0640000-0000-0000-0000-000000000002','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.assistant_begin() $q$,
  '23514', 'Лимит вопросов ассистенту на этот месяц исчерпан: 100 из 100. Сообщите владельцу центра — лимит снимает смена тарифа',
  '…специалисту — без имени тарифа');
reset role;

-- Резерв протухает: старая running-попытка место не занимает.
update public.assistant_requests set started_at = now() - interval '6 minutes'
 where id = (select id from t_ins where name = 'r2');
select public.tests_claims('a0640000-0000-0000-0000-000000000001','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok($q$ select public.assistant_begin() $q$, 'Попытка старше 5 минут перестаёт занимать место (Р9)');
reset role;

-- Без лимита (−1) и без ключа — тариф правит платформа.
select public.tests_claims('a0640000-0000-0000-0000-000000000009', null);
update public.centers set plan = 'center' where id = 'a0640000-0000-0000-0000-0000000000c1';
update public.plans set limits = limits || '{"ai_questions_month": -1}' where code = 'center';
select public.tests_claims('a0640000-0000-0000-0000-000000000001','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok($q$ select public.assistant_begin() $q$, '−1 — без ограничения');
select is((select (public.assistant_quota())->>'limit')::int, -1, 'quota отдаёт −1 как есть');
reset role;
update public.plans set limits = limits - 'ai_questions_month' where code = 'center';
select public.tests_claims('a0640000-0000-0000-0000-000000000001','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($q$ select public.assistant_begin() $q$, '23514', null, 'Ключа лимита нет — «не задан тариф», не бесконечность');
reset role;
update public.plans set limits = limits || '{"ai_questions_month": 2000}' where code = 'center';
select public.tests_claims('a0640000-0000-0000-0000-000000000009', null);
update public.centers set plan = 'solo' where id = 'a0640000-0000-0000-0000-0000000000c1';


-- center_limits и частичный unique (Р13) --------------------------------------------------------------

select public.tests_claims('a0640000-0000-0000-0000-000000000001','a0640000-0000-0000-0000-0000000000c1');
set local role authenticated;
select set_eq(
  $$ select jsonb_object_keys(public.center_limits()) $$,
  $$ values ('plan'), ('plan_name'), ('price_tiyin'), ('is_trial'), ('until'), ('days_left'), ('writable'), ('state'), ('limits'), ('usage'), ('onboarding') $$,
  'center_limits: полный набор ключей, включая state из 0056 — переиздача не потеряла ничего');
select set_eq(
  $$ select jsonb_object_keys(public.center_limits()->'usage') $$,
  $$ values ('teachers'), ('students'), ('ai_notes_month'), ('ai_questions_month') $$,
  'center_limits.usage — четыре счётчика');
select is(
  ((public.center_limits())->'usage'->>'ai_questions_month')::int,
  (public.assistant_quota()->>'used')::int,
  'center_limits.usage.ai_questions_month = тот же счётчик, что у витрины и гейта');
select is((public.center_limits())->>'state', 'ok', 'state — как в 0056');
reset role;
select is(
  (select count(*)::int from public.ai_usage where kind = 'question' and event_id is null and center_id = 'a0640000-0000-0000-0000-0000000000c1'),
  99, 'Много строк question с event_id null сосуществуют — частичный unique (event_id, kind) их не судит (Р13)');

select * from finish();

rollback;
