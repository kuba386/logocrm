-- pgTAP: кнопка «Подтвердить приход» под напоминанием (0035).
--
-- Два кейса, которых не было в 0034 и из-за которых дефекты дожили до
-- живой приёмки:
--   1. путь «событие → сообщение с кнопкой» целиком, а не confirm_lesson
--      отдельно от него;
--   2. родитель с ДВУМЯ детьми в одном групповом занятии — 0034 проверял
--      двух РАЗНЫХ родителей, и схлопывание двух сообщений в одну строку
--      журнала не всплывало.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(26);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-btn@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-btn@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-btn','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Нургуль Абдырахманова');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Родитель двоих','+996700000001');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',  null, null),
  ('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000001');

insert into public.telegram_accounts (user_id, chat_id) values
  ('77777777-7777-7777-7777-777777777777', 880001);

-- Двое детей одной семьи в одной группе — ядро проверки.
insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Айдана','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Тимур','dddddddd-0000-0000-0000-000000000001');

insert into public.groups (id, center_id, name, teacher_id) values
  ('9a9a9a9a-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Группа','aaaaaaaa-0000-0000-0000-000000000001');
insert into public.group_students (center_id, group_id, student_id, joined_at) values
  ('cccccccc-0000-0000-0000-00000000000a','9a9a9a9a-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', current_date - 7),
  ('cccccccc-0000-0000-0000-00000000000a','9a9a9a9a-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000002', current_date - 7);

insert into public.lessons (id, center_id, teacher_id, group_id, service_id, status, starts_at, ends_at) values
  ('ffffffff-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','9a9a9a9a-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','planned', now() + interval '10 hours', now() + interval '10 hours 45 minutes');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_ev (name text primary key, id bigint);

with ins as (
  insert into public.events (center_id, type, payload)
  values ('cccccccc-0000-0000-0000-00000000000a', 'lesson.reminder',
          jsonb_build_object('center_id','cccccccc-0000-0000-0000-00000000000a',
                             'lesson_id','ffffffff-0000-0000-0000-000000000001'))
  returning id)
insert into t_ev select 'reminder', id from ins;

with ins as (
  insert into public.events (center_id, type, payload)
  values ('cccccccc-0000-0000-0000-00000000000a', 'digest.daily',
          jsonb_build_object('center_id','cccccccc-0000-0000-0000-00000000000a',
                             'date', current_date, 'lessons_today', 1, 'low_balance', 0,
                             'debt_tiyin', 0, 'installments_overdue', 0))
  returning id)
insert into t_ev select 'digest', id from ins;

select public.tests_claims(null, null);


-- 1-3. Форма ответа и права ----------------------------------------------------------------------

select is(
  pg_get_function_result('public.event_messages(bigint)'::regprocedure),
  'TABLE(recipient_user_id uuid, channel text, chat_id bigint, message text, subject_id uuid, action jsonb)',
  'event_messages отдаёт ребёнка и данные кнопки — без них n8n нечем её прикрепить');

select ok(
  has_function_privilege('bot_worker', 'public.event_messages(bigint)', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.notification_begin(bigint,uuid,text,uuid)', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.confirm_lesson_by_event(bigint,bigint,uuid)', 'EXECUTE'),
  'Перевыпущенные функции остались за bot_worker');

select ok(
  not has_function_privilege('authenticated', 'public.confirm_lesson_by_event(bigint,bigint,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.event_messages(bigint)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.notification_begin(bigint,uuid,text,uuid)', 'EXECUTE'),
  'И недоступны никому больше');


-- 4-10. Кнопка под напоминанием ------------------------------------------------------------------

create temporary table t_msg as
  select * from public.event_messages((select id from t_ev where name = 'reminder'));

select is((select count(*)::int from t_msg), 2,
  'Родителю двоих детей в одном занятии уходит два сообщения, а не одно');

select set_eq(
  $q$ select subject_id::text from t_msg $q$,
  $q$ values ('eeeeeeee-0000-0000-0000-000000000001'), ('eeeeeeee-0000-0000-0000-000000000002') $q$,
  'В каждом сообщении указан свой ребёнок');

select is((select count(distinct action->>'callback_data')::int from t_msg), 2,
  'Кнопки в двух сообщениях ведут на разных детей');

select is(
  (select action->>'callback_data' from t_msg where subject_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  'c:' || (select id::text from t_ev where name = 'reminder') || ':eeeeeeee-0000-0000-0000-000000000001',
  'Формат callback_data — c:<событие>:<ребёнок>');

-- Р2: две uuid-ки с префиксом дали бы 81 байт, и Telegram отверг бы кнопку.
select cmp_ok((select max(length(action->>'callback_data'))::int from t_msg), '<=', 64,
  'callback_data помещается в лимит Telegram — 64 байта');

select is((select action->>'label' from t_msg limit 1), 'Подтвердить приход',
  'Подпись кнопки приходит из базы, а не собирается в сценарии');

select is((select count(*)::int from t_msg where channel = 'telegram'), 2,
  'Оба сообщения идут в Telegram: чат у родителя привязан');


-- 11-13. Где кнопки быть не должно ----------------------------------------------------------------

create temporary table t_digest as
  select * from public.event_messages((select id from t_ev where name = 'digest'));

select is((select count(*)::int from t_digest), 1, 'Сводка уходит владельцу');
select is((select action from t_digest), null, 'У сводки кнопки нет');
select is((select subject_id from t_digest), null, 'И ребёнка в ней нет — сводка не про конкретного ребёнка');


-- 14-16. Журнал различает детей --------------------------------------------------------------------

create temporary table t_log (name text primary key, id uuid);
insert into t_log values ('first',
  public.notification_begin((select id from t_ev where name = 'reminder'),
                            '77777777-7777-7777-7777-777777777777', 'telegram',
                            'eeeeeeee-0000-0000-0000-000000000001'));
insert into t_log values ('second',
  public.notification_begin((select id from t_ev where name = 'reminder'),
                            '77777777-7777-7777-7777-777777777777', 'telegram',
                            'eeeeeeee-0000-0000-0000-000000000002'));

select isnt((select id from t_log where name = 'second'), null,
  'Второе сообщение того же родителя захватывается, а не считается дублем (Р3)');
select isnt(
  (select id from t_log where name = 'first'), (select id from t_log where name = 'second'),
  'Это разные строки журнала');
select is(
  public.notification_begin((select id from t_ev where name = 'reminder'),
                            '77777777-7777-7777-7777-777777777777', 'telegram',
                            'eeeeeeee-0000-0000-0000-000000000001'),
  (select id from t_log where name = 'first'),
  'Повтор по тому же ребёнку по-прежнему возвращает ту же строку');


-- 17-20. Нажатие кнопки ------------------------------------------------------------------------------

select is(
  public.confirm_lesson_by_event(880001, (select id from t_ev where name = 'reminder'),
                                 'eeeeeeee-0000-0000-0000-000000000001'),
  true, 'Родитель подтверждает приход нажатием кнопки');
select is(
  public.confirm_lesson_by_event(880001, (select id from t_ev where name = 'reminder'),
                                 'eeeeeeee-0000-0000-0000-000000000001'),
  false, 'Повторное нажатие — false, не ошибка');
select is((select count(*)::int from public.lesson_confirmations), 1,
  'В подтверждениях одна строка — по нажатому ребёнку');
select throws_ok(
  format($q$ select public.confirm_lesson_by_event(880001, %s, 'eeeeeeee-0000-0000-0000-000000000001') $q$,
         (select id from t_ev where name = 'digest')),
  '42704', null,
  'Кнопка с чужим событием (не напоминанием) — отказ, а не подтверждение вслепую');


-- 21-22. Ребёнок обязателен, и старые строки не пересылаются ---------------------------------------

-- Р5: узел сценария потерял маппинг p_subject_id — это отказ, а не молчание.
select throws_ok(
  format($q$ select public.notification_begin(%s, '77777777-7777-7777-7777-777777777777', 'telegram') $q$,
         (select id from t_ev where name = 'reminder')),
  '22023', null,
  'Захват без ребёнка отбивается триггером, а не возвращает дедуп к прежнему поведению');

-- Р6: строка, записанная до 0035. Триггер такие больше не пропускает,
-- поэтому для имитации он на время выключается — в бою эти строки уже лежат.
alter table public.notification_log disable trigger notification_log_subject_required;
insert into public.notification_log (center_id, event_id, recipient_user_id, channel, status, subject_id)
select 'cccccccc-0000-0000-0000-00000000000a', id, '77777777-7777-7777-7777-777777777777', 'whatsapp_link', 'sent', null
  from t_ev where name = 'digest';
alter table public.notification_log enable trigger notification_log_subject_required;

select is(
  public.notification_begin((select id from t_ev where name = 'digest'),
                            '77777777-7777-7777-7777-777777777777', 'whatsapp_link',
                            'eeeeeeee-0000-0000-0000-000000000001'),
  null,
  'Сообщение, ушедшее до 0035, не отправляется второй раз из-за смены ключа (Р6)');


-- 23-25. Получатель без бота ------------------------------------------------------------------------

update public.telegram_accounts set unlinked_at = now() where chat_id = 880001;

create temporary table t_nobot as
  select * from public.event_messages((select id from t_ev where name = 'reminder'));

select is((select count(*)::int from t_nobot where channel = 'whatsapp_link'), 2,
  'Без привязанного чата оба сообщения уходят каналом whatsapp_link');
select is((select count(*)::int from t_nobot where action is not null), 0,
  'Кнопки там нет: в WhatsApp её некуда прикрепить');
select is((select count(*)::int from t_nobot where subject_id is null), 0,
  'Ребёнок при этом указан — журналу он нужен в любом канале');


-- 26. Кнопка из старой переписки --------------------------------------------------------------------

update public.lessons set status = 'cancelled' where id = 'ffffffff-0000-0000-0000-000000000001';

select throws_ok(
  format($q$ select public.confirm_lesson_by_event(880001, %s, 'eeeeeeee-0000-0000-0000-000000000002') $q$,
         (select id from t_ev where name = 'reminder')),
  '22023', null,
  'Подтвердить приход на отменённое занятие нельзя — кнопка в переписке живёт дольше занятия (Р7)');

select * from finish();

rollback;
