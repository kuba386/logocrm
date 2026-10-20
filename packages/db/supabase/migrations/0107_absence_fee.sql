-- =============================================================================
-- 0107_absence_fee.sql — штраф за пропуск (этап 16)
--
-- Решение владельца 20.10.2026: доля за пропуск — штраф деньгами, абонемент
-- остаётся в целых занятиях (как late cancel fee в Pike13/Glofox).
--
-- Решения (ревью архитектора плана: 3 блокера — схема изменена на «колонку»):
--   Р1. attendance_statuses.fee_percent (1..100 или null) — только у статуса без
--       списания, без присутствия, без права на отработку и не по умолчанию.
--   Р2. attendance.fee_tiyin — сумма штрафа; deducted у штрафной отметки false,
--       subscription_id и price_tiyin — снимок занятия и замораживаются, как у
--       «Болел». Поэтому выручка, посещаемость, покрытие долга, recalc,
--       события и CSV штраф не видят, а круги «Пришёл → штраф → Пришёл» и
--       «штраф → Болел → штраф» идемпотентны (без «50% от 50%»).
--   Р3. База штрафа — снимок цены: у несписывающей отметки на INSERT — цена
--       занятия абонемента, который списал бы занятие (pick без блокировки),
--       иначе цена услуги. База 0/NULL — штрафа нет, отметка проходит.
--       Арифметика целая: (база × % + 50) / 100.
--   Р4. Долг семьи: lesson_debt_accounts_unchecked (0089) складывает долг за
--       занятия и живые штрафы у живых занятий — штраф виден в «Долгах»,
--       карточке, боте, напоминаниях, «Деньгах семьи», гасится оплатой и
--       авансом.
--   Р5. Отработка штрафом не облагается (CHECK формы на attendance).
--   Р6. Ставит штраф любой, кто отмечает (это статус). Отменяет — только
--       владелец, отдельным действием cancel_attendance_fee с причиной;
--       отмена держится при смене статуса. Через «Списать долг» не отменяем:
--       списание не привязано к штрафу и включало бы отказ в авансе.
--   Р7. Зарплата — по флагу pays_teacher статуса, как сейчас; процентная
--       ставка считается от снимка цены занятия, не от штрафа. Снимок цены у
--       новых несписывающих отметок («Болел») теперь — цена пакета (Р3).
--   Р9 (ревью SQL). Отмену держит триггер заполнения: менять fee_cancelled_*
--       может только владелец в сессии (отменить живой — by = он; вернуть —
--       все поля в null); вернуть — restore_attendance_fee. База у безлимита —
--       0 (как в списывающей ветке), цена услуги — только без абонемента.
--   Р10. Принято: специалист прямым select видит fee_tiyin и причину отмены
--       своих занятий — тот же пробел, что price_tiyin (0103 Р3, политика
--       attendance_teacher_read); в закрытом месяце штраф не отменить
--       (financial_period_guard); отмена после «Списать долг» оставляет
--       списание висеть (класс 0087); старые «Болел» до 0107 несут цену услуги.
--   Р8. Принято: «Покрыть долг абонементом» штрафную отметку не покрывает
--       (она не deducted), но граница remaining_tiyin включает штрафы —
--       покрытие при остатке только штрафа спишет занятие, разница — в аванс.
-- =============================================================================


-- 1. Статусы ----------------------------------------------------------------------------------------

alter table public.attendance_statuses add column if not exists fee_percent integer;

alter table public.attendance_statuses drop constraint if exists attendance_statuses_fee_percent_check;
alter table public.attendance_statuses add constraint attendance_statuses_fee_percent_check
  check (fee_percent is null
         or (fee_percent between 1 and 100
             and not deducts_lesson and not is_present and not grants_makeup and not is_default));

comment on column public.attendance_statuses.fee_percent is
  'Штраф за пропуск, % цены занятия (0107): занятие с абонемента не списывается, доля цены — в долг семьи.';

grant update (code, name, color, deducts_lesson, pays_teacher, counts_absence, notify_parent, sort, grants_makeup, fee_percent)
  on public.attendance_statuses to authenticated;


-- 2. Отметка: сумма и отмена штрафа -----------------------------------------------------------------

alter table public.attendance add column if not exists fee_tiyin integer not null default 0;
alter table public.attendance add column if not exists fee_cancelled_at timestamptz;
alter table public.attendance add column if not exists fee_cancelled_by uuid;
alter table public.attendance add column if not exists fee_cancel_reason text;

alter table public.attendance drop constraint if exists attendance_fee_shape;
alter table public.attendance add constraint attendance_fee_shape
  check (fee_tiyin >= 0
         and (fee_tiyin = 0 or makeup_credit_id is null)
         and ((fee_cancelled_at is null) = (fee_cancel_reason is null))
         and (fee_cancel_reason is null or char_length(fee_cancel_reason) between 1 and 500));

comment on column public.attendance.fee_tiyin is
  'Штраф за пропуск в тыйынах (0107): заполняет attendance_fill_and_check по fee_percent статуса; в долг идёт, пока fee_cancelled_at is null.';

-- Долг семьи читает штрафы по центру — частичный индекс, как у deducted (0031).
create index if not exists attendance_fee_center_idx on public.attendance (center_id, student_id) where fee_tiyin > 0;


-- 3. Перевыпуск отметки, метки панели и счёта долга (Р2–Р4) -----------------------------------------

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
    new.fee_tiyin        := old.fee_tiyin;        -- 0107: сумма штрафа пересчитывается только при смене статуса
    -- 0107 Р6: отмену штрафа держит триггер, а не только колоночный грант.
    -- Менять её может только владелец в сессии: отменить живой штраф
    -- (by = он сам) или вернуть отменённый (все поля в null). Иначе — как было.
    if not (
         auth.uid() is not null
         and coalesce(public.my_role(), '') = 'owner'
         and (
           (old.fee_cancelled_at is null and new.fee_cancelled_at is not null
            and old.fee_tiyin > 0 and new.fee_cancelled_by = auth.uid())
           or
           (old.fee_cancelled_at is not null and new.fee_cancelled_at is null
            and new.fee_cancelled_by is null and new.fee_cancel_reason is null)
         )
       ) then
      new.fee_cancelled_at  := old.fee_cancelled_at;
      new.fee_cancelled_by  := old.fee_cancelled_by;
      new.fee_cancel_reason := old.fee_cancel_reason;
    end if;
    if not v_status_changed and not v_keys_changed then
      new.marked_at := old.marked_at;
      return new;
    end if;
  else
    new.marked_by       := coalesce(auth.uid(), new.marked_by);
    new.subscription_id := null;
    new.price_tiyin     := 0;
    new.paid_teacher_id := coalesce(v_lesson.substitute_teacher_id, v_lesson.teacher_id);  -- 0017
    -- 0107: штраф и его отмена — только из триггера и RPC; клиентское значение перетирается.
    new.fee_tiyin           := 0;
    new.fee_cancelled_at    := null;
    new.fee_cancelled_by    := null;
    new.fee_cancel_reason   := null;
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
    -- 0107: снимок цены несписывающей отметки — цена занятия абонемента,
    -- который списал бы это занятие (без блокировки), иначе цена услуги.
    -- Это база штрафа: одинакова, ставят штраф сразу или исправлением позже.
    -- Нашёлся абонемент — его цена занятия, как в списывающей ветке (у
    -- безлимита 0, штрафа нет); не нашёлся — цена услуги. Так сумма одна,
    -- ставят штраф сразу или исправлением «Пришёл → штраф».
    select coalesce(s.lesson_price_tiyin, 0) into new.price_tiyin
      from public.attendance_pick_subscription_unchecked(
             new.center_id, new.student_id, v_lesson.service_id, v_lesson_date) p
      join public.subscriptions s on s.id = p.id;
    if not found then
      select sv.default_price_tiyin into v_price from public.services sv
       where sv.id = v_lesson.service_id;
      new.price_tiyin := coalesce(v_price, 0);
    end if;
  end if;

  -- 0107: штраф за пропуск — доля снимка цены занятия; абонемент не трогается
  -- (deducted следует за статусом и у штрафного статуса false). Отработка
  -- штрафом не облагается; база 0 или NULL — штрафа нет, отметка проходит.
  -- Отменённый владельцем штраф остаётся отменённым при смене статуса.
  if v_status.fee_percent is not null and new.makeup_credit_id is null then
    new.fee_tiyin := case when coalesce(new.price_tiyin, 0) > 0
                          then ((new.price_tiyin::bigint * v_status.fee_percent + 50) / 100)::integer
                          else 0 end;
  else
    new.fee_tiyin := 0;
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
           a.fee_tiyin, a.fee_cancelled_at,
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
    elsif coalesce(r.fee_tiyin, 0) > 0 and r.fee_cancelled_at is null then
      -- 0107: штраф за пропуск; сумма — только стойке.
      v_kind := 'fee';
    elsif coalesce(r.fee_tiyin, 0) > 0 then
      v_kind := 'fee_cancelled';
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
    price_tiyin  := case when v_numbers and v_kind = 'no_subscription' then coalesce(v_price, 0)
                         when v_numbers and v_kind in ('fee', 'fee_cancelled') then r.fee_tiyin end;
    numbers      := v_numbers;
    return next;
  end loop;
end;
$$;

comment on function public.lesson_attendance_balances(uuid) is
  'Метка панели отметки: по каждому ребёнку занятия — с какого абонемента спишется (или списалось) занятие с учётом услуги и даты занятия, либо долг; 0105 — вид makeup; 0107 — вид fee (штраф за пропуск). Числа — только стойке.';

revoke all on function public.lesson_attendance_balances(uuid) from public, anon;
grant execute on function public.lesson_attendance_balances(uuid) to authenticated;

create or replace function public.lesson_debt_accounts_unchecked(p_center_id uuid, p_student_id uuid default null)
  returns table (
    student_id          uuid,
    accrued_tiyin       integer,
    overdrawn_gross_tiyin integer,
    paid_tiyin          integer,
    written_off_tiyin   integer,
    debt_tiyin          integer,
    overdrawn_tiyin     integer,
    credit_tiyin        integer,
    remaining_tiyin     integer
  )
  language sql
  stable
  security definer
  set search_path = ''
as $$
  with acc as (
    select x.student_id, sum(x.v)::bigint as v
      from (
        select a.student_id, a.price_tiyin::bigint as v
          from public.attendance a
          join public.lessons l on l.id = a.lesson_id
         where a.center_id = p_center_id
           and (p_student_id is null or a.student_id = p_student_id)
           and a.subscription_id is null
           and a.deducted
           and l.deleted_at is null
           and l.status <> 'cancelled'
           -- 0088: отметка, покрытая абонементом, — уже не долг: её занятие списано с абонемента.
           and not exists (select 1 from public.lesson_debt_covers c
                            where c.attendance_id = a.id and c.deleted_at is null)
        union all
        -- 0107: штрафы за пропуск у живых занятий, не отменённые владельцем.
        select a.student_id, a.fee_tiyin::bigint
          from public.attendance a
          join public.lessons l on l.id = a.lesson_id
         where a.center_id = p_center_id
           and (p_student_id is null or a.student_id = p_student_id)
           and a.fee_tiyin > 0
           and a.fee_cancelled_at is null
           and l.deleted_at is null
           and l.status <> 'cancelled'
      ) x
     group by x.student_id
  ),
  ov as (
    select s.student_id,
           sum(greatest(s.lessons_used + s.lessons_written_off - s.lessons_total, 0)::bigint
               * coalesce(s.lesson_price_tiyin, 0))::bigint as v
      from public.subscriptions s
     where s.center_id = p_center_id
       and (p_student_id is null or s.student_id = p_student_id)
       -- 0089: без s.deleted_at is null — архив перерасходованного пакета
       -- перерасход не отменяет (Р1).
       and s.lessons_total is not null
     group by s.student_id
  ),
  pd as (
    select p.student_id, sum(p.amount_tiyin)::bigint as v
      from public.payments p
     where p.center_id = p_center_id
       and (p_student_id is null or p.student_id = p_student_id)
       and p.covers_lesson_debt
     group by p.student_id
  ),
  wo as (
    select w.student_id, sum(w.amount_tiyin)::bigint as v
      from public.lesson_debt_writeoffs w
     where w.center_id = p_center_id
       and (p_student_id is null or w.student_id = p_student_id)
       and w.deleted_at is null
     group by w.student_id
  ),
  ids as (
    select acc.student_id from acc
    union select ov.student_id from ov
    union select pd.student_id from pd
    union select wo.student_id from wo
  ),
  base as (
    select i.student_id,
           coalesce(acc.v, 0)              as accrued,
           coalesce(ov.v, 0)               as over_gross,
           greatest(coalesce(pd.v, 0), 0)  as paid,
           coalesce(wo.v, 0)               as written_off
      from ids i
      join public.students st on st.id = i.student_id and st.center_id = p_center_id and st.deleted_at is null
      left join acc on acc.student_id = i.student_id
      left join ov  on ov.student_id  = i.student_id
      left join pd  on pd.student_id  = i.student_id
      left join wo  on wo.student_id  = i.student_id
  )
  select b.student_id,
         b.accrued::integer,
         b.over_gross::integer,
         b.paid::integer,
         b.written_off::integer,
         greatest(b.accrued - (b.paid + b.written_off), 0)::integer,
         greatest(b.over_gross - greatest(b.paid + b.written_off - b.accrued, 0), 0)::integer,
         greatest(b.paid - (b.accrued + b.over_gross), 0)::integer,
         greatest(b.accrued + b.over_gross - (b.paid + b.written_off), 0)::integer
    from base b;
$$;

comment on function public.lesson_debt_accounts_unchecked(uuid, uuid) is
  'Счёт долга за занятия по ученику (0087/0089): начислено = долговые отметки без абонемента + живые штрафы за пропуск (0107); перерасход пакетов; оплачено; списано. Без проверки прав.';

revoke all on function public.lesson_debt_accounts_unchecked(uuid, uuid) from public, anon, authenticated, service_role;


-- 4. Отмена штрафа — только владелец (Р6) -----------------------------------------------------------

create or replace function public.cancel_attendance_fee(p_attendance_id uuid, p_reason text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_row    public.attendance;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Штраф отменяет только владелец' using errcode = '42501';
  end if;
  if not public.center_writable(v_center) then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  if coalesce(trim(p_reason), '') = '' or char_length(trim(p_reason)) > 500 then
    raise exception 'Укажите причину отмены штрафа (до 500 символов)' using errcode = '22023';
  end if;

  select * into v_row from public.attendance where id = p_attendance_id and center_id = v_center for update;
  if not found then
    raise exception 'Отметка не найдена' using errcode = '42704';
  end if;
  if v_row.fee_tiyin = 0 then
    raise exception 'По этой отметке нет штрафа' using errcode = '22023';
  end if;
  if v_row.fee_cancelled_at is not null then
    return;
  end if;

  update public.attendance
     set fee_cancelled_at = now(), fee_cancelled_by = auth.uid(), fee_cancel_reason = trim(p_reason)
   where id = p_attendance_id;
end;
$$;

revoke all on function public.cancel_attendance_fee(uuid, text) from public, anon, service_role;
grant execute on function public.cancel_attendance_fee(uuid, text) to authenticated;

create or replace function public.restore_attendance_fee(p_attendance_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_row    public.attendance;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Штраф возвращает только владелец' using errcode = '42501';
  end if;
  if not public.center_writable(v_center) then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;

  select * into v_row from public.attendance where id = p_attendance_id and center_id = v_center for update;
  if not found then
    raise exception 'Отметка не найдена' using errcode = '42704';
  end if;
  if v_row.fee_cancelled_at is null then
    return;
  end if;

  update public.attendance
     set fee_cancelled_at = null, fee_cancelled_by = null, fee_cancel_reason = null
   where id = p_attendance_id;
end;
$$;

revoke all on function public.restore_attendance_fee(uuid) from public, anon, service_role;
grant execute on function public.restore_attendance_fee(uuid) to authenticated;
