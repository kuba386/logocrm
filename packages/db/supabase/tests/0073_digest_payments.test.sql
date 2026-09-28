-- pgTAP: сводка digest.daily со строкой про поступления (0073).
--
-- Главное, что ловит файл:
--   - сумма берётся из платежей на момент доставки, а не из payload: событие
--     с подделанными полями суммы (до 0075 emit_event была открыта любой роли центра)
--     даёт в сообщении настоящую цифру;
--   - границы суток центра: платёж ровно в 00:00 дня «до сводки» входит, в
--     00:00 дня сводки и на микросекунду раньше начала — нет; возврат и
--     корректировка входят со знаком, расход и платёж чужого центра — нет;
--   - три вида текста: сумма, «платежей не было», отрицательная сумма;
--   - предпросмотр шаблона не показывает {payments} буквально;
--   - дефолты платформы содержат {payments}, шаблон центра без него не
--     ломается, шаблон центра с ним подставляется;
--   - остальные ветки event_messages живы (installment.due — родителю);
--   - гранты: event_messages — только bot_worker, preview_message — только
--     authenticated, center_payments_day — никто.
-- Фикстура вставляется как postgres; платежи — обычным путём от владельца.
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(28);


-- 1. Гранты ---------------------------------------------------------------------------------------

select ok(
  has_function_privilege('bot_worker', 'public.event_messages(bigint)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.event_messages(bigint)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.event_messages(bigint)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.event_messages(bigint)', 'EXECUTE')
  and not has_function_privilege('public', 'public.event_messages(bigint)', 'EXECUTE'),
  'event_messages по-прежнему исполняет только bot_worker');

select ok(
  has_function_privilege('authenticated', 'public.preview_message(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.preview_message(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('bot_worker', 'public.preview_message(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('public', 'public.preview_message(text,jsonb)', 'EXECUTE'),
  'preview_message — только authenticated');

select ok(
  not has_function_privilege('bot_worker', 'public.center_payments_day(uuid,date)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.center_payments_day(uuid,date)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.center_payments_day(uuid,date)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.center_payments_day(uuid,date)', 'EXECUTE')
  and not has_function_privilege('public', 'public.center_payments_day(uuid,date)', 'EXECUTE'),
  'center_payments_day по-прежнему без грантов ни у кого — воркер зовёт её только через event_messages');


-- 2. Дефолты платформы ---------------------------------------------------------------------------

select is(
  (select count(*)::int from public.message_templates
    where center_id is null and event_type = 'digest.daily' and deleted_at is null
      and text like '%{payments}%'),
  2, 'Оба дефолта платформы сводки (telegram и whatsapp_link) содержат {payments}');
select ok(
  (select bool_and(text like 'Сводка на {date}: занятий сегодня — {lessons}, заканчивается абонементов — {low}, долг — {debt}, просроченных рассрочек — {overdue}. Поступления {payments}.')
     from public.message_templates
    where center_id is null and event_type = 'digest.daily' and deleted_at is null),
  'Дефолт — старый текст плюс одна фраза, ничего лишнего не потеряно');


-- 3. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000',
       ('73000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0073@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 6) n;

insert into public.centers (id, name, slug, settings) values
  ('73000000-0000-0000-0000-0000000000c1','Центр 0073',  'centr-0073',   '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('73000000-0000-0000-0000-0000000000c2','Центр 0073 Б','centr-0073-b', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('73000000-0000-0000-0000-00000000aa01','73000000-0000-0000-0000-0000000000c1','Специалист 0073');

insert into public.payers (id, center_id, full_name, phone) values
  ('73000000-0000-0000-0000-00000000dd01','73000000-0000-0000-0000-0000000000c1','Плательщик 0073','+996700007370'),
  ('73000000-0000-0000-0000-00000000dd02','73000000-0000-0000-0000-0000000000c2','Плательщик Б 0073','+996700007371');

-- 1 owner c1 · 2 admin c1 · 3 teacher c1 · 4 parent c1 · 5 owner c2.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('73000000-0000-0000-0000-000000000001','73000000-0000-0000-0000-0000000000c1','owner',  null, null),
  ('73000000-0000-0000-0000-000000000002','73000000-0000-0000-0000-0000000000c1','admin',  null, null),
  ('73000000-0000-0000-0000-000000000003','73000000-0000-0000-0000-0000000000c1','teacher','73000000-0000-0000-0000-00000000aa01', null),
  ('73000000-0000-0000-0000-000000000004','73000000-0000-0000-0000-0000000000c1','parent', null, '73000000-0000-0000-0000-00000000dd01'),
  ('73000000-0000-0000-0000-000000000005','73000000-0000-0000-0000-0000000000c2','owner',  null, null);

insert into public.telegram_accounts (user_id, chat_id) values
  ('73000000-0000-0000-0000-000000000001', 730001),
  ('73000000-0000-0000-0000-000000000004', 730004),
  ('73000000-0000-0000-0000-000000000005', 730005);

insert into public.students (id, center_id, full_name, payer_id) values
  ('73000000-0000-0000-0000-00000000ee01','73000000-0000-0000-0000-0000000000c1','Ребёнок 0073','73000000-0000-0000-0000-00000000dd01');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

create temporary table t_src as
  select (select id from public.payment_sources where center_id = '73000000-0000-0000-0000-0000000000c1' order by sort, code limit 1) as cash_id,
         (select id from public.payment_sources where center_id = '73000000-0000-0000-0000-0000000000c2' order by sort, code limit 1) as cash_b_id;
create temporary table t_cat as
  select id from public.expense_categories where center_id = '73000000-0000-0000-0000-0000000000c1' order by 1 limit 1;
grant select on t_src, t_cat to public;

-- Платежи центра c1 — от имени владельца. Дата сводки D = 2026-06-15,
-- «вчера» = 2026-06-14 по поясу центра (+06).
select public.tests_claims('73000000-0000-0000-0000-000000000001','73000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.record_payment('73000000-0000-0000-0000-00000000dd01', 30000, 'payment', null, null, (select cash_id from t_src), '2026-06-14 00:00:00+06', 'ровно 00:00 вчера');
select public.record_payment('73000000-0000-0000-0000-00000000dd01', 20000, 'payment', null, null, null,                       '2026-06-14 23:59:59+06', 'без источника, 23:59:59');
select public.record_payment('73000000-0000-0000-0000-00000000dd01', 9000,  'payment', null, null, (select cash_id from t_src), '2026-06-13 23:59:59.999999+06', 'на микросекунду раньше');
select public.record_payment('73000000-0000-0000-0000-00000000dd01', 7000,  'payment', null, null, (select cash_id from t_src), '2026-06-15 00:00:00+06', 'ровно 00:00 дня сводки');
select public.record_payment('73000000-0000-0000-0000-00000000dd01', -5000, 'refund', null, null, (select cash_id from t_src), '2026-06-14 12:00:00+06', 'возврат');
select public.record_payment('73000000-0000-0000-0000-00000000dd01', -1000, 'correction', null, null, null,                     '2026-06-14 13:00:00+06', 'корректировка');
select public.record_payment('73000000-0000-0000-0000-00000000dd01', -3000, 'refund', null, null, (select cash_id from t_src), '2026-06-10 12:00:00+06', 'день только с возвратом');
select public.record_payment('73000000-0000-0000-0000-00000000dd01', 10000, 'payment', null, null, (select cash_id from t_src), '2026-06-05 10:00:00+06', 'плюс X');
select public.record_payment('73000000-0000-0000-0000-00000000dd01', -10000, 'refund', null, null, (select cash_id from t_src), '2026-06-05 11:00:00+06', 'минус X');
select public.record_expense((select id from t_cat), 40000, 'expense', (select cash_id from t_src), '2026-06-14', 'расход вчера');

select public.tests_claims('73000000-0000-0000-0000-000000000005','73000000-0000-0000-0000-0000000000c2');
select public.record_payment('73000000-0000-0000-0000-00000000dd02', 88800, 'payment', null, null, (select cash_b_id from t_src), '2026-06-14 10:00:00+06', 'чужой центр в те же сутки');
reset role;
select public.tests_claims(null, null);

create temporary table t_ev (name text primary key, id bigint);
grant all on t_ev to public;

insert into public.events (center_id, type, payload)
select '73000000-0000-0000-0000-0000000000c1', 'digest.daily',
       jsonb_build_object('center_id', '73000000-0000-0000-0000-0000000000c1', 'date', v.d,
                          'lessons_today', 5, 'low_balance', 1, 'debt_tiyin', 70000, 'installments_overdue', 0)
  from (values ('2026-06-15'), ('2026-06-16'), ('2026-06-20'), ('2026-06-11'), ('2026-06-06')) as v(d);
insert into t_ev
  select 'digest_' || (payload ->> 'date'), id from public.events where type = 'digest.daily' and center_id = '73000000-0000-0000-0000-0000000000c1';

-- Подделка центра: events.center_id = c1 (его проверяет emit_event), а в
-- payload лежит центр Б — сумма обязана быть c1, а не Б.
insert into public.events (center_id, type, payload)
values ('73000000-0000-0000-0000-0000000000c1', 'digest.daily',
        jsonb_build_object('center_id', '73000000-0000-0000-0000-0000000000c2', 'date', '2026-06-15',
                           'lessons_today', 5, 'low_balance', 1, 'debt_tiyin', 70000, 'installments_overdue', 0));
insert into t_ev select 'forged_center', max(id) from public.events where type = 'digest.daily';

-- Подделка: любой участник центра может положить в payload что угодно.
insert into public.events (center_id, type, payload)
values ('73000000-0000-0000-0000-0000000000c1', 'digest.daily',
        jsonb_build_object('center_id', '73000000-0000-0000-0000-0000000000c1', 'date', '2026-06-15',
                           'lessons_today', 5, 'low_balance', 1, 'debt_tiyin', 70000, 'installments_overdue', 0,
                           'payments_yesterday_tiyin', 99999900, 'payments_yesterday_ops', 3, 'payments', 'подделка'));
insert into t_ev select 'forged', max(id) from public.events where type = 'digest.daily';

insert into public.events (center_id, type, payload)
values ('73000000-0000-0000-0000-0000000000c2', 'digest.daily',
        jsonb_build_object('center_id', '73000000-0000-0000-0000-0000000000c2', 'date', '2026-06-15',
                           'lessons_today', 0, 'low_balance', 0, 'debt_tiyin', 0, 'installments_overdue', 0));
insert into t_ev select 'digest_c2', max(id) from public.events where type = 'digest.daily';

insert into public.events (center_id, type, payload)
values ('73000000-0000-0000-0000-0000000000c1', 'installment.due',
        jsonb_build_object('center_id', '73000000-0000-0000-0000-0000000000c1',
                           'student_id', '73000000-0000-0000-0000-00000000ee01',
                           'amount_tiyin', 200000, 'due_date', '2026-06-15'));
insert into t_ev select 'installment', max(id) from public.events where type = 'installment.due';


-- 4. Сумма за сутки центра ------------------------------------------------------------------------

select is(
  (select message from public.event_messages((select id from t_ev where name = 'digest_2026-06-15')) where recipient_user_id = '73000000-0000-0000-0000-000000000001' limit 1),
  'Сводка на 15.06.2026: занятий сегодня — 5, заканчивается абонементов — 1, долг — 700,00 сом, просроченных рассрочек — 0. Поступления за 14.06: 440,00 сом (операций: 4).',
  'Вчера: 30 000 + 20 000 − 5 000 возврат − 1 000 корректировка = 440,00 сом, 4 операции; 00:00 вчера входит, 23:59:59 входит');
select ok(
  (select message not like '%90,00%' and message not like '%70,00%' and message not like '%400,00%' and message not like '%888,00%'
     from public.event_messages((select id from t_ev where name = 'digest_2026-06-15')) limit 1),
  'Не вошли: платёж на микросекунду раньше, платёж в 00:00 дня сводки, расход 40 000, платёж чужого центра');
select ok(
  (select message like '% Поступления за 15.06: 70,00 сом (операций: 1).' from public.event_messages((select id from t_ev where name = 'digest_2026-06-16')) limit 1),
  'Платёж ровно в 00:00 дня сводки — вчерашний для следующей сводки');
select ok(
  (select message like '% Поступления за 19.06: платежей не было.' from public.event_messages((select id from t_ev where name = 'digest_2026-06-20')) limit 1),
  'День без платежей — явная фраза, не «0,00 сом» и не пустота');
select ok(
  (select message like '% Поступления за 10.06: −30,00 сом (операций: 1).' from public.event_messages((select id from t_ev where name = 'digest_2026-06-11')) limit 1),
  'Отрицательная сумма — со знаком «−»');
select ok(
  (select bool_and(message like '%Поступления за 14.06: 440,00 сом (операций: 4).')
     from public.event_messages((select id from t_ev where name = 'forged_center'))),
  'Центр берётся из events.center_id, не из payload: чужой center_id в payload не открывает поступления другого центра');
select ok(
  (select message like '% Поступления за 05.06: 0,00 сом (операций: 2).'
     from public.event_messages((select id from t_ev where name = 'digest_2026-06-06')) limit 1),
  'Платёж и возврат на одну сумму — «0,00 сом (операций: 2)», а не «платежей не было»: пусто и ноль различаются');
select is(
  (select message from public.event_messages((select id from t_ev where name = 'forged')) where recipient_user_id = '73000000-0000-0000-0000-000000000001' limit 1),
  (select message from public.event_messages((select id from t_ev where name = 'digest_2026-06-15')) where recipient_user_id = '73000000-0000-0000-0000-000000000001' limit 1),
  'Подделанные поля payload (сумма, операции, готовая строка) игнорируются — цифра всегда из платежей');
select ok(
  (select message like '%Поступления за 14.06: 888,00 сом (операций: 1).'
     from public.event_messages((select id from t_ev where name = 'digest_c2')) limit 1),
  'Центр Б получает свою цифру, не чужую');
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'digest_2026-06-15'))
    where message like '%Поступления за 14.06: 440,00 сом (операций: 4).'),
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'digest_2026-06-15'))),
  'Все получатели сводки видят одну и ту же цифру');
select ok(
  (select count(*) from public.event_messages((select id from t_ev where name = 'digest_2026-06-15'))
    where recipient_user_id in ('73000000-0000-0000-0000-000000000003', '73000000-0000-0000-0000-000000000004')) = 0,
  'Специалист и родитель сводку с деньгами не получают — только owner/admin');


-- 5. Шаблоны центра ------------------------------------------------------------------------------

insert into public.message_templates (center_id, event_type, channel, text)
values ('73000000-0000-0000-0000-0000000000c1', 'digest.daily', 'telegram', 'Свой текст: занятий {lessons}.');
select is(
  (select message from public.event_messages((select id from t_ev where name = 'digest_2026-06-15')) where recipient_user_id = '73000000-0000-0000-0000-000000000001' and channel = 'telegram' limit 1),
  'Свой текст: занятий 5.',
  'Свой шаблон центра без {payments} работает как раньше — строка про поступления не навязывается');
update public.message_templates set text = 'Итог: {payments}.'
 where center_id = '73000000-0000-0000-0000-0000000000c1' and event_type = 'digest.daily' and channel = 'telegram';
select is(
  (select message from public.event_messages((select id from t_ev where name = 'digest_2026-06-15')) where recipient_user_id = '73000000-0000-0000-0000-000000000001' and channel = 'telegram' limit 1),
  'Итог: за 14.06: 440,00 сом (операций: 4).',
  'Свой шаблон центра с {payments} — подстановка работает');


-- 6. Остальные ветки живы -------------------------------------------------------------------------

select ok(
  (select count(*) >= 1 and bool_and(message like '%2000,00 сом%')
     from public.event_messages((select id from t_ev where name = 'installment'))),
  'installment.due по-прежнему уходит родителю с деньгами из SQL — ветки рядом не задеты');
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'installment'))
    where recipient_user_id = '73000000-0000-0000-0000-000000000004'), 1,
  'И именно родителю плательщика');
select throws_ok($q$ select * from public.event_messages(999999999) $q$, '42704', 'Событие не найдено',
  'Несуществующее событие — отказ, как раньше');


-- 7. Предпросмотр --------------------------------------------------------------------------------

select public.tests_claims('73000000-0000-0000-0000-000000000001','73000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select ok(
  public.preview_message((select text from public.message_templates
                           where center_id is null and event_type = 'digest.daily' and channel = 'telegram' and deleted_at is null))
    like '%Поступления за 30.09: 12500,00 сом (операций: 7).',
  'Предпросмотр нового дефолта подставляет образец — {payments} буквально не остаётся');
select ok(
  public.preview_message('Привет, {child}: {payments}') like 'Привет, Айдана: за 30.09%',
  'Образец payments есть и для произвольного текста');
reset role;

select public.tests_claims('73000000-0000-0000-0000-000000000003','73000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($q$ select public.preview_message('x') $q$, '42501', null, 'Специалист предпросмотр не открывает — как раньше');
reset role;
select public.tests_claims(null, null);

select throws_ok($q$ select public.preview_message('x') $q$, '42501', null, 'Без сессии предпросмотра нет');


-- 8. Побайтовость и соседние функции --------------------------------------------------------------

select ok(
  pg_get_functiondef('public.event_messages(bigint)'::regprocedure) like '%center_payments_day%'
  and pg_get_functiondef('public.event_messages(bigint)'::regprocedure) like '%booking.requested%'
  and pg_get_functiondef('public.event_messages(bigint)'::regprocedure) like '%lesson.note_approved%'
  and pg_get_functiondef('public.event_messages(bigint)'::regprocedure) like '%subscription.ending%',
  'Переиздание сохранило ветки предыдущих миграций (booking, lesson.note_approved, subscription.*) — и добавило вызов center_payments_day');
select ok(
  pg_get_functiondef('public.daily_digest()'::regprocedure) not like '%center_payments_day%',
  'daily_digest не менялась: сумма считается при доставке, не при постановке события (Р1)');
select ok(
  not (select coalesce(bool_or(prosecdef is false), false) from pg_proc
        where pronamespace = 'public'::regnamespace and proname in ('event_messages', 'preview_message')),
  'Обе переизданные функции остались security definer');

select * from finish();
rollback;
