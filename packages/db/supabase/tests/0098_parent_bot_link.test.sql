-- pgTAP: родитель подключается к боту ссылкой с карточки плательщика (0098).
--
-- reset role не сбрасывает request.jwt.claims — перед вызовами «от бота»
-- явно tests_claims(null, null).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select * from no_plan();


-- Фикстура ---------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('98000000-0000-0000-0000-0000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0098@test.kg', '', '', '', '', '', '', '', ''
  from unnest(array['01', '02', '03', '04', '05', '06', '07']) n;

-- А — центр теста, Б — второй центр, R — центр «только чтение».
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('98000000-0000-0000-0000-0000000000c1', 'Центр А 0098', 'centr-a-0098', 'studio', now() + interval '30 days', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('98000000-0000-0000-0000-0000000000c2', 'Центр Б 0098', 'centr-b-0098', 'studio', now() + interval '30 days', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('98000000-0000-0000-0000-0000000000c3', 'Центр R 0098', 'centr-r-0098', 'studio', now() + interval '30 days', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('98000000-0000-0000-0000-0000000000a1', '98000000-0000-0000-0000-0000000000c1', 'Специалист А', '98000000-0000-0000-0000-000000000004');

insert into public.payers (id, center_id, full_name, phone) values
  ('98000000-0000-0000-0000-0000000000d1', '98000000-0000-0000-0000-0000000000c1', 'Асель Маратова', '+996700980001'),
  ('98000000-0000-0000-0000-0000000000d2', '98000000-0000-0000-0000-0000000000c1', 'Бакыт Эсенов',   '+996700980002'),
  ('98000000-0000-0000-0000-0000000000d3', '98000000-0000-0000-0000-0000000000c1', 'Архивная семья', '+996700980003'),
  ('98000000-0000-0000-0000-0000000000db', '98000000-0000-0000-0000-0000000000c2', 'Семья Б',        '+996700980009'),
  ('98000000-0000-0000-0000-0000000000df', '98000000-0000-0000-0000-0000000000c3', 'Семья R',        '+996700980008');

insert into public.students (id, center_id, full_name, payer_id) values
  ('98000000-0000-0000-0000-0000000000e1', '98000000-0000-0000-0000-0000000000c1', 'Айдана', '98000000-0000-0000-0000-0000000000d1');

-- 01 owner А, 02 admin А, 03 finance А, 04 teacher А, 05 owner Б,
-- 06 «ничей» родитель А (payer_id null, до 0060), 07 owner R.
insert into public.memberships (user_id, center_id, role, payer_id, teacher_id) values
  ('98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1', 'owner',   null, null),
  ('98000000-0000-0000-0000-000000000002', '98000000-0000-0000-0000-0000000000c1', 'admin',   null, null),
  ('98000000-0000-0000-0000-000000000003', '98000000-0000-0000-0000-0000000000c1', 'finance', null, null),
  ('98000000-0000-0000-0000-000000000004', '98000000-0000-0000-0000-0000000000c1', 'teacher', null, '98000000-0000-0000-0000-0000000000a1'),
  ('98000000-0000-0000-0000-000000000005', '98000000-0000-0000-0000-0000000000c2', 'owner',   null, null),
  ('98000000-0000-0000-0000-000000000006', '98000000-0000-0000-0000-0000000000c1', 'parent',  null, null),
  ('98000000-0000-0000-0000-000000000007', '98000000-0000-0000-0000-0000000000c3', 'owner',   null, null);

-- Специалист и «ничей» родитель уже в Telegram.
insert into public.telegram_accounts (user_id, chat_id) values
  ('98000000-0000-0000-0000-000000000004', 980004),
  ('98000000-0000-0000-0000-000000000006', 980006);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_code (name text primary key, code text);
grant select, insert on t_code to authenticated;

-- Выдать ссылку от имени пользователя.
create or replace function public.tests_link(p_name text, p_user uuid, p_center uuid, p_payer uuid)
  returns void language plpgsql as $$
begin
  perform public.tests_claims(p_user, p_center);
  execute 'set local role authenticated';
  insert into t_code select p_name, x.code from public.create_payer_telegram_link(p_payer) x;
  execute 'reset role';
  perform public.tests_claims(null, null);
end;
$$;


-- 1. Гранты и заборы ------------------------------------------------------------------------------

select ok(
  has_function_privilege('authenticated', 'public.create_payer_telegram_link(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.payer_telegram_status(uuid)', 'EXECUTE')
  and not has_function_privilege('bot_worker', 'public.create_payer_telegram_link(uuid)', 'EXECUTE'),
  'Выдача и статус — из приложения');
select ok(
  has_function_privilege('bot_worker', 'public.link_payer_telegram(text,bigint,text)', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.bot_unlink_telegram(bigint)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.link_payer_telegram(text,bigint,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.link_payer_telegram(text,bigint,text)', 'EXECUTE'),
  'Подключение и /stop — только бот');
select ok(
  not has_function_privilege('bot_worker', 'public.create_bot_parent_user(text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.create_bot_parent_user(text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.create_bot_parent_user(text)', 'EXECUTE'),
  'Вставку в auth.users не исполняет никто');
select is_empty(
  $$ select c.oid::regclass::text || ' ' || a.grantee::regrole::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where c.oid in ('public.payer_telegram_invites'::regclass, 'public.bot_accounts'::regclass)
        and a.grantee <> c.relowner $$,
  'Ссылки и бот-аккаунты: ни одной привилегии, кроме владельца (Б6)');
select is(
  (select count(*)::int from pg_policies where tablename in ('payer_telegram_invites', 'bot_accounts')),
  0, 'Политик нет ни одной — PostgREST их не читает');
select ok(
  exists (select 1 from public.readonly_guard_exempt_tables() x where x.table_name = 'bot_accounts')
  and exists (select 1 from public.export_center_excluded_tables() x where x.table_name = 'payer_telegram_invites')
  and exists (select 1 from pg_trigger t where t.tgrelid = 'public.payer_telegram_invites'::regclass and t.tgname = 'a00_readonly_guard'),
  'Заборы: bot_accounts — исключение guard, ссылки — под guard и вне выгрузки');


-- 2. Выдача ссылки (В2, Б1, Б2) -------------------------------------------------------------------

select lives_ok(
  $$ select public.tests_link('owner1', '98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1', '98000000-0000-0000-0000-0000000000d1') $$,
  'Владелец выдаёт ссылку');
select is(length((select code from t_code where name = 'owner1')), 24, 'Код — 24 hex-знака');
select is(
  (select count(*)::int from public.payer_telegram_invites
    where code_hash = (select code from t_code where name = 'owner1')),
  0, 'Открытый код в базе не хранится (Б6)');
select is(
  (select code_hash from public.payer_telegram_invites
    where payer_id = '98000000-0000-0000-0000-0000000000d1' and revoked_at is null),
  encode(digest((select code from t_code where name = 'owner1'), 'sha256'), 'hex'),
  'Хранится sha256 кода');

select lives_ok(
  $$ select public.tests_link('admin1', '98000000-0000-0000-0000-000000000002', '98000000-0000-0000-0000-0000000000c1', '98000000-0000-0000-0000-0000000000d1') $$,
  'Администратор выдаёт новую ссылку тому же плательщику — без 23505 (Б2)');
select is(
  (select count(*)::int from public.payer_telegram_invites
    where payer_id = '98000000-0000-0000-0000-0000000000d1' and revoked_at is not null),
  1, 'Прежняя ссылка отозвана');

select public.tests_claims('98000000-0000-0000-0000-000000000003', '98000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select * from public.create_payer_telegram_link('98000000-0000-0000-0000-0000000000d1') $$,
  '42501', null, 'Бухгалтер ссылку не выдаёт (Б1)');
reset role;
select public.tests_claims('98000000-0000-0000-0000-000000000004', '98000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select * from public.create_payer_telegram_link('98000000-0000-0000-0000-0000000000d1') $$,
  '42501', null, 'Специалист ссылку не выдаёт');
reset role;
select public.tests_claims('98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select * from public.create_payer_telegram_link('98000000-0000-0000-0000-0000000000db') $$,
  '22023', null, 'Плательщик чужого центра — отказ');
select throws_ok(
  $$ insert into public.payer_telegram_invites (code_hash, center_id, payer_id, expires_at)
     values ('x', '98000000-0000-0000-0000-0000000000c1', '98000000-0000-0000-0000-0000000000d1', now() + interval '1 day') $$,
  '42501', null, 'Прямой записи в таблицу ссылок нет');
reset role;
select public.tests_claims(null, null);

update public.payers set deleted_at = now() where id = '98000000-0000-0000-0000-0000000000d3';
select public.tests_claims('98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select * from public.create_payer_telegram_link('98000000-0000-0000-0000-0000000000d3') $$,
  '22023', null, 'Архивный плательщик — отказ');
reset role;
select public.tests_claims(null, null);

select throws_ok(
  $$ insert into public.payer_telegram_invites (code_hash, center_id, payer_id, created_at, expires_at)
     values ('y', '98000000-0000-0000-0000-0000000000c1', '98000000-0000-0000-0000-0000000000d2', now(), now() + interval '4 days') $$,
  '23514', null, 'Срок больше трёх дней держит CHECK (п.12)');


-- 3. Подключение: новый чат — бот-аккаунт ------------------------------------------------------------

select public.tests_claims('98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.link_payer_telegram('x', 1, null) $$,
  '42501', null, 'Пользователь подключение не зовёт');
reset role;
select public.tests_claims(null, null);

select throws_ok(
  $$ select public.link_payer_telegram((select code from t_code where name = 'admin1'), -100, null) $$,
  '22023', null, 'Группа (chat_id < 0) — отказ');
select throws_ok(
  $$ select public.link_payer_telegram((select code from t_code where name = 'owner1'), 980101, null) $$,
  '22023', 'Ссылка устарела — попросите в центре новую', 'Отозванная ссылка — отказ');
select throws_ok(
  $$ select public.link_payer_telegram('deadbeefdeadbeefdeadbeef', 980101, null) $$,
  '22023', 'Ссылка недействительна — попросите в центре новую', 'Чужой код — отказ');

select is(
  public.link_payer_telegram((select code from t_code where name = 'admin1'), 980101, 'Асель'),
  jsonb_build_object('center_name', 'Центр А 0098', 'payer_name', 'Асель Маратова', 'already', false),
  'Новый чат подключён');

create temporary table t_bot as
  select a.user_id from public.telegram_accounts a where a.chat_id = 980101 and a.unlinked_at is null;
grant select on t_bot to authenticated;

select is(
  (select row(u.email is null, u.is_anonymous, u.confirmation_token, u.recovery_token, u.email_change,
              u.email_change_token_new, u.email_change_token_current, u.phone_change,
              u.phone_change_token, u.reauthentication_token)::text
     from auth.users u where u.id = (select user_id from t_bot)),
  '(t,f,"","","","","","","","")',
  'Бот-аккаунт: без почты, не аноним, токен-колонки пустые строки (п.11)');
select is(
  (select tg_name from public.bot_accounts where user_id = (select user_id from t_bot)),
  'Асель', 'bot_accounts помнит имя в Telegram');
select is(
  (select row(m.role, m.payer_id)::text from public.memberships m
    where m.user_id = (select user_id from t_bot) and m.center_id = '98000000-0000-0000-0000-0000000000c1'),
  '(parent,98000000-0000-0000-0000-0000000000d1)', 'Членство parent с карточкой плательщика');
select is(
  (select row(used_chat_id, used_tg_name, used_by = (select user_id from t_bot))::text
     from public.payer_telegram_invites
    where code_hash = encode(digest((select code from t_code where name = 'admin1'), 'sha256'), 'hex')),
  '(980101,Асель,t)', 'Ссылка погашена: кто и с какого чата');
select is(
  (select payload ->> 'via' from public.events where type = 'membership.created' order by id desc limit 1),
  'telegram_link', 'membership.created помечен via = telegram_link (п.13)');

select is(
  public.link_payer_telegram((select code from t_code where name = 'admin1'), 980101, 'Асель'),
  jsonb_build_object('center_name', 'Центр А 0098', 'payer_name', 'Асель Маратова', 'already', true),
  'Повтор апдейта Telegram с того же чата — «уже подключены» (п.10)');
select throws_ok(
  $$ select public.link_payer_telegram((select code from t_code where name = 'admin1'), 980102, null) $$,
  '22023', 'Ссылка уже использована — попросите в центре новую', 'Та же ссылка с другого чата — отказ');


-- 4. Весь контур работает на бот-аккаунте ----------------------------------------------------------

select is(
  (select row(r.user_id = (select user_id from t_bot), r.channel, r.chat_id)::text
     from public.notification_targets('98000000-0000-0000-0000-0000000000c1', '98000000-0000-0000-0000-0000000000d1', 'lesson.reminder') r),
  '(t,telegram,980101)', 'Уведомления плательщика доходят до бот-аккаунта в Telegram');
select is(
  (select full_name from public.bot_balance(980101)),
  'Айдана', '/balance показывает ребёнка');

select public.tests_claims('98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select (public.payer_telegram_status('98000000-0000-0000-0000-0000000000d1') -> 'parents' -> 0 ->> 'name')
          || '|' || (public.payer_telegram_status('98000000-0000-0000-0000-0000000000d1') -> 'parents' -> 0 ->> 'via_bot')),
  'Асель|true', 'Карточка видит, кто подключился (п.9)');
select is(
  public.payer_telegram_status('98000000-0000-0000-0000-0000000000d1') -> 'link',
  'null'::jsonb, 'Живой ссылки больше нет');
select throws_ok(
  $$ select public.change_member_role((select user_id from t_bot), 'admin') $$,
  '22023', null, 'Бот-аккаунт сотрудником не становится (Б5)');
select throws_ok(
  $$ select public.change_member_role((select user_id from t_bot), 'teacher') $$,
  '22023', null, 'Ни специалистом');
reset role;
select public.tests_claims('98000000-0000-0000-0000-000000000004', '98000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.payer_telegram_status('98000000-0000-0000-0000-0000000000d1') $$,
  '42501', null, 'Специалист статус подключения не видит');
reset role;
select public.tests_claims(null, null);


-- 5. Существующие пользователи ----------------------------------------------------------------------

-- «Ничей» родитель А (payer_id null) открывает ссылку второй семьи — карточка дописывается (п.7).
select public.tests_link('d2', '98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1', '98000000-0000-0000-0000-0000000000d2');
select lives_ok(
  $$ select public.link_payer_telegram((select code from t_code where name = 'd2'), 980006, null) $$,
  'Родитель без карточки подключается по ссылке');
select is(
  (select payer_id from public.memberships
    where user_id = '98000000-0000-0000-0000-000000000006' and center_id = '98000000-0000-0000-0000-0000000000c1'),
  '98000000-0000-0000-0000-0000000000d2'::uuid, 'payer_id дописан');
select is(
  (select type from public.events where payload ->> 'user_id' = '98000000-0000-0000-0000-000000000006' order by id desc limit 1),
  'membership.payer_linked', 'Дописанной карточке — событие payer_linked, а не membership.created (0060 Р6)');

-- Бот-родитель семьи 1 открывает ссылку семьи 2 того же центра — отказ.
select public.tests_link('d2b', '98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1', '98000000-0000-0000-0000-0000000000d2');
select throws_ok(
  $$ select public.link_payer_telegram((select code from t_code where name = 'd2b'), 980101, null) $$,
  '22023', 'Этот Telegram уже подключён к другой семье в этом центре', 'Другая семья того же центра — отказ');

-- Специалист этого центра — отказ.
select throws_ok(
  $$ select public.link_payer_telegram((select code from t_code where name = 'd2b'), 980004, null) $$,
  '22023', null, 'Чат сотрудника центра — отказ');
select is(
  (select used_at from public.payer_telegram_invites
    where code_hash = encode(digest((select code from t_code where name = 'd2b'), 'sha256'), 'hex')),
  null, 'Отказ не гасит ссылку');

-- Бот-родитель центра А получает второй центр тем же аккаунтом.
select public.tests_link('b1', '98000000-0000-0000-0000-000000000005', '98000000-0000-0000-0000-0000000000c2', '98000000-0000-0000-0000-0000000000db');
select lives_ok(
  $$ select public.link_payer_telegram((select code from t_code where name = 'b1'), 980101, null) $$,
  'Тот же чат подключается ко второму центру');
select is(
  (select count(*)::int from public.memberships where user_id = (select user_id from t_bot)),
  2, 'Второе членство — тому же аккаунту, нового пользователя нет');


-- 6. Центр «только чтение» (Б4) ---------------------------------------------------------------------

select public.tests_link('r1', '98000000-0000-0000-0000-000000000007', '98000000-0000-0000-0000-0000000000c3', '98000000-0000-0000-0000-0000000000df');
-- Срок держит centers_protect_plan (0049) — меняет только платформа; в тесте триггер снимаем.
alter table public.centers disable trigger centers_protect_plan;
update public.centers set subscription_until = now() - interval '5 days' where id = '98000000-0000-0000-0000-0000000000c3';
alter table public.centers enable trigger centers_protect_plan;
select throws_ok(
  $$ select public.link_payer_telegram((select code from t_code where name = 'r1'), 980201, null) $$,
  '22023', 'Центр сейчас не подключает родителей — обратитесь в центр', 'Read-only центр — подключение отказано');
select is(
  (select count(*)::int from public.memberships where center_id = '98000000-0000-0000-0000-0000000000c3' and role = 'parent'),
  0, 'Членство не создано');


-- 7. /stop и отключение -------------------------------------------------------------------------------

select is(public.bot_unlink_telegram(980101), '{"unlinked": true, "bot_only": true}'::jsonb, '/stop отвязывает чат бот-родителя');
select is(public.bot_unlink_telegram(980101), '{"unlinked": false, "bot_only": false}'::jsonb, 'Повтор /stop — unlinked false');
select is(
  (select count(*)::int from public.notification_targets('98000000-0000-0000-0000-0000000000c1', '98000000-0000-0000-0000-0000000000d1', 'lesson.reminder') r
    where r.channel = 'telegram'),
  0, 'После /stop в Telegram ничего не уходит');

-- /start по новой ссылке с того же чата — прежний бот-аккаунт, без «призрака» (ревью п.5).
select public.tests_link('d1r', '98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1', '98000000-0000-0000-0000-0000000000d1');
select is(
  public.link_payer_telegram((select code from t_code where name = 'd1r'), 980101, 'Асель') ->> 'already',
  'true', 'Та же семья — «уже подключены», событие не дублируется');
select is(
  (select user_id from public.telegram_accounts where chat_id = 980101 and unlinked_at is null),
  (select user_id from t_bot), 'Чат вернулся прежнему бот-аккаунту');
select is((select count(*)::int from public.bot_accounts), 1, 'Нового бот-аккаунта не появилось');

-- Отключение администратором: членства нет — telegram_user молчит (п.14).
select public.tests_claims('98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.revoke_membership('98000000-0000-0000-0000-000000000006') $$,
  'Администратор отключает родителя');
reset role;
select public.tests_claims(null, null);
select is(public.telegram_user(980006), null, 'Чат родителя без членств — «не привязан», а не пустой список');


-- 8. Веб-аккаунт перехватывает чат у бот-аккаунта (п.8) -------------------------------------------

select public.tests_link('d1', '98000000-0000-0000-0000-000000000001', '98000000-0000-0000-0000-0000000000c1', '98000000-0000-0000-0000-0000000000d1');
select lives_ok(
  $$ select public.link_payer_telegram((select code from t_code where name = 'd1'), 980301, 'Мама') $$,
  'Ещё один бот-аккаунт на чате 980301');
insert into public.telegram_link_codes (code, user_id, expires_at)
values ('web0098code', '98000000-0000-0000-0000-000000000002', now() + interval '10 minutes');
select is(public.link_telegram('web0098code', 980301), '98000000-0000-0000-0000-000000000002'::uuid,
  'Веб-код на чат бот-аккаунта — чат уходит веб-аккаунту, без тупика');
select is(
  (select count(*)::int from public.telegram_accounts where chat_id = 980301 and unlinked_at is null),
  1, 'Живая привязка чата одна');

select * from finish();
rollback;
