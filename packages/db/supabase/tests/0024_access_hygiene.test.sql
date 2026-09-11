-- pgTAP: гигиена доступа (0024).
-- Заборы — по каталогу pg_class, без белых списков: новая таблица или вью с
-- default privileges роняет тест, пока автор не снимет лишнее.
-- Claims задаются явно перед каждым блоком: reset role их не сбрасывает.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(21);


-- 1-6. Заборы по каталогу ------------------------------------------------------------

select ok(
  (select bool_and(not has_table_privilege('authenticated', c.oid, 'DELETE'))
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p', 'v')),
  'authenticated не имеет DELETE ни на одной таблице и вью public — удаление есть только в revoke_membership'
);
select ok(
  (select bool_and(
       not has_table_privilege('anon', c.oid, 'SELECT')
       and not has_table_privilege('anon', c.oid, 'INSERT')
       and not has_table_privilege('anon', c.oid, 'UPDATE')
       and not has_table_privilege('anon', c.oid, 'DELETE'))
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p', 'v')),
  'anon не имеет ни одного права ни на одну таблицу и вью public (второй слой под RLS)'
);
select ok(
  (select bool_and(
       not has_table_privilege('authenticated', c.oid, 'INSERT')
       and not has_table_privilege('authenticated', c.oid, 'UPDATE'))
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'),
  'authenticated не пишет ни в одну вью public'
);
select ok(
  (select bool_and(
       has_table_privilege('authenticated', c.oid, 'SELECT')
       and has_table_privilege('authenticated', c.oid, 'INSERT')
       and has_table_privilege('authenticated', c.oid, 'UPDATE'))
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in ('students', 'payers', 'rooms', 'services', 'groups', 'group_students', 'lessons', 'invitations')),
  'Рабочие таблицы 0004–0006 сохранили select/insert/update — снят только DELETE'
);
select ok(
  (select bool_and(
       has_table_privilege('authenticated', c.oid, 'SELECT')
       and not has_table_privilege('authenticated', c.oid, 'INSERT')
       and not has_table_privilege('authenticated', c.oid, 'UPDATE'))
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in ('lesson_participants', 'audit_log', 'events', 'memberships')),
  'Денормализованные и служебные таблицы — только чтение'
);
select ok(
  has_table_privilege('service_role', 'public.students', 'DELETE'),
  'service_role не задет — revoke только у public/anon/authenticated'
);


-- 7. Политика memberships — auth.uid() как InitPlan ---------------------------------

select ok(
  (select qual like '%SELECT auth.uid()%' from pg_policies
    where schemaname = 'public' and tablename = 'memberships'
      and policyname = 'memberships_select_self_or_admin'),
  'memberships_select_self_or_admin вызывает auth.uid() через (select …)'
);


-- Фикстура ------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-b@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','newcomer@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-000000000024','Центр гигиены','centr-hygiene','{}'::jsonb);

insert into public.memberships (user_id, center_id, role) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000024','owner'),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000024','teacher');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 8. Политика работает как прежде ---------------------------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000024');
set local role authenticated;
select is(
  (select count(*)::int from public.memberships), 1,
  'Специалист видит только собственную строку memberships'
);
reset role;


-- 9-13. Последний владелец — триггер на любом пути -----------------------------------------

select throws_ok(
  $q$ update public.memberships set role = 'admin'
       where user_id = '11111111-1111-1111-1111-111111111111' $q$,
  '23514', 'Нельзя понизить последнего владельца центра',
  'Прямой update роли единственного владельца — отказ (не только через change_member_role)'
);
select throws_ok(
  $q$ delete from public.memberships
       where user_id = '11111111-1111-1111-1111-111111111111' $q$,
  '23514', null, 'Прямое удаление единственного владельца — отказ'
);

insert into public.memberships (user_id, center_id, role) values
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-000000000024','owner');

select lives_ok(
  $q$ update public.memberships set role = 'admin'
       where user_id = '11111111-1111-1111-1111-111111111111' $q$,
  'При двух владельцах понижение одного проходит'
);
select throws_ok(
  $q$ update public.memberships set role = 'teacher'
       where user_id = '22222222-2222-2222-2222-222222222222' $q$,
  '23514', null, 'Оставшийся владелец — снова последний, понижение отбито'
);
select lives_ok(
  $q$ update public.memberships set role = 'owner'
       where user_id = '11111111-1111-1111-1111-111111111111' $q$,
  'Повышение до владельца триггер не трогает'
);


-- 14-19. accept_invitation: участнику — отказ, новичку — членство ---------------------------

insert into public.invitations (id, center_id, role, token) values
  ('99990000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000024','parent','tok-0024-existing-member'),
  ('99990000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-000000000024','teacher','tok-0024-newcomer');

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-000000000024');
set local role authenticated;

select throws_ok(
  $q$ select public.accept_invitation('tok-0024-existing-member') $q$,
  '23505', 'Вы уже участник этого центра — роль меняет владелец',
  'Владелец по ссылке с ролью parent — отказ, а не понижение (было: on conflict do update set role)'
);

reset role;

select is(
  (select role from public.memberships where user_id = '22222222-2222-2222-2222-222222222222'),
  'owner', 'Роль владельца не изменилась'
);
select ok(
  (select accepted_at is null from public.invitations where id = '99990000-0000-0000-0000-000000000001'),
  'Приглашение не потрачено — его можно отдать тому, кому оно предназначалось'
);

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-000000000024');
set local role authenticated;

select lives_ok(
  $q$ select public.accept_invitation('tok-0024-newcomer') $q$,
  'Новичок принимает приглашение как раньше'
);

reset role;

select is(
  (select role from public.memberships where user_id = '44444444-4444-4444-4444-444444444444'),
  'teacher', 'Членство создано с ролью из приглашения'
);
select ok(
  (select accepted_at is not null from public.invitations where id = '99990000-0000-0000-0000-000000000002'),
  'Приглашение отмечено использованным'
);


-- 20-21. Гранты триггерной функции -------------------------------------------------------------

select ok(
  not has_function_privilege('authenticated', 'public.memberships_last_owner_guard()', 'EXECUTE'),
  'memberships_last_owner_guard закрыта для authenticated'
);
select ok(
  not has_function_privilege('anon', 'public.memberships_last_owner_guard()', 'EXECUTE'),
  '…и для anon'
);

select * from finish();

rollback;
