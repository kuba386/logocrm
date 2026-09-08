-- =============================================================================
-- 0006_schedule.sql — расписание
--
--   1. btree_gist            — нужен для EXCLUDE по uuid + диапазону
--   2. rooms, services       — справочники центра
--   3. groups, group_students
--   4. lessons               — занятие; effective_teacher_id закрывает замену
--   5. lesson_participants   — денормализованный состав ради констрейнта
--   6. RLS
--   7. Функции серий, отмены, замены, отпуска, смены статуса
--
-- Почему состав участников вынесен в отдельную таблицу — ADR-006.
-- =============================================================================

create extension if not exists btree_gist with schema extensions;


-- 2. Справочники --------------------------------------------------------------

create table if not exists public.rooms (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  name          text not null,
  capacity      integer not null default 1 check (capacity > 0),
  is_active     boolean not null default true,
  custom_fields jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz
);

create index if not exists rooms_center_idx on public.rooms (center_id) where deleted_at is null;

drop trigger if exists rooms_set_updated_at on public.rooms;
create trigger rooms_set_updated_at before update on public.rooms
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('rooms');
call public.apply_audit('rooms');

create table if not exists public.services (
  id                  uuid primary key default gen_random_uuid(),
  center_id           uuid not null default public.current_center()
                        references public.centers (id) on delete cascade,
  name                text not null,
  duration_min        integer not null default 45 check (duration_min between 5 and 480),
  default_price_tiyin integer check (default_price_tiyin is null or default_price_tiyin >= 0),
  kind                text not null default 'individual'
                        check (kind in ('individual', 'group')),
  is_active           boolean not null default true,
  custom_fields       jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid default auth.uid(),
  deleted_at          timestamptz
);

comment on column public.services.default_price_tiyin is 'Цена в тыйынах (1 сом = 100 тыйынов).';

create index if not exists services_center_idx on public.services (center_id) where deleted_at is null;

drop trigger if exists services_set_updated_at on public.services;
create trigger services_set_updated_at before update on public.services
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('services');
call public.apply_audit('services');


-- 3. Группы -------------------------------------------------------------------

create table if not exists public.groups (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  name          text not null,
  service_id    uuid references public.services (id) on delete set null,
  teacher_id    uuid references public.teachers (id) on delete set null,
  room_id       uuid references public.rooms (id) on delete set null,
  max_students  integer check (max_students is null or max_students > 0),
  is_active     boolean not null default true,
  custom_fields jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz
);

create index if not exists groups_center_idx on public.groups (center_id) where deleted_at is null;

drop trigger if exists groups_set_updated_at on public.groups;
create trigger groups_set_updated_at before update on public.groups
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('groups');
call public.apply_audit('groups');

-- Состав группы во времени: left_at null — ученик в группе сейчас.
create table if not exists public.group_students (
  id         uuid primary key default gen_random_uuid(),
  center_id  uuid not null default public.current_center()
               references public.centers (id) on delete cascade,
  group_id   uuid not null references public.groups (id) on delete cascade,
  student_id uuid not null references public.students (id) on delete cascade,
  joined_at  date not null default current_date,
  left_at    date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  deleted_at timestamptz,
  check (left_at is null or left_at >= joined_at)
);

create index if not exists group_students_group_idx on public.group_students (group_id) where deleted_at is null;
create index if not exists group_students_student_idx on public.group_students (student_id) where deleted_at is null;

drop trigger if exists group_students_set_updated_at on public.group_students;
create trigger group_students_set_updated_at before update on public.group_students
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('group_students');
call public.apply_audit('group_students');


-- 4. lessons ------------------------------------------------------------------

create table if not exists public.lessons (
  id                    uuid primary key default gen_random_uuid(),
  center_id             uuid not null default public.current_center()
                          references public.centers (id) on delete cascade,
  service_id            uuid references public.services (id) on delete set null,
  teacher_id            uuid not null references public.teachers (id) on delete restrict,
  substitute_teacher_id uuid references public.teachers (id) on delete set null,
  -- Кто фактически ведёт занятие. Именно на эту колонку вешается EXCLUDE:
  -- иначе заменой можно было бы поставить уже занятого специалиста.
  effective_teacher_id  uuid generated always as (coalesce(substitute_teacher_id, teacher_id)) stored,
  room_id               uuid references public.rooms (id) on delete set null,
  group_id              uuid references public.groups (id) on delete cascade,
  student_id            uuid references public.students (id) on delete cascade,
  starts_at             timestamptz not null,
  ends_at               timestamptz not null,
  status                text not null default 'planned'
                          check (status in ('planned', 'done', 'cancelled')),
  cancel_reason         text,
  series_id             uuid,
  notes                 text,
  custom_fields         jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            uuid default auth.uid(),
  deleted_at            timestamptz,

  check (ends_at > starts_at),
  -- Занятие либо групповое, либо индивидуальное. Третьего не дано.
  check ((group_id is null) <> (student_id is null)),

  -- Специалист не может быть в двух местах одновременно.
  constraint lessons_teacher_no_overlap exclude using gist (
    effective_teacher_id with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (deleted_at is null and status <> 'cancelled'),

  -- Кабинет тоже.
  constraint lessons_room_no_overlap exclude using gist (
    room_id with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (deleted_at is null and status <> 'cancelled' and room_id is not null)
);

comment on column public.lessons.effective_teacher_id is
  'coalesce(substitute_teacher_id, teacher_id). Только для констрейнта занятости — в RLS используются обе колонки отдельно, чтобы урок видели и основной специалист, и заменяющий.';

create index if not exists lessons_center_starts_idx on public.lessons (center_id, starts_at) where deleted_at is null;
create index if not exists lessons_teacher_idx on public.lessons (teacher_id, starts_at) where deleted_at is null;
create index if not exists lessons_substitute_idx on public.lessons (substitute_teacher_id) where substitute_teacher_id is not null;
create index if not exists lessons_group_idx on public.lessons (group_id) where group_id is not null;
create index if not exists lessons_student_idx on public.lessons (student_id) where student_id is not null;
create index if not exists lessons_series_idx on public.lessons (series_id) where series_id is not null;

drop trigger if exists lessons_set_updated_at on public.lessons;
create trigger lessons_set_updated_at before update on public.lessons
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('lessons');
call public.apply_audit('lessons');


-- 5. lesson_participants ------------------------------------------------------

-- Денормализация ради констрейнта: EXCLUDE на lessons.student_id ничего не
-- ловит у групповых занятий (там student_id пуст, а NULL-ы в exclusion не
-- конфликтуют). Состав раскрывается в отдельную таблицу, и уже на ней стоит
-- запрет пересечений по ребёнку — он держит и прямой insert, и перенос урока,
-- и добавление ребёнка в группу задним числом, и параллельные транзакции.
-- Подробности — ADR-006.
create table if not exists public.lesson_participants (
  lesson_id  uuid not null references public.lessons (id) on delete cascade,
  student_id uuid not null references public.students (id) on delete cascade,
  center_id  uuid not null,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  status     text not null default 'planned',
  deleted_at timestamptz,

  primary key (lesson_id, student_id),

  constraint lesson_participants_no_overlap exclude using gist (
    student_id with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (deleted_at is null and status <> 'cancelled')
);

comment on table public.lesson_participants is
  'Кто на занятии. Заполняется только триггерами — руками не трогать. Существует ради EXCLUDE по ребёнку.';

create index if not exists lesson_participants_student_idx
  on public.lesson_participants (student_id, starts_at);

-- Пересборка состава одного занятия.
create or replace function public.rebuild_lesson_participants(p_lesson_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_lesson public.lessons;
  v_name   text;
begin
  select * into v_lesson from public.lessons where id = p_lesson_id;

  if not found then
    delete from public.lesson_participants where lesson_id = p_lesson_id;
    return;
  end if;

  delete from public.lesson_participants where lesson_id = p_lesson_id;

  begin
    if v_lesson.student_id is not null then
      insert into public.lesson_participants
        (lesson_id, student_id, center_id, starts_at, ends_at, status, deleted_at)
      values
        (v_lesson.id, v_lesson.student_id, v_lesson.center_id,
         v_lesson.starts_at, v_lesson.ends_at, v_lesson.status, v_lesson.deleted_at);
    else
      -- Состав группы на дату занятия: вошёл не позже, вышел не раньше.
      insert into public.lesson_participants
        (lesson_id, student_id, center_id, starts_at, ends_at, status, deleted_at)
      select v_lesson.id, gs.student_id, v_lesson.center_id,
             v_lesson.starts_at, v_lesson.ends_at, v_lesson.status, v_lesson.deleted_at
        from public.group_students gs
       where gs.group_id = v_lesson.group_id
         and gs.deleted_at is null
         and gs.joined_at <= v_lesson.starts_at::date
         and (gs.left_at is null or gs.left_at > v_lesson.starts_at::date);
    end if;

  exception when exclusion_violation then
    -- Подменяем машинный текст на человеческий: имя ребёнка полезнее,
    -- чем имя констрейнта.
    select s.full_name into v_name
      from public.students s
     where s.id = coalesce(
             v_lesson.student_id,
             (select gs.student_id
                from public.group_students gs
                join public.lesson_participants lp on lp.student_id = gs.student_id
               where gs.group_id = v_lesson.group_id
                 and lp.deleted_at is null
                 and tstzrange(lp.starts_at, lp.ends_at) && tstzrange(v_lesson.starts_at, v_lesson.ends_at)
               limit 1));

    raise exception 'У ученика % уже есть занятие в это время',
      coalesce(v_name, 'из этой группы') using errcode = '23P01';
  end;
end;
$$;

create or replace function public.lessons_participants_trigger()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.lesson_participants where lesson_id = old.id;
    return null;
  end if;

  perform public.rebuild_lesson_participants(new.id);
  return null;
end;
$$;

drop trigger if exists lessons_sync_participants on public.lessons;
create trigger lessons_sync_participants
  after insert or update of student_id, group_id, starts_at, ends_at, status, deleted_at
     or delete
  on public.lessons
  for each row execute function public.lessons_participants_trigger();

-- Вход и выход ученика переписывают его строки в будущих занятиях группы.
create or replace function public.group_students_participants_trigger()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_group uuid := coalesce(new.group_id, old.group_id);
  v_lesson uuid;
begin
  for v_lesson in
    select l.id from public.lessons l
     where l.group_id = v_group
       and l.deleted_at is null
       and l.status <> 'cancelled'
       and l.starts_at >= now()
  loop
    perform public.rebuild_lesson_participants(v_lesson);
  end loop;

  return null;
end;
$$;

drop trigger if exists group_students_sync_participants on public.group_students;
create trigger group_students_sync_participants
  after insert or update or delete on public.group_students
  for each row execute function public.group_students_participants_trigger();

alter table public.lesson_participants enable row level security;

-- Только чтение и только тем, кто видит само занятие. Политик на запись нет
-- ни у кого: строки кладут триггеры (security definer, владелец таблицы —
-- postgres, RLS его не касается). Прямой insert рассинхронил бы состав, и
-- констрейнт продолжил бы работать, но врать — это хуже, чем его отсутствие.
drop policy if exists lesson_participants_read on public.lesson_participants;
create policy lesson_participants_read on public.lesson_participants
  for select to authenticated
  using (
    center_id = public.current_center()
    and (
      public.my_role() in ('owner', 'admin')
      or exists (
        select 1 from public.lessons l
         where l.id = lesson_participants.lesson_id
           and public.my_role() = 'teacher'
           and (l.teacher_id = public.my_teacher_id() or l.substitute_teacher_id = public.my_teacher_id())
      )
      or exists (
        select 1 from public.students s
         where s.id = lesson_participants.student_id
           and public.my_role() = 'parent'
           and s.payer_id = public.my_payer_id()
      )
    )
  );


-- 6. RLS на lessons -----------------------------------------------------------

-- Урок видят оба специалиста: и основной, и заменяющий. Поэтому здесь две
-- колонки, а не effective_teacher_id — иначе основной терял бы свой урок
-- сразу после назначения замены.
drop policy if exists lessons_teacher_read_own on public.lessons;
create policy lessons_teacher_read_own on public.lessons
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'teacher'
    and (teacher_id = public.my_teacher_id() or substitute_teacher_id = public.my_teacher_id())
    and deleted_at is null
  );

-- Политики на UPDATE у специалиста нет намеренно: статус меняется только
-- через mark_lesson_status, где проверяется и право, и набор полей.

drop policy if exists lessons_parent_read on public.lessons;
create policy lessons_parent_read on public.lessons
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'parent'
    and deleted_at is null
    and exists (
      select 1 from public.lesson_participants lp
      join public.students s on s.id = lp.student_id
      where lp.lesson_id = lessons.id
        and s.payer_id = public.my_payer_id()
        and s.deleted_at is null
    )
  );

-- Специалист видит и тех учеников, с кем у него есть занятия, а не только
-- закреплённых за ним.
drop policy if exists students_teacher_read_own on public.students;
create policy students_teacher_read_own on public.students
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'teacher'
    and deleted_at is null
    and (
      primary_teacher_id = public.my_teacher_id()
      or exists (
        select 1 from public.lessons l
        join public.lesson_participants lp on lp.lesson_id = l.id
        where lp.student_id = students.id
          and l.deleted_at is null
          and (l.teacher_id = public.my_teacher_id() or l.substitute_teacher_id = public.my_teacher_id())
      )
    )
  );


-- 7. Функции ------------------------------------------------------------------

-- Часовой пояс центра. Серверный TimeZone здесь не годится: админ вводит
-- локальное время, а на этапе 8 появятся филиалы в разных поясах.
create or replace function public.center_timezone(p_center_id uuid default null)
  returns text
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(
    (select c.settings ->> 'timezone'
       from public.centers c
      where c.id = coalesce(p_center_id, public.current_center())),
    'Asia/Bishkek'
  );
$$;

-- Что мешает занять слот. Одна функция на предпросмотр и на создание —
-- иначе диалог будет показывать одно, а сохранение падать по другому.
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
  if public.my_role() not in ('owner', 'admin') then
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

-- Даты серии по дням недели. weekdays — ISO: 1 понедельник … 7 воскресенье.
create or replace function public.series_dates(p jsonb)
  returns table (day date, starts_at timestamptz, ends_at timestamptz)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid := public.current_center();
  v_tz       text := coalesce(nullif(p ->> 'timezone', ''), public.center_timezone(v_center));
  v_first    date := (p ->> 'first_date')::date;
  v_until    date := coalesce((p ->> 'until')::date, (p ->> 'first_date')::date);
  v_time     time := (p ->> 'time')::time;
  v_weekdays int[] := coalesce(
                        (select array_agg(value::int) from jsonb_array_elements_text(p -> 'weekdays')),
                        array[extract(isodow from (p ->> 'first_date')::date)::int]);
  v_duration int;
  v_cursor   date;
begin
  if v_weekdays is null or array_length(v_weekdays, 1) is null then
    raise exception 'Укажите хотя бы один день недели' using errcode = '22004';
  end if;

  if exists (select 1 from unnest(v_weekdays) d where d < 1 or d > 7) then
    raise exception 'День недели вне диапазона 1–7 (понедельник — воскресенье)'
      using errcode = '22023';
  end if;

  -- Повтор дня в списке — признак ошибки в интерфейсе. Молча схлопывать
  -- нельзя: админ будет думать, что заказал два занятия в среду.
  if (select count(*) from unnest(v_weekdays)) <> (select count(distinct d) from unnest(v_weekdays) d) then
    raise exception 'День недели указан дважды' using errcode = '22023';
  end if;

  select s.duration_min into v_duration
    from public.services s
   where s.id = nullif(p ->> 'service_id', '')::uuid and s.center_id = v_center;
  v_duration := coalesce(v_duration, 45);

  v_cursor := v_first;
  while v_cursor <= v_until loop
    if extract(isodow from v_cursor)::int = any (v_weekdays) then
      day := v_cursor;
      starts_at := (v_cursor + v_time) at time zone v_tz;
      ends_at := starts_at + make_interval(mins => v_duration);
      return next;
    end if;
    v_cursor := v_cursor + 1;
  end loop;
end;
$$;

-- Предпросмотр серии для диалога: дата — свободно или чем занято.
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
  if public.my_role() not in ('owner', 'admin') then
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

-- Серия создаётся целиком или не создаётся вовсе.
--
-- «Создать что получилось» здесь вредно: админ увидит половину расписания и
-- не поймёт, чего не хватает. Поэтому все даты проверяются заранее, и при
-- любом конфликте поднимается исключение со списком в detail.
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
  v_row      record;
  v_id       uuid;
begin
  if public.my_role() not in ('owner', 'admin') then
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
      raise exception 'Слот заняли, пока заполнялась форма — серия не создана'
        using errcode = '23P01',
              detail = jsonb_build_array(jsonb_build_object(
                'day', v_row.day,
                'starts_at', v_row.starts_at,
                'conflicts', public.lesson_slot_conflicts(
                  v_center, v_teacher, v_room, v_group, v_student,
                  v_row.starts_at, v_row.ends_at)
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

create or replace function public.cancel_lesson(p_id uuid, p_reason text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if public.my_role() not in ('owner', 'admin') then
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
  if public.my_role() not in ('owner', 'admin') then
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

create or replace function public.substitute_teacher(p_lesson_id uuid, p_new_teacher_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if public.my_role() not in ('owner', 'admin') then
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
     and public.my_role() in ('owner', 'admin')
     and l.deleted_at is null and l.status = 'planned'
     and l.starts_at >= p_from::timestamptz and l.starts_at < (p_to + 1)::timestamptz
     and (l.teacher_id = p_teacher_id or l.substitute_teacher_id = p_teacher_id)
   order by l.starts_at;
$$;

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
  if public.my_role() not in ('owner', 'admin') then
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

-- Единственный путь специалиста к занятию.
--
-- Разрешённые переходы разные по ролям и зашиты здесь, а не в интерфейсе:
-- специалист закрывает урок или отменяет его, но не переоткрывает задним
-- числом. Разбор «а почему занятие снова planned» — работа администратора.
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

  elsif v_role not in ('owner', 'admin') then
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


-- Права -----------------------------------------------------------------------

grant select, insert, update on public.rooms, public.services, public.groups,
                                public.group_students, public.lessons to authenticated;

-- Только чтение: строки кладут триггеры.
grant select on public.lesson_participants to authenticated;

revoke execute on function
  public.rebuild_lesson_participants(uuid),
  public.center_timezone(uuid),
  public.lesson_slot_conflicts(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid),
  public.series_dates(jsonb),
  public.create_lesson_series_preview(jsonb),
  public.create_lesson_series(jsonb),
  public.cancel_lesson(uuid, text),
  public.cancel_series_from(uuid, date, text),
  public.substitute_teacher(uuid, uuid),
  public.teacher_vacation(uuid, date, date),
  public.teacher_vacation_preview(uuid, date, date),
  public.mark_lesson_status(uuid, text, text)
  from public, anon;

grant execute on function
  public.center_timezone(uuid),
  public.series_dates(jsonb),
  public.create_lesson_series_preview(jsonb),
  public.create_lesson_series(jsonb),
  public.cancel_lesson(uuid, text),
  public.cancel_series_from(uuid, date, text),
  public.substitute_teacher(uuid, uuid),
  public.teacher_vacation(uuid, date, date),
  public.teacher_vacation_preview(uuid, date, date),
  public.mark_lesson_status(uuid, text, text)
  to authenticated;
