-- pgTAP: напоминания о сроке, пульт платформы по центрам, один trial на владельца (0052).
--
-- Заборы: отметочная таблица закрыта на запись и в списке исключений guard;
-- справочник с mandatory/channels; дефолты. Планировщик: ending за 2 дня,
-- expired, ночной пояс — пропуск, повтор — ничего, открытая заявка — молчит
-- без отметки, смена пояса не дублирует, новый срок — новое напоминание,
-- без даты — тишина и no_date в platform_centers, мусорный пояс не роняет
-- прогон. Доставка: owner/admin с {what}/{until}/{when}; выключить нельзя.
-- Trial-лимит: create_center, повышение до owner, архивация не освобождает,
-- платформа заводит второй, совладение без trial проходит, без сессии —
-- тишина. platform_centers/summary, мусорный пояс не роняет пульт.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(46);


-- 1. Заборы ----------------------------------------------------------------------------------------------

select ok(
  exists (select 1 from public.readonly_guard_exempt_tables() x where x.table_name = 'subscription_reminders_sent'),
  'subscription_reminders_sent в списке исключений guard (0050 Р3)');
select is_empty(
  $$ select policyname from pg_policies where schemaname = 'public' and tablename = 'subscription_reminders_sent' and cmd <> 'SELECT' $$,
  'Отметка: ни одной политики на запись');
select set_eq(
  $$ select grantee || ':' || privilege_type from information_schema.role_table_grants
      where grantee in ('authenticated', 'anon', 'service_role') and table_schema = 'public' and table_name = 'subscription_reminders_sent' $$,
  $$ values ('authenticated:SELECT') $$,
  'Отметка: у прикладных ролей — только SELECT authenticated (service_role не гасит напоминание вставкой)');
select set_eq(
  $$ select event_type || ':' || mandatory::text || ':' || array_to_string(channels, '+')
       from public.notification_event_types where event_type in ('subscription.ending', 'subscription.expired') $$,
  $$ values ('subscription.ending:true:telegram+whatsapp_link'), ('subscription.expired:true:telegram+whatsapp_link') $$,
  'Справочник: оба типа обязательные, оба канала (Р1, Р2)');
select is(
  (select count(*)::int from public.message_templates
    where center_id is null and deleted_at is null and event_type in ('subscription.ending', 'subscription.expired')),
  4, 'Дефолтные шаблоны на оба канала');


-- Фикстура ------------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0520000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0052@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0520000-0000-0000-0000-000000000002','authenticated','authenticated','admin-0052@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0520000-0000-0000-0000-000000000003','authenticated','authenticated','owner-night-0052@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0520000-0000-0000-0000-000000000004','authenticated','authenticated','platform-0052@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0520000-0000-0000-0000-000000000005','authenticated','authenticated','owner-trial-b-0052@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0520000-0000-0000-0000-000000000006','authenticated','authenticated','owner-trial-0052@test.kg','','','','','','','','');
update auth.users set email_confirmed_at = now()
 where id in ('a0520000-0000-0000-0000-000000000004', 'a0520000-0000-0000-0000-000000000006');
insert into public.platform_admins (email) values ('platform-0052@test.kg');

-- Приём 0032: дневной и ночной пояса существуют всегда (Etc/GMT покрывают сутки).
create temporary table t_tz as
select
  (select name from pg_timezone_names
    where name like 'Etc/GMT%' and extract(hour from (now() at time zone name))::int between 9 and 19
    order by name limit 1) as tz_day,
  (select name from pg_timezone_names
    where name like 'Etc/GMT%' and extract(hour from (now() at time zone name))::int between 9 and 19
    order by name desc limit 1) as tz_day2,
  (select name from pg_timezone_names
    where name like 'Etc/GMT%' and extract(hour from (now() at time zone name))::int < 7
    order by name limit 1) as tz_night;

-- Полночь местного дня N дней от сегодня в дневном поясе.
create or replace function public.tests_local_midnight(p_days integer) returns timestamptz language sql as $$
  select (((now() at time zone (select tz_day from t_tz))::date + p_days)::timestamp) at time zone (select tz_day from t_tz)
$$;

-- А: solo, до послезавтра (день) → ending. Б: trial, ночь → пропуск.
-- В: solo, истёк вчера (день) → expired. Г: trial владельца 006 (день).
-- Д: trial владельца 005 (день).
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('a0520000-0000-0000-0000-0000000000c1','Центр 0052 А','centr-0052-a','solo', public.tests_local_midnight(2),
   jsonb_build_object('timezone', (select tz_day from t_tz))),
  ('a0520000-0000-0000-0000-0000000000c3','Центр 0052 В','centr-0052-c','solo', public.tests_local_midnight(-1),
   jsonb_build_object('timezone', (select tz_day from t_tz)));
insert into public.centers (id, name, slug, settings) values
  ('a0520000-0000-0000-0000-0000000000c2','Центр 0052 Б','centr-0052-b', jsonb_build_object('timezone', (select tz_night from t_tz))),
  ('a0520000-0000-0000-0000-0000000000c4','Центр 0052 Г','centr-0052-d', jsonb_build_object('timezone', (select tz_day from t_tz))),
  ('a0520000-0000-0000-0000-0000000000c5','Центр 0052 Д','centr-0052-e', jsonb_build_object('timezone', (select tz_day from t_tz)));

insert into public.memberships (user_id, center_id, role) values
  ('a0520000-0000-0000-0000-000000000001','a0520000-0000-0000-0000-0000000000c1','owner'),
  ('a0520000-0000-0000-0000-000000000002','a0520000-0000-0000-0000-0000000000c1','admin'),
  ('a0520000-0000-0000-0000-000000000001','a0520000-0000-0000-0000-0000000000c3','owner'),
  ('a0520000-0000-0000-0000-000000000003','a0520000-0000-0000-0000-0000000000c2','owner'),
  ('a0520000-0000-0000-0000-000000000006','a0520000-0000-0000-0000-0000000000c4','owner'),
  ('a0520000-0000-0000-0000-000000000005','a0520000-0000-0000-0000-0000000000c4','admin'),
  ('a0520000-0000-0000-0000-000000000005','a0520000-0000-0000-0000-0000000000c5','owner');
insert into public.telegram_accounts (user_id, chat_id) values ('a0520000-0000-0000-0000-000000000001', 5201);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

select isnt((select tz_day from t_tz), null, 'Фикстура: нашёлся дневной пояс');
select isnt((select tz_night from t_tz), null, 'Фикстура: нашёлся ночной пояс');


-- 2. Планировщик: первый прогон и повтор (Р3) --------------------------------------------------------------

select public.tests_claims(null, null);
select is((select center_count from public.subscription_reminders()), 2,
  'Первый прогон: А (за 2 дня) и В (истёк) — два события, Б ночью и Г/Д с живым trial — нет');
select is(
  (select count(*)::int from public.events e where e.type = 'subscription.ending'
     and e.center_id = 'a0520000-0000-0000-0000-0000000000c1' and (e.payload ->> 'days_left')::int = 2
     and (e.payload ->> 'is_trial')::boolean = false),
  1, 'А: subscription.ending с days_left = 2, платный');
select is(
  (select count(*)::int from public.events e where e.type = 'subscription.expired' and e.center_id = 'a0520000-0000-0000-0000-0000000000c3'),
  1, 'В: subscription.expired');
select is(
  (select count(*)::int from public.events e where e.type like 'subscription.e%' and e.center_id = 'a0520000-0000-0000-0000-0000000000c2'),
  0, 'Б: до местного 8:00 — ничего');
select is((select center_count from public.subscription_reminders()), 0, 'Повторный прогон — ничего нового (отметки)');


-- 3. Доставка (Р6) и обязательность (Р1) — пока пояс и срок А не менялись ------------------------------------------

select set_eq(
  $$ select recipient_user_id::text || ':' || channel
       from public.event_messages((select min(id) from public.events where type = 'subscription.ending' and center_id = 'a0520000-0000-0000-0000-0000000000c1')) $$,
  $$ values ('a0520000-0000-0000-0000-000000000001:telegram'), ('a0520000-0000-0000-0000-000000000002:whatsapp_link') $$,
  'ending — owner (telegram) и admin (whatsapp_link), никого больше');
select ok(
  (select m.message like 'Подписка заканчивается %' and m.message like '%через 2 дн.%'
     from public.event_messages((select min(id) from public.events where type = 'subscription.ending' and center_id = 'a0520000-0000-0000-0000-0000000000c1')) m
    where m.channel = 'telegram'),
  '{what} = «Подписка», {when} = «через 2 дн.» по сроку из события');
select ok(
  (select m.message like 'Подписка закончилась %' and m.message like '%только чтения%'
     from public.event_messages((select min(id) from public.events where type = 'subscription.expired' and center_id = 'a0520000-0000-0000-0000-0000000000c3')) m
    where m.channel = 'telegram'),
  'expired — текст про режим только чтения');

select public.tests_claims('a0520000-0000-0000-0000-000000000001','a0520000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.upsert_message_template('subscription.ending', 'telegram', 'тишина', false) $q$,
  '42501', null,
  'Выключить напоминание о сроке центр не может (Р1)');
select lives_ok(
  $q$ select public.upsert_message_template('subscription.ending', 'telegram', 'Свой текст: {what} до {until}', true) $q$,
  'А текст править может');
reset role;


-- 4. Планировщик: заявка, пояс, продление, без даты, мусор (Р3–Р7) --------------------------------------------------

-- Открытая заявка — молчим без отметки; после отзыва — напоминание уходит.
select public.tests_claims('a0520000-0000-0000-0000-000000000001','a0520000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.submit_platform_payment('solo', 1, 'mbank', null);
reset role;
select public.tests_claims('a0520000-0000-0000-0000-000000000004', null);
update public.centers set subscription_until = public.tests_local_midnight(1) where id = 'a0520000-0000-0000-0000-0000000000c1';
select public.tests_claims(null, null);
select is((select center_count from public.subscription_reminders()), 0, 'Открытая заявка: напоминание не уходит (Р4)');
select is(
  (select count(*)::int from public.subscription_reminders_sent s where s.center_id = 'a0520000-0000-0000-0000-0000000000c1'),
  1, 'И отметки за новый срок нет — вернёмся после исхода заявки');
-- «Истёк» при открытой заявке уходит: заявка живёт вечно, молчать нельзя (Р4).
select public.tests_claims('a0520000-0000-0000-0000-000000000004', null);
update public.centers set subscription_until = public.tests_local_midnight(-2) where id = 'a0520000-0000-0000-0000-0000000000c1';
select public.tests_claims(null, null);
-- Два ассерта, не сумма: порядок вычисления подзапросов в одном выражении не гарантирован.
select is((select center_count from public.subscription_reminders()), 1,
  'А просрочен при открытой заявке: expired уходит — прогон дал одно событие');
select is(
  (select count(*)::int from public.events e where e.type = 'subscription.expired' and e.center_id = 'a0520000-0000-0000-0000-0000000000c1'),
  1, 'А: событие subscription.expired записано');
select public.tests_claims('a0520000-0000-0000-0000-000000000001','a0520000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.withdraw_platform_payment((select id from public.platform_payments p where p.center_id = 'a0520000-0000-0000-0000-0000000000c1'));
reset role;
select public.tests_claims('a0520000-0000-0000-0000-000000000004', null);
update public.centers set subscription_until = public.tests_local_midnight(1) where id = 'a0520000-0000-0000-0000-0000000000c1';
select public.tests_claims(null, null);
select is((select center_count from public.subscription_reminders()), 1, 'После отзыва заявки — напоминание за новый срок (ступень «завтра»)');
select is(
  (select count(*)::int from public.events e where e.type = 'subscription.ending'
     and e.center_id = 'a0520000-0000-0000-0000-0000000000c1' and (e.payload ->> 'days_left')::int = 1),
  1, 'А: второе событие — за 1 день, по новому сроку');
-- Ступень «сегодня» — третье событие на тот же срок? Нет: срок другой; проверяем ступень на том же сроке.
select public.tests_claims('a0520000-0000-0000-0000-000000000004', null);
update public.centers set subscription_until = public.tests_local_midnight(0) where id = 'a0520000-0000-0000-0000-0000000000c1';
select public.tests_claims(null, null);
select is((select center_count from public.subscription_reminders()), 1, 'В день срока — ступень ending_0, ещё одно напоминание');

-- Смена пояса не даёт второго напоминания за тот же срок (Р3: ключ — сам срок).
update public.centers set settings = jsonb_build_object('timezone', (select tz_day2 from t_tz)) where id = 'a0520000-0000-0000-0000-0000000000c1';
select is((select center_count from public.subscription_reminders()), 0, 'Смена пояса — ничего нового');
update public.centers set settings = jsonb_build_object('timezone', (select tz_day from t_tz)) where id = 'a0520000-0000-0000-0000-0000000000c1';

-- Продление В: новый срок — новое напоминание перед ним.
select public.tests_claims('a0520000-0000-0000-0000-000000000004', null);
update public.centers set subscription_until = public.tests_local_midnight(3) where id = 'a0520000-0000-0000-0000-0000000000c3';
select public.tests_claims(null, null);
select is((select center_count from public.subscription_reminders()), 1, 'В после продления: ending за 3 дня');

-- Без даты — тишина (Р5).
select public.tests_claims('a0520000-0000-0000-0000-000000000004', null);
update public.centers set subscription_until = null where id = 'a0520000-0000-0000-0000-0000000000c3';
select public.tests_claims(null, null);
select is((select center_count from public.subscription_reminders()), 0, 'Центр без даты: напоминаний нет');

-- Мусор в поясе одного центра: фолбэк на Asia/Bishkek у корня (Р7), прогон без пропусков.
update public.centers set settings = '{"timezone":"Mars/Olympus"}'::jsonb where id = 'a0520000-0000-0000-0000-0000000000c2';
select is(public.center_timezone('a0520000-0000-0000-0000-0000000000c2'), 'Asia/Bishkek',
  'center_timezone: имя вне pg_timezone_names → Asia/Bishkek');
select is((select center_count + skipped_count from public.subscription_reminders()), 0,
  'Мусорный пояс у Б — прогон живёт, пропусков нет, живой trial события не даёт');
update public.centers set settings = jsonb_build_object('timezone', (select tz_night from t_tz)) where id = 'a0520000-0000-0000-0000-0000000000c2';


-- 5. Один trial-центр на владельца (Р9) ------------------------------------------------------------------------------

select public.tests_claims('a0520000-0000-0000-0000-000000000006', 'a0520000-0000-0000-0000-0000000000c4');
set local role authenticated;
select throws_ok(
  $q$ select public.create_center('Второй trial', 'Бишкек') $q$,
  '23514', null,
  'Второй trial-центр тому же владельцу — отказ');
select throws_ok(
  $q$ select public.change_member_role('a0520000-0000-0000-0000-000000000005', 'owner') $q$,
  '23514', null,
  'Повышение до owner во втором trial-центре — тот же отказ (update of role)');
reset role;

select public.tests_claims('a0520000-0000-0000-0000-000000000004', null);
set local role authenticated;
select lives_ok(
  $q$ select public.platform_create_center('Второй филиал 0052', 'owner-trial-0052@test.kg', 'Ош') $q$,
  'Платформа заводит второй центр владельцу');
reset role;
select is(
  (select count(*)::int from public.memberships m join public.centers c on c.id = m.center_id
    where m.user_id = 'a0520000-0000-0000-0000-000000000006' and m.role = 'owner' and c.plan = 'trial' and c.deleted_at is null),
  2, 'У владельца два trial-центра, второй — от платформы');
select is(
  (select count(*)::int from public.memberships m where m.user_id = 'a0520000-0000-0000-0000-000000000004'),
  0, 'Платформа членства в новом центре не получила');

-- Архивация не освобождает: trial моложе 90 дней считается.
select public.tests_claims(null, null);
update public.centers set deleted_at = now() where id = 'a0520000-0000-0000-0000-0000000000c5';
select public.tests_claims('a0520000-0000-0000-0000-000000000005', 'a0520000-0000-0000-0000-0000000000c5');
set local role authenticated;
select throws_ok(
  $q$ select public.create_center('Третий trial', null) $q$,
  '23514', null,
  'Закрыл trial-центр — новый trial всё равно только через платформу');
reset role;

-- Повышение до owner участника без своего trial — обычное совладение, проходит.
select public.tests_claims('a0520000-0000-0000-0000-000000000001','a0520000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.change_member_role('a0520000-0000-0000-0000-000000000002', 'owner') $q$,
  'Совладелец без своего trial-центра — правило не мешает');
reset role;

-- Без сессии — фикстурам и миграциям правило не мешает.
select public.tests_claims(null, null);
select lives_ok(
  $q$ insert into public.memberships (user_id, center_id, role)
      values ('a0520000-0000-0000-0000-000000000005', 'a0520000-0000-0000-0000-0000000000c2', 'owner') $q$,
  'Без auth.uid() второе owner-членство в trial проходит (граница Р9)');


-- 6. Пульт платформы (Р5, Р10, Р11) ------------------------------------------------------------------------------

select public.tests_claims('a0520000-0000-0000-0000-000000000001','a0520000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($q$ select * from public.platform_centers() $q$, '42501', null, 'platform_centers от центра — отказ');
select throws_ok($q$ select public.platform_summary() $q$, '42501', null, 'platform_summary от центра — отказ');
reset role;

-- Мусорный пояс у В не роняет пульт (Р7): фолбэк в center_timezone.
update public.centers set settings = '{"timezone":"Mars/Olympus"}'::jsonb where id = 'a0520000-0000-0000-0000-0000000000c3';
select public.tests_claims('a0520000-0000-0000-0000-000000000004', null);
set local role authenticated;
select lives_ok($q$ select * from public.platform_centers() $q$, 'platform_centers живёт при мусорном поясе одного центра');
select is(
  (select pc.no_date from public.platform_centers() pc limit 1),
  true, 'Центр без даты — первым в списке (Р5)');
select ok(
  (select pc.writable and pc.days_left = 0 and pc.owner_email = 'owner-0052@test.kg' and not pc.is_trial
     from public.platform_centers() pc where pc.center_id = 'a0520000-0000-0000-0000-0000000000c1'),
  'А: writable в день срока, days_left = 0 в поясе центра, email первого владельца');
select is(
  (select count(*)::int from public.platform_centers() pc where pc.center_id = 'a0520000-0000-0000-0000-0000000000c5'),
  0, 'Закрытый центр в списке отсутствует (Р11)');
reset role;
-- Сравнение с прямым агрегатом — от postgres: center_writable без гранта authenticated (0050), claims платформы остаются.
select is(
  (public.platform_summary() ->> 'mrr_tiyin')::bigint,
  (select coalesce(sum(p.price_tiyin), 0)::bigint from public.centers c join public.plans p on p.code = c.plan
    where c.deleted_at is null and c.plan <> 'trial' and public.center_writable(c.id)),
  'MRR — прайс живых платных центров, считает SQL (Р10)');
select is(jsonb_typeof(public.platform_summary() -> 'revenue'), 'array', 'Выручка по месяцам — массив из SQL');
select is(
  (public.platform_summary() ->> 'centers_no_date')::int,
  (select count(*)::int from public.centers c where c.deleted_at is null
     and (case when c.plan = 'trial' then c.trial_ends_at else c.subscription_until end) is null),
  'Счётчик центров без даты совпадает с прямым запросом');
select public.tests_claims(null, null);

select * from finish();

rollback;
