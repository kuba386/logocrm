-- pgTAP: родитель видит только упражнения из ДЗ своих детей (0082).
--
-- Главное, что ловит файл:
--   - родитель: упражнения (свои центра и платформенные) из живых строк живых
--     ДЗ живых своих детей, любого статуса ДЗ; не видит: без ДЗ, из ДЗ чужого
--     ребёнка, из удалённого ДЗ/строки, удалённого ребёнка, «только
--     специалист» (даже выданное до тега), чужого центра;
--   - родитель без payer_id — ничего; owner/admin/teacher (в т.ч. teacher с
--     payer_id) — вся библиотека, как раньше; registrar/finance — ничего;
--   - join homework_exercises × exercise_library под родителем — без recursion;
--   - гранты parent_exercise_ids.
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(14);

select is_empty(
  $$ select a.grantee::regrole::text
       from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = 'public.parent_exercise_ids()'::regprocedure
        and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner
        and a.grantee <> 'authenticated'::regrole $$,
  'parent_exercise_ids — EXECUTE только у владельца и authenticated');


-- Фикстура ---------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('82000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0082@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 10) n;

insert into public.centers (id, name, slug, settings) values
  ('82000000-0000-0000-0000-0000000000c1','Центр А 0082','centr-a-0082','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('82000000-0000-0000-0000-0000000000c2','Центр Б 0082','centr-b-0082','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('82000000-0000-0000-0000-0000000000a1','82000000-0000-0000-0000-0000000000c1','Специалист 0082',  '82000000-0000-0000-0000-000000000003'),
  ('82000000-0000-0000-0000-0000000000a2','82000000-0000-0000-0000-0000000000c1','Специалист 2 0082','82000000-0000-0000-0000-000000000009');

insert into public.payers (id, center_id, full_name, phone) values
  ('82000000-0000-0000-0000-0000000000d1','82000000-0000-0000-0000-0000000000c1','Плательщик 1 0082','+996700008201'),
  ('82000000-0000-0000-0000-0000000000d2','82000000-0000-0000-0000-0000000000c1','Плательщик 2 0082','+996700008202'),
  ('82000000-0000-0000-0000-0000000000db','82000000-0000-0000-0000-0000000000c2','Плательщик Б 0082','+996700008203');

-- 1 owner · 2 admin · 3 teacher · 4 registrar · 5 finance · 6 parent (d1) · 7 parent (d2) ·
-- 8 parent без payer_id · 9 teacher с payer_id d1 · 10 parent центра Б.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('82000000-0000-0000-0000-000000000001','82000000-0000-0000-0000-0000000000c1','owner',     null, null),
  ('82000000-0000-0000-0000-000000000002','82000000-0000-0000-0000-0000000000c1','admin',     null, null),
  ('82000000-0000-0000-0000-000000000003','82000000-0000-0000-0000-0000000000c1','teacher',   '82000000-0000-0000-0000-0000000000a1', null),
  ('82000000-0000-0000-0000-000000000004','82000000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('82000000-0000-0000-0000-000000000005','82000000-0000-0000-0000-0000000000c1','finance',   null, null),
  ('82000000-0000-0000-0000-000000000006','82000000-0000-0000-0000-0000000000c1','parent',    null, '82000000-0000-0000-0000-0000000000d1'),
  ('82000000-0000-0000-0000-000000000007','82000000-0000-0000-0000-0000000000c1','parent',    null, '82000000-0000-0000-0000-0000000000d2'),
  ('82000000-0000-0000-0000-000000000008','82000000-0000-0000-0000-0000000000c1','parent',    null, null),
  ('82000000-0000-0000-0000-000000000009','82000000-0000-0000-0000-0000000000c1','teacher',   '82000000-0000-0000-0000-0000000000a2', '82000000-0000-0000-0000-0000000000d1'),
  ('82000000-0000-0000-0000-000000000010','82000000-0000-0000-0000-0000000000c2','parent',    null, '82000000-0000-0000-0000-0000000000db');

insert into public.students (id, center_id, full_name, payer_id) values
  ('82000000-0000-0000-0000-0000000000e1','82000000-0000-0000-0000-0000000000c1','Ребёнок 1 0082','82000000-0000-0000-0000-0000000000d1'),
  ('82000000-0000-0000-0000-0000000000e2','82000000-0000-0000-0000-0000000000c1','Ребёнок 2 0082','82000000-0000-0000-0000-0000000000d2'),
  ('82000000-0000-0000-0000-0000000000e3','82000000-0000-0000-0000-0000000000c1','Удалённый 0082','82000000-0000-0000-0000-0000000000d1'),
  ('82000000-0000-0000-0000-0000000000eb','82000000-0000-0000-0000-0000000000c2','Ребёнок Б 0082','82000000-0000-0000-0000-0000000000db');

-- f1 — в ДЗ ребёнка 1; b1 — платформенное в ДЗ ребёнка 1 (reviewed); f2, b2 — без ДЗ;
-- f3 — только в ДЗ ребёнка 2; f4 — в удалённом ДЗ; f5 — в удалённой строке ДЗ;
-- f6 — в ДЗ удалённого ребёнка; f7 — в ДЗ ребёнка 1, тег «только специалист» появится после; fb — центр Б.
insert into public.exercise_library (id, center_id, title) values
  ('82000000-0000-0000-0000-0000000000f1','82000000-0000-0000-0000-0000000000c1','В ДЗ 0082'),
  ('82000000-0000-0000-0000-0000000000b1', null,                                  'Платформенное в ДЗ 0082'),
  ('82000000-0000-0000-0000-0000000000f2','82000000-0000-0000-0000-0000000000c1','Без ДЗ 0082'),
  ('82000000-0000-0000-0000-0000000000b2', null,                                  'Платформенное без ДЗ 0082'),
  ('82000000-0000-0000-0000-0000000000f3','82000000-0000-0000-0000-0000000000c1','Чужого ребёнка 0082'),
  ('82000000-0000-0000-0000-0000000000f4','82000000-0000-0000-0000-0000000000c1','Удалённое ДЗ 0082'),
  ('82000000-0000-0000-0000-0000000000f5','82000000-0000-0000-0000-0000000000c1','Удалённая строка 0082'),
  ('82000000-0000-0000-0000-0000000000f6','82000000-0000-0000-0000-0000000000c1','Удалённый ребёнок 0082'),
  ('82000000-0000-0000-0000-0000000000f7','82000000-0000-0000-0000-0000000000c1','Методичка 0082'),
  ('82000000-0000-0000-0000-0000000000fb','82000000-0000-0000-0000-0000000000c2','Центр Б 0082');

insert into public.homework (id, center_id, student_id, free_text, status) values
  ('82000000-0000-0000-0000-000000000101','82000000-0000-0000-0000-0000000000c1','82000000-0000-0000-0000-0000000000e1','ДЗ 1', 'assigned'),
  ('82000000-0000-0000-0000-000000000102','82000000-0000-0000-0000-0000000000c1','82000000-0000-0000-0000-0000000000e1','ДЗ 1 проверено', 'reviewed'),
  ('82000000-0000-0000-0000-000000000103','82000000-0000-0000-0000-0000000000c1','82000000-0000-0000-0000-0000000000e1','ДЗ 1 удалено', 'assigned'),
  ('82000000-0000-0000-0000-000000000201','82000000-0000-0000-0000-0000000000c1','82000000-0000-0000-0000-0000000000e2','ДЗ 2', 'assigned'),
  ('82000000-0000-0000-0000-000000000301','82000000-0000-0000-0000-0000000000c1','82000000-0000-0000-0000-0000000000e3','ДЗ удалённого', 'assigned'),
  ('82000000-0000-0000-0000-000000000901','82000000-0000-0000-0000-0000000000c2','82000000-0000-0000-0000-0000000000eb','ДЗ Б', 'assigned');

insert into public.homework_exercises (homework_id, exercise_id, center_id, deleted_at) values
  ('82000000-0000-0000-0000-000000000101','82000000-0000-0000-0000-0000000000f1','82000000-0000-0000-0000-0000000000c1', null),
  ('82000000-0000-0000-0000-000000000102','82000000-0000-0000-0000-0000000000b1','82000000-0000-0000-0000-0000000000c1', null),
  ('82000000-0000-0000-0000-000000000103','82000000-0000-0000-0000-0000000000f4','82000000-0000-0000-0000-0000000000c1', null),
  ('82000000-0000-0000-0000-000000000101','82000000-0000-0000-0000-0000000000f5','82000000-0000-0000-0000-0000000000c1', now()),
  ('82000000-0000-0000-0000-000000000101','82000000-0000-0000-0000-0000000000f7','82000000-0000-0000-0000-0000000000c1', null),
  ('82000000-0000-0000-0000-000000000201','82000000-0000-0000-0000-0000000000f3','82000000-0000-0000-0000-0000000000c1', null),
  ('82000000-0000-0000-0000-000000000301','82000000-0000-0000-0000-0000000000f6','82000000-0000-0000-0000-0000000000c1', null),
  ('82000000-0000-0000-0000-000000000901','82000000-0000-0000-0000-0000000000fb','82000000-0000-0000-0000-0000000000c2', null);

update public.homework set deleted_at = now() where id = '82000000-0000-0000-0000-000000000103';
update public.students set deleted_at = now() where id = '82000000-0000-0000-0000-0000000000e3';
update public.exercise_library set tags = array['только специалист'] where id = '82000000-0000-0000-0000-0000000000f7';

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_lib (who text, id uuid);
create temporary table t_misc (who text, n int);
grant all on t_lib, t_misc to public;

create or replace function public.t_snap(p_who text, p_user uuid, p_center uuid) returns void
  language plpgsql as $$
begin
  perform public.tests_claims(p_user, p_center);
  execute 'set local role authenticated';
  insert into t_lib select p_who, e.id from public.exercise_library e;
  insert into t_misc select p_who, count(*)::int from public.parent_exercise_ids();
  execute 'reset role';
  perform public.tests_claims(null, null);
end;
$$;

select public.t_snap('owner',     '82000000-0000-0000-0000-000000000001', '82000000-0000-0000-0000-0000000000c1');
select public.t_snap('admin',     '82000000-0000-0000-0000-000000000002', '82000000-0000-0000-0000-0000000000c1');
select public.t_snap('teacher',   '82000000-0000-0000-0000-000000000003', '82000000-0000-0000-0000-0000000000c1');
select public.t_snap('registrar', '82000000-0000-0000-0000-000000000004', '82000000-0000-0000-0000-0000000000c1');
select public.t_snap('finance',   '82000000-0000-0000-0000-000000000005', '82000000-0000-0000-0000-0000000000c1');
select public.t_snap('parent1',   '82000000-0000-0000-0000-000000000006', '82000000-0000-0000-0000-0000000000c1');
select public.t_snap('parent2',   '82000000-0000-0000-0000-000000000007', '82000000-0000-0000-0000-0000000000c1');
select public.t_snap('parent0',   '82000000-0000-0000-0000-000000000008', '82000000-0000-0000-0000-0000000000c1');
select public.t_snap('teacherP',  '82000000-0000-0000-0000-000000000009', '82000000-0000-0000-0000-0000000000c1');
select public.t_snap('parentB',   '82000000-0000-0000-0000-000000000010', '82000000-0000-0000-0000-0000000000c2');

create temporary table t_all as
  select id from public.exercise_library
   where deleted_at is null
     and (center_id is null or center_id = '82000000-0000-0000-0000-0000000000c1');


-- Родитель ----------------------------------------------------------------------------------------

select set_eq(
  $$ select id from t_lib where who = 'parent1' $$,
  $$ values ('82000000-0000-0000-0000-0000000000f1'::uuid), ('82000000-0000-0000-0000-0000000000b1') $$,
  'Родитель видит своё и платформенное из ДЗ своего ребёнка (любого статуса) — и больше ничего: ни без ДЗ, ни чужого ребёнка, ни удалённых ДЗ/строк/детей, ни «только специалист»');

select set_eq(
  $$ select id from t_lib where who = 'parent2' $$,
  $$ values ('82000000-0000-0000-0000-0000000000f3'::uuid) $$,
  'Второй родитель — только из ДЗ своего ребёнка');

select is((select count(*)::int from t_lib where who = 'parent0'), 0,
  'Родитель без payer_id — ни одного упражнения');

select set_eq(
  $$ select id from t_lib where who = 'parentB' $$,
  $$ values ('82000000-0000-0000-0000-0000000000fb'::uuid) $$,
  'Родитель другого центра — только из ДЗ своего ребёнка в своём центре');

select is((select count(*)::int from t_lib where who = 'parent1'
            and id = '82000000-0000-0000-0000-0000000000f7'), 0,
  '«Только специалист» из уже выданного ДЗ родителю не отдаётся (0081)');

select public.tests_claims('82000000-0000-0000-0000-000000000006', '82000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select he.id, e.title from public.homework_exercises he join public.exercise_library e on e.id = he.exercise_id $q$,
  'Родитель читает ДЗ с названиями одним join — без infinite recursion в политиках');
reset role;
select public.tests_claims(null, null);


-- Персонал ----------------------------------------------------------------------------------------

select set_eq($$ select id from t_lib where who = 'owner' $$, $$ select id from t_all $$,
  'Владелец — вся живая библиотека центра и платформы, как раньше');
select set_eq($$ select id from t_lib where who = 'admin' $$, $$ select id from t_all $$,
  'Администратор — вся библиотека');
select set_eq($$ select id from t_lib where who = 'teacher' $$, $$ select id from t_all $$,
  'Специалист — вся библиотека');
select set_eq($$ select id from t_lib where who = 'teacherP' $$, $$ select id from t_all $$,
  'Специалист с payer_id в членстве — всё равно вся библиотека: решает роль, не плательщик');

select is((select count(*)::int from t_lib where who in ('registrar', 'finance')), 0,
  'Регистратор и бухгалтер — ничего, как раньше');

select is((select coalesce(sum(n), 0)::int from t_misc where who in ('owner', 'teacher', 'teacherP', 'registrar')), 0,
  'parent_exercise_ids не родителю — пусто');

select is((select n from t_misc where who = 'parent1'), 2,
  'parent_exercise_ids родителю — ровно его упражнения');

select * from finish();
rollback;
