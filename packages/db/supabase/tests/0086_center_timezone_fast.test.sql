-- pgTAP: пояс центра без скана tzdata (0086).
--
-- Каталог: center_timezone не читает pg_timezone_names, сохраняет definer,
-- stable и search_path; триггерная функция закрыта для всех ролей, триггер
-- before insert/update на centers. Чтение: пояс центра, дефолт, через
-- current_center(). Запись владельцем: всё, кроме точного имени из
-- pg_timezone_names, — 22023 (POSIX «UTC+6», «MSK», пустая строка, число,
-- null, объект, нижний регистр). INSERT с мусором — 22023 и от роли фикстуры.
-- Валидная смена проходит. Запись, не меняющая пояс (set_booking_enabled,
-- имя), проходит и при устаревшем поясе (дрейф tzdata, Р2).
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(27);


-- Фикстура ---------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values ('00000000-0000-0000-0000-000000000000', '86000000-0000-0000-0000-000000000001',
        'authenticated', 'authenticated', 'owner-0086@test.kg', '', '', '', '', '', '', '', '');

insert into public.centers (id, name, slug, settings) values
  ('86000000-0000-0000-0000-0000000000c1', 'Центр А 0086', 'centr-a-0086', '{"timezone":"Asia/Almaty"}'::jsonb),
  ('86000000-0000-0000-0000-0000000000c2', 'Центр Б 0086', 'centr-b-0086', '{}'::jsonb);

insert into public.memberships (user_id, center_id, role) values
  ('86000000-0000-0000-0000-000000000001', '86000000-0000-0000-0000-0000000000c1', 'owner');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 1. Каталог ---------------------------------------------------------------------------------------

select ok(
  (select p.prosrc not like '%pg_timezone_names%' from pg_proc p
    where p.oid = 'public.center_timezone(uuid)'::regprocedure),
  'center_timezone не читает pg_timezone_names — нет скана tzdata на каждый вызов');

select ok(
  (select p.prosecdef and p.provolatile = 's' and 'search_path=""' = any(p.proconfig) from pg_proc p
    where p.oid = 'public.center_timezone(uuid)'::regprocedure),
  'center_timezone: security definer, stable, search_path пуст — как в 0052');

select ok(
  has_function_privilege('authenticated', 'public.center_timezone(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.center_timezone(uuid)', 'execute'),
  'center_timezone: authenticated — да, anon — нет');

select is_empty(
  $$ select r
       from unnest(array['public', 'anon', 'authenticated', 'service_role']) r
      where has_function_privilege(r, 'public.centers_validate_timezone()', 'execute') $$,
  'centers_validate_timezone не исполняется ни PUBLIC, ни одной ролью приложения');

select ok(
  not (select p.prosecdef from pg_proc p where p.oid = 'public.centers_validate_timezone()'::regprocedure),
  'триггерная функция — security invoker (Р5)');

select ok(
  exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.centers'::regclass
       and t.tgname = 'centers_validate_timezone'
       and not t.tgisinternal
       and (t.tgtype & 1) = 1      -- FOR EACH ROW
       and (t.tgtype & 2) = 2      -- BEFORE
       and (t.tgtype & 4) = 4      -- INSERT
       and (t.tgtype & 16) = 16    -- UPDATE
       and t.tgattr::int2[] = array[(
         select a.attnum from pg_attribute a
          where a.attrelid = 'public.centers'::regclass and a.attname = 'settings')]),
  'триггер centers_validate_timezone: before insert or update of settings, for each row');


-- 2. Чтение ----------------------------------------------------------------------------------------

select is(public.center_timezone('86000000-0000-0000-0000-0000000000c1'), 'Asia/Almaty', 'пояс центра из settings');
select is(public.center_timezone('86000000-0000-0000-0000-0000000000c2'), 'Asia/Bishkek', 'без ключа — Asia/Bishkek');

select public.tests_claims('86000000-0000-0000-0000-000000000001', '86000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is(public.center_timezone(), 'Asia/Almaty', 'без аргумента — пояс текущего центра');


-- 3. Запись владельцем: мусор → 22023 --------------------------------------------------------------

select throws_ok(
  $$ update public.centers set settings = settings || '{"timezone":"Mars/Olympus"}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  '22023', null, 'несуществующее имя — отказ');

select throws_ok(
  $$ update public.centers set settings = settings || '{"timezone":"UTC+6"}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  '22023', null, 'POSIX «UTC+6» — отказ (Postgres понял бы его как UTC-6)');

select throws_ok(
  $$ update public.centers set settings = settings || '{"timezone":"MSK"}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  '22023', null, 'аббревиатура «MSK» — отказ (Intl её не знает)');

select throws_ok(
  $$ update public.centers set settings = settings || '{"timezone":""}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  '22023', null, 'пустая строка — отказ');

select throws_ok(
  $$ update public.centers set settings = settings || '{"timezone":6}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  '22023', null, 'число — отказ');

select throws_ok(
  $$ update public.centers set settings = settings || '{"timezone":null}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  '22023', null, 'JSON null — отказ');

select throws_ok(
  $$ update public.centers set settings = settings || '{"timezone":{"name":"Asia/Bishkek"}}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  '22023', null, 'объект — отказ');

select throws_ok(
  $$ update public.centers set settings = settings || '{"timezone":"asia/bishkek"}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  '22023', null, 'нижний регистр — отказ: одна каноническая форма имени (Р3)');


-- 4. Запись владельцем: допустимое -----------------------------------------------------------------

select lives_ok(
  $$ update public.centers set settings = settings || '{"timezone":"Asia/Tokyo"}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  'точное имя из pg_timezone_names проходит');

select is(public.center_timezone(), 'Asia/Tokyo', 'новый пояс сразу виден');

select lives_ok(
  $$ select public.set_booking_enabled(true) $$,
  'set_booking_enabled проходит — пояс не меняется');

select lives_ok(
  $$ update public.centers set name = 'Центр А 0086 (новое имя)'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  'смена имени центра проходит');

reset role;


-- 5. INSERT с мусором — от роли фикстуры тоже ------------------------------------------------------

select throws_ok(
  $$ insert into public.centers (id, name, slug, settings)
     values ('86000000-0000-0000-0000-0000000000c3', 'Центр В 0086', 'centr-v-0086', '{"timezone":"Nowhere/Land"}') $$,
  '22023', null, 'INSERT с мусором — отказ и без сессии');

select lives_ok(
  $$ insert into public.centers (id, name, slug, settings)
     values ('86000000-0000-0000-0000-0000000000c4', 'Центр Г 0086', 'centr-g-0086', '{"timezone":"Europe/Moscow"}') $$,
  'INSERT с точным именем проходит');


-- 6. Дрейф tzdata: устаревшее имя без записи не блокирует другие настройки (Р2) --------------------

alter table public.centers disable trigger centers_validate_timezone;
update public.centers set settings = settings || '{"timezone":"Mars/Drift"}'
 where id = '86000000-0000-0000-0000-0000000000c1';
alter table public.centers enable trigger centers_validate_timezone;

select is(public.center_timezone('86000000-0000-0000-0000-0000000000c1'), 'Mars/Drift',
  'при дрейфе center_timezone отдаёт имя как есть — проверки при чтении нет (остаточный риск 0086)');

select public.tests_claims('86000000-0000-0000-0000-000000000001', '86000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select lives_ok(
  $$ select public.set_booking_enabled(false) $$,
  'set_booking_enabled проходит и при устаревшем поясе — триггер проверяет только смену пояса');

select throws_ok(
  $$ update public.centers set settings = settings || '{"timezone":"Mars/Other"}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  '22023', null, 'замена устаревшего на другой мусор — отказ');

select lives_ok(
  $$ update public.centers set settings = settings || '{"timezone":"Asia/Bishkek"}'
      where id = '86000000-0000-0000-0000-0000000000c1' $$,
  'исправление устаревшего на валидное проходит');

reset role;

select * from finish();
rollback;
