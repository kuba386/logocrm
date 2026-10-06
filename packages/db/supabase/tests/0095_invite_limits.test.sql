-- pgTAP: приглашение специалиста — карточка при принятии (0095).
--
-- Р1: выдача ссылки карточку не создаёт; принятие создаёт её с ФИО из
-- приглашения; отказ лимита при принятии — текст для приглашённого. Р2:
-- живые приглашения без карточки бронируют место (шестое — отказ с
-- объяснением), срок нельзя продлить. Р3: ссылка только на свободную карточку
-- и одна живая ссылка на карточку. Р4: повторное приглашение работающего
-- специалиста привязывает его карточку, новой не создаёт; одна карточка —
-- одно членство.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(15);


-- 1. Фикстура: Studio (лимит 5) — 2 работающих специалиста и 1 свободная карточка ------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('95000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0095@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 6) n;

insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('95000000-0000-0000-0000-0000000000c1', 'Центр 0095', 'centr-0095', 'studio', now() + interval '30 days', '{"timezone":"Asia/Bishkek"}'::jsonb);

-- aa02, aa03 — работают (2, 3); ff01 — свободная карточка без аккаунта.
insert into public.teachers (id, center_id, full_name, profile_id, is_active) values
  ('95000000-0000-0000-0000-00000000aa02', '95000000-0000-0000-0000-0000000000c1', 'Работает 1', '95000000-0000-0000-0000-000000000002', true),
  ('95000000-0000-0000-0000-00000000aa03', '95000000-0000-0000-0000-0000000000c1', 'Работает 2', '95000000-0000-0000-0000-000000000003', true),
  ('95000000-0000-0000-0000-00000000ff01', '95000000-0000-0000-0000-0000000000c1', 'Свободная', null, true);

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

create or replace function public.tests_cards()
  returns integer language sql as $$
  select count(*)::int from public.teachers
   where center_id = '95000000-0000-0000-0000-0000000000c1' and deleted_at is null;
$$;

create temporary table t_inv (name text primary key, id uuid, token text);
grant select, insert on t_inv to authenticated;


-- 2. Выдача ссылок: карточка не создаётся, места бронируются (Р1, Р2) ------------------------------

select public.tests_claims('95000000-0000-0000-0000-000000000001', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_inv select 'a', invitation_id, token from public.create_invitation('teacher', 'Новый 1');
insert into t_inv select 'b', invitation_id, token from public.create_invitation('teacher', 'Новый 2');
reset role;
select is(public.tests_cards(), 3, 'Две ссылки выданы — карточек по-прежнему 3, пустых не появилось');

select public.tests_claims('95000000-0000-0000-0000-000000000001', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_like(
  $$ select * from public.create_invitation('teacher', 'Шестой') $$,
  'Лимит тарифа Studio — специалистов: 5 (карточек 3, ждут приглашения 2)%',
  'Шестое место (3 карточки + 2 живые ссылки) — отказ с объяснением');


-- 3. Ссылка на существующую карточку (Р3) ---------------------------------------------------------

select lives_ok(
  $$ insert into t_inv select 'f', invitation_id, token from public.create_invitation('teacher', null, null, null, '95000000-0000-0000-0000-00000000ff01') $$,
  'Ссылка на свободную карточку проходит и места не требует');
select throws_ok(
  $$ select * from public.create_invitation('teacher', null, null, null, '95000000-0000-0000-0000-00000000ff01') $$,
  '22023', 'На эту карточку уже есть действующее приглашение — отправьте его или отмените',
  'Вторая живая ссылка на ту же карточку — отказ');
select throws_ok(
  $$ select * from public.create_invitation('teacher', null, null, null, '95000000-0000-0000-0000-00000000aa02') $$,
  '22023', 'Эта карточка уже привязана к сотруднику — выберите свободную или создайте новую',
  'Ссылку на привязанную карточку выпустить нельзя');
reset role;


-- 4. Срок только сокращается (Р2) -----------------------------------------------------------------

select public.tests_claims('95000000-0000-0000-0000-000000000001', '95000000-0000-0000-0000-0000000000c1');
select throws_ok(
  $$ update public.invitations set expires_at = now() + interval '30 days' where id = (select id from t_inv where name = 'b') $$,
  '22023', 'Срок приглашения продлить нельзя — отправьте новое приглашение', 'Продлить срок нельзя — бронь не обойти');
select lives_ok(
  $$ update public.invitations set expires_at = now() where id = (select id from t_inv where name = 'b') $$,
  'Отменить (сократить срок) можно');


-- 5. Принятие (Р1, Р4) ----------------------------------------------------------------------------

select public.tests_claims('95000000-0000-0000-0000-000000000004', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.accept_invitation((select token from t_inv where name = 'a')) $$,
  'Новичок принимает ссылку');
reset role;
select is(
  (select row(t.full_name, t.profile_id, t.is_active)::text
     from public.memberships m join public.teachers t on t.id = m.teacher_id
    where m.user_id = '95000000-0000-0000-0000-000000000004'),
  '("Новый 1",95000000-0000-0000-0000-000000000004,t)', 'Карточка создана при принятии — с ФИО из приглашения');

-- Повторное приглашение работающего специалиста.
select public.tests_claims('95000000-0000-0000-0000-000000000001', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_inv select 'r', invitation_id, token from public.create_invitation('teacher', 'Работает 1 (повтор)');
reset role;
select public.tests_claims('95000000-0000-0000-0000-000000000002', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.accept_invitation((select token from t_inv where name = 'r')) $$,
  'Работающий специалист принимает повторную ссылку без ошибки (раньше — teachers_profile_uniq)');
reset role;
select is(
  (select row(m.teacher_id, public.tests_cards())::text from public.memberships m where m.user_id = '95000000-0000-0000-0000-000000000002'),
  '(95000000-0000-0000-0000-00000000aa02,4)', 'Осталась его карточка, новой не создано (карточек 4: 3 + новичок)');

-- Ссылка на свободную карточку — привязка.
select public.tests_claims('95000000-0000-0000-0000-000000000005', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.accept_invitation((select token from t_inv where name = 'f'));
reset role;
select is(
  (select t.profile_id from public.teachers t where t.id = '95000000-0000-0000-0000-00000000ff01'),
  '95000000-0000-0000-0000-000000000005'::uuid, 'Свободная карточка привязана к принявшему');


-- 6. Лимит при принятии и одна карточка — одно членство -------------------------------------------

select public.tests_claims('95000000-0000-0000-0000-000000000001', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_inv select 'c', invitation_id, token from public.create_invitation('teacher', 'Последний');
reset role;
-- Пятое место заняли вручную до принятия.
select public.tests_claims(null, null);
insert into public.teachers (center_id, full_name) values ('95000000-0000-0000-0000-0000000000c1', 'Ручная карточка');
select is(public.tests_cards(), 5, 'Карточек 5 из 5');

select public.tests_claims('95000000-0000-0000-0000-000000000006', '95000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.accept_invitation((select token from t_inv where name = 'c')) $$,
  '23514', 'В центре закончились места специалистов по тарифу — попросите администратора освободить место или сменить тариф',
  'Принятие сверх лимита — отказ с текстом для приглашённого');
reset role;

select public.tests_claims(null, null);
select throws_ok(
  $$ insert into public.memberships (user_id, center_id, role, teacher_id)
     values ('95000000-0000-0000-0000-000000000006', '95000000-0000-0000-0000-0000000000c1', 'teacher', '95000000-0000-0000-0000-00000000aa02') $$,
  '23505', null, 'Вторая запись членства на ту же карточку — отказ уникального индекса');

select * from finish();
rollback;
