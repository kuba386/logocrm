-- pgTAP: только чтение при истёкшей подписке (0050).
--
-- Забор в начале: каждая таблица с center_id либо под a00_readonly_guard,
-- либо в списке исключений; список nullable center_id зафиксирован.
-- Главный путь — definer-RPC от сессии просроченного центра; прямой PATCH;
-- разблокировка платформой; owner не заперт; воркер без сессии проходит;
-- fail closed на пустых датах; порядок причин с лимитом.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(29);


-- 1. Заборы по каталогу -----------------------------------------------------------------------------

select is_empty(
  $$ select c.table_name
       from information_schema.columns c
       join information_schema.tables t
         on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
      where c.table_schema = 'public' and c.column_name = 'center_id'
        and c.table_name not in (select x.table_name from public.readonly_guard_exempt_tables() x)
        and not exists (
          select 1 from pg_trigger tg
           where tg.tgrelid = ('public.' || c.table_name)::regclass and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal) $$,
  'Каждая таблица с center_id либо под guard, либо в явном списке исключений');

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

-- Р4: memberships/invitations — только insert.
select is(
  (select string_agg(case when tg.tgtype & 4 > 0 then 'i' else '' end || case when tg.tgtype & 16 > 0 then 'u' else '' end || case when tg.tgtype & 8 > 0 then 'd' else '' end, ',' order by tg.tgrelid::regclass::text)
     from pg_trigger tg where tg.tgname = 'a00_readonly_guard' and tg.tgrelid in ('public.memberships'::regclass, 'public.invitations'::regclass)),
  'i,i', 'memberships и invitations — guard только на insert (Р4)');

select is(
  (select count(*)::int from pg_trigger tg where tg.tgname = 'a00_readonly_guard'
     and tg.tgrelid not in ('public.memberships'::regclass, 'public.invitations'::regclass)
     and not (tg.tgtype & 4 > 0 and tg.tgtype & 16 > 0 and tg.tgtype & 8 > 0)),
  0, 'На остальных таблицах guard объявлен на insert, update и delete (Р13)');


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
  ('00000000-0000-0000-0000-000000000000','a0500000-0000-0000-0000-000000000003','authenticated','authenticated','platform-0050@test.kg','','','','','','','','');
update auth.users set email_confirmed_at = now() where id = 'a0500000-0000-0000-0000-000000000003';
insert into public.platform_admins (email) values ('platform-0050@test.kg');

-- Центр А — просроченный solo (истёк вчера в поясе центра); центр Б — живой trial.
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
  ('a0500000-0000-0000-0000-000000000002','a0500000-0000-0000-0000-0000000000c1','teacher','a0500000-0000-0000-0000-000000000010');
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0500000-0000-0000-0000-000000000040','a0500000-0000-0000-0000-0000000000c1','Ребёнок 0050','a0500000-0000-0000-0000-000000000030');
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('a0500000-0000-0000-0000-000000000050','a0500000-0000-0000-0000-0000000000c1','a0500000-0000-0000-0000-000000000010',
   'a0500000-0000-0000-0000-000000000040','a0500000-0000-0000-0000-000000000020','planned',
   now() - interval '2 hours', now() - interval '1 hour 15 minutes');

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

select throws_ok(
  $q$ update public.centers set trial_ends_at = null where id = 'a0500000-0000-0000-0000-0000000000c2' $q$,
  '23514', null,
  'Trial без даты окончания невозможен — инвариант на centers (Р5)');

select public.tests_claims('a0500000-0000-0000-0000-000000000003', null);
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
  'PT402', null,
  'Специалист просроченного центра не отмечает посещение — код режима, не 42501');
reset role;

select public.tests_claims('a0500000-0000-0000-0000-000000000001','a0500000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.archive_student('a0500000-0000-0000-0000-000000000040') $q$,
  'PT402', null,
  'Владелец просроченного центра не пишет через definer-RPC — то, чего политики RLS не ловили');
select throws_ok(
  $q$ update public.students set full_name = 'Прямой PATCH' where id = 'a0500000-0000-0000-0000-000000000040' $q$,
  'PT402', null,
  'И прямой PATCH — тот же код: путь, который гейт в функциях не ловил');
select throws_ok(
  $q$ select * from public.create_invitation('teacher', 'Новый специалист') $q$,
  'PT402', null,
  'Приём нового сотрудника при просрочке закрыт (Р4)');

-- Owner не заперт (Р12).
select lives_ok(
  $q$ update public.centers set name = 'Центр 0050 переименован' where id = 'a0500000-0000-0000-0000-0000000000c1' $q$,
  'Название центра правится');
select lives_ok(
  $q$ select public.revoke_membership('a0500000-0000-0000-0000-000000000002') $q$,
  'Отзыв доступа сотруднику проходит при просрочке (Р4/Р12)');
select is((select count(*)::int from public.students), 1, 'Чтение живо');
reset role;

-- Порядок причин: просрочка + превышенный лимит → текст просрочки (Р8).
select public.tests_claims('a0500000-0000-0000-0000-000000000003', null);
update public.centers set plan = 'solo' where id = 'a0500000-0000-0000-0000-0000000000c1';
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

select public.tests_claims('a0500000-0000-0000-0000-000000000003', null);
set local role authenticated;
select lives_ok(
  $q$ update public.students set full_name = 'Платформа' where id = 'a0500000-0000-0000-0000-000000000040' $q$,
  'Администратор платформы пишет в просроченном центре');
reset role;


-- 5. Разблокировка: платформа продлевает — центр снова пишет ----------------------------------------------

select public.tests_claims('a0500000-0000-0000-0000-000000000003', null);
select lives_ok(
  $q$ update public.centers set subscription_until = now() + interval '30 days' where id = 'a0500000-0000-0000-0000-0000000000c1' $q$,
  'Продление проходит: аудит centers вне guard (Р2)');
select ok(
  (select (new_data ->> 'subscription_until')::timestamptz > now() from public.audit_log
    where table_name = 'centers' and row_id = 'a0500000-0000-0000-0000-0000000000c1' and action = 'UPDATE'
    order by at desc limit 1),
  'Аудит центра записал продление — владелец видит, кто менял срок');

select public.tests_claims('a0500000-0000-0000-0000-000000000001','a0500000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ update public.students set full_name = 'Снова пишем' where id = 'a0500000-0000-0000-0000-000000000040' $q$,
  'После продления владелец снова пишет');
reset role;


-- 6. Nullable center_id из сессии — отказ (Р6) ------------------------------------------------------------

select public.tests_claims('a0500000-0000-0000-0000-000000000001','a0500000-0000-0000-0000-0000000000c1');
select throws_ok(
  $q$ insert into public.message_templates (center_id, event_type, channel, text) values (null, 'lesson.reminder', 'telegram', 'подмена платформы') $q$,
  'PT402', null,
  'Строка платформы с пустым center_id из сессии центра — отказ, не пропуск');
select public.tests_claims(null, null);


-- 7. Грейс до конца дня в поясе центра (Р11) --------------------------------------------------------------

select public.tests_claims('a0500000-0000-0000-0000-000000000003', null);
update public.centers set subscription_until = (now() at time zone 'Asia/Bishkek')::date::timestamp at time zone 'Asia/Bishkek' where id = 'a0500000-0000-0000-0000-0000000000c1';
select ok(public.center_writable('a0500000-0000-0000-0000-0000000000c1'),
  'Срок «до сегодня» — сегодня ещё пишем (до конца дня в поясе центра)');
update public.centers set subscription_until = (now() at time zone 'Asia/Bishkek')::date::timestamp at time zone 'Asia/Bishkek' - interval '1 second' where id = 'a0500000-0000-0000-0000-0000000000c1';
select ok(not public.center_writable('a0500000-0000-0000-0000-0000000000c1'),
  'Секунда до полуночи вчера в поясе центра — уже не пишем');
select public.tests_claims(null, null);

select * from finish();

rollback;
