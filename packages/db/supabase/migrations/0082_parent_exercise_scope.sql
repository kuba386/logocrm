-- =============================================================================
-- 0082_parent_exercise_scope.sql — родитель видит только упражнения из ДЗ
-- своих детей
--
-- Решение владельца. До 0082 exercise_library_read_all (0036) отдавала
-- родителю всю библиотеку центра и платформы прямым GET /rest/v1/
-- exercise_library — включая методички центра, которые не вычищались под
-- родителя так, как платформенные (0074 Р7).
--
-- Ревью плана — architect (блокеров нет):
--   Р1. Роли — явным списком: owner/admin/teacher видят библиотеку как раньше,
--       parent — только parent_exercise_ids(). Не «всё, кроме родителя»: новая
--       роль в clinical_role_allowed иначе получила бы всю библиотеку молча.
--   Р2. parent_exercise_ids() — set-returning SECURITY DEFINER рядом с
--       homework_exercises (политика, читающая таблицу с RLS, ходит через
--       definer — иначе recursion). В политике — id in (select …): подзапрос не
--       зависит от строки и считается один раз на запрос, а не на каждую из
--       90+ платформенных строк.
--   Р3. Видны упражнения из живых строк живых ДЗ живых детей текущего центра,
--       любого статуса ДЗ. Упражнение «только специалист» (0081) родителю не
--       отдаётся даже из ДЗ, выданного до тега: смысл тега — методичка не для
--       родителя.
--   Р4. registrar/finance — по-прежнему ничего. Список ролей теперь и здесь, не
--       только в clinical_role_allowed (0036 называл её единственным местом).
--
-- Записано, не чинится: web родителя названий упражнений в ДЗ не показывает
-- вовсе (students/[id]/page.tsx, ветка parent: exerciseTitles: []) — отдельная
-- задача; политика меняет только прямое чтение таблицы.
-- =============================================================================

create function public.parent_exercise_ids()
  returns setof uuid
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_payer  uuid;
begin
  if auth.uid() is null or v_center is null or coalesce(public.my_role(), '') <> 'parent' then
    return;
  end if;
  -- Отдельным if: payer_id = NULL в предикате дал бы NULL, а не отказ.
  v_payer := public.my_payer_id();
  if v_payer is null then
    return;
  end if;

  return query
    select distinct he.exercise_id
      from public.homework_exercises he
      join public.homework h on h.id = he.homework_id and h.center_id = he.center_id
      -- Плательщик один раз, join по students_payer_idx — не parent_of_student на
      -- каждую строку ДЗ центра. Условия те же: свой плательщик, ребёнок не удалён.
      join public.students s on s.id = h.student_id and s.center_id = h.center_id
                            and s.payer_id = v_payer and s.deleted_at is null
      join public.exercise_library e on e.id = he.exercise_id
     where he.center_id = v_center
       and he.deleted_at is null
       and h.deleted_at is null
       and not public.exercise_is_specialist_only(e.tags);
end;
$$;

comment on function public.parent_exercise_ids() is
  'Упражнения, которые родитель видит в библиотеке (0082): из живых строк живых ДЗ его детей в текущем центре, кроме «только специалист» (0081). Не родителю — пусто. Для политики exercise_library_read_all: definer, чтобы не упереться в RLS homework/homework_exercises.';

revoke all on function public.parent_exercise_ids() from public, anon, service_role, bot_worker;
grant execute on function public.parent_exercise_ids() to authenticated;


drop policy if exists exercise_library_read_all on public.exercise_library;
create policy exercise_library_read_all on public.exercise_library
  for select to authenticated
  using (
    deleted_at is null
    and (center_id is null or center_id = public.current_center())
    and (
      coalesce(public.my_role(), '') in ('owner', 'admin', 'teacher')
      or (coalesce(public.my_role(), '') = 'parent' and id in (select public.parent_exercise_ids()))
    )
  );
