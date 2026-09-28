-- pgTAP: emit_event закрыта для клиента (0075).
--
-- Главное, что ловит файл:
--   - у emit_event нет EXECUTE ни у кого, кроме владельца (aclexplode по всем
--     перегрузкам; включая bot_worker, public_booking и будущие роли);
--   - отказ под authenticated — именно по гранту («permission denied for
--     function»), а не по проверке членства: вызов идёт в СВОЙ центр, который
--     на прежнем main проходил;
--   - проверка членства осталась вторым рубежом (вызов от владельца функции с
--     claims чужого центра — 42501);
--   - цепочка событий из definer-RPC под authenticated жива: create_center и
--     record_payment по-прежнему пишут события;
--   - все вызывающие emit_event — definer, и у их владельца есть EXECUTE;
--     вью, политики, значения по умолчанию и триггеры её не вызывают
--     (иначе пошли бы от роли пользователя и упали бы молча).
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(16);


-- 1. Гранты ---------------------------------------------------------------------------------------

select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.pronamespace = 'public'::regnamespace and p.proname = 'emit_event'
        and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner $$,
  'EXECUTE на emit_event (все перегрузки) — только у владельца: ни PUBLIC, ни anon/authenticated/service_role, ни будущей роли');

select ok(
  (select bool_and(not has_function_privilege(r, 'public.emit_event(text,jsonb,uuid)', 'EXECUTE'))
     from unnest(array['anon', 'authenticated', 'service_role', 'bot_worker', 'public_booking', 'public']) r),
  'Ни одна прикладная роль не исполняет emit_event');


-- 2. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','75000000-0000-0000-0000-000000000001','authenticated','authenticated','owner-a-0075@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','75000000-0000-0000-0000-000000000002','authenticated','authenticated','owner-b-0075@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','75000000-0000-0000-0000-000000000003','authenticated','authenticated','newbie-0075@test.kg','','','','','','','','');
insert into public.centers (id, name, slug, settings) values
  ('75000000-0000-0000-0000-0000000000a1','Центр A 0075','centr-a-0075','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('75000000-0000-0000-0000-0000000000b1','Центр Б 0075','centr-b-0075','{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.memberships (user_id, center_id, role) values
  ('75000000-0000-0000-0000-000000000001','75000000-0000-0000-0000-0000000000a1','owner'),
  ('75000000-0000-0000-0000-000000000002','75000000-0000-0000-0000-0000000000b1','owner');
insert into public.payers (id, center_id, full_name, phone) values
  ('75000000-0000-0000-0000-00000000dd01','75000000-0000-0000-0000-0000000000a1','Плательщик 0075','+996700007575');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;


-- 3. Отказ по гранту, а не по членству -------------------------------------------------------------

select public.tests_claims('75000000-0000-0000-0000-000000000001','75000000-0000-0000-0000-0000000000a1');
set local role authenticated;
select throws_ok(
  $q$ select public.emit_event('digest.daily', '{"forged": true}'::jsonb) $q$,
  '42501', 'permission denied for function emit_event',
  'Владелец СВОЕГО центра не может вызвать emit_event: отказ именно по гранту (на прежнем main этот вызов проходил)');
select throws_ok(
  $q$ select public.emit_event('lesson.reminder', '{}'::jsonb, '75000000-0000-0000-0000-0000000000a1') $q$,
  '42501', 'permission denied for function emit_event',
  'И с явным центром — то же');
reset role;


-- 4. Проверка членства осталась вторым рубежом ------------------------------------------------------

select lives_ok(
  $q$ select public.emit_event('center.created', '{"probe": "own"}'::jsonb) $q$,
  'От владельца функции с claims владельца центра A вызов проходит (definer-RPC работают так же)');
select is(
  (select center_id from public.events where payload ->> 'probe' = 'own'),
  '75000000-0000-0000-0000-0000000000a1'::uuid, 'Событие записано в центр из claims');
select throws_ok(
  $q$ select public.emit_event('center.created', '{}'::jsonb, '75000000-0000-0000-0000-0000000000b1') $q$,
  '42501', 'Нет доступа к центру 75000000-0000-0000-0000-0000000000b1',
  'Центр Б при claims владельца A — 42501 именно от проверки членства (текст из 0002), а не от гранта: рубеж жив');


-- 5. Цепочка событий из definer-RPC под authenticated жива ------------------------------------------

select public.tests_claims('75000000-0000-0000-0000-000000000003', null);
set local role authenticated;
create temporary table t_new (id uuid);
grant all on t_new to public;
select lives_ok(
  $q$ insert into t_new select public.create_center('Новый центр 0075', 'Бишкек') $q$,
  'create_center под authenticated проходит');
reset role;
select ok(
  exists (select 1 from public.events e, t_new n where e.center_id = n.id and e.type = 'center.created'),
  'create_center (definer) по-прежнему пишет center.created — цепочка не сломана');

select public.tests_claims('75000000-0000-0000-0000-000000000001','75000000-0000-0000-0000-0000000000a1');
set local role authenticated;
select lives_ok(
  $q$ select public.record_payment('75000000-0000-0000-0000-00000000dd01', 10000, 'payment', null, null, null, now(), 'проба 0075') $q$,
  'record_payment под authenticated проходит');
reset role;
select ok(
  exists (select 1 from public.events where type = 'payment.received' and center_id = '75000000-0000-0000-0000-0000000000a1'),
  'и пишет payment.received: definer вызывает emit_event от владельца');
select public.tests_claims(null, null);


-- 6. Заборы: кто вызывает emit_event ---------------------------------------------------------------

select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where p.prokind in ('f', 'p')
        and (p.prosrc ~* '\memit_event\s*\(' or coalesce(pg_get_function_sqlbody(p.oid)::text, '') ~* '\memit_event\s*\(')
        and n.nspname not in ('pg_catalog', 'information_schema')
        and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
        and (not p.prosecdef
             or not has_function_privilege(p.proowner, 'public.emit_event(text,jsonb,uuid)'::regprocedure, 'EXECUTE')) $$,
  'Все функции, вызывающие emit_event, — SECURITY DEFINER, и у владельца есть EXECUTE: от роли пользователя её не зовёт никто');

select is_empty(
  $$ select c.oid::regclass::text from pg_class c
      where c.relkind in ('v', 'm') and c.relnamespace = 'public'::regnamespace
        and pg_get_viewdef(c.oid) ~* '\memit_event\s*\(' $$,
  'Ни одно представление не вызывает emit_event');

select is_empty(
  $$ select p.polname::text from pg_policy p
      where coalesce(pg_get_expr(p.polqual, p.polrelid), '') ~* '\memit_event\s*\('
         or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') ~* '\memit_event\s*\(' $$,
  'Ни одна политика не вызывает emit_event');

select is_empty(
  $$ select a.adrelid::regclass::text from pg_attrdef a
      where pg_get_expr(a.adbin, a.adrelid) ~* '\memit_event\s*\(' $$,
  'Ни одно значение по умолчанию не вызывает emit_event');

select is_empty(
  $$ select t.tgname::text from pg_trigger t
      where not t.tgisinternal and pg_get_triggerdef(t.oid) ~* '\memit_event\s*\(' $$,
  'Ни одно определение триггера (WHEN и др.) не вызывает emit_event напрямую');

select * from finish();
rollback;
