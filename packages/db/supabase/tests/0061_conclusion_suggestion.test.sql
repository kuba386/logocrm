-- pgTAP: подсказка заключения из шкал speech_areas (0061).
--
-- Функция чистая (language sql immutable, ни одной таблицы) — фикстур
-- центра/ролей не требуется. Случаи 1–16 — тот же пронумерованный список,
-- что в packages/core/src/nosology.test.ts; расходятся реализации,
-- расходятся и результаты. Остальное (замкнутость результата, каталог
-- speech_conclusions, форма jsonb-аргумента) — только здесь, у SQL нет
-- статической типизации TS и своего справочника с is_active.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(30);


-- 0. Тотальность — функция никогда не бросает, каким бы ни был speech_areas ----------------------

select lives_ok(
  $$ select public.suggest_speech_conclusion('{"звукопроизношение":"средне"}'::jsonb) $$,
  'Строка вместо числа — не 22P02, функция тотальна (главный урок ревью плана)');
select lives_ok(
  $$ select public.suggest_speech_conclusion('{"звукопроизношение":0,"фонематика":7,"лексика":2.5,"грамматика":null,"связная речь":[1,2]}'::jsonb) $$,
  'Мусор в каждом ключе (0, 7, дробное, null, массив) — не бросает');
select lives_ok(
  $$ select public.suggest_speech_conclusion('{}'::jsonb) $$,
  'Пустой jsonb-объект — не бросает');
select lives_ok(
  $$ select public.suggest_speech_conclusion(null) $$,
  'null вместо jsonb — не бросает');
select lives_ok(
  $$ select public.suggest_speech_conclusion('[1,2,3]'::jsonb) $$,
  'jsonb-массив вместо объекта — не бросает');
select lives_ok(
  $$ select public.suggest_speech_conclusion('"строка"'::jsonb) $$,
  'jsonb-скаляр (строка) вместо объекта — не бросает');
select is(
  public.suggest_speech_conclusion(null), null,
  'null-аргумент — null-результат, не ошибка');
select is(
  public.suggest_speech_conclusion('[1,2,3]'::jsonb), null,
  'jsonb-массив вместо объекта — null, не совпадение по индексу');


-- 1–16. Единый список случаев (см. nosology.test.ts) ----------------------------------------------

select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":5,"лексика":5,"грамматика":5,"связная речь":5}'::jsonb),
  null,
  '1. Все пять в норме — null, а не norm (функция не видит sounds, Р8)');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":3,"фонематика":3,"лексика":3,"грамматика":3,"связная речь":3}'::jsonb),
  null,
  '2. Граница: 3 по всем — ещё «не нарушено», тоже null');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":2,"фонематика":5,"лексика":5,"грамматика":5,"связная речь":5}'::jsonb),
  'fnr',
  '3. Граница: 2 в звукопроизношении — уже нарушено, fnr');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":1,"фонематика":5,"лексика":5,"грамматика":5,"связная речь":5}'::jsonb),
  'fnr',
  '4. Только звукопроизношение нарушено (1) — fnr');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":2,"фонематика":2,"лексика":5,"грамматика":5,"связная речь":5}'::jsonb),
  'ffnr',
  '5. Звукопроизношение и фонематика нарушены, остальное в норме — ffnr');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":1,"лексика":5,"грамматика":5,"связная речь":5}'::jsonb),
  'ffnr',
  '6. Только фонематика нарушена (без звукопроизношения) — тоже ffnr');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":5,"лексика":2,"грамматика":5,"связная речь":5}'::jsonb),
  'onr_suspected',
  '7. Нарушена лексика — onr_suspected');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":5,"лексика":5,"грамматика":1,"связная речь":5}'::jsonb),
  'onr_suspected',
  '8. Нарушена только грамматика — тоже onr_suspected');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":5,"лексика":5,"грамматика":5,"связная речь":2}'::jsonb),
  'onr_suspected',
  '9. Нарушена только связная речь — тоже onr_suspected');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":5,"лексика":1,"грамматика":5,"связная речь":5}'::jsonb),
  (select public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":5,"лексика":2,"грамматика":2,"связная речь":2}'::jsonb)),
  '10. Тяжесть не влияет на флаг: одна область=1 и три области=2 дают один и тот же onr_suspected (Р1)');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":1,"фонематика":1,"лексика":1,"грамматика":5,"связная речь":5}'::jsonb),
  'onr_suspected',
  '11. Приоритет: нарушены звукопроизношение/фонематика/лексика разом — onr_suspected, не ффнр');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":5,"лексика":5,"грамматика":5}'::jsonb),
  null,
  '12. Не хватает «связная речь» — null (недостаточно данных)');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":5,"лексика":"средне","грамматика":5,"связная речь":5}'::jsonb),
  null,
  '13. Нечисловое значение в любой из пяти — null, не бросает');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":5,"лексика":0,"грамматика":5,"связная речь":5}'::jsonb),
  null,
  '14. Значение 0 — вне шкалы [1,5], null, не «тяжело нарушено»');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":6,"фонематика":5,"лексика":5,"грамматика":5,"связная речь":5}'::jsonb),
  null,
  '15. Значение 6 — вне шкалы [1,5], null, не «норма»');
select is(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":5,"фонематика":5,"лексика":2.5,"грамматика":5,"связная речь":5}'::jsonb),
  null,
  '16. Дробное значение внутри диапазона (2.5) — валидный балл, не нарушено');


-- 17. Ключи зашиты литералами — переименование/регистр/пробел гасит подсказку --------------------

select is(
  public.suggest_speech_conclusion(
    '{"Звукопроизношение":1,"фонематика":5,"лексика":5,"грамматика":5,"связная речь":5}'::jsonb),
  null,
  '17. Ключ с большой буквы («Звукопроизношение») не совпадает — null, не fnr (ключи зашиты литералами)');


-- 18. Замкнутость результата — на любом входе результат из закрытого множества --------------------

select ok(
  public.suggest_speech_conclusion(
    '{"звукопроизношение":1,"фонематика":1,"лексика":1,"грамматика":1,"связная речь":1}'::jsonb)
    in ('onr_suspected', 'fnr', 'ffnr'),
  '18. Самый тяжёлый профиль (все по 1) — результат из закрытого множества, не onr_1..onr_4 и не zrr');


-- 19. speech_conclusions — положительная сторона: реальные коды подсказки существуют и активны ----

select is(
  (select count(*)::int from public.speech_conclusions where code = 'fnr' and is_active), 1,
  '19a. fnr есть в справочнике и активен — иначе кнопка «Применить» тихо исчезает (0059)');
select is(
  (select count(*)::int from public.speech_conclusions where code = 'ffnr' and is_active), 1,
  '19b. ffnr есть в справочнике и активен');
select is(
  (select count(*)::int from public.speech_conclusions where code = 'onr_suspected'), 0,
  '19c. onr_suspected не является кодом speech_conclusions — коллизии со справочником нет');
select is(
  (select count(*)::int from public.speech_conclusions where code = 'norm'), 1,
  '19d. norm остаётся в справочнике как код для ручного выбора — просто подсказка его больше не предлагает (Р8)');

select * from finish();
rollback;
