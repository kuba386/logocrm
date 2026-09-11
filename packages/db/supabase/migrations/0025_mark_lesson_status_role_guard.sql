-- =============================================================================
-- 0025_mark_lesson_status_role_guard.sql — последняя RPC без coalesce в роли
--
-- 0011_role_guards.sql закрыла `NULL not in ('owner','admin')` в девяти RPC
-- этапов 0–3. mark_lesson_status в тот список не попала — ни в миграцию, ни
-- в тест 0011_role_guards.test.sql. Её определение так и осталось из 0006:928.
--
-- Что это значит у неё. Роль читается в переменную: v_role := my_role(), и у
-- пользователя с живым JWT, но уже отозванным членством, это NULL. Дальше:
--
--   if v_role = 'teacher' then ...                 -- NULL = 'teacher' → NULL
--   elsif v_role not in ('owner','admin') then     -- NULL not in (...) → NULL
--     raise exception 'Недостаточно прав';
--   end if;
--   update public.lessons set status = p_status, notes = ... ;
--
-- Ни одна ветка не срабатывает — управление доходит до update. Проверка
-- «занятие моё», которая живёт внутри ветки teacher, при NULL тоже не
-- выполняется, поэтому речь о ЛЮБОМ занятии центра из JWT: функция
-- security definer, RLS внутри неё не действует.
--
-- Второго рубежа здесь нет, в отличие от остальных девяти. Шапка 0011
-- опирается на то, что «каждая заканчивается emit_event, а тот требует
-- role_in(center) is not null и откатывает транзакцию». В этой функции
-- emit_event стоит под `if p_status = 'cancelled'`. Значит:
--   * 'cancelled' — update проходит, но emit_event откатывает транзакцию;
--   * 'done' и 'planned' — изменение сохраняется молча.
--
-- Цена ошибки не косметическая: 'done' — это признак проведённого занятия,
-- по которому считается зарплата (calc_salary берёт attendance с
-- pays_teacher и lessons.status = 'done', 0017_teacher_rates_and_salary.sql).
-- Плюс переписывается notes.
--
-- Тело — дословно из 0006:928-984, меняется ровно одна строка (правило
-- 0011). Ветку teacher править не нужно: после coalesce в elsif NULL
-- отбивается 42501 раньше, чем дойдёт до update.
--
-- Номер 0025, а не 0024: 0024 занят веткой feat/0024-access-hygiene, ещё не
-- влитой. Пропуск номера безвреден, дубль роняет db reset на
-- schema_migrations_pkey (docs/Database.md).
-- =============================================================================

create or replace function public.mark_lesson_status(
  p_lesson_id uuid, p_status text, p_notes text default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := public.my_role();
  v_lesson public.lessons;
begin
  if p_status not in ('planned', 'done', 'cancelled') then
    raise exception 'Неизвестный статус %', p_status using errcode = '22023';
  end if;

  select * into v_lesson
    from public.lessons
   where id = p_lesson_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;

  if v_role = 'teacher' then
    if v_lesson.teacher_id is distinct from public.my_teacher_id()
       and v_lesson.substitute_teacher_id is distinct from public.my_teacher_id() then
      raise exception 'Это занятие ведёт другой специалист' using errcode = '42501';
    end if;

    if v_lesson.status <> 'planned' then
      raise exception 'Занятие уже закрыто — изменить может только администратор'
        using errcode = '42501';
    end if;

    if p_status not in ('done', 'cancelled') then
      raise exception 'Специалист может только провести или отменить занятие'
        using errcode = '42501';
    end if;

  elsif coalesce(v_role, '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.lessons
     set status = p_status,
         notes  = coalesce(p_notes, notes)
   where id = p_lesson_id;

  if p_status = 'cancelled' then
    perform public.emit_event('lesson.cancelled',
      jsonb_build_object('center_id', v_center, 'lesson_id', p_lesson_id,
                         'by_role', v_role), v_center);
  end if;
end;
$$;

-- Гранты повторяются явно: правило проекта (CLAUDE.md), а create or replace
-- их и так сохраняет — но искать ACL по истории миграций не должно быть нужно.
revoke all on function public.mark_lesson_status(uuid, text, text) from public, anon;
grant execute on function public.mark_lesson_status(uuid, text, text) to authenticated;
