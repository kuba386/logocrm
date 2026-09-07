-- =============================================================================
-- 0005_students.sql — ученики и плательщики
--
--   1. payers    — плательщик (родитель/опекун), носитель контактов и денег
--   2. students  — ребёнок
--   3. students_teacher_view — витрина для специалиста без контактов
--   4. payers_with_stats     — витрина для владельца/администратора
--   5. archive_student / restore_student
--   6. find_payer_by_phone + normalize_kg_phone
--   7. create_student_with_payer — создание ребёнка и плательщика одной транзакцией
--
-- Почему плательщик отдельной таблицей и почему витрина, а не колоночные
-- гранты — см. docs/Decisions/ADR-005-column-privacy.md
-- =============================================================================


-- 1. Нормализация телефона ----------------------------------------------------

-- Кыргызстан: +996 и девять цифр. На вход принимаем 0700123456, 700123456,
-- +996 700 12-34-56 и подобное. Иммутабельная — используется в индексе.
create or replace function public.normalize_kg_phone(p_phone text)
  returns text
  language plpgsql
  immutable
  set search_path = ''
as $$
declare
  v_digits text;
begin
  if p_phone is null then
    return null;
  end if;

  v_digits := regexp_replace(p_phone, '[^0-9]', '', 'g');

  -- 996XXXXXXXXX
  if length(v_digits) = 12 and left(v_digits, 3) = '996' then
    return '+' || v_digits;
  end if;

  -- 0XXXXXXXXX — местная запись с ведущим нулём
  if length(v_digits) = 10 and left(v_digits, 1) = '0' then
    return '+996' || right(v_digits, 9);
  end if;

  -- XXXXXXXXX — девять цифр без кода
  if length(v_digits) = 9 then
    return '+996' || v_digits;
  end if;

  return null;
end;
$$;


-- 2. payers -------------------------------------------------------------------

create table if not exists public.payers (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  full_name     text not null,
  phone         text not null,
  phone_alt     text,
  email         text,
  relation      text check (relation is null or relation in ('мама', 'папа', 'бабушка', 'дедушка', 'опекун', 'другое')),
  notes         text,
  custom_fields jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz
);

comment on table public.payers is
  'Плательщик — родитель или опекун. Отдельная сущность: один плательщик платит за нескольких детей, и на нём же висят долги и рассылки.';

create index if not exists payers_center_idx on public.payers (center_id) where deleted_at is null;

-- Дубли родителей потом сливать мучительно — не даём создать.
-- Индекс по нормализованному номеру: +996700123456 и 0700 12-34-56 — один и тот же.
create unique index if not exists payers_center_phone_uniq
  on public.payers (center_id, public.normalize_kg_phone(phone))
  where deleted_at is null;

drop trigger if exists payers_set_updated_at on public.payers;
create trigger payers_set_updated_at
  before update on public.payers
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('payers');
call public.apply_audit('payers');

-- Родитель видит собственную карточку.
drop policy if exists payers_read_self on public.payers;
create policy payers_read_self on public.payers
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'parent'
    and id = public.my_payer_id()
    and deleted_at is null
  );


-- 3. students -----------------------------------------------------------------

create table if not exists public.students (
  id                 uuid primary key default gen_random_uuid(),
  center_id          uuid not null default public.current_center()
                       references public.centers (id) on delete cascade,
  full_name          text not null,
  birth_date         date,
  gender             text check (gender is null or gender in ('м', 'ж')),
  payer_id           uuid not null references public.payers (id) on delete restrict,
  primary_teacher_id uuid references public.teachers (id) on delete set null,
  status             text not null default 'active'
                       check (status in ('lead', 'active', 'paused', 'archived')),
  source             text,
  started_at         date,
  notes              text,
  custom_fields      jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid default auth.uid(),
  deleted_at         timestamptz
);

comment on table public.students is 'Ребёнок. Контакты и деньги живут на payers, здесь их намеренно нет.';

create index if not exists students_center_status_idx on public.students (center_id, status) where deleted_at is null;
create index if not exists students_payer_idx on public.students (payer_id);
create index if not exists students_teacher_idx on public.students (primary_teacher_id);

drop trigger if exists students_set_updated_at on public.students;
create trigger students_set_updated_at
  before update on public.students
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('students');
call public.apply_audit('students');

-- Специалист видит своих детей. Позже расширим на тех, у кого есть занятия с ним.
drop policy if exists students_teacher_read_own on public.students;
create policy students_teacher_read_own on public.students
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'teacher'
    and primary_teacher_id = public.my_teacher_id()
    and deleted_at is null
  );

-- Родитель видит своих детей.
drop policy if exists students_parent_read_own on public.students;
create policy students_parent_read_own on public.students
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'parent'
    and payer_id = public.my_payer_id()
    and deleted_at is null
  );


-- 4. Витрины ------------------------------------------------------------------

-- Возраст в годах на заданную дату.
create or replace function public.age_years(p_birth_date date)
  returns integer
  language sql
  stable
  set search_path = ''
as $$
  select case when p_birth_date is null then null
              else extract(year from age(current_date, p_birth_date))::int end;
$$;

-- Имя плательщика для тех, кому сама таблица payers закрыта.
--
-- Join к payers здесь не годится: вью с security_invoker выполняется с правами
-- вызывающего, специалисту payers не видна вовсе (0 строк по RLS), и внутреннее
-- соединение обнулило бы всю витрину. Отдаём ровно одну безопасную колонку
-- через узкую security definer-функцию — тем же приёмом, что и user_email().
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
  if v_role in ('owner', 'admin') then
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

-- Витрина для специалиста: ребёнок есть, контактов родителя нет.
-- Колонок phone / payer_id / email здесь нет физически — не «скрыты в UI».
drop view if exists public.students_teacher_view;
create view public.students_teacher_view
  with (security_invoker = true)
as
select
  s.id,
  s.center_id,
  s.full_name,
  s.birth_date,
  public.age_years(s.birth_date) as age_years,
  s.gender,
  s.status,
  s.notes,
  s.primary_teacher_id,
  public.payer_display_name(s.payer_id) as payer_full_name
from public.students s
where s.deleted_at is null;

comment on view public.students_teacher_view is
  'Ученики без контактов плательщика. Из имени родителя видно только ФИО — телефон остаётся в payers, куда специалисту доступ закрыт RLS.';

drop view if exists public.payers_with_stats;
create view public.payers_with_stats
  with (security_invoker = true)
as
select
  p.id,
  p.center_id,
  p.full_name,
  p.phone,
  p.phone_alt,
  p.email,
  p.relation,
  p.notes,
  p.created_at,
  (select count(*) from public.students s
    where s.payer_id = p.id and s.deleted_at is null)::int as children_count
from public.payers p
where p.deleted_at is null;


-- 5. Архивация ----------------------------------------------------------------

create or replace function public.archive_student(p_id uuid)
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

create or replace function public.restore_student(p_id uuid)
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


-- 6. Поиск плательщика по телефону -------------------------------------------

-- Для формы «добавить ученика»: администратор вводит номер, система отвечает
-- «эта мама уже есть, у неё двое детей — привязать?».
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
  if public.my_role() not in ('owner', 'admin') then
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


-- 7. Создание ученика ---------------------------------------------------------

-- Ребёнок и плательщик создаются одной транзакцией: иначе при падении второго
-- шага в центре остаётся плательщик-сирота без детей.
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
  if public.my_role() not in ('owner', 'admin') then
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


-- 8. Признак отозванного доступа ---------------------------------------------

-- Отличает «никогда не состоял в центре» от «доступ отозвали»: без этого
-- отключённый сотрудник попадал на «Создайте свой центр» сразу после увольнения.
--
-- Читает events напрямую в обход RLS: политика на events пускает только
-- владельца центра, а спрашивает здесь как раз тот, у кого центра уже нет.
-- Наружу отдаётся один булев признак — ни центра, ни дат, ни кто отключил.
create or replace function public.was_access_revoked()
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1
      from public.events e
     where e.type = 'membership.revoked'
       and e.payload ->> 'user_id' = auth.uid()::text
       and e.created_at > now() - interval '90 days'
  );
$$;


-- Права -----------------------------------------------------------------------

grant select, insert, update on public.payers   to authenticated;
grant select, insert, update on public.students to authenticated;
grant select on public.students_teacher_view    to authenticated;
grant select on public.payers_with_stats        to authenticated;

revoke execute on function
  public.normalize_kg_phone(text),
  public.age_years(date),
  public.payer_display_name(uuid),
  public.was_access_revoked(),
  public.archive_student(uuid),
  public.restore_student(uuid),
  public.find_payer_by_phone(text),
  public.create_student_with_payer(text, uuid, text, text, text, date, text, uuid, text, text)
  from public, anon;

grant execute on function
  public.normalize_kg_phone(text),
  public.age_years(date),
  public.payer_display_name(uuid),
  public.was_access_revoked(),
  public.archive_student(uuid),
  public.restore_student(uuid),
  public.find_payer_by_phone(text),
  public.create_student_with_payer(text, uuid, text, text, text, date, text, uuid, text, text)
  to authenticated;
