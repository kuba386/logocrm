-- =============================================================================
-- 0038_clinical_write_rpcs.sql — клиническое ядро: точечные RPC записи
-- (этап 7a, шаг 2 из 2 — запись; complete_lesson не входит, будет отдельно)
--
-- Номер: 0036 предполагал «0037 придёт позже», но 0037 занял живой баг
-- message_templates (PR #78). Проверено check:versions и git log перед
-- написанием файла — main не двигался с тех пор.
--
-- Решения:
--   Р1. Каждая функция, адресующая строку по id (update_*, set_*,
--       archive_*, review_/submit_homework, approve_lesson_note), сама
--       читает строку по (id, center_id = current_center(), deleted_at is
--       null) и потом ветвится по правам на основе прочитанного, а не по
--       голым параметрам. Без этого owner/admin-ветка любой такой функции —
--       готовый межцентровый пробой: raw update ... where id = p_id без
--       center_id пишет в любую строку базы, поскольку force row level
--       security нигде в проекте не включён, а роль-владелец функции
--       владеет и таблицей.
--   Р2. Право редактировать УЖЕ существующей записи — уже, чем право её
--       ВИДЕТЬ: автор записи (created_by = auth.uid()) или owner/admin.
--       Право её ЗАВЕСТИ — как видимость, clinical_teacher_sees. Иначе
--       заменяющий специалист правил бы чужую клиническую заметку задним
--       числом. Единственное намеренное исключение — update_homework: состав
--       ДЗ до того, как родитель его увидел, это координационный черновик
--       команды, а не чья-то личная заметка, и заменяющий специалист должен
--       уметь поправить состав, если выдавший недоступен; отсюда её право —
--       «видит ребёнка», а не «сам выдал». submit_homework/review_homework —
--       это не правка чужой записи, а обработка своей стороны рабочего
--       процесса (родитель сдаёт своё задание, специалист разбирает то, что
--       видит), поэтому их право — по текущей видимости, не по автору.
--   Р3. update_goal НЕ принимает status. Форма карточки цели и кнопка
--       «Достигнута» — разные действия; одна ручка на оба совмещала бы
--       медленный PATCH формы с быстрым кликом по кнопке, и устаревшая
--       форма могла молча откатить только что нажатую «Достигнута» (и
--       наоборот). Статус — отдельная set_goal_status.
--   Р4. Событие статус-перехода (goal.achieved, homework.submitted,
--       lesson.note_approved) эмитит существующий 0036-триггер, а не новая
--       RPC и не новый параллельный AFTER-триггер: 0036 (Р8) уже это
--       предполагал текстом в комментарии, и переиздание того же триггера
--       через create or replace function — не правка неизменяемой миграции,
--       а обычный способ поправить функцию следующей.
--       Важно: эмитит НЕ public.emit_event (тот проверяет
--       role_in(center_id) у auth.uid() — а фикстура/бэкфилл/будущий 7b-бот
--       пишет строку одного центра, будучи представленным клеймами другого
--       пользователя или вовсе без сессии), а новый internal-only
--       emit_clinical_event: центр строки уже гарантирован её собственным
--       FK и тем, что запись вообще прошла (RLS/RPC-проверку выше по
--       стеку) — повторная проверка членства внутри триггера ловит не
--       злоумышленника, а прямую фикстуру 0036, которая заводит записи
--       центра Б под клеймами владельца центра А.
--   Р5. Диагностика — видимость не меняется (0037 её оставил как есть):
--       владелец 19.09.2026 выбрал «после первого занятия» явно, поэтому
--       clinical_teacher_sees используется как есть, без students.primary_teacher_id.
--   Р6. Дата — по часовому поясу центра, не клиента: p_date default null,
--       coalesce(p_date, center_today(v_center)). CLAUDE.md: «Время
--       рендерится в часовом поясе центра».
--   Р7. Состав ДЗ — дедуп и сортировка одним insert..select с ordinality,
--       без цикла: повтор id в массиве схлопывается в одну строку по
--       первому вхождению, а весь insert атомарен — чужой-центру exercise_id
--       где угодно в списке откатывает всю вставку целиком (проверяет
--       clinical_check_lesson_participant-соседний триггер на самой
--       homework_exercises из 0036, здесь не переиздаётся).
--       p_conduct_key — идемпотентность второго клика: сперва смотрим
--       живую запись с тем же ключом и возвращаем её id, а не begin/exception.
--   Р8. Утверждённое содержимое заметки (soap/parent_summary/raw_transcript/
--       source) защищает НОВЫЙ триггер lesson_notes_lock_approved_content,
--       а не только проверка в write_lesson_note: инвариант — констрейнт
--       или триггер (CLAUDE.md), проверка в функции не закрывает гонку двух
--       одновременных вызовов и не защищает от будущего прямого PATCH
--       администратора (0036 Р8 сознательно оставляет owner/admin такую
--       возможность для остальных колонок).
--   Р9. Полное закрытие CRUD по всем шести таблицам — включая archive_* для
--       diagnostics/goal_progress/homework/lesson_notes и archive_goal,
--       которых не было в первом проекте миграции. Без них ошибочная запись
--       не удаляется никак: deleted_at выставляет только RPC (docs:
--       soft-delete-needs-rpc), а прямой update закрыт вместе с остальными.
--  Р10. goal_stages и exercise_library НЕ получают RPC в этой миграции.
--       Экран /app/library, который писал бы в них, ещё не построен — а
--       значит и живого бага, аналогичного message_templates (0037), нет:
--       есть только тот же факт (exercise_library.center_id nullable),
--       записанный впрок. grant insert, update ... to authenticated на этих
--       двух таблицах остаётся из 0036 без изменений. Когда появится экран,
--       блокировку и RPC заводить тем же приёмом, что здесь.
--  Р11. Доставка пяти новых типов событий (diagnostic.created, goal.achieved,
--       homework.assigned, homework.submitted, lesson.note_approved) в эту
--       миграцию не входит: event_messages не знает про них, шаблонов в
--       message_templates нет. События пишутся в outbox уже сейчас —
--       откладывается именно ДОСТАВКА, не сам факт записи. Заведётся вместе
--       с остальной доставкой 7a/7b.
--  Р12. tests/0036_clinical_core.test.sql правится в этом PR (не миграция —
--       правка теста после мержа разрешена): прямой insert в
--       homework_exercises от владельца под authenticated был доказательством
--       Р7 в 0036, а теперь такой insert закрыт как и всё остальное — тест
--       переведён на update_homework, снятие assert не меняет.
-- =============================================================================


-- 0. Внутренний emit для триггеров статус-переходов ---------------------------------------------

-- Не emit_event: тот требует role_in(p_center_id) у auth.uid() текущей
-- сессии — верно для RPC, вызванной живым пользователем, но не для
-- триггера на goals/homework/lesson_notes, где строка может принадлежать
-- центру, отличному от клеймов, под которыми пишет фикстура/бэкфилл/service_role
-- (ровно так устроена фикстура 0036: центр Б заводится под клеймами
-- владельца центра А, потому что роль на время инициализации — postgres).
-- center_id строки уже гарантирован её FK на centers и тем, что запись вообще
-- состоялась — повторная проверка членства здесь избыточна и ломает не того,
-- кого нужно. Не для прямого вызова с клиента.
create or replace function public.emit_clinical_event(p_type text, p_payload jsonb, p_center_id uuid)
  returns bigint
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_id bigint;
begin
  if p_center_id is null then
    raise exception 'emit_clinical_event: не определён center_id' using errcode = '22004';
  end if;

  insert into public.events (center_id, type, payload)
  values (p_center_id, p_type, coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.emit_clinical_event(text, jsonb, uuid) is
  'emit_event без проверки членства вызывающего — для триггеров статус-перехода на goals/homework/lesson_notes. center_id строки уже проверен её FK; повторная проверка auth.uid() внутри триггера ловит фикстуру и бэкфилл, а не нарушителя.';

revoke all on function public.emit_clinical_event(text, jsonb, uuid) from public, anon, authenticated, service_role;


-- 1. Переиздание триггеров 0036 — те же функции плюс emit_clinical_event -----------------------

create or replace function public.goals_sync_achieved_at()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.status = 'achieved' then
    if tg_op = 'INSERT' or old.status is distinct from 'achieved' then
      new.achieved_at := now();
      perform public.emit_clinical_event('goal.achieved',
        jsonb_build_object('goal_id', new.id, 'student_id', new.student_id), new.center_id);
    else
      -- Уже была достигнута: присланную дату не принимаем.
      new.achieved_at := old.achieved_at;
    end if;
  else
    new.achieved_at := null;
  end if;

  return new;
end;
$$;

revoke all on function public.goals_sync_achieved_at() from public, anon, authenticated, service_role;


create or replace function public.homework_status_transition()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_rank constant jsonb := '{"assigned": 1, "submitted": 2, "reviewed": 3}'::jsonb;
begin
  if new.status is distinct from old.status
     and (v_rank ->> new.status)::int < (v_rank ->> old.status)::int then
    raise exception 'Нельзя вернуть задание из «%» в «%»', old.status, new.status
      using errcode = '23514';
  end if;

  if new.status = 'submitted' and old.status is distinct from 'submitted' then
    perform public.emit_clinical_event('homework.submitted',
      jsonb_build_object('homework_id', new.id, 'student_id', new.student_id), new.center_id);
  end if;

  return new;
end;
$$;

revoke all on function public.homework_status_transition() from public, anon, authenticated, service_role;


create or replace function public.lesson_notes_approval_transition()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.status = 'approved' and new.status <> 'approved' then
    raise exception 'Утверждённое резюме нельзя вернуть в черновик: родитель его уже видел'
      using errcode = '23514';
  end if;

  if new.status = 'approved' then
    if tg_op = 'INSERT' or old.status <> 'approved' then
      new.approved_at := now();
      new.approved_by := auth.uid();
      perform public.emit_clinical_event('lesson.note_approved',
        jsonb_build_object('lesson_note_id', new.id, 'student_id', new.student_id, 'lesson_id', new.lesson_id),
        new.center_id);
    else
      -- Уже было утверждено: метку и автора не переписывают.
      new.approved_at := old.approved_at;
      new.approved_by := old.approved_by;
    end if;
  else
    new.approved_at := null;
    new.approved_by := null;
  end if;

  return new;
end;
$$;

revoke all on function public.lesson_notes_approval_transition() from public, anon, authenticated, service_role;


-- 2. Утверждённое содержимое заметки неприкосновенно (Р8) --------------------------------------

create or replace function public.lesson_notes_lock_approved_content()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if old.status = 'approved' and (
       new.soap is distinct from old.soap
    or new.parent_summary is distinct from old.parent_summary
    or new.raw_transcript is distinct from old.raw_transcript
    or new.source is distinct from old.source
  ) then
    raise exception 'Утверждённую заметку нельзя изменить — заведите новую на следующем занятии'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function public.lesson_notes_lock_approved_content() from public, anon, authenticated, service_role;

drop trigger if exists lesson_notes_lock_approved_content on public.lesson_notes;
create trigger lesson_notes_lock_approved_content
  before update on public.lesson_notes
  for each row execute function public.lesson_notes_lock_approved_content();


-- 3. Диагностика --------------------------------------------------------------------------------

create or replace function public.record_diagnostic(
  p_student_id   uuid,
  p_conclusion   text default null,
  p_sounds       jsonb default '{}'::jsonb,
  p_speech_areas jsonb default '{}'::jsonb,
  p_date         date default null,
  p_teacher_id   uuid default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center     uuid := public.current_center();
  v_role       text := coalesce(public.my_role(), '');
  v_teacher_id uuid;
  v_id         uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.students s
     where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null
  ) then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  -- Р5: та же граница, что и раньше — clinical_teacher_sees не меняется.
  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(p_student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_role = 'teacher' then
    v_teacher_id := public.my_teacher_id();
  elsif p_teacher_id is not null then
    if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.center_id = v_center) then
      raise exception 'Специалист не найден' using errcode = '42704';
    end if;
    v_teacher_id := p_teacher_id;
  end if;

  insert into public.diagnostics (center_id, student_id, teacher_id, date, conclusion, sounds, speech_areas)
  values (v_center, p_student_id, v_teacher_id, coalesce(p_date, public.center_today(v_center)),
          p_conclusion, coalesce(p_sounds, '{}'::jsonb), coalesce(p_speech_areas, '{}'::jsonb))
  returning id into v_id;

  perform public.emit_event('diagnostic.created',
    jsonb_build_object('diagnostic_id', v_id, 'student_id', p_student_id), v_center);

  return v_id;
end;
$$;

revoke all on function public.record_diagnostic(uuid, text, jsonb, jsonb, date, uuid) from public, anon, authenticated, service_role;
grant execute on function public.record_diagnostic(uuid, text, jsonb, jsonb, date, uuid) to authenticated;


create or replace function public.update_diagnostic(
  p_id           uuid,
  p_conclusion   text default null,
  p_sounds       jsonb default null,
  p_speech_areas jsonb default null,
  p_date         date default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.diagnostics;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.diagnostics
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Запись не найдена' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or v_row.created_by = auth.uid()) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.diagnostics
     set conclusion   = coalesce(p_conclusion, conclusion),
         sounds       = coalesce(p_sounds, sounds),
         speech_areas = coalesce(p_speech_areas, speech_areas),
         date         = coalesce(p_date, date)
   where id = p_id;
end;
$$;

revoke all on function public.update_diagnostic(uuid, text, jsonb, jsonb, date) from public, anon, authenticated, service_role;
grant execute on function public.update_diagnostic(uuid, text, jsonb, jsonb, date) to authenticated;


create or replace function public.archive_diagnostic(p_id uuid)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.diagnostics set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  return found;
end;
$$;

revoke all on function public.archive_diagnostic(uuid) from public, anon, authenticated, service_role;
grant execute on function public.archive_diagnostic(uuid) to authenticated;


-- 4. Цели -----------------------------------------------------------------------------------

create or replace function public.create_goal(
  p_student_id  uuid,
  p_stage_id    uuid,
  p_title       text,
  p_area        text default null,
  p_sound       text default null,
  p_target_date date default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_id     uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.students s
     where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null
  ) then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(p_student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.goal_stages gs
     where gs.id = p_stage_id and gs.center_id = v_center and gs.deleted_at is null
  ) then
    raise exception 'Этап не найден' using errcode = '42704';
  end if;

  insert into public.goals (center_id, student_id, stage_id, title, area, sound, target_date)
  values (v_center, p_student_id, p_stage_id, p_title, p_area, p_sound, p_target_date)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.create_goal(uuid, uuid, text, text, text, date) from public, anon, authenticated, service_role;
grant execute on function public.create_goal(uuid, uuid, text, text, text, date) to authenticated;


-- Р3: без status — форма и кнопка «Достигнута» не одна ручка.
create or replace function public.update_goal(
  p_id          uuid,
  p_title       text default null,
  p_area        text default null,
  p_sound       text default null,
  p_stage_id    uuid default null,
  p_target_date date default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.goals;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.goals
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Цель не найдена' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or v_row.created_by = auth.uid()) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_stage_id is not null and not exists (
    select 1 from public.goal_stages gs
     where gs.id = p_stage_id and gs.center_id = v_center and gs.deleted_at is null
  ) then
    raise exception 'Этап не найден' using errcode = '42704';
  end if;

  update public.goals
     set title       = coalesce(p_title, title),
         area        = coalesce(p_area, area),
         sound       = coalesce(p_sound, sound),
         stage_id    = coalesce(p_stage_id, stage_id),
         target_date = coalesce(p_target_date, target_date)
   where id = p_id;
end;
$$;

revoke all on function public.update_goal(uuid, text, text, text, uuid, date) from public, anon, authenticated, service_role;
grant execute on function public.update_goal(uuid, text, text, text, uuid, date) to authenticated;


create or replace function public.set_goal_status(p_id uuid, p_status text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.goals;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  if p_status not in ('active', 'achieved', 'paused') then
    raise exception 'Неизвестный статус цели' using errcode = '23514';
  end if;

  select * into v_row from public.goals
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Цель не найдена' using errcode = '42704';
  end if;

  -- Смена статуса — командное действие по видимости, а не правка чужой
  -- заметки (Р2): любой специалист, ведущий ребёнка сейчас, отмечает
  -- достижение, даже если цель завёл другой.
  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(v_row.student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.goals set status = p_status where id = p_id;
end;
$$;

revoke all on function public.set_goal_status(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.set_goal_status(uuid, text) to authenticated;


create or replace function public.archive_goal(p_id uuid)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.goals set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  return found;
end;
$$;

revoke all on function public.archive_goal(uuid) from public, anon, authenticated, service_role;
grant execute on function public.archive_goal(uuid) to authenticated;


-- 5. Прогресс по цели ------------------------------------------------------------------------

create or replace function public.record_goal_progress(
  p_goal_id     uuid,
  p_score       integer,
  p_note        text default null,
  p_lesson_id   uuid default null,
  p_date        date default null,
  p_conduct_key uuid default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_goal   public.goals;
  v_id     uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_goal from public.goals
   where id = p_goal_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Цель не найдена' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(v_goal.student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_conduct_key is not null then
    select id into v_id from public.goal_progress
     where goal_id = p_goal_id and conduct_key = p_conduct_key and deleted_at is null;
    if found then
      return v_id;
    end if;
  end if;

  insert into public.goal_progress (center_id, goal_id, lesson_id, date, score, note, conduct_key)
  values (v_center, p_goal_id, p_lesson_id, coalesce(p_date, public.center_today(v_center)),
          p_score, p_note, p_conduct_key)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.record_goal_progress(uuid, integer, text, uuid, date, uuid) from public, anon, authenticated, service_role;
grant execute on function public.record_goal_progress(uuid, integer, text, uuid, date, uuid) to authenticated;


create or replace function public.update_goal_progress(p_id uuid, p_score integer default null, p_note text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.goal_progress;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.goal_progress
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Запись не найдена' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or v_row.created_by = auth.uid()) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.goal_progress
     set score = coalesce(p_score, score),
         note  = coalesce(p_note, note)
   where id = p_id;
end;
$$;

revoke all on function public.update_goal_progress(uuid, integer, text) from public, anon, authenticated, service_role;
grant execute on function public.update_goal_progress(uuid, integer, text) to authenticated;


create or replace function public.archive_goal_progress(p_id uuid)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.goal_progress;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.goal_progress
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    return false;
  end if;

  if not (v_role in ('owner', 'admin') or v_row.created_by = auth.uid()) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.goal_progress set deleted_at = now() where id = p_id;
  return true;
end;
$$;

revoke all on function public.archive_goal_progress(uuid) from public, anon, authenticated, service_role;
grant execute on function public.archive_goal_progress(uuid) to authenticated;


-- 6. Домашнее задание -------------------------------------------------------------------------

create or replace function public.assign_homework(
  p_student_id   uuid,
  p_free_text    text default null,
  p_exercise_ids uuid[] default '{}'::uuid[],
  p_lesson_id    uuid default null,
  p_due_on       date default null,
  p_conduct_key  uuid default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_id     uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.students s
     where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null
  ) then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(p_student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_conduct_key is not null then
    select id into v_id from public.homework
     where student_id = p_student_id and conduct_key = p_conduct_key and deleted_at is null;
    if found then
      return v_id;
    end if;
  end if;

  insert into public.homework (center_id, student_id, lesson_id, due_on, free_text, conduct_key)
  values (v_center, p_student_id, p_lesson_id, p_due_on, p_free_text, p_conduct_key)
  returning id into v_id;

  -- Р7: дедуп по exercise_id, порядок — по первому вхождению; вся вставка
  -- атомарна — чужой центру exercise_id где угодно в списке откатывает всё.
  if coalesce(array_length(p_exercise_ids, 1), 0) > 0 then
    with items as (
      select exercise_id, min(ord) as sort
        from unnest(p_exercise_ids) with ordinality as u(exercise_id, ord)
       group by exercise_id
    )
    insert into public.homework_exercises (homework_id, exercise_id, center_id, sort)
    select v_id, exercise_id, v_center, sort from items order by sort;
  end if;

  perform public.emit_event('homework.assigned',
    jsonb_build_object('homework_id', v_id, 'student_id', p_student_id), v_center);

  return v_id;
end;
$$;

revoke all on function public.assign_homework(uuid, text, uuid[], uuid, date, uuid) from public, anon, authenticated, service_role;
grant execute on function public.assign_homework(uuid, text, uuid[], uuid, date, uuid) to authenticated;


-- Р2: право — «видит ребёнка», а не «сам выдал» (асимметрия с
-- update_diagnostic/update_goal — намеренная, см. заголовок).
create or replace function public.update_homework(
  p_id           uuid,
  p_due_on       date default null,
  p_free_text    text default null,
  p_exercise_ids uuid[] default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.homework;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.homework
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Задание не найдено' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(v_row.student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_row.status <> 'assigned' then
    raise exception 'Задание уже увидел родитель — состав больше не меняется' using errcode = '23514';
  end if;

  update public.homework
     set due_on    = coalesce(p_due_on, due_on),
         free_text = coalesce(p_free_text, free_text)
   where id = p_id;

  if p_exercise_ids is not null then
    update public.homework_exercises set deleted_at = now()
     where homework_id = p_id and deleted_at is null;

    if coalesce(array_length(p_exercise_ids, 1), 0) > 0 then
      with items as (
        select exercise_id, min(ord) as sort
          from unnest(p_exercise_ids) with ordinality as u(exercise_id, ord)
         group by exercise_id
      )
      insert into public.homework_exercises (homework_id, exercise_id, center_id, sort)
      select p_id, exercise_id, v_center, sort from items order by sort;
    end if;
  end if;
end;
$$;

revoke all on function public.update_homework(uuid, date, text, uuid[]) from public, anon, authenticated, service_role;
grant execute on function public.update_homework(uuid, date, text, uuid[]) to authenticated;


create or replace function public.submit_homework(p_id uuid, p_parent_note text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.homework;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.homework
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Задание не найдено' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or (v_role = 'parent' and public.parent_of_student(v_row.student_id))) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_row.status <> 'assigned' then
    raise exception 'Задание уже отправлено или проверено' using errcode = '23514';
  end if;

  update public.homework
     set status = 'submitted', parent_note = coalesce(p_parent_note, parent_note)
   where id = p_id;
end;
$$;

revoke all on function public.submit_homework(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.submit_homework(uuid, text) to authenticated;


create or replace function public.review_homework(p_id uuid, p_teacher_feedback text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.homework;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.homework
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Задание не найдено' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(v_row.student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_row.status <> 'submitted' then
    raise exception 'Задание ещё не сдано' using errcode = '23514';
  end if;

  update public.homework
     set status = 'reviewed', teacher_feedback = coalesce(p_teacher_feedback, teacher_feedback)
   where id = p_id;
end;
$$;

revoke all on function public.review_homework(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.review_homework(uuid, text) to authenticated;


create or replace function public.archive_homework(p_id uuid)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.homework set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  return found;
end;
$$;

revoke all on function public.archive_homework(uuid) from public, anon, authenticated, service_role;
grant execute on function public.archive_homework(uuid) to authenticated;


-- 7. Заметка занятия --------------------------------------------------------------------------

-- Одна функция на создание и правку черновика: карточка занятия не знает
-- заранее, есть ли уже заметка по (lesson_id, student_id) — так же, как
-- upsert_message_template (0037) для той же формы «одна строка на ключ».
create or replace function public.write_lesson_note(
  p_lesson_id      uuid,
  p_student_id     uuid,
  p_soap           jsonb default null,
  p_parent_summary text default null,
  p_teacher_id     uuid default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center     uuid := public.current_center();
  v_role       text := coalesce(public.my_role(), '');
  v_teacher_id uuid;
  v_row        public.lesson_notes;
  v_id         uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.lesson_notes
   where lesson_id = p_lesson_id and student_id = p_student_id
     and center_id = v_center and deleted_at is null;

  if found then
    -- Второй рубеж — триггер lesson_notes_lock_approved_content; эта
    -- проверка только даёт понятное сообщение до похода в базу.
    if v_row.status = 'approved' then
      raise exception 'Утверждённую заметку нельзя изменить — заведите новую на следующем занятии'
        using errcode = '23514';
    end if;

    if not (v_role in ('owner', 'admin') or v_row.created_by = auth.uid()) then
      raise exception 'Недостаточно прав' using errcode = '42501';
    end if;

    update public.lesson_notes
       set soap           = coalesce(p_soap, soap),
           parent_summary = coalesce(p_parent_summary, parent_summary)
     where id = v_row.id;

    return v_row.id;
  end if;

  if not exists (
    select 1 from public.students s
     where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null
  ) then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(p_student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_role = 'teacher' then
    v_teacher_id := public.my_teacher_id();
  elsif p_teacher_id is not null then
    if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.center_id = v_center) then
      raise exception 'Специалист не найден' using errcode = '42704';
    end if;
    v_teacher_id := p_teacher_id;
  end if;

  -- Состав занятия (lesson_id ↔ student_id) проверяет существующий
  -- clinical_check_lesson_participant на самой таблице — не дублируется.
  insert into public.lesson_notes (center_id, lesson_id, student_id, teacher_id, soap, parent_summary)
  values (v_center, p_lesson_id, p_student_id, v_teacher_id, coalesce(p_soap, '{}'::jsonb), p_parent_summary)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.write_lesson_note(uuid, uuid, jsonb, text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.write_lesson_note(uuid, uuid, jsonb, text, uuid) to authenticated;


create or replace function public.approve_lesson_note(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.lesson_notes;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.lesson_notes
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Заметка не найдена' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or v_row.created_by = auth.uid()) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Повторное утверждение — не ошибка, а холостой ход: кнопка «Утвердить»,
  -- нажатая дважды подряд (двойной клик, повтор запроса), не должна падать.
  if v_row.status = 'approved' then
    return;
  end if;

  update public.lesson_notes set status = 'approved' where id = p_id;
end;
$$;

revoke all on function public.approve_lesson_note(uuid) from public, anon, authenticated, service_role;
grant execute on function public.approve_lesson_note(uuid) to authenticated;


create or replace function public.archive_lesson_note(p_id uuid)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.lesson_notes set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  return found;
end;
$$;

revoke all on function public.archive_lesson_note(uuid) from public, anon, authenticated, service_role;
grant execute on function public.archive_lesson_note(uuid) to authenticated;


-- 8. Прямая запись закрыта (Р9, Р10) ------------------------------------------------------------

-- select остаётся: политики видимости 0036 не меняются, меняется только
-- то, что INSERT/UPDATE идут через RPC выше, а не PostgREST напрямую.
revoke insert, update on public.diagnostics        from authenticated;
revoke insert, update on public.goals              from authenticated;
revoke insert, update on public.goal_progress      from authenticated;
revoke insert, update on public.homework           from authenticated;
revoke insert, update on public.homework_exercises from authenticated;
revoke insert, update on public.lesson_notes       from authenticated;
