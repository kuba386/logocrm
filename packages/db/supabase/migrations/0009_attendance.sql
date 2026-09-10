-- =============================================================================
-- 0009_attendance.sql — посещения и списание
--
--   1. attendance         — отметка, факты заморожены в строке
--   2. Проверки           — триггером, а не в функции
--   3. Пересчёт остатка   — из фактических строк, под блокировкой
--   4. События            — low_balance, exhausted, absent_streak
--   5. student_balance    — витрина остатков и долга
--   6. Бейдж специалисту  — «есть / заканчивается / нет», без сумм
--   7. mark_attendance    — единственный путь записи
--
-- Ключевое решение: остаток абонемента — производная величина. Инкремент
-- внутри функции обходят четыре обычных действия: прямой insert админа,
-- правка статуса «болел» → «пришёл», отмена занятия задним числом и правка
-- lessons_used напрямую. Поэтому lessons_used пересчитывается триггером из
-- строк attendance, а не увеличивается на единицу.
-- =============================================================================


-- 1. Отметка ---------------------------------------------------------------------

create table if not exists public.attendance (
  id              uuid primary key default gen_random_uuid(),
  center_id       uuid not null default public.current_center()
                    references public.centers (id) on delete cascade,
  lesson_id       uuid not null,
  student_id      uuid not null,
  status_id       uuid not null,
  -- С какого абонемента списано. null = отметка в долг.
  subscription_id uuid,

  -- Факты заморожены в строке, а не читаются из справочника при пересчёте.
  -- Иначе снятая галочка «списывает» у статуса «прогул» пересчитает остатки
  -- у всех детей за всю историю: сломается не сегодня, а три месяца назад.
  deducted        boolean not null default false,
  counts_absence  boolean not null default false,
  -- Цена занятия на момент отметки: долг не должен расти сам, когда центр
  -- поднимает прайс. Явный 0 вместо null — сумма не должна молча теряться.
  price_tiyin     integer not null default 0 check (price_tiyin >= 0),

  marked_by       uuid default auth.uid(),
  marked_at       timestamptz not null default now(),
  comment         text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  -- Soft delete у отметки нет намеренно. Отметка — наблюдение с
  -- естественным ключом (занятие, ребёнок): ошибка исправляется сменой
  -- статуса, история лежит в audit_log. С deleted_at обычный unique
  -- продолжал бы видеть «удалённую» строку, и повторная отметка того же
  -- ребёнка навсегда упиралась бы в 23505.
  constraint attendance_lesson_student_key unique (lesson_id, student_id),
  constraint attendance_id_center_key unique (id, center_id),
  constraint attendance_lesson_fk
    foreign key (lesson_id, center_id) references public.lessons (id, center_id) on delete cascade,
  constraint attendance_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id),
  constraint attendance_status_fk
    foreign key (status_id, center_id) references public.attendance_statuses (id, center_id),
  constraint attendance_subscription_fk
    foreign key (subscription_id, center_id) references public.subscriptions (id, center_id)
);

create index if not exists attendance_lesson_idx on public.attendance (lesson_id);
create index if not exists attendance_student_idx on public.attendance (student_id);
create index if not exists attendance_subscription_idx
  on public.attendance (subscription_id) where subscription_id is not null;

drop trigger if exists attendance_set_updated_at on public.attendance;
create trigger attendance_set_updated_at before update on public.attendance
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('attendance', false);
call public.apply_audit('attendance');

-- Специалисту — только чтение своих занятий. Политики на insert/update у
-- него нет намеренно: она и была бы прямым путём мимо mark_attendance, и
-- позволила бы подставить чужой subscription_id или чужой marked_by.
-- Прецедент — mark_lesson_status на этапе 3.
drop policy if exists attendance_teacher_read on public.attendance;
create policy attendance_teacher_read on public.attendance
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'teacher'
    and public.teacher_of_lesson(lesson_id)
  );

drop policy if exists attendance_parent_read on public.attendance;
create policy attendance_parent_read on public.attendance
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'parent'
    and public.parent_of_student(student_id)
  );


-- 2. Проверки и заморозка фактов --------------------------------------------------

-- Всё, что клиент мог бы подделать, проставляется здесь и перетирается.
create or replace function public.attendance_fill_and_check()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_lesson public.lessons;
  v_status public.attendance_statuses;
  v_sub    public.subscriptions;
  v_price  integer;
begin
  select * into v_lesson from public.lessons where id = new.lesson_id;
  if not found or v_lesson.deleted_at is not null then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;
  if v_lesson.status = 'cancelled' then
    raise exception 'Занятие отменено — отметить посещение нельзя' using errcode = '22023';
  end if;
  if v_lesson.starts_at > now() then
    raise exception 'Занятие ещё не началось' using errcode = '22023';
  end if;

  -- Ребёнок обязан быть участником занятия. FK на lesson_participants здесь
  -- ловушка: rebuild_lesson_participants чистит состав при каждой правке
  -- занятия, и каскад снёс бы отметки, а restrict заблокировал бы перенос.
  if not exists (
    select 1 from public.lesson_participants p
     where p.lesson_id = new.lesson_id and p.student_id = new.student_id
  ) then
    raise exception 'Этот ребёнок не участник занятия' using errcode = '22023';
  end if;

  select * into v_status from public.attendance_statuses
   where id = new.status_id and center_id = new.center_id and deleted_at is null;
  if not found then
    raise exception 'Статус посещения не найден' using errcode = '42704';
  end if;

  new.deducted       := v_status.deducts_lesson;
  new.counts_absence := v_status.counts_absence;
  new.marked_at      := now();
  if tg_op = 'INSERT' then
    new.marked_by := coalesce(auth.uid(), new.marked_by);
  end if;

  -- Абонемент выбирается здесь, а не клиентом. Порядок явный: nulls last,
  -- потом created_at и id — иначе при равных ends_at выбор недетерминирован.
  if new.deducted then
    select s.* into v_sub from public.subscriptions s
     where s.student_id = new.student_id
       and s.center_id = new.center_id
       and s.deleted_at is null
       and s.status = 'active'
       and public.subscription_state(s.id) = 'active'
       and (s.starts_at <= public.center_today(s.center_id))
       and (s.type_id is null
            or exists (select 1 from public.subscription_types t
                        where t.id = s.type_id
                          and (t.service_id is null or t.service_id = v_lesson.service_id)))
     order by s.ends_at asc nulls last, s.created_at, s.id
     limit 1;

    new.subscription_id := v_sub.id;
  else
    new.subscription_id := null;
  end if;

  -- Замороженный абонемент выбран быть не мог (status <> 'active'), но
  -- проверяем явно: подделанный subscription_id перетирается выше, а эта
  -- проверка держит и прямой insert от администратора.
  if new.subscription_id is not null then
    perform 1 from public.subscription_freezes f
     where f.subscription_id = new.subscription_id
       and f.period @> public.center_today(new.center_id);
    if found then
      raise exception 'Абонемент заморожен — списать занятие нельзя' using errcode = '22023';
    end if;
  end if;

  -- Цена замораживается: из абонемента, иначе из услуги занятия.
  if new.subscription_id is not null then
    v_price := v_sub.lesson_price_tiyin;
  else
    select s.default_price_tiyin into v_price from public.services s
     where s.id = v_lesson.service_id;
  end if;
  new.price_tiyin := coalesce(v_price, 0);

  return new;
end;
$$;

drop trigger if exists attendance_fill on public.attendance;
create trigger attendance_fill before insert or update on public.attendance
  for each row execute function public.attendance_fill_and_check();


-- 4. Серия пропусков ----------------------------------------------------------------

-- «Подряд» считается по времени занятий, а не по времени отметок: специалист
-- в понедельник закрывает пятницу и понедельник, и порядок отметок обратен
-- порядку занятий. Неотмеченное прошедшее занятие внутри серии разрывает её:
-- иначе событие уходит, а на следующий день середину отмечают «пришёл», и
-- отозвать сообщение родителю уже нечем.
create or replace function public.check_absent_streak(
  p_center uuid, p_student uuid, p_lesson uuid
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_prev record;
  v_curr record;
  v_gap  boolean;
begin
  select a.counts_absence, l.starts_at into v_curr
    from public.attendance a join public.lessons l on l.id = a.lesson_id
   where a.lesson_id = p_lesson and a.student_id = p_student;

  if not found or not v_curr.counts_absence then
    return;
  end if;

  -- Предыдущее отмеченное занятие этого ребёнка.
  select a.counts_absence, l.starts_at, l.id into v_prev
    from public.attendance a join public.lessons l on l.id = a.lesson_id
   where a.student_id = p_student
     and l.starts_at < v_curr.starts_at
     and l.deleted_at is null and l.status <> 'cancelled'
   order by l.starts_at desc limit 1;

  if not found or not v_prev.counts_absence then
    return;
  end if;

  -- Между ними не должно быть прошедшего, но неотмеченного занятия.
  select exists (
    select 1 from public.lesson_participants p
    join public.lessons l on l.id = p.lesson_id
    left join public.attendance a on a.lesson_id = l.id and a.student_id = p_student
   where p.student_id = p_student
     and l.starts_at > v_prev.starts_at and l.starts_at < v_curr.starts_at
     and l.deleted_at is null and l.status <> 'cancelled'
     and a.id is null
  ) into v_gap;
  if v_gap then
    return;
  end if;

  -- Ровно длина 2: на третьем и четвёртом пропуске событие не повторяется.
  if exists (
    select 1 from public.attendance a join public.lessons l on l.id = a.lesson_id
     where a.student_id = p_student and a.counts_absence
       and l.starts_at < v_prev.starts_at
       and l.deleted_at is null and l.status <> 'cancelled'
     order by l.starts_at desc limit 1
  ) then
    return;
  end if;

  -- Дедупликация по данным, а не по памяти: повторный пересчёт не должен
  -- слать второе сообщение о том же факте.
  if exists (
    select 1 from public.events e
     where e.type = 'student.absent_streak'
       and e.payload ->> 'streak_start_lesson_id' = v_prev.id::text
       and e.payload ->> 'student_id' = p_student::text
  ) then
    return;
  end if;

  perform public.emit_event('student.absent_streak',
    jsonb_build_object('center_id', p_center, 'student_id', p_student,
                       'streak_start_lesson_id', v_prev.id,
                       'lesson_id', p_lesson, 'length', 2), p_center);
end;
$$;


-- 3. Пересчёт остатка --------------------------------------------------------------

-- Считает lessons_used из фактических строк, а не прибавляет единицу.
-- Блокировка строки абонемента обязательна: без неё две параллельные
-- отметки читают один снимок, обе пишут N+1, и одно списание теряется
-- молча — расхождение всплывает через месяц как «нам не досчитали».
create or replace function public.recalc_subscription_usage(p_subscription_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_used integer;
begin
  if p_subscription_id is null then
    return;
  end if;

  perform 1 from public.subscriptions where id = p_subscription_id for update;
  if not found then
    return;
  end if;

  select count(*) into v_used
    from public.attendance a
    join public.lessons l on l.id = a.lesson_id
   where a.subscription_id = p_subscription_id
     and a.deducted
     and l.deleted_at is null
     and l.status <> 'cancelled';

  update public.subscriptions set lessons_used = v_used where id = p_subscription_id;
end;
$$;

create or replace function public.attendance_recalc_trigger()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_left  integer;
  v_sub   uuid;
begin
  -- И старый, и новый абонемент: правка статуса могла сменить списание.
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.recalc_subscription_usage(old.subscription_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform public.recalc_subscription_usage(new.subscription_id);
  end if;

  if tg_op = 'DELETE' then
    return null;
  end if;

  v_sub := new.subscription_id;

  if v_sub is null and new.deducted then
    perform public.emit_event('attendance.no_subscription',
      jsonb_build_object('center_id', new.center_id, 'attendance_id', new.id,
                         'lesson_id', new.lesson_id, 'student_id', new.student_id,
                         'debt_tiyin', new.price_tiyin), new.center_id);
  end if;

  perform public.emit_event('attendance.marked',
    jsonb_build_object('center_id', new.center_id, 'attendance_id', new.id,
                       'lesson_id', new.lesson_id, 'student_id', new.student_id,
                       'subscription_id', v_sub, 'deducted', new.deducted), new.center_id);

  if v_sub is not null then
    v_left := public.subscription_lessons_left(v_sub);

    -- Событие ровно на границе, а не «при остатке <= 2»: иначе третья,
    -- четвёртая и пятая отметки шлют его повторно.
    -- Дедупликация по данным, а не по памяти. Событие на границе шлётся
    -- один раз, но остаток — величина пересчитываемая: правка статуса
    -- «болел» → «пришёл» снова приводит его к двойке, и без этой проверки
    -- родитель получил бы второе «остаётся 2 занятия» о том же факте.
    if v_left = 2 and not exists (
      select 1 from public.events e
       where e.type = 'subscription.low_balance'
         and e.payload ->> 'subscription_id' = v_sub::text
         and (e.payload ->> 'lessons_left')::int = 2
    ) then
      perform public.emit_event('subscription.low_balance',
        jsonb_build_object('center_id', new.center_id, 'subscription_id', v_sub,
                           'student_id', new.student_id, 'lessons_left', v_left), new.center_id);
    elsif v_left = 0 and not exists (
      select 1 from public.events e
       where e.type = 'subscription.exhausted'
         and e.payload ->> 'subscription_id' = v_sub::text
    ) then
      perform public.emit_event('subscription.exhausted',
        jsonb_build_object('center_id', new.center_id, 'subscription_id', v_sub,
                           'student_id', new.student_id), new.center_id);
    end if;
  end if;

  perform public.check_absent_streak(new.center_id, new.student_id, new.lesson_id);
  return null;
end;
$$;

drop trigger if exists attendance_recalc on public.attendance;
create trigger attendance_recalc after insert or update or delete on public.attendance
  for each row execute function public.attendance_recalc_trigger();

-- Отмена занятия и его удаление возвращают списание в остаток: иначе
-- отменённое задним числом занятие оставляет списание висеть.
create or replace function public.lessons_recalc_attendance_trigger()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_sub uuid;
begin
  for v_sub in
    select distinct a.subscription_id from public.attendance a
     where a.lesson_id = new.id and a.subscription_id is not null
  loop
    perform public.recalc_subscription_usage(v_sub);
  end loop;
  return null;
end;
$$;

drop trigger if exists lessons_recalc_attendance on public.lessons;
create trigger lessons_recalc_attendance
  after update of status, deleted_at on public.lessons
  for each row execute function public.lessons_recalc_attendance_trigger();


-- 5. Витрина остатков -----------------------------------------------------------------

-- security_invoker обязателен: по умолчанию вью читает таблицы правами
-- владельца, а владелец RLS не подчиняется — любой залогиненный получил бы
-- остатки и долги всех детей платформы. Тот же механизм разбирался в
-- ADR-005 для staff_view.
create or replace view public.student_balance
  with (security_invoker = true)
as
  select
    s.id                                        as student_id,
    s.center_id,
    sub.id                                      as active_subscription_id,
    public.subscription_lessons_left(sub.id)    as lessons_left,
    sub.ends_at,
    coalesce((
      select sum(a.price_tiyin) from public.attendance a
       where a.student_id = s.id and a.subscription_id is null and a.deducted
    ), 0)::integer                              as debt_tiyin
  from public.students s
  left join lateral (
    select s2.* from public.subscriptions s2
     where s2.student_id = s.id
       and s2.deleted_at is null
       and s2.status = 'active'
       and public.subscription_state(s2.id) = 'active'
     order by s2.ends_at asc nulls last, s2.created_at, s2.id
     limit 1
  ) sub on true
  where s.deleted_at is null
    -- Роль фильтруется в самой вью. security_invoker закрывает подписки, но
    -- debt_tiyin считается по attendance, а её специалист видит по своим
    -- занятиям — без этого условия сумма долга утекала бы к нему.
    and (
      public.my_role() in ('owner', 'admin')
      or (public.my_role() = 'parent' and public.parent_of_student(s.id))
    );

-- Грант выдаётся ниже, в общем блоке прав, после revoke дефолтных.
-- Роль фильтрует сама вью: грант в Postgres выдаётся роли authenticated
-- целиком, а «специалисту нельзя» — это условие на строку, не на роль.


-- 6. Что видит специалист --------------------------------------------------------------

-- Промт этапа просил показывать специалисту остаток числом, чек-лист —
-- только «есть / нет». Выбрано второе: число это шаг к суммам, а база
-- клиентов и денег — ровно то, с чем уходят открывать кабинет через дорогу.
-- Проверка роли внутри функции, а не только грантами: один неосторожный
-- grant в будущей миграции иначе открыл бы всё.
create or replace function public.student_subscription_badge(p_student_id uuid)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_role text := public.my_role();
  v_left integer;
  v_sub  uuid;
begin
  if v_role is null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if v_role = 'teacher' and not public.teacher_teaches_student(p_student_id) then
    raise exception 'Этот ребёнок не на ваших занятиях' using errcode = '42501';
  end if;
  if v_role = 'parent' and not public.parent_of_student(p_student_id) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Напрямую из subscriptions, а не из витрины: она фильтруется по роли и
  -- для специалиста пуста, отчего бейдж всегда показывал бы «нет».
  select s.id, public.subscription_lessons_left(s.id) into v_sub, v_left
    from public.subscriptions s
   where s.student_id = p_student_id
     and s.deleted_at is null
     and s.status = 'active'
     and public.subscription_state(s.id) = 'active'
   order by s.ends_at asc nulls last, s.created_at, s.id
   limit 1;

  if v_sub is null then return 'нет'; end if;
  if v_left is null then return 'есть'; end if;
  if v_left <= 2 then return 'заканчивается'; end if;
  return 'есть';
end;
$$;


-- 7. Отметка --------------------------------------------------------------------------

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
  if v_role not in ('owner', 'admin', 'teacher') then
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

-- Массовая отметка группы. Всё или ничего: половина отмеченной группы хуже,
-- чем неотмеченная — специалист не увидит, кого пропустил.
create or replace function public.mark_attendance_bulk(p_lesson_id uuid, p jsonb)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_item  jsonb;
  v_count integer := 0;
begin
  for v_item in select * from jsonb_array_elements(p) loop
    perform public.mark_attendance(
      p_lesson_id,
      (v_item ->> 'student_id')::uuid,
      nullif(v_item ->> 'status_code', ''),
      nullif(v_item ->> 'comment', '')
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;


-- Права ---------------------------------------------------------------------------------

-- То же, что в 0008: дефолтные права Supabase снимаются явно.
revoke all on public.attendance, public.student_balance from anon, authenticated;

grant select on public.attendance to authenticated;
grant insert, update on public.attendance to authenticated;
grant select on public.student_balance to authenticated;

revoke execute on function
  public.attendance_fill_and_check(),
  public.attendance_recalc_trigger(),
  public.lessons_recalc_attendance_trigger(),
  public.recalc_subscription_usage(uuid),
  public.check_absent_streak(uuid, uuid, uuid)
  from public, anon, authenticated;

revoke execute on function
  public.student_subscription_badge(uuid),
  public.mark_attendance(uuid, uuid, text, text),
  public.mark_attendance_bulk(uuid, jsonb)
  from public, anon;

grant execute on function
  public.student_subscription_badge(uuid),
  public.mark_attendance(uuid, uuid, text, text),
  public.mark_attendance_bulk(uuid, jsonb)
  to authenticated;
