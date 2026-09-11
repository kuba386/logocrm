-- =============================================================================
-- 0026_roles_registrar_rpc.sql — роли registrar/finance, шаг 1 из 3: чеки,
-- предикаты, RPC стойки и платежей (этап 5, «Доработка» п.1)
--
-- Порядок трёх миграций инвертирован по ревью плана: сначала функции (0026,
-- 0027), потом (0028) политики и лестница назначений. Здесь чек-констрейнты
-- уже расширены, но назначить новую роль пока нельзя — change_member_role и
-- create_invitation остаются с прежними списками; строка с registrar в
-- memberships появляется только из pgTAP от postgres. Промежуточное
-- состояние: у роли есть RPC на запись, но нет ни одной политики на чтение и
-- нет пути назначения — до 0028 такой пользователь не существует.
--
-- Решения:
--   Р1. Три предиката вместо литералов ('owner','admin') в каждом гейте:
--       can_front_desk (owner/admin/registrar), can_finance
--       (owner/admin/finance), can_payments (все четыре). Обёртка и
--       внутренняя функция иначе разъезжаются молча — так
--       installment_plans_cancel_live заблокировала бы cancel_installment_plan
--       и refund_subscription у обеих ролей после расширения обёрток.
--       Предикаты — security invoker: role_in уже definer с грантом
--       authenticated, второй definer-слой не нужен; auth.uid() null →
--       role_in null → false, NULL-дыры «not in» нет.
--   Р2. Тело каждой функции — копия последнего определения (файл указан в
--       заголовке каждой; сверено grep'ом по всем миграциям, не по памяти —
--       mark_attendance, например, живёт в 0010, не в 0009), меняется
--       только строка гейта. Гранты повторены явно.
--   Р3. mark_lesson_status: NULL-роль (`elsif v_role not in (...)` при NULL
--       не срабатывает) закрыта параллельно в 0025 (#49) через coalesce; здесь
--       тело берётся из 0025, гейт — предикат, и это последнее определение:
--       0026 > 0025 в порядке применения, registrar не потеряет закрытие
--       занятия.
--   Р6. Инвокерные калькуляторы — refund_calc, subscription_lessons_left,
--       subscription_state (через subscription_visible_to_caller — та definer,
--       но вью student_balance и installments_view — invoker) — для
--       registrar/finance до 0028 отдают NULL/пусто: RLS базовых таблиц их
--       ещё не пускает. Прикладной путь к остатку и сумме возврата для новых
--       ролей — только subscription_summary (definer, can_payments):
--       refund_subscription(p_expected := subscription_summary(...).refund_tiyin).
--       Иначе повторяется двусмысленный NULL из student_balance: «безлимит»
--       и «не моя роль» неразличимы.
--   Р7. refund_subscription — can_front_desk, не can_payments: это не платёж,
--       а списание остатка и отмена абонемента; роль, которой запрещено
--       продать, заморозить и перенести абонемент, не должна его гасить.
--       Бухгалтер проводит платёж возврата через record_payment(kind =
--       'refund'). cancel_installment_plan остаётся can_payments: рассрочка —
--       график платежей, не абонемент.
--   Р4. subscription_visible_to_caller: семантика «роль в текущем центре И
--       абонемент этого центра» сохранена дословно (can_payments() без
--       аргумента + сравнение center_id), не заменена на role_in(центра
--       абонемента) — иначе admin центра X, переключённый в Y, видел бы
--       абонементы X с экрана Y.
--   Р5. payer_display_name получает can_payments: бухгалтеру ФИО
--       плательщика в платежах нужно так же, как стойке.
-- =============================================================================


-- 1. Чек-констрейнты ролей ------------------------------------------------------

alter table public.memberships drop constraint if exists memberships_role_check;
alter table public.memberships add constraint memberships_role_check
  check (role in ('owner', 'admin', 'teacher', 'parent', 'registrar', 'finance'));

alter table public.invitations drop constraint if exists invitations_role_check;
alter table public.invitations add constraint invitations_role_check
  check (role in ('admin', 'teacher', 'parent', 'registrar', 'finance'));


-- 2. Предикаты ролей ------------------------------------------------------------------

create or replace function public.can_front_desk(p_center_id uuid default public.current_center())
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(public.role_in(p_center_id), '') in ('owner', 'admin', 'registrar');
$$;

create or replace function public.can_finance(p_center_id uuid default public.current_center())
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(public.role_in(p_center_id), '') in ('owner', 'admin', 'finance');
$$;

create or replace function public.can_payments(p_center_id uuid default public.current_center())
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(public.role_in(p_center_id), '') in ('owner', 'admin', 'registrar', 'finance');
$$;

comment on function public.can_front_desk(uuid) is 'Стойка: ученики, плательщики, расписание, посещения, абонементы — owner/admin/registrar.';
comment on function public.can_finance(uuid)    is 'Деньги сотрудников: расходы, ставки, зарплаты, периоды — owner/admin/finance.';
comment on function public.can_payments(uuid)   is 'Платежи и рассрочки клиентов — обе новые роли вместе с owner/admin.';

revoke execute on function
  public.can_front_desk(uuid), public.can_finance(uuid), public.can_payments(uuid)
  from public, anon;
grant execute on function
  public.can_front_desk(uuid), public.can_finance(uuid), public.can_payments(uuid)
  to authenticated;


-- 3. Ученики и плательщики (can_front_desk) --------------------------------------------

-- из 0011_role_guards.sql
create or replace function public.archive_student(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if not public.can_front_desk() then
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

-- из 0011_role_guards.sql
create or replace function public.restore_student(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if not public.can_front_desk() then
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

-- из 0011_role_guards.sql
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
  if not public.can_front_desk() then
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

-- из 0010_stage4_hardening.sql
create or replace function public.find_payer_by_phone(p_phone text)
  returns table (id uuid, full_name text, phone text, relation text, children_count integer)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_norm   text := public.normalize_kg_phone(p_phone);
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_norm is null then
    return;
  end if;

  return query
    select p.id, p.full_name, p.phone, p.relation,
           (select count(*) from public.students s
             where s.payer_id = p.id and s.deleted_at is null)::int
      from public.payers p
     where p.center_id = v_center
       and p.deleted_at is null
       and public.normalize_kg_phone(p.phone) = v_norm;
end;
$$;

-- из 0005_students.sql (Р5: ветка owner/admin → can_payments)
create or replace function public.payer_display_name(p_payer_id uuid)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_role text := public.my_role();
  v_name text;
begin
  if public.can_payments() then
    select p.full_name into v_name
      from public.payers p
     where p.id = p_payer_id
       and p.center_id = public.current_center()
       and p.deleted_at is null;

  elsif v_role = 'teacher' then
    -- Только плательщики собственных учеников.
    select p.full_name into v_name
      from public.payers p
     where p.id = p_payer_id
       and p.center_id = public.current_center()
       and p.deleted_at is null
       and exists (
         select 1 from public.students s
          where s.payer_id = p.id
            and s.primary_teacher_id = public.my_teacher_id()
            and s.deleted_at is null
       );

  elsif v_role = 'parent' then
    select p.full_name into v_name
      from public.payers p
     where p.id = p_payer_id
       and p.id = public.my_payer_id()
       and p.deleted_at is null;
  end if;

  return v_name;
end;
$$;


-- 4. Расписание (can_front_desk) --------------------------------------------------------

-- из 0010_stage4_hardening.sql
create or replace function public.create_lesson_series_preview(p jsonb)
  returns table (day date, starts_at timestamptz, ends_at timestamptz, conflicts jsonb)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return query
    select d.day, d.starts_at, d.ends_at,
           public.lesson_slot_conflicts(
             v_center,
             (p ->> 'teacher_id')::uuid,
             nullif(p ->> 'room_id', '')::uuid,
             nullif(p ->> 'group_id', '')::uuid,
             nullif(p ->> 'student_id', '')::uuid,
             d.starts_at, d.ends_at)
      from public.series_dates(p) d;
end;
$$;

-- из 0010_stage4_hardening.sql
create or replace function public.lesson_slot_conflicts(
  p_center     uuid,
  p_teacher    uuid,
  p_room       uuid,
  p_group      uuid,
  p_student    uuid,
  p_starts     timestamptz,
  p_ends       timestamptz,
  p_exclude_id uuid default null
)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_conflicts jsonb := '[]'::jsonb;
  v_row       record;
begin
  -- Функция отдаёт имена чужих учеников и то, чем занят слот. Гранта у
  -- authenticated нет, но проверку дублируем внутри: иначе один неосторожный
  -- grant в будущей миграции откроет специалисту всё расписание центра.
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Специалист (с учётом замены).
  for v_row in
    select l.id, l.starts_at, l.ends_at
      from public.lessons l
     where l.center_id = p_center
       and l.deleted_at is null
       and l.status <> 'cancelled'
       and l.id is distinct from p_exclude_id
       and l.effective_teacher_id = p_teacher
       and tstzrange(l.starts_at, l.ends_at) && tstzrange(p_starts, p_ends)
  loop
    v_conflicts := v_conflicts || jsonb_build_object(
      'kind', 'teacher', 'lesson_id', v_row.id,
      'starts_at', v_row.starts_at, 'ends_at', v_row.ends_at);
  end loop;

  -- Кабинет.
  if p_room is not null then
    for v_row in
      select l.id, l.starts_at, l.ends_at
        from public.lessons l
       where l.center_id = p_center
         and l.deleted_at is null
         and l.status <> 'cancelled'
         and l.id is distinct from p_exclude_id
         and l.room_id = p_room
         and tstzrange(l.starts_at, l.ends_at) && tstzrange(p_starts, p_ends)
    loop
      v_conflicts := v_conflicts || jsonb_build_object(
        'kind', 'room', 'lesson_id', v_row.id,
        'starts_at', v_row.starts_at, 'ends_at', v_row.ends_at);
    end loop;
  end if;

  -- Ученики: для индивидуального — он сам, для группового — состав на дату.
  for v_row in
    select lp.student_id, s.full_name, lp.lesson_id, lp.starts_at, lp.ends_at
      from public.lesson_participants lp
      join public.students s on s.id = lp.student_id
     where lp.center_id = p_center
       and lp.deleted_at is null
       and lp.status <> 'cancelled'
       and lp.lesson_id is distinct from p_exclude_id
       and tstzrange(lp.starts_at, lp.ends_at) && tstzrange(p_starts, p_ends)
       and lp.student_id in (
         select p_student where p_student is not null
         union
         select gs.student_id
           from public.group_students gs
          where p_group is not null
            and gs.group_id = p_group
            and gs.deleted_at is null
            and gs.joined_at <= p_starts::date
            and (gs.left_at is null or gs.left_at > p_starts::date)
       )
  loop
    v_conflicts := v_conflicts || jsonb_build_object(
      'kind', 'student', 'student_id', v_row.student_id, 'student_name', v_row.full_name,
      'lesson_id', v_row.lesson_id, 'starts_at', v_row.starts_at, 'ends_at', v_row.ends_at);
  end loop;

  return v_conflicts;
end;
$$;

-- из 0022_center_scoped_fks.sql
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
  v_service  uuid := nullif(p ->> 'service_id', '')::uuid;
  v_problems jsonb := '[]'::jsonb;
  v_late     jsonb;
  v_row      record;
  v_id       uuid;
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if (v_group is null) = (v_student is null) then
    raise exception 'Укажите либо группу, либо ученика' using errcode = '22023';
  end if;

  if v_teacher is null then
    raise exception 'Укажите специалиста' using errcode = '22004';
  end if;

  if not exists (
     select 1 from public.teachers t
      where t.id = v_teacher and t.center_id = v_center and t.deleted_at is null
  ) then
    raise exception 'Специалист недоступен: не найден в этом центре или в архиве' using errcode = '42704';
  end if;

  if v_room is not null and not exists (
     select 1 from public.rooms r
      where r.id = v_room and r.center_id = v_center and r.deleted_at is null
  ) then
    raise exception 'Кабинет недоступен: не найден в этом центре или в архиве' using errcode = '42704';
  end if;

  if v_service is not null and not exists (
     select 1 from public.services s
      where s.id = v_service and s.center_id = v_center and s.deleted_at is null
  ) then
    raise exception 'Услуга недоступна: не найдена в этом центре или в архиве' using errcode = '42704';
  end if;

  if v_group is not null and not exists (
     select 1 from public.groups g
      where g.id = v_group and g.center_id = v_center and g.deleted_at is null
  ) then
    raise exception 'Группа недоступна: не найдена в этом центре или в архиве' using errcode = '42704';
  end if;

  if v_student is not null and not exists (
     select 1 from public.students st
      where st.id = v_student and st.center_id = v_center and st.deleted_at is null
  ) then
    raise exception 'Ученик недоступен: не найден в этом центре или в архиве' using errcode = '42704';
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
        v_center, v_service, v_teacher, v_room,
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

-- из 0011_role_guards.sql
create or replace function public.cancel_lesson(p_id uuid, p_reason text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if not public.can_front_desk() then
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

-- из 0011_role_guards.sql
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
  if not public.can_front_desk() then
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

-- из 0011_role_guards.sql
create or replace function public.substitute_teacher(p_lesson_id uuid, p_new_teacher_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if not public.can_front_desk() then
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
create or replace function public.teacher_vacation_preview(
  p_teacher_id uuid, p_from date, p_to date
)
  returns table (lesson_id uuid, starts_at timestamptz, as_substitute boolean)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select l.id, l.starts_at, l.substitute_teacher_id = p_teacher_id
    from public.lessons l
   where l.center_id = public.current_center()
     and public.can_front_desk()
     and l.deleted_at is null and l.status = 'planned'
     and l.starts_at >= p_from::timestamptz and l.starts_at < (p_to + 1)::timestamptz
     and (l.teacher_id = p_teacher_id or l.substitute_teacher_id = p_teacher_id)
   order by l.starts_at;
$$;

-- из 0011_role_guards.sql
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
  if not public.can_front_desk() then
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

-- из 0011_role_guards.sql
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
  if not public.can_front_desk() then
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

-- из 0010_stage4_hardening.sql
create or replace function public.mark_attendance(
  p_lesson_id  uuid,
  p_student_id uuid,
  p_status_code text default null,
  p_comment    text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := public.my_role();
  v_status public.attendance_statuses;
  v_id     uuid;
  v_exists public.attendance;
begin
  -- coalesce обязателен: `false or NULL` — NULL, `not NULL` — NULL, if не
  -- сработал бы — та же дыра, что закрывала 0010.
  if not (public.can_front_desk() or coalesce(v_role, '') = 'teacher') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if v_role = 'teacher' and not public.teacher_of_lesson(p_lesson_id) then
    raise exception 'Это занятие ведёт другой специалист' using errcode = '42501';
  end if;

  if p_status_code is null then
    select * into v_status from public.attendance_statuses
     where center_id = v_center and is_default and deleted_at is null;
  else
    select * into v_status from public.attendance_statuses
     where center_id = v_center and code = p_status_code and deleted_at is null;
  end if;
  if not found then
    raise exception 'Статус посещения не найден' using errcode = '42704';
  end if;

  insert into public.attendance (center_id, lesson_id, student_id, status_id, comment)
  values (v_center, p_lesson_id, p_student_id, v_status.id, p_comment)
  returning id into v_id;

  return v_id;

exception when unique_violation then
  -- Двойной клик не должен выглядеть как ошибка. Тот же статус —
  -- идемпотентный успех; другой — правка отметки, а не отказ.
  select * into v_exists from public.attendance
   where lesson_id = p_lesson_id and student_id = p_student_id;

  if v_exists.status_id = v_status.id then
    return v_exists.id;
  end if;

  update public.attendance
     set status_id = v_status.id, comment = coalesce(p_comment, comment)
   where id = v_exists.id;
  return v_exists.id;
end;
$$;

-- из 0025_mark_lesson_status_role_guard.sql (#49); Р3
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

  elsif not public.can_front_desk() then
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


-- 5. Абонементы (can_front_desk) ---------------------------------------------------------

-- из 0010_stage4_hardening.sql
create or replace function public.sell_subscription(
  p_type_id    uuid,
  p_student_id uuid,
  p_price_tiyin integer default null,
  p_starts_at  date default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_type    public.subscription_types;
  v_student public.students;
  v_price   integer;
  v_starts  date;
  v_ends    date;
  v_total   integer;
  v_id      uuid;
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_type from public.subscription_types
   where id = p_type_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Тип абонемента не найден' using errcode = '42704';
  end if;

  select * into v_student from public.students
   where id = p_student_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  v_price  := coalesce(p_price_tiyin, v_type.price_tiyin);
  v_starts := coalesce(p_starts_at, public.center_today(v_center));
  v_total  := case when v_type.kind = 'unlimited' then null else v_type.lessons_count end;
  v_ends   := case when v_type.period_days is null then null
                   else v_starts + v_type.period_days end;

  insert into public.subscriptions (
    center_id, student_id, payer_id, type_id,
    lessons_total, price_tiyin, lesson_price_tiyin,
    starts_at, ends_at
  )
  values (
    v_center, p_student_id, v_student.payer_id, p_type_id,
    v_total, v_price, public.calc_lesson_price(v_price, v_total),
    v_starts, v_ends
  )
  returning id into v_id;

  perform public.emit_event('subscription.created',
    jsonb_build_object('center_id', v_center, 'subscription_id', v_id,
                       'student_id', p_student_id, 'price_tiyin', v_price,
                       'lessons_total', v_total), v_center);
  return v_id;
end;
$$;

-- из 0023_sell_subscription_paid.sql
create or replace function public.sell_subscription_paid(
  p_type_id                  uuid,
  p_student_id               uuid,
  p_sale_key                 uuid,
  p_price_tiyin              integer  default null,
  p_starts_at                date     default null,
  p_paid_tiyin               integer  default null,
  p_source_id                uuid     default null,
  p_paid_on                  date     default null,
  p_installments             integer  default null,
  p_first_due                date     default null,
  p_step_months              smallint default 1,
  p_expected_remaining_tiyin integer  default null
)
  returns table (
    subscription_id uuid,
    payment_id      uuid,
    seq             smallint,
    due_date        date,
    amount_tiyin    integer
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_sub       public.subscriptions;
  v_id        uuid;
  v_payment   uuid;
  v_today     date;
  v_paid_on   date;
  v_paid_at   timestamptz;
  v_paid      integer := coalesce(p_paid_tiyin, 0);
  v_remaining integer;
begin
  if auth.uid() is null or not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_sale_key is null then
    raise exception 'sell_subscription_paid: не передан ключ продажи' using errcode = '22004';
  end if;
  if v_paid < 0 then
    raise exception 'Внесённая сумма не может быть отрицательной' using errcode = '22023';
  end if;
  if v_paid > 0 and p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;
  if p_installments is not null and p_installments < 1 then
    raise exception 'Число платежей рассрочки — от 1; без рассрочки поле не передаётся' using errcode = '22023';
  end if;

  v_today   := public.center_today(v_center);
  v_paid_on := coalesce(p_paid_on, v_today);
  if v_paid_on > v_today then
    raise exception 'Дата оплаты не может быть в будущем' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_sale_key::text, 0));
  if exists (select 1 from public.subscriptions s where s.sale_key = p_sale_key) then
    raise exception 'Эта продажа уже проведена — обновите страницу' using errcode = '22023';
  end if;

  v_id := public.sell_subscription(p_type_id, p_student_id, p_price_tiyin, p_starts_at);

  update public.subscriptions s set sale_key = p_sale_key where s.id = v_id;
  select s.* into v_sub from public.subscriptions s where s.id = v_id;

  if v_paid > v_sub.price_tiyin then
    raise exception 'Оплата больше цены абонемента' using errcode = '22023';
  end if;

  v_remaining := v_sub.price_tiyin - v_paid;
  if p_expected_remaining_tiyin is not null and p_expected_remaining_tiyin <> v_remaining then
    raise exception 'Остаток изменился, пока готовили продажу: сейчас % тыйын. Проверьте суммы.', v_remaining
      using errcode = '23514';
  end if;

  if v_paid > 0 then
    v_paid_at := (v_paid_on::timestamp) at time zone public.center_timezone(v_center);
    v_payment := public.record_payment(
      v_sub.payer_id, v_paid, 'payment', p_student_id, v_id,
      p_source_id, v_paid_at, 'Оплата при продаже абонемента'
    );
  end if;

  if p_installments is not null then
    return query
      select v_id, v_payment, v.seq, v.due_date, v.amount_tiyin
        from public.create_installment_plan(v_id, p_installments, p_first_due, p_step_months, v_remaining) v
       order by v.seq;
  else
    return query select v_id, v_payment, null::smallint, null::date, null::integer;
  end if;
end;
$$;

-- из 0015_freeze_state_unification.sql
create or replace function public.freeze_subscription(
  p_id   uuid,
  p_from date,
  p_to   date default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_sub    public.subscriptions;
  v_state  text;
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Почему так — 0015, раздел 6: блокировка — ЕДИНСТВЕННОЕ, что не даёт
  -- двум одновременным freeze_subscription пройти проверку «нет незакрытой
  -- заморозки» на одном снимке (не убирать); coalesce у subscription_state;
  -- защёлка «уже есть незакрытая»; `<=` против пустого daterange(x,x).
  select * into v_sub from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  v_state := coalesce(public.subscription_state(p_id), '');
  if v_state <> 'active' then
    raise exception 'Заморозить можно только действующий абонемент — этот %',
      case v_state
        when 'frozen'    then 'уже заморожен'
        when 'exhausted' then 'исчерпан'
        when 'expired'   then 'истёк'
        when 'cancelled' then 'отменён'
        else 'не действует'
      end
      using errcode = '22023';
  end if;

  if p_from is null then
    raise exception 'Не указана дата начала заморозки' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.subscription_freezes f
     where f.subscription_id = p_id
       and not isempty(f.period)
       and (upper_inf(f.period) or upper(f.period) > public.center_today(v_center))
  ) then
    raise exception 'У абонемента уже есть незакрытая заморозка' using errcode = '22023';
  end if;

  if p_to is not null and p_to <= p_from then
    raise exception 'Дата окончания заморозки должна быть позже даты начала' using errcode = '22023';
  end if;

  insert into public.subscription_freezes (center_id, subscription_id, period)
  values (v_center, p_id, daterange(p_from, p_to, '[)'));

  perform public.emit_event('subscription.frozen',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id,
                       'from', p_from, 'to', p_to), v_center);
end;
$$;

-- из 0015_freeze_state_unification.sql
create or replace function public.unfreeze_subscription(p_id uuid, p_to date default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_open   public.subscription_freezes;
  v_to     date;
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Почему так — 0015, раздел 6: блокировка абонемента; «открытая» — и
  -- бессрочная, и ещё не начавшаяся (её «разморозить» = отменить целиком,
  -- схлопнуть в пустой диапазон); разморозить можно только сегодняшним или
  -- прошлым числом.
  perform 1 from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  select * into v_open from public.subscription_freezes f
   where f.subscription_id = p_id and f.center_id = v_center
     and (upper_inf(f.period) or lower(f.period) > public.center_today(v_center))
   order by lower(f.period) desc limit 1;
  if not found then
    raise exception 'У абонемента нет открытой заморозки' using errcode = '42704';
  end if;

  if lower(v_open.period) > public.center_today(v_center) then
    update public.subscription_freezes
       set period = daterange(lower(v_open.period), lower(v_open.period))
     where id = v_open.id;

    perform public.emit_event('subscription.unfrozen',
      jsonb_build_object('center_id', v_center, 'subscription_id', p_id,
                         'to', lower(v_open.period), 'cancelled_before_start', true), v_center);
    return;
  end if;

  v_to := coalesce(p_to, public.center_today(v_center));
  if v_to < lower(v_open.period) then
    raise exception 'Дата окончания заморозки раньше её начала' using errcode = '22023';
  end if;
  if v_to > public.center_today(v_center) then
    raise exception 'Разморозить можно только сегодняшним или прошлым числом — для будущей даты укажите срок при заморозке'
      using errcode = '22023';
  end if;

  update public.subscription_freezes
     set period = daterange(lower(v_open.period), v_to, '[)')
   where id = v_open.id;

  perform public.emit_event('subscription.unfrozen',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id, 'to', v_to), v_center);
end;
$$;

-- из 0010_stage4_hardening.sql
create or replace function public.transfer_remaining(p_from uuid, p_to_student uuid)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_from    public.subscriptions;
  v_student public.students;
  v_left    integer;
  v_new     uuid;
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_from from public.subscriptions
   where id = p_from and center_id = v_center and deleted_at is null for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  select * into v_student from public.students
   where id = p_to_student and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  v_left := coalesce(public.subscription_lessons_left(p_from), 0);
  if v_left <= 0 then
    raise exception 'Переносить нечего: остаток пуст' using errcode = '22023';
  end if;

  update public.subscriptions
     set lessons_written_off = lessons_written_off + v_left,
         status = 'cancelled'
   where id = p_from;

  insert into public.subscriptions (
    center_id, student_id, payer_id, type_id,
    lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at, notes
  )
  values (
    v_center, p_to_student, v_student.payer_id, v_from.type_id,
    v_left, v_left * coalesce(v_from.lesson_price_tiyin, 0), v_from.lesson_price_tiyin,
    public.center_today(v_center), v_from.ends_at,
    'Перенос остатка с абонемента ' || p_from::text
  )
  returning id into v_new;

  perform public.emit_event('subscription.transferred',
    jsonb_build_object('center_id', v_center, 'from_subscription_id', p_from,
                       'to_subscription_id', v_new, 'lessons', v_left), v_center);
  return v_new;
end;
$$;


-- 6. Платежи и рассрочки (can_payments); возврат абонемента — стойка (Р7) -------------

-- из 0013_finance_core.sql
create or replace function public.record_payment(
  p_payer_id        uuid,
  p_amount_tiyin    integer,
  p_kind            text default 'payment',
  p_student_id      uuid default null,
  p_subscription_id uuid default null,
  p_source_id       uuid default null,
  p_paid_at         timestamptz default now(),
  p_comment         text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_id     uuid;
begin
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  insert into public.payments (
    center_id, payer_id, student_id, subscription_id,
    amount_tiyin, source_id, paid_at, kind, comment, created_by
  )
  values (
    v_center, p_payer_id, p_student_id, p_subscription_id,
    p_amount_tiyin, p_source_id, p_paid_at, p_kind, p_comment, auth.uid()
  )
  returning id into v_id;

  perform public.emit_event(
    case when p_kind = 'refund' then 'payment.refunded' else 'payment.received' end,
    jsonb_build_object(
      'center_id', v_center, 'payment_id', v_id, 'payer_id', p_payer_id,
      'student_id', p_student_id, 'subscription_id', p_subscription_id,
      'amount_tiyin', p_amount_tiyin, 'kind', p_kind
    ),
    v_center
  );

  return v_id;
end;
$$;

-- из 0010_stage4_hardening.sql (Р7: стойка, не платежи)
create or replace function public.refund_subscription(p_id uuid, p_expected_tiyin integer)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_actual integer;
  v_left   integer;
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  perform 1 from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  v_actual := public.refund_calc(p_id);
  if v_actual is distinct from p_expected_tiyin then
    raise exception 'Остаток изменился, пока считали возврат: сейчас % тыйын. Проверьте расчёт.', v_actual
      using errcode = '23514';
  end if;

  v_left := coalesce(public.subscription_lessons_left(p_id), 0);
  update public.subscriptions
     set lessons_written_off = lessons_written_off + v_left,
         status = 'cancelled'
   where id = p_id;

  perform public.emit_event('subscription.refunded',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id,
                       'lessons', v_left, 'amount_tiyin', v_actual), v_center);
  return v_actual;
end;
$$;

-- из 0020_installment_plans.sql (внутренняя; роль — по центру абонемента)
create or replace function public.installment_plans_cancel_live(p_subscription_id uuid)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid;
  v_count  integer;
begin
  select s.center_id into v_center from public.subscriptions s where s.id = p_subscription_id;
  if v_center is null then
    return 0;
  end if;
  if auth.uid() is not null and not public.can_payments(v_center) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.installment_plans p
     set cancelled_at = now()
   where p.subscription_id = p_subscription_id
     and p.cancelled_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- из 0020_installment_plans.sql
create or replace function public.cancel_installment_plan(p_subscription_id uuid)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_plan   public.installment_plans;
  v_rows   integer;
  v_unpaid integer;
begin
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Порядок захвата (Р12 из 0020): абонемент, затем план.
  perform 1 from public.subscriptions s
    where s.id = p_subscription_id and s.center_id = v_center and s.deleted_at is null
    for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  select * into v_plan from public.installment_plans p
   where p.subscription_id = p_subscription_id and p.cancelled_at is null
   for update;
  if not found then
    raise exception 'По абонементу нет живой рассрочки' using errcode = '22023';
  end if;

  select count(*), count(*) filter (where v.state in ('upcoming', 'due', 'overdue'))
    into v_rows, v_unpaid
    from public.installments_view v where v.plan_id = v_plan.id;
  if v_unpaid = 0 then
    raise exception 'Рассрочка оплачена целиком — отменять нечего' using errcode = '22023';
  end if;

  perform public.installment_plans_cancel_live(p_subscription_id);

  perform public.emit_event('installment_plan.cancelled',
    jsonb_build_object(
      'center_id', v_center, 'plan_id', v_plan.id, 'subscription_id', p_subscription_id,
      'student_id', v_plan.student_id, 'payer_id', v_plan.payer_id,
      'unpaid', v_unpaid
    ),
    v_center);

  return v_unpaid;
end;
$$;

-- из 0020_installment_plans.sql
create or replace function public.create_installment_plan(
  p_subscription_id          uuid,
  p_n                        integer,
  p_first_due                date     default null,
  p_step_months              smallint default 1,
  p_expected_remaining_tiyin integer  default null
)
  returns table (
    id                  uuid,
    center_id           uuid,
    subscription_id     uuid,
    student_id          uuid,
    payer_id            uuid,
    plan_id             uuid,
    base_paid_tiyin     integer,
    cancelled_at        timestamptz,
    seq                 smallint,
    due_date            date,
    amount_tiyin        integer,
    due_notified_at     timestamptz,
    overdue_notified_at timestamptz,
    created_at          timestamptz,
    updated_at          timestamptz,
    price_tiyin         integer,
    paid_tiyin          integer,
    cumulative_tiyin    integer,
    state               text
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_sub       public.subscriptions;
  v_plan      uuid;
  v_today     date;
  v_first_due date;
  v_remaining integer;
  v_base      integer;
  v_extra     integer;
  i           integer;
begin
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_n is null or p_n < 1 or p_n > 24 then
    raise exception 'Число платежей — от 1 до 24' using errcode = '22023';
  end if;
  if p_step_months is null or p_step_months < 1 then
    raise exception 'Шаг рассрочки — целое число месяцев, не меньше одного' using errcode = '22023';
  end if;

  -- Почему так — 0020, раздел 5: алиасы обязательны (OUT-параметры returns
  -- table затеняют колонки); остаток проверяется РАНЬШЕ живого плана (иначе
  -- тупик «отмените рассрочку» ↔ «отменять нечего»); p_expected — 23514;
  -- строки в ответ — интерфейс рисует по ответу сервера.
  select s.* into v_sub from public.subscriptions s
   where s.id = p_subscription_id and s.center_id = v_center and s.deleted_at is null
   for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;
  if v_sub.status = 'cancelled' then
    raise exception 'Абонемент отменён — рассрочка невозможна' using errcode = '22023';
  end if;

  v_remaining := v_sub.price_tiyin - v_sub.paid_tiyin;
  if v_remaining <= 0 then
    raise exception 'Абонемент оплачен — рассрочивать нечего' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.installment_plans p
     where p.subscription_id = v_sub.id and p.cancelled_at is null
  ) then
    raise exception 'По абонементу уже есть рассрочка — сначала отмените её' using errcode = '22023';
  end if;
  if p_expected_remaining_tiyin is not null and p_expected_remaining_tiyin <> v_remaining then
    raise exception 'Остаток изменился, пока готовили рассрочку: сейчас % тыйын. Проверьте расчёт.', v_remaining
      using errcode = '23514';
  end if;
  if p_n > v_remaining then
    raise exception 'Платежей больше, чем тыйынов в остатке' using errcode = '22023';
  end if;

  v_today     := public.center_today(v_center);
  v_first_due := coalesce(p_first_due, v_today);
  if v_first_due < v_today then
    raise exception 'Первый платёж рассрочки не может быть в прошлом' using errcode = '22023';
  end if;

  insert into public.installment_plans
    (center_id, subscription_id, student_id, payer_id, base_paid_tiyin, created_by)
  values (v_center, v_sub.id, v_sub.student_id, v_sub.payer_id, v_sub.paid_tiyin, auth.uid())
  returning installment_plans.id into v_plan;

  v_base  := v_remaining / p_n;
  v_extra := v_remaining % p_n;

  for i in 1..p_n loop
    insert into public.installments
      (center_id, subscription_id, student_id, payer_id, plan_id, seq, due_date, amount_tiyin, created_by)
    values
      (v_center, v_sub.id, v_sub.student_id, v_sub.payer_id, v_plan, i,
       (v_first_due + make_interval(months => (i - 1) * p_step_months))::date,
       v_base + (case when i <= v_extra then 1 else 0 end),
       auth.uid());
  end loop;

  perform public.emit_event('installment_plan.created',
    jsonb_build_object(
      'center_id', v_center, 'plan_id', v_plan, 'subscription_id', v_sub.id,
      'student_id', v_sub.student_id, 'payer_id', v_sub.payer_id,
      'installments', p_n, 'total_tiyin', v_remaining, 'first_due', v_first_due
    ),
    v_center);

  return query
    select v.id, v.center_id, v.subscription_id, v.student_id, v.payer_id, v.plan_id,
           v.base_paid_tiyin, v.cancelled_at, v.seq, v.due_date, v.amount_tiyin,
           v.due_notified_at, v.overdue_notified_at, v.created_at, v.updated_at,
           v.price_tiyin, v.paid_tiyin, v.cumulative_tiyin, v.state
      from public.installments_view v
     where v.plan_id = v_plan
     order by v.seq;
end;
$$;

-- из 0020_installment_plans.sql
create or replace function public.pay_installment(
  p_installment_id uuid,
  p_source_id      uuid        default null,
  p_paid_at        timestamptz default now(),
  p_comment        text        default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center     uuid := public.current_center();
  v_inst       public.installments;
  v_sub        public.subscriptions;
  v_plan       public.installment_plans;
  v_cumulative integer;
  v_amount     integer;
begin
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_inst from public.installments
   where id = p_installment_id and center_id = v_center;
  if not found then
    raise exception 'Платёж рассрочки не найден' using errcode = '42704';
  end if;

  -- Р12 из 0020: сначала абонемент, затем строка.
  select * into v_sub from public.subscriptions
   where id = v_inst.subscription_id
   for update;
  if v_sub.deleted_at is not null or v_sub.status = 'cancelled' then
    raise exception 'Абонемент отменён — платёж по рассрочке невозможен' using errcode = '22023';
  end if;

  select * into v_inst from public.installments where id = p_installment_id for update;
  select * into v_plan from public.installment_plans where id = v_inst.plan_id;
  if v_plan.cancelled_at is not null then
    raise exception 'Рассрочка отменена' using errcode = '22023';
  end if;

  select coalesce(sum(x.amount_tiyin), 0) into v_cumulative
    from public.installments x
   where x.plan_id = v_inst.plan_id and x.seq <= v_inst.seq;

  v_amount := v_plan.base_paid_tiyin + v_cumulative - v_sub.paid_tiyin;
  if v_amount <= 0 then
    raise exception 'Этот платёж рассрочки уже оплачен' using errcode = '22023';
  end if;

  return public.record_payment(
    v_inst.payer_id, v_amount, 'payment', v_inst.student_id,
    v_inst.subscription_id, p_source_id, coalesce(p_paid_at, now()), p_comment
  );
end;
$$;

-- из 0015_freeze_state_unification.sql
create or replace function public.subscription_summary(p_subscription_id uuid)
  returns table (
    lessons_left   integer,
    state          text,
    freeze_days    integer,
    refund_tiyin   integer,
    allow_negative boolean,
    freeze_from    date,
    freeze_to      date
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.subscriptions s
     where s.id = p_subscription_id and s.center_id = v_center
  ) then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  return query
    select public.subscription_lessons_left(s.id),
           public.subscription_state(s.id),
           public.subscription_freeze_days(s.id),
           public.refund_calc(s.id),
           s.allow_negative,
           lower(f.period),
           case when upper_inf(f.period) then null else upper(f.period) - 1 end
      from public.subscriptions s
      left join lateral (
        select * from public.subscription_freezes sf
         where sf.subscription_id = s.id
           and (sf.period @> public.center_today(s.center_id)
                or lower(sf.period) > public.center_today(s.center_id))
         order by (sf.period @> public.center_today(s.center_id)) desc, lower(sf.period)
         limit 1
      ) f on true
     where s.id = p_subscription_id;
end;
$$;

-- из 0015_freeze_state_unification.sql (Р4: семантика «текущий центр» сохранена)
create or replace function public.subscription_visible_to_caller(p_subscription_id uuid)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_sub  public.subscriptions;
  v_role text;
begin
  if auth.uid() is null then
    return false;
  end if;

  select * into v_sub from public.subscriptions
   where id = p_subscription_id and deleted_at is null;
  if not found then
    return false;
  end if;

  v_role := coalesce(public.my_role(), '');
  return coalesce(
    (public.can_payments() and v_sub.center_id = public.current_center())
    or (v_role = 'parent' and public.parent_of_student(v_sub.student_id)),
    false
  );
end;
$$;


-- Гранты — заново, явно (create or replace ACL не трогает, правило проекта) --------

revoke execute on function
  public.archive_student(uuid),
  public.restore_student(uuid),
  public.create_student_with_payer(text, uuid, text, text, text, date, text, uuid, text, text),
  public.find_payer_by_phone(text),
  public.payer_display_name(uuid),
  public.create_lesson_series_preview(jsonb),
  public.create_lesson_series(jsonb),
  public.cancel_lesson(uuid, text),
  public.cancel_series_from(uuid, date, text),
  public.substitute_teacher(uuid, uuid),
  public.teacher_vacation_preview(uuid, date, date),
  public.teacher_vacation(uuid, date, date),
  public.reschedule_lesson(uuid, timestamptz, timestamptz),
  public.mark_attendance(uuid, uuid, text, text),
  public.mark_lesson_status(uuid, text, text),
  public.sell_subscription(uuid, uuid, integer, date),
  public.sell_subscription_paid(uuid, uuid, uuid, integer, date, integer, uuid, date, integer, date, smallint, integer),
  public.freeze_subscription(uuid, date, date),
  public.unfreeze_subscription(uuid, date),
  public.transfer_remaining(uuid, uuid),
  public.record_payment(uuid, integer, text, uuid, uuid, uuid, timestamptz, text),
  public.refund_subscription(uuid, integer),
  public.cancel_installment_plan(uuid),
  public.create_installment_plan(uuid, integer, date, smallint, integer),
  public.pay_installment(uuid, uuid, timestamptz, text),
  public.subscription_summary(uuid),
  public.subscription_visible_to_caller(uuid)
  from public, anon, authenticated;

grant execute on function
  public.archive_student(uuid),
  public.restore_student(uuid),
  public.create_student_with_payer(text, uuid, text, text, text, date, text, uuid, text, text),
  public.find_payer_by_phone(text),
  public.payer_display_name(uuid),
  public.create_lesson_series_preview(jsonb),
  public.create_lesson_series(jsonb),
  public.cancel_lesson(uuid, text),
  public.cancel_series_from(uuid, date, text),
  public.substitute_teacher(uuid, uuid),
  public.teacher_vacation_preview(uuid, date, date),
  public.teacher_vacation(uuid, date, date),
  public.reschedule_lesson(uuid, timestamptz, timestamptz),
  public.mark_attendance(uuid, uuid, text, text),
  public.mark_lesson_status(uuid, text, text),
  public.sell_subscription(uuid, uuid, integer, date),
  public.sell_subscription_paid(uuid, uuid, uuid, integer, date, integer, uuid, date, integer, date, smallint, integer),
  public.freeze_subscription(uuid, date, date),
  public.unfreeze_subscription(uuid, date),
  public.transfer_remaining(uuid, uuid),
  public.record_payment(uuid, integer, text, uuid, uuid, uuid, timestamptz, text),
  public.refund_subscription(uuid, integer),
  public.cancel_installment_plan(uuid),
  public.create_installment_plan(uuid, integer, date, smallint, integer),
  public.pay_installment(uuid, uuid, timestamptz, text),
  public.subscription_summary(uuid)
  to authenticated;

-- Внутренние — закрыты для всех прикладных ролей, как раньше.
revoke execute on function public.lesson_slot_conflicts(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid)
  from public, anon, authenticated;
revoke all on function public.installment_plans_cancel_live(uuid)
  from public, anon, authenticated, service_role;
