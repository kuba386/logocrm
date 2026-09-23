-- =============================================================================
-- 0055_funnel.sql — воронка учеников: funnel_stage/funnel_events, отдельно
-- от students.status (этап 8a, шаг 6)
--
-- План — reports/stage-8.md, раздел «Воронка — этап отдельно от состояния
-- (ревью)»; ревью плана архитектором 23.09.2026 (19 находок + 5 вопросов) —
-- ниже как Р-условия и решения по вопросам А–Д.
--
--   А. funnel_stages — ГЛОБАЛЬНАЯ таблица (как plans), не per-center: семь
--      шагов одинаковы для всех центров, ни один не просил свои. code text
--      primary key, RLS + select(true), в списке исключений guard.
--
--   Б. create_student_with_payer получает p_funnel_stage text default null
--      → coalesce(...,'lead'); валидируется по funnel_stages и не 'completed'.
--      Кассир, заводящий уже действующего клиента (заплатил в день записи),
--      не обязан ждать автоперехода.
--
--   В. cause — свободный текст (как platform_payments.note), не лукап:
--      агрегировать причины сегодня некому, лукап — миграция данных завтра.
--
--   Г. archive_student/restore_student НЕ трогают funnel_stage вообще и не
--      пишут funnel_events. Буквальное «restore возвращает предыдущий этап»
--      прочитано как предостережение от наивной реализации (funnel_stage :=
--      'active' при восстановлении фабрикует конверсию), а не как код:
--      сегодня у существующих учеников нет funnel_events, «предыдущий этап»
--      читать неоткуда. Проверяется ассертом «архив → восстановление не
--      меняют funnel_stage и не создают событий».
--
--   Д. Критерий «первое посещение» — НЕ attendance.deducted (у статуса
--      «Прогул» deducts_lesson=true в сиде 0008 — неявка перевела бы лида в
--      active) и не «not counts_absence» (не обратно присутствию: статус
--      «отмена с уведомлением» может не считаться пропуском, но ребёнка не
--      было). Новый явный признак attendance_statuses.is_present, заморожен
--      на attendance рядом с deducted/counts_absence (Р1/Р2).
--
--   Р1. attendance_statuses.is_present — сид: present/late = true, sick/
--       absent = false; backfill существующих строк центра по code.
--
--   Р2. attendance.is_present — заморожен attendance_fill_and_check() при
--       КАЖДОЙ смене статуса (как pays_teacher из 0017, не как
--       subscription_id/price_tiyin, которые морозятся один раз): «пришёл →
--       заболел → пришёл» обязан второй раз считаться присутствием.
--       Backfill существующих строк из текущего status_id.
--
--   Р3. Путь записи funnel_stage — три контура, не один: ручной (через RPC
--       set_funnel_stage, транзакционный флаг logocrm.funnel_write, как
--       logocrm.revoke_membership в 0050), автоматический (продажа
--       абонемента/первое посещение, флаг logocrm.funnel_auto, роль не
--       проверяется — это факт, а не действие человека), без сессии
--       (backfill этой миграции, auth.uid() is null — граница 0050 Р1).
--       Прямой PATCH от owner/admin/registrar (apply_role_rls даёт update)
--       без флага и с сессией — 42501: «переходы в функции» не защищают,
--       пока есть прямой путь (CLAUDE.md, находка 2).
--
--   Р4. Граф переходов — BEFORE-триггер, инвариант, а не проверка в RPC
--       (CLAUDE.md). Ручной путь: вперёд — только на непосредственно
--       следующий шаг (по sort funnel_stages), назад — на любой более
--       ранний (человек передумал на консультации — возврат к «связались»
--       без потери истории); прыжок вперёд через шаг отбивается — иначе
--       воронка фабрикует события, которых не было. Автопуть: прямой скачок
--       в 'active' из любого этапа ДО active, а также из 'completed'
--       (реактивация вернувшегося клиента — Р9); граф его не ограничивает.
--       INSERT с funnel_stage='completed' отбивается всегда (в т.ч. без
--       сессии) — свежего клиента нельзя завести уже закрытым.
--
--   Р5. Автопереход — продажа абонемента (AFTER INSERT на subscriptions) и
--       первое посещение (AFTER INSERT OR UPDATE OF status_id на attendance,
--       по свежему NEW.is_present = true) — только если funnel_stage
--       студента ещё не 'active' и status НЕ in ('paused','archived') —
--       обе спека называет явно: приостановленный или архивный не должен
--       тихо реактивироваться забытой отметкой задним числом. Событие в
--       funnel_events — is_service=false: это настоящая конверсия, не
--       служебный переход.
--
--   Р6. funnel_events — денормализованная история, только select: политика
--       вручную (center_id = current_center() and can_front_desk()), БЕЗ
--       apply_tenant_rls; ни одной политики на запись никому — пишет только
--       AFTER-триггер (security definer). teacher/parent/finance — ни
--       строки (коммерческие данные, спека прямо это называет — can_finance
--       ≠ can_front_desk). Составной FK (student_id, center_id) →
--       students(id, center_id) — тот же приём, что в 0008/0013.
--
--   Р7. funnel_stage остаётся плоской колонкой на students, видимой там же,
--       где сегодня видна status (students_teacher_read_own,
--       students_parent_read_own — обе на весь ряд, без ограничения
--       колонок). Отдельная таблица 1:1 не заводится: она утроила бы число
--       мест, которые нужно держать в курсе (RPC, оба триггера,
--       funnel_summary), а status уже несёт тот же класс коммерческого
--       сигнала без жалоб. Принятое следствие, не недосмотр.
--
--   Р8. students.status теряет литерал 'lead' из check: проверено запросом
--       на облачном проекте 22.09.2026 — ни одной строки со status='lead'
--       (create_student_with_payer никогда его не ставил, дефолт колонки —
--       'active'). Без этого после 0055 в базе жили бы два независимых
--       понятия «лид» и расходились молча.
--
--   Р9. completed → active автопереходом разрешён и считается обычной
--       конверсией (не отдельной меткой): вернувшийся клиент не должен
--       вечно висеть в «курс окончен», пока принуждает администратора
--       править этап руками — а ручная правка тоже попала бы в сводку как
--       конверсия, только без правильного from_stage.
--
--   Р10. funnel_summary(from, to) — по funnel_events, не по текущему этапу:
--        конверсия считается ПО УЧЕНИКАМ (вошёл в период → достиг active
--        когда-либо после), не по рёбрам «lead→active» — такого ребра в
--        графе не бывает физически (Р4), счёт по рёбрам всегда дал бы 0.
--        Срез «сейчас на этапе» — по students.funnel_stage, deleted_at is
--        null and status<>'archived'. Среднее время на этапе — открытые
--        интервалы (coalesce(next.at, now())), иначе застрявшие незаметно
--        улучшают метрику. Пояс — center_today/center_timezone (0032),
--        порядок funnel_events — (student_id, at, id): at одинаков внутри
--        одной транзакции (backfill, автопереход из одного вызова).
--        Роль внутри функции — owner/admin (бизнес-аналитика, не
--        операционная сводка); revoke execute от public/anon/service_role,
--        grant только authenticated — сама функция роль перепроверяет.
--
--   Р11. Гранты по умолчанию: funnel_stages и funnel_events получают явный
--        revoke от anon/authenticated (Supabase выдаёт всё по умолчанию) —
--        забор 0024/0007.

-- 1. funnel_stages — глобальный справочник (А) -------------------------------------------------------

create table if not exists public.funnel_stages (
  code text primary key,
  name text not null,
  sort integer not null
);

alter table public.funnel_stages enable row level security;

drop policy if exists funnel_stages_select on public.funnel_stages;
create policy funnel_stages_select on public.funnel_stages
  for select to authenticated
  using (true);

revoke all on table public.funnel_stages from public, anon, authenticated;
grant select on public.funnel_stages to authenticated;

comment on table public.funnel_stages is
  'Семь шагов воронки, одинаковы для всех центров (0055 А) — не per-center lookup, как attendance_statuses. Пишет только миграция.';

insert into public.funnel_stages (code, name, sort) values
  ('lead',         'Лид',              10),
  ('contacted',    'Связались',        20),
  ('consultation', 'Консультация',     30),
  ('assessment',   'Диагностика',      40),
  ('trial',        'Пробное занятие',  50),
  ('active',       'Занимается',       60),
  ('completed',    'Курс окончен',     70)
on conflict (code) do nothing;


-- 2. funnel_events — денормализованная история (Р6) --------------------------------------------------

create table if not exists public.funnel_events (
  id         bigserial primary key,
  student_id uuid not null,
  center_id  uuid not null references public.centers (id) on delete cascade,
  from_stage text references public.funnel_stages (code),
  to_stage   text not null references public.funnel_stages (code),
  at         timestamptz not null default now(),
  by         uuid references auth.users (id) on delete set null,
  cause      text check (cause is null or length(cause) <= 500),
  is_service boolean not null default false,

  constraint funnel_events_student_center_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade
);

create index if not exists funnel_events_student_at_idx
  on public.funnel_events (student_id, at, id);
create index if not exists funnel_events_center_at_idx
  on public.funnel_events (center_id, at);

alter table public.funnel_events enable row level security;

-- Р6: без apply_tenant_rls — она дала бы for all с with check, а строку
-- пишет только триггер. Роль — can_front_desk (owner/admin/registrar), не
-- can_finance: спека явно исключает бухгалтера из коммерческой истории.
drop policy if exists funnel_events_select on public.funnel_events;
create policy funnel_events_select on public.funnel_events
  for select to authenticated
  using (center_id = public.current_center() and public.can_front_desk());

revoke all on table public.funnel_events from public, anon, authenticated;
grant select on public.funnel_events to authenticated;

comment on table public.funnel_events is
  'История переходов по воронке (0055 Р6). Пишет только AFTER-триггер students_funnel_events; ни одной политики на запись никому. is_service=true — служебный переход (backfill, ручная коррекция ошибки), funnel_summary его не считает конверсией.';


-- 3. attendance_statuses.is_present (Д, Р1) ----------------------------------------------------------

alter table public.attendance_statuses add column if not exists is_present boolean not null default false;

update public.attendance_statuses set is_present = true where code in ('present', 'late');
update public.attendance_statuses set is_present = false where code in ('sick', 'absent');

create or replace function public.seed_attendance_statuses(p_center_id uuid)
  returns void
  language sql
  security definer
  set search_path = ''
as $$
  insert into public.attendance_statuses
    (center_id, code, name, color, deducts_lesson, pays_teacher, counts_absence, notify_parent, is_default, sort, is_present)
  values
    (p_center_id, 'present', 'Пришёл',  'green',  true,  true,  false, false, true,  10, true),
    (p_center_id, 'late',    'Опоздал', 'amber',  true,  true,  false, false, false, 20, true),
    (p_center_id, 'sick',    'Болел',   'sky',    false, false, true,  true,  false, 30, false),
    (p_center_id, 'absent',  'Прогул',  'rose',   true,  true,  true,  true,  false, 40, false)
  on conflict do nothing;
$$;

comment on function public.seed_attendance_statuses(uuid) is
  'Четыре статуса новому центру. С 0055 — и is_present (Д): присутствие, не «списывает» и не «обратное пропуску» — статус «Прогул» списывает занятие (deducts_lesson=true) и присутствием не является.';


-- 4. attendance.is_present — заморожен (Р2) ------------------------------------------------------------

alter table public.attendance add column if not exists is_present boolean not null default false;

update public.attendance a
   set is_present = s.is_present
  from public.attendance_statuses s
 where a.status_id = s.id;

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
    if not v_status_changed and not v_keys_changed then
      new.marked_at := old.marked_at;
      return new;
    end if;
  else
    new.marked_by       := coalesce(auth.uid(), new.marked_by);
    new.subscription_id := null;
    new.price_tiyin     := 0;
    new.paid_teacher_id := coalesce(v_lesson.substitute_teacher_id, v_lesson.teacher_id);  -- 0017
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

  if new.deducted and new.subscription_id is null then
    select c.id, c.is_frozen into v_cand, v_cand_frozen_at_select
      from (
        select s.id,
               exists (
                 select 1 from public.subscription_freezes f
                  where f.subscription_id = s.id and f.period @> v_lesson_date
               ) as is_frozen,
               s.ends_at, s.created_at
          from public.subscriptions s
         where s.student_id = new.student_id
           and s.center_id  = new.center_id
           and s.deleted_at is null
           and s.status <> 'cancelled'
           and s.starts_at <= v_lesson_date
           and (s.allow_negative
                or s.lessons_total is null
                or s.lessons_total - s.lessons_used - s.lessons_written_off > 0)
           and (s.type_id is null
                or exists (select 1 from public.subscription_types t
                            where t.id = s.type_id
                              and (t.service_id is null or t.service_id = v_lesson.service_id)))
      ) c
     where c.ends_at is null or c.ends_at >= v_lesson_date or c.is_frozen
     order by c.is_frozen asc, c.ends_at asc nulls last, c.created_at, c.id
     limit 1;

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
            select 1 from public.subscriptions s2
             where s2.student_id = new.student_id and s2.center_id = new.center_id
               and s2.id <> v_sub.id
               and s2.deleted_at is null and s2.status <> 'cancelled'
               and s2.starts_at <= v_lesson_date
               and (s2.ends_at is null or s2.ends_at >= v_lesson_date)
               and (s2.allow_negative or s2.lessons_total is null
                    or s2.lessons_total - s2.lessons_used - s2.lessons_written_off > 0)
               and not exists (select 1 from public.subscription_freezes f2
                                where f2.subscription_id = s2.id and f2.period @> v_lesson_date)
               and (s2.type_id is null or exists (select 1 from public.subscription_types t2
                      where t2.id = s2.type_id
                        and (t2.service_id is null or t2.service_id = v_lesson.service_id)))
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


-- 5. students.funnel_stage — колонка, триггеры, backfill, RPC (Б, Г, Р3, Р4, Р7, Р8) --------------------

alter table public.students add column if not exists funnel_stage text references public.funnel_stages (code);

-- Порядковый ранг этапа по sort — общий для обоих триггеров ниже.
create or replace function public.funnel_stage_rank(p_code text)
  returns integer
  language sql
  stable
  set search_path = ''
as $$
  select rn::integer from (
    select code, row_number() over (order by sort) as rn from public.funnel_stages
  ) r where r.code = p_code;
$$;

revoke all on function public.funnel_stage_rank(text) from public, anon, authenticated, service_role;

-- Р3/Р4: граф переходов. Три контура: ручной (флаг funnel_write — только
-- вперёд на один шаг или назад на любой более ранний), автоматический
-- (флаг funnel_auto — прямой скачок в active из любого этапа), без сессии
-- (backfill/миграции — проходит целиком). Прямой PATCH с сессией и без
-- флага — 42501: apply_role_rls даёt registrar/admin update на students
-- напрямую, «переходы в функции» это не защищает (CLAUDE.md).
create or replace function public.students_funnel_stage_guard()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_old_rank integer;
  v_new_rank integer;
begin
  if tg_op = 'INSERT' then
    if new.funnel_stage = 'completed' then
      raise exception 'Ученика нельзя завести сразу с этапом «Курс окончен»' using errcode = '23514';
    end if;
    return new;
  end if;

  -- UPDATE.
  if new.funnel_stage is not distinct from old.funnel_stage then
    return new;
  end if;

  if auth.uid() is null then
    -- Миграции, backfill, RI-каскады — вне контура (граница 0050 Р1).
    return new;
  end if;

  if current_setting('logocrm.funnel_auto', true) = '1' then
    if new.funnel_stage <> 'active' then
      raise exception 'Автопереход ведёт только в «Занимается»' using errcode = '23514';
    end if;
    return new;
  end if;

  if current_setting('logocrm.funnel_write', true) = '1' then
    v_old_rank := public.funnel_stage_rank(old.funnel_stage);
    v_new_rank := public.funnel_stage_rank(new.funnel_stage);
    if v_new_rank = v_old_rank + 1 or v_new_rank < v_old_rank then
      return new;
    end if;
    raise exception 'Переход «%» → «%» недоступен: пропускает реальные шаги воронки',
      (select name from public.funnel_stages where code = old.funnel_stage),
      (select name from public.funnel_stages where code = new.funnel_stage)
      using errcode = '23514';
  end if;

  raise exception 'Этап воронки меняется только через set_funnel_stage' using errcode = '42501';
end;
$$;

revoke all on function public.students_funnel_stage_guard() from public, anon, authenticated, service_role;

drop trigger if exists a00_students_funnel_stage_guard on public.students;
create trigger a00_students_funnel_stage_guard
  before insert or update of funnel_stage on public.students
  for each row execute function public.students_funnel_stage_guard();

-- Р6: история. is_service/cause читаются из тех же транзакционных GUC, что
-- держит guard-триггер выше и RPC ниже — единственное место записи.
create or replace function public.students_funnel_events()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_cause      text;
  v_is_service boolean;
begin
  if tg_op = 'UPDATE' and new.funnel_stage is not distinct from old.funnel_stage then
    return null;
  end if;

  v_cause      := nullif(current_setting('logocrm.funnel_cause', true), '');
  v_is_service := coalesce(nullif(current_setting('logocrm.funnel_is_service', true), '')::boolean, false);

  insert into public.funnel_events (student_id, center_id, from_stage, to_stage, at, by, cause, is_service)
  values (
    new.id, new.center_id,
    case when tg_op = 'INSERT' then null else old.funnel_stage end,
    new.funnel_stage,
    now(), auth.uid(), v_cause, v_is_service
  );

  return null;
end;
$$;

revoke all on function public.students_funnel_events() from public, anon, authenticated, service_role;

drop trigger if exists z99_students_funnel_events on public.students;
create trigger z99_students_funnel_events
  after insert or update of funnel_stage on public.students
  for each row execute function public.students_funnel_events();

comment on trigger a00_students_funnel_stage_guard on public.students is
  'Граф переходов воронки (0055 Р3/Р4) — сортируется перед z99, чтобы отказ пришёл до записи истории.';
comment on trigger z99_students_funnel_events on public.students is
  'История переходов в funnel_events (0055 Р6) — имя сортируется после a00, история пишется только для прошедших граф.';


-- Backfill (Г, Р8): по фактам, до NOT NULL/DEFAULT и до сужения check.
-- Триггеры уже стоят — auth.uid() is null здесь (миграция), guard пропускает
-- целиком; is_service=true помечает это событие как служебное, не конверсию.
-- is_local=true (транзакция миграции, не сессия) — иначе GUC пережил бы
-- эту миграцию и утёк бы на пуловое соединение (0050 Р10 — тот же риск).
select set_config('logocrm.funnel_is_service', 'true', true);

update public.students s
   set funnel_stage = case
     when exists (
       select 1 from public.subscriptions sub
        where sub.student_id = s.id and sub.center_id = s.center_id and sub.deleted_at is null
     ) then 'active'
     when exists (
       select 1 from public.attendance a
        where a.student_id = s.id and a.center_id = s.center_id and a.is_present
     ) then 'active'
     else 'lead'
   end
 where s.funnel_stage is null;

select set_config('logocrm.funnel_is_service', '', true);

alter table public.students alter column funnel_stage set not null;
alter table public.students alter column funnel_stage set default 'lead';

-- Р8: 'lead' в status мёртв (проверено на облачном проекте 22.09.2026 —
-- ни одной строки; create_student_with_payer его никогда не ставил).
alter table public.students drop constraint if exists students_status_check;
alter table public.students
  add constraint students_status_check check (status in ('active', 'paused', 'archived'));


-- 6. set_funnel_stage — единственный ручной путь записи (Р3) ------------------------------------------

create or replace function public.set_funnel_stage(
  p_student_id uuid,
  p_to_stage   text,
  p_cause      text default null,
  p_is_service boolean default false
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_student public.students;
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;
  if not exists (select 1 from public.funnel_stages f where f.code = p_to_stage) then
    raise exception 'Неизвестный этап воронки' using errcode = '22023';
  end if;

  select * into v_student from public.students
   where id = p_student_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;
  -- Р4/Р7: архивного не ведут по воронке — сначала restore_student;
  -- приостановленного вести можно (например закрыть как «Курс окончен»).
  if v_student.status = 'archived' then
    raise exception 'Ученик в архиве — восстановите, чтобы менять этап воронки' using errcode = '22023';
  end if;

  perform set_config('logocrm.funnel_write', '1', true);
  perform set_config('logocrm.funnel_cause', coalesce(p_cause, ''), true);
  perform set_config('logocrm.funnel_is_service', p_is_service::text, true);

  update public.students set funnel_stage = p_to_stage
   where id = p_student_id and center_id = v_center;

  perform set_config('logocrm.funnel_write', '', true);
  perform set_config('logocrm.funnel_cause', '', true);
  perform set_config('logocrm.funnel_is_service', '', true);
end;
$$;

comment on function public.set_funnel_stage(uuid, text, text, boolean) is
  'Единственный путь ручной смены этапа воронки (0055 Р3) — граф проверяет BEFORE-триггер, эта функция только права/центр/статус и транзакционные флаги для истории. p_is_service=true — коррекция ошибки оператора, не реальное движение: funnel_summary её не считает.';

revoke all on function public.set_funnel_stage(uuid, text, text, boolean) from public, anon, service_role;
grant execute on function public.set_funnel_stage(uuid, text, text, boolean) to authenticated;


-- 7. create_student_with_payer — из 0026, добавлен параметр (Б) ---------------------------------------

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
  p_notes              text    default null,
  p_funnel_stage       text    default null
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
  v_stage   text := coalesce(p_funnel_stage, 'lead');
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if coalesce(trim(p_full_name), '') = '' then
    raise exception 'Укажите ФИО ребёнка' using errcode = '22004';
  end if;

  -- 0055 Б: кассир заводит уже действующего клиента без ожидания
  -- автоперехода; 'completed' на входе — та же граница, что в guard-триггере.
  if not exists (select 1 from public.funnel_stages f where f.code = v_stage) then
    raise exception 'Неизвестный этап воронки' using errcode = '22023';
  end if;
  if v_stage = 'completed' then
    raise exception 'Нельзя завести ученика сразу с этапом «Курс окончен»' using errcode = '22023';
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
    primary_teacher_id, source, notes, started_at, funnel_stage
  )
  values (
    v_center, trim(p_full_name), p_birth_date, p_gender, v_payer,
    p_primary_teacher_id, p_source, p_notes, current_date, v_stage
  )
  returning id into v_student;

  perform public.emit_event('student.created',
    jsonb_build_object('center_id', v_center, 'student_id', v_student,
                       'payer_id', v_payer, 'primary_teacher_id', p_primary_teacher_id),
    v_center);

  return query select v_student, v_payer;
end;
$$;

comment on function public.create_student_with_payer(text, uuid, text, text, text, date, text, uuid, text, text, text) is
  'Создание ученика и/или привязка плательщика. С 0055 — необязательный p_funnel_stage (Б), по умолчанию lead.';

revoke all on function public.create_student_with_payer(text, uuid, text, text, text, date, text, uuid, text, text, text) from public, anon, service_role;
grant execute on function public.create_student_with_payer(text, uuid, text, text, text, date, text, uuid, text, text, text) to authenticated;

-- Старая сигнатура (без p_funnel_stage) висела бы в каталоге как перегрузка,
-- закрытая по умолчанию, но лишняя запись в 0007 — снимаем явно.
drop function if exists public.create_student_with_payer(text, uuid, text, text, text, date, text, uuid, text, text);


-- 8. Автопереход → active (Р5, Р9) -----------------------------------------------------------------------

create or replace function public.subscriptions_funnel_transition()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_student public.students;
begin
  select * into v_student from public.students
   where id = new.student_id and center_id = new.center_id;
  if not found then
    return new;
  end if;
  if v_student.funnel_stage = 'active' or v_student.status in ('paused', 'archived') then
    return new;
  end if;

  perform set_config('logocrm.funnel_auto', '1', true);
  perform set_config('logocrm.funnel_is_service', 'false', true);
  update public.students set funnel_stage = 'active'
   where id = new.student_id and center_id = new.center_id;
  perform set_config('logocrm.funnel_auto', '', true);
  perform set_config('logocrm.funnel_is_service', '', true);

  return new;
end;
$$;

comment on function public.subscriptions_funnel_transition() is
  'Продажа абонемента переводит ученика в active (0055 Р5), если он ещё не там и не paused/archived. Реальная конверсия — is_service=false.';

revoke all on function public.subscriptions_funnel_transition() from public, anon, authenticated, service_role;

drop trigger if exists subscriptions_funnel_transition on public.subscriptions;
create trigger subscriptions_funnel_transition
  after insert on public.subscriptions
  for each row execute function public.subscriptions_funnel_transition();

create or replace function public.attendance_funnel_transition()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_student public.students;
begin
  if not new.is_present then
    return new;
  end if;

  select * into v_student from public.students
   where id = new.student_id and center_id = new.center_id;
  if not found then
    return new;
  end if;
  if v_student.funnel_stage = 'active' or v_student.status in ('paused', 'archived') then
    return new;
  end if;

  perform set_config('logocrm.funnel_auto', '1', true);
  perform set_config('logocrm.funnel_is_service', 'false', true);
  update public.students set funnel_stage = 'active'
   where id = new.student_id and center_id = new.center_id;
  perform set_config('logocrm.funnel_auto', '', true);
  perform set_config('logocrm.funnel_is_service', '', true);

  return new;
end;
$$;

comment on function public.attendance_funnel_transition() is
  'Первое присутствие (is_present=true, 0055 Д) переводит ученика в active (Р5) — не deducted и не отсутствие counts_absence, статус «Прогул» тоже списывает занятие.';

revoke all on function public.attendance_funnel_transition() from public, anon, authenticated, service_role;

drop trigger if exists attendance_funnel_transition on public.attendance;
create trigger attendance_funnel_transition
  after insert or update of status_id on public.attendance
  for each row execute function public.attendance_funnel_transition();


-- 9. funnel_summary / funnel_stuck (Р10) -----------------------------------------------------------------

create or replace function public.funnel_summary(p_from date, p_to date)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_tz     text;
  v_from   timestamptz;
  v_to     timestamptz;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Некорректный период' using errcode = '22023';
  end if;

  v_tz   := public.center_timezone(v_center);
  v_from := p_from::timestamp at time zone v_tz;
  v_to   := (p_to + 1)::timestamp at time zone v_tz;

  return jsonb_build_object(
    -- Срез «сейчас»: не по периоду — архивные и удалённые не искажают его.
    'current', (
      select coalesce(jsonb_agg(jsonb_build_object('stage', x.code, 'name', x.name, 'count', x.cnt) order by x.sort), '[]'::jsonb)
        from (
          select f.code, f.name, f.sort, count(s.id) as cnt
            from public.funnel_stages f
            left join public.students s
              on s.funnel_stage = f.code and s.center_id = v_center
             and s.deleted_at is null and s.status <> 'archived'
           group by f.code, f.name, f.sort
        ) x
    ),
    -- Переходы за период, только реальные (не служебные).
    'transitions', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'from_stage', e.from_stage, 'to_stage', e.to_stage, 'count', e.cnt) order by e.cnt desc), '[]'::jsonb)
        from (
          select from_stage, to_stage, count(*)::integer as cnt
            from public.funnel_events
           where center_id = v_center and is_service = false
             and at >= v_from and at < v_to
           group by from_stage, to_stage
        ) e
    ),
    -- Конверсия по ученикам: вошёл в воронку в периоде (первое событие с
    -- from_stage is null) → достиг active когда-либо после входа (Р10:
    -- ребра lead→active в графе не существует, считать по рёбрам нельзя).
    'conversion', (
      select jsonb_build_object(
               'entered', count(*)::integer,
               'converted', count(*) filter (where c.converted)::integer
             )
        from (
          select first.student_id,
                 exists (
                   select 1 from public.funnel_events ae
                    where ae.student_id = first.student_id and ae.center_id = v_center
                      and ae.is_service = false and ae.to_stage = 'active'
                      and ae.at >= first.at
                 ) as converted
            from (
              select student_id, min(at) as at
                from public.funnel_events
               where center_id = v_center and is_service = false and from_stage is null
                 and at >= v_from and at < v_to
               group by student_id
            ) first
        ) c
    ),
    -- Среднее время на этапе: открытые интервалы (застрявшие не улучшают
    -- метрику незаметно), порядок (student_id, at, id) — at совпадает
    -- внутри одной транзакции (backfill, автопереход одним вызовом).
    'avg_days_on_stage', (
      select coalesce(jsonb_agg(jsonb_build_object('stage', d.stage, 'avg_days', round(d.avg_days, 1)) order by d.stage), '[]'::jsonb)
        from (
          select w.to_stage as stage, avg(extract(epoch from (w.closes_at - w.at)) / 86400.0) as avg_days
            from (
              select to_stage, at,
                     coalesce(
                       lead(at) over (partition by student_id order by at, id),
                       now()
                     ) as closes_at
                from public.funnel_events
               where center_id = v_center and is_service = false
            ) w
           group by w.to_stage
        ) d
    ),
    -- Источники лидов, вошедших в воронку за период.
    'sources', (
      select coalesce(jsonb_agg(jsonb_build_object('source', coalesce(s.source, '—'), 'count', s.cnt) order by s.cnt desc), '[]'::jsonb)
        from (
          select st.source, count(*)::integer as cnt
            from public.funnel_events fe
            join public.students st on st.id = fe.student_id and st.center_id = v_center
           where fe.center_id = v_center and fe.is_service = false and fe.from_stage is null
             and fe.at >= v_from and fe.at < v_to
           group by st.source
        ) s
    )
  );
end;
$$;

comment on function public.funnel_summary(date, date) is
  'Сводка воронки за период (0055 Р10): срез «сейчас» по students, переходы/конверсия/среднее время по funnel_events (is_service=false), источники — students.source. Owner/admin — бизнес-аналитика, не операционная сводка.';

revoke all on function public.funnel_summary(date, date) from public, anon, service_role;
grant execute on function public.funnel_summary(date, date) to authenticated;

create or replace function public.funnel_stuck(p_days integer default 14)
  returns table (
    student_id   uuid,
    full_name    text,
    stage        text,
    stage_name   text,
    days_on_stage integer,
    payer_phone  text
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_tz     text;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_days is null or p_days < 1 then
    raise exception 'Число дней должно быть больше нуля' using errcode = '22023';
  end if;

  v_tz := public.center_timezone(v_center);

  return query
    with last_event as (
      select fe.student_id, max(fe.at) as at
        from public.funnel_events fe
       where fe.center_id = v_center
       group by fe.student_id
    )
    select s.id, s.full_name, s.funnel_stage, f.name,
           extract(day from now() - coalesce(le.at, s.created_at))::integer,
           p.phone
      from public.students s
      join public.funnel_stages f on f.code = s.funnel_stage
      join public.payers p on p.id = s.payer_id
      left join last_event le on le.student_id = s.id
     where s.center_id = v_center
       and s.deleted_at is null
       and s.status = 'active'
       and s.funnel_stage not in ('active', 'completed')
       and coalesce(le.at, s.created_at) < now() - (p_days || ' days')::interval
     order by coalesce(le.at, s.created_at);
end;
$$;

comment on function public.funnel_stuck(integer) is
  'Ученики без движения по воронке дольше p_days (0055) — для списка «застрявших» с кнопкой WhatsApp. Активные/закрытые/приостановленные/архивные не входят.';

revoke all on function public.funnel_stuck(integer) from public, anon, service_role;
grant execute on function public.funnel_stuck(integer) to authenticated;


-- 10. Заборы: guard, exempt-список (0050/0051/0052 → эта миграция), реестр -------------------------------

call public.apply_readonly_guard('funnel_events');

-- Из 0052 (последняя редакция); добавлена одна строка.
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
    ('funnel_stages',           'А (0055): глобальный справочник без center_id, пишет только миграция')
$$;

revoke all on function public.readonly_guard_exempt_tables() from public, anon, authenticated, service_role;
