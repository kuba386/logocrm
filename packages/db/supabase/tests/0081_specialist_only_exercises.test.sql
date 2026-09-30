-- pgTAP: «только специалист» не выдаётся в ДЗ (0081).
--
-- Главное, что ловит файл:
--   - общий с Vitest набор случаев exercise_is_specialist_only (регистр, края,
--     таб/перевод строки, похожие теги);
--   - новая выдача такого упражнения (assign_homework, update_homework, возврат
--     из архива, смена exercise_id) — 23514 с названием, без следа в таблице;
--   - чужое упражнение с тегом — 42704 без названия (название не утекает);
--   - выданное до тега остаётся и мягко удаляется; строка с удалённым
--     упражнением тоже мягко удаляется (0074 Р5);
--   - смена center_id и перенос в другое ДЗ проверяются; удалённое упражнение
--     в новую выдачу не попадает; у функции EXECUTE ни у кого.
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(18);

select is_empty(
  $$ select a.grantee::regrole::text
       from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = 'public.exercise_is_specialist_only(text[])'::regprocedure
        and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner $$,
  'exercise_is_specialist_only — без EXECUTE у кого-либо, кроме владельца');

-- Те же случаи — в packages/core/src/exercise-tags.test.ts.
select is_empty(
  $$ select c.tags::text
       from (values
         (array['только специалист'],                  true),
         (array['Только Специалист'],                  true),
         (array['  только специалист  '],              true),
         (array[E'\tтолько специалист\n'],             true),
         (array[E'\u00a0только специалист'],           false),
         (array['дом', 'только специалист', 'зеркало'], true),
         ('{}'::text[],                                false),
         (null::text[],                                false),
         (array['только специалиста'],                 false),
         (array['специалист'],                         false),
         (array['дом', 'кабинет'],                     false)
       ) as c(tags, expected)
      where public.exercise_is_specialist_only(c.tags) is distinct from c.expected $$,
  'exercise_is_specialist_only совпадает с TS-зеркалом на общем наборе случаев');


-- Фикстура ---------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','81000000-0000-0000-0000-000000000001','authenticated','authenticated','owner-a-0081@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','81000000-0000-0000-0000-000000000004','authenticated','authenticated','owner-b-0081@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('81000000-0000-0000-0000-0000000000c1','Центр А 0081','centr-a-0081','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('81000000-0000-0000-0000-0000000000c2','Центр Б 0081','centr-b-0081','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('81000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-0000000000c1','owner', null, null),
  ('81000000-0000-0000-0000-000000000004','81000000-0000-0000-0000-0000000000c2','owner', null, null);

insert into public.payers (id, center_id, full_name, phone) values
  ('81000000-0000-0000-0000-0000000000d1','81000000-0000-0000-0000-0000000000c1','Родитель 0081','+996700008101');

insert into public.students (id, center_id, full_name, payer_id) values
  ('81000000-0000-0000-0000-0000000000e1','81000000-0000-0000-0000-0000000000c1','Ребёнок 0081','81000000-0000-0000-0000-0000000000d1');

-- f1 — обычное; f2 — своё «только специалист»; b1 — платформенное «только специалист»;
-- f3 — тег появится после выдачи; f4 — будет удалено после выдачи; f9 — чужое с тегом.
insert into public.exercise_library (id, center_id, title, tags) values
  ('81000000-0000-0000-0000-0000000000f1','81000000-0000-0000-0000-0000000000c1','Обычное 0081',        array['дом']),
  ('81000000-0000-0000-0000-0000000000f2','81000000-0000-0000-0000-0000000000c1','Кабинетное 0081',     array['только специалист']),
  ('81000000-0000-0000-0000-0000000000b1', null,                                  'Платформенное 0081',  array['Только специалист']),
  ('81000000-0000-0000-0000-0000000000f3','81000000-0000-0000-0000-0000000000c1','Позже с тегом 0081',  array['дом']),
  ('81000000-0000-0000-0000-0000000000f4','81000000-0000-0000-0000-0000000000c1','Позже удалено 0081',  array['дом']),
  ('81000000-0000-0000-0000-0000000000f9','81000000-0000-0000-0000-0000000000c2','Секрет центра Б 0081', array['только специалист']);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_hw (name text primary key, id uuid);
grant all on t_hw to public;


-- Новая выдача ------------------------------------------------------------------------------------

select public.tests_claims('81000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select lives_ok(
  $q$ insert into t_hw values ('ok', public.assign_homework('81000000-0000-0000-0000-0000000000e1', null,
        array['81000000-0000-0000-0000-0000000000f1']::uuid[])) $q$,
  'Обычное упражнение выдаётся');

select throws_ok(
  $q$ select public.assign_homework('81000000-0000-0000-0000-0000000000e1', null,
        array['81000000-0000-0000-0000-0000000000f1', '81000000-0000-0000-0000-0000000000f2']::uuid[]) $q$,
  '23514', 'Упражнение «Кабинетное 0081» — только для специалиста: в домашнее задание его не дают',
  'Своё «только специалист» — отказ с названием, даже в паре с обычным');

select throws_ok(
  $q$ select public.assign_homework('81000000-0000-0000-0000-0000000000e1', null,
        array['81000000-0000-0000-0000-0000000000b1']::uuid[]) $q$,
  '23514', 'Упражнение «Платформенное 0081» — только для специалиста: в домашнее задание его не дают',
  'Платформенное «Только специалист» (регистр не важен) — отказ');

select throws_ok(
  $q$ select public.assign_homework('81000000-0000-0000-0000-0000000000e1', null,
        array['81000000-0000-0000-0000-0000000000f9']::uuid[]) $q$,
  '42704', 'Упражнение не найдено в этом центре',
  'Чужое упражнение с тегом — «не найдено», название чужого центра не утекает');

-- Выдачи «до тега» и «до удаления».
insert into t_hw values
  ('later',   public.assign_homework('81000000-0000-0000-0000-0000000000e1', null, array['81000000-0000-0000-0000-0000000000f3']::uuid[])),
  ('deleted', public.assign_homework('81000000-0000-0000-0000-0000000000e1', null, array['81000000-0000-0000-0000-0000000000f4']::uuid[]));
reset role;

select is(
  (select count(*)::int from public.homework_exercises
    where exercise_id in ('81000000-0000-0000-0000-0000000000f2', '81000000-0000-0000-0000-0000000000b1')),
  0, 'После отказов ни одной строки ДЗ с такими упражнениями — вставка откатилась целиком');

update public.exercise_library set tags = array['дом', 'только специалист']
 where id = '81000000-0000-0000-0000-0000000000f3';
update public.exercise_library set deleted_at = now()
 where id = '81000000-0000-0000-0000-0000000000f4';

select is(
  (select count(*)::int from public.homework_exercises
    where exercise_id = '81000000-0000-0000-0000-0000000000f3' and deleted_at is null),
  1, 'Выданное до тега остаётся в ДЗ');


-- Правка состава ----------------------------------------------------------------------------------

select public.tests_claims('81000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select throws_ok(
  $q$ select public.update_homework((select id from t_hw where name = 'later'), null, null,
        array['81000000-0000-0000-0000-0000000000f3']::uuid[]) $q$,
  '23514', 'Упражнение «Позже с тегом 0081» — только для специалиста: в домашнее задание его не дают',
  'update_homework пересобирает состав: упражнение, получившее тег, — это новая выдача, отказ');

select lives_ok(
  $q$ select public.update_homework((select id from t_hw where name = 'later'), null, null,
        array['81000000-0000-0000-0000-0000000000f1']::uuid[]) $q$,
  'Замена на обычное проходит: мягкое удаление строки с тегом не отбивается');

select lives_ok(
  $q$ select public.update_homework((select id from t_hw where name = 'deleted'), null, null,
        array['81000000-0000-0000-0000-0000000000f1']::uuid[]) $q$,
  'Строку с удалённым упражнением можно снять из ДЗ (0074 Р5)');
reset role;
select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.homework_exercises
    where exercise_id = '81000000-0000-0000-0000-0000000000f3' and deleted_at is not null),
  1, 'Строка с тегом ушла в архив, а не исчезла');


-- Прямые правки строки (триггер держит и мимо RPC) ---------------------------------------------------

select throws_ok(
  $q$ update public.homework_exercises set deleted_at = null
       where exercise_id = '81000000-0000-0000-0000-0000000000f3' $q$,
  '23514', 'Упражнение «Позже с тегом 0081» — только для специалиста: в домашнее задание его не дают',
  'Возврат из архива строки с тегом — новая выдача, отказ');

select throws_ok(
  $q$ update public.homework_exercises set exercise_id = '81000000-0000-0000-0000-0000000000f2'
       where homework_id = (select id from t_hw where name = 'ok') $q$,
  '23514', 'Упражнение «Кабинетное 0081» — только для специалиста: в домашнее задание его не дают',
  'Смена exercise_id на «только специалист» — отказ');

select throws_ok(
  $q$ update public.homework_exercises set homework_id = (select id from t_hw where name = 'ok')
       where exercise_id = '81000000-0000-0000-0000-0000000000f3' $q$,
  '23514', 'Упражнение «Позже с тегом 0081» — только для специалиста: в домашнее задание его не дают',
  'Перенос строки в другое ДЗ — тоже новая выдача, отказ');

select throws_ok(
  $q$ insert into public.homework_exercises (homework_id, exercise_id, center_id)
      values ((select id from t_hw where name = 'ok'), '81000000-0000-0000-0000-0000000000f4',
              '81000000-0000-0000-0000-0000000000c1') $q$,
  '42704', 'Упражнение не найдено в этом центре', 'Удалённое упражнение в новую выдачу по-прежнему не попадает');

select throws_ok(
  $q$ update public.homework_exercises set center_id = '81000000-0000-0000-0000-0000000000c2'
       where homework_id = (select id from t_hw where name = 'ok') $q$,
  '42704', 'Упражнение не найдено в этом центре', 'Смена center_id проверяется тем же триггером');

select lives_ok(
  $q$ update public.homework_exercises set sort = sort + 1
       where homework_id = (select id from t_hw where name = 'ok') $q$,
  'Правка без смены упражнения/центра/архива не проверяется повторно');

select * from finish();
rollback;
