-- pgTAP: уведомления этапа 11 (0097).
--
-- Все окна — на фиксированных моментах 2030 года в поясе Asia/Bishkek (UTC+6):
-- *_at(p_now) принимает время параметром, поэтому результат не зависит от
-- часа прогона CI (Б1). 2030-03-04 — понедельник.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

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
select '00000000-0000-0000-0000-000000000000', ('97000000-0000-0000-0000-0000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0097@test.kg', '', '', '', '', '', '', '', ''
  from unnest(array['01', '02', '11', '12', '13', '21', '22']) n;

-- А — центр теста, Б — второй центр (границы). Пояс задан явно.
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('97000000-0000-0000-0000-0000000000c1', 'Центр А 0097', 'centr-a-0097', 'studio', now() + interval '30 days', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('97000000-0000-0000-0000-0000000000c2', 'Центр Б 0097', 'centr-b-0097', 'studio', now() + interval '30 days', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-0000000000c1', 'Специалист с Telegram', '97000000-0000-0000-0000-000000000021'),
  ('97000000-0000-0000-0000-0000000000a2', '97000000-0000-0000-0000-0000000000c1', 'Специалист без Telegram', '97000000-0000-0000-0000-000000000022');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('97000000-0000-0000-0000-0000000000b1', '97000000-0000-0000-0000-0000000000c1', 'Логопед', 70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('97000000-0000-0000-0000-0000000000d1', '97000000-0000-0000-0000-0000000000c1', 'Плательщик 1', '+996700970001'),
  ('97000000-0000-0000-0000-0000000000d2', '97000000-0000-0000-0000-0000000000c1', 'Плательщик 2', '+996700970002'),
  ('97000000-0000-0000-0000-0000000000db', '97000000-0000-0000-0000-0000000000c2', 'Плательщик Б', '+996700970009');

insert into public.students (id, center_id, full_name, payer_id) values
  ('97000000-0000-0000-0000-0000000000e1', '97000000-0000-0000-0000-0000000000c1', 'Айбек', '97000000-0000-0000-0000-0000000000d1'),
  ('97000000-0000-0000-0000-0000000000e2', '97000000-0000-0000-0000-0000000000c1', 'Мира', '97000000-0000-0000-0000-0000000000d2'),
  ('97000000-0000-0000-0000-0000000000eb', '97000000-0000-0000-0000-0000000000c2', 'Ребёнок Б', '97000000-0000-0000-0000-0000000000db');

insert into public.memberships (user_id, center_id, role, payer_id, teacher_id) values
  ('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1', 'owner',   null, null),
  ('97000000-0000-0000-0000-000000000002', '97000000-0000-0000-0000-0000000000c2', 'owner',   null, null),
  ('97000000-0000-0000-0000-000000000011', '97000000-0000-0000-0000-0000000000c1', 'parent',  '97000000-0000-0000-0000-0000000000d1', null),
  ('97000000-0000-0000-0000-000000000012', '97000000-0000-0000-0000-0000000000c1', 'parent',  '97000000-0000-0000-0000-0000000000d2', null),
  ('97000000-0000-0000-0000-000000000013', '97000000-0000-0000-0000-0000000000c2', 'parent',  '97000000-0000-0000-0000-0000000000db', null),
  ('97000000-0000-0000-0000-000000000021', '97000000-0000-0000-0000-0000000000c1', 'teacher', null, '97000000-0000-0000-0000-0000000000a1'),
  ('97000000-0000-0000-0000-000000000022', '97000000-0000-0000-0000-0000000000c1', 'teacher', null, '97000000-0000-0000-0000-0000000000a2');

-- Telegram: родитель 1 и специалист с Telegram. Родитель 2 — без бота (whatsapp_link).
insert into public.telegram_accounts (user_id, chat_id) values
  ('97000000-0000-0000-0000-000000000011', 970011),
  ('97000000-0000-0000-0000-000000000021', 970021);

-- Занятия вторника 05.03.2030 и среды 06.03.2030 (местное время).
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('97000000-0000-0000-0000-000000000f01', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-0000000000e1', '97000000-0000-0000-0000-0000000000b1', 'planned',   '2030-03-05 20:00+06', '2030-03-05 20:45+06'),
  ('97000000-0000-0000-0000-000000000f02', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-0000000000e2', '97000000-0000-0000-0000-0000000000b1', 'planned',   '2030-03-05 10:00+06', '2030-03-05 10:45+06'),
  ('97000000-0000-0000-0000-000000000f03', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-0000000000e2', '97000000-0000-0000-0000-0000000000b1', 'planned',   '2030-03-06 10:00+06', '2030-03-06 10:45+06'),
  ('97000000-0000-0000-0000-000000000f04', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-0000000000e1', '97000000-0000-0000-0000-0000000000b1', 'cancelled', '2030-03-05 12:00+06', '2030-03-05 12:45+06'),
  ('97000000-0000-0000-0000-000000000f07', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000a2', '97000000-0000-0000-0000-0000000000e2', '97000000-0000-0000-0000-0000000000b1', 'planned',   '2030-03-05 14:00+06', '2030-03-05 14:45+06');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_ev (name text primary key, id bigint);
grant select, insert on t_ev to authenticated;

select public.tests_claims(null, null);


-- 1. Гранты и справочник --------------------------------------------------------------------------

select ok(
  not has_function_privilege(r, f, 'EXECUTE'),
  format('%s не исполняет %s', r, f))
from unnest(array['anon', 'authenticated', 'service_role', 'bot_worker']) r,
     unnest(array[
       'public.lesson_reminders_at(timestamptz)',
       'public.teacher_schedules_at(timestamptz)',
       'public.debt_reminders_at(timestamptz)',
       'public.period_subscription_reminders_at(timestamptz)',
       'public.debt_payers_center(uuid,uuid)',
       'public.center_notification_enabled(uuid,text)',
       'public.lesson_reminder_day(timestamptz,text,timestamptz)',
       'public.subscription_renewed(uuid)']) f;

select ok(
  has_function_privilege('bot_worker', 'public.notification_schedules()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.notification_schedules()', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.notification_schedules()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.notification_schedules()', 'EXECUTE'),
  'notification_schedules() — только воркер (Б2)');

select is_empty(
  $$ select c.oid::regclass::text || ' ' || a.grantee::regrole::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where c.oid in ('public.teacher_schedule_sent'::regclass, 'public.debt_reminder_runs'::regclass,
                      'public.subscription_period_reminders_sent'::regclass)
        and a.grantee <> c.relowner
        and not (a.grantee = 'authenticated'::regrole and a.privilege_type = 'SELECT') $$,
  'Отметки планировщиков: у authenticated только SELECT, у остальных ничего');

select set_eq(
  $$ select event_type || ':' || subject_required::text || ':' || array_to_string(channels, ',') || ':' || mandatory::text
       from public.notification_event_types
      where event_type in ('debt.reminder', 'subscription.period_ending', 'attendance.status_changed', 'teacher.schedule') $$,
  $$ values ('debt.reminder:true:telegram,whatsapp_link:false'),
            ('subscription.period_ending:true:telegram,whatsapp_link:false'),
            ('attendance.status_changed:true:telegram,whatsapp_link:false'),
            ('teacher.schedule:false:telegram:false') $$,
  'Новые типы: subject, каналы, необязательные');

select is(
  (select text from public.message_templates
    where center_id is null and event_type = 'lesson.reminder' and channel = 'telegram' and deleted_at is null),
  'Напоминаем: {day} в {time} занятие у {child}. Специалист — {teacher}. Если планы изменились, сообщите нам.',
  'Дефолт напоминания говорит {day}, а не «завтра» (В1)');

select is(
  (select count(*)::int from public.attendance_statuses
    where center_id = '97000000-0000-0000-0000-0000000000c1' and notify_parent),
  0, 'Новому центру галочка «Уведомлять родителя» не ставится (В4)');

select ok(
  exists (select 1 from public.readonly_guard_exempt_tables() x where x.table_name = 'debt_reminder_runs')
  and exists (select 1 from public.export_center_excluded_tables() x where x.table_name = 'teacher_schedule_sent'),
  'Отметки — в заборах readonly guard и выгрузки (Б4)');

-- Канал шаблона — из справочника (п.11).
select public.tests_claims('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.upsert_message_template('teacher.schedule', 'whatsapp_link', 'x', true) $$,
  '22023', null, 'Шаблон расписания специалисту в whatsapp_link не заводится');
select lives_ok(
  $$ select public.upsert_message_template('teacher.schedule', 'telegram', 'Завтра {date}: {lesson_list}', true) $$,
  'В telegram — заводится');
select throws_ok(
  $$ select public.lesson_reminders_at(now()) $$,
  '42501', null, 'Пользователь планировщик со своим временем не зовёт');
reset role;
select public.tests_claims(null, null);
-- Возвращаем дефолт: дальше тест читает текст по умолчанию.
update public.message_templates set deleted_at = now()
 where center_id = '97000000-0000-0000-0000-0000000000c1' and event_type = 'teacher.schedule';


-- 2. Слово дня {day} (Б1) -------------------------------------------------------------------------

select is(public.lesson_reminder_day('2030-03-05 20:00+06', 'Asia/Bishkek', '2030-03-04 18:10+06'), 'завтра', '{day}: накануне — «завтра»');
select is(public.lesson_reminder_day('2030-03-05 20:00+06', 'Asia/Bishkek', '2030-03-05 08:10+06'), 'сегодня', '{day}: утром того же дня — «сегодня»');
select is(public.lesson_reminder_day('2030-03-05 20:00+06', 'Asia/Bishkek', '2030-03-03 18:10+06'), '05.03', '{day}: раньше — дата');
select is(public.lesson_reminder_day('2030-03-05 00:30+06', 'Asia/Bishkek', '2030-03-04 18:10+06'), 'завтра',
  '{day}: 00:30 по Бишкеку — это 18:30 UTC предыдущего дня, но «завтра» считается в поясе центра');


-- 3. Расписание специалисту (В5) — до напоминаний, на тех же занятиях --------------------------

select is(public.teacher_schedules_at('2030-03-04 17:00+06'), 0, 'Расписание: в 17:00 — рано');
select is(public.teacher_schedules_at('2030-03-04 18:20+06'), 1,
  'Расписание: в 18:20 — одному специалисту; второй без Telegram события не получает (п.14)');
select is(public.teacher_schedules_at('2030-03-04 19:20+06'), 0, 'Расписание: повтор в тот же вечер — ноль');

insert into t_ev select 'schedule', max(id) from public.events where type = 'teacher.schedule';

select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'schedule'))),
  1, 'Расписание — одно сообщение специалисту');
select is(
  (select channel || '|' || message from public.event_messages((select id from t_ev where name = 'schedule'))),
  'telegram|Завтра, 05.03.2030, в «Центр А 0097» у вас 2 занятия:' || chr(10) || '10:00 — Мира' || chr(10) || '20:00 — Айбек',
  'Расписание: только telegram, отменённое не в списке, время в поясе центра, по порядку');

-- Отменили после выпуска события — список на момент доставки.
update public.lessons set status = 'cancelled' where id = '97000000-0000-0000-0000-000000000f02';
select ok(
  (select message like '%у вас 1 занятие:%' and message not like '%Мира%'
     from public.event_messages((select id from t_ev where name = 'schedule'))),
  'Расписание собирается при доставке: отменённое после события — не в списке');
update public.lessons set status = 'planned' where id = '97000000-0000-0000-0000-000000000f02';

-- Чужой teacher_id в событии своего центра (п.12).
with ins as (
  insert into public.events (center_id, type, payload)
  values ('97000000-0000-0000-0000-0000000000c2', 'teacher.schedule',
          jsonb_build_object('teacher_id', '97000000-0000-0000-0000-0000000000a1', 'date', '2030-03-05'))
  returning id)
insert into t_ev select 'schedule_foreign', id from ins;
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'schedule_foreign'))),
  0, 'Расписание по специалисту чужого центра — пусто');


-- 4. Напоминание о занятии (В1, п.9) ---------------------------------------------------------------

select is(public.lesson_reminders_at('2030-03-04 17:30+06'), 0, 'Напоминание: в 17:30 накануне — рано');
select is(public.lesson_reminders_at('2030-03-04 18:10+06'), 3,
  'Напоминание: в 18:10 — три завтрашних planned-занятия; отменённое и послезавтрашнее — нет');
select is(public.lesson_reminders_at('2030-03-04 19:10+06'), 0, 'Повтор в тот же вечер — ноль');

-- Ночью ничего; поставленное поздно — утром, если до начала больше часа.
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('97000000-0000-0000-0000-000000000f05', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-0000000000e2', '97000000-0000-0000-0000-0000000000b1', 'planned', '2030-03-05 15:00+06', '2030-03-05 15:45+06'),
  ('97000000-0000-0000-0000-000000000f06', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-0000000000e1', '97000000-0000-0000-0000-0000000000b1', 'planned', '2030-03-05 08:50+06', '2030-03-05 09:20+06');

select is(public.lesson_reminders_at('2030-03-04 22:00+06'), 0, 'В 22:00 — ничего, даже поставленное только что');
select is(public.lesson_reminders_at('2030-03-05 02:00+06'), 0, 'В 02:00 — ничего (было: «завтра в 20:00» ночью того же дня)');
select is(public.lesson_reminders_at('2030-03-05 08:10+06'), 1,
  'В 08:10 — занятие в 15:00 («сегодня»); в 08:50 — нет, до начала меньше часа');

-- Перенос после напоминания: старое событие молчит, новое время — новое напоминание.
insert into t_ev select 'reminder_old', e.id from public.events e
 where e.type = 'lesson.reminder' and e.payload ->> 'lesson_id' = '97000000-0000-0000-0000-000000000f01';

update public.lessons
   set starts_at = '2030-03-07 20:00+06', ends_at = '2030-03-07 20:45+06'
 where id = '97000000-0000-0000-0000-000000000f01';

select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'reminder_old'))),
  0, 'Напоминание о старом времени после переноса — пусто');
select is(public.lesson_reminders_at('2030-03-06 18:10+06'), 1, 'Новое время — новое напоминание');
select is(
  (select count(*)::int from public.lesson_reminders_sent where lesson_id = '97000000-0000-0000-0000-000000000f01'),
  2, 'Две отметки: по старому и по новому времени');

insert into t_ev select 'reminder_new', max(e.id) from public.events e
 where e.type = 'lesson.reminder' and e.payload ->> 'lesson_id' = '97000000-0000-0000-0000-000000000f01';
select ok(
  (select message like '%20:00%' and action ->> 'callback_data' like 'c:%'
     from public.event_messages((select id from t_ev where name = 'reminder_new'))
    where recipient_user_id = '97000000-0000-0000-0000-000000000011'),
  'Новое напоминание доставляется родителю с кнопкой подтверждения');


-- 5. Долг раз в неделю (В2) ------------------------------------------------------------------------

-- Долг Айбека: отметка без абонемента на прошедшем занятии — руками владельца.
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('97000000-0000-0000-0000-000000000f10', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-0000000000e1', '97000000-0000-0000-0000-0000000000b1', 'planned', now() - interval '2 days', now() - interval '2 days' + interval '45 minutes');

select public.tests_claims('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.mark_attendance('97000000-0000-0000-0000-000000000f10', '97000000-0000-0000-0000-0000000000e1');
reset role;
select public.tests_claims(null, null);

select is(public.debt_reminders_at('2030-03-04 09:30+06'), 0, 'Долг: понедельник 09:30 — рано');
select is(public.debt_reminders_at('2030-03-04 10:05+06'), 1, 'Долг: понедельник 10:05 — одно событие, плательщику с долгом');
select is(public.debt_reminders_at('2030-03-04 11:05+06'), 0, 'Долг: повтор в понедельник — ноль');
select is(public.debt_reminders_at('2030-03-06 12:00+06'), 0, 'Долг: среда той же недели — ноль (неделя отмечена)');
select is(
  (select payload ->> 'payer_id' from public.events where type = 'debt.reminder' order by id desc limit 1),
  '97000000-0000-0000-0000-0000000000d1', 'Событие — по плательщику Айбека');
select is(
  (select count(*)::int from public.debt_reminder_runs), 2,
  'Отметка недели — на каждый центр, и у центра без должников тоже (п.7)');

insert into t_ev select 'debt', max(id) from public.events where type = 'debt.reminder';
select is(
  (select recipient_user_id::text || '|' || channel || '|' || subject_id::text from public.event_messages((select id from t_ev where name = 'debt'))),
  '97000000-0000-0000-0000-000000000011|telegram|97000000-0000-0000-0000-0000000000e1',
  'Долг доставляется родителю плательщика, по ребёнку');
select ok(
  (select message like '%Айбек%' and message like '%долг за занятия — %' and message not like '%просрочка%'
     from public.event_messages((select id from t_ev where name = 'debt'))),
  'Текст: ребёнок и долг за занятия; просрочки нет — не упоминается');

select is(
  (select current_setting('request.jwt.claims', true)::jsonb ->> 'sub'), null,
  'После подмены claims возвращены (sub пуст)');

-- Помощник подмены под сессией отказывает, даже если ему по ошибке выдадут грант (п.5).
grant execute on function public.debt_payers_center(uuid, uuid) to authenticated;
select public.tests_claims('97000000-0000-0000-0000-000000000011', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select * from public.debt_payers_center('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1') $$,
  '42501', null, 'debt_payers_center под сессией — отказ: держит guard, а не только отсутствие гранта');
reset role;
revoke execute on function public.debt_payers_center(uuid, uuid) from authenticated;
select public.tests_claims(null, null);

-- Чужой плательщик в событии своего центра (п.12).
with ins as (
  insert into public.events (center_id, type, payload)
  values ('97000000-0000-0000-0000-0000000000c1', 'debt.reminder',
          jsonb_build_object('payer_id', '97000000-0000-0000-0000-0000000000db'))
  returning id)
insert into t_ev select 'debt_foreign', id from ins;
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'debt_foreign'))),
  0, 'Долг по плательщику чужого центра — пусто');

-- Следующая неделя: тип выключен центром — неделя отмечается, событий нет (п.14).
insert into public.message_templates (center_id, event_type, channel, text, is_active) values
  ('97000000-0000-0000-0000-0000000000c1', 'debt.reminder', 'telegram', 'выкл', false),
  ('97000000-0000-0000-0000-0000000000c1', 'debt.reminder', 'whatsapp_link', 'выкл', false);
select is(public.debt_reminders_at('2030-03-11 10:05+06'), 0, 'Долг: тип выключен центром — событий нет');
select is(
  (select count(*)::int from public.events e where e.type = 'debt.reminder'
     and e.payload ->> 'week_start' = '2030-03-11'), 0, 'И событий за неделю нет');
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'debt'))),
  0, 'Выключенный шаблон и при доставке не даёт получателя');
update public.message_templates set deleted_at = now()
 where center_id = '97000000-0000-0000-0000-0000000000c1' and event_type = 'debt.reminder';


-- 6. Абонемент на срок (В3, п.8) -------------------------------------------------------------------

insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, starts_at, ends_at, created_at) values
  ('97000000-0000-0000-0000-0000000005a1', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000e2',
   '97000000-0000-0000-0000-0000000000d2', null, 0, '2030-02-06', '2030-03-06', now() - interval '1 day');

select is(public.period_subscription_reminders_at('2030-03-02 10:30+06'), 0, 'Срок: за 4 дня — рано');
select is(public.period_subscription_reminders_at('2030-03-03 09:30+06'), 0, 'Срок: за 3 дня, но 09:30 — рано');
select is(public.period_subscription_reminders_at('2030-03-03 10:30+06'), 1, 'Срок: за 3 дня в 10:30 — напоминание');
select is(public.period_subscription_reminders_at('2030-03-04 10:30+06'), 0, 'Срок: на следующий день — не повторяется');

insert into t_ev select 'period', max(id) from public.events where type = 'subscription.period_ending';
select is(
  (select recipient_user_id::text || '|' || channel from public.event_messages((select id from t_ev where name = 'period'))),
  '97000000-0000-0000-0000-000000000012|whatsapp_link',
  'Срок: родителю текущего плательщика; без бота — whatsapp_link');
select ok(
  (select message like '%Мира%' and message like '%06.03.2030%'
     from public.event_messages((select id from t_ev where name = 'period'))),
  'Срок: ребёнок и дата окончания');

-- Продлили — доставка молчит.
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, starts_at, ends_at) values
  ('97000000-0000-0000-0000-0000000005a2', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000e2',
   '97000000-0000-0000-0000-0000000000d2', null, 0, '2030-03-07', '2030-04-06');
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'period'))),
  0, 'Срок: абонемент продлён — сообщение не уходит');
select ok(public.subscription_renewed('97000000-0000-0000-0000-0000000005a1'), 'subscription_renewed видит продление');
select ok(not public.subscription_renewed('97000000-0000-0000-0000-0000000005a2'), 'Новый абонемент сам продлённым не считается');
select ok(
  not exists (select 1 from public.debt_reminder_runs where week_start < '2030-01-01'
                and center_id in ('97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000c2')),
  'Засев текущей недели касается только центров, живших до миграции');

-- У продлённого абонемента — свой срок и своё напоминание.
select is(public.period_subscription_reminders_at('2030-04-03 10:30+06'), 1,
  'Срок второго абонемента — своё напоминание');
update public.subscriptions set status = 'cancelled'
 where id = '97000000-0000-0000-0000-0000000005a2';
insert into t_ev select 'period2', max(id) from public.events where type = 'subscription.period_ending';
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'period2'))),
  0, 'Срок: отменённый абонемент — пусто при доставке');


-- 7. Отметка со статусом «Уведомлять родителя» (В4, Б3) --------------------------------------------

update public.attendance_statuses set notify_parent = true
 where center_id = '97000000-0000-0000-0000-0000000000c1' and code = 'absent';

insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('97000000-0000-0000-0000-000000000f20', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-0000000000e2', '97000000-0000-0000-0000-0000000000b1', 'planned', now() - interval '1 hour', now() - interval '15 minutes'),
  ('97000000-0000-0000-0000-000000000f21', '97000000-0000-0000-0000-0000000000c1', '97000000-0000-0000-0000-0000000000a1', '97000000-0000-0000-0000-0000000000e2', '97000000-0000-0000-0000-0000000000b1', 'planned', now() - interval '5 days', now() - interval '5 days' + interval '45 minutes');

select public.tests_claims('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.mark_attendance('97000000-0000-0000-0000-000000000f20', '97000000-0000-0000-0000-0000000000e2', 'present');
reset role;
select public.tests_claims(null, null);
select is(
  (select count(*)::int from public.events where type = 'attendance.status_changed'), 0,
  'Статус без галочки — события нет');

select public.tests_claims('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.mark_attendance('97000000-0000-0000-0000-000000000f20', '97000000-0000-0000-0000-0000000000e2', 'absent');
reset role;
select public.tests_claims(null, null);
insert into t_ev select 'absent1', max(id) from public.events where type = 'attendance.status_changed';

select is(
  (select payload ->> 'status_id' from public.events where id = (select id from t_ev where name = 'absent1')),
  (select id::text from public.attendance_statuses where center_id = '97000000-0000-0000-0000-0000000000c1' and code = 'absent'),
  'Смена на статус с галочкой — событие со status_id');
select ok(
  (select recipient_user_id = '97000000-0000-0000-0000-000000000012' and message like '%Мира%' and message like '%«Прогул»%'
     from public.event_messages((select id from t_ev where name = 'absent1'))),
  'Родителю — ребёнок и название статуса');

-- Исправили на статус без галочки — первое событие перекрыто.
select public.tests_claims('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.mark_attendance('97000000-0000-0000-0000-000000000f20', '97000000-0000-0000-0000-0000000000e2', 'sick');
reset role;
select public.tests_claims(null, null);
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'absent1'))),
  0, 'Статус сменили после события — по старому событию пусто');

-- Первое сообщение «ушло»: у родителя без бота n8n закрывает строку как
-- no_channel (ссылка в журнале). Потом статус вернули — повтор не уходит.
insert into public.notification_log (center_id, event_id, recipient_user_id, channel, status, subject_id)
values ('97000000-0000-0000-0000-0000000000c1', (select id from t_ev where name = 'absent1'),
        '97000000-0000-0000-0000-000000000012', 'whatsapp_link', 'no_channel', '97000000-0000-0000-0000-0000000000e2');

select public.tests_claims('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.mark_attendance('97000000-0000-0000-0000-000000000f20', '97000000-0000-0000-0000-0000000000e2', 'absent');
reset role;
select public.tests_claims(null, null);
insert into t_ev select 'absent2', max(id) from public.events where type = 'attendance.status_changed';
select isnt((select id from t_ev where name = 'absent2'), (select id from t_ev where name = 'absent1'),
  'Возврат статуса — новое событие');
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'absent2'))),
  0, 'Тот же статус тому же получателю уже уходил — повтора нет');

-- Занятие пятидневной давности — пусто.
select public.tests_claims('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.mark_attendance('97000000-0000-0000-0000-000000000f21', '97000000-0000-0000-0000-0000000000e2', 'absent');
reset role;
select public.tests_claims(null, null);
insert into t_ev select 'absent_old', max(id) from public.events where type = 'attendance.status_changed';
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'absent_old'))),
  0, 'Отметка задним числом (занятие старше 3 суток) — пусто');

-- Событие старше 12 часов — пусто (очередь после простоя).
update public.events set created_at = now() - interval '13 hours'
 where id = (select id from t_ev where name = 'absent2');
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'absent2'))),
  0, 'Событие старше 12 часов — пусто');

-- attendance_id чужого центра (п.12).
with ins as (
  insert into public.events (center_id, type, payload)
  values ('97000000-0000-0000-0000-0000000000c2', 'attendance.status_changed',
          (select payload from public.events where id = (select id from t_ev where name = 'absent1')))
  returning id)
insert into t_ev select 'absent_foreign', id from ins;
select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'absent_foreign'))),
  0, 'Отметка чужого центра — пусто');


-- 8. Вход воркера -----------------------------------------------------------------------------------

select public.tests_claims('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select * from public.notification_schedules() $$, '42501', null,
  'Пользователь notification_schedules не запускает');
reset role;
select public.tests_claims(null, null);
select lives_ok($$ select * from public.notification_schedules() $$,
  'Без сессии notification_schedules исполняется (результат зависит от часа — не проверяется)');


-- 9. Отметки читает только администрация своего центра --------------------------------------------

select public.tests_claims('97000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select ok((select count(*) from public.debt_reminder_runs) >= 1, 'Владелец видит отметки своего центра');
select is(
  (select count(*)::int from public.debt_reminder_runs where center_id <> '97000000-0000-0000-0000-0000000000c1'),
  0, 'Чужих — не видит');
select throws_ok(
  $$ insert into public.debt_reminder_runs (center_id, week_start) values ('97000000-0000-0000-0000-0000000000c1', '2031-01-06') $$,
  '42501', null, 'Записать отметку недели нельзя — иначе рассылка молча не уйдёт');
reset role;

select public.tests_claims('97000000-0000-0000-0000-000000000011', '97000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.teacher_schedule_sent), 0, 'Родитель отметок не видит');
reset role;
select public.tests_claims(null, null);

select * from finish();
rollback;
