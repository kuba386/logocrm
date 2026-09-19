-- pgTAP: клиническое ядро — видимость по ролям (0036).
--
-- Главное здесь не таблицы, а кто что видит. Клинические данные — самый
-- чувствительный класс в проекте: деньги пересчитываются, сказанное про
-- ребёнка — нет. Поэтому каждая из шести ролей проверяется отдельно, а
-- «родитель не видит рабочий материал» — по составу колонок функции, а не
-- по значению: колонки там нет физически (ADR-005).
--
-- Фикстура устроена так, чтобы ни один ассерт не проходил по неверной
-- причине. Везде, где проверяется изоляция, строк в таблице больше одной:
-- «1 из 2» означает изоляцию, «1 из 1» не означает ничего. У каждого
-- ребёнка свой плательщик, у каждого центра свой владелец и свой
-- специалист — иначе «чужой ребёнок» чужой только наполовину.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() перед каждым
-- блоком явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(80);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','12121212-1212-1212-1212-121212121212','authenticated','authenticated','admin-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-own-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','teacher-other-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','parent2-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','88888888-8888-8888-8888-888888888888','authenticated','authenticated','parent-nopayer-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','99999999-9999-9999-9999-999999999999','authenticated','authenticated','owner-b-cl@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','10101010-1010-1010-1010-101010101010','authenticated','authenticated','teacher-b-cl@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-clin','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-clin','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ведущий специалист'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Другой специалист'),
  ('aaaaaaaa-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000b','Специалист центра Б');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Логопед',70000),
  ('bbbbbbbb-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000b','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Родитель один','+996700000001'),
  ('dddddddd-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Родитель два','+996700000002'),
  ('dddddddd-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000b','Родитель центра Б','+996700000003');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',    null, null),
  ('12121212-1212-1212-1212-121212121212','cccccccc-0000-0000-0000-00000000000a','admin',    null, null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001', null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000002', null),
  ('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a','parent',   null, 'dddddddd-0000-0000-0000-000000000001'),
  ('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a','parent',   null, 'dddddddd-0000-0000-0000-000000000002'),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a','registrar',null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','finance',  null, null),
  ('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-00000000000a','parent',   null, null),
  ('99999999-9999-9999-9999-999999999999','cccccccc-0000-0000-0000-00000000000b','owner',    null, null),
  ('10101010-1010-1010-1010-101010101010','cccccccc-0000-0000-0000-00000000000b','teacher','aaaaaaaa-0000-0000-0000-000000000003', null);

-- У каждого ребёнка свой плательщик: иначе «чужой ребёнок» для родителя не
-- чужой, и половина ассертов проходит по неверной причине.
insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок первого родителя','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Ребёнок второго родителя','dddddddd-0000-0000-0000-000000000002'),
  ('eeeeeeee-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Архивный ребёнок','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000b','Ребёнок центра Б','dddddddd-0000-0000-0000-000000000003');

-- Специалист связан с ребёнком через состав занятия. Занятие …0005 отменено:
-- оно не должно давать другому специалисту доступ к первому ребёнку (Р10).
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('ffffffff-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','planned',   now() + interval '2 hours',  now() + interval '2 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','planned',   now() + interval '6 hours',  now() + interval '6 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-000000000001','planned',   now() + interval '4 hours',  now() + interval '4 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000001','planned',   now() + interval '8 hours',  now() + interval '8 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','cancelled', now() + interval '10 hours', now() + interval '10 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000006','cccccccc-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-000000000003','eeeeeeee-0000-0000-0000-000000000004','bbbbbbbb-0000-0000-0000-000000000002','planned',   now() + interval '2 hours',  now() + interval '2 hours 45 minutes');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

-- Клеймы владельца на время фикстуры: роль остаётся postgres (RLS не мешает
-- заводить данные), но auth.uid() перестаёт быть пустым — иначе created_by и
-- approved_by заполнить нечем, и «кто утвердил» проверять не на чем.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');

-- Клинические данные заводит владелец (запись специалиста — RPC в 0037).
insert into public.diagnostics (center_id, student_id, teacher_id, conclusion, sounds, speech_areas) values
  ('cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
   'ОНР III уровня', '{"р": "искажение"}'::jsonb, '{"звукопроизношение": 3}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000002', null, 'Заключение второго ребёнка', '{}'::jsonb, '{}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','eeeeeeee-0000-0000-0000-000000000004', null, 'Заключение центра Б', '{}'::jsonb, '{}'::jsonb);

insert into public.goals (id, center_id, student_id, stage_id, title, sound, status) values
  ('bbbb0000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001',
   (select id from public.goal_stages where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'syllables'),
   'Автоматизация [р] в слогах', 'р', 'active'),
  ('bbbb0000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000002',
   (select id from public.goal_stages where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'setting'),
   'Постановка [л]', 'л', 'active'),
  ('bbbb0000-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001',
   (select id from public.goal_stages where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'setting'),
   'Постановка [р]', 'р', 'achieved'),
  ('bbbb0000-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000b','eeeeeeee-0000-0000-0000-000000000004',
   (select id from public.goal_stages where center_id = 'cccccccc-0000-0000-0000-00000000000b' and code = 'words'),
   'Цель центра Б', 'ш', 'active');

insert into public.goal_progress (center_id, goal_id, lesson_id, score, note) values
  ('cccccccc-0000-0000-0000-00000000000a','bbbb0000-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001', 60,
   'Внутренняя пометка: мать торопит, ребёнок устаёт'),
  ('cccccccc-0000-0000-0000-00000000000a','bbbb0000-0000-0000-0000-000000000002','ffffffff-0000-0000-0000-000000000004', 40,
   'Пометка по второму ребёнку');

insert into public.lesson_notes (center_id, lesson_id, student_id, teacher_id, raw_transcript, soap, parent_summary, status) values
  ('cccccccc-0000-0000-0000-00000000000a','ffffffff-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001', 'расшифровка голосового со словами специалиста',
   '{"plan": "закрепить слоги"}'::jsonb, 'Сегодня хорошо получались слоги.', 'approved');

-- Черновик на том же живом ребёнке, а не на архивном: иначе «родителю
-- черновик не виден» доказывалось бы архивом, и снятие фильтра по статусу
-- из student_notes_brief тест бы не заметил.
insert into public.lesson_notes (center_id, lesson_id, student_id, teacher_id, parent_summary, status) values
  ('cccccccc-0000-0000-0000-00000000000a','ffffffff-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001', 'Черновик, родителю показывать рано', 'draft'),
  ('cccccccc-0000-0000-0000-00000000000a','ffffffff-0000-0000-0000-000000000003','eeeeeeee-0000-0000-0000-000000000003',
   'aaaaaaaa-0000-0000-0000-000000000001', 'Резюме по архивному ребёнку', 'approved'),
  ('cccccccc-0000-0000-0000-00000000000b','ffffffff-0000-0000-0000-000000000006','eeeeeeee-0000-0000-0000-000000000004',
   'aaaaaaaa-0000-0000-0000-000000000003', 'Резюме центра Б', 'approved');

insert into public.exercise_library (id, center_id, title, sound, stage_code) values
  ('dddd0000-0000-0000-0000-000000000001', null, 'Упражнение платформы', 'р', 'syllables'),
  ('dddd0000-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-00000000000a', 'Упражнение центра А', 'р', 'words'),
  ('dddd0000-0000-0000-0000-000000000003', 'cccccccc-0000-0000-0000-00000000000b', 'Упражнение центра Б', 'ш', 'words');

insert into public.homework (id, center_id, student_id, lesson_id, free_text) values
  ('aaaa0000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001',
   'ffffffff-0000-0000-0000-000000000001','Повторять слоги пять минут в день'),
  ('aaaa0000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000002',
   'ffffffff-0000-0000-0000-000000000004','Задание второму ребёнку');

-- Состав задания заводится здесь, а не в конце файла: иначе блоки
-- регистратора и бухгалтера суммировали бы ноль из пустой таблицы, и снятие
-- политики с homework_exercises тест бы не заметил. По набору на каждого
-- ребёнка — чтобы у каждого «видит» был свой «не видит».
insert into public.homework_exercises (homework_id, exercise_id, center_id) values
  ('aaaa0000-0000-0000-0000-000000000001','dddd0000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a'),
  ('aaaa0000-0000-0000-0000-000000000002','dddd0000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a');

-- Архивируем ребёнка после того, как завели ему заметку: специалист не
-- должен видеть клинику архивного.
update public.students set deleted_at = now() where id = 'eeeeeeee-0000-0000-0000-000000000003';


-- Справочник этапов ------------------------------------------------------------------------

select is(
  (select count(*)::int from public.goal_stages where center_id = 'cccccccc-0000-0000-0000-00000000000a'),
  7, 'Новому центру этапы ставит триггер: семь штук');

select is(
  (select code from public.goal_stages
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' order by sort limit 1),
  'setting', 'Первый этап — постановка: её в промте не было, а с неё начинается половина случаев');

select is(
  (select code from public.goal_stages
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' order by sort desc limit 1),
  'differentiation', 'Последний — дифференциация, а не «автоматизирован»: достижение цели это статус');

select is(
  (select count(*)::int from public.goal_stages
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'automated'),
  0, '«Автоматизирован» из этапов убран — иначе два способа сказать одно и то же разъедутся');

select ok(
  (select bool_and(sort > 0) from public.goal_stages where center_id = 'cccccccc-0000-0000-0000-00000000000a'),
  'У каждого этапа есть порядок — он нужен прогресс-бару и подсказке «следующий этап»');


-- Инварианты статусов (Р8) ------------------------------------------------------------------

-- Проверяется от postgres сознательно: смысл в том, что констрейнт и триггер
-- держат инвариант независимо от роли и от того, звали RPC или нет.

select ok(
  (select approved_at is not null from public.lesson_notes where lesson_id = 'ffffffff-0000-0000-0000-000000000001'),
  'Метку утверждения ставит база: клиент прислал только status');

select ok(
  (select approved_by is not null from public.lesson_notes where lesson_id = 'ffffffff-0000-0000-0000-000000000001'),
  'Вместе с автором — иначе «кто утвердил» не восстановить');

select ok(
  (select approved_at is null from public.lesson_notes where lesson_id = 'ffffffff-0000-0000-0000-000000000002'),
  'У черновика метки утверждения нет');

select throws_ok(
  $q$ update public.lesson_notes set status = 'draft'
       where lesson_id = 'ffffffff-0000-0000-0000-000000000001' $q$,
  '23514', null,
  'Утверждённое резюме нельзя вернуть в черновик: родитель его уже видел');

-- Метку нельзя ни подделать снаружи, ни оставить от прошлого статуса:
-- триггер выводит её из статуса, а не принимает от клиента.
insert into public.lesson_notes (center_id, lesson_id, student_id, status, approved_at, approved_by)
values ('cccccccc-0000-0000-0000-00000000000a','ffffffff-0000-0000-0000-000000000004',
        'eeeeeeee-0000-0000-0000-000000000002','draft', now(), '11111111-1111-1111-1111-111111111111');

select ok(
  (select approved_at is null and approved_by is null from public.lesson_notes
    where lesson_id = 'ffffffff-0000-0000-0000-000000000004'),
  'Присланную метку утверждения у черновика база стирает: статус и метка — один инвариант');

select ok(
  (select achieved_at is not null from public.goals where id = 'bbbb0000-0000-0000-0000-000000000003'),
  'Достигнутая цель получает метку достижения от триггера');

select ok(
  (select achieved_at is null from public.goals where id = 'bbbb0000-0000-0000-0000-000000000001'),
  'У активной цели метки нет');

-- Статус не менялся, меняют только метку: без отдельной ветки в триггере
-- проверка перехода не срабатывает, и подделка выглядит как гарантия.
update public.lesson_notes
   set approved_by = '33333333-3333-3333-3333-333333333333', approved_at = '2020-01-01'
 where lesson_id = 'ffffffff-0000-0000-0000-000000000001';

select is(
  (select approved_by from public.lesson_notes where lesson_id = 'ffffffff-0000-0000-0000-000000000001'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'Автора утверждения не переписать: статус не менялся, значит и метка прежняя');

select ok(
  (select approved_at > '2021-01-01'::timestamptz from public.lesson_notes
    where lesson_id = 'ffffffff-0000-0000-0000-000000000001'),
  'И дату тоже: присланную триггер отбрасывает');

update public.goals set achieved_at = '2020-01-01'
 where id = 'bbbb0000-0000-0000-0000-000000000003';

select ok(
  (select achieved_at > '2021-01-01'::timestamptz from public.goals
    where id = 'bbbb0000-0000-0000-0000-000000000003'),
  'Дату достижения уже достигнутой цели тоже не переписать');

select throws_ok(
  $q$ update public.goals set student_id = 'eeeeeeee-0000-0000-0000-000000000002'
       where id = 'bbbb0000-0000-0000-0000-000000000001' $q$,
  '23514', null,
  'Цель нельзя переставить на другого ребёнка: весь хвост прогресса уехал бы вместе с ней');

select throws_ok(
  $q$ update public.homework set status = 'reviewed' where id = 'aaaa0000-0000-0000-0000-000000000001';
      update public.homework set status = 'assigned' where id = 'aaaa0000-0000-0000-0000-000000000001' $q$,
  '23514', null,
  'Задание не откатывается из «проверено» обратно в «выдано»');


-- Контекст без пользователя: воркер 7b, бэкфилл, definer без клеймов.
select public.tests_claims(null, null);
select throws_ok(
  $q$ insert into public.lesson_notes (center_id, lesson_id, student_id, parent_summary, status)
      values ('cccccccc-0000-0000-0000-00000000000a','ffffffff-0000-0000-0000-000000000004',
              'eeeeeeee-0000-0000-0000-000000000002','Резюме без автора','approved') $q$,
  '23514', null,
  'Утверждённое резюме без автора не заводится — иначе «утверждено неизвестно кем» прошло бы молча');
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');


-- Состав занятия (Р9) ------------------------------------------------------------------------------

select throws_ok(
  $q$ insert into public.lesson_notes (center_id, lesson_id, student_id, parent_summary)
      values ('cccccccc-0000-0000-0000-00000000000a','ffffffff-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000002','SOAP не того ребёнка') $q$,
  '42704', null,
  'Заметку нельзя записать на ребёнка, которого на этом занятии не было');

select throws_ok(
  $q$ insert into public.goal_progress (center_id, goal_id, lesson_id, score)
      values ('cccccccc-0000-0000-0000-00000000000a','bbbb0000-0000-0000-0000-000000000002',
              'ffffffff-0000-0000-0000-000000000001', 50) $q$,
  '42704', null,
  'И прогресс по цели ребёнка, которого на занятии не было');

select lives_ok(
  $q$ insert into public.homework (center_id, student_id, free_text)
      values ('cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000002',
              'Задание без привязки к занятию') $q$,
  'Без lesson_id проверка состава не применяется: задание можно выдать и вне занятия');

select throws_ok(
  $q$ insert into public.lesson_notes (center_id, lesson_id, student_id, parent_summary)
      values ('cccccccc-0000-0000-0000-00000000000a','ffffffff-0000-0000-0000-000000000005',
              'eeeeeeee-0000-0000-0000-000000000001','Заметка на отменённом занятии') $q$,
  '42704', null,
  'На отменённое занятие клинику не записать — иначе автор заметки не смог бы её прочитать, а родитель смог');


-- Ведущий специалист видит своё и только своё ------------------------------------------------

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is((select count(*)::int from public.diagnostics), 1,
  'Ведущий специалист видит диагностику своего ребёнка и не видит диагностику второго');
select is((select count(*)::int from public.goals), 2, 'И обе его цели — из трёх в центре');
select is((select count(*)::int from public.goal_progress), 1, 'И прогресс только по своему ребёнку');
select is((select count(*)::int from public.lesson_notes), 2,
  'И обе заметки по живому ребёнку — но не по архивному');
select is((select count(*)::int from public.homework), 1, 'И домашнее задание своего ребёнка');
select is((select count(*)::int from public.homework_exercises), 1,
  'И состав этого задания — из двух наборов в центре');
select is((select count(*)::int from public.goal_stages), 7, 'Справочник этапов специалисту нужен');
select is((select count(*)::int from public.exercise_library), 2,
  'Библиотека: упражнение центра и платформенное, но не упражнение центра Б');
select throws_ok(
  $q$ insert into public.goals (center_id, student_id, stage_id, title)
      values ('cccccccc-0000-0000-0000-00000000000a', 'eeeeeeee-0000-0000-0000-000000000001',
              (select id from public.goal_stages where code = 'words' limit 1), 'Своя цель') $q$,
  '42501', null,
  'Специалист не пишет клинику напрямую — только через RPC (Р1)');
select throws_ok(
  $q$ insert into public.homework_exercises (homework_id, exercise_id, center_id)
      values ('aaaa0000-0000-0000-0000-000000000001','dddd0000-0000-0000-0000-000000000001',
              'cccccccc-0000-0000-0000-00000000000a') $q$,
  '42501', null,
  'И состав задания тоже не правит напрямую');
reset role;


-- Другой специалист: отменённое занятие доступа не даёт (Р10) --------------------------------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostics where student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  0, 'Отменённое занятие не открывает специалисту диагностику ребёнка');
select is(
  (select count(*)::int from public.lesson_notes where student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  0, 'Ни его заметки');
select is(
  (select count(*)::int from public.goals where student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  0, 'Ни его цели');
select is((select count(*)::int from public.diagnostics), 1,
  'Зато диагностику ребёнка, с которым занятие не отменено, он видит — проверка не «всё запрещено»');
select is(
  (select count(*)::int from public.student_goals_brief('eeeeeeee-0000-0000-0000-000000000001')), 0,
  'И через узкую функцию по чужому ребёнку тоже ничего');
reset role;


-- Родитель: только то, что для него -----------------------------------------------------------

select public.tests_claims('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is((select count(*)::int from public.diagnostics), 0,
  'Родителю таблица диагностики закрыта целиком — заключение отдаёт функция');
select is((select count(*)::int from public.lesson_notes), 0,
  'И таблица заметок: там расшифровка и SOAP');
select is((select count(*)::int from public.goal_progress), 0,
  'И прогресс: там внутренние пометки специалиста');
select is((select count(*)::int from public.goals), 0,
  'И таблица целей: этапы и статусы отдаёт функция');
select is((select count(*)::int from public.homework where student_id = 'eeeeeeee-0000-0000-0000-000000000001'), 1,
  'А домашнее задание своего ребёнка видно: оно для него и написано');
select is((select count(*)::int from public.homework where student_id = 'eeeeeeee-0000-0000-0000-000000000002'), 0,
  'Задания ребёнка другого плательщика — нет');

select is(
  (select conclusion from public.student_diagnostics_brief('eeeeeeee-0000-0000-0000-000000000001')),
  'ОНР III уровня', 'Заключение родителю доступно');
select is(
  (select count(*)::int from public.student_goals_brief('eeeeeeee-0000-0000-0000-000000000001')), 2,
  'Цели ребёнка — доступны обе');
select is(
  (select last_score from public.student_goals_brief('eeeeeeee-0000-0000-0000-000000000001')
    where id = 'bbbb0000-0000-0000-0000-000000000001'), 60,
  'Вместе с последней оценкой — но без пометки к ней');
select is(
  (select count(*)::int from public.student_diagnostics_brief('eeeeeeee-0000-0000-0000-000000000002')), 0,
  'По ребёнку другого плательщика функция молчит');
reset role;


-- Черновик родителю не виден ни при каких условиях --------------------------------------------

select public.tests_claims('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.student_notes_brief('eeeeeeee-0000-0000-0000-000000000001')), 1,
  'Из двух заметок живого ребёнка родителю видна одна');
select is(
  (select parent_summary from public.student_notes_brief('eeeeeeee-0000-0000-0000-000000000001')),
  'Сегодня хорошо получались слоги.',
  'И это именно утверждённая, а не черновик: фильтр по статусу, а не случайность фикстуры');
reset role;

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.homework where student_id = 'eeeeeeee-0000-0000-0000-000000000002'), 2,
  'Второй родитель видит оба задания своего ребёнка');
select is((select count(*)::int from public.homework_exercises), 1,
  'И состав только своего задания — чужой набор ему не виден');
select is(
  (select count(*)::int from public.student_notes_brief('eeeeeeee-0000-0000-0000-000000000001')), 0,
  'И ничего по ребёнку первого родителя — плательщик разный');
reset role;


-- Чего родитель не увидит физически -------------------------------------------------------------

select is(
  pg_get_function_result('public.student_diagnostics_brief(uuid)'::regprocedure),
  'TABLE(id uuid, date date, conclusion text, teacher_name text)',
  'В диагностике для родителя нет колонок sounds и speech_areas — физически');

select is(
  pg_get_function_result('public.student_notes_brief(uuid)'::regprocedure),
  'TABLE(id uuid, lesson_id uuid, lesson_at timestamp with time zone, parent_summary text)',
  'В резюме занятий нет raw_transcript и soap — физически');

select ok(
  pg_get_function_result('public.student_goals_brief(uuid)'::regprocedure) not like '%note%',
  'В целях для родителя нет пометки специалиста');

select public.tests_claims('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.student_goals_brief('eeeeeeee-0000-0000-0000-000000000001')), 0,
  'Родитель без плательщика в членстве не видит ничего — NULL в связке не открывает чужого ребёнка');
reset role;


-- Стойке и бухгалтеру клиника не положена (Р2) ---------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostics) + (select count(*)::int from public.goals)
  + (select count(*)::int from public.goal_progress) + (select count(*)::int from public.lesson_notes)
  + (select count(*)::int from public.homework) + (select count(*)::int from public.homework_exercises),
  0, 'Регистратор не видит ни одной клинической строки — включая задания и их состав');
select is((select count(*)::int from public.goal_stages), 0,
  'И справочник этапов: через него видно, над чем центр работает');
select is((select count(*)::int from public.exercise_library), 0,
  'И библиотеку упражнений: instructions и media_url — рабочий материал');
select is(
  (select count(*)::int from public.student_notes_brief('eeeeeeee-0000-0000-0000-000000000001')), 0,
  'И через узкую функцию ничего');
reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostics) + (select count(*)::int from public.goals)
  + (select count(*)::int from public.goal_progress) + (select count(*)::int from public.lesson_notes)
  + (select count(*)::int from public.homework) + (select count(*)::int from public.homework_exercises),
  0, 'Бухгалтер тоже: 0031 закрыл ему заметки о семье, клиника тем более');
select is((select count(*)::int from public.goal_stages), 0, 'И справочник этапов');
select is((select count(*)::int from public.exercise_library), 0, 'И библиотеку');
select is(
  (select count(*)::int from public.student_goals_brief('eeeeeeee-0000-0000-0000-000000000001')), 0,
  'И через узкую функцию ничего');
reset role;


-- Владелец и администратор видят всё --------------------------------------------------------------

-- Проверяющая сторона обещания: без неё тест ловит только тех, кто видеть
-- не должен, и опечатка в предикате «owner или admin» уехала бы в staging.

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.diagnostics), 2,
  'Владелец видит диагностику обоих детей своего центра');
select is((select count(*)::int from public.lesson_notes), 4,
  'И все заметки — включая черновики и заметку по архивному ребёнку');
select is((select count(*)::int from public.goals), 3, 'И все цели');
select is((select count(*)::int from public.homework_exercises), 2,
  'И оба набора упражнений — ассерты про ноль выше считались по непустой таблице');
select is(
  (select count(*)::int from public.student_notes_brief('eeeeeeee-0000-0000-0000-000000000001')), 1,
  'Узкие функции ему тоже отвечают — их зовёт та же карточка ребёнка');
reset role;

select public.tests_claims('12121212-1212-1212-1212-121212121212','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.diagnostics), 2, 'Администратор — так же, как владелец');
select is(
  (select count(*)::int from public.student_diagnostics_brief('eeeeeeee-0000-0000-0000-000000000002')), 1,
  'И по второму ребёнку тоже');
reset role;


-- Чужой центр (Database.md: обязательный тест для каждой таблицы с RLS) ------------------------------

select public.tests_claims('99999999-9999-9999-9999-999999999999','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostics where center_id = 'cccccccc-0000-0000-0000-00000000000a')
  + (select count(*)::int from public.goals where center_id = 'cccccccc-0000-0000-0000-00000000000a')
  + (select count(*)::int from public.goal_progress where center_id = 'cccccccc-0000-0000-0000-00000000000a')
  + (select count(*)::int from public.lesson_notes where center_id = 'cccccccc-0000-0000-0000-00000000000a')
  + (select count(*)::int from public.homework where center_id = 'cccccccc-0000-0000-0000-00000000000a')
  + (select count(*)::int from public.goal_stages where center_id = 'cccccccc-0000-0000-0000-00000000000a'),
  0, 'Владелец центра Б не видит ни одной строки центра А');
select is((select count(*)::int from public.diagnostics), 1,
  'Свою диагностику при этом видит — иначе ноль выше ничего не доказывает');
select is(
  (select count(*)::int from public.student_goals_brief('eeeeeeee-0000-0000-0000-000000000001')), 0,
  'Узкая функция по ребёнку центра А молчит: current_center() здесь единственный рубеж');
select is(
  (select count(*)::int from public.student_notes_brief('eeeeeeee-0000-0000-0000-000000000001')), 0,
  'И резюме занятий тоже');
reset role;

select public.tests_claims('10101010-1010-1010-1010-101010101010','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select is(
  (select count(*)::int from public.diagnostics where student_id = 'eeeeeeee-0000-0000-0000-000000000001'), 0,
  'Специалист центра Б не видит диагностику ребёнка центра А');
reset role;


-- Упражнения в задании (Р7) --------------------------------------------------------------------------

-- От владельца под ролью authenticated, а не от postgres: иначе проверялся бы
-- только триггер, а with check политики остался бы недоказанным.

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- Прямая запись в homework_exercises закрыта 0038 — состав задания теперь
-- меняется только через update_homework, ей и проверяются оба случая.
select lives_ok(
  $q$ select public.update_homework('aaaa0000-0000-0000-0000-000000000002', null,
        'Задание второму ребёнку',
        array['dddd0000-0000-0000-0000-000000000002','dddd0000-0000-0000-0000-000000000001']::uuid[]) $q$,
  'Упражнение платформы добавляется в ДЗ — составной FK это бы запретил (Р7)');

select throws_ok(
  $q$ select public.update_homework('aaaa0000-0000-0000-0000-000000000001', null,
        'Повторять слоги пять минут в день',
        array['dddd0000-0000-0000-0000-000000000001','dddd0000-0000-0000-0000-000000000003']::uuid[]) $q$,
  '42704', null,
  'Упражнение чужого центра отбивается триггером, а не проверкой в функции');

-- 0040 закрыла прямую запись в exercise_library тем же приёмом, что и у
-- остальных клинических таблиц (0038) — теперь это 42501 на гранте, а не
-- тихий ноль строк от tenant_admin.
select throws_ok(
  $q$ update public.exercise_library set title = 'Переписали платформу'
      where id = 'dddd0000-0000-0000-0000-000000000001' $q$,
  '42501', null,
  'exercise_library: прямой update закрыт (0040) — библиотеку правит save_exercise');
reset role;

-- Одно правило про отменённое занятие на оба конца: специалист теряет
-- доступ, родитель — резюме. Иначе они видят разные истории одного ребёнка.
update public.lessons set status = 'cancelled' where id = 'ffffffff-0000-0000-0000-000000000001';

select public.tests_claims('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.student_notes_brief('eeeeeeee-0000-0000-0000-000000000001')), 0,
  'После отмены занятия его резюме уходит и у родителя, а не только у специалиста');
reset role;

select * from finish();

rollback;
