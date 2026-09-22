-- pgTAP: только чтение при истёкшей подписке (0050).
--
-- Забор в начале: каждая базовая таблица public либо под a00_readonly_guard,
-- либо в списке исключений; таблицы без center_id и с nullable center_id
-- зафиксированы поимённо. Главный путь — definer-RPC от сессии
-- просроченного центра; прямой PATCH; отзыв доступа сотруднику с гашением
-- карточки; приём приглашения закрыт; разблокировка платформой; owner не
-- заперт; воркер без сессии проходит; fail closed на пустых датах; порядок
-- причин с лимитом; строка платформы (center_id null) — отказ прав, не режима;
-- граница дня через center_writable и center_limits.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(43);


-- 1. Заборы по каталогу -----------------------------------------------------------------------------

select is_empty(
  $$ select t.table_name
       from information_schema.tables t
      where t.table_schema = 'public' and t.table_type = 'BASE TABLE'
        and t.table_name not in (select x.table_name from public.readonly_guard_exempt_tables() x)
        and not exists (
          select 1 from pg_trigger tg
           where tg.tgrelid = ('public.' || t.table_name)::regclass and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal) $$,
  'Каждая базовая таблица public либо под guard, либо в явном списке исключений (Р7)');

select is_empty(
  $$ select x.table_name from public.readonly_guard_exempt_tables() x
      where not exists (select 1 from information_schema.tables t where t.table_schema = 'public' and t.table_name = x.table_name) $$,
  'Список исключений не протух: все его таблицы существуют');

select is_empty(
  $$ select x.table_name from public.readonly_guard_exempt_tables() x
      where exists (select 1 from pg_trigger tg
                     where tg.tgrelid = ('public.' || x.table_name)::regclass and tg.tgname = 'a00_readonly_guard') $$,
  'На исключённых таблицах guard не стоит');

select set_eq(
  $$ select c.table_name from information_schema.columns c
       join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
      where c.table_schema = 'public' and c.column_name = 'center_id' and c.is_nullable = 'YES' $$,
  $$ values ('audit_log'), ('message_templates'), ('exercise_library') $$,
  'Таблицы с nullable center_id — ровно три; новая такая роняет CI и требует решения (Р6)');

select set_eq(
  $$ select t.table_name from information_schema.tables t
      where t.table_schema = 'public' and t.table_type = 'BASE TABLE'
        and not exists (select 1 from information_schema.columns c
                         where c.table_schema = 'public' and c.table_name = t.table_name and c.column_name = 'center_id') $$,
  $$ values ('centers'), ('plans'), ('platform_admins'), ('notification_event_types'), ('telegram_accounts'), ('telegram_link_codes') $$,
  'Таблицы без center_id — ровно шесть, все в списке исключений с причиной; новая требует решения (Р7)');

-- Р4: memberships/invitations — только insert. tgtype: 1 = ROW, 2 = BEFORE,
-- 4 = INSERT, 8 = DELETE, 16 = UPDATE — время и уровень тоже под забором,
-- иначе AFTER или FOR EACH STATEMENT прошли бы проверку по операциям.
select is(
  (select string_agg(
       case when tg.tgtype & 2 > 0 and tg.tgtype & 1 > 0 then 'before-row:' else 'wrong:' end
       || case when tg.tgtype & 4 > 0 then 'i' else '' end || case when tg.tgtype & 16 > 0 then 'u' else '' end || case when tg.tgtype & 8 > 0 then 'd' else '' end,
       ',' order by tg.tgrelid::regclass::text)
     from pg_trigger tg where tg.tgname = 'a00_readonly_guard' and tg.tgrelid in ('public.memberships'::regclass, 'public.invitations'::regclass)),
  'before-row:i,before-row:i', 'memberships и invitations — BEFORE ROW guard только на insert (Р4)');

select is(
  (select count(*)::int from pg_trigger tg where tg.tgname = 'a00_readonly_guard'
     and tg.tgrelid not in ('public.memberships'::regclass, 'public.invitations'::regclass)
     and not (tg.tgtype & 2 > 0 and tg.tgtype & 1 > 0 and tg.tgtype & 4 > 0 and tg.tgtype & 16 > 0 and tg.tgtype & 8 > 0)),
  0, 'На остальных таблицах guard — BEFORE ROW на insert, update и delete (Р8/Р13)');


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0500000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0050@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0500000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-0050@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0500000-0000-0000-0000-000000000003','authenticated','authenticated','platform-0050@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0500000-0000-0000-0000-000000000004','authenticated','authenticated','invitee-0050@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0500000-0000-0000-0000-000000000005','authenticated','authenticated','owner-b-0050@test.kg','','','','','','','','');
update auth.users set email_confirmed_at = now() where id = 'a0500000-0000-0000-0000-000000000003';
insert into public.platform_admins (email) values ('platform-0050@test.kg');

-- Центр А — просроченный solo (истёк позавчера); центр Б — живой trial.
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('a0500000-0000-0000-0000-0000000000c1','Центр 0050 просрочен','centr-0050-a','solo', now() - interval '2 days','{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, settings) values
  ('a0500000-0000-0000-0000-0000000000c2','Центр 0050 живой','centr-0050-b','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0500000-0000-0000-0000-000000000010','a0500000-0000-0000-0000-0000000000c1','Специалист 0050','a0500000-0000-0000-0000-000000000002');
insert into public.services (id, center_id, name, default_price_tiyin) values
  ('a0500000-0000-0000-0000-000000000020','a0500000-0000-0000-0000-0000000000c1','Логопед',70000);
insert into public.payers (id, center_id, full_name, phone) values
  ('a0500000-0000-0000-0000-000000000030','a0500000-0000-0000-0000-0000000000c1','Родитель 0050','+996700005001');
insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('a0500000-0000-0000-0000-000000000001','a0500000-0000-0000-0000-0000000000c1','owner',  null),
  ('a0500000-0000-0000-0000-000000000002','a0500000-0000-0000-0000-0000000000c1','teacher','a0500000-0000-0000-0000-000000000010'),
  ('a0500000-0000-0000-0000-000000000005','a0500000-0000-0000-0000-0000000000c2','owner',  null);
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0500000-0000-0000-0000-000000000040','a0500000-0000-0000-0000-0000000000c1','Ребёнок 0050','a0500000-0000-0000-0000-000000000030');
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('a0500000-0000-0000-0000-000000000050','a0500000-0000-0000-0000-0000000000c1','a0500000-0000-0000-0000-000000000010',
   'a0500000-0000-0000-0000-000000000040','a0500000-0000-0000-0000-000000000020','planned',
   now() - interval '2 hours', now() - interval '1 hour 15 minutes');
-- Приглашение, выписанное до просрочки: принять его при просрочке нельзя (Р4).
insert into public.invitations (id, center_id, role, token, expires_at) values
  ('a0500000-0000-0000-0000-000000000060','a0500000-0000-0000-0000-0000000000c1','admin','tok-0050-expired-center', now() + interval '7 days');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Предикат: fail closed ---------------------------------------------------------------------------

select ok(not public.center_writable('a0500000-0000-0000-0000-0000000000c1'), 'Просроченная подписка — не пишет');
select ok(public.center_writable('a0500000-0000-0000-0000-0000000000c2'), 'Живой trial — пишет');
select ok(not public.center_writable('a0500000-0000-0000-0000-000000000099'), 'Несуществующий центр — не пишет');

-- Срок и тариф centers меняет только платформа (centers_protect_plan, 0049) — claims платформы.
select public.tests_claims('a0500000-0000-0000-0000-000000000003', null);
select throws_ok(
  $q$ update public.centers set trial_ends_at = null where id = 'a0500000-0000-0000-0000-0000000000c2' $q$,
  '23514', null,
  'Trial без даты окончания невозможен — инвариант на centers (Р5)');
update public.centers set plan = 'studio', subscription_until = null where id = 'a0500000-0000-0000-0000-0000000000c2';
select ok(not public.center_writable('a0500000-0000-0000-0000-0000000000c2'), 'Платный тариф без subscription_until — не пишет (fail closed)');
update public.centers set subscription_until = now() + interval '1 day' where id = 'a0500000-0000-0000-0000-0000000000c2';
select ok(public.center_writable('a0500000-0000-0000-0000-0000000000c2'), 'С живой подпиской — пишет');
select public.tests_claims(null, null);


-- 3. Главный путь: definer-RPC и прямой PATCH от сессии просроченного центра -----------------------------

select public.tests_claims('a0500000-0000-0000-0000-000000000002','a0500000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.mark_attendance('a0500000-0000-0000-0000-000000000050','a0500000-0000-0000-0000-000000000040', null, null) $q$,
  'PT402',
  'Центр временно доступен только для чтения — обратитесь к администратору центра',
  'Специалист просроченного центра не отмечает посещение — код режима, текст без «оплатите» (Р9)');
reset role;

select public.tests_claims('a0500000-0000-0000-0000-000000000001','a0500000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.archive_student('a0500000-0000-0000-0000-000000000040') $q$,
  'PT402', null,
  'Владелец просроченного центра не пишет через definer-RPC — то, чего политики RLS не ловили');
select throws_ok(
  $q$ update public.students set full_name = 'Прямой PATCH' where id = 'a0500000-0000-0000-0000-000000000040' $q$,
  'PT402',
  'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра',
  'И прямой PATCH — тот же код и тот же текст: путь, который гейт в функциях не ловил');
select throws_ok(
  $q$ select * from public.create_invitation('teacher', 'Новый специалист') $q$,
  'PT402', null,
  'Приём нового сотрудника при просрочке закрыт (Р4)');
select throws_ok(
  $q$ update public.teachers set is_active = false where id = 'a0500000-0000-0000-0000-000000000010' $q$,
  'PT402', null,
  'Прямой PATCH is_active = false — обычная запись, не отзыв доступа (Р4)');

-- Owner не заперт (Р12).
select lives_ok(
  $q$ update public.centers set name = 'Центр 0050 переименован' where id = 'a0500000-0000-0000-0000-0000000000c1' $q$,
  'Название центра правится');
select is(
  (select name from public.centers where id = 'a0500000-0000-0000-0000-0000000000c1'),
  'Центр 0050 переименован', 'Название действительно изменилось — не ноль строк под RLS (Р12)');
select lives_ok(
  $q$ select public.revoke_membership('a0500000-0000-0000-0000-000000000002') $q$,
  'Отзыв доступа сотруднику проходит при просрочке (Р4/Р12)');
select is((select count(*)::int from public.students), 1, 'Чтение живо');
reset role;

select ok(
  (select not t.is_active and t.profile_id is null from public.teachers t where t.id = 'a0500000-0000-0000-0000-000000000010'),
  'revoke_membership погасил карточку: is_active = false, profile_id пуст — флаг сработал');
select is(
  current_setting('logocrm.revoke_membership', true), '',
  'Флаг revoke_membership снят после update — не протекает в следующие записи');

-- Приглашение, выписанное до просрочки, при просрочке не принимается.
select public.tests_claims('a0500000-0000-0000-0000-000000000004', null);
set local role authenticated;
select throws_ok(
  $q$ select public.accept_invitation('tok-0050-expired-center') $q$,
  'PT402', null,
  'accept_invitation: insert в memberships под guard — приём при просрочке закрыт (Р4)');
reset role;

-- Порядок причин: просрочка + полный лимит (solo: 1 специалист, карточка жива) → текст просрочки (Р8).
select public.tests_claims('a0500000-0000-0000-0000-000000000001','a0500000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ insert into public.teachers (center_id, full_name) values ('a0500000-0000-0000-0000-0000000000c1', 'Сверх лимита и срока') $q$,
  'PT402', null,
  'При просрочке и полном лимите первым отвечает режим, а не лимит (Р8)');
reset role;


-- 4. Без сессии и от платформы guard молчит (Р1/Р2) -----------------------------------------------------

select public.tests_claims(null, null);
select lives_ok(
  $q$ update public.students set full_name = 'Миграция' where id = 'a0500000-0000-0000-0000-000000000040' $q$,
  'Без auth.uid() (миграция, каскад, bot_worker) запись проходит');
select lives_ok(
  $q$ delete from auth.users where id = 'a0500000-0000-0000-0000-000000000002' $q$,
  'Удаление пользователя с карточкой в просроченном центре проходит (каскад on delete set null)');

-- Платформа пишет через definer-RPC (/admin, 0051): uid платформы, строка видна — результат проверяем.
select public.tests_claims('a0500000-0000-0000-0000-000000000003', null);
select lives_ok(
  $q$ update public.students set full_name = 'Платформа' where id = 'a0500000-0000-0000-0000-000000000040' $q$,
  'Администратор платформы пишет в просроченном центре');
select is(
  (select full_name from public.students where id = 'a0500000-0000-0000-0000-000000000040'),
  'Платформа', 'Запись платформы дошла до строки — не пустой update под RLS');


-- 5. Разблокировка: платформа продлевает — центр снова пишет ----------------------------------------------

select public.tests_claims('a0500000-0000-0000-0000-000000000003', null);
select lives_ok(
  $q$ update public.centers set subscription_until = now() + interval '30 days' where id = 'a0500000-0000-0000-0000-0000000000c1' $q$,
  'Продление проходит: аудит centers вне guard (Р2)');
select ok(
  (select (new_data ->> 'subscription_until')::timestamptz > now() from public.audit_log
    where table_name = 'centers' and row_id = 'a0500000-0000-0000-0000-0000000000c1' and action = 'UPDATE'
    -- at = now() одинаков на всю транзакцию — порядок только по id.
    order by id desc limit 1),
  'Аудит центра записал продление — владелец видит, кто менял срок');

select public.tests_claims('a0500000-0000-0000-0000-000000000001','a0500000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ update public.students set full_name = 'Снова пишем' where id = 'a0500000-0000-0000-0000-000000000040' $q$,
  'После продления владелец снова пишет');
reset role;


-- 6. Nullable center_id — guard не судит, строку платформы держат свои рубежи (Р6) ------------------------
-- Грант insert выдаётся внутри транзакции (приём 0040): иначе 42501 пришёл бы
-- от отсутствия гранта, и тест не доказывал бы ни политику 0037, ни триггер
-- 0040. Просроченный и живой центр — один и тот же отказ прав, не PT402 и не успех.

grant insert on public.message_templates to authenticated;
grant insert on public.exercise_library to authenticated;

select public.tests_claims('a0500000-0000-0000-0000-000000000001','a0500000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ insert into public.message_templates (center_id, event_type, channel, text) values (null, 'lesson.reminder', 'telegram', 'подмена платформы') $q$,
  '42501', null,
  'Просроченный центр, message_templates с пустым center_id — with check политики 0037, не режим');
select throws_ok(
  $q$ insert into public.exercise_library (center_id, title) values (null, 'подмена платформы') $q$,
  '42501', 'Упражнение платформы заводится только миграцией',
  'Просроченный центр, exercise_library с пустым center_id — триггер 0040, не режим');
reset role;

select public.tests_claims('a0500000-0000-0000-0000-000000000005','a0500000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_ok(
  $q$ insert into public.message_templates (center_id, event_type, channel, text) values (null, 'lesson.reminder', 'telegram', 'подмена платформы') $q$,
  '42501', null,
  'Живой центр, message_templates с пустым center_id — тот же отказ прав');
select throws_ok(
  $q$ insert into public.exercise_library (center_id, title) values (null, 'подмена платформы') $q$,
  '42501', 'Упражнение платформы заводится только миграцией',
  'Живой центр, exercise_library с пустым center_id — тот же отказ прав');
reset role;

revoke insert on public.message_templates from authenticated;
revoke insert on public.exercise_library from authenticated;
select public.tests_claims(null, null);


-- 7. Грейс до конца дня в поясе центра — через center_writable и center_limits (Р11) ----------------------

select public.tests_claims('a0500000-0000-0000-0000-000000000003', null);
update public.centers set subscription_until = (now() at time zone 'Asia/Bishkek')::date::timestamp at time zone 'Asia/Bishkek' where id = 'a0500000-0000-0000-0000-0000000000c1';
select ok(public.center_writable('a0500000-0000-0000-0000-0000000000c1'),
  'Срок «до сегодня» — сегодня ещё пишем (до конца дня в поясе центра)');
select public.tests_claims('a0500000-0000-0000-0000-000000000001','a0500000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((public.center_limits() ->> 'writable')::boolean, true, 'center_limits: writable = true на день истечения');
select is((public.center_limits() ->> 'days_left')::int, 0, 'center_limits: days_left = 0 на день истечения');
reset role;

select public.tests_claims('a0500000-0000-0000-0000-000000000003', null);
update public.centers set subscription_until = (now() at time zone 'Asia/Bishkek')::date::timestamp at time zone 'Asia/Bishkek' - interval '1 second' where id = 'a0500000-0000-0000-0000-0000000000c1';
select ok(not public.center_writable('a0500000-0000-0000-0000-0000000000c1'),
  'Секунда до полуночи вчера в поясе центра — уже не пишем');
select public.tests_claims('a0500000-0000-0000-0000-000000000001','a0500000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((public.center_limits() ->> 'writable')::boolean, false, 'center_limits: writable = false на следующий день');
select is((public.center_limits() ->> 'days_left')::int, -1, 'center_limits: days_left = -1 на следующий день — одна граница в обеих функциях');
reset role;
select public.tests_claims(null, null);

select * from finish();

rollback;
