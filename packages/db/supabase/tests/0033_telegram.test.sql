-- pgTAP: привязка Telegram, команды бота, подтверждение прихода (0033).
--
-- Главное здесь — не привязка, а видимость: bot_*-функции исполняются от
-- bot_worker и ходят мимо RLS, то есть воспроизводят правила доступа заново.
-- Поэтому каждая роль проверяется отдельно, а групповое занятие ребёнка
-- стоит отдельным кейсом: по lessons.student_id родитель его не увидел бы,
-- у группового занятия эта колонка пуста (ADR-006).
--
-- Вызовы бота идут от postgres при пустых claims — так же, как их будет
-- звать bot_worker; гранты роли проверяются по каталогу.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(36);


-- 1-5. Гранты ------------------------------------------------------------------------------------

select ok(
  has_function_privilege('bot_worker', 'public.link_telegram(text,bigint)', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.bot_today(bigint)', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.bot_balance(bigint)', 'EXECUTE')
  and has_function_privilege('bot_worker', 'public.confirm_lesson(bigint,uuid,uuid)', 'EXECUTE'),
  'bot_worker исполняет функции бота'
);
select ok(
  has_function_privilege('authenticated', 'public.create_telegram_link_code()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.unlink_telegram()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.payer_telegram_linked(uuid)', 'EXECUTE'),
  'Пользователь сам выпускает код, отвязывается и видит бейдж плательщика'
);
select ok(
  not has_function_privilege('authenticated', 'public.link_telegram(text,bigint)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.bot_today(bigint)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.bot_balance(bigint)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.confirm_lesson(bigint,uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.bot_today(bigint)', 'EXECUTE'),
  'Функции бота недоступны из браузера: чат подставляется, а не проверяется паролем'
);
select ok(
  not has_function_privilege('service_role', 'public.bot_today(bigint)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.link_telegram(text,bigint)', 'EXECUTE')
  and not has_table_privilege('service_role', 'public.telegram_accounts', 'SELECT')
  and not has_table_privilege('service_role', 'public.lesson_confirmations', 'INSERT'),
  'service_role здесь тоже не дверь (0032, Р2)'
);
select ok(
  not has_function_privilege('authenticated', 'public.telegram_user(bigint)', 'EXECUTE')
  and not has_function_privilege('bot_worker', 'public.telegram_user(bigint)', 'EXECUTE'),
  'telegram_user закрыта от всех: «чей это чат» наружу не спрашивается'
);


-- Фикстура ----------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-tg@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-tg@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-tg@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-tg@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','88888888-8888-8888-8888-888888888888','authenticated','authenticated','other-parent-tg@test.kg','','','','','','','','');

-- Пояс, где сейчас день: занятие «через час» обязано остаться в тех же
-- местных сутках, иначе «занятия на сегодня» зависели бы от часа прогона CI.
create temporary table t_tz as
  select (select name from pg_timezone_names
           where name like 'Etc/GMT%'
             and extract(hour from (now() at time zone name))::int between 9 and 19
           order by name limit 1) as tz_day;

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-tg',
   jsonb_build_object('timezone', (select tz_day from t_tz)));

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист Один'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Специалист Два');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Наш плательщик','+996700000001'),
  ('dddddddd-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Чужой плательщик','+996700000002');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',  null, null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001', null),
  ('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000001'),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','finance',null, null),
  ('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000002');

-- S1 — без абонемента, с долгом; S2 — в группе, абонемент на 2 занятия;
-- S4 — безлимит (отличать «безлимит» от «нет абонемента»); S3 — чужая семья.
insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок Один','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Ребёнок Два','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','Ребёнок Четыре','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Чужой Ребёнок','dddddddd-0000-0000-0000-000000000002');

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','2 занятия','lessons',2,200000),
  ('77777777-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Безлимит','unlimited',null,500000);

-- Состав группы заводится ДО занятия: участников занятия кладёт триггер по
-- group_students, а joined_at по умолчанию — сегодня (грабли из 0017).
insert into public.groups (id, center_id, name, teacher_id) values
  ('9a9a9a9a-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Группа','aaaaaaaa-0000-0000-0000-000000000001');
-- center_id явно: его проверяет BEFORE-триггер group_students_check_center_refs
-- (0022), а current_center() в фикстуре пуст.
insert into public.group_students (center_id, group_id, student_id, joined_at) values
  ('cccccccc-0000-0000-0000-00000000000a','9a9a9a9a-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000002', current_date - 7);

insert into public.lessons (id, center_id, teacher_id, student_id, group_id, service_id, status, starts_at, ends_at) values
  ('ffffffff-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',null,'bbbbbbbb-0000-0000-0000-000000000001','planned',   now() + interval '1 hour', now() + interval '1 hour 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001',null,'9a9a9a9a-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','planned',   now() + interval '3 hours', now() + interval '3 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',null,'bbbbbbbb-0000-0000-0000-000000000001','cancelled', now() + interval '5 hours', now() + interval '5 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000003',null,'bbbbbbbb-0000-0000-0000-000000000001','planned',   now() + interval '7 hours', now() + interval '7 hours 45 minutes'),
  ('ffffffff-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',null,'bbbbbbbb-0000-0000-0000-000000000001','planned',   now() - interval '1 day',  now() - interval '1 day' + interval '45 minutes');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_code (name text primary key, code text);
grant select, insert on t_code to authenticated;

-- Абонементы и долг — руками владельца.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000002', null, current_date);
select public.sell_subscription('77777777-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000004', null, current_date);
select public.mark_attendance('ffffffff-0000-0000-0000-000000000005', 'eeeeeeee-0000-0000-0000-000000000001');
reset role;

select is(
  (select count(*)::int from public.lesson_participants where lesson_id = 'ffffffff-0000-0000-0000-000000000002'),
  1, 'Фикстура: в групповом занятии есть участник — иначе кейс родителя был бы пустым по другой причине');


-- 7-14. Коды и привязка -----------------------------------------------------------------------------

select public.tests_claims('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
insert into t_code values ('first', public.create_telegram_link_code());
select is(length((select code from t_code where name = 'first')), 24,
  'Код — 24 символа hex: перебором в открытом боте не берётся');
insert into t_code values ('second', public.create_telegram_link_code());
reset role;
select public.tests_claims(null, null);

select throws_ok(
  format($q$ select public.link_telegram(%L, 555001) $q$, (select code from t_code where name = 'first')),
  '22023', null, 'Выдача нового кода гасит прежний — старая ссылка из переписки больше не работает');

select is(public.link_telegram((select code from t_code where name = 'second'), 555001),
  '77777777-7777-7777-7777-777777777777'::uuid, 'Привязка по живому коду');

select throws_ok(
  format($q$ select public.link_telegram(%L, 555002) $q$, (select code from t_code where name = 'second')),
  '22023', null, 'Тот же код второй раз — отказ: ретрай вебхука Telegram не должен привязать второй чат (Р3)');

select is((select count(*)::int from public.telegram_accounts where unlinked_at is null), 1,
  'Живая привязка одна');

-- Р2: отвязка и повторная привязка ТОГО ЖЕ чата обязаны проходить.
select public.tests_claims('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(public.unlink_telegram(), true, 'Отвязка проходит');
select is(public.unlink_telegram(), false, 'Повторная отвязка — false, не ошибка');
insert into t_code values ('third', public.create_telegram_link_code());
reset role;
select public.tests_claims(null, null);

select is(public.link_telegram((select code from t_code where name = 'third'), 555001),
  '77777777-7777-7777-7777-777777777777'::uuid,
  'Тот же чат привязывается заново — частичные индексы, а не PK по user_id (Р2)');
select is((select count(*)::int from public.telegram_accounts), 2,
  'История привязок осталась: строки не переиспользуются');


-- 15-20. bot_today ------------------------------------------------------------------------------------

select throws_ok($q$ select * from public.bot_today(999999) $q$, '42501', null,
  'Непривязанный чат — отказ, а не пустой список «сегодня занятий нет» (Р5)');

select is((select count(*)::int from public.bot_today(555001)), 2,
  'Родитель видит два занятия своих детей: индивидуальное и групповое');

select ok(
  exists (select 1 from public.bot_today(555001) where lesson_id = 'ffffffff-0000-0000-0000-000000000002'),
  'Групповое занятие ребёнка родителю видно — по составу занятия, а не по lessons.student_id (ADR-006)'
);
select ok(
  not exists (select 1 from public.bot_today(555001) where lesson_id = 'ffffffff-0000-0000-0000-000000000004'),
  'Занятие чужого ребёнка родителю не видно'
);
select ok(
  not exists (select 1 from public.bot_today(555001) where lesson_id = 'ffffffff-0000-0000-0000-000000000003'),
  'Отменённое занятие не показывается'
);

-- Чаты специалиста и бухгалтера заводятся напрямую: путь «код → link_telegram»
-- уже проверен выше, здесь нужна только их видимость.
insert into public.telegram_accounts (user_id, chat_id) values
  ('44444444-4444-4444-4444-444444444444', 555004),
  ('33333333-3333-3333-3333-333333333333', 555003);

select is((select count(*)::int from public.bot_today(555004)), 2,
  'Специалист видит только свои занятия: индивидуальное и групповое, но не занятие второго специалиста');

select is((select count(*)::int from public.bot_today(555003)), 0,
  'Бухгалтеру бот занятий не показывает — 0031 закрыл ему lessons, и бот не дверь в обход');


-- 21-25. bot_balance ----------------------------------------------------------------------------------

select is((select count(*)::int from public.bot_balance(555001)), 3, 'Родителю показаны трое его детей');
select is(
  (select debt_tiyin from public.bot_balance(555001) where student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  70000, 'Ребёнок без абонемента: долг числом');
select ok(
  (select not has_subscription from public.bot_balance(555001) where student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  'У него же has_subscription = false');
select is(
  (select lessons_left from public.bot_balance(555001) where student_id = 'eeeeeeee-0000-0000-0000-000000000002'),
  2, 'Ребёнок с абонементом на два занятия: остаток 2');
select ok(
  (select has_subscription and lessons_left is null
     from public.bot_balance(555001) where student_id = 'eeeeeeee-0000-0000-0000-000000000004'),
  'Безлимит: абонемент есть, остаток NULL — это не «ноль занятий» (0010)');
select is((select count(*)::int from public.bot_balance(555004)), 0,
  'Специалисту баланс в боте не отдаётся: у него в приложении слово, а не числа');


-- 27-31. Подтверждение прихода -------------------------------------------------------------------------

select is(public.confirm_lesson(555001, 'ffffffff-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000002'), true,
  'Родитель подтверждает приход ребёнка на групповое занятие');
select is(public.confirm_lesson(555001, 'ffffffff-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000002'), false,
  'Повторное подтверждение — false, не ошибка');
select is((select count(*)::int from public.events where type = 'lesson.confirmed'), 1,
  'Одно событие lesson.confirmed');
select throws_ok(
  $q$ select public.confirm_lesson(555001, 'ffffffff-0000-0000-0000-000000000004', 'eeeeeeee-0000-0000-0000-000000000003') $q$,
  '42704', null, 'Чужого ребёнка подтвердить нельзя');
select throws_ok(
  $q$ select public.confirm_lesson(555004, 'ffffffff-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42704', null, 'Специалист не подтверждает за родителя');


-- 32-34. Видимость подтверждений и бейдж ----------------------------------------------------------------

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.lesson_confirmations), 1,
  'Специалист занятия видит подтверждение');
select throws_ok($q$ select public.payer_telegram_linked('dddddddd-0000-0000-0000-000000000001') $q$,
  '42501', null, 'Специалисту бейдж плательщика не положен');
reset role;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(public.payer_telegram_linked('dddddddd-0000-0000-0000-000000000001'), true,
  'Владелец видит, что у плательщика Telegram привязан');
reset role;

select * from finish();

rollback;
