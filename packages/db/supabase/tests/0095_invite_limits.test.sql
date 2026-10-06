-- pgTAP: приглашение специалиста — лимит, повтор, чужая карточка (0095).
--
-- Р1: пустая карточка непринятого приглашения места не занимает (случай prod:
-- 2 работают + 3 пустые на лимите 5 — новое приглашение проходит), принятие
-- (включение is_active) проверяется лимитом. Р2: живые приглашения бронируют
-- место — шестое при 2 работающих и 3 живых ссылках на лимите 5 — отказ с
-- текстом; отменённое место освобождает. Р3: ссылку на привязанную карточку
-- выпустить нельзя. Р4: повторное приглашение работающего специалиста
-- принимается без ошибки и привязывает его собственную карточку. Р5:
-- center_limits считает только действующие карточки.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(11);


-- 1. Фикстура: центр Studio (лимит 5) — 2 работающих, 3 пустые карточки истёкших ссылок -----------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('95000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0095@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 4) n;

insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('95000000-0000-0000-0000-0000000000c1', 'Центр 0095', 'centr-0095', 'studio', now() + interval '30 days', '{"timezone":"Asia/Bishkek"}'::jsonb);

-- 2, 3 — работающие специалисты; 4 — человек без членства (примет ссылку).
insert into public.teachers (id, center_id, full_name, profile_id, is_active) values
  ('95000000-0000-0000-0000-00000000aa02', '95000000-0000-0000-0000-0000000000c1', 'Работает 1', '95000000-0000-0000-0000-000000000002', true),
  ('95000000-0000-0000-0000-00000000aa03', '95000000-0000-0000-0000-0000000000c1', 'Работает 2', '95000000-0000-0000-0000-000000000003', true),
  ('95000000-0000-0000-0000-00000000ab01', '95000000-0000-0000-0000-0000000000c1', 'Пустая 1', null, false),
  ('95000000-0000-0000-0000-00000000ab02', '95000000-0000-0000-0000-0000000000c1', 'Пустая 2', null, false),
  ('95000000-0000-0000-0000-00000000ab03', '95000000-0000-0000-0000-0000000000c1', 'Пустая 3', null, false);

insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('95000000-0000-0000-0000-000000000001', '95000000-0000-0000-0000-0000000000c1', 'owner', null),
  ('95000000-0000-0000-0000-000000000002', '95000000-0000-0000-0000-0000000000c1', 'teacher', '95000000-0000-0000-0000-00000000aa02'),
  ('95000000-0000-0000-0000-000000000003', '95000000-0000-0000-0000-0000000000c1', 'teacher', '95000000-0000-0000-0000-00000000aa03');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_inv (name text primary key, id uuid, token text, teacher_id uuid);
grant select, insert on t_inv to authenticated;


-- 2. Пустые карточки места не занимают (Р1, Р5) ---------------------------------------------------

select public.tests_claims('95000000-0000-0000-0000-000000000001', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((public.center_limits() -> 'usage' ->> 'teachers')::int, 2,
  'center_limits: специалистов 2 из 5 — три пустые карточки не считаются (было 5 из 5)');
select lives_ok(
  $$ insert into t_inv select 'a', invitation_id, token, teacher_id from public.create_invitation('teacher', 'Новый 1') $$,
  'Приглашение проходит: работают 2, ждут 0 — раньше лимит отказывал');
insert into t_inv select 'b', invitation_id, token, teacher_id from public.create_invitation('teacher', 'Новый 2');
insert into t_inv select 'c', invitation_id, token, teacher_id from public.create_invitation('teacher', null, null, null, '95000000-0000-0000-0000-00000000ab01');


-- 3. Живые приглашения бронируют место (Р2) -------------------------------------------------------

select throws_like(
  $$ select * from public.create_invitation('teacher', 'Шестой') $$,
  'Лимит тарифа Studio — специалистов: 5 (работают 2, ждут приглашения 3)%',
  'Шестое место при 2 работающих и 3 живых ссылках — отказ с объяснением');
reset role;

update public.invitations set expires_at = now() where id = (select id from t_inv where name = 'b');

select public.tests_claims('95000000-0000-0000-0000-000000000001', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
-- Освободившееся место — под повторное приглашение работающего специалиста (Р4 ниже).
select lives_ok(
  $$ insert into t_inv select 'r', invitation_id, token, teacher_id from public.create_invitation('teacher', 'Работает 1 (повтор)') $$,
  'Отменённая ссылка освобождает место');


-- 4. Только свободная карточка (Р3) ---------------------------------------------------------------

select throws_ok(
  $$ select * from public.create_invitation('teacher', null, null, null, '95000000-0000-0000-0000-00000000aa02') $$,
  '22023', 'Эта карточка уже привязана к сотруднику — выберите свободную или создайте новую',
  'Ссылку на привязанную карточку выпустить нельзя');
reset role;


-- 5. Принятие (Р1, Р4) ----------------------------------------------------------------------------

select public.tests_claims('95000000-0000-0000-0000-000000000004', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.accept_invitation((select token from t_inv where name = 'a')) $$,
  'Новый специалист принимает ссылку');
reset role;
select is(
  (select row(t.profile_id, t.is_active)::text from public.teachers t where t.id = (select teacher_id from t_inv where name = 'a')),
  '(95000000-0000-0000-0000-000000000004,t)', 'Его карточка привязана и стала действующей');

select public.tests_claims('95000000-0000-0000-0000-000000000002', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.accept_invitation((select token from t_inv where name = 'r')) $$,
  'Работающий специалист принимает повторную ссылку без ошибки (раньше — teachers_profile_uniq)');
reset role;
select is(
  (select row(m.teacher_id, (select t.profile_id from public.teachers t where t.id = (select teacher_id from t_inv where name = 'r')))::text
     from public.memberships m where m.user_id = '95000000-0000-0000-0000-000000000002'),
  '(95000000-0000-0000-0000-00000000aa02,)',
  'Привязана его прежняя карточка, новая осталась пустой');

-- Лимит при принятии: доводим действующих до 5 напрямую, затем ещё одно принятие — отказ.
select public.tests_claims(null, null);
update public.teachers set is_active = true
 where id in ('95000000-0000-0000-0000-00000000ab02', '95000000-0000-0000-0000-00000000ab03');
select is((select count(*)::int from public.teachers where center_id = '95000000-0000-0000-0000-0000000000c1' and is_active and deleted_at is null),
  5, 'Действующих 5 из 5');
select throws_ok(
  $$ update public.teachers set is_active = true where id = '95000000-0000-0000-0000-00000000ab01' $$,
  '23514', null, 'Включить шестую карточку — отказ лимита (вход в действующие)');

select * from finish();
rollback;
