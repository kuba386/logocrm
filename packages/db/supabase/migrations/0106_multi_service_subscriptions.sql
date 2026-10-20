-- =============================================================================
-- 0106_multi_service_subscriptions.sql — абонемент на несколько услуг (этап 15)
--
-- Решение владельца 20.10.2026 (анализ «Мой Класс», случай KadamLogo: СМК и
-- логопед у одного ребёнка). Ядро, не модуль. Семейный абонемент — отдельно.
--
-- Решения (ревью архитектора плана: 9 дыр — учтены):
--   Р1. Модель «основная subscription_types.service_id + дополнительные в
--       subscription_type_extra_services». Тип без основной — любая услуга;
--       потерянная дополнительная только сужает покрытие, а не расширяет.
--   Р2. Одна копия правила — subscription_type_covers(type, service): всегда
--       true/false (без NULL — иначе «not covers» в guard выключался бы).
--       Архив услуги покрытие не снимает (как у основной). Перевыпущены
--       attendance_subscription_candidates_unchecked (0103), lesson_debt_cover_plan
--       и lesson_debt_covers_guard (0088).
--   Р3. Набор услуг пишет одна RPC set_subscription_type_services под FOR UPDATE
--       строки типа; тот же набор в другом порядке — ничего не делает; текущая
--       основная остаётся основной, если осталась в наборе. Порядок внутри:
--       погасить дополнительные → сменить основную → вставить новые.
--   Р4. pick (0103): при равном сроке — самый узкий (своя услуга → мульти →
--       любая), subscription_type_breadth.
--   Р5. Инварианты триггерами под блокировкой строки типа: у проданного типа
--       набор не меняется (вставка и любое изменение строки junction);
--       дополнительная — только у типа с основной и не равна ей; основная не
--       может стать одной из живых дополнительных и не снимается при живых
--       дополнительных. Продажа берёт FOR SHARE строки типа (BEFORE INSERT на
--       subscriptions) — правка набора и продажа не проходят одновременно.
--   Р6. Junction: только select (стойка и бухгалтер — как типы абонементов),
--       писать — только RPC и триггеры; составные FK, непартиальные индексы.
--       Грант update(service_id) на типы остаётся (старый веб); его держат
--       триггеры.
--   Р7 (ревью SQL). Владелец и админ видят архивные услуги (как архивные типы,
--       0012) — иначе форма типа молча сняла бы архивную услугу из набора;
--       добавить в набор можно только живую услугу, уже входящую — остаётся.
--   Р8. Смена порядка выбора у существующих центров: при равном сроке узкий
--       тип теперь раньше «любой услуги» и абонемента без типа. История отметок
--       не меняется (subscription_id в отметке заморожен).
-- =============================================================================


-- 1. Таблица дополнительных услуг -----------------------------------------------------------------

create table if not exists public.subscription_type_extra_services (
  id         uuid primary key default gen_random_uuid(),
  center_id  uuid not null default public.current_center()
               references public.centers (id) on delete cascade,
  type_id    uuid not null,
  service_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  deleted_at timestamptz,

  constraint subscription_type_extra_services_type_fk
    foreign key (type_id, center_id) references public.subscription_types (id, center_id) on delete cascade,
  constraint subscription_type_extra_services_service_fk
    foreign key (service_id, center_id) references public.services (id, center_id)
);

comment on table public.subscription_type_extra_services is
  'Дополнительные услуги типа абонемента (0106 Р1): тип покрывает основную subscription_types.service_id и живые строки отсюда. Пишет только set_subscription_type_services.';

create unique index if not exists subscription_type_extra_services_live_key
  on public.subscription_type_extra_services (type_id, service_id) where deleted_at is null;
create index if not exists subscription_type_extra_services_type_idx
  on public.subscription_type_extra_services (type_id, center_id);
create index if not exists subscription_type_extra_services_service_idx
  on public.subscription_type_extra_services (service_id, center_id);
create index if not exists subscription_type_extra_services_center_idx
  on public.subscription_type_extra_services (center_id);
-- Проверка «тип продан» в триггерах — не полным сканом (и покрытие FK subscriptions → types).
create index if not exists subscriptions_type_center_idx on public.subscriptions (type_id, center_id);

drop trigger if exists subscription_type_extra_services_set_updated_at on public.subscription_type_extra_services;
create trigger subscription_type_extra_services_set_updated_at
  before update on public.subscription_type_extra_services
  for each row execute function extensions.moddatetime(updated_at);

alter table public.subscription_type_extra_services enable row level security;

drop policy if exists subscription_type_extra_services_select on public.subscription_type_extra_services;
create policy subscription_type_extra_services_select on public.subscription_type_extra_services
  for select to authenticated
  using (center_id = public.current_center()
         and (public.can_front_desk(center_id) or public.can_finance(center_id)));

revoke all on table public.subscription_type_extra_services from public, anon, authenticated, service_role;
grant select on public.subscription_type_extra_services to authenticated;

call public.apply_audit('subscription_type_extra_services');
call public.apply_readonly_guard('subscription_type_extra_services');


-- Р7: архивные услуги — владельцу и админу, узкая политика поверх tenant_admin.
drop policy if exists services_read_archived on public.services;
create policy services_read_archived on public.services
  for select to authenticated
  using (
    center_id = public.current_center()
    and deleted_at is not null
    and coalesce(public.my_role(), '') in ('owner', 'admin')
  );


-- 2. Правило услуги — одна копия (Р2) -------------------------------------------------------------

create or replace function public.subscription_type_covers(p_type uuid, p_service uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce((
    select t.service_id is null
        or t.service_id = p_service
        or exists (select 1 from public.subscription_type_extra_services e
                    where e.type_id = t.id and e.service_id = p_service and e.deleted_at is null)
      from public.subscription_types t
     where t.id = p_type
  ), false);
$$;

comment on function public.subscription_type_covers(uuid, uuid) is
  'Тип абонемента покрывает услугу занятия (0106 Р2): без основной — любую; иначе основную или живую дополнительную. Всегда true/false. Без грантов.';

revoke all on function public.subscription_type_covers(uuid, uuid) from public, anon, authenticated, service_role;

create or replace function public.subscription_type_breadth(p_type uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select case
    when p_type is null then 2
    when (select t.service_id from public.subscription_types t where t.id = p_type) is null then 2
    when exists (select 1 from public.subscription_type_extra_services e
                  where e.type_id = p_type and e.deleted_at is null) then 1
    else 0
  end;
$$;

comment on function public.subscription_type_breadth(uuid) is
  'Ширина типа для порядка выбора абонемента (0106 Р4): 0 — одна услуга, 1 — несколько, 2 — любая или без типа.';

revoke all on function public.subscription_type_breadth(uuid) from public, anon, authenticated, service_role;

create or replace function public.attendance_subscription_candidates_unchecked(
  p_center  uuid,
  p_student uuid,
  p_service uuid,
  p_day     date
)
  returns table (id uuid, is_frozen boolean, ends_at date, created_at timestamptz)
  language sql
  stable
  security invoker
  set search_path = ''
as $$
  select c.id, c.is_frozen, c.ends_at, c.created_at
    from (
      select s.id,
             exists (
               select 1 from public.subscription_freezes f
                where f.subscription_id = s.id and f.period @> p_day
             ) as is_frozen,
             s.ends_at, s.created_at
        from public.subscriptions s
       where s.student_id = p_student
         and s.center_id  = p_center
         and s.deleted_at is null
         and s.status <> 'cancelled'
         and s.starts_at <= p_day
         and (s.allow_negative
              or s.lessons_total is null
              or s.lessons_total - s.lessons_used - s.lessons_written_off > 0)
         -- 0106: одна копия правила услуги — subscription_type_covers.
         and (s.type_id is null or public.subscription_type_covers(s.type_id, p_service))
    ) c
   where c.ends_at is null or c.ends_at >= p_day or c.is_frozen;
$$;

revoke all on function public.attendance_subscription_candidates_unchecked(uuid, uuid, uuid, date)
  from public, anon, authenticated, service_role;

create or replace function public.attendance_pick_subscription_unchecked(
  p_center  uuid,
  p_student uuid,
  p_service uuid,
  p_day     date
)
  returns table (id uuid, is_frozen boolean)
  language sql
  stable
  security invoker
  set search_path = ''
as $$
  select c.id, c.is_frozen
    from public.attendance_subscription_candidates_unchecked(p_center, p_student, p_service, p_day) c
    join public.subscriptions s on s.id = c.id
   -- 0106 Р4: при равном сроке — самый узкий: своя услуга (0), мульти (1),
   -- любая услуга или без типа (2). Иначе «Логопед» списывался бы с
   -- «Логопед+СМК», и СМК уходило бы в долг при живом остатке.
   order by c.is_frozen asc, c.ends_at asc nulls last,
            public.subscription_type_breadth(s.type_id), c.created_at, c.id
   limit 1;
$$;

revoke all on function public.attendance_pick_subscription_unchecked(uuid, uuid, uuid, date)
  from public, anon, authenticated, service_role;

comment on function public.attendance_subscription_candidates_unchecked(uuid, uuid, uuid, date) is
  'Абонементы, с которых может списаться отметка ребёнка на занятие услуги p_service в день p_day. Правило услуги — subscription_type_covers (0106). Без проверки прав — только для definer-функций.';
comment on function public.attendance_pick_subscription_unchecked(uuid, uuid, uuid, date) is
  'Абонемент, с которого спишется отметка: незамороженные, раньше кончается, затем самый узкий тип (subscription_type_breadth, 0106), затем раньше создан. Одна копия для attendance_fill_and_check и lesson_attendance_balances.';

create or replace function public.lesson_debt_cover_plan(p_subscription_id uuid)
  returns table (attendance_id uuid, lesson_id uuid, price_tiyin integer)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_sub       public.subscriptions;
  v_free      integer;
  v_remaining bigint;
  r           record;
begin
  select * into v_sub from public.subscriptions s where s.id = p_subscription_id;
  if not found
     or v_sub.deleted_at is not null
     or v_sub.lessons_total is null
     or public.subscription_state_unchecked(v_sub.id) <> 'active' then
    return;
  end if;

  v_free := v_sub.lessons_total - v_sub.lessons_used - v_sub.lessons_written_off;
  select coalesce(max(x.remaining_tiyin), 0) into v_remaining
    from public.lesson_debt_accounts_unchecked(v_sub.center_id, v_sub.student_id) x;

  for r in
    select a.id as attendance_id, a.lesson_id, a.price_tiyin
      from public.attendance a
      join public.lessons l on l.id = a.lesson_id
     where a.student_id = v_sub.student_id
       and a.center_id = v_sub.center_id
       and a.subscription_id is null
       and a.deducted
       and a.price_tiyin > 0
       and l.deleted_at is null
       and l.status <> 'cancelled'
       -- Правило услуги — одна копия (0106): subscription_type_covers.
       and (v_sub.type_id is null or public.subscription_type_covers(v_sub.type_id, l.service_id))
       and not exists (select 1 from public.lesson_debt_covers c
                        where c.attendance_id = a.id and c.deleted_at is null)
     order by l.starts_at, a.id
  loop
    exit when v_free <= 0 or v_remaining <= 0;
    attendance_id := r.attendance_id;
    lesson_id := r.lesson_id;
    price_tiyin := r.price_tiyin;
    return next;
    v_free := v_free - 1;
    v_remaining := v_remaining - r.price_tiyin;
  end loop;
end;
$$;

revoke all on function public.lesson_debt_cover_plan(uuid) from public, anon, authenticated, service_role;

comment on function public.lesson_debt_cover_plan(uuid) is
  'Отметки, которые этот абонемент может покрыть сейчас, по порядку (0088 Р5/Р8): долговые, непокрытые, у живых занятий, услуга покрывается типом (subscription_type_covers, 0106); пока есть место и перед очередной есть остаток долга. Без проверки сессии; грантов нет.';

create or replace function public.lesson_debt_covers_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_att       public.attendance;
  v_lesson    public.lessons;
  v_sub       public.subscriptions;
  v_remaining integer;
begin
  -- Р4: тот же порядок, что в cover_lesson_debt.
  perform public.lesson_debt_lock(new.student_id);
  select * into v_lesson from public.lessons l
   where l.id = (select a.lesson_id from public.attendance a where a.id = new.attendance_id)
   for share;
  select * into v_att from public.attendance a where a.id = new.attendance_id for update;
  select * into v_sub from public.subscriptions s where s.id = new.subscription_id for update;

  if v_att.id is null or v_att.student_id <> new.student_id or v_att.center_id <> new.center_id then
    raise exception 'Отметка не найдена' using errcode = '42704';
  end if;
  if not v_att.deducted or v_att.subscription_id is not null or v_att.price_tiyin <= 0
     or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
    raise exception 'Покрыть можно только неоплаченное занятие без абонемента' using errcode = '22023';
  end if;
  if v_sub.id is null or v_sub.deleted_at is not null or v_sub.lessons_total is null
     or public.subscription_state_unchecked(v_sub.id) <> 'active' then
    raise exception 'Покрыть долг можно только действующим пакетом занятий' using errcode = '22023';
  end if;
  -- 0106: одна копия правила; covers всегда true/false, без NULL — not NULL
  -- выключил бы этот последний рубеж.
  if v_sub.type_id is not null and not public.subscription_type_covers(v_sub.type_id, v_lesson.service_id) then
    raise exception 'Абонемент на другую услугу — им это занятие не покрыть' using errcode = '22023';
  end if;
  if v_sub.lessons_total - v_sub.lessons_used - v_sub.lessons_written_off < 1 then
    raise exception 'В абонементе не осталось свободных занятий' using errcode = '22023';
  end if;

  select coalesce(max(x.remaining_tiyin), 0) into v_remaining
    from public.lesson_debt_accounts_unchecked(new.center_id, new.student_id) x;
  if v_remaining <= 0 then
    raise exception 'Долга нет — покрывать нечего' using errcode = '22023';
  end if;

  new.price_tiyin := v_att.price_tiyin;
  return new;
end;
$$;

revoke all on function public.lesson_debt_covers_guard() from public, anon, authenticated, service_role;

comment on function public.lesson_debt_covers_guard() is
  'Граница 0088 при вставке покрытия: долговая отметка у живого занятия, действующий пакет того же ребёнка, услуга покрывается типом (subscription_type_covers, 0106), свободное место ≥ 1 при любом allow_negative, остаток долга > 0. Под блокировками в порядке Р4.';


-- 3. Инварианты — триггеры под блокировкой строки типа (Р5) ---------------------------------------

create or replace function public.subscription_type_extra_services_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_type public.subscription_types;
begin
  -- FOR UPDATE конфликтует с KEY SHARE от FK продажи: проверка «продан»
  -- после блокировки видит закоммиченные продажи.
  select * into v_type from public.subscription_types
   where id = coalesce(new.type_id, old.type_id) for update;

  if tg_op = 'UPDATE' then
    if new.type_id is distinct from old.type_id
       or new.service_id is distinct from old.service_id
       or new.center_id is distinct from old.center_id then
      raise exception 'Дополнительную услугу типа нельзя изменить — только снять или добавить заново'
        using errcode = '22023';
    end if;
  end if;

  if exists (select 1 from public.subscriptions s where s.type_id = v_type.id) then
    raise exception 'У этого типа уже есть проданные абонементы — набор услуг менять нельзя, заведите новый тип'
      using errcode = '22023';
  end if;

  if new.deleted_at is null then
    if v_type.service_id is null then
      raise exception 'Дополнительные услуги — только у типа с основной услугой' using errcode = '22023';
    end if;
    if new.service_id = v_type.service_id then
      raise exception 'Дополнительная услуга совпадает с основной' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.subscription_type_extra_services_guard() from public, anon, authenticated, service_role;

-- Имя после a00_readonly_guard: readonly-отказ — первым.
drop trigger if exists b01_extra_services_guard on public.subscription_type_extra_services;
create trigger b01_extra_services_guard
  before insert or update on public.subscription_type_extra_services
  for each row execute function public.subscription_type_extra_services_guard();

-- Основная услуга: не одна из живых дополнительных и не снимается при живых
-- дополнительных (прямой PATCH service_id — грант остаётся для старого веба).
create or replace function public.subscription_types_primary_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.service_id is not distinct from old.service_id then
    return new;
  end if;
  if new.service_id is null
     and exists (select 1 from public.subscription_type_extra_services e
                  where e.type_id = new.id and e.deleted_at is null) then
    raise exception 'Сначала снимите дополнительные услуги — тип без основной покрывает любую услугу'
      using errcode = '22023';
  end if;
  if new.service_id is not null
     and exists (select 1 from public.subscription_type_extra_services e
                  where e.type_id = new.id and e.service_id = new.service_id and e.deleted_at is null) then
    raise exception 'Эта услуга уже дополнительная у типа' using errcode = '22023';
  end if;
  return new;
end;
$$;

revoke all on function public.subscription_types_primary_guard() from public, anon, authenticated, service_role;

drop trigger if exists subscription_types_primary_guard on public.subscription_types;
create trigger subscription_types_primary_guard
  before update of service_id on public.subscription_types
  for each row execute function public.subscription_types_primary_guard();

-- Продажа (и перенос остатка) берёт FOR SHARE строки типа: правка услуг типа
-- (FOR UPDATE / UPDATE строки) и продажа не проходят одновременно.
create or replace function public.subscriptions_lock_type()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.type_id is not null then
    perform 1 from public.subscription_types t where t.id = new.type_id for share;
  end if;
  return new;
end;
$$;

revoke all on function public.subscriptions_lock_type() from public, anon, authenticated, service_role;

drop trigger if exists subscriptions_lock_type on public.subscriptions;
create trigger subscriptions_lock_type
  before insert on public.subscriptions
  for each row execute function public.subscriptions_lock_type();


-- 4. Набор услуг — одна RPC (Р3) ------------------------------------------------------------------

create or replace function public.set_subscription_type_services(p_type_id uuid, p_service_ids uuid[])
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_type    public.subscription_types;
  v_new     uuid[];
  v_current uuid[];
  v_primary uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not public.center_writable(v_center) then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  if p_service_ids is not null and array_position(p_service_ids, null) is not null then
    raise exception 'Пустая услуга в наборе' using errcode = '22023';
  end if;

  select * into v_type from public.subscription_types
   where id = p_type_id and center_id = v_center
   for update;
  if not found then
    raise exception 'Тип абонемента не найден' using errcode = '42704';
  end if;

  -- Дедупликация с сохранением порядка; NULL и '{}' — «любая услуга».
  select coalesce(array_agg(x.sid order by x.ord), '{}') into v_new
    from (select distinct on (u.sid) u.sid, u.ord
            from unnest(coalesce(p_service_ids, '{}')) with ordinality u(sid, ord)
           order by u.sid, u.ord) x;

  if exists (select 1 from unnest(v_new) sid
              where not exists (select 1 from public.services sv
                                 where sv.id = sid and sv.center_id = v_center)) then
    raise exception 'Услуга не найдена' using errcode = '42704';
  end if;

  select case when v_type.service_id is null then '{}'::uuid[]
              else array[v_type.service_id] || coalesce(array_agg(e.service_id), '{}') end
    into v_current
    from public.subscription_type_extra_services e
   where e.type_id = v_type.id and e.deleted_at is null;

  -- Р7: новую услугу — только живую; уже входящая в набор архивная остаётся.
  if exists (select 1 from unnest(v_new) sid
              join public.services sv on sv.id = sid
             where sv.deleted_at is not null and not (sid = any (v_current))) then
    raise exception 'Услуга в архиве — добавить её в набор нельзя' using errcode = '22023';
  end if;

  -- Тот же набор в любом порядке — ничего не делаем (правка цены проданного
  -- типа не должна падать на «услугу менять нельзя»).
  if v_current <@ v_new and v_new <@ v_current then
    return;
  end if;
  if exists (select 1 from public.subscriptions s where s.type_id = v_type.id) then
    raise exception 'У этого типа уже есть проданные абонементы — набор услуг менять нельзя, заведите новый тип'
      using errcode = '22023';
  end if;

  v_primary := case
    when cardinality(v_new) = 0 then null
    when v_type.service_id = any (v_new) then v_type.service_id
    else v_new[1]
  end;

  -- Порядок: погасить → сменить основную → вставить (обмен A↔B не упрётся в
  -- собственные триггеры).
  update public.subscription_type_extra_services
     set deleted_at = now()
   where type_id = v_type.id and deleted_at is null
     and (service_id <> all (v_new) or service_id = v_primary);

  if v_primary is distinct from v_type.service_id then
    update public.subscription_types set service_id = v_primary where id = v_type.id;
  end if;

  insert into public.subscription_type_extra_services (center_id, type_id, service_id)
  select v_center, v_type.id, sid
    from unnest(v_new) sid
   where sid is distinct from v_primary
     and not exists (select 1 from public.subscription_type_extra_services e
                      where e.type_id = v_type.id and e.service_id = sid and e.deleted_at is null);
end;
$$;

revoke all on function public.set_subscription_type_services(uuid, uuid[]) from public, anon, service_role;
grant execute on function public.set_subscription_type_services(uuid, uuid[]) to authenticated;


-- 5. Экспорт центра -------------------------------------------------------------------------------

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
    ('subscription_type_extra_services'), ('subscription_types'), ('subscriptions'), ('syllable_assessments'), ('teacher_rates'), ('teachers')
$$;

comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. 0087: lesson_debt_writeoffs. 0088: lesson_debt_covers. 0090: subscription_shortfall_writeoffs. 0093: payment_voids. 0101: cash_transfers, discount_reasons. 0102: cash_counts. 0104: center_modules. 0105: makeup_policies, makeup_credits, makeup_bookings. 0106: subscription_type_extra_services. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
