-- pgTAP: контакт платформы в отказе второго trial-центра (0083).
--
-- Обе ветки assert_one_trial_center — точным текстом с телефоном: сам
-- открывает второй trial (create_center) и повышение до owner участника со
-- своим trial (change_member_role). Исходник функции без «@» — почта не
-- вернётся ни в одну ветку незаметно. ACL и security definer пережили
-- create or replace.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(7);


-- Фикстура ------------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0830000-0000-0000-0000-000000000001','authenticated','authenticated','owner-a-0083@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0830000-0000-0000-0000-000000000002','authenticated','authenticated','owner-b-0083@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0830000-0000-0000-0000-000000000003','authenticated','authenticated','member-0083@test.kg','','','','','','','','');

-- План по умолчанию — trial: все три центра пробные.
insert into public.centers (id, name, slug) values
  ('a0830000-0000-0000-0000-0000000000c1','Центр 0083 А','centr-0083-a'),
  ('a0830000-0000-0000-0000-0000000000c2','Центр 0083 Б','centr-0083-b'),
  ('a0830000-0000-0000-0000-0000000000c3','Центр 0083 В','centr-0083-c');

-- Без сессии триггер trial-лимита молчит (0052): фикстура вставляется свободно.
insert into public.memberships (user_id, center_id, role) values
  ('a0830000-0000-0000-0000-000000000001','a0830000-0000-0000-0000-0000000000c1','owner'),
  ('a0830000-0000-0000-0000-000000000002','a0830000-0000-0000-0000-0000000000c2','owner'),
  ('a0830000-0000-0000-0000-000000000003','a0830000-0000-0000-0000-0000000000c2','admin'),
  ('a0830000-0000-0000-0000-000000000003','a0830000-0000-0000-0000-0000000000c3','owner');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 1. Тексты отказа ----------------------------------------------------------------------------------------

select public.tests_claims('a0830000-0000-0000-0000-000000000001', 'a0830000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.create_center('Второй trial 0083', 'Ош') $q$,
  '23514',
  'У вас уже есть центр на пробном периоде. Второй центр открывает администратор платформы — позвоните или напишите: 0707 001 107.',
  'Второй trial самому себе — отказ с телефоном платформы');
reset role;

select public.tests_claims('a0830000-0000-0000-0000-000000000002', 'a0830000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_ok(
  $q$ select public.change_member_role('a0830000-0000-0000-0000-000000000003', 'owner') $q$,
  '23514',
  'У этого участника уже есть свой центр на пробном периоде — сделать его владельцем второго trial-центра может только администратор платформы: 0707 001 107.',
  'Повышение до owner участника со своим trial — отказ с телефоном платформы');
reset role;
select public.tests_claims(null, null);


-- 2. Исходник и права -------------------------------------------------------------------------------------

select ok(
  (select position('@' in p.prosrc) = 0
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'assert_one_trial_center'),
  'В исходнике assert_one_trial_center нет почты');
select ok(
  (select p.prosrc like '%0707 001 107%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'assert_one_trial_center'),
  'В исходнике assert_one_trial_center — телефон платформы');
select ok(
  (select p.prosecdef
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'assert_one_trial_center'),
  'assert_one_trial_center осталась security definer');
select ok(
  not has_function_privilege('anon', 'public.assert_one_trial_center(uuid, boolean)', 'execute'),
  'anon не вызывает assert_one_trial_center');
select ok(
  not has_function_privilege('authenticated', 'public.assert_one_trial_center(uuid, boolean)', 'execute'),
  'authenticated не вызывает assert_one_trial_center напрямую — только через триггер');

select * from finish();
rollback;
