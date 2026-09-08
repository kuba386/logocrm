-- pgTAP: дымовой тест RLS.
-- Запуск: pnpm db:test   (supabase test db)
--
-- Тест не проверяет, ЧТО видит роль — это дело тестов по каждой миграции.
-- Он проверяет, что запрос вообще выполняется: под каждой ролью делается
-- простой select из каждой таблицы с включённым RLS.
--
-- Ловит класс отказов, который дважды ломал проект:
--
--   * `infinite recursion detected in policy` (42P17) — политика ссылается
--     на таблицу, чья политика ссылается обратно. На этапе 3 это уронило
--     не только новые lessons, но и students из этапа 2;
--   * политика зовёт функцию, объявленную ниже по файлу (42883);
--   * таблица приехала без RLS вообще.
--
-- Главное свойство: список таблиц берётся из каталога, а не пишется руками.
-- Таблица из будущей миграции попадает под проверку сама, без правки теста.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select * from no_plan();

-- Фикстуры --------------------------------------------------------------------

insert into auth.users (instance_id, id, aud, role, email)
values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated', 'smoke-owner@test.kg'),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated', 'smoke-admin@test.kg'),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated', 'smoke-teacher@test.kg'),
  ('00000000-0000-0000-0000-000000000000', '44444444-4444-4444-4444-444444444444', 'authenticated', 'authenticated', 'smoke-parent@test.kg');

insert into public.centers (id, name, slug, settings)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Центр дымовой', 'centr-dymovoy', '{}'::jsonb);

insert into public.memberships (user_id, center_id, role)
values
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'owner'),
  ('22222222-2222-2222-2222-222222222222', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'admin'),
  ('33333333-3333-3333-3333-333333333333', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'teacher'),
  ('44444444-4444-4444-4444-444444444444', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'parent');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', p_user,
      'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center)
    )::text,
    true
  );
end;
$$;

-- Выполняет запрос и возвращает 'ok' либо код ошибки.
--
-- 42501 тоже 'ok': явный отказ в правах — это работающая защита, а не
-- поломка. Тест ловит другое — когда политика не может быть вычислена.
create or replace function public.tests_probe(p_sql text)
  returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception
  when insufficient_privilege then
    return 'ok';
  when others then
    return sqlstate || ': ' || sqlerrm;
end;
$$;


-- 1. Список таблиц не пуст ----------------------------------------------------

-- Без этой проверки тест «проходит», когда каталог ничего не вернул: ноль
-- запусков lives_ok — это ноль провалов.
select cmp_ok(
  (select count(*) from pg_tables where schemaname = 'public' and rowsecurity)::int,
  '>=',
  8,
  'В public есть таблицы с включённым RLS — тесту есть что проверять'
);


-- 2. Таблиц без RLS в public нет ----------------------------------------------

select is(
  (select coalesce(string_agg(tablename, ', ' order by tablename), '')
     from pg_tables where schemaname = 'public' and not rowsecurity),
  '',
  'Каждая таблица в public закрыта RLS'
);


-- 3. Под каждой ролью select из каждой таблицы выполняется --------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
set local role authenticated;

select is(
  public.tests_probe(format('select count(*) from %I.%I', schemaname, tablename)),
  'ok',
  format('owner: select из %s выполняется', tablename)
)
from pg_tables where schemaname = 'public' and rowsecurity order by tablename;

reset role;


select public.tests_claims('22222222-2222-2222-2222-222222222222', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
set local role authenticated;

select is(
  public.tests_probe(format('select count(*) from %I.%I', schemaname, tablename)),
  'ok',
  format('admin: select из %s выполняется', tablename)
)
from pg_tables where schemaname = 'public' and rowsecurity order by tablename;

reset role;


select public.tests_claims('33333333-3333-3333-3333-333333333333', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
set local role authenticated;

select is(
  public.tests_probe(format('select count(*) from %I.%I', schemaname, tablename)),
  'ok',
  format('teacher: select из %s выполняется', tablename)
)
from pg_tables where schemaname = 'public' and rowsecurity order by tablename;

reset role;


select public.tests_claims('44444444-4444-4444-4444-444444444444', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
set local role authenticated;

select is(
  public.tests_probe(format('select count(*) from %I.%I', schemaname, tablename)),
  'ok',
  format('parent: select из %s выполняется', tablename)
)
from pg_tables where schemaname = 'public' and rowsecurity order by tablename;

reset role;


select * from finish();

rollback;
