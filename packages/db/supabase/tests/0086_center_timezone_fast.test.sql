-- pgTAP: center_timezone() без pg_timezone_names (0086).
--
-- Правило: имя IANA «Область/Место» или UTC, известное tzdata, иначе
-- Asia/Bishkek. Набор случаев — тот же, что CENTER_TIME_ZONE_CASES в
-- packages/core/src/timezone.ts (Vitest): меняешь правило — меняешь обе
-- стороны. Плюс: нет ключа и несуществующий центр — дефолт; тело функции не
-- ходит в pg_timezone_names; definer, stable, PARALLEL UNSAFE (блок
-- исключений), search_path ''; грантов anon нет; 2000 вызовов на валидном и на
-- мусорном поясе — меньше секунды (старая версия — ~100 с).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(30);

insert into public.centers (id, name, slug, settings) values
  ('a0860000-0000-0000-0000-0000000000c1', 'Центр 0086', 'centr-0086', '{}'::jsonb),
  ('a0860000-0000-0000-0000-0000000000c2', 'Центр 0086 мусор', 'centr-0086-b', '{"timezone":"Mars/Olympus"}'::jsonb);


-- 1. Общий набор случаев (= Vitest) -------------------------------------------------------------

update public.centers set settings = jsonb_build_object('timezone', '"Asia/Bishkek"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс Asia/Bishkek → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"Europe/Moscow"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Europe/Moscow', 'пояс Europe/Moscow → Europe/Moscow');
update public.centers set settings = jsonb_build_object('timezone', '"America/Argentina/Buenos_Aires"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'America/Argentina/Buenos_Aires', 'пояс America/Argentina/Buenos_Aires → America/Argentina/Buenos_Aires');
update public.centers set settings = jsonb_build_object('timezone', '"Etc/GMT+6"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Etc/GMT+6', 'пояс Etc/GMT+6 → Etc/GMT+6');
update public.centers set settings = jsonb_build_object('timezone', '"UTC"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'UTC', 'пояс UTC → UTC');
update public.centers set settings = jsonb_build_object('timezone', '""'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс пустая строка → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '6'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс число 6 → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', 'null'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс null → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"Mars/Olympus"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс Mars/Olympus → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"MSK"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс MSK → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"Z"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс Z → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"UTC+6"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс UTC+6 → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"+6"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс +6 → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"+06:00"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс +06:00 → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"Factory"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс Factory → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"EST5EDT"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс EST5EDT → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"asia/bishkek"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс asia/bishkek → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"posix/Asia/Bishkek"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс posix/Asia/Bishkek → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', '"Asia/../Bishkek"'::jsonb) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс Asia/../Bishkek → Asia/Bishkek');
update public.centers set settings = jsonb_build_object('timezone', to_jsonb('Asia/' || repeat('X', 300))) where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'пояс строка 305 символов → Asia/Bishkek');

update public.centers set settings = '{}'::jsonb where id = 'a0860000-0000-0000-0000-0000000000c1';
select is(public.center_timezone('a0860000-0000-0000-0000-0000000000c1'), 'Asia/Bishkek', 'Нет ключа timezone → Asia/Bishkek');
select is(public.center_timezone('a0860000-0000-0000-0000-00000000dead'), 'Asia/Bishkek', 'Несуществующий центр → Asia/Bishkek');


-- 2. Форма функции ------------------------------------------------------------------------------

select ok(
  (select p.prosrc not like '%pg_timezone_names%' from pg_proc p where p.oid = 'public.center_timezone(uuid)'::regprocedure),
  'Тело center_timezone не читает pg_timezone_names (50 мс на вызов)');
select ok(
  (select p.prosecdef and p.provolatile = 's' from pg_proc p where p.oid = 'public.center_timezone(uuid)'::regprocedure),
  'center_timezone: security definer, stable');
select is(
  (select p.proparallel::text from pg_proc p where p.oid = 'public.center_timezone(uuid)'::regprocedure),
  'u', 'center_timezone: PARALLEL UNSAFE — блок исключений нельзя в параллельном режиме');
select ok(
  (select 'search_path=""' = any(p.proconfig) from pg_proc p where p.oid = 'public.center_timezone(uuid)'::regprocedure),
  'center_timezone: search_path пустой');
select ok(not has_function_privilege('anon', 'public.center_timezone(uuid)', 'execute'), 'anon: нет EXECUTE');
select ok(has_function_privilege('authenticated', 'public.center_timezone(uuid)', 'execute'), 'authenticated: EXECUTE есть');


-- 3. Скорость -----------------------------------------------------------------------------------
-- Замер clock_timestamp(), а не lives_ok под statement_timeout: lives_ok не ловит
-- 57014, и таймаут обрывал бы файл вместо «not ok». Таймаут — только страховка
-- от зависания старой версии, и сразу возвращается.

create temp table t_elapsed (label text primary key, ms numeric not null);
set local statement_timeout = '60s';
do $$
declare
  t0 timestamptz;
  v  text;
begin
  t0 := clock_timestamp();
  update public.centers set settings = '{"timezone":"Asia/Bishkek"}'::jsonb where id = 'a0860000-0000-0000-0000-0000000000c1';
  for i in 1..2000 loop
    v := public.center_timezone('a0860000-0000-0000-0000-0000000000c1');
  end loop;
  insert into t_elapsed values ('valid', extract(epoch from clock_timestamp() - t0) * 1000);

  t0 := clock_timestamp();
  for i in 1..2000 loop
    v := public.center_timezone('a0860000-0000-0000-0000-0000000000c2');
  end loop;
  insert into t_elapsed values ('garbage', extract(epoch from clock_timestamp() - t0) * 1000);
end $$;
set local statement_timeout = default;

select ok((select ms from t_elapsed where label = 'valid') < 1000,
  '2000 вызовов на валидном поясе — меньше 1 с (было ~100 с)');
select ok((select ms from t_elapsed where label = 'garbage') < 1000,
  '2000 вызовов на мусорном поясе — меньше 1 с');


select * from finish();
rollback;
