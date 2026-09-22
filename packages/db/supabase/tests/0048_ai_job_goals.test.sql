-- pgTAP: список целей ребёнка в ответе ai_job_begin (0048).
--
-- Главное — границы: в списке только цели ребёнка диктовки, и текст чужой
-- цели не встречается в ответе нигде (ассерт про утечку, не про фильтр);
-- состав полей элемента зафиксирован поимённо, чтобы «добавим имя для
-- контекста» падало тестом; гранты функции закреплены — с 0048 ответ несёт
-- клинику, а не только идентификаторы.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(25);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0480000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0048@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0480000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-0048@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('a0480000-0000-0000-0000-0000000000c1','Центр А 0048','centr-a-0048','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('a0480000-0000-0000-0000-0000000000c2','Центр Б 0048','centr-b-0048','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0480000-0000-0000-0000-000000000010','a0480000-0000-0000-0000-0000000000c1','Специалист 0048','a0480000-0000-0000-0000-000000000002');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('a0480000-0000-0000-0000-000000000020','a0480000-0000-0000-0000-0000000000c1','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('a0480000-0000-0000-0000-000000000030','a0480000-0000-0000-0000-0000000000c1','Родитель 0048','+996700004801'),
  ('a0480000-0000-0000-0000-000000000031','a0480000-0000-0000-0000-0000000000c2','Родитель Б 0048','+996700004802');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0480000-0000-0000-0000-000000000001','a0480000-0000-0000-0000-0000000000c1','owner',  null, null),
  ('a0480000-0000-0000-0000-000000000002','a0480000-0000-0000-0000-0000000000c1','teacher','a0480000-0000-0000-0000-000000000010', null);

-- Айсулуу — ребёнок диктовки; Бекжан — сосед по группе; Тимур — без целей.
insert into public.students (id, center_id, full_name, payer_id) values
  ('a0480000-0000-0000-0000-000000000040','a0480000-0000-0000-0000-0000000000c1','Айсулуу','a0480000-0000-0000-0000-000000000030'),
  ('a0480000-0000-0000-0000-000000000041','a0480000-0000-0000-0000-0000000000c1','Бекжан','a0480000-0000-0000-0000-000000000030'),
  ('a0480000-0000-0000-0000-000000000042','a0480000-0000-0000-0000-0000000000c1','Тимур','a0480000-0000-0000-0000-000000000030'),
  ('a0480000-0000-0000-0000-000000000043','a0480000-0000-0000-0000-0000000000c2','Ребёнок Б','a0480000-0000-0000-0000-000000000031');

insert into public.groups (id, center_id, name) values
  ('a0480000-0000-0000-0000-000000000050','a0480000-0000-0000-0000-0000000000c1','Группа 0048');

insert into public.group_students (group_id, student_id, center_id) values
  ('a0480000-0000-0000-0000-000000000050','a0480000-0000-0000-0000-000000000040','a0480000-0000-0000-0000-0000000000c1'),
  ('a0480000-0000-0000-0000-000000000050','a0480000-0000-0000-0000-000000000041','a0480000-0000-0000-0000-0000000000c1'),
  ('a0480000-0000-0000-0000-000000000050','a0480000-0000-0000-0000-000000000042','a0480000-0000-0000-0000-0000000000c1');

insert into public.lessons (id, center_id, teacher_id, group_id, service_id, status, starts_at, ends_at) values
  ('a0480000-0000-0000-0000-000000000060','a0480000-0000-0000-0000-0000000000c1','a0480000-0000-0000-0000-000000000010',
   'a0480000-0000-0000-0000-000000000050','a0480000-0000-0000-0000-000000000020','planned',
   now() - interval '2 hours', now() - interval '1 hour 15 minutes');

insert into public.telegram_accounts (user_id, chat_id) values
  ('a0480000-0000-0000-0000-000000000002', 780048);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

select public.tests_claims('a0480000-0000-0000-0000-000000000001','a0480000-0000-0000-0000-0000000000c1');

-- Цели Айсулуу: 0071 — постановка (ранний этап); 0072 и 0073 — слоги, одним
-- insert (общий created_at, порядок держит только id); 0074 — paused;
-- 0075 — achieved; 0076 — удалена. 0077 — цель Бекжана. 0078 — цель
-- ребёнка центра Б.
insert into public.goals (id, center_id, student_id, stage_id, title, area, sound, status) values
  ('a0480000-0000-0000-0000-000000000071','a0480000-0000-0000-0000-0000000000c1','a0480000-0000-0000-0000-000000000040',
   (select id from public.goal_stages where center_id = 'a0480000-0000-0000-0000-0000000000c1' and code = 'setting'),
   'Постановка [р]','звукопроизношение','р','active'),
  ('a0480000-0000-0000-0000-000000000072','a0480000-0000-0000-0000-0000000000c1','a0480000-0000-0000-0000-000000000040',
   (select id from public.goal_stages where center_id = 'a0480000-0000-0000-0000-0000000000c1' and code = 'syllables'),
   '[р] в слогах','звукопроизношение','р','active'),
  ('a0480000-0000-0000-0000-000000000073','a0480000-0000-0000-0000-0000000000c1','a0480000-0000-0000-0000-000000000040',
   (select id from public.goal_stages where center_id = 'a0480000-0000-0000-0000-0000000000c1' and code = 'syllables'),
   '[л] в слогах','звукопроизношение','л','active'),
  ('a0480000-0000-0000-0000-000000000074','a0480000-0000-0000-0000-0000000000c1','a0480000-0000-0000-0000-000000000040',
   (select id from public.goal_stages where center_id = 'a0480000-0000-0000-0000-0000000000c1' and code = 'words'),
   'КАНАРЕЙКА-ПАУЗА','звукопроизношение','ш','paused'),
  ('a0480000-0000-0000-0000-000000000075','a0480000-0000-0000-0000-0000000000c1','a0480000-0000-0000-0000-000000000040',
   (select id from public.goal_stages where center_id = 'a0480000-0000-0000-0000-0000000000c1' and code = 'words'),
   'КАНАРЕЙКА-ДОСТИГНУТА','звукопроизношение','с','achieved'),
  ('a0480000-0000-0000-0000-000000000076','a0480000-0000-0000-0000-0000000000c1','a0480000-0000-0000-0000-000000000040',
   (select id from public.goal_stages where center_id = 'a0480000-0000-0000-0000-0000000000c1' and code = 'phrases'),
   'КАНАРЕЙКА-УДАЛЕНА','звукопроизношение','ж','active'),
  ('a0480000-0000-0000-0000-000000000077','a0480000-0000-0000-0000-0000000000c1','a0480000-0000-0000-0000-000000000041',
   (select id from public.goal_stages where center_id = 'a0480000-0000-0000-0000-0000000000c1' and code = 'setting'),
   'КАНАРЕЙКА-БЕКЖАН','звукопроизношение','р','active'),
  ('a0480000-0000-0000-0000-000000000078','a0480000-0000-0000-0000-0000000000c2','a0480000-0000-0000-0000-000000000043',
   (select id from public.goal_stages where center_id = 'a0480000-0000-0000-0000-0000000000c2' and code = 'setting'),
   'КАНАРЕЙКА-ЦЕНТР-Б','звукопроизношение','р','active');

update public.goals set deleted_at = now() where id = 'a0480000-0000-0000-0000-000000000076';


-- Диктовка по Айсулуу ------------------------------------------------------------------------------

select public.tests_claims('a0480000-0000-0000-0000-000000000002','a0480000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.request_voice_note('a0480000-0000-0000-0000-000000000060','a0480000-0000-0000-0000-000000000040') $q$,
  'Диктовка по Айсулуу запрошена');
reset role;

select public.tests_claims(null, null);
select lives_ok(
  $q$ select public.arm_voice_request(
        (select token from public.lesson_voice_requests where consumed_at is null and cancelled_at is null),
        780048) $q$,
  'Токен армирован');
select lives_ok(
  $q$ select public.report_voice_note(780048, 'file-048', 30) $q$,
  'Голосовое принято');
update public.events set claimed_at = now() where claimed_at is null and type = 'lesson.voice_received';

create temporary table t048_job as
  select public.ai_job_begin((select max(id) from public.events where type = 'lesson.voice_received')) as j;

select is((select j ->> 'file_id' from t048_job), 'file-048',
  'Старый ключ file_id на месте');
select ok((select j ?& array['file_id','center_id','lesson_id','student_id','student_goals','student_goals_total'] from t048_job),
  'Все шесть ключей верхнего уровня присутствуют');
select is((select count(*)::int from t048_job, jsonb_object_keys(j)), 6,
  'И ровно шесть — лишнего ничего не уехало');

select is((select jsonb_typeof(j -> 'student_goals') from t048_job), 'array',
  'student_goals — массив');
select is((select jsonb_array_length(j -> 'student_goals') from t048_job), 3,
  'Три активные цели Айсулуу: постановка и две в слогах');
select is((select (j ->> 'student_goals_total')::int from t048_job), 3,
  'student_goals_total совпадает с длиной списка, когда усечения нет (Р6)');

select is(
  (select array_agg(e ->> 'goal_id' order by ord) from t048_job, jsonb_array_elements(j -> 'student_goals') with ordinality as x(e, ord)),
  array['a0480000-0000-0000-0000-000000000071','a0480000-0000-0000-0000-000000000072','a0480000-0000-0000-0000-000000000073'],
  'Порядок: ранний этап раньше позднего, внутри этапа с общим created_at — по id (Р5)');

select ok(
  (select bool_and(e ?& array['goal_id','title','area','sound','stage_title'] and (select count(*) from jsonb_object_keys(e)) = 5)
     from t048_job, jsonb_array_elements(j -> 'student_goals') e),
  'Состав полей элемента зафиксирован: ровно goal_id, title, area, sound, stage_title (Р2)');

select is((select e ->> 'stage_title' from t048_job, jsonb_array_elements(j -> 'student_goals') e where e ->> 'goal_id' = 'a0480000-0000-0000-0000-000000000071'),
  'Постановка', 'Название этапа подставлено из справочника');

select is((select position('КАНАРЕЙКА-ПАУЗА' in j::text) from t048_job), 0,
  'Цель на паузе в ответе не встречается (Р3)');
select is((select position('КАНАРЕЙКА-ДОСТИГНУТА' in j::text) from t048_job), 0,
  'Достигнутая цель в ответе не встречается (Р3)');
select is((select position('КАНАРЕЙКА-УДАЛЕНА' in j::text) from t048_job), 0,
  'Удалённая цель в ответе не встречается');
select is((select position('КАНАРЕЙКА-БЕКЖАН' in j::text) from t048_job), 0,
  'Цель соседа по групповому занятию в ответе не встречается нигде — ассерт про утечку, не про фильтр');
select is((select position('КАНАРЕЙКА-ЦЕНТР-Б' in j::text) from t048_job), 0,
  'Цель ребёнка другого центра в ответе не встречается');
select is((select position('Айсулуу' in j::text) from t048_job), 0,
  'Имени ребёнка в ответе нет — список обезличен (Р2)');

select ok(
  (select public.ai_job_begin((select max(id) from public.events where type = 'lesson.voice_received')) is null),
  'Второй вызов в восьмиминутном окне — null, занятие работы не изменилось (0042 В2)');


-- Ребёнок без целей ---------------------------------------------------------------------------------

select public.tests_claims('a0480000-0000-0000-0000-000000000002','a0480000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.request_voice_note('a0480000-0000-0000-0000-000000000060','a0480000-0000-0000-0000-000000000042') $q$,
  'Диктовка по Тимуру запрошена');
reset role;
select public.tests_claims(null, null);
select public.arm_voice_request(
  (select token from public.lesson_voice_requests where consumed_at is null and cancelled_at is null), 780048);
select public.report_voice_note(780048, 'file-048-2', 10);
update public.events set claimed_at = now() where claimed_at is null and type = 'lesson.voice_received';

select is(
  (select public.ai_job_begin((select max(id) from public.events where type = 'lesson.voice_received')) -> 'student_goals'),
  '[]'::jsonb,
  'Без активных целей — пустой массив, а не null (Р4)');


-- Гранты: с 0048 ответ несёт клинику (Р7) --------------------------------------------------------------

select ok(has_function_privilege('bot_worker', 'public.ai_job_begin(bigint)', 'EXECUTE'),
  'bot_worker исполняет ai_job_begin');
select ok(not has_function_privilege('anon', 'public.ai_job_begin(bigint)', 'EXECUTE'),
  'anon — нет');
select ok(not has_function_privilege('authenticated', 'public.ai_job_begin(bigint)', 'EXECUTE'),
  'authenticated — нет');
select ok(not has_function_privilege('public', 'public.ai_job_begin(bigint)', 'EXECUTE'),
  'public — нет');

select * from finish();

rollback;
