-- =============================================================================
-- 0039_complete_lesson.sql — «Провести занятие» одним вызовом (этап 7a, финал)
--
-- 0036 завёл таблицы и чтение, 0038 — точечные RPC записи. Здесь — атомарный
-- сценарий экрана «Провести занятие» (docs/Roadmap/stages.md, «Доработка»):
-- посещение, списание (через ту же mark_attendance), заметка, прогресс по
-- целям, домашнее задание и lessons.status = 'done' одним вызовом. Либо всё,
-- либо ничего — половина отмеченного занятия хуже неотмеченного.
--
-- Решения (план проверен субагентом architect):
--   Р1. Строка занятия берётся select ... for update ДО проверки статуса.
--       Без блокировки два параллельных вызова (двойной клик, повтор по
--       таймауту) оба читают status='planned' и оба проходят: одно занятие
--       получит два attendance-триггера подряд (не страшно — уникальный
--       ключ и пересчёт из строк это гасят), но lesson.completed уйдёт в
--       outbox дважды, и родитель получит два уведомления, когда 7b
--       подключит доставку. Проверка «уже проведено» имеет смысл только
--       после блокировки — она же и есть единственная гарантия идемпотентности,
--       а не сам факт отказа с 23514.
--   Р2. Покрытие состава занятия проверяется по таблице attendance, а не по
--       длине присланного массива. Причины две: (а) экран может прислать
--       неполный черновик (потерялась строка, обрыв сети) — занятие уйдёт в
--       done с ребёнком без отметки, а month_open_lessons_count (0031)
--       считает такое занятие открытым независимо от статуса, и бухгалтер
--       найдёт дыру только в конце месяца; (б) mark_attendance способна
--       вернуть null изнутри своего exception-блока (0026) — доверять
--       возврату perform нельзя, а строке в attendance можно.
--   Р3. У goal_progress/homework один вызов — одна запись на цель/ребёнка:
--       conduct_key = p_lesson_id (уникальность в 0036 — (goal_id,
--       conduct_key) и (student_id, conduct_key)), значит повтор той же
--       цели/ребёнка в одном payload не создаёт вторую запись, а тихо
--       возвращает id первой — специалист решил бы, что вторая оценка или
--       второе задание сохранились, а они исчезли без следа. Поэтому дубль
--       внутри одного вызова отбивается явной ошибкой ДО первой записи, а
--       не молча схлопывается.
--   Р4. Форма p проверяется целиком: неизвестный ключ верхнего уровня и
--       не-массив в известном — явная ошибка с именем ключа. Экран чистит
--       черновик localStorage после успеха — «успех» обязан значить «все
--       присланные разделы записаны», а не «то, что не потерялось при
--       вводе неверного ключа».
--   Р5. lesson_id всех клинических вызовов — только аргумент функции,
--       никогда не значение из p. clinical_check_lesson_participant (0036)
--       возвращает new без проверки, если lesson_id is null — единственная
--       причина, по которой чужой ребёнок в notes/homework отбивается,
--       это то, что lesson_id туда попадает явно и всегда.
--   Р6. Заметку занятия, закрываемого owner/admin (специалист заболел),
--       подписывает вёдший занятие: coalesce(substitute_teacher_id,
--       teacher_id) передаётся как p_teacher_id в write_lesson_note.
--       write_lesson_note сам её проигнорирует для роли teacher (берёт
--       my_teacher_id()) — передавать можно безусловно.
--   Р7. Срок ДЗ — не дата с клиента, а смещение в днях от center_today
--       (docs/Database.md, «время в поясе центра»): due_in_days integer,
--       due_on = center_today(v_center) + due_in_days. Прямая дата с
--       клиента для record_diagnostic/record_goal_progress уже отбита в
--       0038 (Р6) тем же приёмом — complete_lesson был единственным местом,
--       где дата всё ещё приходила бы извне.
--   Р8. Занятие из будущего отбивается явно до записи: attendance_fill_and_
--       check (0009) сделал бы то же самое, но только если attendance
--       вообще пришла — при пустом payload (до Р2) занятие ушло бы в done
--       без единой проверки.
--   Р9. Роли — owner, admin, teacher. Не can_front_desk (mark_attendance
--       её пускает): регистратору клиника не положена вовсе (0036 Р2), а
--       complete_lesson всегда концептуально клинический вызов, даже с
--       пустыми progress/notes/homework.
--  Р10. Верхняя проверка teacher_of_lesson — не гарантия (её держат сами
--       mark_attendance/mark_lesson_status), а единообразное сообщение до
--       любых побочных эффектов при пустом payload. Не убирать как
--       «дубль» — без неё то же самое отобьётся глубже в стеке и с другим
--       текстом на каждом шаге.
--  Р11. За один вызов в outbox ложится attendance.marked на каждого
--       участника (и возможные low_balance/exhausted/absent_streak),
--       homework.assigned на каждого с заданием и один lesson.completed.
--       Доставка 7b должна знать, что это один факт занятия, а не считать
--       события поштучно.
--  Р12. Списание — исключительно через mark_attendance: подбор абонемента,
--       заморозка цены и lessons_used считает attendance_fill_and_check +
--       attendance_recalc_trigger (0009/0010). Отдельного шага списания в
--       этой функции нет и заводить его нельзя — источник должен быть один.
-- =============================================================================

create or replace function public.complete_lesson(p_lesson_id uuid, p jsonb default '{}'::jsonb)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_role    text := coalesce(public.my_role(), '');
  v_lesson  public.lessons;
  v_key     text;
  v_item    jsonb;
  v_missing text;
  v_teacher_for_notes uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;
  -- Р9: не can_front_desk — регистратору клиника не положена вовсе.
  if v_role not in ('owner', 'admin', 'teacher') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р1: блокировка строки раньше любой проверки статуса.
  select * into v_lesson from public.lessons
   where id = p_lesson_id and center_id = v_center and deleted_at is null
     for update;

  if not found then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;

  -- Р10: единообразное сообщение до побочных эффектов; настоящую границу
  -- держат mark_attendance/mark_lesson_status ниже по стеку.
  if v_role = 'teacher' and not public.teacher_of_lesson(p_lesson_id) then
    raise exception 'Это занятие ведёт другой специалист' using errcode = '42501';
  end if;

  if v_lesson.status = 'cancelled' then
    raise exception 'Отменённое занятие нельзя провести' using errcode = '23514';
  end if;
  if v_lesson.status = 'done' then
    raise exception 'Занятие уже проведено — откройте карточку и нажмите «Править»'
      using errcode = '23514';
  end if;
  -- Р8: до этой строки — до того, как что-либо записано.
  if v_lesson.starts_at > now() then
    raise exception 'Занятие ещё не началось' using errcode = '22023';
  end if;

  -- Р4: форма payload — целиком, а не по частям по ходу дела.
  for v_key in select jsonb_object_keys(coalesce(p, '{}'::jsonb)) loop
    if v_key not in ('attendance', 'progress', 'notes', 'homework') then
      raise exception 'Неизвестный раздел данных занятия: %', v_key using errcode = '22023';
    end if;
  end loop;
  if p ? 'attendance' and jsonb_typeof(p -> 'attendance') <> 'array' then
    raise exception 'attendance должен быть массивом' using errcode = '22023';
  end if;
  if p ? 'progress' and jsonb_typeof(p -> 'progress') <> 'array' then
    raise exception 'progress должен быть массивом' using errcode = '22023';
  end if;
  if p ? 'notes' and jsonb_typeof(p -> 'notes') <> 'array' then
    raise exception 'notes должен быть массивом' using errcode = '22023';
  end if;
  if p ? 'homework' and jsonb_typeof(p -> 'homework') <> 'array' then
    raise exception 'homework должен быть массивом' using errcode = '22023';
  end if;

  -- Р3: дубль в массиве — явная ошибка раньше первой записи, а не тихое
  -- схлопывание в одну строку через conduct_key.
  if (select count(*) from jsonb_array_elements(coalesce(p -> 'progress', '[]'::jsonb)))
     <> (select count(distinct e ->> 'goal_id') from jsonb_array_elements(coalesce(p -> 'progress', '[]'::jsonb)) e)
  then
    raise exception 'В прогрессе по целям — повтор одной цели за одно занятие' using errcode = '23514';
  end if;
  if (select count(*) from jsonb_array_elements(coalesce(p -> 'homework', '[]'::jsonb)))
     <> (select count(distinct e ->> 'student_id') from jsonb_array_elements(coalesce(p -> 'homework', '[]'::jsonb)) e)
  then
    raise exception 'В домашних заданиях — повтор одного ребёнка за одно занятие' using errcode = '23514';
  end if;
  if (select count(*) from jsonb_array_elements(coalesce(p -> 'notes', '[]'::jsonb)))
     <> (select count(distinct e ->> 'student_id') from jsonb_array_elements(coalesce(p -> 'notes', '[]'::jsonb)) e)
  then
    raise exception 'В заметках занятия — повтор одного ребёнка за одно занятие' using errcode = '23514';
  end if;

  -- 1. Посещение и списание (Р12) -------------------------------------------

  for v_item in select * from jsonb_array_elements(coalesce(p -> 'attendance', '[]'::jsonb)) loop
    perform public.mark_attendance(
      p_lesson_id,
      (v_item ->> 'student_id')::uuid,
      nullif(v_item ->> 'status_code', ''),
      nullif(v_item ->> 'comment', '')
    );
  end loop;

  -- Р2: покрытие — по таблице, не по длине массива.
  if not exists (
    select 1 from public.lesson_participants
     where lesson_id = p_lesson_id and deleted_at is null
  ) then
    raise exception 'В занятии нет ни одного участника' using errcode = '23514';
  end if;

  select string_agg(lp.student_id::text, ', ') into v_missing
    from public.lesson_participants lp
   where lp.lesson_id = p_lesson_id and lp.deleted_at is null
     and not exists (
       select 1 from public.attendance a
        where a.lesson_id = p_lesson_id and a.student_id = lp.student_id
     );
  if v_missing is not null then
    raise exception 'Не отмечено посещение: %', v_missing using errcode = '23514';
  end if;

  -- 2. Прогресс по целям (Р3, Р5) --------------------------------------------

  for v_item in select * from jsonb_array_elements(coalesce(p -> 'progress', '[]'::jsonb)) loop
    perform public.record_goal_progress(
      (v_item ->> 'goal_id')::uuid,
      (v_item ->> 'score')::int,
      nullif(v_item ->> 'note', ''),
      p_lesson_id,
      null,
      p_lesson_id
    );
  end loop;

  -- 3. Заметка занятия (Р5, Р6) -----------------------------------------------

  v_teacher_for_notes := coalesce(v_lesson.substitute_teacher_id, v_lesson.teacher_id);

  for v_item in select * from jsonb_array_elements(coalesce(p -> 'notes', '[]'::jsonb)) loop
    perform public.write_lesson_note(
      p_lesson_id,
      (v_item ->> 'student_id')::uuid,
      v_item -> 'soap',
      nullif(v_item ->> 'parent_summary', ''),
      v_teacher_for_notes
    );
  end loop;

  -- 4. Домашнее задание (Р3, Р5, Р7) -------------------------------------------

  for v_item in select * from jsonb_array_elements(coalesce(p -> 'homework', '[]'::jsonb)) loop
    perform public.assign_homework(
      (v_item ->> 'student_id')::uuid,
      nullif(v_item ->> 'free_text', ''),
      coalesce(
        (select array_agg((x)::uuid) from jsonb_array_elements_text(coalesce(v_item -> 'exercise_ids', '[]'::jsonb)) x),
        '{}'::uuid[]
      ),
      p_lesson_id,
      case when v_item ? 'due_in_days' and v_item ->> 'due_in_days' is not null
             then public.center_today(v_center) + (v_item ->> 'due_in_days')::int
           else null end,
      p_lesson_id
    );
  end loop;

  -- 5. Статус и событие ------------------------------------------------------

  perform public.mark_lesson_status(p_lesson_id, 'done');

  perform public.emit_event('lesson.completed',
    jsonb_build_object('center_id', v_center, 'lesson_id', p_lesson_id), v_center);
end;
$$;

comment on function public.complete_lesson(uuid, jsonb) is
  'Экран «Провести занятие» одним вызовом: посещение+списание, заметка, прогресс по целям, ДЗ, lessons.status=''done'', события. Всё или ничего — план проверен субагентом architect, решения Р1–Р12 в заголовке миграции.';

revoke all on function public.complete_lesson(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.complete_lesson(uuid, jsonb) to authenticated;
