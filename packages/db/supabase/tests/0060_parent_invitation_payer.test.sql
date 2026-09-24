-- pgTAP: приглашение родителя — только с карточкой плательщика (0060).
-- Claims — явно перед каждым блоком: reset role их не сбрасывает.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select * from no_plan();

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a-0060@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','admin-a-0060@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-a-0060@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','owner-b-0060@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','newparent-0060@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','teacher-a-0060@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent2-0060@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','88888888-8888-8888-8888-888888888888','authenticated','authenticated','orphan-0060@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','99999999-9999-9999-9999-999999999999','authenticated','authenticated','parent3-0060@test.kg','','','','','','','','');

insert into public.centers (id, name, slug) values
  ('cccccccc-0000-0000-0000-000000000060','Центр А 0060','centr-a-0060'),
  ('cccccccc-0000-0000-0000-000000000061','Центр Б 0060','centr-b-0060');

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000601','cccccccc-0000-0000-0000-000000000060','Специалист 0060');

insert into public.payers (id, center_id, full_name, phone, deleted_at) values
  ('dddddddd-0000-0000-0000-000000000601','cccccccc-0000-0000-0000-000000000060','Плательщик Один','+996700000601', null),
  ('dddddddd-0000-0000-0000-000000000602','cccccccc-0000-0000-0000-000000000060','Плательщик Архивный','+996700000602', now()),
  ('dddddddd-0000-0000-0000-000000000603','cccccccc-0000-0000-0000-000000000060','Плательщик Три','+996700000603', null),
  ('dddddddd-0000-0000-0000-000000000604','cccccccc-0000-0000-0000-000000000060','Плательщик Четыре','+996700000604', null),
  ('dddddddd-0000-0000-0000-000000000605','cccccccc-0000-0000-0000-000000000061','Плательщик Б','+996700000605', null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000601','cccccccc-0000-0000-0000-000000000060','Ребёнок Один','dddddddd-0000-0000-0000-000000000601'),
  ('eeeeeeee-0000-0000-0000-000000000604','cccccccc-0000-0000-0000-000000000060','Ребёнок Четыре','dddddddd-0000-0000-0000-000000000604');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000060','owner',   null, null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-000000000060','admin',   null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000060','finance', null, null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-000000000061','owner',   null, null),
  ('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-000000000060','teacher', 'aaaaaaaa-0000-0000-0000-000000000601', null),
  -- «Ничей» родитель из прошлого — то, что чинит link_parent_payer.
  ('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-000000000060','parent',  null, null),
  -- Родитель, уже привязанный к P4, — для повторной ссылки к другой карточке (Р7).
  ('99999999-9999-9999-9999-999999999999','cccccccc-0000-0000-0000-000000000060','parent',  null, 'dddddddd-0000-0000-0000-000000000604');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_ins (name text primary key, id uuid, token text, payer uuid, created boolean);
grant select, insert on t_ins to authenticated;


-- 1. Гейт — первым, до валидации плательщика ----------------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000060');
set local role authenticated;
select throws_ok(
  $q$ select * from public.create_invitation('parent') $q$,
  '42501', null, 'finance не приглашает — 42501 до проверки плательщика');
reset role;


-- 2-9. Родитель: карточка обязательна; новая — по ФИО и телефону ----------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000060');
set local role authenticated;

select throws_ok(
  $q$ select * from public.create_invitation('parent') $q$,
  '22023', 'Некорректный номер телефона плательщика', 'Родитель без карточки и без телефона — отказ');
select throws_ok(
  $q$ select * from public.create_invitation('parent', null, '+996700000606') $q$,
  '22004', 'Укажите ФИО плательщика', 'Телефон есть, ФИО нет — отказ');
select throws_ok(
  $q$ select * from public.create_invitation('parent', 'Дубль', '0700 000 601') $q$,
  '22023', 'Плательщик с этим телефоном уже есть — выберите его из списка',
  'Номер живой карточки в любом формате — явный выбор, не молчаливая привязка (стандарт 0057)');
select is(
  (select count(*)::int from public.payers where center_id = 'cccccccc-0000-0000-0000-000000000060'),
  3, 'Ни один отказ карточку не завёл (видимых владельцу 3 — архивную tenant_admin не отдаёт; полный счёт — ниже, под postgres)');

insert into t_ins
  select 'new', invitation_id, token, payer_id, payer_created
    from public.create_invitation('parent', 'Новый Родитель', '0700 000 602');
select is((select created from t_ins where name = 'new'), true,
  'Номер архивной карточки свободен — заведена новая (частичный индекс по deleted_at is null)');
select is(
  (select phone from public.payers where id = (select payer from t_ins where name = 'new')),
  '+996700000602', 'Телефон новой карточки нормализован — как в create_student_with_payer');
select is(
  (select phone from public.invitations where id = (select id from t_ins where name = 'new')),
  '+996700000602', 'invitations.phone — телефон карточки (Р2)');
select ok(
  (select expires_at between now() + interval '2 days' and now() + interval '4 days'
     from public.invitations where id = (select id from t_ins where name = 'new')),
  'Ссылка родителя живёт 3 дня, не 7 (Р1)');

insert into t_ins
  select 'p1', invitation_id, token, payer_id, payer_created
    from public.create_invitation('parent', null, null, null, null, 'dddddddd-0000-0000-0000-000000000601');
select is((select payer from t_ins where name = 'p1'), 'dddddddd-0000-0000-0000-000000000601',
  'Существующая карточка — payer_id в приглашении');
select is((select created from t_ins where name = 'p1'), false, '…и payer_created = false');
select is(
  (select phone from public.invitations where id = (select id from t_ins where name = 'p1')),
  '+996700000601', 'Телефон приглашения — телефон выбранной карточки');

select throws_ok(
  $q$ select * from public.create_invitation('parent', null, null, null, null, 'dddddddd-0000-0000-0000-000000000605') $q$,
  '42704', null, 'Карточка чужого центра — 42704 (ADR-002)');
select throws_ok(
  $q$ select * from public.create_invitation('parent', null, null, null, null, 'dddddddd-0000-0000-0000-000000000602') $q$,
  '42704', null, 'Архивная карточка — 42704');

insert into t_ins
  select 'teacher', invitation_id, token, payer_id, payer_created
    from public.create_invitation('teacher', 'Новый Специалист', null, null, null, 'dddddddd-0000-0000-0000-000000000601');
select is((select payer from t_ins where name = 'teacher'), null::uuid,
  'Для специалиста p_payer_id игнорируется, как p_teacher_id для не-teacher');

-- Ссылка для P3 — карточку архивируют до принятия (тест 11).
insert into t_ins
  select 'p3', invitation_id, token, payer_id, payer_created
    from public.create_invitation('parent', null, null, null, null, 'dddddddd-0000-0000-0000-000000000603');
-- Ссылка к P1 для родителя, уже привязанного к P4 (Р7).
insert into t_ins
  select 'p1_again', invitation_id, token, payer_id, payer_created
    from public.create_invitation('parent', null, null, null, null, 'dddddddd-0000-0000-0000-000000000601');

select throws_ok(
  $q$ update public.invitations set expires_at = now() + interval '30 days'
       where id = (select id from t_ins where name = 'p1') $q$,
  '23514', null, 'Продлить ссылку родителя прямым PATCH expires_at (грант 0024) — 23514, срок держит CHECK, не if в функции');
select lives_ok(
  $q$ update public.invitations set expires_at = now()
       where id = (select id from t_ins where name = 'p1_again') $q$,
  '…а отменить (expires_at = now()) — можно');
update public.invitations set expires_at = now() + interval '1 day'
 where id = (select id from t_ins where name = 'p1_again');
reset role;

-- Администратор приглашает родителя так же, как владелец (симметрия).
select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-000000000060');
set local role authenticated;
select lives_ok(
  $q$ select * from public.create_invitation('parent', null, null, null, null, 'dddddddd-0000-0000-0000-000000000604') $q$,
  'admin приглашает родителя к существующей карточке');
reset role;

select is(
  (select count(*)::int from public.payers where center_id = 'cccccccc-0000-0000-0000-000000000060'),
  5, 'Под postgres: 4 карточки фикстуры + 1 новая из приглашения — отказы карточек не завели');

-- События — как postgres: RLS events не отдаёт строки участникам.
select is(
  (select count(*)::int from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000060' and type = 'payer.created'
      and (payload->>'payer_id')::uuid = (select payer from t_ins where name = 'new')),
  1, 'Новая карточка из приглашения — событие payer.created, как из create_student_with_payer');
select is(
  (select (payload->>'payer_id')::uuid from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000060' and type = 'invitation.created'
      and (payload->>'invitation_id')::uuid = (select id from t_ins where name = 'p1')),
  'dddddddd-0000-0000-0000-000000000601', 'invitation.created несёт payer_id');


-- 10-11. CHECK: родитель без карточки не проходит даже мимо функций --------------------------

select throws_ok(
  $q$ insert into public.invitations (center_id, role, token)
      values ('cccccccc-0000-0000-0000-000000000060', 'parent', 'tok-0060-orphan') $q$,
  '23514', null, 'Прямой insert parent без payer_id (postgres/service_role) — 23514');
select throws_ok(
  $q$ update public.invitations set payer_id = null where id = (select id from t_ins where name = 'p1') $q$,
  '23514', null, 'Обнулить payer_id у parent-приглашения — 23514: NOT VALID не отключает проверку новых строк');


-- 12-14. accept_invitation: карточка живая — привязка; архивная — отказ ----------------------

select public.tests_claims('55555555-5555-5555-5555-555555555555', null);
set local role authenticated;
select lives_ok(
  $q$ select public.accept_invitation((select token from t_ins where name = 'p1')) $q$,
  'Новый родитель принимает ссылку к живой карточке');
reset role;
select is(
  (select payer_id from public.memberships
    where user_id = '55555555-5555-5555-5555-555555555555' and center_id = 'cccccccc-0000-0000-0000-000000000060'),
  'dddddddd-0000-0000-0000-000000000601', 'memberships.payer_id заполнен из приглашения');

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-000000000060');
set local role authenticated;
select is((select count(*)::int from public.students), 1, 'Родитель видит ровно одного — своего — ребёнка');
select is((select full_name from public.students limit 1), 'Ребёнок Один', '…и это ребёнок его карточки');
reset role;

update public.payers set deleted_at = now() where id = 'dddddddd-0000-0000-0000-000000000603';
select public.tests_claims('77777777-7777-7777-7777-777777777777', null);
set local role authenticated;
select throws_ok(
  $q$ select public.accept_invitation((select token from t_ins where name = 'p3')) $q$,
  '22023', 'Карточка плательщика архивирована — попросите администратора прислать новую ссылку',
  'Карточку архивировали после выдачи ссылки — отказ, не membership на архивную строку');
reset role;
select is(
  (select count(*)::int from public.memberships where user_id = '77777777-7777-7777-7777-777777777777'),
  0, '…и членство не создано');

-- Р7: родитель, привязанный к P4, идёт по новой ссылке к P1.
select public.tests_claims('99999999-9999-9999-9999-999999999999', null);
set local role authenticated;
select throws_ok(
  $q$ select public.accept_invitation((select token from t_ins where name = 'p1_again')) $q$,
  '22023', 'Вы уже привязаны к другой карточке плательщика — привязку меняет администратор в «Сотрудниках»',
  'Ссылка к другой карточке для уже привязанного родителя — отказ, не молчаливый coalesce');
reset role;
select is(
  (select payer_id from public.memberships where user_id = '99999999-9999-9999-9999-999999999999'),
  'dddddddd-0000-0000-0000-000000000604', '…привязка не изменилась');
select is(
  (select accepted_at from public.invitations where id = (select id from t_ins where name = 'p1_again')),
  null::timestamptz, '…и приглашение не помечено принятым');


-- 15-17. change_member_role: в parent нельзя, из parent — без payer_id -------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000060');
set local role authenticated;
select throws_ok(
  $q$ select public.change_member_role('66666666-6666-6666-6666-666666666666', 'parent') $q$,
  '22023', null, 'Перевод в parent закрыт — второй путь к «ничьему» родителю');
select lives_ok(
  $q$ select public.change_member_role('55555555-5555-5555-5555-555555555555', 'registrar') $q$,
  'Родителя можно перевести в другую роль');
reset role;
select is(
  (select payer_id from public.memberships
    where user_id = '55555555-5555-5555-5555-555555555555' and center_id = 'cccccccc-0000-0000-0000-000000000060'),
  null::uuid, '…и payer_id снят — симметрично teacher_id');


-- 18-30. link_parent_payer ---------------------------------------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000060');
set local role authenticated;
select throws_ok(
  $q$ select public.link_parent_payer('88888888-8888-8888-8888-888888888888', 'dddddddd-0000-0000-0000-000000000601') $q$,
  '42501', null, 'finance не привязывает');
reset role;

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-000000000061');
set local role authenticated;
select throws_ok(
  $q$ select public.link_parent_payer('88888888-8888-8888-8888-888888888888', 'dddddddd-0000-0000-0000-000000000605') $q$,
  '42704', null, 'Владелец другого центра — «не найден», наличие не раскрывается');
reset role;

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-000000000060');
set local role authenticated;
select throws_ok(
  $q$ select public.link_parent_payer('66666666-6666-6666-6666-666666666666', 'dddddddd-0000-0000-0000-000000000601') $q$,
  '42704', null, 'Специалист — не родитель: тот же 42704');
select throws_ok(
  $q$ select public.link_parent_payer('99999999-9999-9999-9999-999999999999', 'dddddddd-0000-0000-0000-000000000601') $q$,
  '42704', null, 'Несуществующий пользователь — 42704');
select throws_ok(
  $q$ select public.link_parent_payer('88888888-8888-8888-8888-888888888888', 'dddddddd-0000-0000-0000-000000000605') $q$,
  '42704', null, 'Карточка чужого центра — 42704');
select throws_ok(
  $q$ select public.link_parent_payer('88888888-8888-8888-8888-888888888888', 'dddddddd-0000-0000-0000-000000000602') $q$,
  '42704', null, 'Архивная карточка — 42704');

select lives_ok(
  $q$ select public.link_parent_payer('88888888-8888-8888-8888-888888888888', 'dddddddd-0000-0000-0000-000000000601') $q$,
  'admin: null → P1');
select is(
  (select payer_name from public.staff_view where user_id = '88888888-8888-8888-8888-888888888888'),
  'Плательщик Один', 'staff_view.payer_name — карточка родителя');
select is(
  (select full_name from public.staff_view where user_id = '66666666-6666-6666-6666-666666666666'),
  'Специалист 0060', 'staff_view.full_name у специалиста не изменился — семантика колонки прежняя');
select is(
  (select payer_name from public.pending_invitations_view where id = (select id from t_ins where name = 'new')),
  'Новый Родитель', 'pending_invitations_view.payer_name — карточка приглашённого родителя');
select lives_ok(
  $q$ select public.link_parent_payer('88888888-8888-8888-8888-888888888888', 'dddddddd-0000-0000-0000-000000000604') $q$,
  'admin: P1 → P4 — перепривязка тем же действием (ошибочную привязку чинят сразу)');
select lives_ok(
  $q$ select public.link_parent_payer('88888888-8888-8888-8888-888888888888', 'dddddddd-0000-0000-0000-000000000604') $q$,
  'Повтор той же привязки — no-op');
reset role;

select public.tests_claims('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-000000000060');
set local role authenticated;
select is((select full_name from public.students limit 1), 'Ребёнок Четыре',
  'После перепривязки родитель видит детей новой карточки…');
select is((select count(*)::int from public.students where payer_id = 'dddddddd-0000-0000-0000-000000000601'), 0,
  '…и не видит детей прежней');
reset role;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000060');
set local role authenticated;
select lives_ok(
  $q$ select public.link_parent_payer('88888888-8888-8888-8888-888888888888') $q$,
  'owner: отвязать — вызов без второго аргумента, как шлёт клиент без ключа (default null)');
reset role;
select is(
  (select payer_id from public.memberships where user_id = '88888888-8888-8888-8888-888888888888'),
  null::uuid, '…payer_id снят');
select is(
  (select count(*)::int from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000060' and type = 'membership.payer_linked'),
  3, 'Три события: null→P1, P1→P4, P4→null; no-op события не пишет');
select is(
  (select payload->>'previous_payer_id' from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000060' and type = 'membership.payer_linked'
    order by id desc limit 1),
  'dddddddd-0000-0000-0000-000000000604', 'Последнее событие несёт previous_payer_id — след для аудита');


-- 31-35. Гранты ---------------------------------------------------------------------------------

select ok(
  has_function_privilege('authenticated', 'public.create_invitation(text,text,text,text,uuid,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.link_parent_payer(uuid,uuid)', 'EXECUTE'),
  'Новая сигнатура create_invitation и link_parent_payer — authenticated');
select ok(
  not has_function_privilege('anon', 'public.create_invitation(text,text,text,text,uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.link_parent_payer(uuid,uuid)', 'EXECUTE'),
  'anon — нет');
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'create_invitation'),
  1, 'Старой 5-аргументной сигнатуры нет — одна create_invitation');
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'link_parent_payer'),
  1, 'link_parent_payer — одна сигнатура с default, а не перегрузка');
select ok(
  not has_table_privilege('anon', 'public.staff_view', 'SELECT')
  and not has_table_privilege('anon', 'public.pending_invitations_view', 'SELECT'),
  'Витрины после пересоздания: anon без select (второй слой, 0024)');
select ok(
  has_table_privilege('authenticated', 'public.staff_view', 'SELECT')
  and has_table_privilege('authenticated', 'public.pending_invitations_view', 'SELECT'),
  '…authenticated — select');

select * from finish();

rollback;
