-- pgTAP: гигиена доступа (0024).
-- Заборы — по каталогу pg_class, без белых списков: новая таблица или вью с
-- default privileges роняет тест, пока автор не снимет лишнее.
-- Claims задаются явно перед каждым блоком: reset role их не сбрасывает.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(34);


-- 1-9. Заборы по каталогу ------------------------------------------------------------

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
select is_empty(
  $$ select table_name from information_schema.role_column_grants
      where table_schema = 'public' and grantee = 'anon' $$,
  'anon без колоночных грантов — has_table_privilege их не видит'
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
      and c.relname in ('students', 'payers', 'rooms', 'services', 'groups', 'group_students', 'lessons')),
  'Рабочие таблицы 0005–0006 сохранили select/insert/update — снят только DELETE'
);
select ok(
  (select bool_and(
       has_table_privilege('authenticated', c.oid, 'SELECT')
       and not has_table_privilege('authenticated', c.oid, 'INSERT')
       and not has_table_privilege('authenticated', c.oid, 'UPDATE'))
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in ('lesson_participants', 'audit_log', 'events', 'memberships',
                        'ai_usage')),
  'Денормализованные и служебные таблицы — только чтение'
);
-- 0041: токен диктовки и очередь работ ИИ не видны прикладным ролям вовсе —
-- ни select. Токен возвращается один раз из RPC (как telegram_link_codes),
-- очередь ИИ это внутренняя механика воркера.
select ok(
  (select bool_and(
       not has_table_privilege('authenticated', c.oid, 'SELECT')
       and not has_table_privilege('authenticated', c.oid, 'INSERT')
       and not has_table_privilege('authenticated', c.oid, 'UPDATE'))
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in ('lesson_voice_requests', 'ai_jobs')),
  'lesson_voice_requests и ai_jobs закрыты от authenticated целиком (0041)'
);
select ok(
  has_table_privilege('service_role', 'public.students', 'DELETE'),
  'service_role не задет — revoke только у public/anon/authenticated'
);
select ok(
  has_table_privilege('authenticated', 'public.invitations', 'SELECT')
  and not has_table_privilege('authenticated', 'public.invitations', 'INSERT')
  and not has_table_privilege('authenticated', 'public.invitations', 'UPDATE')
  and has_column_privilege('authenticated', 'public.invitations', 'expires_at', 'UPDATE')
  and not has_column_privilege('authenticated', 'public.invitations', 'role', 'UPDATE'),
  'invitations: чтение, update только expires_at (cancelInvitation); insert — через create_invitation'
);
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
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','newcomer@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','admin@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-000000000024','Центр гигиены','centr-hygiene','{}'::jsonb),
  ('cccccccc-0000-0000-0000-000000000025','Другой центр','centr-hygiene-2','{}'::jsonb);

insert into public.memberships (user_id, center_id, role) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000024','owner'),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000024','teacher'),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-000000000024','admin');

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000024','cccccccc-0000-0000-0000-000000000024','Специалист без профиля');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 10. Политика работает как прежде --------------------------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000024');
set local role authenticated;
select is(
  (select count(*)::int from public.memberships), 1,
  'Специалист видит только собственную строку memberships'
);
reset role;


-- 11-19. Последний владелец — триггер на любом пути ----------------------------------------

select throws_ok(
  $q$ update public.memberships set role = 'admin'
       where user_id = '11111111-1111-1111-1111-111111111111' $q$,
  '23514', 'В центре должен остаться хотя бы один владелец',
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

-- Штатный путь при двух владельцах: отказ не приходит из триггера.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000024');
set local role authenticated;
select lives_ok(
  $q$ select public.change_member_role('22222222-2222-2222-2222-222222222222', 'admin') $q$,
  'change_member_role понижает второго владельца — триггер штатному пути не мешает'
);
reset role;

update public.memberships set role = 'owner' where user_id = '22222222-2222-2222-2222-222222222222';

select lives_ok(
  $q$ delete from public.memberships
       where user_id = '22222222-2222-2222-2222-222222222222' $q$,
  'Удаление одного из двух владельцев проходит — DELETE-ветка триггера возвращает old'
);
select ok(
  (select prosrc like '%pg_advisory_xact_lock%' from pg_proc
    where proname = 'memberships_last_owner_guard'),
  'Триггер берёт замок по центру — две параллельные транзакции не понизят обоих владельцев'
);
select throws_ok(
  $q$ update public.memberships set center_id = 'cccccccc-0000-0000-0000-000000000025'
       where user_id = '11111111-1111-1111-1111-111111111111' $q$,
  '23514', null, 'Перенос единственного владельца в другой центр — тот же отказ'
);


-- 20-21. invitations — лестница ролей живёт в create_invitation, не в гранте --------------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-000000000024');
set local role authenticated;
select throws_ok(
  $q$ insert into public.invitations (center_id, role)
      values ('cccccccc-0000-0000-0000-000000000024', 'admin') $q$,
  '42501', null, 'Администратор не создаст приглашение с ролью admin прямым insert — гранта нет'
);
reset role;

insert into public.invitations (id, center_id, role, token) values
  ('99990000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000024','parent','tok-0024-existing-member'),
  ('99990000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-000000000024','teacher','tok-0024-newcomer'),
  ('99990000-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-000000000024','teacher','tok-0024-link');
update public.invitations set teacher_id = 'aaaaaaaa-0000-0000-0000-000000000024'
 where id = '99990000-0000-0000-0000-000000000003';

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000024');
set local role authenticated;
select throws_ok(
  $q$ update public.invitations set role = 'admin'
       where id = '99990000-0000-0000-0000-000000000001' $q$,
  '42501', null, 'Владелец не перепишет роль выданного приглашения — update только expires_at'
);


-- 22-24. accept_invitation: участнику с другой ролью — отказ ---------------------------------

select throws_ok(
  $q$ select public.accept_invitation('tok-0024-existing-member') $q$,
  '23505', null,
  'Владелец по ссылке с ролью parent — отказ, а не понижение (было: on conflict do update set role)'
);

reset role;

select is(
  (select role from public.memberships where user_id = '11111111-1111-1111-1111-111111111111'),
  'owner', 'Роль владельца не изменилась'
);
select ok(
  (select accepted_at is null from public.invitations where id = '99990000-0000-0000-0000-000000000001'),
  'Приглашение не потрачено — его можно отдать тому, кому оно предназначалось'
);


-- 25-30. Новичок — членство; та же роль — связывание с карточкой ----------------------------

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

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-000000000024');
set local role authenticated;

select lives_ok(
  $q$ select public.accept_invitation('tok-0024-link') $q$,
  'Специалист без карточки принимает приглашение с той же ролью — связывание, не отказ'
);

reset role;

select is(
  (select teacher_id from public.memberships where user_id = '44444444-4444-4444-4444-444444444444'),
  'aaaaaaaa-0000-0000-0000-000000000024'::uuid, 'memberships.teacher_id привязан к карточке'
);
select is(
  (select profile_id from public.teachers where id = 'aaaaaaaa-0000-0000-0000-000000000024'),
  '44444444-4444-4444-4444-444444444444'::uuid, 'teachers.profile_id указывает на пользователя'
);


-- 31. cancelInvitation — прямой update expires_at по-прежнему проходит ----------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000024');
set local role authenticated;
select lives_ok(
  $q$ update public.invitations set expires_at = now()
       where id = '99990000-0000-0000-0000-000000000001' $q$,
  'Отмена приглашения (expires_at = now()) владельцем проходит — колоночный грант'
);
reset role;


-- 32-33. Гранты триггерной функции -------------------------------------------------------------

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
