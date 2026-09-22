-- pgTAP: заявки на оплату, продление платформой, контур бота при просрочке (0051).
--
-- Заборы: platform_payments — только select-политика и грант select, в списке
-- исключений guard; справочник событий с audience/subject_required; дефолтные
-- шаблоны. Констрейнты подтверждения. Главный путь: owner/admin просроченного
-- центра подаёт заявку, вторая открытая — 23505, отзыв, видимость по ролям;
-- платформа отклоняет/продлевает, повтор — отказ без изменений; база срока —
-- trial и живая подписка; закрытый центр — 42704. Шаблон платформенного типа
-- центр не правит. Доставка: только платформа с telegram, subject не нужен,
-- {until} в поясе центра. Контур бота: null до ai_jobs, одно событие на
-- диктовку, регрессия для живого центра.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(53);


-- 1. Заборы ----------------------------------------------------------------------------------------------

select is_empty(
  $$ select policyname from pg_policies where schemaname = 'public' and tablename = 'platform_payments' and cmd <> 'SELECT' $$,
  'platform_payments: ни одной политики на insert/update/delete — запись только RPC');

select set_eq(
  $$ select privilege_type from information_schema.role_table_grants
      where grantee = 'authenticated' and table_schema = 'public' and table_name = 'platform_payments' $$,
  $$ values ('SELECT') $$,
  'platform_payments: authenticated — ровно SELECT');

select ok(
  exists (select 1 from public.readonly_guard_exempt_tables() x where x.table_name = 'platform_payments'),
  'platform_payments в списке исключений guard — заявка проходит и в read-only (0050 Р2)');

select set_eq(
  $$ select event_type || ':' || audience || ':' || subject_required::text
       from public.notification_event_types
      where event_type in ('platform.payment_submitted', 'subscription.extended', 'subscription.voice_blocked', 'digest.daily', 'event.failed') $$,
  $$ values ('platform.payment_submitted:platform:false'), ('subscription.extended:center:false'),
            ('subscription.voice_blocked:center:true'), ('digest.daily:center:false'), ('event.failed:center:false') $$,
  'Справочник событий: адресат и обязательность subject (Р1, Р10)');

select is(
  (select count(*)::int from public.message_templates
    where center_id is null and deleted_at is null
      and event_type in ('platform.payment_submitted', 'subscription.extended', 'subscription.voice_blocked')),
  5, 'Дефолтные шаблоны: платформе — только telegram, центру — оба канала');


-- 2. Констрейнты подтверждения (Р4, Р5) — прямой insert от postgres ----------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0510000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0051@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0510000-0000-0000-0000-000000000002','authenticated','authenticated','admin-0051@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0510000-0000-0000-0000-000000000003','authenticated','authenticated','teacher-0051@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0510000-0000-0000-0000-000000000004','authenticated','authenticated','platform-0051@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0510000-0000-0000-0000-000000000005','authenticated','authenticated','owner-b-0051@test.kg','','','','','','','','');
update auth.users set email_confirmed_at = now() where id = 'a0510000-0000-0000-0000-000000000004';
insert into public.platform_admins (email) values ('platform-0051@test.kg');

-- Центр А — просроченный solo; центр Б — живой trial (дефолт 14 дней).
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('a0510000-0000-0000-0000-0000000000c1','Центр 0051 просрочен','centr-0051-a','solo', now() - interval '2 days','{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, settings) values
  ('a0510000-0000-0000-0000-0000000000c2','Центр 0051 живой','centr-0051-b','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0510000-0000-0000-0000-000000000010','a0510000-0000-0000-0000-0000000000c1','Специалист 0051','a0510000-0000-0000-0000-000000000003');
insert into public.services (id, center_id, name, default_price_tiyin) values
  ('a0510000-0000-0000-0000-000000000020','a0510000-0000-0000-0000-0000000000c1','Логопед',70000);
insert into public.payers (id, center_id, full_name, phone) values
  ('a0510000-0000-0000-0000-000000000030','a0510000-0000-0000-0000-0000000000c1','Родитель 0051','+996700005101');
insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('a0510000-0000-0000-0000-000000000001','a0510000-0000-0000-0000-0000000000c1','owner',  null),
  ('a0510000-0000-0000-0000-000000000002','a0510000-0000-0000-0000-0000000000c1','admin',  null),
  ('a0510000-0000-0000-0000-000000000003','a0510000-0000-0000-0000-0000000000c1','teacher','a0510000-0000-0000-0000-000000000010'),
  ('a0510000-0000-0000-0000-000000000005','a0510000-0000-0000-0000-0000000000c2','owner',  null);
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0510000-0000-0000-0000-000000000040','a0510000-0000-0000-0000-0000000000c1','Ребёнок 0051','a0510000-0000-0000-0000-000000000030');
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('a0510000-0000-0000-0000-000000000050','a0510000-0000-0000-0000-0000000000c1','a0510000-0000-0000-0000-000000000010',
   'a0510000-0000-0000-0000-000000000040','a0510000-0000-0000-0000-000000000020','planned',
   now() - interval '2 hours', now() - interval '1 hour 15 minutes');
-- Telegram: owner А и специалист А привязаны, admin А и платформа — пока нет.
insert into public.telegram_accounts (user_id, chat_id) values
  ('a0510000-0000-0000-0000-000000000001', 5101),
  ('a0510000-0000-0000-0000-000000000003', 5103);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

select throws_ok(
  $q$ insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source, confirmed_at)
      values ('a0510000-0000-0000-0000-0000000000c1', 'solo', 1, 99000, 'mbank', now()) $q$,
  '23514', null,
  'Подтверждение без тарифа/месяцев/суммы невозможно — num_nonnulls, а не цепочка равенств (Р4)');
select throws_ok(
  $q$ insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source)
      values ('a0510000-0000-0000-0000-0000000000c1', 'solo', 25, 99000, 'mbank') $q$,
  '23514', null,
  'Месяцы вне 1..24 — констрейнт, не проверка в функции (Р5)');
select throws_ok(
  $q$ insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source)
      values ('a0510000-0000-0000-0000-0000000000c1', 'solo', 1, 99000, 'paypal') $q$,
  '23514', null,
  'Неизвестный способ оплаты — констрейнт');


-- 3. Заявка от центра в read-only (Р3, Р11, Р14) -----------------------------------------------------------

select public.tests_claims('a0510000-0000-0000-0000-000000000003','a0510000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.submit_platform_payment('studio', 3, 'mbank', null) $q$,
  '42501', null,
  'Специалист заявку не подаёт');
reset role;

select public.tests_claims('a0510000-0000-0000-0000-000000000001','a0510000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.submit_platform_payment('studio', 3, 'mbank', '  чек в телеграме  ') $q$,
  'Владелец просроченного центра подаёт заявку — путь оплаты не под guard');
reset role;

select is(
  (select p.claimed_amount_tiyin from public.platform_payments p where p.center_id = 'a0510000-0000-0000-0000-0000000000c1'),
  (select pl.price_tiyin * 3 from public.plans pl where pl.code = 'studio'),
  'Сумма заявки — прайс × месяцы, посчитано в SQL (Р11)');
select is(
  (select count(*)::int from public.events where type = 'platform.payment_submitted' and center_id = 'a0510000-0000-0000-0000-0000000000c1'),
  1, 'Событие заявки одно');

set local role authenticated;
select throws_ok(
  $q$ select public.submit_platform_payment('solo', 1, 'cash', null) $q$,
  '23505', null,
  'Вторая открытая заявка — 23505 platform_payments_one_open_per_center');
reset role;

-- Отзыв — admin того же центра, потом новая заявка проходит (Р3).
select public.tests_claims('a0510000-0000-0000-0000-000000000002','a0510000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.withdraw_platform_payment((select id from public.platform_payments where center_id = 'a0510000-0000-0000-0000-0000000000c1')) $q$,
  'Администратор отзывает открытую заявку');
select lives_ok(
  $q$ select public.submit_platform_payment('solo', 1, 'elcart', null) $q$,
  'После отзыва новая заявка проходит');
reset role;

-- Видимость: чужой центр и специалист — ноль строк; owner — все свои.
select public.tests_claims('a0510000-0000-0000-0000-000000000005','a0510000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is((select count(*)::int from public.platform_payments where center_id = 'a0510000-0000-0000-0000-0000000000c1'), 0,
  'Чужой центр заявок не видит');
reset role;
select public.tests_claims('a0510000-0000-0000-0000-000000000003','a0510000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.platform_payments), 0, 'Специалист заявок своего центра не видит');
reset role;
select public.tests_claims('a0510000-0000-0000-0000-000000000001','a0510000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.platform_payments), 2, 'Владелец видит обе заявки: отозванную и открытую');
select throws_ok(
  $q$ select public.extend_subscription((select id from public.platform_payments where withdrawn_at is null), 'solo', 1, 99000, false) $q$,
  '42501', null,
  'Владелец центра сам себя не продлевает');
reset role;


-- 4. Платформа: отклонение, список, продление, идемпотентность (Р2, Р14) ------------------------------------

select public.tests_claims('a0510000-0000-0000-0000-000000000004', null);
set local role authenticated;
select throws_ok(
  $q$ select public.reject_platform_payment(
        (select id from public.platform_payments where center_id = 'a0510000-0000-0000-0000-0000000000c1' and withdrawn_at is null), '  ') $q$,
  '22023', null,
  'Отклонение без причины — отказ');
select is(
  (select count(*)::int from public.platform_open_payments() o where o.center_name = 'Центр 0051 просрочен' and o.claimed_plan = 'solo'),
  1, 'platform_open_payments: одна открытая заявка центра А — источник истины для /admin (Р2)');
select lives_ok(
  $q$ select public.extend_subscription(
        (select id from public.platform_payments where center_id = 'a0510000-0000-0000-0000-0000000000c1' and withdrawn_at is null),
        'studio', 3, 1170000, true) $q$,
  'Платформа подтверждает: тариф и месяцы — параметры действия, не поля заявки');
reset role;

select is((select plan from public.centers where id = 'a0510000-0000-0000-0000-0000000000c1'), 'studio',
  'Тариф центра сменился одним update с датой');
select ok(
  (select subscription_until between now() + interval '3 months' - interval '1 minute' and now() + interval '3 months' + interval '1 minute'
     from public.centers where id = 'a0510000-0000-0000-0000-0000000000c1'),
  'Просроченный центр: срок от сегодня + 3 месяца (Р14)');
select ok(public.center_writable('a0510000-0000-0000-0000-0000000000c1'), 'Центр снова пишет сразу после продления');
select is(
  (select count(*)::int from public.events where type = 'subscription.extended' and center_id = 'a0510000-0000-0000-0000-0000000000c1'),
  1, 'Событие продления одно');

create temporary table t0051_until as
  select subscription_until from public.centers where id = 'a0510000-0000-0000-0000-0000000000c1';

set local role authenticated;
select throws_ok(
  $q$ select public.extend_subscription(
        (select id from public.platform_payments where center_id = 'a0510000-0000-0000-0000-0000000000c1' and confirmed_at is not null),
        'studio', 3, 1170000, true) $q$,
  '22023', null,
  'Повтор по тому же payment_id — отказ');
reset role;
select is(
  (select subscription_until from public.centers where id = 'a0510000-0000-0000-0000-0000000000c1'),
  (select subscription_until from t0051_until),
  'Повтор не сдвинул срок');
select is(
  (select count(*)::int from public.events where type = 'subscription.extended' and center_id = 'a0510000-0000-0000-0000-0000000000c1'),
  1, 'Повтор не породил второго события');
set local role authenticated;
select is((select count(*)::int from public.platform_open_payments()), 0, 'Открытых заявок не осталось');
reset role;

-- Живая подписка: продление от текущего срока, не от сегодня (Р14).
select public.tests_claims('a0510000-0000-0000-0000-000000000001','a0510000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.submit_platform_payment('studio', 2, 'mbank', null);
reset role;
select public.tests_claims('a0510000-0000-0000-0000-000000000004', null);
set local role authenticated;
select public.extend_subscription(
  (select id from public.platform_payments where center_id = 'a0510000-0000-0000-0000-0000000000c1' and confirmed_at is null),
  'studio', 2, 780000, true);
reset role;
select is(
  (select subscription_until from public.centers where id = 'a0510000-0000-0000-0000-0000000000c1'),
  (select subscription_until + interval '2 months' from t0051_until),
  'Живая подписка: + 2 месяца к текущему сроку');

-- Trial: остаток не сгорает (Р14).
create temporary table t0051_trial as
  select trial_ends_at from public.centers where id = 'a0510000-0000-0000-0000-0000000000c2';
select public.tests_claims('a0510000-0000-0000-0000-000000000005','a0510000-0000-0000-0000-0000000000c2');
set local role authenticated;
select public.submit_platform_payment('solo', 1, 'cash', null);
reset role;
select public.tests_claims('a0510000-0000-0000-0000-000000000004', null);
set local role authenticated;
select public.extend_subscription(
  (select id from public.platform_payments where center_id = 'a0510000-0000-0000-0000-0000000000c2' and confirmed_at is null),
  'solo', 1, 99000, false);
reset role;
select ok(
  (select c.plan = 'solo' and c.subscription_until = t.trial_ends_at + interval '1 month'
     from public.centers c, t0051_trial t where c.id = 'a0510000-0000-0000-0000-0000000000c2'),
  'Trial: тариф solo, срок = конец trial + 1 месяц — остаток не сгорел');

-- Отклонение с причиной, после него новая заявка проходит (Р3).
select public.tests_claims('a0510000-0000-0000-0000-000000000005','a0510000-0000-0000-0000-0000000000c2');
set local role authenticated;
select public.submit_platform_payment('solo', 1, 'other', 'перевод другу');
reset role;
select public.tests_claims('a0510000-0000-0000-0000-000000000004', null);
set local role authenticated;
select public.reject_platform_payment(
  (select id from public.platform_payments where center_id = 'a0510000-0000-0000-0000-0000000000c2' and confirmed_at is null),
  'Чек не читается');
reset role;
select ok(
  (select p.rejected_at is not null and p.rejected_by = 'a0510000-0000-0000-0000-000000000004' and p.reject_reason = 'Чек не читается'
     from public.platform_payments p where p.center_id = 'a0510000-0000-0000-0000-0000000000c2' and p.confirmed_at is null),
  'Отклонение записано с причиной и автором');
select public.tests_claims('a0510000-0000-0000-0000-000000000005','a0510000-0000-0000-0000-0000000000c2');
set local role authenticated;
select lives_ok(
  $q$ select public.submit_platform_payment('solo', 1, 'mbank', null) $q$,
  'После отклонения новая заявка проходит');
reset role;

-- Закрытый центр не продлевается (Р14).
select public.tests_claims(null, null);
update public.centers set deleted_at = now() where id = 'a0510000-0000-0000-0000-0000000000c2';
select public.tests_claims('a0510000-0000-0000-0000-000000000004', null);
set local role authenticated;
select throws_ok(
  $q$ select public.extend_subscription(
        (select id from public.platform_payments where center_id = 'a0510000-0000-0000-0000-0000000000c2'
            and confirmed_at is null and rejected_at is null and withdrawn_at is null),
        'solo', 1, 99000, false) $q$,
  '42704', null,
  'Мягко удалённый центр платформа не продлевает');
reset role;
select public.tests_claims(null, null);
update public.centers set deleted_at = null where id = 'a0510000-0000-0000-0000-0000000000c2';


-- 5. Шаблон платформенного типа центр не правит (Р10) ------------------------------------------------------

select public.tests_claims('a0510000-0000-0000-0000-000000000001','a0510000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.upsert_message_template('platform.payment_submitted', 'telegram', 'подмена текста платформе', true) $q$,
  '42501', null,
  'Строка центра для платформенного типа — отказ триггера, не аргумента вызова');
select lives_ok(
  $q$ select public.upsert_message_template('subscription.extended', 'telegram', 'Продлили до {until}!', true) $q$,
  'Свой текст продления центр править может');
reset role;


-- 6. Доставка (Р1, Р7, Р12) ------------------------------------------------------------------------------------

select public.tests_claims(null, null);
select is(
  (select count(*)::int from public.notification_platform_targets('platform.payment_submitted')),
  0, 'Администратор платформы без Telegram — ноль получателей (ожидаемо, условие выката)');

insert into public.telegram_accounts (user_id, chat_id) values ('a0510000-0000-0000-0000-000000000004', 5104);

select set_eq(
  $$ select recipient_user_id::text || ':' || channel
       from public.event_messages((select min(id) from public.events where type = 'platform.payment_submitted' and center_id = 'a0510000-0000-0000-0000-0000000000c1')) $$,
  $$ values ('a0510000-0000-0000-0000-000000000004:telegram') $$,
  'Заявка уходит только платформе в telegram — owner центра с Telegram в списке нет');
select ok(
  (select m.message like '%Центр 0051 просрочен%' and m.message like '%Studio%' and m.message like '%Mbank%'
      and m.message like '%' || (select p.id::text from public.platform_payments p where p.center_id = 'a0510000-0000-0000-0000-0000000000c1' and p.withdrawn_at is not null) || '%'
      and m.subject_id is null
     from public.event_messages((select min(id) from public.events where type = 'platform.payment_submitted' and center_id = 'a0510000-0000-0000-0000-0000000000c1')) m),
  'Текст платформе: центр, тариф, способ, номер заявки; subject пуст');
select ok(
  public.notification_begin(
    (select min(id) from public.events where type = 'platform.payment_submitted' and center_id = 'a0510000-0000-0000-0000-0000000000c1'),
    'a0510000-0000-0000-0000-000000000004', 'telegram') is not null,
  'notification_begin без subject_id для платформенного типа проходит (Р1)');

select set_eq(
  $$ select recipient_user_id::text || ':' || channel
       from public.event_messages((select min(id) from public.events where type = 'subscription.extended' and center_id = 'a0510000-0000-0000-0000-0000000000c1')) $$,
  $$ values ('a0510000-0000-0000-0000-000000000001:telegram'), ('a0510000-0000-0000-0000-000000000002:whatsapp_link') $$,
  'Продление — owner (telegram) и admin (whatsapp_link) центра, никого больше');
select ok(
  (select m.message like '%' || to_char(((e.payload ->> 'until')::timestamptz) at time zone 'Asia/Bishkek', 'DD.MM.YYYY') || '%'
     from public.events e
     join lateral public.event_messages(e.id) m on m.channel = 'whatsapp_link'
    where e.id = (select min(id) from public.events where type = 'subscription.extended' and center_id = 'a0510000-0000-0000-0000-0000000000c1')),
  '{until} отрендерен в поясе центра (Р12)');


-- 7. Контур бота: подписка истекла между диктовкой и обработкой (Р8, Р9) ------------------------------------

select public.tests_claims('a0510000-0000-0000-0000-000000000003','a0510000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.request_voice_note('a0510000-0000-0000-0000-000000000050','a0510000-0000-0000-0000-000000000040');
reset role;
select public.tests_claims(null, null);
select public.arm_voice_request(
  (select token from public.lesson_voice_requests where center_id = 'a0510000-0000-0000-0000-0000000000c1' and consumed_at is null and cancelled_at is null),
  5103);
select public.report_voice_note(5103, 'file-051', 30);
update public.events set claimed_at = now() where claimed_at is null and type = 'lesson.voice_received' and center_id = 'a0510000-0000-0000-0000-0000000000c1';

create temporary table t0051_voice as
  select (select max(id) from public.events where type = 'lesson.voice_received' and center_id = 'a0510000-0000-0000-0000-0000000000c1') as event_id,
         (select id from public.lesson_voice_requests where center_id = 'a0510000-0000-0000-0000-0000000000c1') as request_id;

-- Срок истекает после диктовки.
select public.tests_claims('a0510000-0000-0000-0000-000000000004', null);
update public.centers set subscription_until = now() - interval '1 day' where id = 'a0510000-0000-0000-0000-0000000000c1';
select public.tests_claims(null, null);

select ok(public.ai_job_begin((select event_id from t0051_voice)) is null, 'ai_job_begin при просрочке — null, платные вызовы не начинаются');
select is((select count(*)::int from public.ai_jobs where event_id = (select event_id from t0051_voice)), 0, 'Строки в ai_jobs нет — null до insert (Р8)');
select is(
  (select count(*)::int from public.events e
    where e.type = 'subscription.voice_blocked' and e.center_id = 'a0510000-0000-0000-0000-0000000000c1'
      and e.payload ->> 'voice_request_id' = (select request_id::text from t0051_voice)
      and e.payload ->> 'reason_code' = 'subscription_expired'),
  1, 'Событие voice_blocked одно, с voice_request_id и reason_code');
select ok(public.ai_job_begin((select event_id from t0051_voice)) is null, 'Повторный вход после release_stale_claims — снова null');
select is(
  (select count(*)::int from public.events e where e.type = 'subscription.voice_blocked' and e.center_id = 'a0510000-0000-0000-0000-0000000000c1'),
  1, 'Второго события нет — дедупликация по данным events (Р8)');

select is(
  (select m.recipient_user_id::text || ':' || m.channel || ':' || m.subject_id::text
     from public.event_messages((select max(id) from public.events where type = 'subscription.voice_blocked')) m),
  'a0510000-0000-0000-0000-000000000003:telegram:a0510000-0000-0000-0000-000000000040',
  'voice_blocked — заказчику диктовки, subject — ребёнок');
select ok(
  (select m.message like '%Ребёнок 0051%' and m.message like '%подписка центра истекла%' and m.message not like '%ещё раз%'
     from public.event_messages((select max(id) from public.events where type = 'subscription.voice_blocked')) m),
  'Текст специалисту: подписка истекла, без «попробуйте ещё раз» (Р9)');
select throws_ok(
  $q$ select public.notification_begin((select max(id) from public.events where type = 'subscription.voice_blocked'), 'a0510000-0000-0000-0000-000000000003', 'telegram') $q$,
  '22023', null,
  'voice_blocked — о ребёнке: без subject_id журнал не принимает (Р1)');

-- Регрессия: после продления та же диктовка обрабатывается, ответ с целями (0048).
select public.tests_claims('a0510000-0000-0000-0000-000000000004', null);
update public.centers set subscription_until = now() + interval '30 days' where id = 'a0510000-0000-0000-0000-0000000000c1';
select public.tests_claims(null, null);
select ok(
  (public.ai_job_begin((select event_id from t0051_voice))) ? 'student_goals',
  'Живой центр: ai_job_begin отдаёт работу с student_goals (регрессия 0048)');
select is((select count(*)::int from public.ai_jobs where event_id = (select event_id from t0051_voice)), 1, 'Строка в ai_jobs создана');

select * from finish();

rollback;
