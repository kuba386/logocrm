-- =============================================================================
-- 0105_makeup_lessons.sql — отработки пропусков (этап 14)
--
-- Решение владельца 19.10.2026: отработка — за ОПЛАЧЕННЫЙ пропуск. Право
-- дают только списывающие статусы; новый статус «Пропуск с отработкой»
-- (absent_makeup) — списывает и даёт право. «Болел» — бесплатный пропуск без
-- отработки, иначе 9 занятий за 8 оплаченных. Ядро, не модуль (ADR-013).
-- Выключено, пока центр не настроил политику.
--
-- Решения (ревью архитектора плана: 12 блокеров, 13 замечаний — учтены):
--   Р1. makeup_policies: нет живой строки = выключено. Выключение не трогает
--       выданные права — ими можно пользоваться до срока.
--   Р2. attendance_statuses.grants_makeup + check (только списывающий статус
--       без присутствия); колоночный грант; absent_makeup засеян всем центрам.
--   Р3. makeup_credits — выдаёт и отменяет AFTER-триггер на attendance (не
--       BEFORE: у права FK на attendance.id) под блокировкой строки права и
--       абонемента. Лимит на абонемент превышен — право молча не выдаётся.
--       Статус перестал давать право: живое право отменяется и его запись
--       закрывается; использованное — отказ с текстом. Отметка на отработке
--       права не выдаёт никогда. Частичный unique по неотменённым — «Болел →
--       Пришёл → Болел» выдаёт право заново без 23505.
--   Р4. makeup_bookings — совместимость права и занятия держит BEFORE-триггер:
--       право живое и не сгорело; тот же центр и ученик; услуга совпадает
--       (is not distinct from); занятие живое, не отменено, в будущем, не
--       раньше даты пропуска и не позже expires_on; групповое — ребёнок не в
--       составе и есть место (max_students, блокировка строки занятия);
--       индивидуальное — только своё. Обновлять можно только закрытие.
--   Р5. Триггер на lessons (BEFORE UPDATE): отмена, удаление, перенос, смена
--       услуги или группы закрывает неотмеченные записи на это занятие
--       (право снова доступно), а отмена или удаление исходного занятия
--       отменяет неиспользованное право с его записью. Закрытие — до
--       пересборки состава: перенос не упирается в EXCLUDE записанного.
--   Р6. Архив ученика закрывает его записи и отменяет неиспользованные права.
--   Р7. rebuild_lesson_participants: состав ∪ живые записи (без дублей),
--       lesson_participants.via_makeup; clinical_teacher_taught не считает
--       строки-отработки — чужая группа не открывает клинику (ADR-005).
--   Р8. attendance_fill_and_check (0103): makeup_credit_id — из живой записи
--       на INSERT, заморожен на UPDATE; с ним deducted = false при любом
--       статусе, без абонемента, цена — снимок цены пропуска (процентная
--       ставка специалиста не ноль; выручка, долг, остатки смотрят deducted).
--       Использование права — AFTER-триггер: присутствие или списывающий
--       статус использует право; иначе право остаётся записанным.
--   Р9. Удаление отметки, на которую ссылается право, — отказ (кроме каскада
--       удаления центра).
--   Р10. lesson_attendance_balances — вид makeup раньше всех веток.
--   Р11. Видимость: owner/admin/registrar — select; специалист — только
--       метка панели; родитель и бухгалтер — нет. Писать — только функции.
--   Р12. Принято: право остаётся до срока при возврате или отмене абонемента;
--       перенос исходного занятия после отметки срок не пересчитывает;
--       восстановление отменённого занятия или ученика право не возвращает;
--       специалист группы-цели видит базовую карточку записанного ребёнка
--       (без контактов и клиники) — иначе нечего отмечать.
--   Р13 (ревью SQL). Любая отметка на отработке её расходует: не пришёл —
--       сгорела. Отменить право со ссылающейся отметкой нельзя — держит
--       BEFORE UPDATE OF cancelled_at на makeup_credits, он же закрывает
--       живые записи (одно место, под блокировкой строки права).
--   Р14. Пропуск без абонемента (в долг) права не даёт — только оплаченный.
--   Р15. absent_makeup засевается в архив, set_makeup_policy достаёт его при
--       включении; при выключенной политике отметку статусом с правом
--       отклоняет attendance_fill_and_check.
--   Р16. Отмена или удаление исходного занятия с использованной отработкой —
--       отказ; занятия-цели — право снова доступно (отметка не списывала).
--       Вступление ребёнка в группу закрывает его записи в её занятиях.
-- =============================================================================


-- 1. Статусы: право на отработку (Р2) -------------------------------------------------------------

alter table public.attendance_statuses add column if not exists grants_makeup boolean not null default false;

alter table public.attendance_statuses drop constraint if exists attendance_statuses_grants_makeup_check;
alter table public.attendance_statuses add constraint attendance_statuses_grants_makeup_check
  check (not grants_makeup or (deducts_lesson and not is_present));

comment on column public.attendance_statuses.grants_makeup is
  'Статус даёт право на отработку (0105): только списывающий и без присутствия — отработка за оплаченный пропуск.';

grant update (code, name, color, deducts_lesson, pays_teacher, counts_absence, notify_parent, sort, grants_makeup)
  on public.attendance_statuses to authenticated;

-- Засевается в архив (ревью п.7): при выключенных отработках статус не
-- виден в панели отметки — иначе специалист выбрал бы его вместо «Прогула»
-- (занятие списано, права нет). Включение отработок его достаёт.
insert into public.attendance_statuses
  (center_id, code, name, color, deducts_lesson, pays_teacher, counts_absence, notify_parent, is_default, sort, is_present, grants_makeup, deleted_at)
select c.id, 'absent_makeup', 'Пропуск с отработкой', 'slate', true, false, true, false, false, 35, false, true, now()
  from public.centers c
on conflict do nothing;

create or replace function public.seed_attendance_statuses(p_center_id uuid)
  returns void
  language sql
  security definer
  set search_path = ''
as $$
  insert into public.attendance_statuses
    (center_id, code, name, color, deducts_lesson, pays_teacher, counts_absence, notify_parent, is_default, sort, is_present, grants_makeup, deleted_at)
  values
    (p_center_id, 'present',       'Пришёл',               'green', true,  true,  false, false, true,  10, true,  false, null),
    (p_center_id, 'late',          'Опоздал',              'amber', true,  true,  false, false, false, 20, true,  false, null),
    (p_center_id, 'sick',          'Болел',                'sky',   false, false, true,  false, false, 30, false, false, null),
    (p_center_id, 'absent_makeup', 'Пропуск с отработкой', 'slate', true,  false, true,  false, false, 35, false, true,  now()),
    (p_center_id, 'absent',        'Прогул',               'rose',  true,  true,  true,  false, false, 40, false, false, null)
  on conflict do nothing;
$$;

revoke all on function public.seed_attendance_statuses(uuid) from public, anon, authenticated, service_role;


-- 2. Таблицы ---------------------------------------------------------------------------------------

create table if not exists public.makeup_policies (
  id                     uuid primary key default gen_random_uuid(),
  center_id              uuid not null default public.current_center()
                           references public.centers (id) on delete cascade,
  valid_days             integer not null check (valid_days between 1 and 365),
  per_subscription_limit integer check (per_subscription_limit is null or per_subscription_limit between 1 and 100),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid default auth.uid(),
  disabled_at            timestamptz
);

comment on table public.makeup_policies is
  'Политика отработок центра (0105 Р1): живая строка (disabled_at is null) — отработки включены. Пишет только set_makeup_policy.';

create unique index if not exists makeup_policies_live_key
  on public.makeup_policies (center_id) where disabled_at is null;
create index if not exists makeup_policies_center_idx on public.makeup_policies (center_id);

create table if not exists public.makeup_credits (
  id                   uuid primary key default gen_random_uuid(),
  center_id            uuid not null references public.centers (id) on delete cascade,
  student_id           uuid not null,
  source_attendance_id uuid not null,
  service_id           uuid,
  subscription_id      uuid,
  price_tiyin          integer not null default 0 check (price_tiyin >= 0),
  missed_on            date not null,
  expires_on           date not null,
  used_attendance_id   uuid,
  cancelled_at         timestamptz,
  cancel_reason        text check (cancel_reason in ('status_changed', 'lesson_cancelled', 'student_archived')),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint makeup_credits_id_center_key unique (id, center_id),
  constraint makeup_credits_cancel_shape check ((cancelled_at is null) = (cancel_reason is null)),
  constraint makeup_credits_used_not_cancelled check (used_attendance_id is null or cancelled_at is null),
  constraint makeup_credits_expiry check (expires_on >= missed_on),
  constraint makeup_credits_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade,
  constraint makeup_credits_source_fk
    foreign key (source_attendance_id, center_id) references public.attendance (id, center_id),
  constraint makeup_credits_used_fk
    foreign key (used_attendance_id, center_id) references public.attendance (id, center_id)
);

comment on table public.makeup_credits is
  'Право на отработку (0105 Р3): выдаёт и отменяет триггер на attendance; использует отметка на отработке. Сгорание — при чтении (expires_on < сегодня центра).';

create unique index if not exists makeup_credits_source_live_key
  on public.makeup_credits (source_attendance_id) where cancelled_at is null;
create unique index if not exists makeup_credits_used_key
  on public.makeup_credits (used_attendance_id) where used_attendance_id is not null;
create index if not exists makeup_credits_source_idx on public.makeup_credits (source_attendance_id, center_id);
create index if not exists makeup_credits_used_idx on public.makeup_credits (used_attendance_id, center_id);
create index if not exists makeup_credits_student_idx on public.makeup_credits (student_id, center_id);
create index if not exists makeup_credits_subscription_idx on public.makeup_credits (subscription_id) where subscription_id is not null;
create index if not exists makeup_credits_center_idx on public.makeup_credits (center_id);

create table if not exists public.makeup_bookings (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null references public.centers (id) on delete cascade,
  credit_id     uuid not null,
  lesson_id     uuid not null,
  student_id    uuid not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  closed_at     timestamptz,
  closed_reason text check (closed_reason in ('cancelled', 'lesson_changed', 'source_changed', 'student_archived', 'joined_group')),

  constraint makeup_bookings_close_shape check ((closed_at is null) = (closed_reason is null)),
  constraint makeup_bookings_credit_fk
    foreign key (credit_id, center_id) references public.makeup_credits (id, center_id) on delete cascade,
  constraint makeup_bookings_lesson_fk
    foreign key (lesson_id, center_id) references public.lessons (id, center_id) on delete cascade,
  constraint makeup_bookings_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade
);

comment on table public.makeup_bookings is
  'Запись на отработку (0105 Р4): одна живая запись на право и одна на (занятие, ученик). Пишут book_makeup, cancel_makeup_booking и триггеры.';

create unique index if not exists makeup_bookings_credit_live_key
  on public.makeup_bookings (credit_id) where closed_at is null;
create unique index if not exists makeup_bookings_lesson_student_live_key
  on public.makeup_bookings (lesson_id, student_id) where closed_at is null;
create index if not exists makeup_bookings_credit_idx on public.makeup_bookings (credit_id, center_id);
create index if not exists makeup_bookings_lesson_idx on public.makeup_bookings (lesson_id, center_id);
create index if not exists makeup_bookings_student_idx on public.makeup_bookings (student_id, center_id);
create index if not exists makeup_bookings_center_idx on public.makeup_bookings (center_id);

-- attendance.makeup_credit_id — признак отметки на отработке (Р8).
alter table public.attendance add column if not exists makeup_credit_id uuid;
alter table public.attendance drop constraint if exists attendance_makeup_credit_fk;
alter table public.attendance add constraint attendance_makeup_credit_fk
  foreign key (makeup_credit_id, center_id) references public.makeup_credits (id, center_id);
create index if not exists attendance_makeup_credit_idx on public.attendance (makeup_credit_id, center_id);

-- lesson_participants.via_makeup — строка состава из записи на отработку (Р7).
alter table public.lesson_participants add column if not exists via_makeup boolean not null default false;

do $$
declare
  t text;
begin
  foreach t in array array['makeup_policies', 'makeup_credits', 'makeup_bookings'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_set_updated_at', t);
    execute format('create trigger %I before update on public.%I for each row execute function extensions.moddatetime(updated_at)',
                   t || '_set_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated, service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    call public.apply_audit(t);
    call public.apply_readonly_guard(t);
  end loop;
end;
$$;

-- Р11: читать — стойка (owner/admin/registrar); писать — только функции.
drop policy if exists makeup_policies_select on public.makeup_policies;
create policy makeup_policies_select on public.makeup_policies
  for select to authenticated using (center_id = public.current_center() and public.can_front_desk(center_id));
drop policy if exists makeup_credits_select on public.makeup_credits;
create policy makeup_credits_select on public.makeup_credits
  for select to authenticated using (center_id = public.current_center() and public.can_front_desk(center_id));
drop policy if exists makeup_bookings_select on public.makeup_bookings;
create policy makeup_bookings_select on public.makeup_bookings
  for select to authenticated using (center_id = public.current_center() and public.can_front_desk(center_id));


-- 3. Выдача, отмена и использование права — AFTER-триггер на attendance (Р3, Р8) -----------------

create or replace function public.makeup_policy_live(p_center uuid)
  returns public.makeup_policies
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select * from public.makeup_policies p where p.center_id = p_center and p.disabled_at is null;
$$;

revoke all on function public.makeup_policy_live(uuid) from public, anon, authenticated, service_role;

create or replace function public.attendance_makeup_sync()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_status  public.attendance_statuses;
  v_credit  public.makeup_credits;
  v_policy  public.makeup_policies;
  v_lesson  public.lessons;
  v_day     date;
  v_count   integer;
begin
  if tg_op = 'UPDATE' and new.status_id is not distinct from old.status_id then
    return null;
  end if;

  select * into v_status from public.attendance_statuses where id = new.status_id;

  -- Отметка на отработке (Р13): любая отметка расходует право — не пришёл,
  -- отработка сгорела. Нового права не выдаёт никогда.
  if new.makeup_credit_id is not null then
    select * into v_credit from public.makeup_credits where id = new.makeup_credit_id for update;
    if v_credit.used_attendance_id is null and v_credit.cancelled_at is null then
      update public.makeup_credits set used_attendance_id = new.id where id = v_credit.id;
    end if;
    return null;
  end if;

  select * into v_credit from public.makeup_credits
   where source_attendance_id = new.id and cancelled_at is null
   for update;

  if coalesce(v_status.grants_makeup, false) then
    if v_credit.id is not null then
      return null;
    end if;
    -- Р14: отработка — за оплаченный пропуск; в долг (без абонемента) права нет.
    if new.subscription_id is null then
      return null;
    end if;
    v_policy := public.makeup_policy_live(new.center_id);
    if v_policy.id is null then
      return null;
    end if;

    -- Лимит на абонемент (Р3): блокировка абонемента, потом подсчёт. В счёт
    -- идут живые, использованные и сгоревшие; отменённые — нет. Превышение —
    -- право молча не выдаётся, отметка не падает.
    if v_policy.per_subscription_limit is not null then
      perform 1 from public.subscriptions s where s.id = new.subscription_id for update;
      select count(*) into v_count from public.makeup_credits c
       where c.subscription_id = new.subscription_id and c.cancelled_at is null;
      if v_count >= v_policy.per_subscription_limit then
        return null;
      end if;
    end if;

    select * into v_lesson from public.lessons where id = new.lesson_id;
    v_day := (v_lesson.starts_at at time zone public.center_timezone(new.center_id))::date;

    insert into public.makeup_credits
      (center_id, student_id, source_attendance_id, service_id, subscription_id, price_tiyin, missed_on, expires_on)
    values
      (new.center_id, new.student_id, new.id, v_lesson.service_id, new.subscription_id,
       coalesce(new.price_tiyin, 0), v_day, v_day + v_policy.valid_days);
    return null;
  end if;

  -- Статус перестал давать право.
  if v_credit.id is not null then
    if v_credit.used_attendance_id is not null then
      raise exception 'По этому пропуску уже прошла отработка — сначала измените отметку на отработке'
        using errcode = '22023';
    end if;
    -- Записи закрывает makeup_credits_cancel (Р13).
    update public.makeup_credits
       set cancelled_at = now(), cancel_reason = 'status_changed'
     where id = v_credit.id;
  end if;
  return null;
end;
$$;

revoke all on function public.attendance_makeup_sync() from public, anon, authenticated, service_role;

drop trigger if exists attendance_makeup_sync on public.attendance;
create trigger attendance_makeup_sync
  after insert or update of status_id on public.attendance
  for each row execute function public.attendance_makeup_sync();

-- Р9: отметку, на которую ссылается право, не удалить. Каскад удаления центра
-- (RI-триггер, глубина > 1) — пропуск.
create or replace function public.attendance_makeup_delete_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if pg_trigger_depth() > 1 then
    return old;
  end if;
  if old.makeup_credit_id is not null
     or exists (select 1 from public.makeup_credits c
                 where c.source_attendance_id = old.id or c.used_attendance_id = old.id) then
    raise exception 'По этой отметке есть отработка — удалить её нельзя, измените статус'
      using errcode = '22023';
  end if;
  return old;
end;
$$;

revoke all on function public.attendance_makeup_delete_guard() from public, anon, authenticated, service_role;

drop trigger if exists attendance_makeup_delete_guard on public.attendance;
create trigger attendance_makeup_delete_guard
  before delete on public.attendance
  for each row execute function public.attendance_makeup_delete_guard();


-- Р13: одно место отмены права — под уже взятой блокировкой строки права.
create or replace function public.makeup_credits_cancel()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.cancelled_at is null or old.cancelled_at is not null then
    return new;
  end if;
  if old.used_attendance_id is not null
     or exists (select 1 from public.attendance a where a.makeup_credit_id = new.id) then
    raise exception 'По этой отработке уже есть отметка — отменить её нельзя' using errcode = '22023';
  end if;
  update public.makeup_bookings
     set closed_at = now(),
         closed_reason = case when new.cancel_reason = 'student_archived' then 'student_archived' else 'source_changed' end
   where credit_id = new.id and closed_at is null;
  return new;
end;
$$;

revoke all on function public.makeup_credits_cancel() from public, anon, authenticated, service_role;

drop trigger if exists makeup_credits_cancel on public.makeup_credits;
create trigger makeup_credits_cancel
  before update of cancelled_at on public.makeup_credits
  for each row execute function public.makeup_credits_cancel();


-- 4. Запись на отработку — совместимость права и занятия (Р4) -------------------------------------

create or replace function public.makeup_bookings_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_credit public.makeup_credits;
  v_lesson public.lessons;
  v_day    date;
  v_max    integer;
  v_taken  integer;
begin
  if tg_op = 'UPDATE' then
    -- Обновлять можно только закрытие живой записи.
    if old.closed_at is not null
       or new.credit_id is distinct from old.credit_id
       or new.lesson_id is distinct from old.lesson_id
       or new.student_id is distinct from old.student_id
       or new.center_id is distinct from old.center_id
       or new.closed_at is null then
      raise exception 'Запись на отработку можно только закрыть' using errcode = '22023';
    end if;
    return new;
  end if;

  select * into v_credit from public.makeup_credits where id = new.credit_id for update;
  if not found then
    raise exception 'Отработка не найдена' using errcode = '42704';
  end if;
  new.center_id  := v_credit.center_id;
  new.student_id := v_credit.student_id;

  if v_credit.cancelled_at is not null or v_credit.used_attendance_id is not null then
    raise exception 'Эта отработка уже использована или отменена' using errcode = '22023';
  end if;
  if exists (select 1 from public.makeup_bookings b where b.credit_id = v_credit.id and b.closed_at is null) then
    raise exception 'Эта отработка уже записана на занятие' using errcode = '22023';
  end if;
  if v_credit.expires_on < public.center_today(v_credit.center_id) then
    raise exception 'Срок отработки истёк %', to_char(v_credit.expires_on, 'DD.MM.YYYY') using errcode = '22023';
  end if;

  -- Блокировка строки занятия: две записи на последнее место не пройдут обе.
  select * into v_lesson from public.lessons where id = new.lesson_id and center_id = v_credit.center_id for update;
  if not found or v_lesson.deleted_at is not null then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;
  if v_lesson.status = 'cancelled' then
    raise exception 'Занятие отменено' using errcode = '22023';
  end if;
  if v_lesson.starts_at <= now() then
    raise exception 'На отработку записывают только на будущее занятие' using errcode = '22023';
  end if;
  v_day := (v_lesson.starts_at at time zone public.center_timezone(v_credit.center_id))::date;
  if v_day < v_credit.missed_on or v_day > v_credit.expires_on then
    raise exception 'Занятие вне срока отработки: с % по %',
      to_char(v_credit.missed_on, 'DD.MM.YYYY'), to_char(v_credit.expires_on, 'DD.MM.YYYY')
      using errcode = '22023';
  end if;
  if v_lesson.service_id is distinct from v_credit.service_id then
    raise exception 'Отработка — только на занятие той же услуги' using errcode = '22023';
  end if;

  if v_lesson.student_id is not null then
    if v_lesson.student_id <> v_credit.student_id then
      raise exception 'Это индивидуальное занятие другого ученика' using errcode = '22023';
    end if;
  else
    if exists (select 1 from public.lesson_participants p
                where p.lesson_id = v_lesson.id and p.student_id = v_credit.student_id
                  and p.deleted_at is null and not p.via_makeup) then
      raise exception 'Ученик и так в составе этого занятия' using errcode = '22023';
    end if;
    select g.max_students into v_max from public.groups g where g.id = v_lesson.group_id;
    if v_max is not null then
      select (select count(*) from public.lesson_participants p
               where p.lesson_id = v_lesson.id and p.deleted_at is null and not p.via_makeup)
           + (select count(*) from public.makeup_bookings b
               where b.lesson_id = v_lesson.id and b.closed_at is null)
        into v_taken;
      if v_taken >= v_max then
        raise exception 'В группе нет свободных мест' using errcode = '22023';
      end if;
    end if;
  end if;

  if exists (select 1 from public.attendance a where a.lesson_id = v_lesson.id and a.student_id = v_credit.student_id) then
    raise exception 'По этому занятию у ученика уже есть отметка' using errcode = '22023';
  end if;

  return new;
end;
$$;

revoke all on function public.makeup_bookings_guard() from public, anon, authenticated, service_role;

drop trigger if exists makeup_bookings_guard on public.makeup_bookings;
create trigger makeup_bookings_guard
  before insert or update on public.makeup_bookings
  for each row execute function public.makeup_bookings_guard();

-- Состав занятия-цели пересобирается при записи и закрытии записи.
create or replace function public.makeup_bookings_rebuild()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform public.rebuild_lesson_participants(new.lesson_id);
  return null;
end;
$$;

revoke all on function public.makeup_bookings_rebuild() from public, anon, authenticated, service_role;

drop trigger if exists makeup_bookings_rebuild on public.makeup_bookings;
create trigger makeup_bookings_rebuild
  after insert or update of closed_at on public.makeup_bookings
  for each row execute function public.makeup_bookings_rebuild();


-- 5. Изменения занятий и архив ученика (Р5, Р6) ---------------------------------------------------

create or replace function public.lessons_makeup_sync()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_gone boolean := (new.status = 'cancelled' and old.status is distinct from 'cancelled')
                 or (new.deleted_at is not null and old.deleted_at is null);
begin
  if not (v_gone
          or new.starts_at is distinct from old.starts_at
          or new.ends_at is distinct from old.ends_at
          or new.service_id is distinct from old.service_id
          or new.group_id is distinct from old.group_id
          or new.student_id is distinct from old.student_id) then
    return new;
  end if;

  -- Порядок блокировок (ревью п.2): сначала права, потом записи — как в
  -- book_makeup, cancel_makeup_booking и отметке. Иначе взаимная блокировка.
  perform 1 from public.makeup_credits c
   where c.id in (select b.credit_id from public.makeup_bookings b where b.lesson_id = new.id and b.closed_at is null)
      or c.source_attendance_id in (select a.id from public.attendance a where a.lesson_id = new.id)
   order by c.id
   for update;

  if v_gone then
    -- Исходное занятие с уже пройденной отработкой отменить нельзя (Р16):
    -- списание пропуска вернётся, а отработка была бесплатной.
    if exists (select 1 from public.makeup_credits c
                 join public.attendance a on a.id = c.source_attendance_id
                where a.lesson_id = new.id and c.used_attendance_id is not null and c.cancelled_at is null) then
      raise exception 'По пропуску на этом занятии уже прошла отработка — сначала отмените её' using errcode = '22023';
    end if;
    -- Занятие-цель: отметки на отработке не списывали — право снова доступно.
    update public.makeup_credits c
       set used_attendance_id = null
      from public.attendance a
     where a.lesson_id = new.id and c.used_attendance_id = a.id;
    update public.makeup_bookings b
       set closed_at = now(), closed_reason = 'lesson_changed'
     where b.lesson_id = new.id and b.closed_at is null;
    -- Исходное занятие: пропуска не было — неиспользованное право отменяется
    -- (записи закрывает makeup_credits_cancel).
    update public.makeup_credits c
       set cancelled_at = now(), cancel_reason = 'lesson_cancelled'
      from public.attendance a
     where a.id = c.source_attendance_id and a.lesson_id = new.id
       and c.cancelled_at is null and c.used_attendance_id is null;
    return new;
  end if;

  -- Перенос, смена услуги, группы или ученика — закрыть неотмеченные записи
  -- (право снова доступно). До пересборки состава (AFTER lessons_sync_participants).
  update public.makeup_bookings b
     set closed_at = now(), closed_reason = 'lesson_changed'
   where b.lesson_id = new.id and b.closed_at is null
     and not exists (select 1 from public.attendance a
                      where a.lesson_id = b.lesson_id and a.student_id = b.student_id);
  return new;
end;
$$;

revoke all on function public.lessons_makeup_sync() from public, anon, authenticated, service_role;

drop trigger if exists lessons_makeup_sync on public.lessons;
create trigger lessons_makeup_sync
  before update of starts_at, ends_at, status, deleted_at, service_id, group_id, student_id on public.lessons
  for each row execute function public.lessons_makeup_sync();

create or replace function public.students_makeup_archive()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    -- Права — под блокировку первыми; записи закрывает makeup_credits_cancel.
    perform 1 from public.makeup_credits c
     where c.student_id = new.id and c.cancelled_at is null and c.used_attendance_id is null
     order by c.id
     for update;
    update public.makeup_credits c
       set cancelled_at = now(), cancel_reason = 'student_archived'
     where c.student_id = new.id and c.cancelled_at is null and c.used_attendance_id is null
       and not exists (select 1 from public.attendance a where a.makeup_credit_id = c.id);
  end if;
  return null;
end;
$$;

revoke all on function public.students_makeup_archive() from public, anon, authenticated, service_role;

drop trigger if exists students_makeup_archive on public.students;
create trigger students_makeup_archive
  after update of deleted_at on public.students
  for each row execute function public.students_makeup_archive();


-- Р16: ребёнок вступил в группу — его записи на отработку в её занятиях
-- закрываются (он теперь свой участник; иначе место считалось бы дважды, а
-- отметка своего занятия сожгла бы право). Имя сортируется раньше
-- group_students_sync_participants: закрытие — до пересборки состава.
create or replace function public.group_students_makeup_close()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.deleted_at is not null then
    return null;
  end if;
  perform 1 from public.makeup_credits c
   where c.id in (select b.credit_id from public.makeup_bookings b
                    join public.lessons l on l.id = b.lesson_id
                   where b.student_id = new.student_id and b.closed_at is null and l.group_id = new.group_id)
   order by c.id
   for update;
  update public.makeup_bookings b
     set closed_at = now(), closed_reason = 'joined_group'
    from public.lessons l
   where l.id = b.lesson_id
     and b.student_id = new.student_id and b.closed_at is null
     and l.group_id = new.group_id
     and l.starts_at::date >= new.joined_at
     and (new.left_at is null or new.left_at > l.starts_at::date)
     and not exists (select 1 from public.attendance a where a.lesson_id = b.lesson_id and a.student_id = b.student_id);
  return null;
end;
$$;

revoke all on function public.group_students_makeup_close() from public, anon, authenticated, service_role;

drop trigger if exists group_students_makeup_close on public.group_students;
create trigger group_students_makeup_close
  after insert or update of joined_at, left_at, deleted_at on public.group_students
  for each row execute function public.group_students_makeup_close();


-- 7. Перевыпуск: состав занятия, клиника, отметка, метка панели (Р7, Р8, Р10) ---------------------

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
  if pg_trigger_depth() = 0 then
    raise exception 'rebuild_lesson_participants вызывается только из триггера'
      using errcode = '42501';
  end if;

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

    -- 0105: живые записи на отработку тоже в составе, с признаком via_makeup.
    -- Ребёнок, уже вошедший в состав как свой, второй строкой не добавляется
    -- (иначе дубль первичного ключа).
    insert into public.lesson_participants
      (lesson_id, student_id, center_id, starts_at, ends_at, status, deleted_at, via_makeup)
    select distinct v_lesson.id, b.student_id, v_lesson.center_id,
           v_lesson.starts_at, v_lesson.ends_at, v_lesson.status, v_lesson.deleted_at, true
      from public.makeup_bookings b
     where b.lesson_id = v_lesson.id
       and b.closed_at is null
       and not exists (
         select 1 from public.lesson_participants p
          where p.lesson_id = v_lesson.id and p.student_id = b.student_id
       );

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
               limit 1),
             -- 0105: записанный на отработку — тоже по имени, не «из этой группы».
             (select b.student_id
                from public.makeup_bookings b
                join public.lesson_participants lp on lp.student_id = b.student_id
               where b.lesson_id = v_lesson.id and b.closed_at is null
                 and lp.deleted_at is null and lp.lesson_id <> v_lesson.id
                 and tstzrange(lp.starts_at, lp.ends_at) && tstzrange(v_lesson.starts_at, v_lesson.ends_at)
               limit 1));

    raise exception 'У ученика % уже есть занятие в это время',
      coalesce(v_name, 'из этой группы') using errcode = '23P01';
  end;
end;
$$;

revoke execute on function public.rebuild_lesson_participants(uuid) from public, anon, authenticated;

create or replace function public.clinical_teacher_taught(p_teacher_id uuid, p_student_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select p_teacher_id is not null
     and exists (
       select 1
         from public.teachers t
         join public.students s on s.center_id = t.center_id
         join public.lesson_participants lp on lp.student_id = s.id
         join public.lessons l on l.id = lp.lesson_id
        where t.id = p_teacher_id
          and s.id = p_student_id
          and lp.deleted_at is null
          -- 0105 (ADR-005): запись на отработку в чужую группу не открывает клинику.
          and not lp.via_makeup
          and l.deleted_at is null
          and l.status <> 'cancelled'
          and (l.teacher_id = p_teacher_id or l.substitute_teacher_id = p_teacher_id)
     );
$$;

revoke all on function public.clinical_teacher_taught(uuid, uuid) from public, anon, authenticated, service_role;

create or replace function public.attendance_fill_and_check()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_lesson                public.lessons;
  v_status                public.attendance_statuses;
  v_sub                    public.subscriptions;
  v_cand                   uuid;
  v_cand_frozen_at_select  boolean;
  v_cand_frozen_now        boolean;
  v_lesson_date            date;
  v_price                  integer;
  v_keys_changed           boolean := false;
  v_status_changed         boolean := false;
  v_student_name           text;
  v_freeze_period          daterange;
begin
  if tg_op = 'UPDATE' then
    v_keys_changed   := new.lesson_id is distinct from old.lesson_id
                     or new.student_id is distinct from old.student_id;
    v_status_changed := new.status_id is distinct from old.status_id;
  end if;

  select * into v_lesson from public.lessons where id = new.lesson_id;
  if not found or v_lesson.deleted_at is not null then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;
  v_lesson_date := (v_lesson.starts_at at time zone public.center_timezone(new.center_id))::date;

  if tg_op = 'INSERT' or v_keys_changed then
    if v_lesson.status = 'cancelled' then
      raise exception 'Занятие отменено — отметить посещение нельзя' using errcode = '22023';
    end if;
    if v_lesson.starts_at > now() then
      raise exception 'Занятие ещё не началось' using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.lesson_participants p
       where p.lesson_id = new.lesson_id and p.student_id = new.student_id
    ) then
      raise exception 'Этот ребёнок не участник занятия' using errcode = '22023';
    end if;
  end if;

  if tg_op = 'UPDATE' then
    new.marked_by       := old.marked_by;
    new.subscription_id := old.subscription_id;
    new.price_tiyin     := old.price_tiyin;
    new.deducted        := old.deducted;
    new.counts_absence  := old.counts_absence;
    new.pays_teacher    := old.pays_teacher;     -- 0017: симметрия с deducted/counts_absence на раннем выходе;
                                                  -- при смене статуса ниже перезапишется из v_status
    new.paid_teacher_id := old.paid_teacher_id;  -- 0017: заморожен один раз, как subscription_id/price_tiyin
    new.is_present       := old.is_present;       -- 0055: та же ранняя симметрия
    new.makeup_credit_id := old.makeup_credit_id; -- 0105 Б2: признак отработки заморожен, как subscription_id
    if not v_status_changed and not v_keys_changed then
      new.marked_at := old.marked_at;
      return new;
    end if;
  else
    new.marked_by       := coalesce(auth.uid(), new.marked_by);
    new.subscription_id := null;
    new.price_tiyin     := 0;
    new.paid_teacher_id := coalesce(v_lesson.substitute_teacher_id, v_lesson.teacher_id);  -- 0017
    -- 0105: отметка ученика, записанного на отработку, — признак из живой
    -- записи; клиентское значение перетирается (прямой insert у owner/admin).
    select b.credit_id into new.makeup_credit_id
      from public.makeup_bookings b
     where b.lesson_id = new.lesson_id and b.student_id = new.student_id and b.closed_at is null;
  end if;
  new.marked_at := now();

  select * into v_status from public.attendance_statuses
   where id = new.status_id and center_id = new.center_id and deleted_at is null;
  if not found then
    raise exception 'Статус посещения не найден' using errcode = '42704';
  end if;
  new.deducted       := v_status.deducts_lesson;
  new.counts_absence := v_status.counts_absence;
  new.pays_teacher    := v_status.pays_teacher;  -- 0017: следует за статусом при КАЖДОЙ смене, не морозится —
                                                  -- как deducted/counts_absence, а не как subscription_id/
                                                  -- price_tiyin. Круг "пришёл → болел → пришёл" обязан вернуть
                                                  -- pays_teacher к true, иначе специалисту не заплатят за
                                                  -- занятие, которое в итоге состоялось.
  new.is_present      := v_status.is_present;    -- 0055 Р2: та же логика — следует за статусом при каждой смене.

  -- 0105 Р15: статус с правом на отработку при выключенных отработках
  -- списал бы занятие без права — отказ, а не тихий «прогул без оплаты».
  if v_status.grants_makeup and public.makeup_policy_live(new.center_id) is null then
    raise exception 'Отработки выключены в настройках центра — выберите другой статус' using errcode = '22023';
  end if;

  if new.makeup_credit_id is not null then
    -- 0105: отработка не списывает с абонемента при любом статусе; цена —
    -- снимок цены пропущенного занятия: процентная ставка специалиста не ноль,
    -- а выручка, долг и остатки смотрят только списанные отметки.
    new.deducted        := false;
    new.subscription_id := null;
    select coalesce(c.price_tiyin, 0) into new.price_tiyin
      from public.makeup_credits c where c.id = new.makeup_credit_id;
    new.price_tiyin := coalesce(new.price_tiyin, 0);
  elsif new.deducted and new.subscription_id is null then
    -- 0103: одна копия правила выбора — та же функция даёт прогноз панели
    -- отметки (lesson_attendance_balances).
    select p.id, p.is_frozen into v_cand, v_cand_frozen_at_select
      from public.attendance_pick_subscription_unchecked(
             new.center_id, new.student_id, v_lesson.service_id, v_lesson_date) p;

    if v_cand is not null then
      select * into v_sub from public.subscriptions s where s.id = v_cand for update;
      if not found then
        raise exception 'Абонемент изменился во время отметки — повторите'
          using errcode = '40001';
      end if;

      if v_sub.deleted_at is not null
         or v_sub.status = 'cancelled'
         or not (v_sub.allow_negative
                 or v_sub.lessons_total is null
                 or v_sub.lessons_total - v_sub.lessons_used - v_sub.lessons_written_off > 0)
      then
        raise exception 'Абонемент изменился во время отметки — повторите'
          using errcode = '40001';
      end if;

      v_cand_frozen_now := exists (
        select 1 from public.subscription_freezes f
         where f.subscription_id = v_sub.id and f.period @> v_lesson_date);

      if v_cand_frozen_now then
        if v_cand_frozen_at_select then
          if exists (
            select 1 from public.attendance_subscription_candidates_unchecked(
                     new.center_id, new.student_id, v_lesson.service_id, v_lesson_date) c2
             where c2.id <> v_sub.id and not c2.is_frozen
          ) then
            raise exception 'Абонемент изменился во время отметки — повторите'
              using errcode = '40001';
          end if;

          select full_name into v_student_name from public.students where id = new.student_id;
          select f.period into v_freeze_period from public.subscription_freezes f
           where f.subscription_id = v_sub.id and f.period @> v_lesson_date
           order by lower(f.period) desc limit 1;

          if upper_inf(v_freeze_period) then
            raise exception '%: абонемент заморожен с % — отметить посещение нельзя, пока не разморозят',
              v_student_name, to_char(lower(v_freeze_period), 'DD.MM.YYYY')
              using errcode = '22023';
          else
            raise exception '%: абонемент заморожен по % — отметить посещение можно после этой даты',
              v_student_name, to_char(upper(v_freeze_period) - 1, 'DD.MM.YYYY')
              using errcode = '22023';
          end if;
        else
          raise exception 'Абонемент изменился во время отметки — повторите'
            using errcode = '40001';
        end if;
      end if;

      new.subscription_id := v_sub.id;
      new.price_tiyin     := coalesce(v_sub.lesson_price_tiyin, 0);
    else
      select sv.default_price_tiyin into v_price from public.services sv
       where sv.id = v_lesson.service_id;
      new.price_tiyin := coalesce(v_price, 0);
    end if;
  elsif tg_op = 'INSERT' then
    select sv.default_price_tiyin into v_price from public.services sv
     where sv.id = v_lesson.service_id;
    new.price_tiyin := coalesce(v_price, 0);
  end if;

  return new;
end;
$$;

revoke all on function public.attendance_fill_and_check() from public, anon, authenticated, service_role;

create or replace function public.lesson_attendance_balances(p_lesson_id uuid)
  returns table (student_id uuid, kind text, lessons_left integer, price_tiyin integer, numbers boolean)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid := public.current_center();
  v_role     text := coalesce(public.my_role(), '');
  v_lesson   public.lessons;
  v_day      date;
  v_numbers  boolean;
  v_price    integer;
  r          record;
  v_sub      public.subscriptions;
  v_pick     uuid;
  v_frozen   boolean;
  v_left     integer;
  v_kind     text;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_lesson from public.lessons l
   where l.id = p_lesson_id and l.center_id = v_center and l.deleted_at is null;
  if not found then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;

  v_numbers := public.can_front_desk(v_center);
  if not (v_numbers or (v_role = 'teacher' and public.teacher_of_lesson(p_lesson_id))) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_day := (v_lesson.starts_at at time zone public.center_timezone(v_center))::date;
  select sv.default_price_tiyin into v_price from public.services sv where sv.id = v_lesson.service_id;

  for r in
    select k.student_id, a.subscription_id, a.deducted, a.price_tiyin, a.id as attendance_id,
           coalesce(a.makeup_credit_id, (
             select b.credit_id from public.makeup_bookings b
              where b.lesson_id = p_lesson_id and b.student_id = k.student_id and b.closed_at is null
           )) as makeup_credit_id
      from (
        select p.student_id from public.lesson_participants p
         where p.lesson_id = p_lesson_id and p.deleted_at is null
        union
        select a2.student_id from public.attendance a2
         where a2.lesson_id = p_lesson_id
      ) k
      left join public.attendance a
        on a.lesson_id = p_lesson_id and a.student_id = k.student_id
  loop
    v_kind := null;
    v_left := null;
    v_sub  := null;

    if r.makeup_credit_id is not null then
      -- 0105: отработка — раньше всех веток, числа не показываем.
      v_kind := 'makeup';
    elsif r.subscription_id is not null then
      select * into v_sub from public.subscriptions s where s.id = r.subscription_id;
      -- Не списывающий статус с абонементом в отметке: обратная смена на
      -- «Пришёл» спишет с этого же абонемента без нового выбора и без
      -- проверки заморозки (0055) — показываем его остаток, не прогноз.
      if r.deducted then v_kind := 'charged'; end if;
    elsif r.deducted then
      if r.price_tiyin = 0 then
        v_kind := 'free';
      elsif exists (select 1 from public.lesson_debt_covers c
                     where c.attendance_id = r.attendance_id and c.deleted_at is null) then
        v_kind := 'covered';
      else
        v_kind := 'debt';
      end if;
    else
      select p.id, p.is_frozen into v_pick, v_frozen
        from public.attendance_pick_subscription_unchecked(
               v_center, r.student_id, v_lesson.service_id, v_day) p;
      if v_pick is null then
        v_kind := case when v_lesson.service_id is null then 'no_service'
                       when coalesce(v_price, 0) = 0 then 'free'
                       else 'no_subscription' end;
      elsif v_frozen then
        v_kind := 'frozen';
      else
        select * into v_sub from public.subscriptions s where s.id = v_pick;
      end if;
      v_pick := null;
    end if;

    if v_sub.id is not null then
      v_left := case when v_sub.lessons_total is null then null
                     else v_sub.lessons_total - v_sub.lessons_used - v_sub.lessons_written_off end;
      if v_kind is null then
        v_kind := case
          when v_left is null or v_left > 2 then 'subscription'
          when v_left > 0 then 'subscription_low'
          else 'subscription_empty'
        end;
      end if;
    end if;

    student_id   := r.student_id;
    kind         := v_kind;
    lessons_left := case when v_numbers and v_kind in ('charged', 'subscription', 'subscription_low', 'subscription_empty')
                         then v_left end;
    price_tiyin  := case when v_numbers and v_kind = 'no_subscription' then coalesce(v_price, 0) end;
    numbers      := v_numbers;
    return next;
  end loop;
end;
$$;

comment on function public.lesson_attendance_balances(uuid) is
  'Метка панели отметки: по каждому ребёнку занятия — с какого абонемента спишется (или списалось) занятие с учётом услуги и даты занятия, либо долг; 0105 — вид makeup для записанных и отмеченных на отработке. Числа — только стойке.';

revoke all on function public.lesson_attendance_balances(uuid) from public, anon;
grant execute on function public.lesson_attendance_balances(uuid) to authenticated;

-- 6. RPC ------------------------------------------------------------------------------------------

-- Политика (Р1): owner/admin. p_valid_days null — выключить.
create or replace function public.set_makeup_policy(p_valid_days integer, p_limit integer default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_live   public.makeup_policies;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Отработки настраивают владелец и администратор' using errcode = '42501';
  end if;
  if not public.center_writable(v_center) then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  if p_valid_days is not null and (p_valid_days < 1 or p_valid_days > 365) then
    raise exception 'Срок отработки — от 1 до 365 дней' using errcode = '22023';
  end if;
  if p_limit is not null and (p_limit < 1 or p_limit > 100) then
    raise exception 'Лимит отработок на абонемент — от 1 до 100' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('makeup_policy:' || v_center::text, 0));
  select * into v_live from public.makeup_policies where center_id = v_center and disabled_at is null;

  if p_valid_days is null then
    update public.makeup_policies set disabled_at = now() where id = v_live.id;
    return;
  end if;
  if v_live.id is not null then
    if v_live.valid_days = p_valid_days and v_live.per_subscription_limit is not distinct from p_limit then
      return;
    end if;
    update public.makeup_policies set disabled_at = now() where id = v_live.id;
  end if;
  insert into public.makeup_policies (center_id, valid_days, per_subscription_limit)
  values (v_center, p_valid_days, p_limit);
  -- Р15: включение отработок достаёт засеянный в архив «Пропуск с отработкой».
  if v_live.id is null then
    update public.attendance_statuses
       set deleted_at = null
     where center_id = v_center and code = 'absent_makeup' and deleted_at is not null
       and not exists (select 1 from public.attendance_statuses s2
                        where s2.center_id = v_center and s2.code = 'absent_makeup' and s2.deleted_at is null);
  end if;
end;
$$;

revoke all on function public.set_makeup_policy(integer, integer) from public, anon, service_role;
grant execute on function public.set_makeup_policy(integer, integer) to authenticated;

-- Запись (Р4): стойка. Проверки — в триггере makeup_bookings_guard.
create or replace function public.book_makeup(p_credit_id uuid, p_lesson_id uuid)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_id     uuid;
  v_name   text;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk(v_center) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not exists (select 1 from public.makeup_credits c where c.id = p_credit_id and c.center_id = v_center) then
    raise exception 'Отработка не найдена' using errcode = '42704';
  end if;

  begin
    insert into public.makeup_bookings (center_id, credit_id, lesson_id, student_id)
    select v_center, c.id, p_lesson_id, c.student_id from public.makeup_credits c where c.id = p_credit_id
    returning id into v_id;
  exception
    when unique_violation then
      get stacked diagnostics v_name = constraint_name;
      if v_name = 'makeup_bookings_lesson_student_live_key' then
        raise exception 'Ученик уже записан на это занятие по другой отработке' using errcode = '22023';
      end if;
      raise exception 'Эта отработка уже записана на занятие' using errcode = '22023';
    when exclusion_violation then
      select s.full_name into v_name
        from public.makeup_credits c join public.students s on s.id = c.student_id
       where c.id = p_credit_id;
      raise exception 'У ученика % уже есть занятие в это время', coalesce(v_name, '') using errcode = '23P01';
  end;
  return v_id;
end;
$$;

revoke all on function public.book_makeup(uuid, uuid) from public, anon, service_role;
grant execute on function public.book_makeup(uuid, uuid) to authenticated;

create or replace function public.cancel_makeup_booking(p_booking_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_booking public.makeup_bookings;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk(v_center) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_booking from public.makeup_bookings where id = p_booking_id and center_id = v_center;
  if not found then
    raise exception 'Запись на отработку не найдена' using errcode = '42704';
  end if;
  -- Право — первым под блокировку: та же очередь, что у отметки и записи.
  perform 1 from public.makeup_credits where id = v_booking.credit_id for update;
  select * into v_booking from public.makeup_bookings where id = p_booking_id for update;
  if v_booking.closed_at is not null then
    return;
  end if;
  if exists (select 1 from public.attendance a
              where a.lesson_id = v_booking.lesson_id and a.student_id = v_booking.student_id) then
    raise exception 'По отработке уже есть отметка — отменить запись нельзя' using errcode = '22023';
  end if;

  update public.makeup_bookings set closed_at = now(), closed_reason = 'cancelled' where id = p_booking_id;
end;
$$;

revoke all on function public.cancel_makeup_booking(uuid) from public, anon, service_role;
grant execute on function public.cancel_makeup_booking(uuid) to authenticated;

-- Куда можно записать (З5): места считает база, не браузер.
create or replace function public.makeup_lesson_options(p_credit_id uuid)
  returns table (lesson_id uuid, starts_at timestamptz, ends_at timestamptz, title text, teacher_name text, free_places integer)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_credit public.makeup_credits;
  v_tz     text;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk(v_center) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  select * into v_credit from public.makeup_credits where id = p_credit_id and center_id = v_center;
  if not found then
    raise exception 'Отработка не найдена' using errcode = '42704';
  end if;
  if v_credit.cancelled_at is not null or v_credit.used_attendance_id is not null
     or v_credit.expires_on < public.center_today(v_center) then
    return;
  end if;
  v_tz := public.center_timezone(v_center);

  return query
    select l.id, l.starts_at, l.ends_at,
           coalesce(g.name, 'Индивидуальное занятие'),
           t.full_name,
           case when g.max_students is null then null
                else g.max_students
                     - (select count(*)::int from public.lesson_participants p
                         where p.lesson_id = l.id and p.deleted_at is null and not p.via_makeup)
                     - (select count(*)::int from public.makeup_bookings b
                         where b.lesson_id = l.id and b.closed_at is null)
           end
      from public.lessons l
      left join public.groups g on g.id = l.group_id
      left join public.teachers t on t.id = coalesce(l.substitute_teacher_id, l.teacher_id)
     where l.center_id = v_center
       and l.deleted_at is null
       and l.status <> 'cancelled'
       and l.starts_at > now()
       and (l.starts_at at time zone v_tz)::date between v_credit.missed_on and v_credit.expires_on
       and l.service_id is not distinct from v_credit.service_id
       and (l.student_id = v_credit.student_id or (l.student_id is null and l.group_id is not null))
       and not exists (select 1 from public.lesson_participants p
                        where p.lesson_id = l.id and p.student_id = v_credit.student_id and p.deleted_at is null
                          and l.student_id is null)
       and not exists (select 1 from public.attendance a where a.lesson_id = l.id and a.student_id = v_credit.student_id)
       -- Уже записан сюда по другому праву или занят в это время (EXCLUDE откажет).
       and not exists (select 1 from public.makeup_bookings b2
                        where b2.lesson_id = l.id and b2.student_id = v_credit.student_id and b2.closed_at is null)
       and not exists (select 1 from public.lesson_participants p2
                        where p2.student_id = v_credit.student_id and p2.deleted_at is null and p2.lesson_id <> l.id
                          and tstzrange(p2.starts_at, p2.ends_at) && tstzrange(l.starts_at, l.ends_at))
       and (g.max_students is null
            or g.max_students
               > (select count(*) from public.lesson_participants p
                   where p.lesson_id = l.id and p.deleted_at is null and not p.via_makeup)
               + (select count(*) from public.makeup_bookings b
                   where b.lesson_id = l.id and b.closed_at is null))
     order by l.starts_at
     limit 50;
end;
$$;

revoke all on function public.makeup_lesson_options(uuid) from public, anon, service_role;
grant execute on function public.makeup_lesson_options(uuid) to authenticated;

-- Отработки ученика для карточки: статус считается в SQL по дню центра (З5).
create or replace function public.student_makeups(p_student_id uuid)
  returns table (
    credit_id        uuid,
    status           text,
    missed_on        date,
    expires_on       date,
    service_name     text,
    booking_id       uuid,
    booked_starts_at timestamptz,
    used_on          date
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_today  date;
  v_tz     text;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk(v_center) then
    return;
  end if;
  v_today := public.center_today(v_center);
  v_tz := public.center_timezone(v_center);

  return query
    select c.id,
           case
             when c.cancelled_at is not null then 'cancelled'
             when c.used_attendance_id is not null then 'used'
             when b.id is not null then 'booked'
             when c.expires_on < v_today then 'expired'
             else 'available'
           end,
           c.missed_on, c.expires_on, sv.name, b.id, bl.starts_at,
           (ul.starts_at at time zone v_tz)::date
      from public.makeup_credits c
      left join public.services sv on sv.id = c.service_id
      left join public.makeup_bookings b on b.credit_id = c.id and b.closed_at is null
      left join public.lessons bl on bl.id = b.lesson_id
      left join public.attendance ua on ua.id = c.used_attendance_id
      left join public.lessons ul on ul.id = ua.lesson_id
     where c.center_id = v_center and c.student_id = p_student_id
     order by c.missed_on desc, c.created_at desc;
end;
$$;

revoke all on function public.student_makeups(uuid) from public, anon, service_role;
grant execute on function public.student_makeups(uuid) to authenticated;


-- 8. Экспорт центра --------------------------------------------------------------------------------

create or replace function public.export_center_tables()
  returns table (table_name text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('attendance'), ('attendance_statuses'), ('booking_requests'), ('cash_counts'), ('cash_transfers'), ('center_modules'),
    ('diagnostic_clinical_forms'), ('diagnostic_referrals'), ('diagnostics'), ('discount_reasons'),
    ('exercise_library'),
    ('expense_categories'), ('expenses'), ('financial_periods'), ('funnel_events'),
    ('goal_progress'), ('goal_stages'), ('goals'), ('group_students'), ('groups'),
    ('homework'), ('homework_exercises'), ('installment_plans'), ('installments'),
    ('lesson_debt_covers'), ('lesson_debt_writeoffs'),
    ('lesson_note_goal_scores'), ('lesson_notes'), ('makeup_bookings'), ('makeup_credits'), ('makeup_policies'), ('lesson_participants'), ('lessons'),
    ('memberships'), ('message_templates'), ('monthly_reports'), ('payers'),
    ('payment_sources'), ('payment_voids'), ('payments'), ('platform_payments'), ('prosody_assessments'),
    ('reading_writing_assessments'), ('rooms'),
    ('salary_adjustments'), ('salary_runs'), ('services'), ('student_anamnesis'),
    ('student_articulation'), ('student_payers'), ('students'), ('subscription_freezes'),
    ('subscription_shortfall_writeoffs'),
    ('subscription_types'), ('subscriptions'), ('syllable_assessments'), ('teacher_rates'), ('teachers')
$$;

comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. 0087: lesson_debt_writeoffs. 0088: lesson_debt_covers. 0090: subscription_shortfall_writeoffs. 0093: payment_voids. 0101: cash_transfers, discount_reasons. 0102: cash_counts. 0104: center_modules. 0105: makeup_policies, makeup_credits, makeup_bookings. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
