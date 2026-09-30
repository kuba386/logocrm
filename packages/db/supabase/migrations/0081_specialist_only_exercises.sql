-- =============================================================================
-- 0081_specialist_only_exercises.sql — «только специалист» не выдаётся в ДЗ
--
-- Долг из 0074 Р3/Р7: теги — свободный text[], тег «только специалист»
-- ничего не запрещал. Решение владельца: такое упражнение нельзя давать в
-- домашнее задание; специалист по-прежнему видит его в библиотеке и работает с
-- ним в кабинете.
--
-- Ревью плана — architect:
--   Р1. Инвариант — в триггере homework_exercises_check_center_refs (0036, других
--       определений нет), а не в assign_homework/update_homework/complete_lesson:
--       все пути записи проходят через него.
--   Р2. Проверяется НОВАЯ выдача: insert, смена exercise_id, смена center_id,
--       возврат строки из архива. Строка ДЗ, выданная до того, как у
--       упражнения появился тег, остаётся; её можно мягко удалить. То же условие
--       теперь и у старой проверки «упражнение живо и своё/платформенное» — это
--       чинит 0074 Р5: мягкое удаление строки ДЗ с удалённым упражнением
--       отбивалось (update_homework снимает весь состав перед вставкой нового).
--       Параллельная правка тегов в READ COMMITTED читается как «выдано до
--       тега» — та же семантика.
--   Р3. Строка упражнения читается один раз и только с фильтром центра: тег и
--       название смотрим у уже найденной «своей или платформенной» строки —
--       иначе в тексте 23514 утекло бы название упражнения чужого центра
--       раньше, чем сработает 42704.
--   Р4. exercise_is_specialist_only(tags) — источник истины; TS-зеркало
--       isSpecialistOnly (packages/core) только скрывает кнопки. Обрезка —
--       btrim(t, E' \t\r\n'), как в зеркале; общие случаи в Vitest и tests/0081.
--   Р5. update_homework пересобирает состав целиком: правка ДЗ, где лежит
--       упражнение, получившее тег после выдачи, отказывает 23514 — это новая
--       выдача (tests/0081 закрепляет).
--
-- Записано, не чинится: для упражнений ЦЕНТРА тег — самоограничение центра
-- (он может снять тег, выдать и вернуть тег; save_exercise не блокируется).
-- Жёстко гарантия держится для платформенных строк — их теги меняет только
-- миграция. Родитель по-прежнему читает всю библиотеку прямым запросом
-- (exercise_library_read_all, 0036) — вопрос владельцу, не здесь.
-- =============================================================================

create function public.exercise_is_specialist_only(p_tags text[])
  returns boolean
  language sql
  immutable
  set search_path = ''
as $$
  select exists (
    select 1 from unnest(coalesce(p_tags, '{}'::text[])) t
     where lower(btrim(t, E' \t\r\n')) = 'только специалист'
  );
$$;

comment on function public.exercise_is_specialist_only(text[]) is
  'Тег «только специалист» (0081): такое упражнение не выдаётся в ДЗ. Источник истины; TS-зеркало isSpecialistOnly (packages/core) — меняются вместе, общие случаи в Vitest и tests/0081.';

revoke all on function public.exercise_is_specialist_only(text[]) from public, anon, authenticated, service_role;


create or replace function public.homework_exercises_check_center_refs()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_title text;
  v_tags  text[];
begin
  -- Проверяется только новая выдача (0081 Р2): мягкое удаление и правка sort не
  -- должны отбиваться из-за того, что стало с упражнением после выдачи.
  if tg_op = 'UPDATE'
     and new.exercise_id is not distinct from old.exercise_id
     and new.center_id is not distinct from old.center_id
     and not (old.deleted_at is not null and new.deleted_at is null) then
    return new;
  end if;

  select e.title, e.tags into v_title, v_tags
    from public.exercise_library e
   where e.id = new.exercise_id
     and e.deleted_at is null
     and (e.center_id is null or e.center_id = new.center_id);

  if not found then
    raise exception 'Упражнение не найдено в этом центре' using errcode = '42704';
  end if;

  if public.exercise_is_specialist_only(v_tags) then
    raise exception 'Упражнение «%» — только для специалиста: в домашнее задание его не дают', v_title
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function public.homework_exercises_check_center_refs() from public, anon, authenticated, service_role;
