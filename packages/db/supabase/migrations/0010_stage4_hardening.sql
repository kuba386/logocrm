-- =============================================================================
-- 0010_stage4_hardening.sql — закрытие находок ревью этапа 4
--
-- 0008 и 0009 влиты и применены. Независимое ревью по пяти линзам нашло в
-- них 25 подтверждённых проблем; архитектор проверил план этой миграции и
-- добавил 14 дефектов к самому плану. Здесь — итог обоих.
--
--   1. my_role() = NULL проходит проверку «not in»      → coalesce во всех RPC
--   2. Калькуляторы читают чужие абонементы              → security invoker
--   3. Бейдж не фильтрует по центру для owner/admin      → проверка центра
--   4. Отметка перевыбирает абонемент при каждом UPDATE  → факты замораживаются
--   5. Клиент может сменить ребёнка/занятие у отметки     → колоночный грант
--   6. Прямой insert в subscriptions без согласования цены → revoke + CHECK
--   7. Гонки и порядок блокировок                         → advisory lock,
--      statement-level триггер, детерминированный порядок
--   8. Дубли событий при правке комментария               → эмит по существу
--   9. allow_negative списывает молча                     → subscription.overdrawn
--
-- Приоритет п.1 перевёрнут относительно первого плана: шесть RPC этапа 4 при
-- NULL уже падают на emit_event (там role_in is null → исключение), а четыре
-- ЧИТАЮЩИЕ функции этапов 0–3 событий не пишут — отозванный администратор с
-- ещё живым JWT вытаскивал через них телефоны родителей и имена детей.
-- =============================================================================


-- 1. Проверка роли при NULL --------------------------------------------------------

-- `NULL not in ('owner', 'admin')` — это NULL, а `if NULL` не срабатывает.
-- Пользователь с валидным JWT, у которого членство уже отозвано, проходил
-- любую такую проверку. coalesce превращает NULL в '', и '' not in (...) —
-- честное true. RLS-политики этим не страдали: там `my_role() in (...)` при
-- NULL даёт NULL → строка не видна. Дыра была только в definer-функциях.

create or replace function public.user_email(p_user_id uuid)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_email text;
begin
  if auth.uid() is null then
    return null;
  end if;

  if p_user_id <> auth.uid() then
    if coalesce(public.my_role(), '') not in ('owner', 'admin') then
      return null;
    end if;

    if not exists (
      select 1 from public.memberships m
       where m.user_id = p_user_id and m.center_id = public.current_center()
    ) then
      return null;
    end if;
  end if;

  select u.email into v_email from auth.users u where u.id = p_user_id;
  return v_email;
end;
$$;

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
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
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
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
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
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
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


-- 2. RPC этапа 4: та же проверка роли, плюс блокировки ---------------------------------

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
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
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
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_sub from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null
     for update;  -- сериализуется с выбором абонемента в attendance_fill_and_check
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  v_state := public.subscription_state(p_id);
  if v_state <> 'active' then
    raise exception 'Заморозить можно только действующий абонемент, а он «%»', v_state
      using errcode = '22023';
  end if;

  if p_to is not null and p_to < p_from then
    raise exception 'Дата окончания заморозки раньше начала' using errcode = '22023';
  end if;

  -- Открытый конец — неограниченная граница (NULL), не дата 'infinity'.
  -- В 0008 стояло 'infinity' с комментарием «иначе EXCLUDE не поймает
  -- пересечение» — это путаница с NULL-значениями колонок: неограниченный
  -- диапазон пересекается со всем после своего начала, EXCLUDE его ловит.
  -- А вот 'infinity' как дата ломала всё остальное: upper_inf() для неё
  -- false, и unfreeze_subscription не находила открытую заморозку, а
  -- upper(period) - lower(period) падал на «cannot subtract infinite dates».
  insert into public.subscription_freezes (center_id, subscription_id, period)
  values (v_center, p_id, daterange(p_from, p_to, '[)'));

  update public.subscriptions set status = 'frozen' where id = p_id;

  perform public.emit_event('subscription.frozen',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id,
                       'from', p_from, 'to', p_to), v_center);
end;
$$;

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
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Близнец freeze_subscription: без блокировки абонемента тот же интерливинг
  -- с отметкой, что и у заморозки.
  perform 1 from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  -- Обе формы открытого конца: неограниченный (с 0010) и дата 'infinity'
  -- (так писала 0008 — строк в staging нет, но форма должна пониматься).
  select * into v_open from public.subscription_freezes f
   where f.subscription_id = p_id and f.center_id = v_center
     and (upper_inf(f.period) or upper(f.period) = 'infinity'::date)
   order by lower(f.period) desc limit 1;
  if not found then
    raise exception 'У абонемента нет открытой заморозки' using errcode = '42704';
  end if;

  v_to := coalesce(p_to, public.center_today(v_center));
  if v_to < lower(v_open.period) then
    raise exception 'Дата окончания заморозки раньше её начала' using errcode = '22023';
  end if;

  update public.subscription_freezes
     set period = daterange(lower(v_open.period), v_to, '[)')
   where id = v_open.id;

  update public.subscriptions set status = 'active' where id = p_id;

  perform public.emit_event('subscription.unfrozen',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id, 'to', v_to), v_center);
end;
$$;

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
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
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
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
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
  if coalesce(v_role, '') not in ('owner', 'admin', 'teacher') then
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

-- Массовая отметка: детерминированный порядок блокировок и без дублей.
-- Два параллельных bulk по пересекающимся группам в разном порядке — это
-- deadlock; сортировка по uuid (не по тексту: collation базы не обязан
-- совпадать с порядком типа) даёт один порядок обеим транзакциям.
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
  for v_item in
    select distinct on ((e.value ->> 'student_id')::uuid) e.value
      from jsonb_array_elements(p) e
     order by (e.value ->> 'student_id')::uuid
  loop
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


-- 3. Калькуляторы: security invoker --------------------------------------------------

-- Были security definer без единой проверки центра и выданы на execute всем
-- залогиненным: любой родитель любого центра по чужому subscription_id читал
-- остаток и сумму возврата. Отзывать execute нельзя — student_balance
-- объявлена security_invoker, и EXECUTE на функции внутри вью проверяется у
-- вызывающего: витрина умерла бы для всех. Поэтому invoker: RLS сама режет
-- чужие строки → NULL. Из definer-функций (триггеры, бейдж, продажа) они
-- вызываются от postgres, и RLS там не применяется, как раньше.
--
-- Побочный эффект, который надо знать: NULL у subscription_lessons_left по
-- контракту — «безлимит». После invoker тот же NULL значит ещё и «не видно».
-- Поэтому четыре калькулятора — внутренние; прикладной путь к остатку и
-- возврату — subscription_summary ниже, с явным 42501.

create or replace function public.subscription_lessons_left(p_subscription_id uuid)
  returns integer
  language sql
  stable
  security invoker
  set search_path = ''
as $$
  select case
    when s.lessons_total is null then null
    else s.lessons_total - s.lessons_used - s.lessons_written_off
  end
  from public.subscriptions s
  where s.id = p_subscription_id;
$$;

create or replace function public.subscription_state(p_subscription_id uuid)
  returns text
  language sql
  stable
  security invoker
  set search_path = ''
as $$
  select case
    when s.status in ('cancelled', 'frozen') then s.status
    when s.ends_at is not null
         and s.ends_at < public.center_today(s.center_id) then 'expired'
    when s.lessons_total is not null
         and s.lessons_total - s.lessons_used - s.lessons_written_off <= 0 then 'exhausted'
    else 'active'
  end
  from public.subscriptions s
  where s.id = p_subscription_id;
$$;

create or replace function public.refund_calc(p_id uuid)
  returns integer
  language sql
  stable
  security invoker
  set search_path = ''
as $$
  select coalesce(public.subscription_lessons_left(p_id), 0) * coalesce(s.lesson_price_tiyin, 0)
  from public.subscriptions s where s.id = p_id;
$$;

-- Переписана, а не только переключена: голая агрегация по subscription_freezes
-- давала coalesce(..., 0) и для невидимого абонемента — то есть не отказ, а
-- враньё «0 дней заморозки». Через subscriptions невидимое даёт NULL.
create or replace function public.subscription_freeze_days(p_subscription_id uuid)
  returns integer
  language sql
  stable
  security invoker
  set search_path = ''
as $$
  select coalesce((
    select sum(
      case when upper_inf(f.period) or upper(f.period) = 'infinity'::date then 0
           else (upper(f.period) - lower(f.period))
      end
    )
    from public.subscription_freezes f
    where f.subscription_id = s.id
  ), 0)::int
  from public.subscriptions s
  where s.id = p_subscription_id;
$$;

-- Прикладной путь к цифрам абонемента: диалог возврата, карточка ребёнка.
-- Definer с проверкой роли и центра внутри и исключением, а не NULL.
create or replace function public.subscription_summary(p_subscription_id uuid)
  returns table (
    lessons_left   integer,
    state          text,
    freeze_days    integer,
    refund_tiyin   integer,
    allow_negative boolean
  )
  language plpgsql
  stable
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
           s.allow_negative
      from public.subscriptions s
     where s.id = p_subscription_id;
end;
$$;


-- 4. Бейдж специалиста: проверка центра для всех ролей -----------------------------------

-- Для owner/admin не было ни одной ветки: функция шла прямо в select по
-- student_id без фильтра по центру. Владелец центра А по известному id
-- ребёнка из центра Б получал состояние его абонемента. Проверяется
-- принадлежность к центру, но не deleted_at: карточка архивного ребёнка для
-- владельца легитимна и должна показывать «нет», а не отказ в правах.
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
  if not exists (
    select 1 from public.students st
     where st.id = p_student_id and st.center_id = public.current_center()
  ) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if v_role = 'teacher' and not public.teacher_teaches_student(p_student_id) then
    raise exception 'Этот ребёнок не на ваших занятиях' using errcode = '42501';
  end if;
  if v_role = 'parent' and not public.parent_of_student(p_student_id) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- allow_negative держит абонемент выбираемым и после нуля — иначе списание
  -- уходило бы в долг по цене услуги, а флаг означает «списывать в минус».
  select s.id, public.subscription_lessons_left(s.id) into v_sub, v_left
    from public.subscriptions s
   where s.student_id = p_student_id
     and s.center_id = public.current_center()
     and s.deleted_at is null
     and s.status = 'active'
     and (s.allow_negative or public.subscription_state(s.id) = 'active')
   order by s.ends_at asc nulls last, s.created_at, s.id
   limit 1;

  if v_sub is null then return 'нет'; end if;
  if v_left is null then return 'есть'; end if;
  -- Ноль и минус — «нет»: оплаченных занятий не осталось, даже если
  -- списание продолжается в долг. Специалисту важно именно это.
  if v_left <= 0 then return 'нет'; end if;
  if v_left <= 2 then return 'заканчивается'; end if;
  return 'есть';
end;
$$;


-- 5. Отметка: замороженные факты и колоночный грант ---------------------------------------

-- Клиенту остаются только status_id и comment. Без этого PATCH с другим
-- student_id переносил бы списание на ребёнка, которого на занятии не было,
-- а marked_by подделывался одной строкой. Составной FK ловит только чужой
-- центр — своего он не различает.
revoke update on public.attendance from authenticated;
grant update (status_id, comment) on public.attendance to authenticated;

-- Семантика по операциям:
--   INSERT — все проверки занятия, абонемент по ДАТЕ ЗАНЯТИЯ, цена замораживается.
--   UPDATE только comment — ничего не пересчитывается, события не рождаются.
--   UPDATE status_id — deducted/counts_absence из нового статуса, привязка к
--     абонементу и цена сохраняются. Новый абонемент подбирается один раз в
--     жизни строки: когда списание впервые становится true, а привязки ещё
--     нет. Круг «пришёл → болел → пришёл» остаётся на том же абонементе —
--     иначе третий шаг выбирал бы из сегодняшнего набора, и занятие января
--     списалось бы с абонемента, купленного в марте.
--   Смена lesson_id/student_id возможна только из доверенного кода (грант
--     закрыт) и запускает все проверки заново.
create or replace function public.attendance_fill_and_check()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_lesson         public.lessons;
  v_status         public.attendance_statuses;
  v_sub            public.subscriptions;
  v_cand           uuid;
  v_lesson_date    date;
  v_price          integer;
  v_keys_changed   boolean := false;
  v_status_changed boolean := false;
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

  -- Состояние занятия проверяется при создании отметки и при смене ключей.
  -- Смена статуса у старой отметки его не трогает: занятие могли отменить
  -- позже, и правка истории не должна об это спотыкаться — пересчёт остатка
  -- отменённые занятия и так не считает.
  if tg_op = 'INSERT' or v_keys_changed then
    if v_lesson.status = 'cancelled' then
      raise exception 'Занятие отменено — отметить посещение нельзя' using errcode = '22023';
    end if;
    if v_lesson.starts_at > now() then
      raise exception 'Занятие ещё не началось' using errcode = '22023';
    end if;
    -- FK на lesson_participants здесь ловушка: rebuild_lesson_participants
    -- чистит состав при каждой правке занятия, каскад снёс бы отметки.
    if not exists (
      select 1 from public.lesson_participants p
       where p.lesson_id = new.lesson_id and p.student_id = new.student_id
    ) then
      raise exception 'Этот ребёнок не участник занятия' using errcode = '22023';
    end if;
  end if;

  if tg_op = 'UPDATE' then
    -- Замороженные факты: всё, что пришло от клиента, перетирается старым.
    new.marked_by       := old.marked_by;
    new.subscription_id := old.subscription_id;
    new.price_tiyin     := old.price_tiyin;
    new.deducted        := old.deducted;
    new.counts_absence  := old.counts_absence;
    if not v_status_changed and not v_keys_changed then
      new.marked_at := old.marked_at;
      return new;
    end if;
  else
    -- На вставке клиент не выбирает абонемент и не назначает цену.
    new.marked_by       := coalesce(auth.uid(), new.marked_by);
    new.subscription_id := null;
    new.price_tiyin     := 0;
  end if;
  new.marked_at := now();

  select * into v_status from public.attendance_statuses
   where id = new.status_id and center_id = new.center_id and deleted_at is null;
  if not found then
    raise exception 'Статус посещения не найден' using errcode = '42704';
  end if;
  new.deducted       := v_status.deducts_lesson;
  new.counts_absence := v_status.counts_absence;

  if new.deducted and new.subscription_id is null then
    -- Кандидат — по дате занятия, а не по сегодня: окно действия, заморозка
    -- и остаток смотрятся на день, когда ребёнок пришёл. Порядок явный:
    -- при равных ends_at выбор иначе недетерминирован.
    select s.id into v_cand
      from public.subscriptions s
     where s.student_id = new.student_id
       and s.center_id  = new.center_id
       and s.deleted_at is null
       and s.status <> 'cancelled'
       and s.starts_at <= v_lesson_date
       and (s.ends_at is null or s.ends_at >= v_lesson_date)
       and (s.allow_negative
            or s.lessons_total is null
            or s.lessons_total - s.lessons_used - s.lessons_written_off > 0)
       and not exists (
             select 1 from public.subscription_freezes f
              where f.subscription_id = s.id and f.period @> v_lesson_date)
       and (s.type_id is null
            or exists (select 1 from public.subscription_types t
                        where t.id = s.type_id
                          and (t.service_id is null or t.service_id = v_lesson.service_id)))
     order by s.ends_at asc nulls last, s.created_at, s.id
     limit 1;

    if v_cand is not null then
      -- Блокировка отдельно от выбора. `for update ... limit 1` в read
      -- committed после ожидания перепроверяет where на новой версии строки
      -- и при несовпадении возвращает ноль строк — отметка молча ушла бы в
      -- долг вместо «повторите». Поэтому: выбрать, заблокировать, перепроверить.
      select * into v_sub from public.subscriptions s where s.id = v_cand for update;
      if v_sub.deleted_at is not null
         or v_sub.status = 'cancelled'
         or not (v_sub.allow_negative
                 or v_sub.lessons_total is null
                 or v_sub.lessons_total - v_sub.lessons_used - v_sub.lessons_written_off > 0)
         or exists (select 1 from public.subscription_freezes f
                     where f.subscription_id = v_sub.id and f.period @> v_lesson_date)
      then
        raise exception 'Абонемент изменился во время отметки — повторите'
          using errcode = '40001';
      end if;
      new.subscription_id := v_sub.id;
      new.price_tiyin     := coalesce(v_sub.lesson_price_tiyin, 0);
    else
      -- Списывать не с чего: долг по цене услуги на момент занятия.
      select sv.default_price_tiyin into v_price from public.services sv
       where sv.id = v_lesson.service_id;
      new.price_tiyin := coalesce(v_price, 0);
    end if;
  elsif tg_op = 'INSERT' then
    -- Без списания цена всё равно фиксируется из услуги: статус позже может
    -- стать списывающим, и тогда первая привязка перезапишет её из абонемента.
    select sv.default_price_tiyin into v_price from public.services sv
     where sv.id = v_lesson.service_id;
    new.price_tiyin := coalesce(v_price, 0);
  end if;

  return new;
end;
$$;

-- События — по существу, а не на каждый UPDATE. Тройная правка комментария
-- рождала три attendance.marked и три no_subscription с одним attendance_id;
-- этап 5 разослал бы родителю три сообщения о долге за одно занятие.
create or replace function public.attendance_recalc_trigger()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_left     integer;
  v_sub      uuid;
  v_material boolean;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.recalc_subscription_usage(old.subscription_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform public.recalc_subscription_usage(new.subscription_id);
  end if;
  if tg_op = 'DELETE' then
    return null;
  end if;

  v_material := tg_op = 'INSERT'
             or new.status_id       is distinct from old.status_id
             or new.deducted        is distinct from old.deducted
             or new.subscription_id is distinct from old.subscription_id
             or new.price_tiyin     is distinct from old.price_tiyin;
  if not v_material then
    return null;
  end if;

  v_sub := new.subscription_id;

  if v_sub is null and new.deducted and not exists (
    select 1 from public.events e
     where e.type = 'attendance.no_subscription'
       and e.payload ->> 'attendance_id' = new.id::text
  ) then
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

    -- Ровно на границе и один раз: остаток — величина пересчитываемая, и без
    -- дедупликации по данным правка «болел» → «пришёл» слала бы второе.
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
    -- allow_negative без этого события списывал бы молча: no_subscription не
    -- шлётся (абонемент есть), debt_tiyin не растёт (считается по
    -- subscription_id is null), exhausted ушло один раз на нуле.
    elsif v_left < 0 and not exists (
      select 1 from public.events e
       where e.type = 'subscription.overdrawn'
         and e.payload ->> 'subscription_id' = v_sub::text
    ) then
      perform public.emit_event('subscription.overdrawn',
        jsonb_build_object('center_id', new.center_id, 'subscription_id', v_sub,
                           'student_id', new.student_id, 'lessons_left', v_left), new.center_id);
    end if;
  end if;

  if tg_op = 'INSERT' or new.counts_absence is distinct from old.counts_absence then
    perform public.check_absent_streak(new.center_id, new.student_id, new.lesson_id);
  end if;
  return null;
end;
$$;

-- 6. Серия пропусков без гонки ---------------------------------------------------------------

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
  v_pp   record;
  v_gap  boolean;
begin
  -- Сериализация проверок серии по ребёнку. Две почти одновременные отметки
  -- соседних занятий на снимке read committed не видят друг друга, и событие
  -- о реальных двух пропусках подряд не уходит вовсе. Advisory lock, а не
  -- `for update` на students: тот конфликтует с for key share, который берёт
  -- вставка любой строки с FK на ребёнка — массовая отметка группы вешала бы
  -- создание расписания.
  perform pg_advisory_xact_lock(hashtextextended(p_student::text, 0));

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
  -- Смотрится занятие, непосредственно предшествующее v_prev, а не «любой
  -- пропуск когда-либо раньше»: в 0009 было второе, и один прогул полгода
  -- назад навсегда глушил бы событие для этого ребёнка.
  select a.counts_absence into v_pp
    from public.attendance a join public.lessons l on l.id = a.lesson_id
   where a.student_id = p_student
     and l.starts_at < v_prev.starts_at
     and l.deleted_at is null and l.status <> 'cancelled'
   order by l.starts_at desc limit 1;
  if found and v_pp.counts_absence then
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


-- 7. Отмена занятий: один порядок блокировок на весь стейтмент ----------------------------------

-- Строчный триггер сортировал абонементы внутри одного занятия. cancel_series_from
-- обновляет двадцать занятий одним стейтментом — двадцать срабатываний, и
-- глобально порядок «занятие 1: A, C; занятие 2: B» не отсортирован. Две
-- параллельные отмены серий сходились в deadlock. Statement-level триггер с
-- transition table собирает все абонементы стейтмента и идёт по ним по порядку.
create or replace function public.lessons_recalc_attendance_trigger()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_sub uuid;
begin
  -- Список колонок у триггера с transition tables Postgres не допускает
  -- (0A000: transition tables cannot be specified for triggers with column
  -- lists), поэтому триггер — на любой update, а «изменились ли status или
  -- deleted_at» проверяется здесь сравнением старой и новой таблиц.
  for v_sub in
    select distinct a.subscription_id
      from next_rows n
      join prev_rows p on p.id = n.id
      join public.attendance a on a.lesson_id = n.id
     where a.subscription_id is not null
       and (n.status is distinct from p.status
            or n.deleted_at is distinct from p.deleted_at)
     order by 1
  loop
    perform public.recalc_subscription_usage(v_sub);
  end loop;
  return null;
end;
$$;

drop trigger if exists lessons_recalc_attendance on public.lessons;
create trigger lessons_recalc_attendance
  after update on public.lessons
  referencing old table as prev_rows new table as next_rows
  for each statement execute function public.lessons_recalc_attendance_trigger();


-- 8. Абонементы: прямой insert закрыт, цена согласована, архив только пустого ---------------------

-- Insert был выдан на всю строку, и админ мог вставить абонемент с любой
-- lesson_price_tiyin мимо sell_subscription — refund_subscription посчитал
-- бы возврат больше, чем когда-либо заплачено. Продажа — только через RPC.
revoke insert on public.subscriptions from authenticated;

-- Инвариант — констрейнт, а не проверка внутри sell_subscription. Без
-- функции в теле: EXECUTE на неё проверялся бы у вставляющей роли, и порядок
-- восстановления из дампа усложнялся бы. Целочисленное деление — это и есть
-- calc_lesson_price. NOT VALID + отдельная валидация: одна строка, заведённая
-- руками в Studio, иначе валила бы деплой целиком, а файл уже неизменяем.
alter table public.subscriptions
  add constraint subscriptions_lesson_price_consistent
  check (lessons_total is null or lesson_price_tiyin = price_tiyin / lessons_total)
  not valid;

do $$
begin
  alter table public.subscriptions validate constraint subscriptions_lesson_price_consistent;
exception when check_violation then
  raise warning 'subscriptions: остались строки с несогласованной lesson_price_tiyin — констрейнт оставлен NOT VALID, новые строки он держит';
end;
$$;

-- Мягкое удаление с остатком: абонемент исчезает из student_balance, деньги
-- остаются. Архивировать можно возвращённый, перенесённый или пустой.
create or replace function public.subscriptions_guard_soft_delete()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.deleted_at is not null and old.deleted_at is null
     and new.status <> 'cancelled'
     and coalesce(new.lessons_total - new.lessons_used - new.lessons_written_off, 0) > 0
  then
    raise exception 'У абонемента есть остаток — сначала верните или перенесите его'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists subscriptions_guard_soft_delete on public.subscriptions;
create trigger subscriptions_guard_soft_delete
  before update of deleted_at on public.subscriptions
  for each row execute function public.subscriptions_guard_soft_delete();


-- 9. Витрина: минус виден --------------------------------------------------------------------------

-- Текущий абонемент показывается и на нуле (exhausted) — администратору важно
-- видеть «0 из 8», а не пустоту. Отрицательный остаток при allow_negative —
-- отдельной суммой: раньше он не был виден нигде, кроме знака у lessons_left.
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
    ), 0)::integer                              as debt_tiyin,
    (greatest(-coalesce(public.subscription_lessons_left(sub.id), 0), 0)
      * coalesce(sub.lesson_price_tiyin, 0))::integer as overdrawn_tiyin
  from public.students s
  left join lateral (
    select s2.* from public.subscriptions s2
     where s2.student_id = s.id
       and s2.deleted_at is null
       and s2.status = 'active'
       and public.subscription_state(s2.id) in ('active', 'exhausted')
     order by s2.ends_at asc nulls last, s2.created_at, s2.id
     limit 1
  ) sub on true
  where s.deleted_at is null
    -- Роль фильтруется в самой вью: debt_tiyin считается по attendance, а её
    -- специалист видит по своим занятиям — без этого долг утекал бы к нему.
    and (
      public.my_role() in ('owner', 'admin')
      or (public.my_role() = 'parent' and public.parent_of_student(s.id))
    );


-- Права ---------------------------------------------------------------------------------------------

-- create or replace сохраняет ACL, но правило проекта — каждая функция
-- заканчивается явными грантами, и новая subscription_summary без них
-- досталась бы anon через default privileges.
revoke execute on function
  public.user_email(uuid),
  public.find_payer_by_phone(text),
  public.create_lesson_series_preview(jsonb),
  public.lesson_slot_conflicts(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid),
  public.sell_subscription(uuid, uuid, integer, date),
  public.freeze_subscription(uuid, date, date),
  public.unfreeze_subscription(uuid, date),
  public.refund_subscription(uuid, integer),
  public.transfer_remaining(uuid, uuid),
  public.mark_attendance(uuid, uuid, text, text),
  public.mark_attendance_bulk(uuid, jsonb),
  public.student_subscription_badge(uuid),
  public.subscription_lessons_left(uuid),
  public.subscription_state(uuid),
  public.subscription_freeze_days(uuid),
  public.refund_calc(uuid),
  public.subscription_summary(uuid)
  from public, anon;

grant execute on function
  public.user_email(uuid),
  public.find_payer_by_phone(text),
  public.create_lesson_series_preview(jsonb),
  public.sell_subscription(uuid, uuid, integer, date),
  public.freeze_subscription(uuid, date, date),
  public.unfreeze_subscription(uuid, date),
  public.refund_subscription(uuid, integer),
  public.transfer_remaining(uuid, uuid),
  public.mark_attendance(uuid, uuid, text, text),
  public.mark_attendance_bulk(uuid, jsonb),
  public.student_subscription_badge(uuid),
  public.subscription_lessons_left(uuid),
  public.subscription_state(uuid),
  public.subscription_freeze_days(uuid),
  public.refund_calc(uuid),
  public.subscription_summary(uuid)
  to authenticated;

revoke execute on function
  public.attendance_fill_and_check(),
  public.attendance_recalc_trigger(),
  public.lessons_recalc_attendance_trigger(),
  public.check_absent_streak(uuid, uuid, uuid),
  public.subscriptions_guard_soft_delete()
  from public, anon, authenticated;

comment on function public.subscription_summary(uuid) is
  'Остаток, состояние, дни заморозки и сумма возврата абонемента. Только owner/admin своего центра; чужой — 42501. Калькуляторы под ней — внутренние.';
