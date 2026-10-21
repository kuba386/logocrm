-- =============================================================================
-- 0109_booking_slots.sql — этап 19: онлайн-запись по свободным окнам и лист ожидания
--
-- Решение владельца 21.10.2026. Витрина /book/[slug] (0057) показывала только
-- занятое время — рабочих часов в схеме не было (0057 Р9). Теперь у
-- специалиста есть режим записи и часы, витрина отдаёт свободные окна, а когда
-- окон нет — родитель встаёт в лист ожидания. План — docs/Roadmap/stages.md,
-- «Этап 19»; ревью архитектора плана: 7 блокеров (Б1–Б7) и 12 замечаний.
--
--   Р1. Режим записи — teachers.booking_mode → справочник booking_modes
--       (any / hours / closed), по умолчанию any: у существующих центров ничего
--       не меняется. Режим задаётся явно, а не выводится из наличия часов —
--       очистка часов не возвращает «любое время» (Б3). Колонка вне
--       колоночного гранта update на teachers: только set_teacher_booking.
--   Р2. teacher_work_hours — интервалы по дням недели (isodow 1..7), время
--       центра; EXCLUDE пересечения по живым строкам (int4range минут, касание
--       не пересечение). Пишет только set_teacher_booking: строка специалиста
--       for update, полная неделя в jsonb, ответ — заявки и занятия, выпавшие
--       из новых часов (ничего не отменяется).
--   Р3. Горизонт витрины (7–31 день, 14) и шаг сетки (15/30/60, 30) —
--       centers.settings, запись через set_booking_settings. Прямой PATCH
--       владельца мимо функции держит триггер centers_validate_booking_settings
--       по образцу centers_validate_timezone (0086) — иначе горизонт 100 000
--       дней и шаг в минуту (Б2). Читатель booking_settings_unchecked ещё и
--       зажимает значения.
--   Р4. Одна копия правила окна — booking_slots_unchecked: генератор кандидатов
--       в поясе центра, окно целиком внутри интервала, шаг от начала
--       интервала, длительность — services.duration_min, только individual,
--       [now + 30 минут; сегодня центра + горизонт]. Занятость — anti-join по
--       tstzrange && против занятий в форме предиката EXCLUDE lessons и против
--       заявок, держащих окно, за весь интервал (Б7). Окно на стыке соседних
--       интервалов (12:30 при 9–13 и 13–18) теряется — осознанно. Витрина
--       (booking_free_slots), подача заявки и дайджест зовут только его.
--   Р5. Заявка держит окно 24 часа от created_at, не дольше; живая заявка —
--       одна на телефон и ребёнка в центре (частичный unique, Б1). Повтор —
--       тот же успешный ответ без новой строки, как Р8: отказ «с этого номера
--       уже есть заявка» раскрыл бы постороннему, что семья обратилась в
--       центр (ревью SQL). Второй ребёнок того же родителя подаёт свою.
--       Старые дубли живых заявок закрываются этой миграцией: остаётся последняя.
--   Р6. submit_booking_request перевыпущена: hours — время обязано совпасть с
--       окном генератора на этот день (одна проверка вместо сетки, горизонта
--       и lead time по отдельности); any — как 0057; closed и групповая
--       услуга — единый отказ (0057 Р4). Advisory-lock — двухаргументная
--       форма с классом, порядок везде «телефон → специалист», до проверок.
--       statement_timeout на роль public_booking.
--   Р7. Лист ожидания — waitlist_entries, не booking_requests (у заявки
--       обязательны специалист и время). Форма строки — CHECK, статус —
--       справочник waitlist_statuses, переходы — триггер; конечные статусы
--       неизменны. Писать — только RPC; читает только стойка.
--   Р8. Повтор в листе ожидания (тот же телефон, ребёнок и услуга, пока
--       запись жива) — тот же успешный ответ без второй строки (Б4): «вы уже в
--       очереди» раскрыл бы постороннему факт обращения ребёнка к логопеду.
--   Р9. enroll_waitlist_entry: захват строки for update по живому статусу
--       раньше создания ученика; плательщик — явный выбор стойки, при null —
--       insert payers с перехватом unique_violation (Б5, как
--       confirm_booking_request). Захват — for update, а не update … returning
--       (0057 Р13): CHECK «enrolled ⇔ есть ученик» не пускает статус раньше
--       ученика. Двойной вызов: второй ждёт замок и видит конечный статус.
--   Р10. Уведомления стойке: waitlist.created (текст собирает event_messages в
--       центре события, без даты рождения и комментария — там может быть
--       диагноз) и дайджест waitlist.digest раз в день с 10 до 20 по часам
--       центра, если у ожидающих есть подходящие окна на неделю. «Раз в день»
--       держит первичный ключ waitlist_digest_runs (Б6).
--   Р11. «Отклонить всё с этого номера» (decline_booking_phone) — заявка и
--       живые записи листа ожидания с того же телефона одним действием:
--       живая заявка с номера одна (Р5), «все» имеет смысл только вместе с
--       листом ожидания.
--
-- Записано, не чинится:
--   - «Любой специалист» не делаем: связи «специалист — услуга» в схеме нет.
--     Дайджест для записи без специалиста считает окна всех специалистов в
--     режиме hours — подсказка «есть окна», не обещание.
--   - Гонка «заявка ↔ занятие, поставленное стойкой вручную»: create_lesson_
--     series заявок не видит, подтверждение тогда получает «Слот уже занят» —
--     данные держит EXCLUDE lessons.
--   - Кабинет, отпуска и разовые выходные в расчёте окон не участвуют.
-- =============================================================================


-- 1. Справочники (Р1, Р7) -----------------------------------------------------------------------

create table if not exists public.booking_modes (
  code  text primary key,
  title text not null,
  sort  integer not null default 0
);

create table if not exists public.waitlist_statuses (
  code  text primary key,
  title text not null,
  sort  integer not null default 0
);

comment on table public.booking_modes is
  'Режим онлайн-записи специалиста (0109 Р1): any — любое время (форма 0057), hours — свободные окна по рабочим часам, closed — на витрине не показывается. Пишет только миграция.';
comment on table public.waitlist_statuses is
  'Статусы листа ожидания (0109 Р7). Переходы держит триггер waitlist_entries_transition. Пишет только миграция.';

insert into public.booking_modes (code, title, sort) values
  ('any',    'Любое время',        10),
  ('hours',  'По рабочим часам',   20),
  ('closed', 'Запись закрыта',     30)
on conflict (code) do nothing;

insert into public.waitlist_statuses (code, title, sort) values
  ('waiting',   'Ждёт',             10),
  ('offered',   'Предложили время', 20),
  ('enrolled',  'Записан',          30),
  ('withdrawn', 'Отказался',        40)
on conflict (code) do nothing;

alter table public.booking_modes enable row level security;
alter table public.waitlist_statuses enable row level security;

drop policy if exists booking_modes_read_all on public.booking_modes;
create policy booking_modes_read_all on public.booking_modes for select to authenticated using (true);
drop policy if exists waitlist_statuses_read_all on public.waitlist_statuses;
create policy waitlist_statuses_read_all on public.waitlist_statuses for select to authenticated using (true);

revoke all on table public.booking_modes, public.waitlist_statuses
  from public, anon, authenticated, service_role;
grant select on table public.booking_modes, public.waitlist_statuses to authenticated;


-- 2. Режим и рабочие часы специалиста (Р1, Р2) ---------------------------------------------------

alter table public.teachers
  add column if not exists booking_mode text not null default 'any' references public.booking_modes (code);

comment on column public.teachers.booking_mode is
  'Режим онлайн-записи (0109 Р1). Вне колоночного гранта update — менять только set_teacher_booking; при создании карточки owner/admin может задать его сразу (табличный грант insert, 0017) — те же роли, что у функции.';

create index if not exists teachers_booking_mode_idx on public.teachers (booking_mode);

create table if not exists public.teacher_work_hours (
  id         uuid primary key default gen_random_uuid(),
  center_id  uuid not null references public.centers (id) on delete cascade,
  teacher_id uuid not null,
  weekday    smallint not null check (weekday between 1 and 7),
  starts_at  time not null,
  ends_at    time not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  deleted_at timestamptz,

  constraint teacher_work_hours_order check (ends_at > starts_at and ends_at < time '24:00'),
  constraint teacher_work_hours_minutes check (extract(second from starts_at) = 0 and extract(second from ends_at) = 0),
  constraint teacher_work_hours_teacher_fk
    foreign key (teacher_id, center_id) references public.teachers (id, center_id) on delete cascade,
  constraint teacher_work_hours_no_overlap exclude using gist (
    teacher_id with =,
    weekday with =,
    int4range((extract(hour from starts_at) * 60 + extract(minute from starts_at))::integer,
              (extract(hour from ends_at) * 60 + extract(minute from ends_at))::integer) with &&
  ) where (deleted_at is null)
);

comment on table public.teacher_work_hours is
  'Рабочие часы специалиста для онлайн-записи (0109 Р2): weekday — isodow (1 = понедельник), время — в поясе центра. Пишет только set_teacher_booking; специалист видит свои, стойка — все.';

create index if not exists teacher_work_hours_teacher_idx on public.teacher_work_hours (teacher_id, center_id);
create index if not exists teacher_work_hours_center_idx on public.teacher_work_hours (center_id);

drop trigger if exists teacher_work_hours_set_updated_at on public.teacher_work_hours;
create trigger teacher_work_hours_set_updated_at before update on public.teacher_work_hours
  for each row execute function extensions.moddatetime(updated_at);

alter table public.teacher_work_hours enable row level security;
revoke all on table public.teacher_work_hours from public, anon, authenticated, service_role;
grant select on public.teacher_work_hours to authenticated;
call public.apply_audit('teacher_work_hours');
call public.apply_readonly_guard('teacher_work_hours');

drop policy if exists teacher_work_hours_select on public.teacher_work_hours;
create policy teacher_work_hours_select on public.teacher_work_hours
  for select to authenticated
  using (
    center_id = public.current_center()
    and deleted_at is null
    and (public.can_front_desk(center_id) or teacher_id = public.my_teacher_id())
  );


-- 3. Настройки витрины (Р3) ----------------------------------------------------------------------

create or replace function public.centers_validate_booking_settings()
  returns trigger
  language plpgsql
  security invoker
  set search_path = ''
as $$
declare
  v_h     jsonb := case when jsonb_typeof(new.settings) = 'object' then new.settings -> 'booking_horizon_days' end;
  v_s     jsonb := case when jsonb_typeof(new.settings) = 'object' then new.settings -> 'booking_step_min' end;
  v_old_h jsonb;
  v_old_s jsonb;
begin
  if tg_op = 'UPDATE' then
    v_old_h := case when jsonb_typeof(old.settings) = 'object' then old.settings -> 'booking_horizon_days' end;
    v_old_s := case when jsonb_typeof(old.settings) = 'object' then old.settings -> 'booking_step_min' end;
  end if;

  -- Как centers_validate_timezone (0086 Р2): правка, не меняющая ключ, не проверяется.
  if v_h is not null and (tg_op = 'INSERT' or v_h is distinct from v_old_h) then
    if not (case when jsonb_typeof(v_h) = 'number' and (v_h #>> '{}') ~ '^[0-9]{1,3}$'
                 then (v_h #>> '{}')::integer between 7 and 31
                 else false end) then
      raise exception 'Горизонт онлайн-записи — целое число дней от 7 до 31' using errcode = '22023';
    end if;
  end if;

  if v_s is not null and (tg_op = 'INSERT' or v_s is distinct from v_old_s) then
    if not (jsonb_typeof(v_s) = 'number' and (v_s #>> '{}') in ('15', '30', '60')) then
      raise exception 'Шаг сетки онлайн-записи — 15, 30 или 60 минут' using errcode = '22023';
    end if;
  end if;

  return new;
end;
$$;

comment on function public.centers_validate_booking_settings() is
  'Триггер centers (0109 Р3, Б2): settings.booking_horizon_days — целое 7..31, settings.booking_step_min — 15/30/60. Проверяется на INSERT и на UPDATE, меняющем ключ, — прямой PATCH мимо set_booking_settings тоже.';

revoke all on function public.centers_validate_booking_settings() from public, anon, authenticated, service_role;

drop trigger if exists centers_validate_booking_settings on public.centers;
create trigger centers_validate_booking_settings
  before insert or update of settings on public.centers
  for each row execute function public.centers_validate_booking_settings();


create or replace function public.booking_settings_unchecked(p_center_id uuid)
  returns table (horizon_days integer, step_min integer)
  language sql
  stable
  set search_path = ''
as $$
  -- Триггер держит допустимые значения; зажим — вторая линия на случай строк,
  -- записанных до 0109 или в обход триггера (Р3).
  select coalesce(case when (c.settings ->> 'booking_horizon_days') ~ '^[0-9]{1,3}$'
                       then least(greatest((c.settings ->> 'booking_horizon_days')::integer, 7), 31) end, 14),
         case when (c.settings ->> 'booking_step_min') in ('15', '30', '60')
              then (c.settings ->> 'booking_step_min')::integer else 30 end
    from public.centers c
   where c.id = p_center_id;
$$;

comment on function public.booking_settings_unchecked(uuid) is
  'Горизонт витрины (дни, 7..31, по умолчанию 14) и шаг сетки (15/30/60, по умолчанию 30) — единственное место, где читаются эти ключи settings (0109 Р3). Внутренняя: грантов нет.';

revoke all on function public.booking_settings_unchecked(uuid) from public, anon, authenticated, service_role;


create or replace function public.set_booking_settings(p_horizon_days integer, p_step_min integer)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Онлайн-запись настраивают владелец и администратор' using errcode = '42501';
  end if;
  if not public.center_writable(v_center) then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  if p_horizon_days is null or p_horizon_days not between 7 and 31 then
    raise exception 'Горизонт онлайн-записи — от 7 до 31 дня' using errcode = '22023';
  end if;
  if p_step_min is null or p_step_min not in (15, 30, 60) then
    raise exception 'Шаг сетки онлайн-записи — 15, 30 или 60 минут' using errcode = '22023';
  end if;

  update public.centers
     set settings = coalesce(settings, '{}'::jsonb)
                    || jsonb_build_object('booking_horizon_days', p_horizon_days, 'booking_step_min', p_step_min)
   where id = v_center;
end;
$$;

comment on function public.set_booking_settings(integer, integer) is
  'Горизонт и шаг публичной витрины записи (0109 Р3) — owner/admin.';

revoke all on function public.set_booking_settings(integer, integer) from public, anon, service_role;
grant execute on function public.set_booking_settings(integer, integer) to authenticated;


-- 4. Генератор окон — одна копия правила (Р4) ----------------------------------------------------

create or replace function public.booking_slots_unchecked(
  p_center_id  uuid,
  p_service_id uuid,
  p_teacher_id uuid,
  p_from       date,
  p_to         date
)
  returns table (teacher_id uuid, starts_at timestamptz, ends_at timestamptz)
  language plpgsql
  stable
  security invoker
  set search_path = ''
as $$
declare
  v_duration integer;
  v_tz       text;
  v_today    date;
  v_horizon  integer;
  v_step     integer;
begin
  -- Только вне пользовательской сессии: витрина (public_booking), подача
  -- заявки и дайджест (bot_worker). Грантов нет ни у кого; SECURITY INVOKER —
  -- ошибочный будущий грант упрётся в отсутствие табличных прав, а не отдаст
  -- окна любого центра по p_center_id (ревью SQL).
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select s.duration_min into v_duration
    from public.services s
   where s.id = p_service_id and s.center_id = p_center_id
     and s.is_active and s.deleted_at is null and s.kind = 'individual';
  if v_duration is null then
    return;
  end if;

  if not exists (
    select 1 from public.teachers t
     where t.id = p_teacher_id and t.center_id = p_center_id
       and t.is_active and t.deleted_at is null and t.booking_mode = 'hours'
  ) then
    return;
  end if;

  v_tz := public.center_timezone(p_center_id);
  v_today := (now() at time zone v_tz)::date;
  select b.horizon_days, b.step_min into v_horizon, v_step
    from public.booking_settings_unchecked(p_center_id) b;
  v_horizon := coalesce(v_horizon, 14);
  v_step := coalesce(v_step, 30);

  return query
    with cand as (
      -- Локальное начало окна: дата + начало интервала + k шагов; окно целиком
      -- внутри интервала (длина интервала в минутах ≥ k·шаг + длительность).
      select (g.day_ts::date + h.starts_at + make_interval(mins => k.n * v_step)) at time zone v_tz as s
        from generate_series(greatest(p_from, v_today)::timestamp,
                             least(p_to, v_today + v_horizon)::timestamp,
                             interval '1 day') as g(day_ts)
        join public.teacher_work_hours h
          on h.teacher_id = p_teacher_id
         and h.center_id = p_center_id
         and h.deleted_at is null
         and h.weekday = extract(isodow from g.day_ts)::smallint
        cross join lateral (
          select (extract(epoch from (h.ends_at - h.starts_at)) / 60)::integer as len
        ) l
        cross join lateral generate_series(
          0, case when l.len < v_duration then -1 else (l.len - v_duration) / v_step end
        ) as k(n)
    )
    select p_teacher_id, c.s, c.s + make_interval(mins => v_duration)
      from cand c
     where c.s >= now() + interval '30 minutes'
       -- Форма предиката EXCLUDE lessons_teacher_no_overlap (0006): тот же
       -- gist-индекс, замена занимает заменяющего, групповое занятие — тоже.
       and not exists (
         select 1 from public.lessons l
          where l.effective_teacher_id = p_teacher_id
            and l.deleted_at is null
            and l.status <> 'cancelled'
            and tstzrange(l.starts_at, l.ends_at) && tstzrange(c.s, c.s + make_interval(mins => v_duration))
       )
       -- Заявка держит окно 24 часа (Р5) — за весь свой интервал (Б7).
       and not exists (
         select 1 from public.booking_requests r
          where r.teacher_id = p_teacher_id
            and r.status = 'new'
            and r.created_at > now() - interval '24 hours'
            and tstzrange(r.starts_at, r.ends_at) && tstzrange(c.s, c.s + make_interval(mins => v_duration))
       )
     order by c.s;
end;
$$;

comment on function public.booking_slots_unchecked(uuid, uuid, uuid, date, date) is
  'Свободные окна специалиста в режиме hours (0109 Р4) — единственная копия правила окна: витрина, подача заявки и дайджест зовут только её. Пустой результат на чужую/неактивную/групповую услугу и специалиста не в режиме hours. Внутренняя: SECURITY INVOKER (зовут definer-функции), грантов нет, отказ при auth.uid() is not null.';

revoke all on function public.booking_slots_unchecked(uuid, uuid, uuid, date, date) from public, anon, authenticated, service_role;


-- 5. Режим и часы — RPC стойки (Р1, Р2) ----------------------------------------------------------

create or replace function public.set_teacher_booking(p_teacher_id uuid, p_mode text, p_intervals jsonb default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_teacher public.teachers;
  v_tz      text;
  v_bad     text;
  v_same    boolean;
  v_days    smallint[];
  v_starts  time[];
  v_ends    time[];
  v_result  jsonb := jsonb_build_object('requests', '[]'::jsonb, 'lessons', '[]'::jsonb);
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Онлайн-запись настраивают владелец и администратор' using errcode = '42501';
  end if;
  if not public.center_writable(v_center) then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  if not exists (select 1 from public.booking_modes m where m.code = p_mode) then
    raise exception 'Неизвестный режим записи' using errcode = '22023';
  end if;

  -- Параллельная правка часов одного специалиста — по очереди; замок того же
  -- класса, что у подачи заявки (Р6): смена режима не проскакивает мимо неё.
  perform pg_advisory_xact_lock(1090002, hashtext(p_teacher_id::text));
  select * into v_teacher
    from public.teachers t
   where t.id = p_teacher_id and t.center_id = v_center and t.deleted_at is null
   for update;
  if not found then
    raise exception 'Специалист не найден' using errcode = '42704';
  end if;
  if p_mode <> 'closed' and not v_teacher.is_active then
    raise exception 'Специалист в архиве — онлайн-запись к нему не открыть' using errcode = '22023';
  end if;

  -- p_intervals null — часы не трогаем; массив — полная неделя (дня нет — в
  -- этот день часов нет).
  if p_intervals is not null then
    if jsonb_typeof(p_intervals) <> 'array' then
      raise exception 'Рабочие часы — список интервалов' using errcode = '22023';
    end if;

    select string_agg(coalesce(e ->> 'weekday', '?') || ' ' || coalesce(e ->> 'starts_at', '?') || '–' || coalesce(e ->> 'ends_at', '?'), ', ')
      into v_bad
      from jsonb_array_elements(p_intervals) e
     where jsonb_typeof(e) <> 'object'
        or coalesce(e ->> 'weekday', '') !~ '^[1-7]$'
        or coalesce(e ->> 'starts_at', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        or coalesce(e ->> 'ends_at', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$';
    if v_bad is not null then
      raise exception 'Неверный интервал рабочих часов: %', v_bad using errcode = '22023';
    end if;

    -- Три массива с одним полным ключом сортировки — элементы выровнены.
    select coalesce(array_agg((e ->> 'weekday')::smallint
                              order by (e ->> 'weekday')::smallint, (e ->> 'starts_at')::time, (e ->> 'ends_at')::time), '{}'),
           coalesce(array_agg((e ->> 'starts_at')::time
                              order by (e ->> 'weekday')::smallint, (e ->> 'starts_at')::time, (e ->> 'ends_at')::time), '{}'),
           coalesce(array_agg((e ->> 'ends_at')::time
                              order by (e ->> 'weekday')::smallint, (e ->> 'starts_at')::time, (e ->> 'ends_at')::time), '{}')
      into v_days, v_starts, v_ends
      from jsonb_array_elements(p_intervals) e;

    if exists (select 1 from unnest(v_starts, v_ends) as x(s, e) where x.e <= x.s) then
      raise exception 'Конец рабочего интервала должен быть позже начала' using errcode = '22023';
    end if;
    if exists (
      select 1
        from unnest(v_days, v_starts, v_ends) with ordinality as a(d, s, e, i)
        join unnest(v_days, v_starts, v_ends) with ordinality as b(d, s, e, i)
          on a.d = b.d and a.i < b.i and a.s < b.e and b.s < a.e
    ) then
      raise exception 'Рабочие интервалы одного дня пересекаются' using errcode = '23P01';
    end if;

    v_same := array(select row(x.d, x.s, x.e)::text
                      from unnest(v_days, v_starts, v_ends) as x(d, s, e)
                     order by x.d, x.s, x.e)
              = array(select row(h.weekday, h.starts_at, h.ends_at)::text
                        from public.teacher_work_hours h
                       where h.teacher_id = p_teacher_id and h.center_id = v_center and h.deleted_at is null
                       order by h.weekday, h.starts_at, h.ends_at);

    if not v_same then
      update public.teacher_work_hours
         set deleted_at = now()
       where teacher_id = p_teacher_id and center_id = v_center and deleted_at is null;

      begin
        insert into public.teacher_work_hours (center_id, teacher_id, weekday, starts_at, ends_at)
        select v_center, p_teacher_id, x.d, x.s, x.e from unnest(v_days, v_starts, v_ends) as x(d, s, e);
      exception when exclusion_violation then
        raise exception 'Рабочие интервалы одного дня пересекаются' using errcode = '23P01';
      end;
    end if;
  end if;

  if v_teacher.booking_mode is distinct from p_mode then
    update public.teachers set booking_mode = p_mode where id = p_teacher_id;
  end if;

  -- Что выпало из новых часов — только показать стойке, ничего не отменяется.
  if p_mode = 'hours' then
    v_tz := public.center_timezone(v_center);
    select jsonb_build_object(
             'requests', coalesce((
               select jsonb_agg(jsonb_build_object('id', r.id, 'starts_at', r.starts_at, 'child_name', r.child_name)
                                order by r.starts_at)
                 from public.booking_requests r
                where r.center_id = v_center and r.teacher_id = p_teacher_id
                  and r.status = 'new' and r.starts_at > now()
                  and not exists (
                    select 1 from public.teacher_work_hours h
                     where h.teacher_id = p_teacher_id and h.center_id = v_center and h.deleted_at is null
                       and h.weekday = extract(isodow from r.starts_at at time zone v_tz)::smallint
                       and (r.starts_at at time zone v_tz)::date = (r.ends_at at time zone v_tz)::date
                       and (r.starts_at at time zone v_tz)::time >= h.starts_at
                       and (r.ends_at at time zone v_tz)::time <= h.ends_at)
             ), '[]'::jsonb),
             'lessons', coalesce((
               select jsonb_agg(jsonb_build_object('id', l.id, 'starts_at', l.starts_at) order by l.starts_at)
                 from (
                   select l.id, l.starts_at, l.ends_at
                     from public.lessons l
                    where l.center_id = v_center and l.effective_teacher_id = p_teacher_id
                      and l.status = 'planned' and l.deleted_at is null
                      and l.starts_at > now() and l.starts_at < now() + interval '62 days'
                    order by l.starts_at
                    limit 200
                 ) l
                where not exists (
                  select 1 from public.teacher_work_hours h
                   where h.teacher_id = p_teacher_id and h.center_id = v_center and h.deleted_at is null
                     and h.weekday = extract(isodow from l.starts_at at time zone v_tz)::smallint
                     and (l.starts_at at time zone v_tz)::date = (l.ends_at at time zone v_tz)::date
                     and (l.starts_at at time zone v_tz)::time >= h.starts_at
                     and (l.ends_at at time zone v_tz)::time <= h.ends_at)
             ), '[]'::jsonb)
           )
      into v_result;
  end if;

  return v_result;
end;
$$;

comment on function public.set_teacher_booking(uuid, text, jsonb) is
  'Режим онлайн-записи и рабочие часы специалиста (0109 Р1, Р2) — owner/admin. p_intervals: [{weekday 1..7, starts_at "HH:MM", ends_at "HH:MM"}] — полная неделя; null — часы не трогать. Ответ в режиме hours: живые заявки и planned-занятия (до 62 дней вперёд), выпавшие из часов, — ничего не отменено.';

revoke all on function public.set_teacher_booking(uuid, text, jsonb) from public, anon, service_role;
grant execute on function public.set_teacher_booking(uuid, text, jsonb) to authenticated;


-- 6. Заявки: удержание окна и лимит живых (Р5) ---------------------------------------------------

-- Живая заявка — одна на телефон и ребёнка в центре. До 0109 дублей ничто не
-- запрещало: оставляем последнюю, остальные закрываем отказом с причиной.
update public.booking_requests r
   set status = 'declined',
       decline_reason = 'Повтор той же заявки — оставлена последняя (0109)',
       decided_at = now()
 where r.status = 'new'
   and exists (
     select 1 from public.booking_requests r2
      where r2.center_id = r.center_id and r2.parent_phone = r.parent_phone and r2.status = 'new'
        and lower(btrim(r2.child_name)) = lower(btrim(r.child_name))
        and (r2.created_at, r2.id) > (r.created_at, r.id)
   );

create unique index if not exists booking_requests_live_key
  on public.booking_requests (center_id, parent_phone, lower(btrim(child_name))) where status = 'new';
create index if not exists booking_requests_hold_idx
  on public.booking_requests (teacher_id, starts_at) where status = 'new';

alter role public_booking set statement_timeout = '5s';
notify pgrst, 'reload config';


-- 7. Публичная витрина: перевыпуск и окна (Р4, Р6) -----------------------------------------------

-- Меняется RETURNS TABLE — drop + create, грант public_booking заново.
drop function if exists public.booking_center_info(text);

create function public.booking_center_info(p_slug text)
  returns table (
    is_open      boolean,
    center_name  text,
    timezone     text,
    services     jsonb,
    teachers     jsonb,
    horizon_days integer,
    step_min     integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center public.centers;
  v_h      integer;
  v_s      integer;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_center from public.centers c where c.slug = p_slug;

  if not found or not public.booking_published(v_center.id) then
    return query select false, null::text, null::text, null::jsonb, null::jsonb, null::integer, null::integer;
    return;
  end if;

  select b.horizon_days, b.step_min into v_h, v_s from public.booking_settings_unchecked(v_center.id) b;

  return query
    select
      true,
      v_center.name,
      public.center_timezone(v_center.id),
      coalesce((
        select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'duration_min', s.duration_min) order by s.name)
          from public.services s
         where s.center_id = v_center.id and s.is_active and s.deleted_at is null and s.kind = 'individual'
      ), '[]'::jsonb),
      -- closed — на витрине нет (Р1).
      coalesce((
        select jsonb_agg(jsonb_build_object('id', t.id, 'full_name', t.full_name, 'booking_mode', t.booking_mode)
                         order by t.full_name)
          from public.teachers t
         where t.center_id = v_center.id and t.is_active and t.deleted_at is null and t.booking_mode <> 'closed'
      ), '[]'::jsonb),
      v_h,
      v_s;
end;
$$;

comment on function public.booking_center_info(text) is
  'Публичное чтение витрины по slug (0057; 0109 — режим записи специалистов, горизонт и шаг). Только активные индивидуальные услуги и специалисты не в режиме closed, без телефонов и center_id. is_open=false для неизвестного/неопубликованного/read-only/удалённого центра — одинаково (0057 Р4).';

revoke all on function public.booking_center_info(text) from public, anon, authenticated, service_role;
grant execute on function public.booking_center_info(text) to public_booking;


create or replace function public.booking_teacher_busy(p_slug text, p_teacher_id uuid, p_date date)
  returns table (starts_at timestamptz, ends_at timestamptz)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid;
  v_tz     text;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select c.id into v_center from public.centers c where c.slug = p_slug;
  if v_center is null or not public.booking_published(v_center) then
    return;
  end if;

  -- 0109: специалист в режиме closed на витрине не существует (Р1).
  if not exists (
    select 1 from public.teachers t
     where t.id = p_teacher_id and t.center_id = v_center and t.is_active and t.deleted_at is null
       and t.booking_mode <> 'closed'
  ) then
    return;
  end if;

  v_tz := public.center_timezone(v_center);
  if p_date < public.center_today(v_center) or p_date > public.center_today(v_center) + 90 then
    return;
  end if;

  return query
    select l.starts_at, l.ends_at
      from public.lessons l
     where l.center_id = v_center
       and l.effective_teacher_id = p_teacher_id
       and l.deleted_at is null
       and l.status <> 'cancelled'
       and (l.starts_at at time zone v_tz)::date = p_date;
end;
$$;

comment on function public.booking_teacher_busy(text, uuid, date) is
  'Занятые интервалы специалиста на дату (0057) — для режима any; только starts_at/ends_at. 0109: специалист в режиме closed — пусто.';

revoke all on function public.booking_teacher_busy(text, uuid, date) from public, anon, authenticated, service_role;
grant execute on function public.booking_teacher_busy(text, uuid, date) to public_booking;


create or replace function public.booking_free_slots(
  p_slug       text,
  p_service_id uuid,
  p_teacher_id uuid,
  p_from       date default null,
  p_days       integer default null
)
  returns table (teacher_id uuid, starts_at timestamptz, ends_at timestamptz)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid;
  v_today   date;
  v_horizon integer;
  v_from    date;
  v_to      date;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select c.id into v_center from public.centers c where c.slug = p_slug;

  -- Единый отказ (0057 Р4): чужой slug, неопубликованный центр, чужая или
  -- неактивная услуга, групповая услуга, специалист не в режиме hours.
  if v_center is null or not public.booking_published(v_center)
     or not exists (
       select 1 from public.services s
        where s.id = p_service_id and s.center_id = v_center
          and s.is_active and s.deleted_at is null and s.kind = 'individual')
     or not exists (
       select 1 from public.teachers t
        where t.id = p_teacher_id and t.center_id = v_center
          and t.is_active and t.deleted_at is null and t.booking_mode = 'hours') then
    raise exception 'Запись сейчас недоступна' using errcode = '22023';
  end if;

  v_today := public.center_today(v_center);
  select b.horizon_days into v_horizon from public.booking_settings_unchecked(v_center) b;
  v_from := greatest(coalesce(p_from, v_today), v_today);
  v_to := least(v_from + least(greatest(coalesce(p_days, v_horizon), 1), v_horizon + 1) - 1, v_today + v_horizon);

  return query
    select s.teacher_id, s.starts_at, s.ends_at
      from public.booking_slots_unchecked(v_center, p_service_id, p_teacher_id, v_from, v_to) s;
end;
$$;

comment on function public.booking_free_slots(text, uuid, uuid, date, integer) is
  'Свободные окна для витрины (0109 Р4) — обёртка над booking_slots_unchecked: p_from не раньше сегодня центра, конец не дальше горизонта. Отдаёт только teacher_id/starts_at/ends_at. Единый отказ «Запись сейчас недоступна» на чужое и неактивное (0057 Р4).';

revoke all on function public.booking_free_slots(text, uuid, uuid, date, integer) from public, anon, authenticated, service_role;
grant execute on function public.booking_free_slots(text, uuid, uuid, date, integer) to public_booking;


-- 8. Лист ожидания (Р7, Р8) ----------------------------------------------------------------------

create table if not exists public.waitlist_entries (
  id                   uuid primary key default gen_random_uuid(),
  center_id            uuid not null references public.centers (id) on delete cascade,
  service_id           uuid not null,
  teacher_id           uuid,
  child_name           text not null,
  child_birth_date     date not null,
  preferred_weekdays   smallint[],
  preferred_from       time,
  preferred_to         time,
  parent_name          text not null,
  parent_phone         text not null,
  comment              text,
  status               text not null default 'waiting' references public.waitlist_statuses (code),
  offered_at           timestamptz,
  withdraw_reason      text,
  converted_student_id uuid,
  decided_by           uuid references auth.users (id) on delete set null,
  decided_at           timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,

  constraint waitlist_entries_names check (
    char_length(btrim(child_name)) between 1 and 200 and char_length(btrim(parent_name)) between 1 and 200),
  -- Грубая граница относительно даты подачи; точная (по сегодня центра) — в функции.
  constraint waitlist_entries_birth_date check (
    child_birth_date <= (created_at at time zone 'UTC')::date + 1
    and child_birth_date >= ((created_at at time zone 'UTC') - interval '25 years')::date),
  constraint waitlist_entries_weekdays check (
    preferred_weekdays is null
    or (cardinality(preferred_weekdays) between 1 and 7
        and array_position(preferred_weekdays, null) is null
        and preferred_weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[])),
  constraint waitlist_entries_time check (
    (preferred_from is null) = (preferred_to is null) and (preferred_to is null or preferred_to > preferred_from)),
  -- Как 0057 Р6: только нормализованный телефон, иначе лимит и дубль сравнивают разные записи одного номера.
  constraint waitlist_entries_phone check (
    public.normalize_kg_phone(parent_phone) is not null and parent_phone = public.normalize_kg_phone(parent_phone)),
  constraint waitlist_entries_comment check (comment is null or char_length(comment) <= 500),
  constraint waitlist_entries_withdraw_reason check (
    withdraw_reason is null or (status = 'withdrawn' and char_length(withdraw_reason) <= 500)),
  constraint waitlist_entries_enrolled check ((status = 'enrolled') = (converted_student_id is not null)),
  constraint waitlist_entries_decided check ((status in ('enrolled', 'withdrawn')) = (decided_at is not null)),
  constraint waitlist_entries_offered check (
    (status <> 'offered' or offered_at is not null) and (status <> 'waiting' or offered_at is null)),

  constraint waitlist_entries_service_fk foreign key (service_id, center_id)
    references public.services (id, center_id) on delete restrict,
  constraint waitlist_entries_teacher_fk foreign key (teacher_id, center_id)
    references public.teachers (id, center_id) on delete restrict,
  constraint waitlist_entries_student_fk foreign key (converted_student_id, center_id)
    references public.students (id, center_id)
);

comment on table public.waitlist_entries is
  'Лист ожидания с публичной витрины (0109 Р7): ребёнок, услуга, специалист (необязательно), удобные дни и время. Пишут только submit_waitlist_entry и RPC стойки; читает только стойка.';
comment on column public.waitlist_entries.preferred_weekdays is
  'Удобные дни недели, isodow 1..7; null — любой день. Пустой массив запрещён (null и {} значили бы одно и то же).';

-- Р8: повтор той же записи, пока она жива, — без второй строки.
create unique index if not exists waitlist_entries_live_key
  on public.waitlist_entries (center_id, parent_phone, lower(btrim(child_name)), service_id)
  where status in ('waiting', 'offered') and deleted_at is null;
create index if not exists waitlist_entries_queue_idx on public.waitlist_entries (center_id, status, created_at);
create index if not exists waitlist_entries_phone_idx on public.waitlist_entries (center_id, parent_phone, created_at desc);
create index if not exists waitlist_entries_status_idx on public.waitlist_entries (status);
create index if not exists waitlist_entries_service_idx on public.waitlist_entries (service_id, center_id);
create index if not exists waitlist_entries_teacher_idx on public.waitlist_entries (teacher_id, center_id);
create index if not exists waitlist_entries_student_idx on public.waitlist_entries (converted_student_id, center_id);
create index if not exists waitlist_entries_decided_by_idx on public.waitlist_entries (decided_by);

drop trigger if exists waitlist_entries_set_updated_at on public.waitlist_entries;
create trigger waitlist_entries_set_updated_at before update on public.waitlist_entries
  for each row execute function extensions.moddatetime(updated_at);

create or replace function public.waitlist_entries_transition()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if old.status in ('enrolled', 'withdrawn') then
    -- Каскад decided_by → null при удалении сотрудника (auth.users) — не
    -- правка записи; без исключения сотрудник, разобравший хоть одну запись,
    -- не удалялся бы вовсе (ревью SQL).
    if new.decided_by is null
       and (to_jsonb(new) - 'decided_by' - 'updated_at') = (to_jsonb(old) - 'decided_by' - 'updated_at') then
      return new;
    end if;
    raise exception 'Запись листа ожидания уже закрыта' using errcode = '22023';
  end if;
  if new.status is distinct from old.status
     and not ((old.status = 'waiting' and new.status in ('offered', 'withdrawn', 'enrolled'))
              or (old.status = 'offered' and new.status in ('withdrawn', 'enrolled'))) then
    raise exception 'Недопустимый переход листа ожидания: % → %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end;
$$;

comment on function public.waitlist_entries_transition() is
  'Переходы листа ожидания (0109 Р7): waiting → offered | withdrawn | enrolled, offered → withdrawn | enrolled; конечные статусы неизменны целиком.';

revoke all on function public.waitlist_entries_transition() from public, anon, authenticated, service_role;

drop trigger if exists waitlist_entries_transition on public.waitlist_entries;
create trigger waitlist_entries_transition before update on public.waitlist_entries
  for each row execute function public.waitlist_entries_transition();

call public.apply_tenant_rls('waitlist_entries');
call public.apply_role_rls('waitlist_entries', 'registrar', 'read', true);
call public.apply_audit('waitlist_entries');
call public.apply_readonly_guard('waitlist_entries');

-- Как booking_requests (0057 Р12): политика owner/admin «for all» без грантов
-- на запись не открывает ничего — все переходы только через RPC.
revoke all on public.waitlist_entries from public, anon, authenticated, service_role;
grant select on public.waitlist_entries to authenticated;


-- 9. Подача: заявка и лист ожидания (Р6, Р8) -----------------------------------------------------

create or replace function public.submit_booking_request(
  p_slug         text,
  p_service_id   uuid,
  p_teacher_id   uuid,
  p_starts_at    timestamptz,
  p_child_name   text,
  p_parent_name  text,
  p_parent_phone text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid;
  v_duration integer;
  v_mode     text;
  v_tz       text;
  v_day      date;
  v_ends_at  timestamptz;
  v_phone    text;
  v_id       uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select c.id into v_center from public.centers c where c.slug = p_slug;
  if v_center is null or not public.booking_published(v_center) then
    raise exception 'Запись сейчас недоступна' using errcode = '22023';
  end if;

  -- 0109: групповая услуга — тот же единый отказ (Р6).
  select s.duration_min into v_duration
    from public.services s
   where s.id = p_service_id and s.center_id = v_center and s.is_active and s.deleted_at is null
     and s.kind = 'individual';
  if not found then
    raise exception 'Запись сейчас недоступна' using errcode = '22023';
  end if;

  select t.booking_mode into v_mode
    from public.teachers t
   where t.id = p_teacher_id and t.center_id = v_center and t.is_active and t.deleted_at is null;
  if not found or v_mode = 'closed' then
    raise exception 'Запись сейчас недоступна' using errcode = '22023';
  end if;

  v_phone := public.normalize_kg_phone(p_parent_phone);
  if v_phone is null then
    raise exception 'Укажите номер телефона в кыргызском формате' using errcode = '22023';
  end if;
  if coalesce(trim(p_child_name), '') = '' or coalesce(trim(p_parent_name), '') = '' then
    raise exception 'Укажите имя ребёнка и имя родителя' using errcode = '22023';
  end if;

  -- Р6: замки до проверок, порядок «телефон → специалист» — тот же в
  -- submit_waitlist_entry (там только телефон). Без замка специалиста две
  -- заявки на одно окно читают генератор до чужого коммита.
  perform pg_advisory_xact_lock(1090001, hashtext(v_phone || ':' || v_center::text));
  perform pg_advisory_xact_lock(1090002, hashtext(p_teacher_id::text));

  -- Режим — заново после замка: set_teacher_booking берёт тот же замок, и
  -- смена any → hours/closed не проскакивает между проверкой и вставкой.
  select t.booking_mode into v_mode
    from public.teachers t
   where t.id = p_teacher_id and t.center_id = v_center and t.is_active and t.deleted_at is null;
  if not found or v_mode = 'closed' then
    raise exception 'Запись сейчас недоступна' using errcode = '22023';
  end if;

  if v_mode = 'hours' then
    -- Одна проверка вместо сетки, горизонта, lead time и длительности по
    -- отдельности: время обязано быть окном генератора на этот день (Р4).
    v_tz := public.center_timezone(v_center);
    v_day := (p_starts_at at time zone v_tz)::date;
    if not exists (
      select 1 from public.booking_slots_unchecked(v_center, p_service_id, p_teacher_id, v_day, v_day) s
       where s.starts_at = p_starts_at
    ) then
      raise exception 'Это время уже заняли — выберите другое' using errcode = '22023';
    end if;
  elsif p_starts_at < now() + interval '30 minutes' or p_starts_at > now() + interval '90 days' then
    raise exception 'Выберите время не раньше чем через 30 минут и не дальше 90 дней от сегодня' using errcode = '22023';
  end if;

  -- 0057 Р8, с 0109 — общий с листом ожидания: обе таблицы за час.
  if (select count(*) from public.booking_requests
       where center_id = v_center and created_at > now() - interval '1 hour')
     + (select count(*) from public.waitlist_entries
         where center_id = v_center and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Слишком много заявок на этот центр, попробуйте позже' using errcode = '22023';
  end if;
  if (select count(*) from public.booking_requests
       where center_id = v_center and parent_phone = v_phone and created_at > now() - interval '1 hour')
     + (select count(*) from public.waitlist_entries
         where center_id = v_center and parent_phone = v_phone and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Слишком много заявок с этого номера, попробуйте позже' using errcode = '22023';
  end if;

  -- Р5: живая заявка на ребёнка с номера — одна (booking_requests_live_key).
  -- Повтор — тот же успешный ответ без новой строки и события: отказ раскрыл
  -- бы постороннему, что семья уже обратилась в центр.
  select r.id into v_id
    from public.booking_requests r
   where r.center_id = v_center and r.parent_phone = v_phone and r.status = 'new'
     and lower(btrim(r.child_name)) = lower(btrim(p_child_name));
  if found then
    return v_id;
  end if;

  v_ends_at := p_starts_at + (v_duration * interval '1 minute');

  insert into public.booking_requests (
    center_id, service_id, teacher_id, starts_at, ends_at, child_name, parent_name, parent_phone
  ) values (
    v_center, p_service_id, p_teacher_id, p_starts_at, v_ends_at, trim(p_child_name), trim(p_parent_name), v_phone
  )
  returning id into v_id;

  perform public.emit_event_unchecked(
    'booking.requested',
    jsonb_build_object('request_id', v_id, 'teacher_id', p_teacher_id, 'service_id', p_service_id, 'starts_at', p_starts_at),
    v_center
  );

  return v_id;
end;
$$;

comment on function public.submit_booking_request(text, uuid, uuid, timestamptz, text, text, text) is
  'Подача заявки с публичной витрины (0057; 0109 Р6): только booking_requests. Режим hours — время обязано совпасть с окном booking_slots_unchecked; any — окно [+30 минут; +90 дней]; closed и групповая услуга — единый отказ. Живая заявка — одна на телефон и ребёнка в центре, повтор — тот же ответ без новой строки; лимиты по телефону и центру общие с листом ожидания.';

revoke all on function public.submit_booking_request(text, uuid, uuid, timestamptz, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.submit_booking_request(text, uuid, uuid, timestamptz, text, text, text) to public_booking;


create or replace function public.submit_waitlist_entry(
  p_slug             text,
  p_service_id       uuid,
  p_teacher_id       uuid,
  p_child_name       text,
  p_child_birth_date date,
  p_weekdays         smallint[],
  p_time_from        time,
  p_time_to          time,
  p_parent_name      text,
  p_parent_phone     text,
  p_comment          text default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid;
  v_today    date;
  v_phone    text;
  v_weekdays smallint[];
  v_comment  text := nullif(btrim(p_comment), '');
  v_id       uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select c.id into v_center from public.centers c where c.slug = p_slug;
  if v_center is null or not public.booking_published(v_center)
     or not exists (
       select 1 from public.services s
        where s.id = p_service_id and s.center_id = v_center
          and s.is_active and s.deleted_at is null and s.kind = 'individual')
     or (p_teacher_id is not null and not exists (
       select 1 from public.teachers t
        where t.id = p_teacher_id and t.center_id = v_center
          and t.is_active and t.deleted_at is null and t.booking_mode <> 'closed')) then
    raise exception 'Запись сейчас недоступна' using errcode = '22023';
  end if;

  v_phone := public.normalize_kg_phone(p_parent_phone);
  if v_phone is null then
    raise exception 'Укажите номер телефона в кыргызском формате' using errcode = '22023';
  end if;
  if coalesce(btrim(p_child_name), '') = '' or coalesce(btrim(p_parent_name), '') = '' then
    raise exception 'Укажите имя ребёнка и имя родителя' using errcode = '22023';
  end if;
  if char_length(btrim(p_child_name)) > 200 or char_length(btrim(p_parent_name)) > 200 then
    raise exception 'Слишком длинное имя' using errcode = '22023';
  end if;

  v_today := public.center_today(v_center);
  if p_child_birth_date is null or p_child_birth_date > v_today
     or p_child_birth_date < (v_today - interval '25 years')::date then
    raise exception 'Проверьте дату рождения ребёнка' using errcode = '22023';
  end if;

  -- Пустой выбор дней — «любой день», как и null (CHECK пустой массив не пускает).
  select array_agg(distinct d order by d) into v_weekdays
    from unnest(p_weekdays) d where d is not null;
  if v_weekdays is not null and not (v_weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]) then
    raise exception 'Неверный день недели' using errcode = '22023';
  end if;
  if (p_time_from is null) <> (p_time_to is null) or p_time_to <= p_time_from then
    raise exception 'Укажите удобное время «с» и «до»' using errcode = '22023';
  end if;
  if char_length(v_comment) > 500 then
    raise exception 'Комментарий — не длиннее 500 знаков' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(1090001, hashtext(v_phone || ':' || v_center::text));

  if (select count(*) from public.booking_requests
       where center_id = v_center and created_at > now() - interval '1 hour')
     + (select count(*) from public.waitlist_entries
         where center_id = v_center and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Слишком много заявок на этот центр, попробуйте позже' using errcode = '22023';
  end if;
  if (select count(*) from public.booking_requests
       where center_id = v_center and parent_phone = v_phone and created_at > now() - interval '1 hour')
     + (select count(*) from public.waitlist_entries
         where center_id = v_center and parent_phone = v_phone and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Слишком много заявок с этого номера, попробуйте позже' using errcode = '22023';
  end if;

  begin
    insert into public.waitlist_entries (
      center_id, service_id, teacher_id, child_name, child_birth_date,
      preferred_weekdays, preferred_from, preferred_to, parent_name, parent_phone, comment
    ) values (
      v_center, p_service_id, p_teacher_id, btrim(p_child_name), p_child_birth_date,
      v_weekdays, p_time_from, p_time_to, btrim(p_parent_name), v_phone, v_comment
    )
    returning id into v_id;
  exception when unique_violation then
    -- Р8 (Б4): тот же успешный ответ — повтор не раскрывает факт обращения.
    return;
  end;

  perform public.emit_event_unchecked('waitlist.created', jsonb_build_object('entry_id', v_id), v_center);
end;
$$;

comment on function public.submit_waitlist_entry(text, uuid, uuid, text, date, smallint[], time, time, text, text, text) is
  'Запись в лист ожидания с публичной витрины (0109 Р7, Р8). Проверки публикации и единый отказ — как у заявки; лимиты общие с заявками. Повтор живой записи — тот же успешный ответ без второй строки (Б4).';

revoke all on function public.submit_waitlist_entry(text, uuid, uuid, text, date, smallint[], time, time, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.submit_waitlist_entry(text, uuid, uuid, text, date, smallint[], time, time, text, text, text) to public_booking;


-- 10. Стойка: лист ожидания и «всё с этого номера» (Р9, Р11) -------------------------------------

create or replace function public.offer_waitlist_entry(p_entry_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.waitlist_entries
     set status = 'offered', offered_at = now()
   where id = p_entry_id and center_id = v_center and deleted_at is null
     and status in ('waiting', 'offered');
  if not found then
    raise exception 'Запись уже обработана' using errcode = '22023';
  end if;
end;
$$;

comment on function public.offer_waitlist_entry(uuid) is
  'Стойка предложила родителю время (0109 Р7): waiting/offered → offered, offered_at — время последнего предложения.';

revoke all on function public.offer_waitlist_entry(uuid) from public, anon, service_role;
grant execute on function public.offer_waitlist_entry(uuid) to authenticated;


create or replace function public.withdraw_waitlist_entry(p_entry_id uuid, p_reason text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_reason text := nullif(btrim(p_reason), '');
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'Причина — не длиннее 500 знаков' using errcode = '22023';
  end if;

  update public.waitlist_entries
     set status = 'withdrawn', withdraw_reason = v_reason, decided_by = auth.uid(), decided_at = now()
   where id = p_entry_id and center_id = v_center and deleted_at is null
     and status in ('waiting', 'offered');
  if not found then
    raise exception 'Запись уже обработана' using errcode = '22023';
  end if;
end;
$$;

comment on function public.withdraw_waitlist_entry(uuid, text) is
  'Родитель отказался или запись больше не нужна (0109 Р7): waiting/offered → withdrawn.';

revoke all on function public.withdraw_waitlist_entry(uuid, text) from public, anon, service_role;
grant execute on function public.withdraw_waitlist_entry(uuid, text) to authenticated;


create or replace function public.waitlist_entry_payer_match(p_entry_id uuid)
  returns table (payer_id uuid, payer_name text)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_phone  text;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select w.parent_phone into v_phone
    from public.waitlist_entries w
   where w.id = p_entry_id and w.center_id = v_center and w.deleted_at is null;
  if not found then
    raise exception 'Запись не найдена' using errcode = '42704';
  end if;

  -- Тем же выражением, что payers_center_phone_uniq (0005), — как
  -- booking_request_payer_match (0057 Р5).
  return query
    select p.id, p.full_name
      from public.payers p
     where p.center_id = v_center and p.deleted_at is null
       and public.normalize_kg_phone(p.phone) = v_phone;
end;
$$;

comment on function public.waitlist_entry_payer_match(uuid) is
  'Предпросмотр совпадения по телефону перед записью из листа ожидания (0109 Р9, как 0057 Р5) — стойка решает сама, привязать к найденному плательщику или завести нового.';

revoke all on function public.waitlist_entry_payer_match(uuid) from public, anon, service_role;
grant execute on function public.waitlist_entry_payer_match(uuid) to authenticated;


create or replace function public.enroll_waitlist_entry(p_entry_id uuid, p_payer_id uuid default null)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_entry   public.waitlist_entries;
  v_payer   uuid;
  v_teacher uuid;
  v_student uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р9: захват раньше создания ученика. Параллельный вызов ждёт замок, после
  -- коммита первого перечитывает строку и видит конечный статус.
  select * into v_entry
    from public.waitlist_entries
   where id = p_entry_id and center_id = v_center and deleted_at is null
     and status in ('waiting', 'offered')
   for update;
  if not found then
    raise exception 'Запись уже обработана' using errcode = '22023';
  end if;

  -- Б5: плательщик — явный выбор стойки; поиск по телефону
  -- create_student_with_payer в этом пути не участвует.
  if p_payer_id is not null then
    if not exists (select 1 from public.payers where id = p_payer_id and center_id = v_center and deleted_at is null) then
      raise exception 'Плательщик не найден в этом центре' using errcode = '22023';
    end if;
    v_payer := p_payer_id;
  else
    begin
      insert into public.payers (center_id, full_name, phone)
      values (v_center, v_entry.parent_name, v_entry.parent_phone)
      returning id into v_payer;
    exception when unique_violation then
      raise exception 'По этому номеру уже есть плательщик — выберите его в списке совпадений и запишите заново'
        using errcode = '22023';
    end;

    perform public.emit_event('payer.created',
      jsonb_build_object('center_id', v_center, 'payer_id', v_payer, 'full_name', v_entry.parent_name), v_center);
  end if;

  select t.id into v_teacher
    from public.teachers t
   where t.id = v_entry.teacher_id and t.center_id = v_center and t.deleted_at is null;

  select cs.student_id into v_student
    from public.create_student_with_payer(
      p_full_name          := v_entry.child_name,
      p_payer_id           := v_payer,
      p_birth_date         := v_entry.child_birth_date,
      p_primary_teacher_id := v_teacher,
      p_source             := 'waitlist',
      p_funnel_stage       := 'lead'
    ) cs;

  update public.waitlist_entries
     set status = 'enrolled', converted_student_id = v_student, decided_by = auth.uid(), decided_at = now()
   where id = p_entry_id;

  return v_student;
end;
$$;

comment on function public.enroll_waitlist_entry(uuid, uuid) is
  'Записать ребёнка из листа ожидания (0109 Р9): захват for update по живому статусу, плательщик — явный выбор стойки (null — новый из текста записи, совпадение по телефону — понятная ошибка), ученик — create_student_with_payer с готовым payer_id. Занятие ставит стойка обычным путём.';

revoke all on function public.enroll_waitlist_entry(uuid, uuid) from public, anon, service_role;
grant execute on function public.enroll_waitlist_entry(uuid, uuid) to authenticated;


create or replace function public.decline_booking_phone(p_request_id uuid, p_reason text default null)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_phone  text;
  v_reason text := coalesce(nullif(btrim(p_reason), ''), 'Отклонено вместе со всем с этого номера');
  v_n      integer;
  v_m      integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'Причина — не длиннее 500 знаков' using errcode = '22023';
  end if;

  select r.parent_phone into v_phone
    from public.booking_requests r
   where r.id = p_request_id and r.center_id = v_center and r.deleted_at is null;
  if not found then
    raise exception 'Заявка не найдена' using errcode = '42704';
  end if;

  -- Замок подачи (Р6): заявка или запись, подаваемая в этот момент, не
  -- переживёт «всё с этого номера».
  perform pg_advisory_xact_lock(1090001, hashtext(v_phone || ':' || v_center::text));

  update public.booking_requests
     set status = 'declined', decline_reason = v_reason, decided_by = auth.uid(), decided_at = now()
   where center_id = v_center and parent_phone = v_phone and status = 'new' and deleted_at is null;
  get diagnostics v_n = row_count;

  update public.waitlist_entries
     set status = 'withdrawn', withdraw_reason = v_reason, decided_by = auth.uid(), decided_at = now()
   where center_id = v_center and parent_phone = v_phone and status in ('waiting', 'offered') and deleted_at is null;
  get diagnostics v_m = row_count;

  return v_n + v_m;
end;
$$;

comment on function public.decline_booking_phone(uuid, text) is
  'Отклонить всё с номера заявки (0109 Р11): живые заявки и записи листа ожидания с того же телефона. Ответ — сколько закрыто.';

revoke all on function public.decline_booking_phone(uuid, text) from public, anon, service_role;
grant execute on function public.decline_booking_phone(uuid, text) to authenticated;


-- 11. Уведомления стойке и дайджест (Р10) --------------------------------------------------------

insert into public.notification_event_types (event_type, description, audience, subject_required, channels, mandatory) values
  ('waitlist.created', 'Новая запись в лист ожидания',              'center', false, array['telegram', 'whatsapp_link'], false),
  ('waitlist.digest',  'Лист ожидания: есть свободные окна на неделю', 'center', false, array['telegram', 'whatsapp_link'], false)
on conflict (event_type) do nothing;

insert into public.message_templates (center_id, event_type, channel, text) values
  (null, 'waitlist.created', 'telegram',
   'Лист ожидания: {child} — {service}, специалист: {teacher}. Телефон: {phone}. Откройте «Заявки → Лист ожидания» в CRM.'),
  (null, 'waitlist.created', 'whatsapp_link',
   'Лист ожидания: {child} — {service}, специалист: {teacher}. Телефон: {phone}. Откройте «Заявки → Лист ожидания» в CRM.'),
  (null, 'waitlist.digest', 'telegram',
   'В листе ожидания {waiting}. Подходящих им свободных окон на неделю: {free_slots}. Откройте «Заявки → Лист ожидания» в CRM.'),
  (null, 'waitlist.digest', 'whatsapp_link',
   'В листе ожидания {waiting}. Подходящих им свободных окон на неделю: {free_slots}. Откройте «Заявки → Лист ожидания» в CRM.');


create table if not exists public.waitlist_digest_runs (
  center_id uuid not null references public.centers (id) on delete cascade,
  day       date not null,
  sent_at   timestamptz not null default now(),
  primary key (center_id, day)
);

comment on table public.waitlist_digest_runs is
  'Дайджест листа ожидания центру за day отправлен (0109 Р10, Б6). Первичный ключ — «раз в день»; строки кладёт только waitlist_digest_at().';

alter table public.waitlist_digest_runs enable row level security;

drop policy if exists waitlist_digest_runs_read on public.waitlist_digest_runs;
create policy waitlist_digest_runs_read on public.waitlist_digest_runs
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() in ('owner', 'admin')
  );

revoke all on table public.waitlist_digest_runs from public, anon, authenticated, service_role;
grant select on public.waitlist_digest_runs to authenticated;


create or replace function public.waitlist_digest_at(p_now timestamptz)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_count integer := 0;
  v_tz    text;
  v_n     integer;
  v_k     integer;
  r       record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    select c.id as center_id, (p_now at time zone public.center_timezone(c.id))::date as day
      from public.centers c
     where c.deleted_at is null
       and extract(hour from (p_now at time zone public.center_timezone(c.id))) between 10 and 19
       -- booking_published включает center_writable: read-only центры пропускаются.
       and public.booking_published(c.id)
       and exists (
         select 1 from public.waitlist_entries w
          where w.center_id = c.id and w.status = 'waiting' and w.deleted_at is null
       )
       and exists (
         select 1 from public.teachers t
          where t.center_id = c.id and t.booking_mode = 'hours' and t.is_active and t.deleted_at is null
       )
       and public.center_notification_enabled(c.id, 'waitlist.digest')
       and not exists (
         select 1 from public.waitlist_digest_runs d
          where d.center_id = c.id and d.day = (p_now at time zone public.center_timezone(c.id))::date
       )
     order by c.id
  loop
    -- Каждый центр — в своей подтранзакции, как debt_reminders_at (0097):
    -- ошибка одного не отменяет дайджест остальных.
    begin
      v_tz := public.center_timezone(r.center_id);

      select count(*)::integer into v_n
        from public.waitlist_entries w
       where w.center_id = r.center_id and w.status = 'waiting' and w.deleted_at is null;

      -- K — окна на 7 дней, совпавшие с удобными днями и временем ожидающих;
      -- одно окно, подходящее двоим, считается один раз. Объём ограничен
      -- 50 старейшими записями: генератор × специалисты × записи — самая
      -- тяжёлая часть notification_schedules, statement_timeout отменил бы
      -- и остальные рассылки.
      select count(*)::integer into v_k
        from (
          select distinct s.teacher_id, s.starts_at
            from (
              select w.* from public.waitlist_entries w
               where w.center_id = r.center_id and w.status = 'waiting' and w.deleted_at is null
               order by w.created_at
               limit 50
            ) w
            join public.teachers t
              on t.center_id = w.center_id and t.booking_mode = 'hours' and t.is_active and t.deleted_at is null
             and (w.teacher_id is null or t.id = w.teacher_id)
            cross join lateral public.booking_slots_unchecked(w.center_id, w.service_id, t.id, r.day, r.day + 6) s
           where (w.preferred_weekdays is null
                  or extract(isodow from (s.starts_at at time zone v_tz))::smallint = any (w.preferred_weekdays))
             and (w.preferred_from is null
                  or ((s.starts_at at time zone v_tz)::time >= w.preferred_from
                      and (s.ends_at at time zone v_tz)::time <= w.preferred_to))
        ) x;

      if v_k > 0 then
        insert into public.waitlist_digest_runs (center_id, day)
        values (r.center_id, r.day)
        on conflict (center_id, day) do nothing;

        if found then
          perform public.emit_event_unchecked('waitlist.digest',
            jsonb_build_object('center_id', r.center_id, 'day', r.day, 'waiting', v_n, 'free_slots', v_k),
            r.center_id
          );
          v_count := v_count + 1;
        end if;
      end if;
    exception when others then
      raise warning 'waitlist_digest_at: центр % — %', r.center_id, sqlerrm;
    end;
  end loop;

  return v_count;
end;
$$;

comment on function public.waitlist_digest_at(timestamptz) is
  'Дайджест листа ожидания (0109 Р10): с 10 до 20 по часам центра, раз в день (waitlist_digest_runs), только опубликованные пишущие центры с ожидающими и специалистами в режиме hours и только если подходящих окон на неделю больше нуля. Внутренняя: SECURITY INVOKER, грантов нет ни у кого.';

revoke all on function public.waitlist_digest_at(timestamptz)
  from public, anon, authenticated, service_role, bot_worker;


-- Меняется RETURNS TABLE — drop + create, грант bot_worker заново (нода n8n
-- читает строку целиком — новая колонка ей не мешает).
drop function if exists public.notification_schedules();

create function public.notification_schedules()
  returns table (teacher_schedules integer, debt_reminders integer, period_reminders integer, waitlist_digests integer)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_teacher  integer := 0;
  v_debt     integer := 0;
  v_period   integer := 0;
  v_waitlist integer := 0;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  begin
    v_teacher := public.teacher_schedules_at(now());
  exception when others then
    raise warning 'notification_schedules: teacher.schedule — %', sqlerrm;
  end;

  begin
    v_debt := public.debt_reminders_at(now());
  exception when others then
    raise warning 'notification_schedules: debt.reminder — %', sqlerrm;
  end;

  begin
    v_period := public.period_subscription_reminders_at(now());
  exception when others then
    raise warning 'notification_schedules: subscription.period_ending — %', sqlerrm;
  end;

  begin
    v_waitlist := public.waitlist_digest_at(now());
  exception when others then
    raise warning 'notification_schedules: waitlist.digest — %', sqlerrm;
  end;

  return query select v_teacher, v_debt, v_period, v_waitlist;
end;
$$;

comment on function public.notification_schedules() is
  'Плановые рассылки (0097; 0109 — дайджест листа ожидания): расписание специалистам, долг раз в неделю, окончание абонемента на срок, лист ожидания. Запуск раз в час отдельной нодой сценария n8n schedule под bot_worker. Каждая рассылка — в своей подтранзакции.';

revoke all on function public.notification_schedules() from public, anon, authenticated, service_role;
grant execute on function public.notification_schedules() to bot_worker;



-- 12. event_messages: ветки листа ожидания (Р10) -------------------------------------------------

-- Переиздаётся целиком от последней редакции (0097): поиск
-- "create or replace function public.event_messages" по всем миграциям.
-- Отличия от 0097: ветки waitlist.created и waitlist.digest после booking.requested.
create or replace function public.event_messages(p_event_id bigint)
  returns table (
    recipient_user_id uuid,
    channel           text,
    chat_id           bigint,
    message           text,
    subject_id        uuid,
    action            jsonb
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_event    public.events;
  v_tz       text;
  v_vars     jsonb := '{}'::jsonb;
  v_student  uuid;
  v_payer    uuid;
  v_lesson   record;
  v_homework public.homework;
  v_note     public.lesson_notes;
  v_request  public.lesson_voice_requests;
  v_child    text;
  v_summary  text;
  v_days     integer;
  v_debt_text text;
  v_user     uuid;
  v_ends     date;
  v_starts   timestamptz;
  v_status   text;
  v_day      date;
  v_n        integer;
  v_list     text;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if not found then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  v_tz := public.center_timezone(v_event.center_id);

  -- 0053 Р8/Р10: лимит голосовых резюме — заказчику диктовки ({child} только
  -- в telegram, с предлогом внутри) и owner/admin центра (без {child}, без
  -- subject), пока повтор диктовки имеет смысл (0047 Р4). Заказчик-владелец
  -- не получает двух строк.
  if v_event.type = 'ai.quota_exceeded' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    v_vars := jsonb_build_object(
      'used',  coalesce(v_event.payload ->> 'used', ''),
      'limit', coalesce(v_event.payload ->> 'limit', '')
    );

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               v_vars || jsonb_build_object('child',
                 case when r.channel = 'telegram' then ' по ' || v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r
      union all
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', '')),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r
       where r.user_id <> v_request.requested_by;
    return;
  end if;

  -- 0052: срок заканчивается / истёк — owner/admin центра. {when} и {until}
  -- считаются на момент доставки в поясе центра (Р6).
  if v_event.type in ('subscription.ending', 'subscription.expired') then
    v_days := ((v_event.payload ->> 'until')::timestamptz at time zone v_tz)::date
              - (now() at time zone v_tz)::date;
    v_vars := jsonb_build_object(
      'what',  case when (v_event.payload ->> 'is_trial')::boolean then 'Пробный период' else 'Подписка' end,
      'until', to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY')
    );
    -- {when} есть только у «заканчивается»: у истёкшего срока «сегодня» врало бы.
    if v_event.type = 'subscription.ending' then
      v_vars := v_vars || jsonb_build_object('when', case
                 when v_days <= 0 then 'сегодня'
                 when v_days = 1 then 'завтра'
                 else 'через ' || v_days::text || ' дн.'
               end);
    end if;
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0051: заявка на оплату — администраторам платформы, шаблон только
  -- дефолтный (Р10), суммы и пояс — центра-заявителя (Р12).
  if v_event.type = 'platform.payment_submitted' then
    v_vars := jsonb_build_object(
      'center_name', coalesce((select c.name from public.centers c where c.id = v_event.center_id), '—'),
      'plan_name',   coalesce((select p.name from public.plans p where p.code = v_event.payload ->> 'plan'), coalesce(v_event.payload ->> 'plan', '—')),
      'months',      coalesce(v_event.payload ->> 'months', ''),
      'amount',      public.format_som(coalesce((v_event.payload ->> 'amount_tiyin')::bigint, 0)),
      'source',      case v_event.payload ->> 'source'
                       when 'mbank' then 'Mbank' when 'elcart' then 'Elcart'
                       when 'cash' then 'наличные' else 'другое' end,
      'payment_id',  coalesce(v_event.payload ->> 'payment_id', '')
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_platform_targets(v_event.type) r;
    return;
  end if;

  -- 0051: продление — owner/admin центра; {until} в поясе центра (Р12).
  if v_event.type = 'subscription.extended' then
    v_vars := jsonb_build_object(
      'plan_name', coalesce((select p.name from public.plans p where p.code = v_event.payload ->> 'plan'), coalesce(v_event.payload ->> 'plan', '—')),
      'months',    coalesce(v_event.payload ->> 'months', ''),
      'until',     coalesce(to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY'), '—')
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0056: заявка на удаление центра — owner/admin (в т.ч. второй владелец,
  -- который её не подавал), без {until}.
  if v_event.type = 'center.deletion_requested' then
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, '{}'::jsonb),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0057: заявка с публичной витрины записи — стойке (owner/admin/
  -- registrar, notification_front_desk_targets — не notification_admin_
  -- targets, регистратор реально разбирает очередь). {child}/{teacher}/
  -- {when}/{phone} читаются заново на момент доставки, не из payload —
  -- заявку могли обработать до отправки, а специалиста переименовать.
  if v_event.type = 'booking.requested' then
    declare
      v_booking      public.booking_requests;
      v_teacher_name text;
    begin
      -- emit_event открыта authenticated и проверяет только center_id
      -- аргумента — payload не доверенный ключ, откуда читать. Без фильтра
      -- по center_id участник центра X мог бы эмитировать событие с
      -- request_id чужой заявки и получить в свой телеграм имя ребёнка и
      -- телефон родителя центра Y (архитектор, раунд 3, п.3).
      select * into v_booking from public.booking_requests
       where id = (v_event.payload ->> 'request_id')::uuid
         and center_id = v_event.center_id
         and deleted_at is null;
      if not found then
        return;
      end if;

      select t.full_name into v_teacher_name from public.teachers t where t.id = v_booking.teacher_id;

      v_vars := jsonb_build_object(
        'child', v_booking.child_name,
        'teacher', coalesce(v_teacher_name, 'специалист'),
        'when', to_char(v_booking.starts_at at time zone v_tz, 'DD.MM HH24:MI'),
        'phone', v_booking.parent_phone
      );

      return query
        select r.user_id, r.channel, r.chat_id,
               public.render_template(r.template_text, v_vars),
               null::uuid,
               null::jsonb
          from public.notification_front_desk_targets(v_event.center_id, v_event.type) r;
      return;
    end;
  end if;

  -- 0109 Р10: запись в лист ожидания — стойке. Строка читается заново на
  -- момент доставки и только в центре события; дата рождения и комментарий в
  -- текст не идут (там может быть диагноз). Закрытая к доставке — пусто.
  if v_event.type = 'waitlist.created' then
    declare
      v_entry public.waitlist_entries;
    begin
      select * into v_entry from public.waitlist_entries
       where id = (v_event.payload ->> 'entry_id')::uuid
         and center_id = v_event.center_id
         and deleted_at is null
         and status in ('waiting', 'offered');
      if not found then
        return;
      end if;

      v_vars := jsonb_build_object(
        'child',   v_entry.child_name,
        'service', coalesce((select s.name from public.services s
                              where s.id = v_entry.service_id and s.center_id = v_event.center_id), 'услуга'),
        'teacher', coalesce((select t.full_name from public.teachers t
                              where t.id = v_entry.teacher_id and t.center_id = v_event.center_id), 'любой'),
        'phone',   v_entry.parent_phone
      );

      return query
        select r.user_id, r.channel, r.chat_id,
               public.render_template(r.template_text, v_vars),
               null::uuid,
               null::jsonb
          from public.notification_front_desk_targets(v_event.center_id, v_event.type) r;
      return;
    end;
  end if;

  -- 0109 Р10: дайджест листа ожидания — стойке. Числа — снимок планировщика;
  -- сводка за прошедший день после простоя n8n не отправляется.
  if v_event.type = 'waitlist.digest' then
    v_day := (v_event.payload ->> 'day')::date;
    if v_day < (now() at time zone v_tz)::date then
      return;
    end if;
    v_n := coalesce((v_event.payload ->> 'waiting')::integer, 0);

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'waiting',    v_n::text || ' ' || case
                               when v_n % 10 = 1 and v_n % 100 <> 11 then 'ребёнок'
                               when v_n % 10 between 2 and 4 and v_n % 100 not between 12 and 14 then 'ребёнка'
                               else 'детей' end,
               'free_slots', coalesce(v_event.payload ->> 'free_slots', '0')
             )),
             null::uuid,
             null::jsonb
        from public.notification_front_desk_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0051 Р9: подписка истекла между диктовкой и обработкой — заказчику
  -- диктовки, если он всё ещё сотрудник (0047 Р2) и повтор диктовки ещё
  -- имеет смысл (0047 Р4, дословно как у lesson.voice_failed — текст просит
  -- записать заново, и просить это при утверждённой заметке нельзя).
  -- {child} только в telegram.
  if v_event.type = 'subscription.voice_blocked' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               jsonb_build_object('child',
                 case when r.channel = 'telegram' then v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r;
    return;
  end if;

  if v_event.type = 'lesson.reminder' then
    select l.starts_at, l.status, l.deleted_at, coalesce(t.full_name, '—') as teacher
      into v_lesson
      from public.lessons l
      left join public.teachers t on t.id = l.effective_teacher_id
     where l.id = (v_event.payload ->> 'lesson_id')::uuid
       and l.center_id = v_event.center_id;

    -- 0097 п.9: занятие перенесли после напоминания (у нового времени своё
    -- напоминание) или оно уже началось — пусто. starts_at в payload кладёт
    -- lesson_reminders с 0032; событие без него (вставленное руками в тестах
    -- до 0075) сверяется только по началу.
    if not found or v_lesson.deleted_at is not null or v_lesson.status <> 'planned'
       or (v_event.payload ? 'starts_at'
           and v_lesson.starts_at is distinct from (v_event.payload ->> 'starts_at')::timestamptz)
       or v_lesson.starts_at <= now() then
      return;
    end if;

    -- 0097 В1: {day} — «сегодня», «завтра» или дата на момент доставки.
    v_vars := jsonb_build_object(
      'date',    to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY'),
      'time',    to_char(v_lesson.starts_at at time zone v_tz, 'HH24:MI'),
      'day',     public.lesson_reminder_day(v_lesson.starts_at, v_tz, now()),
      'teacher', v_lesson.teacher
    );

    return query
      with participants as (
        select lp.student_id, s.full_name, s.payer_id
          from public.lesson_participants lp
          join public.students s on s.id = lp.student_id and s.deleted_at is null
         where lp.lesson_id = (v_event.payload ->> 'lesson_id')::uuid
           and lp.deleted_at is null
      )
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', p.full_name)),
             p.student_id,
             case when r.chat_id is null then null else jsonb_build_object(
               'label', 'Подтвердить приход',
               'callback_data', 'c:' || v_event.id::text || ':' || p.student_id::text
             ) end
        from participants p
        join lateral public.notification_targets(v_event.center_id, p.payer_id, v_event.type) r on true;
    return;
  end if;

  -- 0043: месячный отчёт. Текст уже заморожен в событии (Р4 из 0043) —
  -- здесь он только подставляется, ничего не пересчитывается.
  if v_event.type = 'report.monthly_ready' then
    v_student := (v_event.payload ->> 'student_id')::uuid;

    select s.payer_id into v_payer
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    -- 0047 Р10: текст отчёта — только в telegram, вне его пусто.
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'summary', case when r.channel = 'telegram'
                               then coalesce(v_event.payload ->> 'summary', '') else '' end,
               'month',   to_char((v_event.payload ->> 'period_month')::date, 'MM.YYYY'),
               'child',   (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0047: утверждённое резюме — родителю. Перечитывается на момент
  -- доставки (Р4); {summary} только в telegram (Р1); длина ограничена (Р5).
  if v_event.type = 'lesson.note_approved' then
    select * into v_note from public.lesson_notes n
     where n.id = (v_event.payload ->> 'lesson_note_id')::uuid
       and n.center_id = v_event.center_id
       and n.deleted_at is null
       and n.status = 'approved';
    if not found or coalesce(trim(v_note.parent_summary), '') = '' then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_note.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_note.student_id;
    select s.payer_id, s.full_name into v_payer, v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    v_summary := case
      when length(v_note.parent_summary) > 3500 then left(v_note.parent_summary, 3499) || '…'
      else v_note.parent_summary
    end;
    v_vars := jsonb_build_object(
      'child', v_child,
      'date',  to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY')
    );

    -- Р1: вне telegram переменная пуста, а не отсутствует — иначе
    -- render_template оставит «{summary}» буквально.
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               v_vars || jsonb_build_object('summary',
                 case when r.channel = 'telegram' then v_summary else '' end)),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0047: отказ обработки диктовки — заказчику диктовки, если он всё ещё
  -- сотрудник центра (Р2) и повтор диктовки ещё имеет смысл (Р4).
  -- Причина отказа в текст не идёт (Р6).
  if v_event.type = 'lesson.voice_failed' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    -- Р4: дословно условие отказа ai_job_begin (0042) — утверждено или
    -- голосовой черновик другой диктовки. Ручной черновик не гасит.
    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               jsonb_build_object('child',
                 case when r.channel = 'telegram' then v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r;
    return;
  end if;

  -- 0045: выдано родителю. Шлём независимо от текущего статуса задания —
  -- факт выдачи не перестаёт быть фактом, даже если уже сдано (Р4).
  if v_event.type = 'homework.assigned' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student),
               'due',   coalesce(to_char(v_homework.due_on, 'DD.MM.YYYY'), 'без срока')
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0045: специалисту, что сдано. Шлём, только если статус ВСЁ ЕЩЁ
  -- submitted — напоминание «проверьте» после того, как уже проверено,
  -- вводит в заблуждение (Р4, в отличие от assigned выше).
  if v_event.type = 'homework.submitted' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found or v_homework.status <> 'submitted' then
      return;
    end if;

    v_student := v_homework.student_id;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_homework_targets(v_event.center_id, v_homework.id, v_event.type) r;
    return;
  end if;

  -- 0045: специалист проверил — родителю.
  if v_event.type = 'homework.reviewed' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0097 В2: долг раз в неделю — сумма на момент доставки тем же расчётом,
  -- что /balance в боте (bot_balance_center от имени родителя плательщика):
  -- долг за занятия с перерасходом и просрочка по абонементу — отдельно, не
  -- складываются (0077 Р6). Ошибка расчёта всплывает (п.13): fail_events
  -- повторит доставку, а не запишет «получателей нет».
  if v_event.type = 'debt.reminder' then
    v_payer := (v_event.payload ->> 'payer_id')::uuid;

    select m.user_id into v_user
      from public.memberships m
     where m.center_id = v_event.center_id
       and m.role = 'parent'
       and m.payer_id = v_payer
     order by m.user_id
     limit 1;
    if v_user is null then
      return;
    end if;

    return query
      with b as (
        select x.student_id, x.full_name,
               x.debt_tiyin, x.overdue_tiyin
          from public.bot_balance_center(v_user, v_event.center_id) x
         where x.debt_tiyin > 0 or x.overdue_tiyin > 0
      )
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', b.full_name,
               'debt', concat_ws('; ',
                 case when b.debt_tiyin > 0 then 'долг за занятия — ' || public.format_som(b.debt_tiyin) end,
                 case when b.overdue_tiyin > 0 then 'просрочка по абонементу — ' || public.format_som(b.overdue_tiyin) end)
             )),
             b.student_id,
             null::jsonb
        from b
        cross join lateral public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0097 В3: абонемент на срок заканчивается. Всё перечитывается на момент
  -- доставки: отменён, в архиве, срок сдвинут или продлён — пусто.
  -- Получатель — текущий плательщик ребёнка (п.8).
  if v_event.type = 'subscription.period_ending' then
    select s.student_id, st.full_name, st.payer_id, s.ends_at
      into v_student, v_child, v_payer, v_ends
      from public.subscriptions s
      join public.students st on st.id = s.student_id and st.deleted_at is null and st.status <> 'archived'
     where s.id = (v_event.payload ->> 'subscription_id')::uuid
       and s.center_id = v_event.center_id
       and s.status = 'active'
       and s.deleted_at is null
       and s.ends_at = (v_event.payload ->> 'ends_at')::date
       and s.ends_at >= (now() at time zone v_tz)::date;
    if v_student is null or public.subscription_renewed((v_event.payload ->> 'subscription_id')::uuid) then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', v_child,
               'date',  to_char(v_ends, 'DD.MM.YYYY')
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0097 В4, Б3: отметка со статусом «Уведомлять родителя». Пусто, если
  -- событие старше 12 часов, занятию больше 3 суток, статус с тех пор
  -- сменили (уйдёт по своему событию) или галочку сняли; тому же получателю
  -- то же (отметка, статус) уже уходило — не повторяем.
  if v_event.type = 'attendance.status_changed' then
    if v_event.created_at < now() - interval '12 hours' then
      return;
    end if;

    select a.student_id, st.full_name, st.payer_id, l.starts_at, ast.name
      into v_student, v_child, v_payer, v_starts, v_status
      from public.attendance a
      join public.attendance_statuses ast on ast.id = a.status_id and ast.notify_parent
      join public.lessons l on l.id = a.lesson_id and l.deleted_at is null
      join public.students st on st.id = a.student_id and st.deleted_at is null
     where a.id = (v_event.payload ->> 'attendance_id')::uuid
       and a.center_id = v_event.center_id
       and a.status_id = (v_event.payload ->> 'status_id')::uuid
       and l.starts_at >= now() - interval '3 days';
    if v_student is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child',  v_child,
               'date',   to_char(v_starts at time zone v_tz, 'DD.MM.YYYY'),
               'time',   to_char(v_starts at time zone v_tz, 'HH24:MI'),
               'status', v_status
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r
       where not exists (
         select 1
           from public.events e2
           join public.notification_log nl on nl.event_id = e2.id
          where e2.center_id = v_event.center_id
            and e2.type = 'attendance.status_changed'
            and e2.created_at >= now() - interval '4 days'
            and e2.id <> v_event.id
            and e2.payload ->> 'attendance_id' = v_event.payload ->> 'attendance_id'
            and e2.payload ->> 'status_id' = v_event.payload ->> 'status_id'
            and nl.recipient_user_id = r.user_id
            and nl.status in ('pending', 'sent', 'no_channel')
       );
    return;
  end if;

  -- 0097 В5: расписание специалисту на завтра — список на момент доставки
  -- (отмены и переносы учтены), только telegram, не длиннее 30 строк; {center}
  -- — у специалиста бывает два центра (п.16). Карточка и занятия — только
  -- центра события (п.12).
  if v_event.type = 'teacher.schedule' then
    -- Текст говорит «Завтра»: доставка в сам день занятий или позже (простой
    -- n8n за полночь) — пусто.
    v_day := (v_event.payload ->> 'date')::date;
    if v_day <= (now() at time zone v_tz)::date then
      return;
    end if;

    select t.profile_id into v_user
      from public.teachers t
     where t.id = (v_event.payload ->> 'teacher_id')::uuid
       and t.center_id = v_event.center_id
       and t.deleted_at is null;
    if v_user is null then
      return;
    end if;

    select count(*)::integer,
           string_agg(x.line, chr(10) order by x.starts_at, x.id) filter (where x.rn <= 30)
      into v_n, v_list
      from (
        select l.id, l.starts_at,
               row_number() over (order by l.starts_at, l.id) as rn,
               to_char(l.starts_at at time zone v_tz, 'HH24:MI') || ' — '
                 || coalesce(s.full_name, 'группа «' || g.name || '»', '—') as line
          from public.lessons l
          left join public.students s on s.id = l.student_id
          left join public.groups g on g.id = l.group_id
         where l.center_id = v_event.center_id
           and l.effective_teacher_id = (v_event.payload ->> 'teacher_id')::uuid
           and l.status = 'planned'
           and l.deleted_at is null
           and (l.starts_at at time zone v_tz)::date = v_day
      ) x;
    if coalesce(v_n, 0) = 0 then
      return;
    end if;
    if v_n > 30 then
      v_list := v_list || chr(10) || '…и ещё ' || (v_n - 30)::text;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'date',         to_char(v_day, 'DD.MM.YYYY'),
               'center',       coalesce((select c.name from public.centers c where c.id = v_event.center_id), ''),
               'lesson_count', v_n::text || ' ' || case
                                 when v_n % 10 = 1 and v_n % 100 <> 11 then 'занятие'
                                 when v_n % 10 between 2 and 4 and v_n % 100 not between 12 and 14 then 'занятия'
                                 else 'занятий' end,
               'lesson_list',  v_list
             )),
             null::uuid,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_user, v_event.type) r
       where r.channel = 'telegram';
    return;
  end if;

  if v_event.type in ('subscription.low_balance', 'subscription.exhausted', 'student.absent_streak') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'left',  coalesce(v_event.payload ->> 'lessons_left', ''),
      'count', coalesce(v_event.payload ->> 'length', '')
    );
  elsif v_event.type in ('installment.due', 'installment.overdue') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'amount', public.format_som((v_event.payload ->> 'amount_tiyin')::bigint),
      'date',   to_char((v_event.payload ->> 'due_date')::date, 'DD.MM.YYYY')
    );
  elsif v_event.type = 'digest.daily' then
    -- 0077: {debt} — общее определение «должника» (student_debt_summary через
    -- digest_debt_text), на момент доставки, а не payload.debt_tiyin (0032:
    -- только debt_tiyin, без перерасхода и просрочки). Центр — events.center_id.
    v_debt_text := public.digest_debt_text(v_event.center_id);
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'date',    to_char((v_event.payload ->> 'date')::date, 'DD.MM.YYYY'),
               'lessons', coalesce(v_event.payload ->> 'lessons_today', '0'),
               'low',     coalesce(v_event.payload ->> 'low_balance', '0'),
               'debt',    v_debt_text,
               'overdue', coalesce(v_event.payload ->> 'installments_overdue', '0'),
               -- 0073: поступления за день ДО даты сводки — из базы на момент
               -- доставки, не из payload (emit_event открыта любой роли центра:
               -- цифра из payload подделывалась бы). Дата в самой строке —
               -- доставка бывает позже утра.
               'payments', 'за ' || to_char((v_event.payload ->> 'date')::date - 1, 'DD.MM') || ': '
                           || case when (pay.p ->> 'ops')::integer = 0
                                   then 'платежей не было'
                                   else public.format_som((pay.p ->> 'total_tiyin')::bigint)
                                        || ' (операций: ' || (pay.p ->> 'ops') || ')' end
             )),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r
       cross join lateral (
         select public.center_payments_day(v_event.center_id, (v_event.payload ->> 'date')::date - 1) as p
         offset 0
       ) pay;
    return;
  else
    return;
  end if;

  select s.payer_id into v_payer
    from public.students s
   where s.id = v_student and s.deleted_at is null;

  if v_payer is null then
    return;
  end if;

  return query
    select r.user_id, r.channel, r.chat_id,
           public.render_template(r.template_text, v_vars || jsonb_build_object(
             'child', (select s.full_name from public.students s where s.id = v_student))),
           v_student,
           null::jsonb
      from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
end;
$$;

comment on function public.event_messages(bigint) is
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4), с 0047 — только в telegram. Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. lesson.note_approved (0047) — резюме родителю, {summary} только в telegram и не длиннее 3500 символов; lesson.voice_failed (0047) — заказчику диктовки через notification_user_targets, без причины отказа и только пока повтор диктовки имеет смысл (условие ai_job_begin). 0051: platform.payment_submitted — администраторам платформы (notification_platform_targets, шаблон только дефолтный), subscription.extended — owner/admin центра с {until} в поясе центра, subscription.voice_blocked — заказчику диктовки, {child} только в telegram. 0052: subscription.ending/expired — owner/admin центра, {what}/{until}/{when} на момент доставки в поясе центра. 0053: ai.quota_exceeded — заказчику диктовки ({child} с предлогом, только telegram) и owner/admin центра без {child}, {used}/{limit} в оба канала, пока повтор диктовки имеет смысл. 0056: center.deletion_requested — owner/admin центра, без переменных. 0057: booking.requested — стойке (owner/admin/registrar) через notification_front_desk_targets, {child}/{teacher}/{when}/{phone} читаются заново из booking_requests на момент доставки, не из payload. Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать. 0073: digest.daily — {payments} («за ДД.ММ: сумма (операций: N)» или «платежей не было») считается из платежей на момент доставки (center_payments_day), не из payload. 0077: {debt} в digest.daily — общее определение «должника» из student_debt_summary (долг за занятия с перерасходом; при просрочке по абонементам — «; просрочка по абонементам — сумма», суммы не складываются), считается на момент доставки через digest_debt_text от имени владельца центра (events.center_id), payload.debt_tiyin не читается; при сбое расчёта — «не удалось посчитать — см. /debts», а не ноль. {overdue} — по-прежнему число просроченных рассрочек из payload. 0097: lesson.reminder — {day} («сегодня»/«завтра»/дата на момент доставки), занятие только центра события, пусто при переносе после напоминания (starts_at из payload) и после начала; debt.reminder — родителям плательщика, сумма на момент доставки через bot_balance_center (долг за занятия и просрочка по абонементу раздельно), ошибка расчёта всплывает; subscription.period_ending — перечитывает абонемент (активен, срок тот же, не продлён), получатель — текущий плательщик ребёнка; attendance.status_changed — только пока статус тот же и с галочкой, событие моложе 12 часов, занятие моложе 3 суток, без повтора той же пары (отметка, статус) тому же получателю; teacher.schedule — специалисту только в telegram, список занятий на дату на момент доставки, не длиннее 30 строк. 0109: waitlist.created — стойке через notification_front_desk_targets, {child}/{service}/{teacher}/{phone} читаются заново из waitlist_entries центра события, без даты рождения и комментария, закрытая запись — пусто; waitlist.digest — стойке, {waiting} (со склонением) и {free_slots} из payload, сводка за прошедший день — пусто.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;


-- 13. preview_message: образцы новых переменных ---------------------------------------------------

-- От последней редакции (0097); добавлены образцы {when}/{phone} (0057 — их не
-- было) и {service}/{waiting}/{free_slots} (0109).
create or replace function public.preview_message(p_text text, p_vars jsonb default null)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return public.render_template(
    p_text,
    coalesce(p_vars, jsonb_build_object(
      'child', 'Айдана', 'date', '01.10.2026', 'time', '10:00',
      'teacher', 'Нургуль Абдырахманова', 'left', '2', 'count', '2',
      'amount', public.format_som(200000), 'lessons', '5', 'low', '1',
      'debt', public.format_som(70000) || '; просрочка по абонементам — ' || public.format_som(120000),
      'overdue', '0',
      'payments', 'за 30.09: ' || public.format_som(1250000) || ' (операций: 7)',
      'day', 'завтра',
      'status', 'Прогул',
      'center', 'Логопедический центр',
      'lesson_count', '3 занятия',
      'lesson_list', '09:00 — Айдана' || chr(10) || '10:00 — Тимур' || chr(10) || '11:00 — группа «Звуки»',
      'when', '27.10 16:00',
      'phone', '+996700123456',
      'service', 'Логопед',
      'waiting', '3 ребёнка',
      'free_slots', '5'
    ))
  );
end;
$$;

comment on function public.preview_message(text, jsonb) is 'Предпросмотр шаблона на образцовых данных — тем же рендером, что и отправка.';

revoke all on function public.preview_message(text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.preview_message(text, jsonb) to authenticated;


-- 14. Заборы-каталоги: readonly_guard_exempt_tables (от 0104), export_center_tables (от 0106),
--     export_center_excluded_tables (от 0099) ---------------------------------------------------

create or replace function public.readonly_guard_exempt_tables()
  returns table (table_name text, reason text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('audit_log',               'Р2: аудит действия платформы, снимающего блокировку'),
    ('events',                  'Р2/Р3: события платформы и закрытие работы воркера'),
    ('notification_log',        'Р3: закрытие доставки'),
    ('lesson_reminders_sent',   'Р3: отметка воркера'),
    ('center_digest_runs',      'Р3: отметка воркера'),
    ('ai_jobs',                 'Р3: закрытие работы ИИ'),
    ('ai_usage',                'Р3: учёт уже потраченного'),
    ('lesson_confirmations',    'Р3: пишет только bot_worker'),
    ('centers',                 'Р12: нет center_id; название и пояс правятся, тариф и срок держит centers_protect_plan (0049)'),
    ('plans',                   'Р7: справочник платформы, пишет только миграция'),
    ('platform_admins',         'Р7: справочник платформы, пишет только миграция'),
    ('notification_event_types','Р7: справочник, пишет только миграция'),
    ('telegram_accounts',       'Р12: нет center_id; привязать и отвязать Telegram не зависит от оплаты'),
    ('telegram_link_codes',     'Р12: нет center_id; код привязки Telegram'),
    ('platform_payments',       'Р2/Р12: заявка на оплату — путь разблокировки (0051)'),
    ('subscription_reminders_sent', 'Р3: отметка планировщика (0052)'),
    ('funnel_stages',           'А (0055): глобальный справочник без center_id, пишет только миграция'),
    ('speech_conclusions',      'Р1 (0059): глобальный справочник без center_id, пишет только миграция'),
    ('clinical_forms',          'Р1 (0059): глобальный справочник без center_id, пишет только миграция'),
    ('referral_targets',        'Р1 (0059): глобальный справочник без center_id, пишет только миграция'),
    ('teacher_schedule_sent',   'Р3: отметка планировщика (0097)'),
    ('debt_reminder_runs',      'Р3: отметка планировщика (0097)'),
    ('subscription_period_reminders_sent', 'Р3: отметка планировщика (0097)'),
    ('bot_accounts',            'Р12: нет center_id; бот-аккаунт родителя пишет только бот (0098)'),
    ('center_kinds',            'Р7 (0104): глобальный справочник без center_id, пишет только миграция'),
    ('app_modules',             'Р7 (0104): глобальный справочник без center_id, пишет только миграция'),
    ('center_kind_modules',     'Р7 (0104): глобальный справочник без center_id, пишет только миграция'),
    ('booking_modes',           'Р1 (0109): глобальный справочник без center_id, пишет только миграция'),
    ('waitlist_statuses',       'Р7 (0109): глобальный справочник без center_id, пишет только миграция'),
    ('waitlist_digest_runs',    'Р3: отметка планировщика (0109)')
$$;

revoke all on function public.readonly_guard_exempt_tables() from public, anon, authenticated, service_role;

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
    ('subscription_type_extra_services'), ('subscription_types'), ('subscriptions'), ('syllable_assessments'), ('teacher_rates'), ('teacher_work_hours'), ('teachers'),
    ('waitlist_entries')
$$;

comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. 0087: lesson_debt_writeoffs. 0088: lesson_debt_covers. 0090: subscription_shortfall_writeoffs. 0093: payment_voids. 0101: cash_transfers, discount_reasons. 0102: cash_counts. 0104: center_modules. 0105: makeup_policies, makeup_credits, makeup_bookings. 0106: subscription_type_extra_services. 0109: teacher_work_hours, waitlist_entries. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;

create or replace function public.export_center_excluded_tables()
  returns table (table_name text, reason text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('audit_log',                 'Своя функция export_center_audit() — за диапазон дат, у платящего центра самая большая таблица'),
    ('invitations',                'Р2: token — единственный секрет 7-дневного приглашения (0004); утечка = вход в центр ролью из приглашения'),
    ('lesson_voice_requests',      'Р2: путь к файлу голосового в Storage — секрет по факту (0041)'),
    ('ai_jobs',                    'Внутренняя очередь ИИ-обработки, не данные центра — результат уже в lesson_notes/monthly_reports'),
    ('ai_usage',                   'Внутренний учёт расхода ИИ (0053 Р3), не данные о ребёнке'),
    ('assistant_requests',         'Внутренний учёт попыток ассистента (0064): текста вопроса нет, расход — в ai_usage, тоже исключён'),
    ('bot_pending_actions',        'Контекст шага в Telegram-боте (0071 Р16): chat_id специалиста — не данные центра, результат действия уже в attendance/lesson_notes'),
    ('center_digest_runs',         'Отметка воркера (0050 Р3)'),
    ('events',                     'Внутренняя очередь доставки, не данные центра'),
    ('lesson_confirmations',       'Пишет только bot_worker (0050 Р3), техническая отметка подтверждения'),
    ('lesson_reminders_sent',      'Отметка воркера (0050 Р3)'),
    ('notification_log',           'Журнал доставки, не данные центра — что отправлено, не что произошло'),
    ('saved_filters',              'Личные наборы фильтров сотрудника (0094 Р6), не данные центра: имя — свободный текст, владельцу центра его видеть незачем'),
    ('subscription_reminders_sent', 'Отметка воркера (0052 Р3)'),
    ('teacher_schedule_sent',      'Отметка планировщика (0097)'),
    ('debt_reminder_runs',         'Отметка планировщика (0097)'),
    ('subscription_period_reminders_sent', 'Отметка планировщика (0097)'),
    ('payer_telegram_invites',     'Хеш одноразовой ссылки на бота (0098 Б6): след выдачи — в events, не данные центра'),
    ('platform_center_actions',    'Журнал ручных действий платформы (0099 Р1): причины пишет платформа, это не данные центра'),
    ('waitlist_digest_runs',       'Отметка планировщика (0109)')
$$;
revoke all on function public.export_center_excluded_tables() from public, anon, authenticated, service_role;


comment on column public.centers.settings is
  'Настройки центра (jsonb): city, features (меняет только платформа — centers_protect_plan), booking_enabled (set_booking_enabled), timezone — имя из pg_timezone_names (centers_validate_timezone, 0086), по умолчанию Asia/Bishkek; booking_horizon_days (7..31, по умолчанию 14) и booking_step_min (15/30/60, по умолчанию 30) — set_booking_settings, centers_validate_booking_settings (0109).';
