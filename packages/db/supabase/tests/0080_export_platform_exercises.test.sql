-- pgTAP: выгрузка центра с платформенными упражнениями из его ДЗ (0080).
--
-- Главное, что ловит файл:
--   - в exercise_library центра — свои строки и платформенные, на которые
--     ссылаются его homework_exercises (включая удалённые ДЗ и удалённые
--     платформенные строки), каждая один раз;
--   - платформенные без ссылок и ссылки только из другого центра — не тянутся;
--   - счётчик в center.exported = длине файла (один предикат на обе функции);
--   - таблицы с nullable center_id без ссылок (message_templates) — как раньше;
--   - teacher/parent — 42501; у предиката EXECUTE ни у кого.
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(10);

select is_empty(
  $$ select a.grantee::regrole::text
       from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = 'public.export_center_predicate(text)'::regprocedure
        and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner $$,
  'export_center_predicate — без EXECUTE у кого-либо, кроме владельца');


-- Фикстура ---------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','80000000-0000-0000-0000-000000000001','authenticated','authenticated','owner-a-0080@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','80000000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-a-0080@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','80000000-0000-0000-0000-000000000003','authenticated','authenticated','parent-a-0080@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','80000000-0000-0000-0000-000000000004','authenticated','authenticated','owner-b-0080@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('80000000-0000-0000-0000-0000000000c1','Центр А 0080','centr-a-0080','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('80000000-0000-0000-0000-0000000000c2','Центр Б 0080','centr-b-0080','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('80000000-0000-0000-0000-0000000000a1','80000000-0000-0000-0000-0000000000c1','Специалист 0080','80000000-0000-0000-0000-000000000002');

insert into public.payers (id, center_id, full_name, phone) values
  ('80000000-0000-0000-0000-0000000000d1','80000000-0000-0000-0000-0000000000c1','Родитель А 0080','+996700008001'),
  ('80000000-0000-0000-0000-0000000000d2','80000000-0000-0000-0000-0000000000c2','Родитель Б 0080','+996700008002');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('80000000-0000-0000-0000-000000000001','80000000-0000-0000-0000-0000000000c1','owner',   null, null),
  ('80000000-0000-0000-0000-000000000002','80000000-0000-0000-0000-0000000000c1','teacher', '80000000-0000-0000-0000-0000000000a1', null),
  ('80000000-0000-0000-0000-000000000003','80000000-0000-0000-0000-0000000000c1','parent',  null, '80000000-0000-0000-0000-0000000000d1'),
  ('80000000-0000-0000-0000-000000000004','80000000-0000-0000-0000-0000000000c2','owner',   null, null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('80000000-0000-0000-0000-0000000000e1','80000000-0000-0000-0000-0000000000c1','Ребёнок А 0080','80000000-0000-0000-0000-0000000000d1'),
  ('80000000-0000-0000-0000-0000000000e2','80000000-0000-0000-0000-0000000000c2','Ребёнок Б 0080','80000000-0000-0000-0000-0000000000d2');

-- f1 — своё А, f2 — своё Б; p1 — платформа, ссылки из двух ДЗ А (в файле один раз);
-- p2 — платформа без ссылок; p3 — платформа, ссылка только из Б;
-- p4 — платформа, позже удалена, ссылка из А; p5 — платформа, ссылка только из удалённой строки ДЗ А.
insert into public.exercise_library (id, center_id, title) values
  ('80000000-0000-0000-0000-0000000000f1','80000000-0000-0000-0000-0000000000c1','Своё А 0080'),
  ('80000000-0000-0000-0000-0000000000f2','80000000-0000-0000-0000-0000000000c2','Своё Б 0080'),
  ('80000000-0000-0000-0000-0000000000b1', null, 'Платформа по ДЗ А 0080'),
  ('80000000-0000-0000-0000-0000000000b2', null, 'Платформа без ссылок 0080'),
  ('80000000-0000-0000-0000-0000000000b3', null, 'Платформа по ДЗ Б 0080'),
  ('80000000-0000-0000-0000-0000000000b4', null, 'Платформа удалённая 0080'),
  ('80000000-0000-0000-0000-0000000000b5', null, 'Платформа из удалённой строки ДЗ 0080');

insert into public.homework (id, center_id, student_id, free_text, deleted_at) values
  ('80000000-0000-0000-0000-000000000101','80000000-0000-0000-0000-0000000000c1','80000000-0000-0000-0000-0000000000e1','ДЗ 1', null),
  ('80000000-0000-0000-0000-000000000102','80000000-0000-0000-0000-0000000000c1','80000000-0000-0000-0000-0000000000e1','ДЗ 2', null),
  ('80000000-0000-0000-0000-000000000201','80000000-0000-0000-0000-0000000000c2','80000000-0000-0000-0000-0000000000e2','ДЗ Б', null);

insert into public.homework_exercises (homework_id, exercise_id, center_id, deleted_at) values
  ('80000000-0000-0000-0000-000000000101','80000000-0000-0000-0000-0000000000f1','80000000-0000-0000-0000-0000000000c1', null),
  ('80000000-0000-0000-0000-000000000101','80000000-0000-0000-0000-0000000000b1','80000000-0000-0000-0000-0000000000c1', null),
  ('80000000-0000-0000-0000-000000000102','80000000-0000-0000-0000-0000000000b1','80000000-0000-0000-0000-0000000000c1', null),
  ('80000000-0000-0000-0000-000000000101','80000000-0000-0000-0000-0000000000b4','80000000-0000-0000-0000-0000000000c1', null),
  ('80000000-0000-0000-0000-000000000101','80000000-0000-0000-0000-0000000000b5','80000000-0000-0000-0000-0000000000c1', now()),
  ('80000000-0000-0000-0000-000000000201','80000000-0000-0000-0000-0000000000f2','80000000-0000-0000-0000-0000000000c2', null),
  ('80000000-0000-0000-0000-000000000201','80000000-0000-0000-0000-0000000000b3','80000000-0000-0000-0000-0000000000c2', null);

-- Удаления — после ссылок: удалённое ДЗ и удалённая платформенная строка всё равно в архиве.
update public.homework set deleted_at = now() where id = '80000000-0000-0000-0000-000000000102';
update public.exercise_library set deleted_at = now() where id = '80000000-0000-0000-0000-0000000000b4';
-- Неактивное платформенное (снято с показа, 0074 Р5) — тоже в архиве, раз на него есть ссылка.
update public.exercise_library set is_active = false where id = '80000000-0000-0000-0000-0000000000b1';

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_exp (who text, tbl text, data jsonb);
create temporary table t_evt (who text, event_id bigint);
grant all on t_exp, t_evt to public;

select public.tests_claims('80000000-0000-0000-0000-000000000001','80000000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_exp values
  ('A', 'exercise_library', public.export_center_table('exercise_library')),
  ('A', 'homework_exercises', public.export_center_table('homework_exercises')),
  ('A', 'message_templates', public.export_center_table('message_templates'));
insert into t_evt values ('A', public.record_center_export());
reset role;

select public.tests_claims('80000000-0000-0000-0000-000000000004','80000000-0000-0000-0000-0000000000c2');
set local role authenticated;
insert into t_exp values ('B', 'exercise_library', public.export_center_table('exercise_library'));
reset role;
select public.tests_claims(null, null);


-- Выгрузка ---------------------------------------------------------------------------------------

select set_eq(
  $$ select (e ->> 'id')::uuid from t_exp, jsonb_array_elements(data) e where who = 'A' and tbl = 'exercise_library' $$,
  $$ values ('80000000-0000-0000-0000-0000000000f1'::uuid), ('80000000-0000-0000-0000-0000000000b1'),
            ('80000000-0000-0000-0000-0000000000b4'), ('80000000-0000-0000-0000-0000000000b5') $$,
  'Центр А: своё упражнение + платформенные из его ДЗ (включая удалённые ДЗ, удалённую и неактивную платформенные строки); без чужих и без платформы без ссылок');

select is(
  (select jsonb_array_length(data) from t_exp where who = 'A' and tbl = 'exercise_library'), 4,
  'Платформенное из двух ДЗ — одной строкой, без дублей');

select set_eq(
  $$ select (e ->> 'id')::uuid from t_exp, jsonb_array_elements(data) e where who = 'B' and tbl = 'exercise_library' $$,
  $$ values ('80000000-0000-0000-0000-0000000000f2'::uuid), ('80000000-0000-0000-0000-0000000000b3') $$,
  'Центр Б: только своё и платформенное из своего ДЗ — ссылки А его не касаются');

select is(
  (select jsonb_array_length(data) from t_exp where who = 'A' and tbl = 'homework_exercises'), 5,
  'Остальные таблицы — как раньше: все строки центра, включая удалённые');

select is(
  (select count(*)::int from t_exp, jsonb_array_elements(data) e
    where who = 'A' and tbl = 'message_templates'
      and (e ->> 'center_id') is distinct from '80000000-0000-0000-0000-0000000000c1'), 0,
  'message_templates: платформенные дефолты в выгрузку не тянутся (на них никто не ссылается)');


-- Журнал ------------------------------------------------------------------------------------------

select is(
  (select (ev.payload -> 'tables' ->> 'exercise_library')::int
     from t_evt join public.events ev on ev.id = t_evt.event_id where t_evt.who = 'A'),
  (select jsonb_array_length(data) from t_exp where who = 'A' and tbl = 'exercise_library'),
  'center.exported считает exercise_library тем же предикатом, что и файл');

select is(
  (select (ev.payload -> 'tables' ->> 'homework_exercises')::int
     from t_evt join public.events ev on ev.id = t_evt.event_id where t_evt.who = 'A'),
  5, 'Счётчик остальных таблиц не изменился');


-- Права -------------------------------------------------------------------------------------------

select public.tests_claims('80000000-0000-0000-0000-000000000002','80000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($q$ select public.export_center_table('exercise_library') $q$, '42501', 'Недостаточно прав',
  'Специалисту выгрузка недоступна');
reset role;

select public.tests_claims('80000000-0000-0000-0000-000000000003','80000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($q$ select public.export_center_table('exercise_library') $q$, '42501', 'Недостаточно прав',
  'Родителю выгрузка недоступна');
reset role;
select public.tests_claims(null, null);

select * from finish();
rollback;
