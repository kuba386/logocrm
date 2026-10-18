-- =============================================================================
-- 0103_attendance_balance_by_service.sql — метка остатка в панели отметки
-- с учётом услуги занятия
--
-- Жалоба KadamLogo 18.10.2026: «специалист отмечает СМК — снимает с
-- абонемента». На проде за 60 дней 59 списывающих отметок СМК — все ушли в
-- долг (абонементов СМК не продано), логопедические абонементы не тронуты.
-- Путаницу давала метка панели: student_balance / student_subscription_badge
-- не знают ни услуги, ни даты занятия и показывали «8 зан.» логопедического
-- абонемента рядом с кнопками СМК-занятия. Решение владельца: СМК — отдельный
-- абонемент, правило списания не меняется.
--
-- Решения (architect-ревью плана: 9 замечаний — учтены):
--   Р1. Правило выбора абонемента — одна копия. attendance_subscription_
--       candidates_unchecked отдаёт кандидатов (фильтр из 0055 без изменений),
--       attendance_pick_subscription_unchecked — первого по порядку 0055.
--       attendance_fill_and_check перевыпущен из 0055 с двумя заменами:
--       первый select кандидата → pick, проверка «есть незамороженная
--       альтернатива» (s2) → candidates. Остальное — байт в байт.
--   Р2. lesson_attendance_balances(lesson) — строка на ребёнка:
--       отметка с subscription_id — этот абонемент (смена статуса его не
--       меняет, 0055: «пришёл → болел → пришёл» спишет с него же):
--         deducted → 'charged', иначе — его остаток (заморозку обратная смена не проверяет);
--       отметка без абонемента и deducted → 'free' (цена 0: занятие без
--         услуги, бесплатная услуга — в долг не идёт), 'covered' (живое
--         покрытие 0088) или 'debt'; суммы нет и текст нейтральный — долг
--         гасится и деньгами, и списанием (0087), по отметке этого не видно;
--       иначе прогноз pick на дату занятия (пояс центра) и услугу занятия:
--         нет кандидата → 'no_service' (у занятия нет услуги, цена 0),
--         'free' (услуга бесплатна) или 'no_subscription' (цена услуги);
--         заморожен → 'frozen'; иначе остаток.
--   Р3. Остаток словом для всех: 'subscription' (> 2 или безлимит),
--       'subscription_low' (1–2), 'subscription_empty' (≤ 0, allow_negative).
--       Числа (lessons_left, price_tiyin) — только стойке (can_front_desk:
--       owner/admin/registrar — им student_balance и так открыт). Специалисту
--       null. Колонка numbers говорит вебу, скрыты ли числа: null у стойки —
--       «безлимит», у специалиста — «скрыто»; роль веб не дублирует.
--       Известный пробел, не закрываемый здесь: attendance_teacher_read
--       (0009) отдаёт специалисту price_tiyin его занятий прямым select.
--   Р4. Гейт — как у mark_attendance (0026): стойка или специалист этого
--       занятия; занятие своего центра и не удалено (teacher_of_lesson центр
--       не проверяет). Роль — coalesce(my_role(), '').
--   Р5. Дети — участники занятия плюс все, у кого есть отметка по нему:
--       пересборка состава после переноса не прячет уже отмеченного.
--   Р6. lessons_left у 'charged' — текущий остаток абонемента, не «после этого
--       занятия»; веб пишет «сейчас осталось N».
-- =============================================================================


-- 1. Кандидаты и выбор абонемента — одна копия правила ---------------------------------------

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
         and (s.type_id is null
              or exists (select 1 from public.subscription_types t
                          where t.id = s.type_id
                            and (t.service_id is null or t.service_id = p_service)))
    ) c
   where c.ends_at is null or c.ends_at >= p_day or c.is_frozen;
$$;

comment on function public.attendance_subscription_candidates_unchecked(uuid, uuid, uuid, date) is
  'Абонементы, с которых может списаться отметка ребёнка на занятие услуги p_service в день p_day (правило 0055). Без проверки прав — только для definer-функций.';

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
   order by c.is_frozen asc, c.ends_at asc nulls last, c.created_at, c.id
   limit 1;
$$;

comment on function public.attendance_pick_subscription_unchecked(uuid, uuid, uuid, date) is
  'Абонемент, с которого спишется отметка (порядок 0055: незамороженные, раньше кончается, раньше создан). Одна копия для attendance_fill_and_check и lesson_attendance_balances.';

revoke all on function public.attendance_pick_subscription_unchecked(uuid, uuid, uuid, date)
  from public, anon, authenticated, service_role;


-- 2. attendance_fill_and_check — из 0055, выбор через функции раздела 1 ---------------------

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


-- 3. lesson_attendance_balances — метка панели отметки ---------------------------------------

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
    select k.student_id, a.subscription_id, a.deducted, a.price_tiyin, a.id as attendance_id
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

    if r.subscription_id is not null then
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
  'Метка панели отметки: по каждому ребёнку занятия — с какого абонемента спишется (или списалось) занятие с учётом услуги и даты занятия, либо долг. Числа — только стойке.';

revoke all on function public.lesson_attendance_balances(uuid) from public, anon;
grant execute on function public.lesson_attendance_balances(uuid) to authenticated;
