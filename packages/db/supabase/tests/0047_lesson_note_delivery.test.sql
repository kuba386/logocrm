-- pgTAP: резюме занятия родителю и отказ диктовки специалисту (0047).
--
-- Главное — границы: {summary} не выходит из канала telegram даже если
-- центр допишет его в шаблон whatsapp_link (Р1); отказ диктовки не
-- доходит до уволенного (Р2); утвердить пустое резюме нельзя ни через RPC,
-- ни прямым update (Р3); сырая причина отказа в чат не попадает (Р6).
--
-- event_messages не проверяет claimed_at — событие достаточно создать.
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(46);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0470000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0047@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0470000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-0047@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0470000-0000-0000-0000-000000000003','authenticated','authenticated','parent1-0047@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0470000-0000-0000-0000-000000000004','authenticated','authenticated','parent2-0047@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0470000-0000-0000-0000-000000000005','authenticated','authenticated','owner-b-0047@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0470000-0000-0000-0000-000000000006','authenticated','authenticated','parent-b-0047@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0470000-0000-0000-0000-000000000007','authenticated','authenticated','fired-0047@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0470000-0000-0000-0000-0000000000c1','Центр А 0047','centr-a-0047','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0470000-0000-0000-0000-0000000000c2','Центр Б 0047','centr-b-0047','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-0000000000c1','Специалист А','a0470000-0000-0000-0000-000000000002'),
  ('a0470000-0000-0000-0000-000000000011','a0470000-0000-0000-0000-0000000000c2','Специалист Б',null);

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('a0470000-0000-0000-0000-000000000020','a0470000-0000-0000-0000-0000000000c1','Логопед',70000),
  ('a0470000-0000-0000-0000-000000000021','a0470000-0000-0000-0000-0000000000c2','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('a0470000-0000-0000-0000-000000000030','a0470000-0000-0000-0000-0000000000c1','Плательщик 1','+996700004701'),
  ('a0470000-0000-0000-0000-000000000031','a0470000-0000-0000-0000-0000000000c1','Плательщик 2','+996700004702'),
  ('a0470000-0000-0000-0000-000000000032','a0470000-0000-0000-0000-0000000000c2','Плательщик Б','+996700004703');

-- «Уволенный» (…07) членства не имеет вовсе — только привязку Telegram.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0470000-0000-0000-0000-000000000001','a0470000-0000-0000-0000-0000000000c1','owner',  null, null),
  ('a0470000-0000-0000-0000-000000000002','a0470000-0000-0000-0000-0000000000c1','teacher','a0470000-0000-0000-0000-000000000010', null),
  ('a0470000-0000-0000-0000-000000000003','a0470000-0000-0000-0000-0000000000c1','parent', null, 'a0470000-0000-0000-0000-000000000030'),
  ('a0470000-0000-0000-0000-000000000004','a0470000-0000-0000-0000-0000000000c1','parent', null, 'a0470000-0000-0000-0000-000000000031'),
  ('a0470000-0000-0000-0000-000000000005','a0470000-0000-0000-0000-0000000000c2','owner',  null, null),
  ('a0470000-0000-0000-0000-000000000006','a0470000-0000-0000-0000-0000000000c2','parent', null, 'a0470000-0000-0000-0000-000000000032');

insert into public.telegram_accounts (user_id, chat_id) values
  ('a0470000-0000-0000-0000-000000000002', 780471),
  ('a0470000-0000-0000-0000-000000000003', 780472),
  ('a0470000-0000-0000-0000-000000000004', 780473),
  ('a0470000-0000-0000-0000-000000000006', 780474),
  ('a0470000-0000-0000-0000-000000000007', 780475);

insert into public.students (id, center_id, full_name, payer_id) values
  ('a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-0000000000c1','Ребёнок КАНАРЕЙКА-ИМЯ','a0470000-0000-0000-0000-000000000030'),
  ('a0470000-0000-0000-0000-000000000041','a0470000-0000-0000-0000-0000000000c1','Ребёнок второй','a0470000-0000-0000-0000-000000000031'),
  ('a0470000-0000-0000-0000-000000000042','a0470000-0000-0000-0000-0000000000c2','Ребёнок Б','a0470000-0000-0000-0000-000000000032');

-- Слоты не пересекаются: EXCLUDE по effective_teacher_id. Занятие 50 —
-- в фиксированную дату на границе суток: 20:30 UTC это уже следующий день
-- в поясе центра, дата в сообщении обязана быть датой центра.
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('a0470000-0000-0000-0000-000000000050','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-000000000020','done','2026-09-01 20:30:00+00','2026-09-01 21:15:00+00'),
  ('a0470000-0000-0000-0000-000000000051','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-000000000020','done', now() - interval '1 hour',  now() - interval '15 minutes'),
  ('a0470000-0000-0000-0000-000000000052','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-000000000020','done', now() - interval '2 hours', now() - interval '1 hour 15 minutes'),
  ('a0470000-0000-0000-0000-000000000053','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-000000000020','done', now() - interval '3 hours', now() - interval '2 hours 15 minutes'),
  ('a0470000-0000-0000-0000-000000000054','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-000000000020','done', now() - interval '4 hours', now() - interval '3 hours 15 minutes'),
  ('a0470000-0000-0000-0000-000000000055','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-000000000020','done', now() - interval '5 hours', now() - interval '4 hours 15 minutes'),
  ('a0470000-0000-0000-0000-000000000056','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-000000000020','done', now() - interval '6 hours', now() - interval '5 hours 15 minutes'),
  ('a0470000-0000-0000-0000-000000000057','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000041','a0470000-0000-0000-0000-000000000020','planned', now() + interval '1 day', now() + interval '1 day' + interval '45 minutes'),
  ('a0470000-0000-0000-0000-000000000058','a0470000-0000-0000-0000-0000000000c2','a0470000-0000-0000-0000-000000000011','a0470000-0000-0000-0000-000000000042','a0470000-0000-0000-0000-000000000021','done', now() - interval '1 hour',  now() - interval '15 minutes');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

select public.tests_claims('a0470000-0000-0000-0000-000000000001','a0470000-0000-0000-0000-0000000000c1');

-- Заметки: 60 — основной сценарий; 61 — занятие потом отменят; 62 — без
-- резюме; 63 — черновик, который «утвердят» подложенным событием; 64 —
-- живая заметка, из-за которой отказ диктовки по занятию 53 не шлётся;
-- 65 — длинное резюме.
insert into public.lesson_notes (id, center_id, lesson_id, student_id, status, created_by, parent_summary) values
  ('a0470000-0000-0000-0000-000000000060','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000050','a0470000-0000-0000-0000-000000000040','draft','a0470000-0000-0000-0000-000000000002','КАНАРЕЙКА-РЕЗЮМЕ для родителя.'),
  ('a0470000-0000-0000-0000-000000000061','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000051','a0470000-0000-0000-0000-000000000040','draft','a0470000-0000-0000-0000-000000000002','Резюме по занятию, которое отменят.'),
  ('a0470000-0000-0000-0000-000000000062','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000055','a0470000-0000-0000-0000-000000000040','draft','a0470000-0000-0000-0000-000000000002', null),
  ('a0470000-0000-0000-0000-000000000063','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000056','a0470000-0000-0000-0000-000000000040','draft','a0470000-0000-0000-0000-000000000002','Черновик, не утверждён.'),
  ('a0470000-0000-0000-0000-000000000064','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000053','a0470000-0000-0000-0000-000000000040','draft','a0470000-0000-0000-0000-000000000002','Уже надиктовано заново.'),
  ('a0470000-0000-0000-0000-000000000065','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000054','a0470000-0000-0000-0000-000000000040','draft','a0470000-0000-0000-0000-000000000002', repeat('ы', 4000));

-- Запросы диктовки: 70 — упавшая, заметки нет; 71 — упавшая, но по
-- занятию уже есть заметка 64; 72 — заказчик уволен.
insert into public.lesson_voice_requests (id, token, center_id, lesson_id, student_id, teacher_id, requested_by, chat_id, expires_at, armed_at, consumed_at) values
  ('a0470000-0000-0000-0000-000000000070','t047-1','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000052','a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000002',780471, now() + interval '15 minutes', now() - interval '3 minutes', now() - interval '2 minutes'),
  ('a0470000-0000-0000-0000-000000000071','t047-2','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000053','a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000002',780471, now() + interval '15 minutes', now() - interval '3 minutes', now() - interval '2 minutes'),
  ('a0470000-0000-0000-0000-000000000072','t047-3','a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000052','a0470000-0000-0000-0000-000000000040','a0470000-0000-0000-0000-000000000010','a0470000-0000-0000-0000-000000000007',780475, now() + interval '15 minutes', now() - interval '3 minutes', now() - interval '2 minutes');

-- Все накопленные события до этого места — не наши.
update public.events set processed_at = now() where processed_at is null;


-- 1. Типы и шаблоны заведены, повтор не дублирует ---------------------------------------------------

select is(
  (select count(*)::int from public.notification_event_types
    where event_type in ('lesson.note_approved','lesson.voice_failed')),
  2, 'Оба типа в справочнике');

select is(
  (select count(*)::int from public.message_templates
    where center_id is null and event_type in ('lesson.note_approved','lesson.voice_failed') and deleted_at is null),
  4, 'Четыре шаблона по умолчанию: два типа × два канала');

insert into public.message_templates (center_id, event_type, channel, text)
select null::uuid, 'lesson.note_approved', 'telegram', 'повтор'
 where not exists (
   select 1 from public.message_templates m
    where m.center_id is null and m.event_type = 'lesson.note_approved' and m.channel = 'telegram' and m.deleted_at is null
 );
select is(
  (select count(*)::int from public.message_templates
    where center_id is null and event_type = 'lesson.note_approved' and channel = 'telegram' and deleted_at is null),
  1, 'Повторный прогон вставки ничего не дублирует (where not exists)');


-- 2. Утверждение: событие ровно одно, без резюме — отказ (Р3) ---------------------------------------

set local role authenticated;
select lives_ok(
  $q$ select public.approve_lesson_note('a0470000-0000-0000-0000-000000000060') $q$,
  'Владелец утверждает заметку с резюме');
select lives_ok(
  $q$ select public.approve_lesson_note('a0470000-0000-0000-0000-000000000060') $q$,
  'Повторное утверждение — холостой ход');
select lives_ok(
  $q$ select public.approve_lesson_note('a0470000-0000-0000-0000-000000000061') $q$,
  'Утверждена и заметка по занятию, которое отменят');
select lives_ok(
  $q$ select public.approve_lesson_note('a0470000-0000-0000-0000-000000000065') $q$,
  'Утверждена заметка с длинным резюме');

select throws_ok(
  $q$ select public.approve_lesson_note('a0470000-0000-0000-0000-000000000062') $q$,
  '23514', null,
  'Без резюме для родителя утверждать нечего — отказ через RPC (Р3)');
reset role;

-- Второй рубеж: от postgres, в обход RPC — триггер, а не проверка функции.
select throws_ok(
  $q$ update public.lesson_notes set status = 'approved' where id = 'a0470000-0000-0000-0000-000000000062' $q$,
  '23514', null,
  'Прямой update status=approved без резюме — тот же отказ, держит триггер');

select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.events
    where type = 'lesson.note_approved' and payload ->> 'lesson_note_id' = 'a0470000-0000-0000-0000-000000000060'),
  1, 'Событие по заметке 60 ровно одно — повтор не эмитит второе');

select id as e_note60 from public.events
 where type = 'lesson.note_approved' and payload ->> 'lesson_note_id' = 'a0470000-0000-0000-0000-000000000060' \gset
select id as e_note61 from public.events
 where type = 'lesson.note_approved' and payload ->> 'lesson_note_id' = 'a0470000-0000-0000-0000-000000000061' \gset
select id as e_note65 from public.events
 where type = 'lesson.note_approved' and payload ->> 'lesson_note_id' = 'a0470000-0000-0000-0000-000000000065' \gset


-- 3. Доставка резюме родителю ---------------------------------------------------------------------------

select is(
  (select count(*)::int from public.event_messages(:'e_note60')),
  1, 'Ровно один получатель');

select is(
  (select recipient_user_id from public.event_messages(:'e_note60')),
  'a0470000-0000-0000-0000-000000000003'::uuid,
  'И это родитель-плательщик ребёнка — не второй родитель, не центр Б');

select is(
  (select channel from public.event_messages(:'e_note60')),
  'telegram', 'Канал — telegram при живой привязке');

select ok(
  (select message from public.event_messages(:'e_note60')) like '%КАНАРЕЙКА-РЕЗЮМЕ%',
  'Текст содержит само резюме');

select ok(
  (select message from public.event_messages(:'e_note60')) like '%02.09.2026%',
  'Дата — день занятия в поясе центра (20:30 UTC 1 сентября = 2 сентября в Бишкеке)');

select is(
  (select subject_id from public.event_messages(:'e_note60')),
  'a0470000-0000-0000-0000-000000000040'::uuid,
  'subject_id = ребёнок — иначе notification_log не примет строку (Р8)');

select ok(
  (select public.notification_begin(:'e_note60', 'a0470000-0000-0000-0000-000000000003', 'telegram',
     'a0470000-0000-0000-0000-000000000040')) is not null,
  'notification_begin с subject_id принимает строку');

select throws_ok(
  format($q$ select public.notification_begin(%s, 'a0470000-0000-0000-0000-000000000004', 'telegram', null) $q$, :'e_note60'),
  '22023', null,
  'А без subject_id — отказ триггера обязательности (0035)');

-- Длина: резюме на 4000 символов не уходит в Telegram как есть.
select ok(
  (select length(message) from public.event_messages(:'e_note65')) < 3700,
  'Длинное резюме обрезано до границы (Р5)');
select ok(
  (select message from public.event_messages(:'e_note65')) like '%…%',
  'И обрезка помечена многоточием, а не оборвана молча');

-- Подложенное событие по черновику: доставки нет.
insert into public.events (center_id, type, payload) values
  ('a0470000-0000-0000-0000-0000000000c1', 'lesson.note_approved',
   jsonb_build_object('center_id','a0470000-0000-0000-0000-0000000000c1',
     'lesson_note_id','a0470000-0000-0000-0000-000000000063',
     'student_id','a0470000-0000-0000-0000-000000000040',
     'lesson_id','a0470000-0000-0000-0000-000000000056'));
select is(
  (select count(*)::int from public.event_messages(
     (select max(id) from public.events where payload ->> 'lesson_note_id' = 'a0470000-0000-0000-0000-000000000063'))),
  0, 'Черновик (status=draft) не рассылается, даже если событие подложили');

-- Занятие отменили после утверждения — доставка отстала и молчит (Р4).
update public.lessons set status = 'cancelled' where id = 'a0470000-0000-0000-0000-000000000051';
select is(
  (select count(*)::int from public.event_messages(:'e_note61')),
  0, 'Отменённое занятие — ноль сообщений, как и у student_notes_brief');

-- Выключенный шаблон центра — тишина, а не подмена дефолтом.
select public.tests_claims('a0470000-0000-0000-0000-000000000001','a0470000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.upsert_message_template('lesson.note_approved', 'telegram', 'выкл', false) $q$,
  'Владелец выключает telegram-шаблон резюме');
select lives_ok(
  $q$ select public.upsert_message_template('lesson.note_approved', 'whatsapp_link', 'WA {child} {date} {summary}', true) $q$,
  'И дописывает {summary} в whatsapp_link — интерфейс этого не предлагает, но поле свободное');
reset role;
select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.event_messages(:'e_note60')),
  0, 'Выключенный шаблон — ноль получателей (resolve_template.should_send)');

-- Канареечный (Р1): родитель без Telegram, канал whatsapp_link, в шаблоне
-- центра стоит {summary} — а резюме в тексте всё равно нет.
update public.telegram_accounts set unlinked_at = now() where user_id = 'a0470000-0000-0000-0000-000000000003';

select is(
  (select channel from public.event_messages(:'e_note60')),
  'whatsapp_link', 'Без привязки канал — whatsapp_link');
select ok(
  (select message from public.event_messages(:'e_note60')) not like '%КАНАРЕЙКА-РЕЗЮМЕ%',
  '{summary} в whatsapp_link не подставляется, даже если центр его дописал (Р1)');
select ok(
  (select message from public.event_messages(:'e_note60')) like '%КАНАРЕЙКА-ИМЯ%',
  'А {child} и {date} в этот канал по-прежнему идут');

-- Архив заметки — доставки больше нет.
select public.tests_claims('a0470000-0000-0000-0000-000000000001','a0470000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.archive_lesson_note('a0470000-0000-0000-0000-000000000060') $q$,
  'Владелец архивирует утверждённую заметку');
reset role;
select public.tests_claims(null, null);
select is(
  (select count(*)::int from public.event_messages(:'e_note60')),
  0, 'Архивная заметка не рассылается (Р4)');


-- 4. Отказ диктовки — специалисту ----------------------------------------------------------------------

insert into public.events (center_id, type, payload) values
  ('a0470000-0000-0000-0000-0000000000c1', 'lesson.voice_failed',
   jsonb_build_object('center_id','a0470000-0000-0000-0000-0000000000c1',
     'voice_request_id','a0470000-0000-0000-0000-000000000070',
     'reason','invalid input syntax for type uuid: "sound_R"')),
  ('a0470000-0000-0000-0000-0000000000c1', 'lesson.voice_failed',
   jsonb_build_object('center_id','a0470000-0000-0000-0000-0000000000c1',
     'voice_request_id','a0470000-0000-0000-0000-000000000071',
     'reason','timeout')),
  ('a0470000-0000-0000-0000-0000000000c1', 'lesson.voice_failed',
   jsonb_build_object('center_id','a0470000-0000-0000-0000-0000000000c1',
     'voice_request_id','a0470000-0000-0000-0000-000000000072',
     'reason','timeout')),
  ('a0470000-0000-0000-0000-0000000000c2', 'lesson.voice_failed',
   jsonb_build_object('center_id','a0470000-0000-0000-0000-0000000000c2',
     'voice_request_id','a0470000-0000-0000-0000-000000000070',
     'reason','подложенный центр')),
  ('a0470000-0000-0000-0000-0000000000c1', 'lesson.voice_failed',
   jsonb_build_object('center_id','a0470000-0000-0000-0000-0000000000c1',
     'reason','без voice_request_id'));

select id as e_vf_ok from public.events
 where type = 'lesson.voice_failed' and payload ->> 'voice_request_id' = 'a0470000-0000-0000-0000-000000000070'
   and center_id = 'a0470000-0000-0000-0000-0000000000c1' \gset
select id as e_vf_note from public.events
 where type = 'lesson.voice_failed' and payload ->> 'voice_request_id' = 'a0470000-0000-0000-0000-000000000071' \gset
select id as e_vf_fired from public.events
 where type = 'lesson.voice_failed' and payload ->> 'voice_request_id' = 'a0470000-0000-0000-0000-000000000072' \gset
select id as e_vf_center from public.events
 where type = 'lesson.voice_failed' and center_id = 'a0470000-0000-0000-0000-0000000000c2' \gset
select id as e_vf_empty from public.events
 where type = 'lesson.voice_failed' and not (payload ? 'voice_request_id') \gset

select is(
  (select count(*)::int from public.event_messages(:'e_vf_ok')),
  1, 'Отказ доставлен одному получателю');
select is(
  (select recipient_user_id from public.event_messages(:'e_vf_ok')),
  'a0470000-0000-0000-0000-000000000002'::uuid,
  'Получатель — заказчик диктовки');
select is(
  (select channel from public.event_messages(:'e_vf_ok')),
  'telegram', 'Канал — telegram, привязка жива');
select ok(
  (select message from public.event_messages(:'e_vf_ok')) not like '%sound_R%'
  and (select message from public.event_messages(:'e_vf_ok')) not like '%invalid input%',
  'Сырая причина отказа в сообщение не попадает (Р6)');
select is(
  (select subject_id from public.event_messages(:'e_vf_ok')),
  'a0470000-0000-0000-0000-000000000040'::uuid,
  'subject_id = ребёнок диктовки');

select is(
  (select count(*)::int from public.event_messages(:'e_vf_note')),
  0, 'По занятию уже есть живая заметка — «попробуйте ещё раз» не шлётся (Р4)');
select is(
  (select count(*)::int from public.event_messages(:'e_vf_fired')),
  0, 'Заказчик без членства в центре — ноль получателей, хотя Telegram привязан (Р2)');
select is(
  (select count(*)::int from public.event_messages(:'e_vf_center')),
  0, 'Событие центра Б с запросом центра А — ноль получателей');
select lives_ok(
  format($q$ select * from public.event_messages(%s) $q$, :'e_vf_empty'),
  'Payload без voice_request_id не роняет доставку');

-- Специалист отвязал Telegram: канал whatsapp_link, имени ребёнка в тексте нет.
update public.telegram_accounts set unlinked_at = now() where user_id = 'a0470000-0000-0000-0000-000000000002';
select is(
  (select channel from public.event_messages(:'e_vf_ok')),
  'whatsapp_link', 'Без привязки — whatsapp_link');
select ok(
  (select message from public.event_messages(:'e_vf_ok')) not like '%КАНАРЕЙКА-ИМЯ%',
  'В whatsapp_link имя ребёнка не подставляется (Р1, как 0045 Р8)');


-- 5. Права и сохранность старых веток ----------------------------------------------------------------

select public.tests_claims('a0470000-0000-0000-0000-000000000002','a0470000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  format($q$ select public.event_messages(%s) $q$, :'e_vf_ok'),
  '42501', null,
  'event_messages под живой сессией специалиста отбивается');
select throws_ok(
  $q$ select public.notification_user_targets('a0470000-0000-0000-0000-0000000000c1','a0470000-0000-0000-0000-000000000002','lesson.voice_failed') $q$,
  '42501', null,
  'notification_user_targets из сессии не вызвать');
reset role;
select public.tests_claims(null, null);

select ok(
  not has_function_privilege('authenticated', 'public.notification_user_targets(uuid, uuid, text)', 'EXECUTE'),
  'У authenticated нет EXECUTE на notification_user_targets');

-- lesson.reminder жив после переиздания: кнопка подтверждения на месте.
-- Занятие 57 — у второго ребёнка: его родитель Telegram не отвязывал.
insert into public.events (center_id, type, payload) values
  ('a0470000-0000-0000-0000-0000000000c1', 'lesson.reminder',
   jsonb_build_object('lesson_id','a0470000-0000-0000-0000-000000000057'));
select ok(
  (select action ->> 'callback_data' from public.event_messages(
     (select max(id) from public.events where type = 'lesson.reminder'))
    where recipient_user_id = 'a0470000-0000-0000-0000-000000000004') like 'c:%',
  'lesson.reminder после переиздания по-прежнему отдаёт кнопку с callback_data');

insert into public.events (center_id, type, payload) values
  ('a0470000-0000-0000-0000-0000000000c1', 'nobody.knows', '{}'::jsonb);
select is(
  (select count(*)::int from public.event_messages(
     (select max(id) from public.events where type = 'nobody.knows'))),
  0, 'Тип вне белого списка — пустой результат');

select * from finish();

rollback;
