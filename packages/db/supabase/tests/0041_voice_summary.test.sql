-- pgTAP: голосовое резюме занятия (0041).
--
-- Главное здесь — деньги и права. Контур записи работает без сессии
-- специалиста, поэтому каждая функция проверяется на то, что живая сессия
-- её вызвать НЕ может, а повтор события не приводит ко второй оплате.
--
-- Самый важный ассерт в файле — «специалист утверждает собственный
-- надиктованный черновик»: created_by у воркера пуст по умолчанию, и на
-- этом весь сценарий закрывался бы на последнем шаге.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(22);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','51111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-voice@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','54444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-voice@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','teacher-other-voice@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','59999999-9999-9999-9999-999999999999','authenticated','authenticated','owner-b-voice@test.kg','','','','','','','','');

-- Центр Б с поясом, отличным от бишкекского: дата прогресса обязана
-- считаться от занятия в поясе ЦЕНТРА, а не от center_today воркера.
insert into public.centers (id, name, slug, settings) values
  ('5ccccccc-0000-0000-0000-00000000000a','Центр А (голос)','centr-a-voice','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('5ccccccc-0000-0000-0000-00000000000b','Центр Б (голос)','centr-b-voice','{"timezone":"Europe/Lisbon"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('5aaaaaaa-0000-0000-0000-000000000001','5ccccccc-0000-0000-0000-00000000000a','Ведущий специалист'),
  ('5aaaaaaa-0000-0000-0000-000000000002','5ccccccc-0000-0000-0000-00000000000a','Другой специалист');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('5bbbbbbb-0000-0000-0000-000000000001','5ccccccc-0000-0000-0000-00000000000a','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('5ddddddd-0000-0000-0000-000000000001','5ccccccc-0000-0000-0000-00000000000a','Родитель','+996700000501');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('51111111-1111-1111-1111-111111111111','5ccccccc-0000-0000-0000-00000000000a','owner',   null, null),
  ('54444444-4444-4444-4444-444444444444','5ccccccc-0000-0000-0000-00000000000a','teacher','5aaaaaaa-0000-0000-0000-000000000001', null),
  ('55555555-5555-5555-5555-555555555555','5ccccccc-0000-0000-0000-00000000000a','teacher','5aaaaaaa-0000-0000-0000-000000000002', null),
  ('59999999-9999-9999-9999-999999999999','5ccccccc-0000-0000-0000-00000000000b','owner',   null, null);

-- Двое детей на одном занятии: групповое — там и живёт риск записать
-- оценку в цель соседа.
insert into public.students (id, center_id, full_name, payer_id) values
  ('5eeeeeee-0000-0000-0000-000000000001','5ccccccc-0000-0000-0000-00000000000a','Айсулуу','5ddddddd-0000-0000-0000-000000000001'),
  ('5eeeeeee-0000-0000-0000-000000000002','5ccccccc-0000-0000-0000-00000000000a','Бекжан','5ddddddd-0000-0000-0000-000000000001');

insert into public.groups (id, center_id, name) values
  ('5abc0000-0000-0000-0000-000000000001'::uuid,'5ccccccc-0000-0000-0000-00000000000a','Группа голос');

insert into public.group_students (group_id, student_id, center_id) values
  ('5abc0000-0000-0000-0000-000000000001','5eeeeeee-0000-0000-0000-000000000001','5ccccccc-0000-0000-0000-00000000000a'),
  ('5abc0000-0000-0000-0000-000000000001','5eeeeeee-0000-0000-0000-000000000002','5ccccccc-0000-0000-0000-00000000000a');

insert into public.lessons (id, center_id, teacher_id, group_id, service_id, status, starts_at, ends_at) values
  ('5fffffff-0000-0000-0000-000000000001','5ccccccc-0000-0000-0000-00000000000a','5aaaaaaa-0000-0000-0000-000000000001',
   '5abc0000-0000-0000-0000-000000000001','5bbbbbbb-0000-0000-0000-000000000001','planned',
   now() - interval '2 hours', now() - interval '1 hour 15 minutes');

insert into public.telegram_accounts (user_id, chat_id) values
  ('54444444-4444-4444-4444-444444444444', 777001),
  ('55555555-5555-5555-5555-555555555555', 777002);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

select public.tests_claims('51111111-1111-1111-1111-111111111111','5ccccccc-0000-0000-0000-00000000000a');

insert into public.goals (id, center_id, student_id, stage_id, title, status) values
  ('5bbb0000-0000-0000-0000-000000000001','5ccccccc-0000-0000-0000-00000000000a','5eeeeeee-0000-0000-0000-000000000001',
   (select id from public.goal_stages where center_id = '5ccccccc-0000-0000-0000-00000000000a' and code = 'syllables'),
   'Цель Айсулуу','active'),
  ('5bbb0000-0000-0000-0000-000000000002','5ccccccc-0000-0000-0000-00000000000a','5eeeeeee-0000-0000-0000-000000000002',
   (select id from public.goal_stages where center_id = '5ccccccc-0000-0000-0000-00000000000a' and code = 'setting'),
   'Цель Бекжана','active');


-- Выдача токена -------------------------------------------------------------------------------------

select public.tests_claims('54444444-4444-4444-4444-444444444444','5ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select lives_ok(
  $q$ select public.request_voice_note('5fffffff-0000-0000-0000-000000000001','5eeeeeee-0000-0000-0000-000000000001') $q$,
  'Ведущий специалист запрашивает диктовку по своему ребёнку');

-- Содержимое таблицы читаем от postgres: прикладной роли она не видна вовсе,
-- и это ровно то, что проверяет отдельный ассерт в конце файла.
reset role;
select is(
  (select count(*)::int from public.lesson_voice_requests
    where requested_by = '54444444-4444-4444-4444-444444444444' and consumed_at is null and cancelled_at is null),
  1, 'Живой токен ровно один');

set local role authenticated;
select lives_ok(
  $q$ select public.request_voice_note('5fffffff-0000-0000-0000-000000000001','5eeeeeee-0000-0000-0000-000000000001') $q$,
  'Повторный запрос проходит — прежний токен при этом гасится (проверка ниже)');

reset role;
select is(
  (select count(*)::int from public.lesson_voice_requests
    where requested_by = '54444444-4444-4444-4444-444444444444' and consumed_at is null and cancelled_at is null),
  1, 'Живой токен по-прежнему один: выдача нового погасила прежний (Р9)');

select public.tests_claims('55555555-5555-5555-5555-555555555555','5ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.request_voice_note('5fffffff-0000-0000-0000-000000000001','5eeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', null,
  'Специалист без занятий с ребёнком диктовку не запросит');
reset role;


-- Армирование: NULL-ловушка и чужой чат ---------------------------------------------------------------

select public.tests_claims(null, null);

select throws_ok(
  format($q$ select public.arm_voice_request(%L, 777999) $q$,
    (select token from public.lesson_voice_requests
      where requested_by = '54444444-4444-4444-4444-444444444444' and consumed_at is null and cancelled_at is null)),
  '42501', null,
  'Непривязанный чат не армирует запись — это та самая NULL-ловушка');

select throws_ok(
  format($q$ select public.arm_voice_request(%L, 777002) $q$,
    (select token from public.lesson_voice_requests
      where requested_by = '54444444-4444-4444-4444-444444444444' and consumed_at is null and cancelled_at is null)),
  '42501', null,
  'Чат другого пользователя не армирует чужой токен');

select is(
  (select public.arm_voice_request(token, 777001) ->> 'student_name'
     from public.lesson_voice_requests
    where requested_by = '54444444-4444-4444-4444-444444444444' and consumed_at is null and cancelled_at is null),
  'Айсулуу',
  'Свой чат армирует и получает имя ребёнка — ответ бота ловит диктовку не про того');

select throws_ok(
  $q$ select public.arm_voice_request('нет-такого-токена', 777001) $q$,
  '42704', null,
  'Несуществующий токен не армируется');


-- Гашение и событие — одной транзакцией ----------------------------------------------------------------

select lives_ok(
  $q$ select public.report_voice_note(777001, 'file-abc', 42) $q$,
  'Голосовое принято');

select is(
  (select count(*)::int from public.events
    where type = 'lesson.voice_received' and center_id = '5ccccccc-0000-0000-0000-00000000000a'),
  1, 'Событие ровно одно');

select is(
  (select count(*)::int from public.lesson_voice_requests
    where requested_by = '54444444-4444-4444-4444-444444444444' and consumed_at is null and cancelled_at is null),
  0, 'Токен погашен той же транзакцией (Р10)');

select ok(
  (select not (payload ? 'lesson_id') and not (payload ? 'chat_id') and payload ? 'voice_request_id'
     from public.events where type = 'lesson.voice_received'),
  'В payload только ссылка на запрос: занятие и чат туда не попали (Р3)');

select throws_ok(
  $q$ select public.report_voice_note(777001, 'file-abc', 42) $q$,
  '42704', null,
  'Второе голосовое подряд получает человеческий ответ, а не второе событие');


-- Захват работы и запись черновика — в tests/0042.
--
-- 0042 меняет модель: ИИ больше не пишет goal_progress, а предлагает
-- оценки, которые переносит человек при утверждении. Ассерты, фиксировавшие
-- прежнее поведение, переехали туда целиком, чтобы не держать два описания
-- одного и того же в разных файлах.


-- Реестр расхода -------------------------------------------------------------------------------------------

select lives_ok(
  format($q$ select public.ai_usage_record(%s,'transcribe','whisper-1',0,0,120,'1 токен = 0,01 тыйын') $q$,
    (select max(id) from public.events where type = 'lesson.voice_received')),
  'Расход на расшифровку записан отдельным вызовом (Р12)');

select lives_ok(
  format($q$ select public.ai_usage_record(%s,'summary','claude-sonnet-5',1200,300,450,null) $q$,
    (select max(id) from public.events where type = 'lesson.voice_received')),
  'И расход на резюме — тоже отдельно');

select is(
  (select count(*)::int from public.ai_usage), 2,
  'Две строки на занятие: расшифровка и резюме');


-- Права: живая сессия не может ничего из контура воркера ------------------------------------------------------

select public.tests_claims('51111111-1111-1111-1111-111111111111','5ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.ai_write_lesson_note(1, '{}'::jsonb) $q$,
  '42501', null,
  'Владелец не может писать черновик от имени воркера');

select throws_ok(
  $q$ insert into public.ai_usage (center_id, kind) values ('5ccccccc-0000-0000-0000-00000000000a','summary') $q$,
  '42501', null,
  'И не может дописать себе строку расхода — счётчик закрыт на запись');

select is(
  (select count(*)::int from public.ai_usage), 2,
  'Зато видит свой расход: политика на чтение есть');

select throws_ok(
  $q$ select count(*) from public.lesson_voice_requests $q$,
  '42501', null,
  'Таблица токенов не видна прикладной роли вовсе');
reset role;

select public.tests_claims('59999999-9999-9999-9999-999999999999','5ccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select is(
  (select count(*)::int from public.ai_usage), 0,
  'Владелец центра Б чужого расхода не видит');
reset role;

select * from finish();

rollback;
