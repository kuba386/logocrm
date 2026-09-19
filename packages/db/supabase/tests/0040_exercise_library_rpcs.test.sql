-- pgTAP: библиотека упражнений — save_exercise вместо прямой записи (0040).
--
-- 0036 доказал видимость exercise_library, 0038 — точечные RPC записи
-- остальных клинических таблиц. Здесь — тот же приём для exercise_library:
-- владелец/админ своего центра правят каталог через save_exercise, прямая
-- запись закрыта, границу платформенной строки (center_id is null) держит
-- триггер, а не только код функции.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(21);


create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','41111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-lib@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-lib@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','47777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-lib@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','42222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-lib@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','43333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-lib@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','49999999-9999-9999-9999-999999999999','authenticated','authenticated','owner-b-lib@test.kg','','','','','','','','');

-- Центры заводятся под postgres (auth.uid() is null) — триггер
-- centers_seed_goal_stages сеет goal_stages, а exercise_library_center_required
-- их не касается вовсе (пишем не в exercise_library).
insert into public.centers (id, name, slug, settings) values
  ('4ccccccc-0000-0000-0000-00000000000a','Центр А (библиотека)','centr-a-library','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('4ccccccc-0000-0000-0000-00000000000b','Центр Б (библиотека)','centr-b-library','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.payers (id, center_id, full_name, phone) values
  ('4ddddddd-0000-0000-0000-000000000001','4ccccccc-0000-0000-0000-00000000000a','Родитель','+996700000401');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('41111111-1111-1111-1111-111111111111','4ccccccc-0000-0000-0000-00000000000a','owner',     null, null),
  ('44444444-4444-4444-4444-444444444444','4ccccccc-0000-0000-0000-00000000000a','teacher',   null, null),
  ('47777777-7777-7777-7777-777777777777','4ccccccc-0000-0000-0000-00000000000a','parent',    null, '4ddddddd-0000-0000-0000-000000000001'),
  ('42222222-2222-2222-2222-222222222222','4ccccccc-0000-0000-0000-00000000000a','registrar', null, null),
  ('43333333-3333-3333-3333-333333333333','4ccccccc-0000-0000-0000-00000000000a','finance',   null, null),
  ('49999999-9999-9999-9999-999999999999','4ccccccc-0000-0000-0000-00000000000b','owner',     null, null);

-- Платформенная строка — заведена как миграция/бэкфилл: под postgres, минуя
-- живую сессию, exercise_library_center_required её пропускает.
insert into public.exercise_library (id, center_id, title, sound) values
  ('4eeeeeee-0000-0000-0000-000000000001', null, 'Упражнение платформы', 'р');

-- Строка центра Б — доказывает межцентровую границу save_exercise.
select public.tests_claims('49999999-9999-9999-9999-999999999999','4ccccccc-0000-0000-0000-00000000000b');
select public.save_exercise('Упражнение центра Б');

insert into public.exercise_library (id, center_id, title)
  values (gen_random_uuid(), '4ccccccc-0000-0000-0000-00000000000a', 'Дубликат по названию');


-- 1. Владелец создаёт и правит своё упражнение ---------------------------------------------------

select public.tests_claims('41111111-1111-1111-1111-111111111111','4ccccccc-0000-0000-0000-00000000000a');

select lives_ok(
  $q$ select public.save_exercise('Автоматизация Р в словах', null, 'звукопроизношение', 'р', 'setting') $q$,
  'owner создаёт упражнение своего центра');

select is(
  (select center_id from public.exercise_library where title = 'Автоматизация Р в словах'),
  '4ccccccc-0000-0000-0000-00000000000a'::uuid,
  'новая строка получила center_id вызывающего, а не NULL');

-- results_eq здесь не годится принципиально: он открывает оба курсора до
-- первой выборки, поэтому второй запрос получает снимок ДО правки и нового
-- названия не видит. Падало «have: (uuid), want: NULL» — при том что функция
-- отрабатывала верно. Сравниваем идентификаторы: совпадение и есть
-- доказательство, что правка изменила строку, а не завела вторую.
create temporary table t_exercise_before as
  select id from public.exercise_library where title = 'Автоматизация Р в словах';

select is(
  public.save_exercise('Автоматизация Р в словах — правка',
    (select id from t_exercise_before), 'звукопроизношение', 'р', 'setting'),
  (select id from t_exercise_before),
  'update по своему id возвращает тот же id — строка та же, новой не появилось');


-- 2. Чужой центр и платформа — один и тот же код отказа ------------------------------------------

select throws_ok(
  $q$ select public.save_exercise('Чужое', id) from public.exercise_library where title = 'Упражнение центра Б' $q$,
  '42704', null, 'update по id чужого центра — не найдено, а не тихий проход');

select throws_ok(
  $q$ select public.save_exercise('Переписали платформу', '4eeeeeee-0000-0000-0000-000000000001') $q$,
  '42704', null, 'update по id платформенной строки — тот же код, что у чужого центра (Р1)');

select is(
  (select title from public.exercise_library where id = '4eeeeeee-0000-0000-0000-000000000001'),
  'Упражнение платформы',
  'платформенная строка не изменилась');


-- 3. Этап и возраст проверяются, а не сохраняются как есть ----------------------------------------

select throws_ok(
  $q$ select public.save_exercise('Плохой этап', null, null, null, 'no-such-stage') $q$,
  '42704', null, 'несуществующий stage_code своего центра отбивается, а не сохраняется сырым');

select throws_ok(
  $q$ select public.save_exercise('Плохой возраст', null, null, null, null, null, null, 5, 3) $q$,
  '23514', null, 'age_from > age_to — констрейнт таблицы (Р6)');

select throws_ok(
  $q$ select public.save_exercise('Отрицательный возраст', null, null, null, null, null, null, -1) $q$,
  '23514', null, 'отрицательный age_from — констрейнт таблицы');

select throws_ok(
  $q$ select public.save_exercise('Плохая ссылка', null, null, null, null, null, 'ftp://x') $q$,
  '23514', null, 'media_url без http(s) — констрейнт таблицы');

select throws_ok(
  $q$ select public.save_exercise('Дубликат по названию') $q$,
  '23505', null, 'дубль названия в своём центре отбивается уникальным индексом (Р7)');


-- 4. Чужая роль — 42501 --------------------------------------------------------------------------

select public.tests_claims('44444444-4444-4444-4444-444444444444','4ccccccc-0000-0000-0000-00000000000a');
select throws_ok(
  $q$ select public.save_exercise('От специалиста') $q$,
  '42501', null, 'teacher не правит каталог — только owner/admin');

select public.tests_claims('47777777-7777-7777-7777-777777777777','4ccccccc-0000-0000-0000-00000000000a');
select throws_ok(
  $q$ select public.save_exercise('От родителя') $q$,
  '42501', null, 'parent не правит каталог');

select public.tests_claims('42222222-2222-2222-2222-222222222222','4ccccccc-0000-0000-0000-00000000000a');
select throws_ok(
  $q$ select public.save_exercise('От регистратора') $q$,
  '42501', null, 'registrar не правит каталог');

select public.tests_claims('43333333-3333-3333-3333-333333333333','4ccccccc-0000-0000-0000-00000000000a');
select throws_ok(
  $q$ select public.save_exercise('От бухгалтера') $q$,
  '42501', null, 'finance не правит каталог');


-- 5. Прямая запись закрыта, границу платформы держит триггер (Р2, Р3) -----------------------------

select public.tests_claims('41111111-1111-1111-1111-111111111111','4ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ insert into public.exercise_library (center_id, title) values ('4ccccccc-0000-0000-0000-00000000000a', 'Мимо RPC') $q$,
  '42501', null, 'прямой insert закрыт даже владельцу (0040)');
select throws_ok(
  $q$ update public.exercise_library set title = 'Мимо RPC' where id = '4eeeeeee-0000-0000-0000-000000000001' $q$,
  '42501', null, 'прямой update закрыт даже владельцу (0040)');
-- Три, а не четыре: под владельцем центра А видны платформенная строка и две
-- свои, а упражнение центра Б отсекает та же политика 0036. Ожидание «4»
-- считало содержимое таблицы целиком, как от postgres, — мимо RLS.
select is((select count(*)::int from public.exercise_library), 3,
  'select при этом жив: своё и платформа видны, чужой центр — нет');

reset role;

-- Грант сейчас закрыт целиком — им уже доказано, что authenticated до
-- триггера не доходит вовсе (тесты выше). Триггер — защита от гипотетического
-- будущего grant insert «впрок» (как в 0036), а не от сегодняшнего пути.
-- Чтобы проверить именно его, а не факт отсутствия гранта, выдаём грант
-- временно внутри этой же транзакции (откатится вместе с rollback в конце
-- файла) и повторяем попытку под настоящей ролью authenticated.
grant insert on public.exercise_library to authenticated;

select public.tests_claims('41111111-1111-1111-1111-111111111111','4ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ insert into public.exercise_library (center_id, title) values (null, 'Тайная платформа') $q$,
  '42501', null,
  'даже при гранте на insert живая сессия не заводит платформенную строку — держит триггер (Р3)');

reset role;
revoke insert on public.exercise_library from authenticated;


-- 6. Гранты функции (забор 0007 дополнен той же сигнатурой) ----------------------------------------

select isnt(
  has_function_privilege('anon', 'public.save_exercise(text,uuid,text,text,text,text,text,integer,integer,text[],boolean)', 'execute'),
  true, 'anon не исполняет save_exercise');
select is(
  has_function_privilege('authenticated', 'public.save_exercise(text,uuid,text,text,text,text,text,integer,integer,text[],boolean)', 'execute'),
  true, 'authenticated исполняет save_exercise — сама функция проверяет роль внутри');

select * from finish();
rollback;
