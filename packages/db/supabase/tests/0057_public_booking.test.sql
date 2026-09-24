-- pgTAP: публичная витрина записи /book/[slug] (0057).
--
-- Заборы: booking_requests закрыта от anon/authenticated (только select у
-- authenticated), под readonly-guard, в export_center_tables(). Роль
-- public_booking не имеет ни одного табличного гранта, только execute на
-- три функции витрины. booking_center_info/booking_teacher_busy —
-- found=false/пусто одинаково для неизвестного slug, неопубликованного,
-- read-only и удалённого центра; никакого PII в ответе; teacher чужого
-- центра не виден. submit_booking_request — не трогает students/lessons/
-- payers; телефон нормализуется; rate limit по телефону и по центру;
-- сессия отбивается (эта функция — только для public_booking, у которой
-- сессии не бывает). confirm/decline — только can_front_desk(); двойное
-- подтверждение не создаёт двух уроков; матчинг с плательщиком — только
-- явным p_payer_id, не автоматом; конфликт слота — тот же контракт 23P01 с
-- detail, что и остальное расписание.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(47);


-- 1. Заборы по каталогу (до любого tests_claims()/set role) ----------------------------------------

select ok(
  has_table_privilege('authenticated', 'public.booking_requests', 'SELECT')
  and not has_table_privilege('authenticated', 'public.booking_requests', 'INSERT')
  and not has_table_privilege('authenticated', 'public.booking_requests', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.booking_requests', 'DELETE'),
  'booking_requests: authenticated только SELECT — подача/подтверждение/отклонение только через RPC');

select ok(
  not has_table_privilege('anon', 'public.booking_requests', 'SELECT')
  and not has_table_privilege('anon', 'public.booking_requests', 'INSERT'),
  'booking_requests: anon вообще без прав');

select ok(
  not has_table_privilege('public_booking', 'public.booking_requests', 'SELECT')
  and not has_table_privilege('public_booking', 'public.students', 'SELECT')
  and not has_table_privilege('public_booking', 'public.payers', 'SELECT')
  and not has_table_privilege('public_booking', 'public.lessons', 'SELECT')
  and not has_table_privilege('public_booking', 'public.centers', 'SELECT'),
  'public_booking не читает ни одной таблицы напрямую (образец — bot_worker, 0032)');

select set_eq(
  $$ select p.oid::regprocedure::text
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind in ('f','p')
        and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
        and has_function_privilege('public_booking', p.oid, 'EXECUTE') $$,
  $$ values
    ('booking_center_info(text)'),
    ('booking_teacher_busy(text,uuid,date)'),
    ('submit_booking_request(text,uuid,uuid,timestamp with time zone,text,text,text)') $$,
  'public_booking исполняет только три функции витрины, ни одной больше');

select ok(
  exists (select 1 from pg_trigger tg
           where tg.tgrelid = 'public.booking_requests'::regclass and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal),
  'booking_requests под readonly guard — обычная таблица центра (Р12)');

-- Реальная защита — гранты (проверены выше): apply_tenant_rls создаёt
-- политику tenant_admin "for all" (cmd='ALL'), IN ('INSERT','UPDATE',
-- 'DELETE') её не поймал бы — проверять отдельно нечего, без грантов
-- политика не открывает ничего (архитектор, раунд 3, замечание к тесту).

select ok(
  exists (select 1 from public.export_center_tables() x where x.table_name = 'booking_requests'),
  'booking_requests в allow-list экспорта (Р14) — текст заявки те же персональные данные, что students');


-- Фикстура -------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0570000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0057@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0570000-0000-0000-0000-000000000002','authenticated','authenticated','registrar-0057@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0570000-0000-0000-0000-000000000003','authenticated','authenticated','teacher-0057@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0570000-0000-0000-0000-0000000000c1','Центр А 0057','centr-a-0057','{"timezone":"Asia/Bishkek","booking_enabled":true}'::jsonb),
  ('a0570000-0000-0000-0000-0000000000c2','Центр Б 0057 (не опубликован)','centr-b-0057','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0570000-0000-0000-0000-000000000010','a0570000-0000-0000-0000-0000000000c1','Специалист 0057','a0570000-0000-0000-0000-000000000003'),
  ('a0570000-0000-0000-0000-000000000011','a0570000-0000-0000-0000-0000000000c2','Специалист Б 0057', null);

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('a0570000-0000-0000-0000-000000000020','a0570000-0000-0000-0000-0000000000c1','Логопед',45,70000);

insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('a0570000-0000-0000-0000-000000000001','a0570000-0000-0000-0000-0000000000c1','owner', null),
  ('a0570000-0000-0000-0000-000000000002','a0570000-0000-0000-0000-0000000000c1','registrar', null),
  ('a0570000-0000-0000-0000-000000000003','a0570000-0000-0000-0000-0000000000c1','teacher','a0570000-0000-0000-0000-000000000010');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. booking_center_info / booking_teacher_busy (без сессии — как настоящий public_booking) ----------

select public.tests_claims(null, null);

select is(
  (select found from public.booking_center_info('centr-a-0057')), true,
  'Опубликованный центр — found=true');
select is(
  (select found from public.booking_center_info('net-takogo-slug')), false,
  'Неизвестный slug — found=false');
select is(
  (select found from public.booking_center_info('centr-b-0057')), false,
  'Центр без booking_enabled — found=false, неотличимо от неизвестного slug (Р4)');
select is(
  (select jsonb_array_length(teachers) from public.booking_center_info('centr-a-0057')), 1,
  'Только активные специалисты опубликованного центра');
select ok(
  (select services -> 0 ? 'duration_min' and not (services -> 0 ? 'default_price_tiyin')
     from public.booking_center_info('centr-a-0057')),
  'В карточке услуги нет прайса/лишних полей — только id/name/duration_min');

select is(
  (select count(*)::int from public.booking_teacher_busy('centr-a-0057', 'a0570000-0000-0000-0000-000000000011', public.center_today('a0570000-0000-0000-0000-0000000000c1'))),
  0,
  'Специалист чужого центра при чужом slug — пусто (не оракул)');
select is(
  (select count(*)::int from public.booking_teacher_busy('centr-a-0057', 'a0570000-0000-0000-0000-000000000010', public.center_today('a0570000-0000-0000-0000-0000000000c1') + 200)),
  0,
  'Дата дальше 90 дней — пусто');

select throws_ok(
  $q$ select public.tests_claims('a0570000-0000-0000-0000-000000000001', 'a0570000-0000-0000-0000-0000000000c1');
      select * from public.booking_center_info('centr-a-0057') $q$,
  '42501', null, 'booking_center_info с живой сессией — отказ (защита в глубину, Р2)');
select public.tests_claims(null, null);


-- 3. submit_booking_request: подача, нормализация телефона, лимиты, изоляция от students/lessons -----

select is(
  (select count(*)::int from public.students), 0, 'До подачи заявок students пуст');
select is(
  (select count(*)::int from public.lessons), 0, 'До подачи заявок lessons пуст');

select lives_ok(
  $q$ select public.submit_booking_request(
        'centr-a-0057', 'a0570000-0000-0000-0000-000000000020', 'a0570000-0000-0000-0000-000000000010',
        now() + interval '2 days', 'Ребёнок 1', 'Родитель 1', '0700111001') $q$,
  'Первая заявка проходит');

select is(
  (select count(*)::int from public.students), 0, 'submit_booking_request не создаёт students (Р1)');
select is(
  (select count(*)::int from public.lessons), 0, 'submit_booking_request не создаёт lessons (Р1)');
select is(
  (select parent_phone from public.booking_requests order by created_at desc limit 1), '+996700111001',
  'Телефон хранится нормализованным (Р6) — 0700111001 стал +996700111001');
select is(
  (select ends_at - starts_at from public.booking_requests order by created_at desc limit 1), interval '45 minutes',
  'ends_at считается из services.duration_min, не приходит от клиента (Р7)');

select throws_ok(
  $q$ select public.submit_booking_request(
        'centr-a-0057', 'a0570000-0000-0000-0000-000000000020', 'a0570000-0000-0000-0000-000000000010',
        now() + interval '5 minutes', 'Ребёнок', 'Родитель', '0700111002') $q$,
  '22023', null, 'Слот раньше чем через 30 минут — отказ');

select throws_ok(
  $q$ select public.submit_booking_request(
        'net-takogo-slug', 'a0570000-0000-0000-0000-000000000020', 'a0570000-0000-0000-0000-000000000010',
        now() + interval '2 days', 'Ребёнок', 'Родитель', '0700111003') $q$,
  '22023', null, 'Неизвестный slug — тот же общий отказ, не отдельная причина (Р4)');

-- Та же семья: до лимита (3/час) включительно — проходит, следующая — нет.
-- Первая заявка уже учтена выше, значит до предела осталось две.
select lives_ok(
  $q$ select public.submit_booking_request(
        'centr-a-0057', 'a0570000-0000-0000-0000-000000000020', 'a0570000-0000-0000-0000-000000000010',
        now() + interval '3 days', 'Ребёнок 1', 'Родитель 1', '+996 700 11-10-01') $q$,
  'Второе написание того же номера — тот же нормализованный телефон, вторая заявка проходит');
select lives_ok(
  $q$ select public.submit_booking_request(
        'centr-a-0057', 'a0570000-0000-0000-0000-000000000020', 'a0570000-0000-0000-0000-000000000010',
        now() + interval '4 days', 'Ребёнок 1', 'Родитель 1', '996700111001') $q$,
  'Третья заявка с того же номера — ровно на пределе (2 существующих < 3), ещё проходит');
select throws_ok(
  $q$ select public.submit_booking_request(
        'centr-a-0057', 'a0570000-0000-0000-0000-000000000020', 'a0570000-0000-0000-0000-000000000010',
        now() + interval '5 days', 'Ребёнок 1', 'Родитель 1', '0700-111-001') $q$,
  '22023', null, 'Четвёртая заявка с того же номера за час — лимит на телефон (Р8)');

select throws_ok(
  $q$ select public.submit_booking_request(
        'centr-a-0057', 'a0570000-0000-0000-0000-000000000020', 'a0570000-0000-0000-0000-000000000010',
        now() + interval '2 days', 'Ребёнок', 'Родитель', 'not-a-phone') $q$,
  '22023', null, 'Нераспознанный формат телефона — отказ, не NULL молча');

select throws_ok(
  $q$ select public.tests_claims('a0570000-0000-0000-0000-000000000001', 'a0570000-0000-0000-0000-0000000000c1');
      select public.submit_booking_request(
        'centr-a-0057', 'a0570000-0000-0000-0000-000000000020', 'a0570000-0000-0000-0000-000000000010',
        now() + interval '2 days', 'Ребёнок', 'Родитель', '0700199999') $q$,
  '42501', null, 'submit_booking_request с живой сессией — отказ (эта функция только для public_booking)');
select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.events where type = 'booking.requested'),
  3,
  'На каждую успешную заявку — ровно одно событие booking.requested (после трёх успешных подач)');


-- 4. Подтверждение/отклонение (стойка) ------------------------------------------------------------

select public.tests_claims('a0570000-0000-0000-0000-000000000003','a0570000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.confirm_booking_request((select id from public.booking_requests limit 1)) $q$,
  '42501', null, 'teacher не подтверждает заявки (can_front_desk)');
reset role;

select public.tests_claims('a0570000-0000-0000-0000-000000000002','a0570000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- Все три заявки вставлены в одной транзакции — created_at у них
-- идентичен (now() заморожен), order by created_at не детерминирован
-- (архитектор, раунд 3). starts_at — единственный столбец, где заявки
-- различаются: выбираем явно первую (interval '2 days').
create temporary table t0057_req as
  select id from public.booking_requests
   where starts_at = (select min(starts_at) from public.booking_requests);

select is(
  (select count(*)::int from public.booking_request_payer_match((select id from t0057_req))), 0,
  'Совпадения по телефону нет — плательщика с таким номером в центре ещё не было');

create temporary table t0057_confirm as
  select * from public.confirm_booking_request((select id from t0057_req));

select is((select count(*)::int from t0057_confirm), 1, 'confirm_booking_request вернул одну строку student_id/lesson_id');
select ok((select student_id is not null and lesson_id is not null from t0057_confirm), 'И student_id, и lesson_id заполнены');
select is(
  (select status from public.booking_requests where id = (select id from t0057_req)), 'confirmed',
  'Заявка помечена confirmed');
select is(
  (select funnel_stage from public.students where id = (select student_id from t0057_confirm)), 'lead',
  'Созданный ученик — funnel_stage lead, status active (воронка, не students.status)');
select is(
  (select count(*)::int from public.lessons where student_id = (select student_id from t0057_confirm)), 1,
  'Ровно один урок создан из заявки');

select throws_ok(
  $q$ select public.confirm_booking_request((select id from t0057_req)) $q$,
  '22023', null, 'Повторное подтверждение той же заявки — «уже обработана», второго урока нет (Р13)');
select is(
  (select count(*)::int from public.lessons where student_id = (select student_id from t0057_confirm)), 1,
  'После повторной попытки урок по-прежнему один');

-- Вторая заявка того же родителя (starts_at = now() + interval '3 days' —
-- now() заморожен транзакцией, значение совпадает бит-в-бит со вставкой
-- выше) — теперь есть совпадение по плательщику.
create temporary table t0057_req2 as
  select id from public.booking_requests where starts_at = now() + interval '3 days';

select is(
  (select count(*)::int from public.booking_request_payer_match((select id from t0057_req2))), 1,
  'Вторая заявка того же родителя — теперь есть совпадение по телефону (плательщик уже создан первым подтверждением)');

select lives_ok(
  $q$ select public.decline_booking_request((select id from t0057_req2), 'дубль') $q$,
  'decline_booking_request проходит на валидной новой заявке');
select is(
  (select status from public.booking_requests where id = (select id from t0057_req2)), 'declined',
  'Вторая заявка отклонена');
select is(
  (select count(*)::int from public.students), 1,
  'Отклонённая заявка не создала второго ученика — students по-прежнему одна запись');

reset role;


-- 5. Доставка booking.requested: получатели, выключенный канал, межцентровый payload ----------------
-- (регрессия на баг 0034/0037 Р2 — is_active в фильтре до order by давал
-- побег на дефолт вместо «не слать»; тот же приём здесь скопирован в
-- notification_front_desk_targets и должен вести себя так же правильно)

select public.tests_claims(null, null);

select set_eq(
  $q$ select recipient_user_id::text || ':' || channel
       from public.event_messages((select min(id) from public.events
                                     where type = 'booking.requested'
                                       and (payload ->> 'request_id')::uuid = (select id from t0057_req2))) $q$,
  $$ values
    ('a0570000-0000-0000-0000-000000000001:whatsapp_link'),
    ('a0570000-0000-0000-0000-000000000002:whatsapp_link') $$,
  'Получатели — owner и registrar (Р11), teacher не входит; без telegram_accounts канал — whatsapp_link у обоих');

select ok(
  (select message like '%Ребёнок 1%' and message like '%Специалист 0057%' and message like '%700111001%'
     from public.event_messages((select min(id) from public.events
                                   where type = 'booking.requested'
                                     and (payload ->> 'request_id')::uuid = (select id from t0057_req2)))
    limit 1),
  '{child}/{teacher}/{phone} подставлены из самой заявки, не из payload события');

select public.tests_claims('a0570000-0000-0000-0000-000000000001','a0570000-0000-0000-0000-0000000000c1');
set local role authenticated;
select ok(
  (select public.upsert_message_template('booking.requested', 'whatsapp_link', 'тихо', false) is not null),
  'Центр выключает канал whatsapp_link для booking.requested');
reset role;
select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.event_messages((select min(id) from public.events
                                                       where type = 'booking.requested'
                                                         and (payload ->> 'request_id')::uuid = (select id from t0057_req)))),
  0,
  'Выключенный канал — event_messages отдаёт пусто, а не дефолтный шаблон платформы (регрессия 0037 Р2)');

-- Событие с чужим center_id и payload, указывающим на заявку центра А —
-- фильтр по center_id внутри event_messages должен отбить чтение чужого
-- центра, даже если payload это позволял бы (payload не доверенный ключ).
insert into public.events (center_id, type, payload)
values ('a0570000-0000-0000-0000-0000000000c2', 'booking.requested',
        jsonb_build_object('request_id', (select id from t0057_req), 'teacher_id', 'a0570000-0000-0000-0000-000000000011',
                            'service_id', 'a0570000-0000-0000-0000-000000000020', 'starts_at', now()));

select is(
  (select count(*)::int from public.event_messages((select max(id) from public.events where center_id = 'a0570000-0000-0000-0000-0000000000c2' and type = 'booking.requested'))),
  0,
  'Событие с center_id чужого центра и payload, указывающим на заявку другого — пусто, не чужие персональные данные');

select * from finish();
rollback;
