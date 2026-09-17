-- pgTAP: очередь outbox и планировщики (0032).
--
-- Функции очереди исполняются только вне пользовательской сессии, поэтому
-- перед функциональными блоками claims гасятся явно: reset role их не
-- сбрасывает, и оставленный «владелец» из фикстуры сделал бы все вызовы
-- отказами. Сами вызовы идут от postgres (владельца функций); то, что их
-- исполняет именно bot_worker и не исполняет service_role, проверяется по
-- каталогу прав плюс отдельный вызов от роли в самом конце. Внутри `set
-- local role bot_worker` нельзя звать функции pgTAP: у роли нет usage на
-- схему extensions, поэтому результат складывается во временную таблицу, а
-- ассерт делается уже от postgres.
--
-- Часовой пояс центра выбирается запросом к pg_timezone_names под текущее
-- время: «местные 08:00» иначе делали бы тест зелёным или красным в
-- зависимости от того, в какой час суток его запустил CI.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(48);


-- 1-10. Роль, гранты, индексы -------------------------------------------------------------------

select has_role('bot_worker', 'Роль bot_worker заведена');

select ok(
  not has_table_privilege('bot_worker', 'public.students', 'SELECT')
  and not has_table_privilege('bot_worker', 'public.payers', 'SELECT')
  and not has_table_privilege('bot_worker', 'public.attendance', 'SELECT')
  and not has_table_privilege('bot_worker', 'public.events', 'SELECT'),
  'bot_worker не читает таблицы напрямую — ровно то, чего не даёт service_role (Р2)'
);

select ok(
  has_function_privilege('bot_worker', 'public.claim_events(integer)', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.ack_events(bigint[])', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.fail_events(bigint[],text)', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.release_stale_claims(interval)', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.lesson_reminders()', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.daily_digest()', 'EXECUTE'),
  'bot_worker исполняет все шесть функций очереди и планировщиков'
);

select ok(
  not has_function_privilege('service_role', 'public.claim_events(integer)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.ack_events(bigint[])', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.fail_events(bigint[],text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.release_stale_claims(interval)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.lesson_reminders()', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.daily_digest()', 'EXECUTE'),
  'service_role очередь не исполняет: у него остаются все таблицы (0024), это не его дверь'
);

select ok(
  not has_function_privilege('authenticated', 'public.claim_events(integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.claim_events(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.daily_digest()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.daily_digest()', 'EXECUTE'),
  'Ни anon, ни authenticated очередь не исполняют'
);

select ok(
  has_function_privilege('bot_worker', 'public.installments_notify()', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.installments_notify()', 'EXECUTE'),
  'Вход планировщика переехал с service_role на bot_worker'
);

-- Default privileges Supabase выдают новой таблице ALL роли service_role, а
-- 0024 у него ничего не снимал: без явного revoke обладатель service-ключа
-- удаляет отметку о напоминании (уйдёт второе) или вставляет отметку о
-- дайджесте (не уйдёт ни одного).
select ok(
  not has_table_privilege('service_role', 'public.lesson_reminders_sent', 'INSERT')
  and not has_table_privilege('service_role', 'public.lesson_reminders_sent', 'DELETE')
  and not has_table_privilege('service_role', 'public.center_digest_runs', 'INSERT')
  and not has_table_privilege('service_role', 'public.center_digest_runs', 'DELETE'),
  'service_role не пишет в отметки напоминаний и дайджестов — они закрыты на запись всем'
);

select hasnt_index('public', 'events', 'events_unprocessed_idx',
  'Старый индекс по processed_at снят — выдача упорядочена по id');
select has_index('public', 'events', 'events_pending_idx',
  'Индекс под claim_events на месте');
select has_index('public', 'events', 'events_claimed_idx',
  'Индекс под release_stale_claims на месте — иначе он сканирует всю events');


-- Фикстура ---------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-q@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-b-q@test.kg','','','','','','','','');

-- tz_day: местный час 9..19 — дайджест обязан уйти, а занятие «через час»
-- остаётся в тех же местных сутках. tz_night: местный час меньше 7 (а не 8) —
-- запас, чтобы час не сменился между фикстурой и вызовом дайджеста. Оба пояса
-- есть всегда: смещения Etc/GMT+12..Etc/GMT-14 покрывают все 24 часа.
create temporary table t_tz as
select
  (select name from pg_timezone_names
    where name like 'Etc/GMT%'
      and extract(hour from (now() at time zone name))::int between 9 and 19
    order by name limit 1) as tz_day,
  (select name from pg_timezone_names
    where name like 'Etc/GMT%'
      and extract(hour from (now() at time zone name))::int < 7
    order by name limit 1) as tz_night;

select isnt((select tz_day from t_tz), null, 'Фикстура: нашёлся пояс, где сейчас день');
select isnt((select tz_night from t_tz), null, 'Фикстура: нашёлся пояс, где сейчас раннее утро');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-queue',
   jsonb_build_object('timezone', (select tz_day from t_tz))),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-queue',
   jsonb_build_object('timezone', (select tz_night from t_tz))),
  ('cccccccc-0000-0000-0000-00000000000d','Центр закрытый','centr-d-queue',
   jsonb_build_object('timezone', (select tz_day from t_tz)));

insert into public.memberships (user_id, center_id, role) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner'),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner');

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист А'),
  ('aaaaaaaa-0000-0000-0000-00000000000d','cccccccc-0000-0000-0000-00000000000d','Специалист закрытого центра');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик А','+996700000001'),
  ('dddddddd-0000-0000-0000-00000000000d','cccccccc-0000-0000-0000-00000000000d','Плательщик закрытого центра','+996700000009');

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок с абонементом','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Ребёнок с долгом','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Ребёнок с безлимитом','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-00000000000d','cccccccc-0000-0000-0000-00000000000d','Ребёнок закрытого центра','dddddddd-0000-0000-0000-00000000000d');

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','2 занятия','lessons',2,200000),
  ('77777777-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Безлимит','unlimited',null,500000);

-- L_soon — через час: попадает и в окно напоминания (18 часов), и в «занятия
-- сегодня» дайджеста. L_far — через 30 часов, вне окна. L_cancel — в окне, но
-- отменено. L_past — вчера, на нём отметка без абонемента (долг 70000).
-- L_closed — через час, но в закрытом центре: напоминание уходить не должно.
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('ffffffff-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','planned', now() + interval '1 hour',  now() + interval '1 hour 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000001','planned', now() + interval '30 hours', now() + interval '30 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-000000000001','cancelled', now() + interval '2 hours', now() + interval '2 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000001','planned', now() - interval '1 day',   now() - interval '1 day' + interval '45 minutes'),
  ('ffffffff-0000-0000-0000-00000000000d','cccccccc-0000-0000-0000-00000000000d','aaaaaaaa-0000-0000-0000-00000000000d','eeeeeeee-0000-0000-0000-00000000000d',null,'planned', now() + interval '1 hour',  now() + interval '1 hour 45 minutes');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

-- Абонементы и долг — руками владельца через RPC, как в приложении.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', null, current_date);
select public.sell_subscription('77777777-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000003', null, current_date);
select public.mark_attendance('ffffffff-0000-0000-0000-000000000004', 'eeeeeeee-0000-0000-0000-000000000002');
reset role;

-- Центр закрывается уже после того, как в нём завелись данные: RPC выше
-- отказали бы по членству, а закрытие — обычный soft delete.
update public.centers set deleted_at = now() where id = 'cccccccc-0000-0000-0000-00000000000d';

-- Р7 миграции в миниатюре: всё, что накопила фикстура, в очередь этого
-- теста попадать не должно.
update public.events set processed_at = now() where processed_at is null;

create temporary table t_ev_raw as
  with ins as (
    insert into public.events (center_id, type, payload)
    values
      ('cccccccc-0000-0000-0000-00000000000a', 'test.one',     '{}'::jsonb),
      ('cccccccc-0000-0000-0000-00000000000a', 'test.two',     '{}'::jsonb),
      ('cccccccc-0000-0000-0000-00000000000a', 'test.three',   '{}'::jsonb),
      ('cccccccc-0000-0000-0000-00000000000a', 'test.four',    '{}'::jsonb),
      ('cccccccc-0000-0000-0000-00000000000a', 'event.failed', '{}'::jsonb),
      ('cccccccc-0000-0000-0000-00000000000a', 'test.six',     '{}'::jsonb)
    returning id
  )
  select id from ins;

create temporary table t_ev as
  select row_number() over (order by id) as n, id from t_ev_raw;

-- Дальше пользователя нет: функции очереди исполняются только так.
select public.tests_claims(null, null);


-- 13-27. Очередь -----------------------------------------------------------------------------------

-- row_number over () сохраняет порядок, в котором функция отдала строки:
-- именно он уходит в n8n и определяет порядок сообщений (Р4).
create temporary table t_c1 as
  select row_number() over () as pos, id, type from public.claim_events(2);
create temporary table t_c2 as
  select row_number() over () as pos, id, type from public.claim_events(2);

select results_eq(
  $q$ select type from t_c1 order by pos $q$,
  $q$ values ('test.one'::text), ('test.two'::text) $q$,
  'claim_events отдаёт два события с наименьшими id и именно в этом порядке (Р4)'
);
select results_eq(
  $q$ select type from t_c2 order by pos $q$,
  $q$ values ('test.three'::text), ('test.four'::text) $q$,
  'Второй claim не пересекается с первым и тоже упорядочен'
);
select is((select count(*)::int from public.claim_events(1)), 1,
  'Третий claim с лимитом 1 берёт ровно одно событие');
select is(
  (select count(*)::int from public.events where claimed_at is not null and processed_at is null), 5,
  'Пять событий помечены claimed_at');
select is(
  (select count(*)::int from public.events
    where processed_at is null and claimed_at is null and id = (select id from t_ev where n = 6)), 1,
  'Шестое событие никто не брал — на нём проверяются ack и fail «мимо claim»');

select is(public.ack_events(array[(select id from t_ev where n = 6)]), 0,
  'ack по невзятому событию — ноль: закрыть можно только то, что сам же и взял');
select is(public.fail_events(array[(select id from t_ev where n = 6)], 'мимо'), 0,
  'fail по невзятому событию — ноль');

select is(public.ack_events(array[(select id from t_ev where n = 1)]), 1, 'ack закрывает взятое событие');
select is(public.ack_events(array[(select id from t_ev where n = 1)]), 0,
  'Повторный ack уже закрытого — ноль строк, не ошибка: доставка at-least-once');

select is(public.fail_events(array[(select id from t_ev where n = 2)], 'первая неудача'), 1,
  'fail возвращает событие в очередь');
select is(
  (select attempts::int from public.events where id = (select id from t_ev where n = 2)), 1,
  'После первого fail: attempts = 1');
select is(
  (select claimed_at from public.events where id = (select id from t_ev where n = 2)), null,
  'После fail claimed_at снят — событие снова видно claim_events');

-- Второй и третий заход: обработчик берёт событие снова и снова падает.
-- Пометка claimed_at вместо честного claim_events — чтобы не цеплять
-- остальные события пачкой.
update public.events set claimed_at = now() where id = (select id from t_ev where n = 2);
select public.fail_events(array[(select id from t_ev where n = 2)], 'вторая');
update public.events set claimed_at = now() where id = (select id from t_ev where n = 2);
select public.fail_events(array[(select id from t_ev where n = 2)], 'третья');

select isnt(
  (select processed_at from public.events where id = (select id from t_ev where n = 2)), null,
  'На третьем провале событие уходит в терминал, а не крутится в очереди вечно');
select is(
  (select count(*)::int from public.events
    where type = 'event.failed' and payload->>'event_id' = (select id::text from t_ev where n = 2)),
  1, 'Ровно одно event.failed на исчерпанное событие');

-- Р6: то же самое, но событие само типа event.failed.
update public.events set claimed_at = now() where id = (select id from t_ev where n = 5);
select public.fail_events(array[(select id from t_ev where n = 5)], 'раз');
update public.events set claimed_at = now() where id = (select id from t_ev where n = 5);
select public.fail_events(array[(select id from t_ev where n = 5)], 'два');
update public.events set claimed_at = now() where id = (select id from t_ev where n = 5);
select public.fail_events(array[(select id from t_ev where n = 5)], 'три');

select is(
  (select count(*)::int from public.events
    where type = 'event.failed' and payload->>'event_id' = (select id::text from t_ev where n = 5)),
  0, 'Исчерпанный event.failed не породил следующий event.failed — иначе очередь растёт из себя (Р6)');


-- 28-33. Зависшая пачка и отказы ---------------------------------------------------------------------

update public.events set claimed_at = now() - interval '1 hour'
 where id = (select id from t_ev where n = 3);

select is(public.release_stale_claims('10 minutes'), 1, 'Зависшая пачка возвращается в очередь');
select is(
  (select attempts::int from public.events where id = (select id from t_ev where n = 3)), 1,
  'release_stale_claims растит attempts — иначе строка, на которой обработчик падает по таймауту, возвращается вечно (Р5)');

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok($q$ select * from public.claim_events(10) $q$, '42501', null,
  'Залогиненный пользователь очередь не читает');
select throws_ok($q$ select * from public.daily_digest() $q$, '42501', null,
  'Залогиненный пользователь дайджест не запускает');
reset role;
select public.tests_claims(null, null);

select throws_ok($q$ select * from public.claim_events(0) $q$, '22023', null, 'Размер пачки 0 — отказ');
select throws_ok($q$ select * from public.claim_events(501) $q$, '22023', null, 'Размер пачки 501 — отказ');


-- 34-43. Напоминания о занятии ---------------------------------------------------------------------

select is((select sent_count from public.lesson_reminders()), 1,
  'Напоминание уходит по одному занятию: далёкое, отменённое, прошедшее и занятие закрытого центра не в счёт');
select is((select sent_count from public.lesson_reminders()), 0,
  'Второй вызов — ноль: первичный ключ lesson_reminders_sent и есть инвариант (Р8)');
select is(
  (select count(*)::int from public.lesson_reminders_sent), 1,
  'В lesson_reminders_sent ровно одна строка');
select is(
  (select lesson_id from public.lesson_reminders_sent), 'ffffffff-0000-0000-0000-000000000001'::uuid,
  'Отмечено именно ближайшее занятие действующего центра');
select is(
  (select count(*)::int from public.events where type = 'lesson.reminder'), 1,
  'Одно событие lesson.reminder');
select is(
  (select payload->>'lesson_id' from public.events where type = 'lesson.reminder'),
  'ffffffff-0000-0000-0000-000000000001',
  'В payload — то же занятие');

select throws_ok(
  $q$ insert into public.lesson_reminders_sent (lesson_id, center_id)
      values ('ffffffff-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-00000000000b') $q$,
  '23503', null,
  'Занятие одного центра с center_id другого не проходит: составной FK, как после 0022');

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ insert into public.lesson_reminders_sent (lesson_id, center_id)
      values ('ffffffff-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-00000000000a') $q$,
  '42501', null,
  'Отметку о напоминании нельзя подделать: гранта на запись нет ни у кого (Р8)');
select is((select count(*)::int from public.lesson_reminders_sent), 1,
  'Владелец свою строку видит');
reset role;

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select is((select count(*)::int from public.lesson_reminders_sent), 0,
  'Чужой центр отметок не видит');
reset role;
select public.tests_claims(null, null);


-- 44-47. Дайджест ------------------------------------------------------------------------------------

select is((select center_count from public.daily_digest()), 1,
  'Дайджест уходит одному центру: у второго местный час меньше восьми, третий закрыт');
select is((select center_count from public.daily_digest()), 0,
  'Второй запуск в тот же день — ноль: center_digest_runs держит инвариант (Р9)');
select is(
  (select center_id from public.center_digest_runs), 'cccccccc-0000-0000-0000-00000000000a'::uuid,
  'Отметка о дайджесте — только у центра А');
select is(
  (select jsonb_build_object(
            'lessons_today', payload->'lessons_today',
            'low_balance', payload->'low_balance',
            'debt_tiyin', payload->'debt_tiyin',
            'installments_overdue', payload->'installments_overdue')
     from public.events where type = 'digest.daily'),
  jsonb_build_object(
    'lessons_today', to_jsonb(1),
    'low_balance', to_jsonb(1),
    'debt_tiyin', to_jsonb(70000),
    'installments_overdue', to_jsonb(0)),
  'Сводка считает: одно занятие сегодня, один заканчивающийся абонемент (безлимит не в счёт), долг 70000, просрочек нет'
);


-- 48. Та же дверь, но от самой роли ------------------------------------------------------------------

-- Каталог прав выше говорит, что bot_worker исполняет функции; этот вызов
-- проверяет путь целиком, включая членство authenticator. Ассерт — уже от
-- postgres: у bot_worker нет usage на схему extensions, где живёт pgTAP.
set local role bot_worker;
create temporary table t_smoke as select count(*)::int as n from public.claim_events(10);
reset role;

select cmp_ok((select n from t_smoke), '>=', 1,
  'bot_worker действительно исполняет claim_events, а не только числится в грантах');

select * from finish();

rollback;
