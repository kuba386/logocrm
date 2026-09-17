-- pgTAP: шаблоны сообщений и журнал отправок (0034).
--
-- Проверяется в первую очередь не текст, а два правила: кому уходит
-- сообщение (ошибка здесь отправляет остаток чужого ребёнка чужой семье) и
-- что журнал одновременно защищает от дубля и переживает сбой отправки.
--
-- Вызовы воркера идут от postgres при пустых claims — так же, как их будет
-- звать bot_worker.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(32);


-- 1-4. Дефолты платформы и права на них ------------------------------------------------------------

select is(
  (select count(*)::int from public.message_templates where center_id is null and deleted_at is null),
  14, 'Дефолты платформы заведены на семь типов × два канала');

select ok(
  not has_table_privilege('authenticated', 'public.notification_log', 'INSERT')
  and not has_table_privilege('authenticated', 'public.notification_log', 'UPDATE')
  and not has_table_privilege('service_role', 'public.notification_log', 'INSERT'),
  'Журнал пишется только через RPC воркера — ни браузер, ни service-ключ в него не пишут'
);
select ok(
  has_function_privilege('bot_worker', 'public.event_messages(bigint)', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.notification_begin(bigint,uuid,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.event_messages(bigint)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.event_messages(bigint)', 'EXECUTE'),
  'Сборка сообщений — дверь только для bot_worker'
);
select ok(
  has_function_privilege('authenticated', 'public.preview_message(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.render_template(text,jsonb)', 'EXECUTE'),
  'Предпросмотр открыт, внутренний рендер — нет'
);


-- 5-8. Формат денег и подстановка ------------------------------------------------------------------

select is(public.format_som(200000::bigint), '2000,00 сом', 'Тыйыны в сомы: 200000 → 2000,00');
select is(public.format_som(70000::bigint),  '700,00 сом',  '70000 → 700,00');
select is(public.format_som(5::bigint),      '0,05 сом',    'Копейки не теряются');
select is(
  public.render_template('У {child} осталось {left}', jsonb_build_object('child', 'Айдана', 'left', '2')),
  'У Айдана осталось 2', 'Подстановка по ключам');


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-msg@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-msg@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-tg-msg@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','88888888-8888-8888-8888-888888888888','authenticated','authenticated','parent-wa-msg@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-msg','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Нургуль Абдырахманова');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Логопед',70000);

-- Родитель 7777 с привязанным Telegram, родитель 8888 — без него.
insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Родитель с ботом','+996700000001'),
  ('dddddddd-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Родитель без бота','+996700000002');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',  null, null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001', null),
  ('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000001'),
  ('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000002');

insert into public.telegram_accounts (user_id, chat_id) values
  ('77777777-7777-7777-7777-777777777777', 777001);

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Айдана','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Тимур','dddddddd-0000-0000-0000-000000000002');

-- Групповое занятие с детьми двух разных семей: напоминание обязано уйти
-- обоим родителям, и каждому — про своего ребёнка.
insert into public.groups (id, center_id, name, teacher_id) values
  ('9a9a9a9a-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Группа','aaaaaaaa-0000-0000-0000-000000000001');
-- center_id явно: его проверяет BEFORE-триггер group_students_check_center_refs
-- (0022), а current_center() в фикстуре пуст.
insert into public.group_students (center_id, group_id, student_id, joined_at) values
  ('cccccccc-0000-0000-0000-00000000000a','9a9a9a9a-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', current_date - 7),
  ('cccccccc-0000-0000-0000-00000000000a','9a9a9a9a-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000002', current_date - 7);

insert into public.lessons (id, center_id, teacher_id, group_id, service_id, status, starts_at, ends_at) values
  ('ffffffff-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','9a9a9a9a-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','planned','2026-10-01 10:00+06','2026-10-01 10:45+06');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_ev (name text primary key, id bigint);

with ins_reminder as (
  insert into public.events (center_id, type, payload)
  values ('cccccccc-0000-0000-0000-00000000000a', 'lesson.reminder',
          jsonb_build_object('center_id','cccccccc-0000-0000-0000-00000000000a',
                             'lesson_id','ffffffff-0000-0000-0000-000000000001'))
  returning id)
insert into t_ev select 'reminder', id from ins_reminder;

with ins_low as (
  insert into public.events (center_id, type, payload)
  values ('cccccccc-0000-0000-0000-00000000000a', 'subscription.low_balance',
          jsonb_build_object('center_id','cccccccc-0000-0000-0000-00000000000a',
                             'student_id','eeeeeeee-0000-0000-0000-000000000001',
                             'lessons_left', 2))
  returning id)
insert into t_ev select 'low', id from ins_low;

with ins_digest as (
  insert into public.events (center_id, type, payload)
  values ('cccccccc-0000-0000-0000-00000000000a', 'digest.daily',
          jsonb_build_object('center_id','cccccccc-0000-0000-0000-00000000000a',
                             'date','2026-10-01','lessons_today',5,'low_balance',1,
                             'debt_tiyin',70000,'installments_overdue',0))
  returning id)
insert into t_ev select 'digest', id from ins_digest;

with ins_unknown as (
  insert into public.events (center_id, type, payload)
  values ('cccccccc-0000-0000-0000-00000000000a', 'expense.recorded', '{}'::jsonb)
  returning id)
insert into t_ev select 'unknown', id from ins_unknown;

select public.tests_claims(null, null);


-- 9-17. Событие → сообщения --------------------------------------------------------------------------

select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'reminder'))),
  2, 'Напоминание о групповом занятии уходит обоим родителям — по одному сообщению на семью');

select ok(
  (select message like '%Айдана%'
     from public.event_messages((select id from t_ev where name = 'reminder'))
    where recipient_user_id = '77777777-7777-7777-7777-777777777777'),
  'Каждому родителю — про его ребёнка');
select ok(
  (select message not like '%Тимур%'
     from public.event_messages((select id from t_ev where name = 'reminder'))
    where recipient_user_id = '77777777-7777-7777-7777-777777777777'),
  'И ни слова про чужого ребёнка из той же группы');

select is(
  (select channel from public.event_messages((select id from t_ev where name = 'reminder'))
    where recipient_user_id = '77777777-7777-7777-7777-777777777777'),
  'telegram', 'Родителю с привязанным чатом — канал telegram');
select is(
  (select channel from public.event_messages((select id from t_ev where name = 'reminder'))
    where recipient_user_id = '88888888-8888-8888-8888-888888888888'),
  'whatsapp_link', 'Родителю без бота — whatsapp_link, чтобы интерфейс показал кнопку');
select is(
  (select chat_id from public.event_messages((select id from t_ev where name = 'reminder'))
    where recipient_user_id = '88888888-8888-8888-8888-888888888888'),
  null, 'И без chat_id');

select ok(
  (select message like '%10:00%'
     from public.event_messages((select id from t_ev where name = 'reminder'))
    where recipient_user_id = '77777777-7777-7777-7777-777777777777'),
  'Время — в поясе центра, а не в UTC');

select set_eq(
  format($q$ select recipient_user_id::text from public.event_messages(%s) $q$,
         (select id from t_ev where name = 'low')),
  $q$ values ('77777777-7777-7777-7777-777777777777') $q$,
  'Остаток абонемента уходит ровно одному человеку — родителю этого ребёнка');

select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'unknown'))),
  0, 'Тип без обработчика сообщений не порождает — воркер обязан записать это в журнал (Р3)');


-- 18-20. Сводка и свой шаблон центра -------------------------------------------------------------------

select set_eq(
  format($q$ select recipient_user_id::text from public.event_messages(%s) $q$,
         (select id from t_ev where name = 'digest')),
  $q$ values ('11111111-1111-1111-1111-111111111111') $q$,
  'Сводка уходит владельцу, а не родителям и не специалисту');

select ok(
  (select message like '%700,00 сом%'
     from public.event_messages((select id from t_ev where name = 'digest'))),
  'Деньги в сводке форматирует SQL — тыйыны не доезжают до JS');

-- Центр правит текст: своя строка перекрывает дефолт платформы.
insert into public.message_templates (center_id, event_type, channel, text)
values ('cccccccc-0000-0000-0000-00000000000a', 'subscription.low_balance', 'telegram',
        'Свой текст центра: у {child} осталось {left}.');

select ok(
  (select message like 'Свой текст центра:%'
     from public.event_messages((select id from t_ev where name = 'low'))),
  'Шаблон центра перекрывает дефолт платформы (Р1)');


-- 21-28. Журнал: дубль и сбой ---------------------------------------------------------------------------

create temporary table t_log (name text primary key, id uuid);

insert into t_log values ('first',
  public.notification_begin((select id from t_ev where name = 'low'),
                            '77777777-7777-7777-7777-777777777777', 'telegram'));

select isnt((select id from t_log where name = 'first'), null, 'Первый захват отправки заводит строку');
select is(
  (select status from public.notification_log where id = (select id from t_log where name = 'first')),
  'pending', 'Строка заводится как pending — до отправки, иначе защиты от дубля нет (Р4)');

select is(
  public.notification_begin((select id from t_ev where name = 'low'),
                            '77777777-7777-7777-7777-777777777777', 'telegram'),
  (select id from t_log where name = 'first'),
  'Повторный захват недоставленного — тот же id: обработчик упал между захватом и отправкой');

select is(
  public.notification_finish((select id from t_log where name = 'first'), 'sent', null, 'текст'), true,
  'Отправка закрывается');
select is(
  public.notification_begin((select id from t_ev where name = 'low'),
                            '77777777-7777-7777-7777-777777777777', 'telegram'),
  null, 'После успешной отправки второй раз не шлём — повтор пачки ничего не дублирует');

select throws_ok(
  format($q$ update public.notification_log set status = 'pending' where id = %L $q$,
         (select id from t_log where name = 'first')),
  '22023', null,
  'sent → pending отбивает триггер: переходы — инвариант, а не порядок нод в сценарии n8n (Р4)');

-- Неудача и повтор: единственный путь назад.
insert into t_log values ('second',
  public.notification_begin((select id from t_ev where name = 'low'),
                            '88888888-8888-8888-8888-888888888888', 'whatsapp_link'));
select is(
  public.notification_finish((select id from t_log where name = 'second'), 'failed', 'телеграм не ответил'), true,
  'Неудачная отправка помечается failed');
select is(
  public.notification_begin((select id from t_ev where name = 'low'),
                            '88888888-8888-8888-8888-888888888888', 'whatsapp_link'),
  (select id from t_log where name = 'second'),
  'После неудачи сообщение можно отправить снова — иначе оно потеряно навсегда');


-- 29-32. Пропуск, видимость журнала, предпросмотр --------------------------------------------------------

select isnt(
  public.notification_skip((select id from t_ev where name = 'unknown'), 'тип без обработчика'), null,
  'Событие без получателей оставляет строку в журнале, а не тишину (Р3)');
select is(
  public.notification_skip((select id from t_ev where name = 'unknown'), 'ещё раз'), null,
  'Повторный пропуск второй строки не создаёт (Р5: nulls not distinct)');

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.notification_log), 0,
  'Специалист журнал не читает: в тексте имя ребёнка и остаток');
select throws_ok($q$ select public.preview_message('У {child} осталось {left}') $q$,
  '42501', null, 'Предпросмотр шаблонов — не для специалиста');
reset role;

select * from finish();

rollback;
