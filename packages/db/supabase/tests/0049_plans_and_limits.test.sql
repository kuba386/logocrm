-- pgTAP: тарифы, роль платформы, лимиты (0049).
--
-- Главное — тариф не пишется центром (owner меняет название, но не план),
-- лимит держится триггером на переходе в «живые» и не мешает уже
-- превысившему центру править и архивировать, гонка двух вставок даёт
-- одну (advisory lock), лицензия специалиста — живая карточка.
--
-- tests_claims здесь с email: is_platform_admin() смотрит на JWT.
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(41);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0490000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0049@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0490000-0000-0000-0000-000000000002','authenticated','authenticated','platform-0049@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0490000-0000-0000-0000-000000000003','authenticated','authenticated','parent-0049@test.kg','','','','','','','','');

-- is_platform_admin() требует подтверждённый email у auth.users (Р4).
update auth.users set email_confirmed_at = now() where id = 'a0490000-0000-0000-0000-000000000002';

-- Центр на solo: 1 специалист, 40 учеников.
insert into public.centers (id, name, slug, plan, settings) values
  ('a0490000-0000-0000-0000-0000000000c1','Центр 0049','centr-0049','solo','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.payers (id, center_id, full_name, phone) values
  ('a0490000-0000-0000-0000-000000000030','a0490000-0000-0000-0000-0000000000c1','Родитель 0049','+996700004901');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0490000-0000-0000-0000-000000000001','a0490000-0000-0000-0000-0000000000c1','owner',  null, null),
  ('a0490000-0000-0000-0000-000000000003','a0490000-0000-0000-0000-0000000000c1','parent', null, 'a0490000-0000-0000-0000-000000000030');

insert into public.platform_admins (email) values ('platform-0049@test.kg');

create or replace function public.tests_claims(p_user uuid, p_center uuid, p_email text default null)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'email', p_email,
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 1. Справочник --------------------------------------------------------------------------------------

select is((select count(*)::int from public.plans), 4, 'Четыре тарифа: trial, solo, studio, center');
select is((select price_tiyin from public.plans where code = 'solo'), 99000, 'Solo — 990 сом');
select is((select (limits ->> 'teachers')::int from public.plans where code = 'center'), -1, 'Center — специалисты без ограничения (-1, не null)');

-- От администратора платформы: иначе первым сработает триггер защиты
-- тарифа (42501), и до FK дело не дойдёт.
select public.tests_claims('a0490000-0000-0000-0000-000000000002', null, 'platform-0049@test.kg');
select throws_ok(
  $q$ update public.centers set plan = 'ai' where id = 'a0490000-0000-0000-0000-0000000000c1' $q$,
  '23503', null,
  'Несуществующий код тарифа отбивает FK — литерального check больше нет');
select public.tests_claims(null, null);

select throws_ok(
  $q$ insert into public.plans (code, name, price_tiyin, limits) values ('x', 'X', 0, '{"teachers": 1}'::jsonb) $q$,
  '23514', null,
  'Тариф без полного набора лимитов не заводится — отсутствие ключа не значит безлимит (Р1)');


-- 2. Тариф пишет только платформа (Р3) ---------------------------------------------------------------

select public.tests_claims('a0490000-0000-0000-0000-000000000001','a0490000-0000-0000-0000-0000000000c1','owner-0049@test.kg');
set local role authenticated;

select lives_ok(
  $q$ update public.centers set name = 'Центр 0049 переименован' where id = 'a0490000-0000-0000-0000-0000000000c1' $q$,
  'Владелец центра меняет название — триггер не перекрыл лишнего');

select throws_ok(
  $q$ update public.centers set plan = 'center' where id = 'a0490000-0000-0000-0000-0000000000c1' $q$,
  '42501', null,
  'Владелец центра не меняет тариф');
select throws_ok(
  $q$ update public.centers set trial_ends_at = now() + interval '10 years' where id = 'a0490000-0000-0000-0000-0000000000c1' $q$,
  '42501', null,
  'И не продлевает себе trial');
select throws_ok(
  $q$ update public.centers set settings = settings || '{"features": ["ai"]}'::jsonb where id = 'a0490000-0000-0000-0000-0000000000c1' $q$,
  '42501', null,
  'И не включает себе фичи');

select ok(not public.is_platform_admin(), 'Владелец центра — не администратор платформы');
select is((select count(*)::int from public.platform_admins), 0, 'Список администраторов платформы ему не виден');
reset role;

select public.tests_claims('a0490000-0000-0000-0000-000000000002', null, 'platform-0049@test.kg');
set local role authenticated;
select ok(public.is_platform_admin(), 'Администратор платформы — по email из JWT, без членства в центре');
select ok((select count(*) from public.platform_admins) >= 1, 'Список администраторов ему виден');
reset role;

-- Продление от имени платформы: от postgres с JWT администратора, как это
-- сделает extend_subscription следующей миграции.
select public.tests_claims('a0490000-0000-0000-0000-000000000002', null, 'platform-0049@test.kg');
select lives_ok(
  $q$ update public.centers set plan = 'studio', subscription_until = now() + interval '1 month' where id = 'a0490000-0000-0000-0000-0000000000c1' $q$,
  'Администратор платформы меняет тариф и срок');
update public.centers set plan = 'solo', subscription_until = null where id = 'a0490000-0000-0000-0000-0000000000c1';


-- 3. Лимит специалистов (Р5–Р8) -------------------------------------------------------------------------

select public.tests_claims(null, null);

select lives_ok(
  $q$ insert into public.teachers (id, center_id, full_name) values ('a0490000-0000-0000-0000-000000000010','a0490000-0000-0000-0000-0000000000c1','Первый') $q$,
  'Первый специалист на solo проходит');
select throws_ok(
  $q$ insert into public.teachers (id, center_id, full_name) values ('a0490000-0000-0000-0000-000000000011','a0490000-0000-0000-0000-0000000000c1','Второй') $q$,
  '23514', null,
  'Второй специалист на solo — отказ по лимиту');
select throws_like(
  $q$ insert into public.teachers (id, center_id, full_name) values ('a0490000-0000-0000-0000-000000000011','a0490000-0000-0000-0000-0000000000c1','Второй') $q$,
  '%Лимит тарифа Solo — специалистов: 1%',
  'Текст отказа — русский, с именем тарифа и лимитом, без склонения числа (Р8)');

-- Путь, которым лимит увидит владелец: форма приглашения заводит карточку.
select public.tests_claims('a0490000-0000-0000-0000-000000000001','a0490000-0000-0000-0000-0000000000c1','owner-0049@test.kg');
set local role authenticated;
select throws_ok(
  $q$ select * from public.create_invitation('teacher', 'Приглашённый') $q$,
  '23514', null,
  'Приглашение второго специалиста на solo — тот же отказ по лимиту');
reset role;
select public.tests_claims(null, null);

select ok((select prosrc like '%pg_advisory_xact_lock%' from pg_proc where proname = 'teachers_check_limit'),
  'Триггер специалистов берёт advisory lock до счёта (Р7)');
select ok((select prosrc like '%pg_advisory_xact_lock%' from pg_proc where proname = 'students_check_limit'),
  'Триггер учеников берёт advisory lock до счёта (Р7)');

-- Архив освобождает лицензию, восстановление снова её занимает.
update public.teachers set deleted_at = now() where id = 'a0490000-0000-0000-0000-000000000010';
select lives_ok(
  $q$ insert into public.teachers (id, center_id, full_name) values ('a0490000-0000-0000-0000-000000000011','a0490000-0000-0000-0000-0000000000c1','Второй') $q$,
  'После архивации первого второй проходит — лицензия это живая карточка (Р5)');
select throws_ok(
  $q$ update public.teachers set deleted_at = null where id = 'a0490000-0000-0000-0000-000000000010' $q$,
  '23514', null,
  'Восстановление первого при занятой лицензии — отказ (Р6: вход в живые)');
select lives_ok(
  $q$ update public.teachers set full_name = 'Второй (правка)' where id = 'a0490000-0000-0000-0000-000000000011' $q$,
  'Правка живой карточки лимитом не проверяется (Р6)');

-- Превысивший центр: план понижен ниже факта — правка и архив проходят, рост нет.
select public.tests_claims('a0490000-0000-0000-0000-000000000002', null, 'platform-0049@test.kg');
update public.centers set plan = 'studio' where id = 'a0490000-0000-0000-0000-0000000000c1';
select public.tests_claims(null, null);
update public.teachers set deleted_at = null where id = 'a0490000-0000-0000-0000-000000000010';
insert into public.teachers (id, center_id, full_name) values ('a0490000-0000-0000-0000-000000000012','a0490000-0000-0000-0000-0000000000c1','Третий');
select public.tests_claims('a0490000-0000-0000-0000-000000000002', null, 'platform-0049@test.kg');
update public.centers set plan = 'solo' where id = 'a0490000-0000-0000-0000-0000000000c1';
select public.tests_claims(null, null);

select lives_ok(
  $q$ update public.teachers set full_name = 'Третий (правка)' where id = 'a0490000-0000-0000-0000-000000000012' $q$,
  'Центр с 3 специалистами на solo правит карточку');
select lives_ok(
  $q$ update public.teachers set deleted_at = now() where id = 'a0490000-0000-0000-0000-000000000012' $q$,
  'И архивирует — этим он в лимит и войдёт');
select throws_ok(
  $q$ insert into public.teachers (id, center_id, full_name) values ('a0490000-0000-0000-0000-000000000013','a0490000-0000-0000-0000-0000000000c1','Четвёртый') $q$,
  '23514', null,
  'Но расти не может');

-- Center: -1 = без ограничения.
select public.tests_claims('a0490000-0000-0000-0000-000000000002', null, 'platform-0049@test.kg');
update public.centers set plan = 'center' where id = 'a0490000-0000-0000-0000-0000000000c1';
select public.tests_claims(null, null);
select lives_ok(
  $q$ insert into public.teachers (id, center_id, full_name) values ('a0490000-0000-0000-0000-000000000013','a0490000-0000-0000-0000-0000000000c1','Четвёртый') $q$,
  'На Center лимита нет (-1)');
select public.tests_claims('a0490000-0000-0000-0000-000000000001','a0490000-0000-0000-0000-0000000000c1','owner-0049@test.kg');
set local role authenticated;
select lives_ok(
  $q$ select * from public.create_invitation('teacher', 'Приглашённый на Center') $q$,
  'И приглашение на Center проходит');
reset role;
select public.tests_claims(null, null);


-- 4. Лимит учеников: место занимает не-архивный ученик (Р5), пакетная вставка не обходит (Р6) ---------

select public.tests_claims('a0490000-0000-0000-0000-000000000002', null, 'platform-0049@test.kg');
update public.centers set plan = 'solo' where id = 'a0490000-0000-0000-0000-0000000000c1';
select public.tests_claims(null, null);

select lives_ok(
  $q$ insert into public.students (center_id, full_name, payer_id)
      select 'a0490000-0000-0000-0000-0000000000c1', 'Ученик ' || n, 'a0490000-0000-0000-0000-000000000030'
        from generate_series(1, 39) as n $q$,
  '39 учеников одним оператором — в лимит 40 укладываются');

select throws_ok(
  $q$ insert into public.students (center_id, full_name, payer_id)
      select 'a0490000-0000-0000-0000-0000000000c1', 'Ученик ' || n, 'a0490000-0000-0000-0000-000000000030'
        from generate_series(40, 41) as n $q$,
  '23514', null,
  'Ещё два одним оператором — отказ: AFTER-триггер видит строки своего оператора, пакет лимит не обходит (Р6)');

select lives_ok(
  $q$ insert into public.students (center_id, full_name, payer_id) values ('a0490000-0000-0000-0000-0000000000c1','Сороковой','a0490000-0000-0000-0000-000000000030') $q$,
  '40-й по одному проходит');
select throws_ok(
  $q$ insert into public.students (center_id, full_name, payer_id) values ('a0490000-0000-0000-0000-0000000000c1','Сорок первый','a0490000-0000-0000-0000-000000000030') $q$,
  '23514', null,
  '41-й — отказ');

-- Архив освобождает место, возврат из архива снова его занимает.
update public.students set status = 'archived' where center_id = 'a0490000-0000-0000-0000-0000000000c1' and full_name = 'Ученик 1';
select lives_ok(
  $q$ insert into public.students (center_id, full_name, payer_id) values ('a0490000-0000-0000-0000-0000000000c1','Сорок первый','a0490000-0000-0000-0000-000000000030') $q$,
  'После архивации одного 41-й проходит — место занимает не-архивный ученик (Р5)');
select throws_ok(
  $q$ update public.students set status = 'active' where center_id = 'a0490000-0000-0000-0000-0000000000c1' and full_name = 'Ученик 1' $q$,
  '23514', null,
  'Возврат из архива при полном списке — отказ (Р6: вход в считаемое состояние)');
select lives_ok(
  $q$ update public.students set notes = 'правка' where center_id = 'a0490000-0000-0000-0000-0000000000c1' and full_name = 'Ученик 2' $q$,
  'Правка карточки лимитом не проверяется');


-- 5. center_limits() (Р9) ------------------------------------------------------------------------------

select public.tests_claims('a0490000-0000-0000-0000-000000000001','a0490000-0000-0000-0000-0000000000c1','owner-0049@test.kg');
set local role authenticated;

select is((select public.center_limits() ->> 'plan'), 'solo', 'center_limits: план');
select is((select (public.center_limits() -> 'usage' ->> 'students')::int), 40, 'center_limits: учеников 40 — тот же счёт, что у триггера');
select is((select (public.center_limits() -> 'limits' ->> 'students')::int), 40, 'center_limits: лимит учеников 40');
select ok((select (public.center_limits() -> 'onboarding' ->> 'teacher')::boolean), 'center_limits: галочка «специалист» стоит');
select ok((select not (public.center_limits() -> 'onboarding' ->> 'lesson')::boolean), 'center_limits: галочки «занятие» нет');
reset role;

select public.tests_claims('a0490000-0000-0000-0000-000000000003','a0490000-0000-0000-0000-0000000000c1','parent-0049@test.kg');
set local role authenticated;
select throws_ok(
  $q$ select public.center_limits() $q$,
  '42501', null,
  'Родителю тариф центра не отдаётся');
reset role;

select * from finish();

rollback;
