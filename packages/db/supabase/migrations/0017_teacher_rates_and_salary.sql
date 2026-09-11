-- =============================================================================
-- 0017_teacher_rates_and_salary.sql — ставки специалистов и расчёт зарплаты
-- (этап 5, промт пп.7-8)
--
-- Два раунда architect-ревью: план (20 находок) и написанный код (11, среди
-- них два денежных бага в calc_salary и утечка цены абонемента через
-- salary_runs.lines) — все закрыты. Решения, которые НЕ выводятся из промта
-- напрямую (принято здесь, а не угадано):
--
--   Р1. Зарплата идёт тому, кто ФАКТИЧЕСКИ провёл занятие — не тому, кто был
--       изначально в расписании. Источник — НЕ lessons.effective_teacher_id
--       (generated column, живое значение родителя, задуман только для
--       EXCLUDE-констрейнта занятости — 0006_schedule.sql:136-137,172-173,
--       ADR-006), а новая attendance.paid_teacher_id, замороженная в
--       attendance_fill_and_check по тому же правилу, что price_tiyin/
--       subscription_id. Иначе substitute_teacher (не проверяет статус
--       занятия) тихо переносит деньги между специалистами задним числом.
--   Р2. Событие 'salary.calculated' эмитится ТОЛЬКО вместе с неизменяемым
--       снимком (salary_runs + approve_salary) — не как побочный эффект
--       calc_salary (чистая функция от живых данных: ставка, статус
--       отметки, замена специалиста — всё это может измениться после того,
--       как зарплату уже выплатили, и без снимка "сколько заплатили в
--       августе" негде посмотреть).
--   Р3. teachers получает ту же защиту, что payment_sources (0014) и
--       expense_categories (0016) уже получили — ровно то же упущение
--       повторилось в третий раз (0004 не сделала revoke all вообще).
--       Заодно archive_teacher/restore_teacher: прямой update deleted_at не
--       пройдёт tenant_admin (RETURNING не видит строку после update —
--       тот же класс, что soft-delete везде в проекте).
--   Р4. approve_salary складывает calc_salary с salary_adjustments того же
--       месяца в total_tiyin снимка — без этого "Утвердить" фиксировало бы
--       число без бонуса/штрафа, хотя администратор видел его на экране
--       (чек-лист этапа: "Бонус 500 → 2 000"). lines снимка — только
--       построчная детализация по занятиям; корректировки остаются
--       отдельной уже-исторической таблицей, не дублируются в jsonb.
--   Р5. per_hour платит ОДНОЙ строкой занятия, как per_lesson: это величина
--       от занятия (длительность), не от ребёнка. Без этого групповое
--       занятие платило бы час работы × число детей. Платящая строка —
--       первая ПЛАТЯЩАЯ, не первая по student_id.
--   Р6. salary_runs без _read_own для teacher, вместо неё salary_summary —
--       итог по специалистам без строк детализации: lines хранит цену
--       занятия каждого ребёнка, прямой select таблицы не знает про
--       маскировку calc_salary. Заодно закрывает "деньги в браузере":
--       число "2 000" чек-листа иначе складывалось бы в React.
--   Р7. approve_salary — только за полностью прошедший месяц, как
--       close_month; reopen_salary сознательно не строится (сценария нет).
--       По занятиям не в статусе done calc_salary отдаёт строку с amount=0
--       и причиной — фильтр done из спеки ограничивает оплату, не видимость.
--   Р8. Ставка или корректировка задним числом в месяц с утверждённой
--       зарплатой — отбивается триггером approved_salary_guard на обеих
--       таблицах (иначе премия после "Утвердить" числится начисленной, а в
--       снимок не попадает — и не выплачивается); в закрытый месяц — замком
--       financial_period_guard. Append-only без этого закрывал только форму
--       записи. lessons получает составные FK на teachers — реальная дыра
--       изоляции, найденная по пути.
--   Р9. Платящая строка per_lesson/per_hour выбирается по ВСЕМ отметкам
--       занятия, включая строки другого специалиста: замена после части
--       отметок замораживает в одном занятии разные paid_teacher_id, и без
--       этого за один час работы центр платил бы дважды. Кому именно —
--       детерминированно (первая платящая по student_id), но произвольно;
--       отступление фиксируется в отчёте этапа.
--
-- Полный список фактов о существующей схеме, на которые опирается план —
-- в истории сессии (агент Explore) и в самом architect-ревью. Ключевое:
-- attendance_statuses.pays_teacher уже существует (0008), но НЕ заморожен
-- в attendance (в отличие от deducted/counts_absence) — это несогласованно
-- и чинится здесь же.
-- =============================================================================


-- 0. teachers — недостающий составной ключ и грант, которого никогда не было ------

-- Нужен для двух новых составных FK ниже (attendance.paid_teacher_id,
-- teacher_rates.teacher_id) — без него alter table упал бы на "there is no
-- unique constraint matching given keys for referenced table teachers".
alter table public.teachers
  add constraint teachers_id_center_key unique (id, center_id);

-- lessons.teacher_id и substitute_teacher_id ссылались на teachers(id) без
-- center_id (0006:132): RLS занятия проверяет только center_id самой строки,
-- а центр специалиста — никто. Специалист чужого центра проходил все
-- существующие проверки. Настоящая дыра изоляции, а не просто риск для
-- attendance_paid_teacher_fk ниже (на непустом staging бэкфилл скопировал бы
-- чужой teacher_id в paid_teacher_id, и FK упал бы с сообщением про
-- attendance, хотя причина — в lessons). Составной FK держит это базой.
alter table public.lessons
  add constraint lessons_teacher_fk
  foreign key (teacher_id, center_id) references public.teachers (id, center_id);

alter table public.lessons
  add constraint lessons_substitute_teacher_fk
  foreign key (substitute_teacher_id, center_id) references public.teachers (id, center_id);

-- 0004 не сделала revoke all вообще — teachers единственная из таблиц
-- персонала прожила без него до сих пор. Тот же класс упущения, что
-- payment_sources (0014) и expense_categories (0016), только на этот раз
-- НИКОГДА не было даже частичного revoke.
revoke all on public.teachers from anon, authenticated;
grant select, insert on public.teachers to authenticated;
grant update (full_name, phone, specialization, is_active, custom_fields)
  on public.teachers to authenticated;
-- deleted_at сознательно вне колоночного гранта: прямой update не пройдёт
-- tenant_admin (RETURNING не увидит строку после того, как deleted_at
-- перестал быть null) — тот же повод, что у всех archive_*/restore_*
-- в проекте. Только через RPC ниже.

comment on column public.teachers.hourly_rate_tiyin is
  'Не используется. Ставки — teacher_rates (0017). Колонка оставлена, чтобы не ломать сгенерированные типы; удаление — отдельной миграцией.';

create or replace function public.archive_teacher(p_id uuid)
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

  update public.teachers
     set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Специалист не найден' using errcode = '42704';
  end if;

  perform public.emit_event('teacher.archived',
    jsonb_build_object('center_id', v_center, 'teacher_id', p_id), v_center);
end;
$$;

create or replace function public.restore_teacher(p_id uuid)
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

  update public.teachers
     set deleted_at = null
   where id = p_id and center_id = v_center and deleted_at is not null;

  if not found then
    raise exception 'Специалист не найден в архиве' using errcode = '42704';
  end if;

  perform public.emit_event('teacher.restored',
    jsonb_build_object('center_id', v_center, 'teacher_id', p_id), v_center);
end;
$$;


-- 1. attendance — pays_teacher (согласован со статусом) и paid_teacher_id ---------
--    (заморожен один раз, как price_tiyin/subscription_id) ----------------------

alter table public.attendance add column if not exists pays_teacher boolean;
alter table public.attendance add column if not exists paid_teacher_id uuid;

-- Бэкфилл — до того, как ниже переопределится attendance_fill_and_check и
-- пока действующий на СЕГОДНЯ financial_period_guard_attendance/старый
-- триггер живы: без disable trigger user бэкфилл на строке из уже
-- закрытого месяца (close_month жив с 0013, staging не гарантированно
-- пуст к этой миграции) упал бы на "Месяц ... закрыт", а если бы прошёл —
-- существующий (пока не переопределённый) триггер всё равно не тронул бы
-- новые колонки, но рисковать порядком нет смысла: весь бэкфилл — под
-- отключёнными пользовательскими триггерами.
alter table public.attendance disable trigger user;

-- Бэкфилл pays_teacher — по status_id БЕЗ фильтра deleted_at: это факт
-- прошлого (каким был статус на момент отметки), а не текущее состояние
-- справочника.
update public.attendance a
   set pays_teacher = s.pays_teacher
  from public.attendance_statuses s
 where a.status_id = s.id;

-- Бэкфилл paid_teacher_id — из lessons на сегодняшний день. Для старых
-- строк это может не совпасть с тем, кто фактически вёл занятие на момент
-- отметки (замена могла случиться и до, и после) — это единственный
-- доступный ответ для истории, и он фиксируется в отчёте по этапу, а не
-- принимается молча.
update public.attendance a
   set paid_teacher_id = coalesce(l.substitute_teacher_id, l.teacher_id)
  from public.lessons l
 where a.lesson_id = l.id;

-- Триггеры обратно СРАЗУ после бэкфилла, до любого alter, который может
-- отказать (set not null / add constraint на неожиданных данных): окно
-- "attendance без attendance_fill_and_check и без замка месяца" — ровно два
-- update выше, не весь раздел. DDL ниже триггеры не задействует.
alter table public.attendance enable trigger user;

alter table public.attendance alter column pays_teacher set not null;
alter table public.attendance alter column paid_teacher_id set not null;

alter table public.attendance
  add constraint attendance_paid_teacher_fk
  foreign key (paid_teacher_id, center_id) references public.teachers (id, center_id);

-- Порядок колонок — как у FK: иначе Supabase Advisor считает FK непокрытым
-- (unindexed_foreign_keys); calc_salary ищет по обеим с равенством, ему
-- порядок безразличен.
create index if not exists attendance_paid_teacher_idx
  on public.attendance (paid_teacher_id, center_id);

-- Тело — из 0015_freeze_state_unification.sql:961-1179 (актуальная версия;
-- 0010 и 0009 старее и не содержат более позднюю гонку выбора абонемента).
-- Изменения отмечены пометкой "-- 0017:" рядом с каждой новой строкой —
-- остальной текст воспроизведён дословно.
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


-- 2. teacher_rates — историчные ставки, без update/delete когда-либо -------------

create table if not exists public.teacher_rates (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null default public.current_center()
                references public.centers (id) on delete cascade,
  teacher_id  uuid not null,
  -- null = ставка на все услуги; конкретная услуга перекрывает общую
  -- независимо от того, какая из двух свежее (раздел calc_salary ниже,
  -- порядок сортировки в подзапросе действующей ставки).
  service_id  uuid,
  model       text not null,
  -- Тыйыны для per_lesson/per_hour/per_student; проценты×100 для
  -- percent_payment (3000 = 30.00%). Единая integer-колонка на все модели —
  -- единицы задаёт model, не тип столбца.
  value       integer not null,
  valid_from  date not null default public.center_today(),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),

  constraint teacher_rates_id_center_key unique (id, center_id),
  constraint teacher_rates_teacher_fk
    foreign key (teacher_id, center_id) references public.teachers (id, center_id),
  constraint teacher_rates_service_fk
    foreign key (service_id, center_id) references public.services (id, center_id),
  constraint teacher_rates_model_known
    check (model in ('per_lesson', 'per_hour', 'percent_payment', 'per_student')),
  constraint teacher_rates_value_not_negative check (value >= 0),
  -- Прямой insert доступен authenticated (нет побочных эффектов, RPC не
  -- нужен — находка Б5-архитектора против первого плана expenses не
  -- применима: событие тут не обязано быть атомарным со вставкой, кроме
  -- одобрения, которое отдельным RPC уже прикрыто ниже), значит некорректный
  -- процент может прийти прямым PostgREST-запросом — то же основание, что
  -- у именованных CHECK везде в проекте: без имени errors.ts не найдёт
  -- текст и покажет общую фразу вместо понятной.
  constraint teacher_rates_percent_bounded
    check (model <> 'percent_payment' or value <= 10000),
  -- Две ставки на одну и ту же специфичность в один день — источник
  -- недетерминированного выбора внутри calc_salary; NULLS NOT DISTINCT
  -- (PG17, config.toml) делает null service_id тоже уникальным per teacher.
  constraint teacher_rates_no_same_day_conflict
    unique nulls not distinct (center_id, teacher_id, service_id, valid_from)
);

create index if not exists teacher_rates_teacher_idx on public.teacher_rates (teacher_id);
create index if not exists teacher_rates_service_idx on public.teacher_rates (service_id);

comment on column public.teacher_rates.value is
  'Тыйыны для per_lesson/per_hour/per_student; проценты×100 для percent_payment (3000 = 30%).';

-- created_by — принудительно auth.uid() вызывающего, не то, что мог бы
-- прислать клиент: insert открыт authenticated целиком, а default на колонке
-- подменяется явным значением в запросе. Тот же приём, что marked_by в
-- attendance_fill_and_check; audit_log хранил бы правду, но искать её там
-- пришлось бы тому, кто уже знает, что таблица врёт.
create or replace function public.teacher_rates_set_created_by()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  new.created_by := auth.uid();
  return new;
end;
$$;

revoke all on function public.teacher_rates_set_created_by() from public, anon, authenticated;

drop trigger if exists teacher_rates_set_created_by on public.teacher_rates;
create trigger teacher_rates_set_created_by
  before insert on public.teacher_rates
  for each row execute function public.teacher_rates_set_created_by();

-- Замок "зарплата за месяц уже утверждена" — approved_salary_guard в
-- разделе 4, после salary_runs: общий для teacher_rates и salary_adjustments.

call public.apply_tenant_rls('teacher_rates', false);
call public.apply_audit('teacher_rates');

-- Специалист видит только свои ставки — сверяет, по какой считается его
-- зарплата (тот же повод, что RLS admin+teacher у payments).
drop policy if exists teacher_rates_read_own on public.teacher_rates;
create policy teacher_rates_read_own on public.teacher_rates
  for select to authenticated
  using (
    center_id = public.current_center()
    and teacher_id = public.my_teacher_id()
  );

-- Ни update, ни delete — никогда. Новая ставка = новая строка с новым
-- valid_from; правка старой строки задним числом молча меняла бы зарплату за
-- уже закрытые и уже выплаченные месяцы. Новая строка с прошлым valid_from
-- сделала бы то же самое — от этого approved_salary_guard (раздел 4) и
-- financial_period_guard_teacher_rates (раздел 5); append-only сам по себе
-- закрывает только форму записи.
revoke all on public.teacher_rates from anon, authenticated;
grant select, insert on public.teacher_rates to authenticated;


-- 3. salary_adjustments — бонус/штраф, через RPC, замок месяца ------------------

create table if not exists public.salary_adjustments (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null default public.current_center()
                references public.centers (id) on delete cascade,
  teacher_id  uuid not null,
  month       date not null,
  amount_tiyin integer not null,
  reason      text not null,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),

  constraint salary_adjustments_id_center_key unique (id, center_id),
  constraint salary_adjustments_teacher_fk
    foreign key (teacher_id, center_id) references public.teachers (id, center_id),
  constraint salary_adjustments_month_is_first_of_month
    check (month = date_trunc('month', month)::date),
  constraint salary_adjustments_amount_not_zero check (amount_tiyin <> 0)
);

create index if not exists salary_adjustments_teacher_idx on public.salary_adjustments (teacher_id, month);

call public.apply_tenant_rls('salary_adjustments', false);
call public.apply_audit('salary_adjustments');

drop policy if exists salary_adjustments_read_own on public.salary_adjustments;
create policy salary_adjustments_read_own on public.salary_adjustments
  for select to authenticated
  using (
    center_id = public.current_center()
    and teacher_id = public.my_teacher_id()
  );

-- Прямая запись закрыта совсем — только через record_salary_adjustment:
-- created_by не должен подделываться клиентом, а замок месяца (раздел 5
-- ниже) должен видеть вставку в одной транзакции с проверкой.
revoke all on public.salary_adjustments from anon, authenticated;
grant select on public.salary_adjustments to authenticated;

create or replace function public.record_salary_adjustment(
  p_teacher_id  uuid,
  p_month       date,
  p_amount_tiyin integer,
  p_reason      text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_month  date := date_trunc('month', p_month)::date;
  v_id     uuid;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.center_id = v_center) then
    raise exception 'Специалист не найден' using errcode = '42704';
  end if;

  insert into public.salary_adjustments (center_id, teacher_id, month, amount_tiyin, reason, created_by)
  values (v_center, p_teacher_id, v_month, p_amount_tiyin, p_reason, auth.uid())
  returning id into v_id;

  perform public.emit_event('salary.adjustment_recorded',
    jsonb_build_object(
      'center_id', v_center, 'adjustment_id', v_id, 'teacher_id', p_teacher_id,
      'month', v_month, 'amount_tiyin', p_amount_tiyin
    ),
    v_center
  );

  return v_id;
end;
$$;


-- 4. salary_runs — неизменяемый снимок, approve_salary --------------------------

-- Без снимка событие 'salary.calculated' утверждало бы факт, который через
-- час перестанет быть правдой: ставка неизменяема, но статус отметки можно
-- поправить, замена специалиста возможна задним числом. Снимок — тот же
-- приём "заморозь факт в дочернюю строку", что payments/attendance.
create table if not exists public.salary_runs (
  id           uuid primary key default gen_random_uuid(),
  center_id    uuid not null default public.current_center()
                 references public.centers (id) on delete cascade,
  teacher_id   uuid not null,
  month        date not null,
  total_tiyin  integer not null,
  -- Построчная детализация calc_salary на момент утверждения — тот же
  -- список, что видел администратор перед нажатием "Утвердить".
  lines        jsonb not null,
  approved_at  timestamptz not null default now(),
  approved_by  uuid default auth.uid(),

  constraint salary_runs_id_center_key unique (id, center_id),
  constraint salary_runs_teacher_fk
    foreign key (teacher_id, center_id) references public.teachers (id, center_id),
  constraint salary_runs_month_is_first_of_month
    check (month = date_trunc('month', month)::date),
  -- Повторное утверждение того же месяца тому же специалисту — вопрос к
  -- reopen-подобному сценарию, которого пока нет; unique отбивает случайное
  -- двойное нажатие "Утвердить" читаемой ошибкой, а не дублем строки.
  constraint salary_runs_teacher_month_key unique (center_id, teacher_id, month)
);

-- Отдельного индекса (teacher_id, month) нет: salary_runs_teacher_month_key
-- уже даёт (center_id, teacher_id, month), а пишут сюда раз в месяц.

call public.apply_tenant_rls('salary_runs', false);
call public.apply_audit('salary_runs');

-- Никакой _read_own для teacher, в отличие от teacher_rates/salary_
-- adjustments: lines — полная детализация calc_salary на момент
-- утверждения, включая price_tiyin по каждому ребёнку. calc_salary прячет
-- её от чужого процента (ADR-005), но прямой select таблицы этой
-- маскировки не знает — и специалист получал бы её в обход, причём даже за
-- занятие, к attendance которого после замены у него уже нет доступа. Свою
-- сумму и дату утверждения он берёт из salary_summary ниже: та строчек не
-- возвращает вовсе.
revoke all on public.salary_runs from anon, authenticated;
grant select on public.salary_runs to authenticated;

-- approved_salary_guard — ничего задним числом в месяц с утверждённой
-- зарплатой. Снимок неизменяем, reopen нет, а salary_summary отдаёт итог
-- ИЗ снимка: премия, записанная после "Утвердить", числилась бы
-- начисленной (adjustments_tiyin) и никогда не выплачивалась (total_tiyin
-- из snapshot). Та же дыра у ставки: append-only закрывает форму записи,
-- а новая строка с прошлым valid_from меняет calc_salary как правка.
-- Триггер, не if внутри record_salary_adjustment: прямого insert сегодня
-- нет, но grant insert в будущей миграции открыл бы обход (CLAUDE.md,
-- "инвариант — это констрейнт или триггер"). Отдельно от
-- financial_period_guard: "утверждено" и "закрыто" — независимые факты,
-- бывает любое без другого.
create or replace function public.approved_salary_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_new_month date;
  v_old_month date;
  v_blocked   date;
begin
  if tg_table_name = 'teacher_rates' then
    -- Только insert: update/delete гранта у teacher_rates нет.
    v_new_month := date_trunc('month', new.valid_from)::date;

  elsif tg_table_name = 'salary_adjustments' then
    if tg_op <> 'DELETE' then
      v_new_month := new.month;
    end if;
    if tg_op <> 'INSERT' then
      v_old_month := old.month;
    end if;

  else
    raise exception 'approved_salary_guard: неизвестная таблица %', tg_table_name
      using errcode = '42704';
  end if;

  if v_new_month is not null and exists (
       select 1 from public.salary_runs sr
        where sr.center_id = new.center_id
          and sr.teacher_id = new.teacher_id
          and sr.month = v_new_month
     ) then
    v_blocked := v_new_month;
  elsif v_old_month is not null and exists (
       select 1 from public.salary_runs sr
        where sr.center_id = old.center_id
          and sr.teacher_id = old.teacher_id
          and sr.month = v_old_month
     ) then
    v_blocked := v_old_month;
  end if;

  if v_blocked is not null then
    raise exception 'Зарплата за % уже утверждена — изменения задним числом невозможны',
      public.ru_month_year(v_blocked)
      using errcode = '22023';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.approved_salary_guard() from public, anon, authenticated;

drop trigger if exists approved_salary_guard_teacher_rates on public.teacher_rates;
create trigger approved_salary_guard_teacher_rates
  before insert on public.teacher_rates
  for each row execute function public.approved_salary_guard();

drop trigger if exists approved_salary_guard_salary_adjustments on public.salary_adjustments;
create trigger approved_salary_guard_salary_adjustments
  before insert or update or delete on public.salary_adjustments
  for each row execute function public.approved_salary_guard();


-- 5. financial_period_guard — ветки salary_adjustments и teacher_rates ----------

-- Тело — из 0016_expenses.sql:360-448 (актуальная версия: else raise
-- exception на неизвестной таблице уже там). Добавлены две ветки:
-- salary_adjustments (нет timestamptz-поля с датой занятия/оплаты, только
-- готовый первый-день-месяца month — сравнение напрямую, без at time zone)
-- и teacher_rates (valid_from — обычная дата, только insert).
create or replace function public.financial_period_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid;
  v_old_date date;
  v_new_date date;
  v_blocked  date;
begin
  if tg_op = 'DELETE' then
    v_center := old.center_id;
  else
    v_center := new.center_id;
  end if;

  if tg_table_name = 'payments' then
    if tg_op <> 'DELETE' then
      v_new_date := (new.paid_at at time zone public.center_timezone(v_center))::date;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := (old.paid_at at time zone public.center_timezone(v_center))::date;
    end if;

  elsif tg_table_name = 'expenses' then
    if tg_op <> 'DELETE' then
      v_new_date := (new.paid_at at time zone public.center_timezone(v_center))::date;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := (old.paid_at at time zone public.center_timezone(v_center))::date;
    end if;

  elsif tg_table_name = 'salary_adjustments' then
    if tg_op <> 'DELETE' then
      v_new_date := new.month;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := old.month;
    end if;

  elsif tg_table_name = 'teacher_rates' then
    -- Только insert: у teacher_rates нет update/delete гранта, old не бывает.
    -- valid_from — произвольный день, до месяца его доводит общий
    -- date_trunc в сравнении ниже, как и у остальных веток.
    v_new_date := new.valid_from;

  elsif tg_table_name = 'attendance' then
    if tg_op <> 'DELETE' then
      select (l.starts_at at time zone public.center_timezone(v_center))::date into v_new_date
        from public.lessons l where l.id = new.lesson_id;
    end if;
    if tg_op <> 'INSERT' then
      select (l.starts_at at time zone public.center_timezone(v_center))::date into v_old_date
        from public.lessons l where l.id = old.lesson_id;
    end if;

  elsif tg_table_name = 'lessons' then
    if tg_op <> 'DELETE' then
      v_new_date := (new.starts_at at time zone public.center_timezone(v_center))::date;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := (old.starts_at at time zone public.center_timezone(v_center))::date;
    end if;

  else
    raise exception 'financial_period_guard: неизвестная таблица %', tg_table_name
      using errcode = '42704';
  end if;

  if v_new_date is not null and exists (
       select 1 from public.financial_periods fp
        where fp.center_id = v_center
          and fp.month = date_trunc('month', v_new_date)::date
          and fp.closed_at is not null
     ) then
    v_blocked := v_new_date;
  elsif v_old_date is not null and exists (
       select 1 from public.financial_periods fp
        where fp.center_id = v_center
          and fp.month = date_trunc('month', v_old_date)::date
          and fp.closed_at is not null
     ) then
    v_blocked := v_old_date;
  end if;

  if v_blocked is not null then
    raise exception 'Месяц % закрыт — операции с этой датой запрещены', public.ru_month_year(v_blocked)
      using errcode = '22023';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists financial_period_guard_salary_adjustments on public.salary_adjustments;
create trigger financial_period_guard_salary_adjustments
  before insert or update or delete on public.salary_adjustments
  for each row execute function public.financial_period_guard();

-- Ставка задним числом в ЗАКРЫТЫЙ месяц — тот же замок, что у остальных
-- финансовых таблиц (второй, независимый от teacher_rates_guard_approved_
-- month: месяц закрыт ≠ зарплата утверждена, бывает любое из двух без другого).
drop trigger if exists financial_period_guard_teacher_rates on public.teacher_rates;
create trigger financial_period_guard_teacher_rates
  before insert on public.teacher_rates
  for each row execute function public.financial_period_guard();


-- calc_salary(p_teacher_id, p_month) — построчная детализация + итог. -----------
--
-- Одна строка = одна отметка (attendance), не одно занятие: sum(amount_tiyin)
-- по всем строкам ВСЕГДА равен итогу без отдельного пересчёта — вызывающая
-- сторона не ведёт вторую арифметику.
--
-- Кто платит на групповом занятии — по модели:
--   per_lesson, per_hour  — ОДНА строка занятия (величина от занятия: факт
--                            проведения / его длительность), остальные строки
--                            того же занятия — amount_tiyin=0 с пояснением.
--                            Платящая строка — первая ПЛАТЯЩАЯ по student_id,
--                            не первая вообще: "болел" на наименьшем id не
--                            должен съедать оплату за занятие, которое
--                            состоялось. Нумерация — по всем отметкам
--                            занятия, в том числе с чужим paid_teacher_id
--                            (замена посреди отметок): одна оплата на
--                            занятие, а не на специалиста.
--   per_student, percent_payment — каждая строка отдельно (величина от
--                            ребёнка: его присутствие / цена его абонемента).
--
-- Строки без подходящей ставки, с pays_teacher=false и по занятиям не в
-- статусе done остаются в выдаче с amount_tiyin=0 и причиной — скрывать
-- нельзя: "5 занятий вместо 6" в детализации, а по непроведённому занятию
-- администратор должен увидеть, что утверждать ещё рано, а не недосчитаться
-- молча. Фильтр status='done' из спеки ограничивает ОПЛАТУ, не видимость.
--
-- Арифметика — bigint на всех промежуточных умножениях (integer уже на
-- price_tiyin × value для процента от крупной суммы переполнился бы) и
-- (a*b + d/2) / d — округление до ближайшего, не усечение; core/salary.ts
-- обязана повторить те же формулы (docs, ADR-006: SQL — источник, core —
-- зеркало).
create or replace function public.calc_salary(p_teacher_id uuid, p_month date)
  returns table (
    attendance_id      uuid,
    lesson_id          uuid,
    lesson_date        date,
    student_id         uuid,
    model              text,
    -- Не base_tiyin: это всегда цена ЗАНЯТИЯ (attendance.price_tiyin), и
    -- базой расчёта она служит только у percent_payment — у остальных
    -- моделей "базы" в этом смысле нет, колонка "база" в детализации врала бы.
    lesson_price_tiyin integer,
    amount_tiyin       integer,
    note               text
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center      uuid := public.current_center();
  v_month       date := date_trunc('month', p_month)::date;
  v_is_teacher  boolean := false;
begin
  if coalesce(public.my_role(), '') in ('owner', 'admin') then
    if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.center_id = v_center) then
      raise exception 'Специалист не найден' using errcode = '42704';
    end if;
  elsif coalesce(public.my_role(), '') = 'teacher'
        and p_teacher_id = public.my_teacher_id() then
    v_is_teacher := true;
  else
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Модель, не входящая в текущий список ниже (будущая миграция расширила
  -- check, эту функцию забыли обновить) — громкий отказ здесь и сейчас,
  -- а не молчаливый NULL внутри case на каждой строке.
  if exists (
    select 1 from public.teacher_rates tr
     where tr.teacher_id = p_teacher_id and tr.center_id = v_center
       and tr.model not in ('per_lesson', 'per_hour', 'percent_payment', 'per_student')
  ) then
    raise exception 'calc_salary: у специалиста есть ставка с неизвестной моделью' using errcode = '22023';
  end if;

  return query
  with lesson_scope as (
    -- Занятия месяца, где у специалиста есть хоть одна отметка.
    select distinct a.lesson_id
      from public.attendance a
      join public.lessons l on l.id = a.lesson_id
     where a.center_id = v_center
       and a.paid_teacher_id = p_teacher_id
       and l.deleted_at is null
       and (l.starts_at at time zone public.center_timezone(v_center))::date >= v_month
       and (l.starts_at at time zone public.center_timezone(v_center))::date < (v_month + interval '1 month')::date
  ),
  candidate as (
    -- ВСЕ отметки этих занятий, не только свои: замена посреди отметок
    -- замораживает в одном занятии разные paid_teacher_id, а платящая
    -- строка per_lesson/per_hour обязана быть одна на ЗАНЯТИЕ, не одна на
    -- специалиста — иначе за один час работы центр платит дважды. Чужие
    -- строки отсекаются в самом конце, уже после нумерации.
    select a.id as attendance_id, a.lesson_id, a.student_id, a.pays_teacher, a.price_tiyin,
           a.paid_teacher_id,
           (l.starts_at at time zone public.center_timezone(v_center))::date as lesson_date,
           l.starts_at, l.ends_at, l.service_id, l.status as lesson_status
      from public.attendance a
      join public.lessons l on l.id = a.lesson_id
     where a.center_id = v_center
       and a.lesson_id in (select ls.lesson_id from lesson_scope ls)
  ),
  rated as (
    select c.*,
           r.model, r.value,
           -- Платящие строки занятия получают меньший rn, чем неплатящие.
           -- Иначе "болел" с наименьшим student_id перетягивает единственную
           -- платящую позицию per_lesson/per_hour на себя, реально пришедшие
           -- дети остаются с amount=0, а причина у них — лживое "оплачено в
           -- другой строке": строки на месте, платит никто.
           row_number() over (
             partition by c.lesson_id
             order by (not c.pays_teacher), c.student_id
           ) as rn_in_lesson
      from candidate c
      left join lateral (
        select tr.model, tr.value
          from public.teacher_rates tr
         where tr.teacher_id = p_teacher_id
           and tr.center_id = v_center
           and (tr.service_id = c.service_id or tr.service_id is null)
           and tr.valid_from <= c.lesson_date
         order by (tr.service_id is null) asc, tr.valid_from desc
         limit 1
      ) r on true
  )
  select
    r.attendance_id, r.lesson_id, r.lesson_date, r.student_id,
    r.model,
    -- Специалисту цена видна только там, где это его собственный процент —
    -- иначе через detail утекает цена абонемента чужого ребёнка (ADR-005,
    -- тот же повод, что закрывает payments/subscriptions от роли teacher).
    case when v_is_teacher and r.model is distinct from 'percent_payment' then null
         else r.price_tiyin end as lesson_price_tiyin,
    case
      when r.lesson_status <> 'done' then 0
      when not r.pays_teacher then 0
      when r.model is null then 0
      when r.model = 'per_lesson' then (case when r.rn_in_lesson = 1 then r.value else 0 end)
      when r.model = 'per_student' then r.value
      -- per_hour — одна строка занятия, как per_lesson: час работы не
      -- умножается на число детей в группе.
      when r.model = 'per_hour' then
        (case when r.rn_in_lesson = 1
              then ((r.value::bigint * extract(epoch from (r.ends_at - r.starts_at))::bigint + 1800) / 3600)::integer
              else 0 end)
      when r.model = 'percent_payment' then
        ((r.price_tiyin::bigint * r.value + 5000) / 10000)::integer
      else 0
    end as amount_tiyin,
    case
      when r.lesson_status <> 'done' then 'занятие не проведено'
      when not r.pays_teacher then 'статус не оплачивается'
      when r.model is null then 'ставка не задана'
      when r.model in ('per_lesson', 'per_hour') and r.rn_in_lesson <> 1 then 'оплачено в другой строке занятия'
      else null
    end as note
  from rated r
  where r.paid_teacher_id = p_teacher_id
  order by r.lesson_date, r.lesson_id, r.student_id;
end;
$$;


-- approve_salary(p_teacher_id, p_month) — снимок + событие в одной транзакции ----

create or replace function public.approve_salary(p_teacher_id uuid, p_month date)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center      uuid := public.current_center();
  v_month       date := date_trunc('month', p_month)::date;
  v_calc_total  integer;
  v_adjustments integer;
  v_total       integer;
  v_lines       jsonb;
  v_id          uuid;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Как close_month: снимок неизменяем, reopen-сценария нет, а unique на
  -- (teacher, month) означает, что утверждённое 20-го числа за 19 дней
  -- зафиксировать заново 1-го уже негде. Пока месяц идёт — только смотреть.
  if v_month >= date_trunc('month', public.center_today(v_center))::date then
    raise exception 'Утвердить зарплату можно только за полностью прошедший месяц' using errcode = '22023';
  end if;

  select coalesce(sum(c.amount_tiyin), 0), coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
    into v_calc_total, v_lines
    from public.calc_salary(p_teacher_id, v_month) c;

  -- Итог снимка — расчёт по занятиям ПЛЮС бонусы/штрафы того же месяца:
  -- иначе "Утвердить" фиксирует число, которое администратор не видел на
  -- экране (там бонус учтён), и sum(lines) != total_tiyin без объяснения.
  select coalesce(sum(sa.amount_tiyin), 0) into v_adjustments
    from public.salary_adjustments sa
   where sa.teacher_id = p_teacher_id and sa.center_id = v_center and sa.month = v_month;

  v_total := v_calc_total + v_adjustments;

  insert into public.salary_runs (center_id, teacher_id, month, total_tiyin, lines, approved_by)
  values (v_center, p_teacher_id, v_month, v_total, v_lines, auth.uid())
  returning id into v_id;

  perform public.emit_event('salary.calculated',
    jsonb_build_object(
      'center_id', v_center, 'salary_run_id', v_id, 'teacher_id', p_teacher_id,
      'month', v_month, 'total_tiyin', v_total
    ),
    v_center
  );

  return v_id;
end;
$$;


-- salary_summary(p_month) — итог месяца по специалистам одним вызовом. -----------
--
-- Без неё число "2 000" из чек-листа этапа (расчёт + корректировка) негде
-- взять с сервера: calc_salary отдаёт строки без корректировок,
-- salary_adjustments — отдельная таблица, salary_runs появляется только
-- после approve_salary. Единственный способ показать итог — сложить в
-- React, а "деньги в браузере не считаются". Заодно экран "месяц → таблица
-- по специалистам" перестаёт делать N вызовов calc_salary — по одному на
-- специалиста. Строк детализации не возвращает: это и есть то, что
-- специалисту из salary_runs.lines видеть нельзя.
create or replace function public.salary_summary(p_month date)
  returns table (
    teacher_id        uuid,
    calc_tiyin        integer,
    adjustments_tiyin integer,
    -- Утверждённый снимок, если он есть; иначе живой расчёт + корректировки.
    total_tiyin       integer,
    approved_run_id   uuid,
    approved_at       timestamptz
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_month  date := date_trunc('month', p_month)::date;
  v_role   text := coalesce(public.my_role(), '');
begin
  if v_role not in ('owner', 'admin', 'teacher') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return query
  with scope as (
    select t.id as teacher_id
      from public.teachers t
     where t.center_id = v_center
       and t.deleted_at is null
       -- teacher — только своя строка; my_teacher_id() у него без
       -- карточки null, тогда строк нет вовсе, а не чужие.
       and (v_role in ('owner', 'admin') or t.id = public.my_teacher_id())
  ),
  calc as (
    select s.teacher_id, coalesce(sum(c.amount_tiyin), 0)::integer as calc_tiyin
      from scope s
      left join lateral public.calc_salary(s.teacher_id, v_month) c on true
     group by s.teacher_id
  ),
  adj as (
    select s.teacher_id, coalesce(sum(sa.amount_tiyin), 0)::integer as adjustments_tiyin
      from scope s
      left join public.salary_adjustments sa
        on sa.teacher_id = s.teacher_id and sa.center_id = v_center and sa.month = v_month
     group by s.teacher_id
  ),
  run as (
    select sr.teacher_id, sr.id as approved_run_id, sr.approved_at, sr.total_tiyin
      from public.salary_runs sr
     where sr.center_id = v_center and sr.month = v_month
  )
  select
    s.teacher_id,
    c.calc_tiyin,
    a.adjustments_tiyin,
    coalesce(r.total_tiyin, c.calc_tiyin + a.adjustments_tiyin),
    r.approved_run_id,
    r.approved_at
  from scope s
  join calc c on c.teacher_id = s.teacher_id
  join adj a on a.teacher_id = s.teacher_id
  left join run r on r.teacher_id = s.teacher_id
  order by s.teacher_id;
end;
$$;


-- Гранты -------------------------------------------------------------------------

revoke execute on function
  public.record_salary_adjustment(uuid, date, integer, text),
  public.calc_salary(uuid, date),
  public.approve_salary(uuid, date),
  public.salary_summary(date),
  public.archive_teacher(uuid),
  public.restore_teacher(uuid)
  from public, anon, authenticated;

grant execute on function
  public.record_salary_adjustment(uuid, date, integer, text),
  public.calc_salary(uuid, date),
  public.approve_salary(uuid, date),
  public.salary_summary(date),
  public.archive_teacher(uuid),
  public.restore_teacher(uuid)
  to authenticated;
