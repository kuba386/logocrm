-- =============================================================================
-- 0011_role_guards.sql — coalesce в проверке роли для RPC этапов 0–3
--
-- `NULL not in ('owner', 'admin')` — это NULL, и `if NULL` не срабатывает:
-- пользователь с валидным JWT и уже отозванным членством проходил проверку.
-- 0010 закрыла это в шести RPC этапа 4 и четырёх ЧИТАЮЩИХ функциях этапов
-- 0–3 — тех, что не пишут событий. Оставшиеся девять держал второй рубеж:
-- каждая заканчивается emit_event, а тот с 0002 требует role_in(center)
-- is not null и откатывает транзакцию. Дыры в данных не было — был чужой
-- текст ошибки («Нет доступа к центру» вместо «Недостаточно прав») и работа,
-- выполненная до отката. Здесь проверка ставится на место — первой строкой.
--
-- Тела взяты из последней определяющей миграции каждой функции; меняется
-- ровно одна строка. Гранты повторяются явно: правило проекта.
-- =============================================================================

-- из 0005_students.sql
create or replace function public.archive_student(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.students
     set status = 'archived'
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  perform public.emit_event('student.archived',
    jsonb_build_object('center_id', v_center, 'student_id', p_id), v_center);
end;
$$;

-- из 0005_students.sql
create or replace function public.restore_student(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.students
     set status = 'active'
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  perform public.emit_event('student.restored',
    jsonb_build_object('center_id', v_center, 'student_id', p_id), v_center);
end;
$$;

-- из 0005_students.sql
create or replace function public.create_student_with_payer(
  p_full_name          text,
  p_payer_id           uuid    default null,
  p_payer_full_name    text    default null,
  p_payer_phone        text    default null,
  p_payer_relation     text    default null,
  p_birth_date         date    default null,
  p_gender             text    default null,
  p_primary_teacher_id uuid    default null,
  p_source             text    default null,
  p_notes              text    default null
)
  returns table (student_id uuid, payer_id uuid)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_payer   uuid := p_payer_id;
  v_student uuid;
  v_norm    text;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if coalesce(trim(p_full_name), '') = '' then
    raise exception 'Укажите ФИО ребёнка' using errcode = '22004';
  end if;

  if v_payer is null then
    v_norm := public.normalize_kg_phone(p_payer_phone);

    if v_norm is null then
      raise exception 'Некорректный номер телефона плательщика' using errcode = '22023';
    end if;

    if coalesce(trim(p_payer_full_name), '') = '' then
      raise exception 'Укажите ФИО плательщика' using errcode = '22004';
    end if;

    -- Если такой номер уже есть — не создаём дубль, а привязываемся.
    select p.id into v_payer
      from public.payers p
     where p.center_id = v_center
       and p.deleted_at is null
       and public.normalize_kg_phone(p.phone) = v_norm;

    if v_payer is null then
      insert into public.payers (center_id, full_name, phone, relation)
      values (v_center, trim(p_payer_full_name), v_norm, p_payer_relation)
      returning id into v_payer;

      perform public.emit_event('payer.created',
        jsonb_build_object('center_id', v_center, 'payer_id', v_payer,
                           'full_name', trim(p_payer_full_name)), v_center);
    end if;
  else
    if not exists (
      select 1 from public.payers p
       where p.id = v_payer and p.center_id = v_center and p.deleted_at is null
    ) then
      raise exception 'Плательщик не найден в этом центре' using errcode = '42704';
    end if;
  end if;

  if p_primary_teacher_id is not null and not exists (
    select 1 from public.teachers t
     where t.id = p_primary_teacher_id and t.center_id = v_center and t.deleted_at is null
  ) then
    raise exception 'Специалист не найден в этом центре' using errcode = '42704';
  end if;

  insert into public.students (
    center_id, full_name, birth_date, gender, payer_id,
    primary_teacher_id, source, notes, started_at
  )
  values (
    v_center, trim(p_full_name), p_birth_date, p_gender, v_payer,
    p_primary_teacher_id, p_source, p_notes, current_date
  )
  returning id into v_student;

  perform public.emit_event('student.created',
    jsonb_build_object('center_id', v_center, 'student_id', v_student,
                       'payer_id', v_payer, 'primary_teacher_id', p_primary_teacher_id),
    v_center);

  return query select v_student, v_payer;
end;
$$;

-- из 0006_schedule.sql
create or replace function public.create_lesson_series(p jsonb)
  returns table (lesson_id uuid, starts_at timestamptz)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid := public.current_center();
  v_series   uuid := gen_random_uuid();
  v_group    uuid := nullif(p ->> 'group_id', '')::uuid;
  v_student  uuid := nullif(p ->> 'student_id', '')::uuid;
  v_teacher  uuid := (p ->> 'teacher_id')::uuid;
  v_room     uuid := nullif(p ->> 'room_id', '')::uuid;
  v_problems jsonb := '[]'::jsonb;
  v_late     jsonb;
  v_row      record;
  v_id       uuid;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if (v_group is null) = (v_student is null) then
    raise exception 'Укажите либо группу, либо ученика' using errcode = '22023';
  end if;

  if v_teacher is null then
    raise exception 'Укажите специалиста' using errcode = '22004';
  end if;

  -- Сначала вся картина целиком.
  for v_row in select * from public.create_lesson_series_preview(p) loop
    if jsonb_array_length(v_row.conflicts) > 0 then
      v_problems := v_problems || jsonb_build_object(
        'day', v_row.day, 'starts_at', v_row.starts_at, 'conflicts', v_row.conflicts);
    end if;
  end loop;

  -- Серия против самой себя: одинаковые дни недели, пересекающиеся слоты
  -- внутри одного вызова. Сейчас на день приходится одно занятие, но правило
  -- должно пережить появление нескольких занятий в день — проверяем явно.
  if exists (
    select 1
      from public.series_dates(p) a
      join public.series_dates(p) b
        on a.day < b.day
       and tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at)
  ) then
    raise exception 'Занятия внутри самой серии пересекаются' using errcode = '23P01';
  end if;

  if jsonb_array_length(v_problems) > 0 then
    raise exception 'Часть занятий пересекается с существующими — серия не создана'
      using errcode = '23P01', detail = v_problems::text;
  end if;

  for v_row in select * from public.series_dates(p) loop
    begin
      insert into public.lessons (
        center_id, service_id, teacher_id, room_id, group_id, student_id,
        starts_at, ends_at, series_id, notes
      )
      values (
        v_center, nullif(p ->> 'service_id', '')::uuid, v_teacher, v_room,
        v_group, v_student, v_row.starts_at, v_row.ends_at, v_series, nullif(p ->> 'notes', '')
      )
      returning id into v_id;

    exception when exclusion_violation then
      -- Слот заняли между предпросмотром и вставкой. Констрейнт защитил
      -- данные, но клиенту нужен тот же формат ошибки, что и на обычном
      -- пути — иначе он не сможет показать, что именно случилось.
      v_late := public.lesson_slot_conflicts(
        v_center, v_teacher, v_room, v_group, v_student,
        v_row.starts_at, v_row.ends_at);

      if jsonb_array_length(v_late) = 0 then
        -- Конкурент успел откатиться, пока мы пересчитывали. Показать нечего,
        -- и повторять за админа не надо: пусть нажмёт сам, увидев актуальный
        -- предпросмотр. Автоповтор внутри функции опаснее лишнего клика.
        raise exception 'Слот был занят на момент сохранения, попробуйте ещё раз'
          using errcode = '23P01';
      end if;

      raise exception 'Слот заняли, пока заполнялась форма — серия не создана'
        using errcode = '23P01',
              detail = jsonb_build_array(jsonb_build_object(
                'day', v_row.day,
                'starts_at', v_row.starts_at,
                'conflicts', v_late
              ))::text;
    end;

    perform public.emit_event('lesson.created',
      jsonb_build_object('center_id', v_center, 'lesson_id', v_id,
                         'series_id', v_series, 'starts_at', v_row.starts_at), v_center);

    lesson_id := v_id;
    starts_at := v_row.starts_at;
    return next;
  end loop;
end;
$$;

-- из 0006_schedule.sql
create or replace function public.cancel_lesson(p_id uuid, p_reason text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.lessons
     set status = 'cancelled', cancel_reason = p_reason
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;

  perform public.emit_event('lesson.cancelled',
    jsonb_build_object('center_id', v_center, 'lesson_id', p_id, 'reason', p_reason), v_center);
end;
$$;

-- из 0006_schedule.sql
create or replace function public.cancel_series_from(
  p_series_id uuid, p_from date, p_reason text default null
)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_count  int;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  with cancelled as (
    update public.lessons
       set status = 'cancelled', cancel_reason = p_reason
     where series_id = p_series_id and center_id = v_center and deleted_at is null
       and status = 'planned' and starts_at >= p_from::timestamptz
    returning id
  )
  select count(*) into v_count from cancelled;

  perform public.emit_event('lesson.cancelled',
    jsonb_build_object('center_id', v_center, 'series_id', p_series_id,
                       'from', p_from, 'reason', p_reason, 'count', v_count), v_center);
  return v_count;
end;
$$;

-- из 0006_schedule.sql
create or replace function public.substitute_teacher(p_lesson_id uuid, p_new_teacher_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.teachers t
     where t.id = p_new_teacher_id and t.center_id = v_center and t.deleted_at is null
  ) then
    raise exception 'Специалист не найден в этом центре' using errcode = '42704';
  end if;

  -- Занятость нового специалиста ловит EXCLUDE по effective_teacher_id.
  update public.lessons
     set substitute_teacher_id = p_new_teacher_id
   where id = p_lesson_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;

  perform public.emit_event('lesson.substituted',
    jsonb_build_object('center_id', v_center, 'lesson_id', p_lesson_id,
                       'teacher_id', p_new_teacher_id), v_center);
end;
$$;

-- из 0006_schedule.sql
create or replace function public.teacher_vacation(
  p_teacher_id uuid, p_from date, p_to date
)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_count  int;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_to < p_from then
    raise exception 'Дата окончания раньше даты начала' using errcode = '22023';
  end if;

  with cancelled as (
    update public.lessons
       set status = 'cancelled', cancel_reason = 'vacation'
     where center_id = v_center and deleted_at is null and status = 'planned'
       and starts_at >= p_from::timestamptz and starts_at < (p_to + 1)::timestamptz
       -- И там, где он ведёт, и там, где подменяет: иначе отпускник
       -- остаётся стоять в замене.
       and (teacher_id = p_teacher_id or substitute_teacher_id = p_teacher_id)
    returning id
  )
  select count(*) into v_count from cancelled;

  perform public.emit_event('teacher.vacation',
    jsonb_build_object('center_id', v_center, 'teacher_id', p_teacher_id,
                       'from', p_from, 'to', p_to, 'cancelled', v_count), v_center);
  return v_count;
end;
$$;

-- из 0006_schedule.sql
create or replace function public.reschedule_lesson(
  p_lesson_id uuid,
  p_starts_at timestamptz,
  p_ends_at   timestamptz
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_lesson    public.lessons;
  v_conflicts jsonb;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_ends_at <= p_starts_at then
    raise exception 'Занятие должно заканчиваться позже, чем начинается' using errcode = '22023';
  end if;

  select * into v_lesson
    from public.lessons
   where id = p_lesson_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;

  if v_lesson.status <> 'planned' then
    raise exception 'Перенести можно только запланированное занятие' using errcode = '22023';
  end if;

  -- Само занятие из проверки исключаем, иначе оно конфликтует с собой.
  v_conflicts := public.lesson_slot_conflicts(
    v_center, v_lesson.effective_teacher_id, v_lesson.room_id,
    v_lesson.group_id, v_lesson.student_id, p_starts_at, p_ends_at, p_lesson_id);

  if jsonb_array_length(v_conflicts) > 0 then
    raise exception 'Новое время пересекается с другими занятиями'
      using errcode = '23P01',
            detail = jsonb_build_array(jsonb_build_object(
              'day', p_starts_at::date, 'starts_at', p_starts_at, 'conflicts', v_conflicts))::text;
  end if;

  begin
    update public.lessons
       set starts_at = p_starts_at, ends_at = p_ends_at
     where id = p_lesson_id;
  exception when exclusion_violation then
    v_conflicts := public.lesson_slot_conflicts(
      v_center, v_lesson.effective_teacher_id, v_lesson.room_id,
      v_lesson.group_id, v_lesson.student_id, p_starts_at, p_ends_at, p_lesson_id);

    if jsonb_array_length(v_conflicts) = 0 then
      raise exception 'Слот был занят на момент сохранения, попробуйте ещё раз'
        using errcode = '23P01';
    end if;

    raise exception 'Новое время пересекается с другими занятиями'
      using errcode = '23P01',
            detail = jsonb_build_array(jsonb_build_object(
              'day', p_starts_at::date, 'starts_at', p_starts_at, 'conflicts', v_conflicts))::text;
  end;

  perform public.emit_event('lesson.rescheduled',
    jsonb_build_object('center_id', v_center, 'lesson_id', p_lesson_id,
                       'from', v_lesson.starts_at, 'to', p_starts_at), v_center);
end;
$$;


-- Права ---------------------------------------------------------------------------

revoke execute on function
  public.archive_student(uuid),
  public.restore_student(uuid),
  public.create_student_with_payer(text, uuid, text, text, text, date, text, uuid, text, text),
  public.create_lesson_series(jsonb),
  public.cancel_lesson(uuid, text),
  public.cancel_series_from(uuid, date, text),
  public.substitute_teacher(uuid, uuid),
  public.teacher_vacation(uuid, date, date),
  public.reschedule_lesson(uuid, timestamptz, timestamptz)
  from public, anon;

grant execute on function
  public.archive_student(uuid),
  public.restore_student(uuid),
  public.create_student_with_payer(text, uuid, text, text, text, date, text, uuid, text, text),
  public.create_lesson_series(jsonb),
  public.cancel_lesson(uuid, text),
  public.cancel_series_from(uuid, date, text),
  public.substitute_teacher(uuid, uuid),
  public.teacher_vacation(uuid, date, date),
  public.reschedule_lesson(uuid, timestamptz, timestamptz)
  to authenticated;
