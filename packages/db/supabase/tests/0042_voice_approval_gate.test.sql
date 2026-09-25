-- pgTAP: голосовое резюме занятия после исправления блокеров (0042).
--
-- Файл заменяет 0041-й набор: модель изменилась — ИИ больше не пишет
-- goal_progress, а предлагает оценки, которые переносит человек.
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

select plan(45);


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
  ('00000000-0000-0000-0000-000000000000','57777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-voice@test.kg','','','','','','','',''),
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
  ('57777777-7777-7777-7777-777777777777','5ccccccc-0000-0000-0000-00000000000a','parent',  null, '5ddddddd-0000-0000-0000-000000000001'),
  ('59999999-9999-9999-9999-999999999999','5ccccccc-0000-0000-0000-00000000000b','owner',   null, null);

-- Двое детей на одном занятии: групповое — там и живёт риск записать
-- оценку в цель соседа.
insert into public.students (id, center_id, full_name, payer_id) values
  ('5eeeeeee-0000-0000-0000-000000000001','5ccccccc-0000-0000-0000-00000000000a','Айсулуу','5ddddddd-0000-0000-0000-000000000001'),
  ('5eeeeeee-0000-0000-0000-000000000002','5ccccccc-0000-0000-0000-00000000000a','Бекжан','5ddddddd-0000-0000-0000-000000000001');

insert into public.groups (id, center_id, name) values
  ('5abc0000-0000-0000-0000-000000000001'::uuid,'5ccccccc-0000-0000-0000-00000000000a','Группа голос');

-- joined_at закреплён явно, не default current_date: starts_at ниже — от
-- now() с отрицательным интервалом, и CI, стартовавший между 00:00 и
-- 02:00 UTC, сдвигает starts_at::date на вчера, а joined_at остался бы
-- today — ребёнок молча выпадает из lesson_participants (0007).
insert into public.group_students (group_id, student_id, center_id, joined_at) values
  ('5abc0000-0000-0000-0000-000000000001','5eeeeeee-0000-0000-0000-000000000001','5ccccccc-0000-0000-0000-00000000000a', current_date - 7),
  ('5abc0000-0000-0000-0000-000000000001','5eeeeeee-0000-0000-0000-000000000002','5ccccccc-0000-0000-0000-00000000000a', current_date - 7);

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


-- Захват работы: повтор не платит ------------------------------------------------------------------------

update public.events set claimed_at = now() where type = 'lesson.voice_received';

select ok(
  (select public.ai_job_begin(id) ->> 'file_id' = 'file-abc'
     from public.events where type = 'lesson.voice_received'),
  'ai_job_begin отдаёт файл и занимает работу');

select ok(
  (select public.ai_job_begin(id) is null
     from public.events where type = 'lesson.voice_received'),
  'Пока прогон свеж, второй обработчик получает отказ — иначе release_stale_claims платит дважды (В2)');

select lives_ok(
  $q$ select public.ai_job_fail((select id from public.events where type = 'lesson.voice_received'), 'тест') $q$,
  'Детерминированный отказ ставит терминальный статус');

select ok(
  (select public.ai_job_begin(id) is null
     from public.events where type = 'lesson.voice_received'),
  'После ai_job_fail работа не начинается заново — повтор не платит (Р4)');


-- Запись черновика: автор, цели, деньги --------------------------------------------------------------------

-- Новая диктовка, чтобы писать по живому запросу.
select public.tests_claims('54444444-4444-4444-4444-444444444444','5ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select public.request_voice_note('5fffffff-0000-0000-0000-000000000001','5eeeeeee-0000-0000-0000-000000000001');
reset role;

select public.tests_claims(null, null);
select public.arm_voice_request(
  (select token from public.lesson_voice_requests where consumed_at is null and cancelled_at is null), 777001);
select public.report_voice_note(777001, 'file-two', 30);
update public.events set claimed_at = now() where claimed_at is null and type = 'lesson.voice_received';

select throws_ok(
  format($q$ select public.ai_write_lesson_note(%s, '{"soap":{},"nonsense":1}'::jsonb) $q$,
    (select max(id) from public.events where type = 'lesson.voice_received')),
  '22023', null,
  'Неизвестный ключ в ответе модели — явная ошибка с его именем');

select throws_ok(
  format($q$ select public.ai_write_lesson_note(%s,
            jsonb_build_object('goals', jsonb_build_array(
              jsonb_build_object('goal_id','5bbb0000-0000-0000-0000-000000000002','score',50)))) $q$,
    (select max(id) from public.events where type = 'lesson.voice_received')),
  '42704', null,
  'Цель ДРУГОГО ребёнка того же группового занятия — отказ (Р5)');

select is(
  (select count(*)::int from public.lesson_note_goal_scores
    where goal_id = '5bbb0000-0000-0000-0000-000000000002'),
  0, 'И ни одного предложения по чужой цели не появилось');

-- Один вызов со всеми случаями сразу: после первой успешной записи
-- следующие уходят в ветку повтора и целей уже не разбирают.
select lives_ok(
  format($q$ select public.ai_write_lesson_note(%s,
            jsonb_build_object(
              'soap', '{"plan":"слоги"}'::jsonb,
              'parent_summary', 'Сегодня хорошо получались слоги.',
              'raw_transcript', 'расшифровка',
              'model', 'claude-sonnet-5',
              'tokens_in', 1200, 'tokens_out', 300, 'cost_tiyin', 450,
              'goals', jsonb_build_array(
                jsonb_build_object('goal_id','5bbb0000-0000-0000-0000-000000000001','score',59.6),
                jsonb_build_object('goal_id','5bbb0000-0000-0000-0000-000000000001','score',500)))) $q$,
    (select max(id) from public.events where type = 'lesson.voice_received')),
  'Черновик записан');

select is(
  (select score from public.lesson_note_goal_scores
    where goal_id = '5bbb0000-0000-0000-0000-000000000001'),
  60, 'Дробная оценка округляется, а не отбрасывается и не роняет запись');

select is(
  (select count(*)::int from public.lesson_note_goal_scores
    where goal_id = '5bbb0000-0000-0000-0000-000000000001'),
  1, 'Оценка вне 0–100 пропущена — но оплаченная заметка цела (В8)');

select is(
  (select created_by from public.lesson_notes where source = 'voice'),
  '54444444-4444-4444-4444-444444444444'::uuid,
  'Автор черновика — заказчик диктовки, а не NULL (Р2)');

select is(
  (select status from public.lesson_notes where source = 'voice'),
  'draft', 'Черновик, а не утверждённая заметка');


-- Главное в 7b: оценка модели не доходит до родителя без человека ------------------------------------

select is(
  (select count(*)::int from public.goal_progress where goal_id = '5bbb0000-0000-0000-0000-000000000001'),
  0, 'До утверждения ИИ не написал в goal_progress ни строки (Б1)');

select is(
  (select count(*)::int from public.lesson_note_goal_scores
    where goal_id = '5bbb0000-0000-0000-0000-000000000001'),
  1, 'Предложение лежит отдельно и ждёт человека');

-- Родитель видит витрину прогресса — и там пока пусто по этой цели.
select public.tests_claims('57777777-7777-7777-7777-777777777777','5ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select last_score from public.student_goals_brief('5eeeeeee-0000-0000-0000-000000000001')
    where id = '5bbb0000-0000-0000-0000-000000000001'),
  null,
  'Родителю оценка модели не видна: last_score пуст, пока заметку не утвердили');
reset role;


-- САМЫЙ ВАЖНЫЙ: специалист утверждает собственный надиктованный черновик ------------------------------

select public.tests_claims('54444444-4444-4444-4444-444444444444','5ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select lives_ok(
  $q$ select public.approve_lesson_note((select id from public.lesson_notes where source = 'voice')) $q$,
  'Специалист утверждает собственный надиктованный черновик — на этом весь 7b и закрывался бы');

select is(
  (select status from public.lesson_notes where source = 'voice'),
  'approved', 'И заметка действительно утверждена');
reset role;

select is(
  (select score from public.goal_progress where goal_id = '5bbb0000-0000-0000-0000-000000000001'),
  60, 'Только теперь оценка переехала в прогресс — после человека');

select is(
  (select date from public.goal_progress where goal_id = '5bbb0000-0000-0000-0000-000000000001'),
  (select (l.starts_at at time zone 'Asia/Bishkek')::date from public.lessons l
    where l.id = '5fffffff-0000-0000-0000-000000000001'),
  'Дата прогресса — день занятия в поясе центра, не сегодняшняя дата воркера');


-- Идемпотентность ------------------------------------------------------------------------------------------

select public.tests_claims(null, null);

select throws_ok(
  format($q$ select public.ai_write_lesson_note(%s, '{"parent_summary":"ещё раз"}'::jsonb) $q$,
    (select max(id) from public.events where type = 'lesson.voice_received')),
  '23514', null,
  'В утверждённую заметку ИИ уже не пишет');

select is(
  (select count(*)::int from public.goal_progress where goal_id = '5bbb0000-0000-0000-0000-000000000001'),
  1, 'Прогресс по цели остался один — повтор не добавил второй точки');

-- Утверждение — действие человека: клеймы воркера тут не годятся.
select public.tests_claims('54444444-4444-4444-4444-444444444444','5ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.approve_lesson_note((select id from public.lesson_notes where source = 'voice')) $q$,
  'Повторное утверждение — холостой ход, а не ошибка');
reset role;
select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.goal_progress where goal_id = '5bbb0000-0000-0000-0000-000000000001'),
  1, 'И второй точки от повторного утверждения тоже не появилось');


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
