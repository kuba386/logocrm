-- pgTAP: доставка уведомлений по домашним заданиям (0045).
--
-- Главное здесь — адресация homework.submitted (три круга, Р1) и то, что
-- доставка идёт от роли без сессии: clinical_teacher_sees внутри
-- event_messages вернула бы false на любом аргументе, если бы адресация
-- была построена на ней (Б1) — все проверки на event_messages идут под
-- tests_claims(null, null).
--
-- event_messages не проверяет claimed_at (это книга claim_events, а не
-- её) — событие достаточно создать, отдельно захватывать не нужно.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно перед
-- каждым блоком.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(33);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','81111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-hw@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','84444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-main-hw@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','85555555-5555-5555-5555-555555555555','authenticated','authenticated','teacher-sub-hw@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','86666666-6666-6666-6666-666666666666','authenticated','authenticated','teacher-old-hw@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','87777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-hw@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','82222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-hw@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','83333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-hw@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('8ccccccc-0000-0000-0000-00000000000a','Центр ДЗ','centr-hw','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('8aaaaaaa-0000-0000-0000-000000000001','8ccccccc-0000-0000-0000-00000000000a','Основной'),
  ('8aaaaaaa-0000-0000-0000-000000000002','8ccccccc-0000-0000-0000-00000000000a','Заменяющий'),
  ('8aaaaaaa-0000-0000-0000-000000000003','8ccccccc-0000-0000-0000-00000000000a','Давний');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('8bbbbbbb-0000-0000-0000-000000000001','8ccccccc-0000-0000-0000-00000000000a','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('8ddddddd-0000-0000-0000-000000000001','8ccccccc-0000-0000-0000-00000000000a','Родитель первого','+996700000801'),
  ('8ddddddd-0000-0000-0000-000000000002','8ccccccc-0000-0000-0000-00000000000a','Родитель второго','+996700000802');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('81111111-1111-1111-1111-111111111111','8ccccccc-0000-0000-0000-00000000000a','owner',    null, null),
  ('84444444-4444-4444-4444-444444444444','8ccccccc-0000-0000-0000-00000000000a','teacher','8aaaaaaa-0000-0000-0000-000000000001', null),
  ('85555555-5555-5555-5555-555555555555','8ccccccc-0000-0000-0000-00000000000a','teacher','8aaaaaaa-0000-0000-0000-000000000002', null),
  ('86666666-6666-6666-6666-666666666666','8ccccccc-0000-0000-0000-00000000000a','teacher','8aaaaaaa-0000-0000-0000-000000000003', null),
  ('82222222-2222-2222-2222-222222222222','8ccccccc-0000-0000-0000-00000000000a','registrar',null, null),
  ('83333333-3333-3333-3333-333333333333','8ccccccc-0000-0000-0000-00000000000a','finance',  null, null),
  ('87777777-7777-7777-7777-777777777777','8ccccccc-0000-0000-0000-00000000000a','parent',   null, '8ddddddd-0000-0000-0000-000000000001');

-- Ребёнок 1: у него живые занятия и с основным, и с заменяющим — за
-- последние часы. Ребёнок 2: только с «давним» специалистом, 70 дней
-- назад — за пределами запасного круга.
insert into public.students (id, center_id, full_name, payer_id) values
  ('8eeeeeee-0000-0000-0000-000000000001','8ccccccc-0000-0000-0000-00000000000a','Ребёнок первый','8ddddddd-0000-0000-0000-000000000001'),
  ('8eeeeeee-0000-0000-0000-000000000002','8ccccccc-0000-0000-0000-00000000000a','Ребёнок второй','8ddddddd-0000-0000-0000-000000000002');

insert into public.lessons (id, center_id, teacher_id, substitute_teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('8fffffff-0000-0000-0000-000000000001','8ccccccc-0000-0000-0000-00000000000a','8aaaaaaa-0000-0000-0000-000000000001',null,'8eeeeeee-0000-0000-0000-000000000001','8bbbbbbb-0000-0000-0000-000000000001','done', now() - interval '2 hours', now() - interval '1 hour 15 minutes'),
  ('8fffffff-0000-0000-0000-000000000002','8ccccccc-0000-0000-0000-00000000000a','8aaaaaaa-0000-0000-0000-000000000001','8aaaaaaa-0000-0000-0000-000000000002','8eeeeeee-0000-0000-0000-000000000001','8bbbbbbb-0000-0000-0000-000000000001','done', now() - interval '4 hours', now() - interval '3 hours 15 minutes'),
  ('8fffffff-0000-0000-0000-000000000003','8ccccccc-0000-0000-0000-00000000000a','8aaaaaaa-0000-0000-0000-000000000003',null,'8eeeeeee-0000-0000-0000-000000000002','8bbbbbbb-0000-0000-0000-000000000001','done', now() - interval '70 days', now() - interval '70 days' + interval '45 minutes');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- Круг 1: специалист занятия, без замены -------------------------------------------------------------

select public.tests_claims('84444444-4444-4444-4444-444444444444','8ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.assign_homework('8eeeeeee-0000-0000-0000-000000000001', 'КАНАРЕЙКА-СВОБОДНЫЙ-ТЕКСТ',
        '{}'::uuid[], '8fffffff-0000-0000-0000-000000000001', current_date + 3) $q$,
  'Специалист выдаёт ДЗ на своём занятии');
reset role;
select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.events where type = 'homework.assigned'),
  1, 'homework.assigned эмитирован при вставке (Р6) — триггером, а не изнутри assign_homework');

select is(
  (select count(*)::int from public.notification_homework_recipients(
     '8ccccccc-0000-0000-0000-00000000000a',
     (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000001'))),
  1, 'Круг 1: ровно один адресат — специалист занятия');

select is(
  (select user_id from public.notification_homework_recipients(
     '8ccccccc-0000-0000-0000-00000000000a',
     (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000001'))),
  '84444444-4444-4444-4444-444444444444'::uuid,
  'Именно специалист занятия');

select public.tests_claims(null, null);
select is(
  (select recipient_user_id from public.event_messages(
     (select id from public.events where type = 'homework.assigned'))),
  '81111111-1111-1111-1111-111111111111'::uuid,
  'homework.assigned доставлен родителю через notification_targets, как остальные student-события');

select ok(
  (select message from public.event_messages(
     (select id from public.events where type = 'homework.assigned')))
    not like '%КАНАРЕЙКА%',
  'free_text задания не попадает в текст уведомления родителю — только {child}/{due} (Р7)');


-- Круг 1 через замену: effective_teacher_id, а не teacher_id -------------------------------------

update public.homework set lesson_id = '8fffffff-0000-0000-0000-000000000002'
 where student_id = '8eeeeeee-0000-0000-0000-000000000001';

select is(
  (select user_id from public.notification_homework_recipients(
     '8ccccccc-0000-0000-0000-00000000000a',
     (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000001'))),
  '85555555-5555-5555-5555-555555555555'::uuid,
  'Занятие с заменой → адресат заменяющий (effective_teacher_id), а не основной');

update public.homework set lesson_id = '8fffffff-0000-0000-0000-000000000001'
 where student_id = '8eeeeeee-0000-0000-0000-000000000001';


-- Круг 2: автор без привязки к занятию, owner --------------------------------------------------------

select public.tests_claims('81111111-1111-1111-1111-111111111111','8ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.assign_homework('8eeeeeee-0000-0000-0000-000000000001', null, '{}'::uuid[], null, null) $q$,
  'Владелец выдаёт ДЗ вне занятия (карточка ребёнка)');
reset role;
select public.tests_claims(null, null);

select is(
  (select user_id from public.notification_homework_recipients(
     '8ccccccc-0000-0000-0000-00000000000a',
     (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000001' and lesson_id is null))),
  '81111111-1111-1111-1111-111111111111'::uuid,
  'Без lesson_id круг 1 пуст, круг 2 находит автора-владельца');


-- Круг 3: автор задания не ведёт ребёнка — несколько адресатов, осознанный компромисс ------------------

update public.homework set created_by = '86666666-6666-6666-6666-666666666666'
 where student_id = '8eeeeeee-0000-0000-0000-000000000001' and lesson_id is null;

select is(
  (select count(*)::int from public.notification_homework_recipients(
     '8ccccccc-0000-0000-0000-00000000000a',
     (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000001' and lesson_id is null))),
  2,
  'Автор («Давний») ребёнка не ведёт — круг 2 не срабатывает; запасной круг находит ОБОИХ специалистов ребёнка (Р1: лучше лишнее сообщение, чем потерянное)');

select is(
  (select count(*)::int from public.notification_homework_recipients(
     '8ccccccc-0000-0000-0000-00000000000a',
     (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000001' and lesson_id is null))
   where user_id in ('84444444-4444-4444-4444-444444444444', '85555555-5555-5555-5555-555555555555')),
  2, 'И это именно основной и заменяющий, а не кто попало');


-- Б2: автор ушёл из центра, а запасной круг не находит никого (занятие старше 60 дней) ------------------

select public.tests_claims('86666666-6666-6666-6666-666666666666','8ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.assign_homework('8eeeeeee-0000-0000-0000-000000000002', null, '{}'::uuid[], null, null) $q$,
  '«Давний» специалист выдаёт ДЗ второму ребёнку — clinical_teacher_sees не ограничен сроком (0036 Р3)');
reset role;
select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.notification_homework_recipients(
     '8ccccccc-0000-0000-0000-00000000000a',
     (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000002'))),
  1, 'Пока «Давний» в центре — круг 2 находит его самого');

delete from public.memberships where user_id = '86666666-6666-6666-6666-666666666666';

select is(
  (select count(*)::int from public.notification_homework_recipients(
     '8ccccccc-0000-0000-0000-00000000000a',
     (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000002'))),
  0,
  'Автор ушёл из центра (Б2) — круг 2 больше не находит его; запасной круг тоже пуст: единственное занятие с этим ребёнком старше 60 дней');


-- registrar/finance никогда не адресаты --------------------------------------------------------------

select is(
  (select count(*)::int from public.notification_homework_recipients(
     '8ccccccc-0000-0000-0000-00000000000a',
     (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000001' and lesson_id is null))
   where user_id in ('82222222-2222-2222-2222-222222222222', '83333333-3333-3333-3333-333333333333')),
  0, 'Регистратор и бухгалтер не входят ни в один круг — их роль не teacher/owner/admin');


-- Б1: доставка обязана работать без сессии, а не по сессии специалиста ------------------------------

select public.tests_claims('84444444-4444-4444-4444-444444444444','8ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  format($q$ select public.event_messages(%s) $q$,
    (select id from public.events where type = 'homework.assigned' limit 1)),
  '42501', null,
  'event_messages под живой сессией отбивается — доставка идёт только от bot_worker без JWT');
reset role;
select public.tests_claims(null, null);


-- Свежесть на доставке: submitted устаревает, assigned — нет (Р4) -----------------------------------

select public.tests_claims('87777777-7777-7777-7777-777777777777','8ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.submit_homework(
        (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000001' and lesson_id = '8fffffff-0000-0000-0000-000000000001'),
        'КАНАРЕЙКА-ОТ-РОДИТЕЛЯ') $q$,
  'Родитель сдаёт задание');
reset role;

select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.event_messages(
     (select id from public.events where type = 'homework.submitted' limit 1))),
  1, 'homework.submitted доставлен специалисту, пока задание ещё submitted');

select is(
  (select recipient_user_id from public.event_messages(
     (select id from public.events where type = 'homework.submitted' limit 1))),
  '84444444-4444-4444-4444-444444444444'::uuid,
  'Адресат submitted — специалист занятия, не родитель и не вся администрация (Р1)');

select ok(
  (select message from public.event_messages(
     (select id from public.events where type = 'homework.submitted' limit 1)))
    not like '%КАНАРЕЙКА%',
  'parent_note родителя не попадает в текст уведомления специалисту (Р7)');

-- assigned того же задания — по-прежнему доставляется, статус ушёл вперёд.
select is(
  (select count(*)::int from public.event_messages(
     (select id from public.events where type = 'homework.assigned' and center_id = '8ccccccc-0000-0000-0000-00000000000a'
        and payload ->> 'homework_id' = (select id from public.homework
          where student_id = '8eeeeeee-0000-0000-0000-000000000001' and lesson_id = '8fffffff-0000-0000-0000-000000000001')::text
      limit 1))),
  1, 'homework.assigned доставляется, даже когда статус уже submitted — факт выдачи не устаревает (Р4)');

select public.tests_claims('84444444-4444-4444-4444-444444444444','8ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.review_homework(
        (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000001' and lesson_id = '8fffffff-0000-0000-0000-000000000001'),
        'Отзыв специалиста') $q$,
  'Специалист проверяет сданное задание');
reset role;
select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.events where type = 'homework.reviewed'),
  1, 'homework.reviewed эмитирован при переходе в reviewed — до 0045 не эмитировался вовсе');

-- То же submitted-событие — доставлять больше нечего, статус ушёл дальше.
select is(
  (select count(*)::int from public.event_messages(
     (select id from public.events where type = 'homework.submitted' limit 1))),
  0, 'После review_homework то же homework.submitted больше не доставляется — напоминание устарело (Р4)');

select public.tests_claims(null, null);
select is(
  (select count(*)::int from public.event_messages(
     (select id from public.events where type = 'homework.reviewed'))),
  1, 'homework.reviewed доставлен родителю');


-- Р5: гонка «проверка — запись» — повторный review_homework не проходит тихо -----------------------

select public.tests_claims('84444444-4444-4444-4444-444444444444','8ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.review_homework(
        (select id from public.homework where student_id = '8eeeeeee-0000-0000-0000-000000000001' and lesson_id = '8fffffff-0000-0000-0000-000000000001'),
        'Второй отзыв') $q$,
  '23514', null,
  'Повторный review_homework на уже проверенном — отказ, а не тихая перезапись teacher_feedback (Р5)');

select is(
  (select teacher_feedback from public.homework
    where student_id = '8eeeeeee-0000-0000-0000-000000000001' and lesson_id = '8fffffff-0000-0000-0000-000000000001'),
  'Отзыв специалиста', 'Отзыв не перезаписан вторым вызовом');
reset role;
select public.tests_claims(null, null);


-- Событие мертво: задание архивировано после эмиссии (Б4) -------------------------------------------

select public.tests_claims('81111111-1111-1111-1111-111111111111','8ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select public.assign_homework('8eeeeeee-0000-0000-0000-000000000001', null, '{}'::uuid[], null, null) as hw_b4_id \gset
reset role;
select public.tests_claims(null, null);

-- По id, не по max(created_at): вся фикстура в одной транзакции, now()
-- заморожен на её начало, и у трёх заданий student1 created_at совпадает
-- день в день — "max" выбрал бы все три, а не только это.
update public.homework set deleted_at = now() where id = :'hw_b4_id';

select public.tests_claims(null, null);
select is(
  (select count(*)::int from public.event_messages(
     (select id from public.events where type = 'homework.assigned'
        and payload ->> 'homework_id' = :'hw_b4_id'))),
  0, 'Архивированное задание не доставляется — та же дыра, что 0035 чинил для lesson.reminder (Б4)');


-- Шаблоны и тип события ------------------------------------------------------------------------------

select is(
  (select count(*)::int from public.notification_event_types
    where event_type in ('homework.assigned', 'homework.submitted', 'homework.reviewed')),
  3, 'Все три типа в белом списке — без этого вставка шаблона упала бы на внешнем ключе');

select is(
  (select count(*)::int from public.message_templates
    where center_id is null
      and event_type in ('homework.assigned', 'homework.submitted', 'homework.reviewed')),
  6, 'По два шаблона на тип — родитель/специалист без Telegram иначе получают тишину при «отправлено»');

select is(
  (select text from public.message_templates
    where center_id is null and event_type = 'homework.submitted' and channel = 'whatsapp_link'),
  'Родитель сдал домашнее задание — откройте LogoCRM.',
  'Дефолт whatsapp_link для специалиста без имени ребёнка (Р8) — этот канал не доставляет, только оседает в журнале');

select ok(
  (select count(*)::int from public.message_templates
    where center_id is null and event_type = 'homework.submitted' and channel = 'whatsapp_link'
      and text like '%{child}%') = 0,
  'И в нём точно нет {child} — следующий автор не «улучшил» текст именем ребёнка');


-- Общий забор: параметризованное правило существует и используется -----------------------------------

select is(
  (select count(*)::int from pg_proc where proname = 'clinical_teacher_taught'),
  1, 'clinical_teacher_taught существует — параметризованное правило видимости, а не третья копия условия');

select * from finish();

rollback;
