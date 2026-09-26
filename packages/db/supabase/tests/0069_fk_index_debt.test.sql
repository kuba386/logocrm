-- pgTAP: 0069 — список колонок у составного `on delete set null` (0022-класс
-- бага на diagnostics/goal_progress/homework/syllable_assessments) и
-- непартиальные покрывающие индексы под составные FK речевой карты.
--
-- Каталог: confdelsetcols/confdeltype/confupdtype/convalidated и
-- conkey/confrelid не разъехались при drop+add — переиздали тот же FK, не
-- похожий (первое доказывает, что список колонок применился, второе — что
-- миграция не подменила действие/родителя).
-- Индексы (раздел 2): партиальный (`where deleted_at is null`) не считается
-- покрытием ссылочной целостности — RI-запрос Postgres не содержит этого
-- предиката; проверено на реальных данных (lessons_teacher_fk у советника
-- Advisors в находках, хотя частичный индекс на teacher_id есть). Предикат
-- покрытия — общий для трёх подпроверок (2а: список имён не пуст сам по
-- себе; 2б: собственно покрытие; 2в: негативный контроль на временной паре
-- таблиц — доказывает, что 2б умеет отличать покрытую схему от непокрытой,
-- а не тождественно истинен по ошибке построения выражения); 2г — что
-- существовавшие партиальные индексы приложения не задело.
-- Поведение (раздел 4): физический delete родителя (teachers/lessons) —
-- SET NULL только своей колонки, соседние обязательные колонки (center_id,
-- student_id/goal_id) не тронуты, updated_at сдвинулся (каскад — настоящий
-- UPDATE дочерней строки, не no-op: важно для update_syllable_assessment,
-- чья оптимистичная блокировка сверяет именно updated_at). Фикстура —
-- отдельный специалист на лидирующую роль в диагностике/слоговой структуре
-- и отдельный специалист-заполнитель lessons.teacher_id (not null,
-- restrict), чтобы удаление первого не упёрлось в lessons_teacher_fk
-- restrict.
--
-- Не покрываются (сознательно, Р3 в шапке миграции): diagnostics_student_fk,
-- goal_progress_goal_fk, homework_student_fk, lesson_participants_lesson_fk
-- и весь остальной долг советника (109 находок, включая каскадную сторону
-- того же пути удаления) — не в объёме этой миграции.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(18);


-- 1. Каталог: список колонок у SET NULL не потерялся при drop+add ---------------------------------

select is(
  (select row(confdelsetcols, confdeltype::text, confupdtype::text, convalidated) from pg_constraint
    where conname = 'diagnostics_teacher_fk'),
  (select row(array[a.attnum], 'n'::text, 'a'::text, true) from pg_attribute a
    where a.attrelid = 'public.diagnostics'::regclass and a.attname = 'teacher_id'),
  'diagnostics_teacher_fk: SET NULL (teacher_id), validated, ON UPDATE NO ACTION — не потерялось при drop+add');

select is(
  (select row(c.conkey, c.confrelid::regclass::text) from pg_constraint c where c.conname = 'diagnostics_teacher_fk'),
  (select row(array[a1.attnum, a2.attnum], 'teachers'::text) from pg_attribute a1, pg_attribute a2
    where a1.attrelid = 'public.diagnostics'::regclass and a1.attname = 'teacher_id'
      and a2.attrelid = 'public.diagnostics'::regclass and a2.attname = 'center_id'),
  'diagnostics_teacher_fk: переиздан тот же FK (teacher_id, center_id) → teachers, не похожий');

select is(
  (select row(confdelsetcols, confdeltype::text, confupdtype::text, convalidated) from pg_constraint
    where conname = 'goal_progress_lesson_fk'),
  (select row(array[a.attnum], 'n'::text, 'a'::text, true) from pg_attribute a
    where a.attrelid = 'public.goal_progress'::regclass and a.attname = 'lesson_id'),
  'goal_progress_lesson_fk: SET NULL (lesson_id), validated, ON UPDATE NO ACTION — не потерялось при drop+add');

select is(
  (select row(c.conkey, c.confrelid::regclass::text) from pg_constraint c where c.conname = 'goal_progress_lesson_fk'),
  (select row(array[a1.attnum, a2.attnum], 'lessons'::text) from pg_attribute a1, pg_attribute a2
    where a1.attrelid = 'public.goal_progress'::regclass and a1.attname = 'lesson_id'
      and a2.attrelid = 'public.goal_progress'::regclass and a2.attname = 'center_id'),
  'goal_progress_lesson_fk: переиздан тот же FK (lesson_id, center_id) → lessons, не похожий');

select is(
  (select row(confdelsetcols, confdeltype::text, confupdtype::text, convalidated) from pg_constraint
    where conname = 'homework_lesson_fk'),
  (select row(array[a.attnum], 'n'::text, 'a'::text, true) from pg_attribute a
    where a.attrelid = 'public.homework'::regclass and a.attname = 'lesson_id'),
  'homework_lesson_fk: SET NULL (lesson_id), validated, ON UPDATE NO ACTION — не потерялось при drop+add');

select is(
  (select row(c.conkey, c.confrelid::regclass::text) from pg_constraint c where c.conname = 'homework_lesson_fk'),
  (select row(array[a1.attnum, a2.attnum], 'lessons'::text) from pg_attribute a1, pg_attribute a2
    where a1.attrelid = 'public.homework'::regclass and a1.attname = 'lesson_id'
      and a2.attrelid = 'public.homework'::regclass and a2.attname = 'center_id'),
  'homework_lesson_fk: переиздан тот же FK (lesson_id, center_id) → lessons, не похожий');

select is(
  (select row(confdelsetcols, confdeltype::text, confupdtype::text, convalidated) from pg_constraint
    where conname = 'syllable_assessments_teacher_fk'),
  (select row(array[a.attnum], 'n'::text, 'a'::text, true) from pg_attribute a
    where a.attrelid = 'public.syllable_assessments'::regclass and a.attname = 'teacher_id'),
  'syllable_assessments_teacher_fk: SET NULL (teacher_id), validated, ON UPDATE NO ACTION — не потерялось при drop+add');

select is(
  (select row(c.conkey, c.confrelid::regclass::text) from pg_constraint c where c.conname = 'syllable_assessments_teacher_fk'),
  (select row(array[a1.attnum, a2.attnum], 'teachers'::text) from pg_attribute a1, pg_attribute a2
    where a1.attrelid = 'public.syllable_assessments'::regclass and a1.attname = 'teacher_id'
      and a2.attrelid = 'public.syllable_assessments'::regclass and a2.attname = 'center_id'),
  'syllable_assessments_teacher_fk: переиздан тот же FK (teacher_id, center_id) → teachers, не похожий');


-- 2. Индексы: непартиальные btree, покрывают составной FK целиком -----------------------------------
-- Предикат покрытия — общий для трёх проверок ниже, чтобы негативный
-- контроль (2в) доказывал именно то выражение, от которого зависят 2а/2б,
-- а не похожее на него.

-- 2а. Список имён не пуст сам по себе — если один из девяти переименуют
-- или снесут, `conname in (...)` просто не найдёт его, а не пожалуется.
select is(
  (select count(*)::int from pg_constraint
    where contype = 'f' and conname in (
      'diagnostics_teacher_fk', 'goal_progress_lesson_fk', 'homework_lesson_fk',
      'syllable_assessments_student_fk', 'syllable_assessments_teacher_fk',
      'prosody_assessments_student_fk', 'prosody_assessments_teacher_fk',
      'reading_writing_assessments_student_fk', 'reading_writing_assessments_teacher_fk')),
  9,
  'Все девять составных FK по именам существуют — иначе проверка покрытия ниже молчала бы вакуумно');

-- 2б. Покрытие: непартиальный, валидный, живой, btree-индекс с префиксом = колонкам FK.
select is(
  (select array_agg(c.conname order by c.conname) from pg_constraint c
    where c.conname in (
      'diagnostics_teacher_fk', 'goal_progress_lesson_fk', 'homework_lesson_fk',
      'syllable_assessments_student_fk', 'syllable_assessments_teacher_fk',
      'prosody_assessments_student_fk', 'prosody_assessments_teacher_fk',
      'reading_writing_assessments_student_fk', 'reading_writing_assessments_teacher_fk')
      and not exists (
        select 1 from pg_index i
         join pg_class ic on ic.oid = i.indexrelid
         join pg_am am on am.oid = ic.relam
        where i.indrelid = c.conrelid
          and i.indpred is null
          and i.indisvalid
          and i.indislive
          and am.amname = 'btree'
          and (i.indkey::smallint[])[0:cardinality(c.conkey) - 1] @> c.conkey::smallint[]
      )),
  null,
  'Каждый составной FK, переизданный или добавленный в речевой карте (0066-0068) этой миграцией, покрыт непартиальным btree-индексом (Р2/Р3) — партиальный не засчитывается: та же проверка бьёт lessons_teacher_fk на реальных данных, хотя частичный индекс на нём есть');

-- 2в. Негативный контроль: та же формула на составном FK, у которого есть
-- ТОЛЬКО партиальный индекс, обязана назвать его непокрытым. Без этого
-- предикат 2б мог бы быть тождественно истинным по ошибке построения
-- (не тот срез indkey, не та граница) — и тест 2б был бы зелёным на
-- полностью непокрытой схеме, узнали бы об этом только от Advisors, как с
-- 0068 Р12.
create temporary table t0069_neg_parent (
  id uuid primary key, center_id uuid not null,
  constraint t0069_neg_parent_id_center_key unique (id, center_id)
);
create temporary table t0069_neg_child (
  id uuid primary key,
  parent_id uuid,
  center_id uuid not null,
  constraint t0069_neg_child_fk foreign key (parent_id, center_id) references t0069_neg_parent (id, center_id)
);
create index t0069_neg_partial_idx on t0069_neg_child (parent_id, center_id) where center_id is not null;

select ok(
  exists (
    select 1 from pg_constraint c
     where c.conname = 't0069_neg_child_fk'
       and not exists (
         select 1 from pg_index i
          join pg_class ic on ic.oid = i.indexrelid
          join pg_am am on am.oid = ic.relam
         where i.indrelid = c.conrelid
           and i.indpred is null
           and i.indisvalid
           and i.indislive
           and am.amname = 'btree'
           and (i.indkey::smallint[])[0:cardinality(c.conkey) - 1] @> c.conkey::smallint[]
       )
  ),
  'Негативный контроль: составной FK с только партиальным индексом предикат называет непокрытым (иначе тест 2б не различал бы покрытую и непокрытую схему)');

select is(
  (select count(*)::int from pg_class where relname = 'reading_writing_assessments_teacher_idx' and relkind = 'i'),
  0,
  'Плацебо 0068 Р12 (частичный (teacher_id) без читателя в apps/web) снято');

-- 2г. Существовавшие партиальные индексы приложения (deleted_at is null) не тронуты.
select ok(
  (select bool_and(exists (
     select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
      where c.relname = idx and i.indpred is not null))
   from unnest(array[
     'diagnostics_student_idx', 'diagnostics_center_idx',
     'goal_progress_goal_idx', 'goal_progress_center_idx',
     'homework_student_idx', 'homework_center_idx',
     'syllable_assessments_student_idx', 'syllable_assessments_center_idx',
     'prosody_assessments_student_idx', 'prosody_assessments_center_idx',
     'reading_writing_assessments_student_idx', 'reading_writing_assessments_center_idx'
   ]) idx),
  'Партиальные индексы под запросы приложения (student/center, deleted_at is null) на месте и остались партиальными — снимается только плацебо 0068 Р12, не они');


-- 3. Гранты не изменились (drop/add constraint и create index их не трогают, дёшево проверить) -------

select ok(
  (select bool_and(
     has_table_privilege('authenticated', t::regclass, 'SELECT')
     and not has_table_privilege('authenticated', t::regclass, 'INSERT')
     and not has_table_privilege('anon', t::regclass, 'SELECT'))
   from unnest(array[
     'public.syllable_assessments', 'public.prosody_assessments', 'public.reading_writing_assessments'
   ]) t),
  'Три таблицы речевой карты: authenticated — только select, anon — ничего');


-- 4. Поведение: физический delete родителя — SET NULL только своей колонки (Р1) --------------------
-- Отдельный «специалист-заполнитель» держит lessons.teacher_id (not null,
-- restrict) — иначе delete на диагностическом/слоговом специалисте упёрся
-- бы в lessons_teacher_fk restrict раньше, чем до diagnostics/syllable_
-- assessments дело дойдёт.

insert into public.centers (id, name, slug, settings) values
  ('c0690000-0000-0000-0000-000000000001', 'Центр 0069', 'centr-0069-fk', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('a0690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', 'Специалист-диагностика 0069'),
  ('a0690000-0000-0000-0000-000000000002', 'c0690000-0000-0000-0000-000000000001', 'Специалист-слоговая 0069'),
  ('a0690000-0000-0000-0000-000000000099', 'c0690000-0000-0000-0000-000000000001', 'Специалист-заполнитель занятий 0069');

insert into public.payers (id, center_id, full_name, phone) values
  ('d0690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', 'Плательщик 0069', '+996700000199');

insert into public.students (id, center_id, full_name, payer_id) values
  ('e0690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', 'Ребёнок 0069', 'd0690000-0000-0000-0000-000000000001');

insert into public.services (id, center_id, name) values
  ('f0690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', 'Индивидуальное 0069');

insert into public.lessons (id, center_id, teacher_id, service_id, student_id, starts_at, ends_at, status) values
  ('10690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', 'a0690000-0000-0000-0000-000000000099',
   'f0690000-0000-0000-0000-000000000001', 'e0690000-0000-0000-0000-000000000001', now(), now() + interval '30 minutes', 'planned'),
  ('10690000-0000-0000-0000-000000000002', 'c0690000-0000-0000-0000-000000000001', 'a0690000-0000-0000-0000-000000000099',
   'f0690000-0000-0000-0000-000000000001', 'e0690000-0000-0000-0000-000000000001', now() + interval '1 hour', now() + interval '90 minutes', 'planned');

insert into public.goal_stages (id, center_id, code, title) values
  ('90690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', 'stage-0069', 'Этап 0069');

insert into public.goals (id, center_id, student_id, stage_id, title) values
  ('80690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', 'e0690000-0000-0000-0000-000000000001',
   '90690000-0000-0000-0000-000000000001', 'Цель 0069');

-- created_at/updated_at — явно на час в прошлое: `now()` в pgTAP-файле
-- зафиксирован на начало транзакции (transaction_timestamp), обычный
-- default `now()` дал бы created_at = updated_at и никаким pg_sleep их не
-- развести. После каскада moddatetime поставит updated_at = тот же
-- зафиксированный `now()` — час вперёд от явно состаренного created_at.
insert into public.diagnostics (id, center_id, student_id, teacher_id, created_at, updated_at) values
  ('70690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', 'e0690000-0000-0000-0000-000000000001',
   'a0690000-0000-0000-0000-000000000001', now() - interval '1 hour', now() - interval '1 hour');

insert into public.syllable_assessments (id, center_id, student_id, teacher_id, created_at, updated_at) values
  ('40690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', 'e0690000-0000-0000-0000-000000000001',
   'a0690000-0000-0000-0000-000000000002', now() - interval '1 hour', now() - interval '1 hour');

insert into public.goal_progress (id, center_id, goal_id, lesson_id, score) values
  ('60690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', '80690000-0000-0000-0000-000000000001',
   '10690000-0000-0000-0000-000000000001', 50);

insert into public.homework (id, center_id, student_id, lesson_id) values
  ('50690000-0000-0000-0000-000000000001', 'c0690000-0000-0000-0000-000000000001', 'e0690000-0000-0000-0000-000000000001',
   '10690000-0000-0000-0000-000000000002');

delete from public.teachers where id = 'a0690000-0000-0000-0000-000000000001';

select ok(
  exists (select 1 from public.diagnostics
     where id = '70690000-0000-0000-0000-000000000001'
       and teacher_id is null and center_id = 'c0690000-0000-0000-0000-000000000001'
       and student_id = 'e0690000-0000-0000-0000-000000000001' and updated_at <> created_at),
  'diagnostics: физический delete специалиста — SET NULL только teacher_id, center_id и student_id не тронуты (не 23502), updated_at сдвинулся (каскад — настоящий UPDATE, не no-op)');

delete from public.teachers where id = 'a0690000-0000-0000-0000-000000000002';

select ok(
  exists (select 1 from public.syllable_assessments
     where id = '40690000-0000-0000-0000-000000000001'
       and teacher_id is null and center_id = 'c0690000-0000-0000-0000-000000000001'
       and student_id = 'e0690000-0000-0000-0000-000000000001' and updated_at <> created_at),
  'syllable_assessments: физический delete специалиста — SET NULL только teacher_id, center_id и student_id не тронуты (не 23502), updated_at сдвинулся');

delete from public.lessons where id = '10690000-0000-0000-0000-000000000001';

select ok(
  exists (select 1 from public.goal_progress
     where id = '60690000-0000-0000-0000-000000000001'
       and lesson_id is null and center_id = 'c0690000-0000-0000-0000-000000000001'
       and goal_id = '80690000-0000-0000-0000-000000000001'),
  'goal_progress: физический delete занятия — SET NULL только lesson_id, center_id и goal_id не тронуты (не 23502)');

delete from public.lessons where id = '10690000-0000-0000-0000-000000000002';

select ok(
  exists (select 1 from public.homework
     where id = '50690000-0000-0000-0000-000000000001'
       and lesson_id is null and center_id = 'c0690000-0000-0000-0000-000000000001'
       and student_id = 'e0690000-0000-0000-0000-000000000001'),
  'homework: физический delete занятия — SET NULL только lesson_id, center_id и student_id не тронуты (не 23502)');


select * from finish();
rollback;
