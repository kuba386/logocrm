-- pgTAP: общая библиотека упражнений платформы (0074).
--
-- Миграция — данные без схемы. Проверяется не текст, а инварианты набора:
-- строки платформенные (center_id is null), области из закрытого перечня,
-- этапы — только семь кодов seed_goal_stages, возраст осмыслен, названия
-- уникальны, механические приёмы помечены «только специалист» и не «дом»,
-- набор виден специалисту и владельцу центра, не виден регистратору (0036), а
-- прямой записи платформенной строки из живой сессии по-прежнему нет (0040).
-- Забор по содержанию: пошаговых механических приёмов, огня и шаров в наборе
-- нет (библиотеку читает и родитель — теги ничего не запрещают).
-- Прежние тесты, считавшие таблицу целиком, переведены на строки фикстуры.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(14);


-- 1. Набор ----------------------------------------------------------------------------------------

select ok(
  (select count(*) from public.exercise_library where center_id is null and deleted_at is null) >= 90,
  'Платформенная библиотека заполнена: 90 упражнений набора не потеряны');

select is(
  (select count(distinct area)::int from public.exercise_library where center_id is null and deleted_at is null), 9,
  'Девять областей');

select is_empty(
  $$ select area from public.exercise_library where center_id is null and deleted_at is null
      and area not in ('артикуляционная гимнастика', 'звукопроизношение', 'дыхание и голос', 'мелкая моторика',
                       'фонематический слух', 'слоговая структура', 'лексика и грамматика', 'связная речь',
                       'чтение и письмо') $$,
  'Области — из закрытого перечня, без опечаток, разбивающих фильтр экрана');

select is_empty(
  $$ select title, stage_code from public.exercise_library
      where center_id is null and deleted_at is null and stage_code is not null
        and stage_code not in ('setting', 'isolated', 'syllables', 'words', 'phrases', 'speech', 'differentiation') $$,
  'Этап — один из семи кодов seed_goal_stages: иначе экран покажет сырой код вместо названия этапа');

select is_empty(
  $$ select title from public.exercise_library
      where center_id is null and deleted_at is null
        and (length(trim(title)) < 3 or length(coalesce(instructions, '')) < 40
             or coalesce(cardinality(tags), 0) = 0 or media_url is not null
             or age_from is null or age_to is null or age_from > age_to or age_from < 2 or age_to > 12
             or is_active is not true) $$,
  'Каждое упражнение: название, инструкция от 40 знаков, теги, разумный возраст 2–12, активное, без внешних ссылок (Р6)');

select is(
  (select count(*)::int from (select lower(title) from public.exercise_library
                               where center_id is null and deleted_at is null group by 1 having count(*) > 1) d), 0,
  'Названия уникальны без учёта регистра');

select is_empty(
  $$ select title from public.exercise_library
      where center_id is null and deleted_at is null and 'только специалист' = any(tags)
        and ('дом' = any(tags) or not ('кабинет' = any(tags))) $$,
  'Согласованность тегов: этап «только специалист» не помечен «дом» (сам тег ничего не запрещает — Р3, Р7)');

select ok(
  exists (select 1 from public.exercise_library where center_id is null and title = 'Артикуляционная гимнастика: общие правила'
           and instructions like '%не подтверждают%'),
  'Первое упражнение области честно говорит о пределах доказательности (Р4)');

select is(
  (select count(distinct stage_code)::int from public.exercise_library
    where center_id is null and deleted_at is null and area = 'звукопроизношение'), 7,
  'В звукопроизношении представлены все семь этапов (постановка, изолированно, слоги, слова, фразы, речь, дифференциация)');

select is_empty(
  $$ select title from public.exercise_library
      where center_id is null and deleted_at is null
        and instructions ~* '(шпател|зонд|соск|свеч|огон|пламя|латекс|воздушн[а-я]+ шар|надува[а-я]+ шар)'
        and title <> 'Постановка звука: работа специалиста' $$,
  'Забор по содержанию (Р7): ни огня, ни шпателя, ни зонда, ни шаров в описаниях — кроме указания, что постановку ведёт специалист');

select is(
  (select count(*)::int from public.exercise_library
    where center_id is null and deleted_at is null and 'дом' = any(tags) and area = 'звукопроизношение'
      and stage_code in ('isolated', 'syllables', 'words', 'phrases', 'speech') and instructions not like '%по назначению специалиста%'), 0,
  'Каждое упражнение на звук с тегом «дом» напоминает: дома — по назначению специалиста, когда звук поставлен (Р7)');


-- 2. Видимость и запись ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','74000000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0074@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','74000000-0000-0000-0000-000000000002','authenticated','authenticated','registrar-0074@test.kg','','','','','','','','');
insert into public.centers (id, name, slug, settings) values
  ('74000000-0000-0000-0000-0000000000c1','Центр 0074','centr-0074','{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.memberships (user_id, center_id, role) values
  ('74000000-0000-0000-0000-000000000001','74000000-0000-0000-0000-0000000000c1','owner'),
  ('74000000-0000-0000-0000-000000000002','74000000-0000-0000-0000-0000000000c1','registrar');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_all as
  select count(*)::int as n from public.exercise_library where center_id is null and deleted_at is null;
grant select on t_all to public;

select public.tests_claims('74000000-0000-0000-0000-000000000001','74000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.exercise_library where center_id is null), (select n from t_all),
  'Владелец центра видит весь платформенный набор');
select throws_ok(
  $q$ select public.save_exercise('Платформенное через RPC', (select id from public.exercise_library where center_id is null limit 1)) $q$,
  '42704', 'Упражнение не найдено', 'Платформенную строку из живой сессии не переписать: save_exercise правит только строки своего центра (0040)');
reset role;

select public.tests_claims('74000000-0000-0000-0000-000000000002','74000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.exercise_library), 0, 'Регистратор библиотеку не видит (0036), даже платформенную');
reset role;
select public.tests_claims(null, null);

select * from finish();
rollback;
