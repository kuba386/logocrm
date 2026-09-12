-- pgTAP: сотрудники и приглашения.
-- Запуск: pnpm db:test   (supabase test db)

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(14);

-- Фикстуры --------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','admin@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','other@test.kg','','','','','','','','');

insert into public.centers (id, name, slug)
values ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Центр Тест', 'centr-test');

insert into public.memberships (user_id, center_id, role)
values
  ('11111111-1111-1111-1111-111111111111','cccccccc-cccc-cccc-cccc-cccccccccccc','owner'),
  ('22222222-2222-2222-2222-222222222222','cccccccc-cccc-cccc-cccc-cccccccccccc','admin');

-- Две карточки специалистов: одна станет «своей» для teacher, вторая — чужой.
insert into public.teachers (id, center_id, full_name)
values
  ('11111111-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-cccccccccccc','Айгуль К.'),
  ('22222222-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-cccccccccccc','Другой Специалист');

insert into public.memberships (user_id, center_id, role, teacher_id)
values ('33333333-3333-3333-3333-333333333333','cccccccc-cccc-cccc-cccc-cccccccccccc','teacher','11111111-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

insert into public.invitations (id, center_id, role, token, expires_at)
values
  ('11111111-bbbb-bbbb-bbbb-bbbbbbbbbbbb','cccccccc-cccc-cccc-cccc-cccccccccccc','parent','valid-token-0001',   now() + interval '7 days'),
  ('22222222-bbbb-bbbb-bbbb-bbbbbbbbbbbb','cccccccc-cccc-cccc-cccc-cccccccccccc','parent','expired-token-0002', now() - interval '1 day');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', p_user,
      'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end
    )::text,
    true
  );
end;
$$;


-- 1. Специалист видит только свою карточку ------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333', 'cccccccc-cccc-cccc-cccc-cccccccccccc');
set local role authenticated;

select results_eq(
  'select full_name from public.teachers',
  array['Айгуль К.'],
  'Специалист видит только собственную карточку teachers'
);

select is(
  (select count(*) from public.invitations)::int, 0,
  'Специалист не видит приглашений'
);

select is(
  (select count(*) from public.staff_view)::int, 1,
  'Специалист видит в staff_view только себя'
);

select is(
  (select count(*) from public.pending_invitations_view)::int, 0,
  'Специалист не видит pending_invitations_view'
);

reset role;


-- 2. Владелец видит всех ------------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111', 'cccccccc-cccc-cccc-cccc-cccccccccccc');
set local role authenticated;

select is(
  (select count(*) from public.staff_view)::int, 3,
  'Владелец видит всех участников центра'
);

select is(
  (select count(*) from public.staff_view where email is not null)::int, 3,
  'Владельцу видны email участников (через user_email)'
);

select is(
  (select count(*) from public.pending_invitations_view)::int, 1,
  'Владельцу видно только непросроченное приглашение'
);

reset role;


-- 3. Приглашения --------------------------------------------------------------

select public.tests_claims('44444444-4444-4444-4444-444444444444', null);
set local role authenticated;

select throws_ok(
  $q$ select public.accept_invitation('expired-token-0002') $q$,
  '22023',
  'Срок действия приглашения истёк',
  'accept_invitation отклоняет просроченный токен'
);

select throws_ok(
  $q$ select public.accept_invitation('нет-такого-токена') $q$,
  '42704',
  'Приглашение не найдено',
  'accept_invitation отклоняет неизвестный токен'
);

select lives_ok(
  $q$ select public.accept_invitation('valid-token-0001') $q$,
  'accept_invitation принимает валидный токен'
);

select throws_ok(
  $q$ select public.accept_invitation('valid-token-0001') $q$,
  '22023',
  'Приглашение уже использовано',
  'Повторный accept_invitation отклонён'
);

reset role;


-- 4. Ограничения ролей --------------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222', 'cccccccc-cccc-cccc-cccc-cccccccccccc');
set local role authenticated;

select throws_ok(
  $q$ select public.change_member_role('33333333-3333-3333-3333-333333333333', 'owner') $q$,
  '42501',
  'Администратор может назначать только роли специалиста, регистратора и бухгалтера',
  'Администратор не может назначить роль owner'
);

select throws_ok(
  $q$ select public.create_invitation('admin') $q$,
  '42501',
  'Администратор не может приглашать администраторов',
  'Администратор не может пригласить администратора'
);

reset role;

select public.tests_claims('11111111-1111-1111-1111-111111111111', 'cccccccc-cccc-cccc-cccc-cccccccccccc');
set local role authenticated;

select throws_ok(
  $q$ select public.revoke_membership('11111111-1111-1111-1111-111111111111') $q$,
  '23514',
  'Нельзя отключить последнего владельца центра',
  'Последнего владельца нельзя отключить'
);

reset role;

select * from finish();

rollback;
