-- =============================================================================
-- 0112_status_pay_to_marks.sql — оплата специалисту по статусу к прошлым отметкам
--
-- Повод: kadamlogo (прод) 16.10.2026 снял галочку «Оплачивается специалисту»
-- у статуса «Пришёл» — подсказка «понадобится расчёту зарплат» читалась как
-- «на будущее». attendance.pays_teacher — снимок галочки на момент отметки
-- (0017), поэтому возврат галочки старые отметки не чинит: 436 занятий в
-- зарплате с «статус не оплачивается». Решение владельца 18.11.2026: кнопка в
-- карточке статуса «применить к прошлым отметкам с даты».
--
-- Решения (ревью архитектора плана: 2 блокера, 6 дыр — все закрыты):
--   Р1. apply_status_pay_to_marks(status, from, dry_run) — can_finance (те же,
--       кто утверждает зарплату и вносит ставки задним числом). Переводит
--       pays_teacher отметок статуса с даты занятия (пояс центра) на текущую
--       галочку. dry_run — тот же отбор без записи, для «изменится N».
--   Р2. Отбор — только живые занятия (deleted_at is null) и не отменённые:
--       триггер отметки падает на удалённом занятии и откатил бы весь вызов,
--       а за отменённое и так платится 0.
--   Р3. Не трогаем месяцы (специалист отметки × месяц занятия): с живым
--       снимком salary_runs, с выплатами (сумма expenses по salary_month ≠ 0)
--       и закрытые financial_periods. Деньги, которые уже утвердили или
--       выплатили, не меняются молча — их поправит корректировка.
--   Р4. Гонка с approve_salary/pay_salary: advisory-ключ 'salary_payout:'
--       (специалист, месяц) — тот же, что у pay_salary (0101); approve_salary
--       перевыпущен из 0027 дословно + этот ключ до calc_salary. RPC берёт
--       ключи в отсортированном порядке ДО проверок Р3.
--   Р5. Строка статуса — for update (галочку не переключат посреди вызова);
--       целевые отметки — for update по id до UPDATE, раньше замков на
--       абонементы из attendance_recalc_trigger (иначе 40P01 с отметкой).
--       Число обновлённых — по returning со сверкой с целью; расхождение —
--       40001, без автоповтора.
--   Р6. Триггер отметки (из 0107, одно изменение): при UPDATE без смены
--       статуса pays_teacher меняется только под транзакционным флагом
--       logocrm.status_pay_apply = '1' и только в текущее значение галочки
--       статуса. Флаг ставит и снимает одна RPC (как logocrm.funnel_write, 0055).
--   Р7. Только чтение (center_writable) — PT402 на применении; dry_run
--       проходит.
--
-- Принято:
--   - attendance_recalc_trigger на каждую строку делает пустой пересчёт
--     абонемента: строка в audit_log и сдвиг subscriptions.updated_at без
--     разницы в данных. Сужать общий триггер — отдельное изменение.
--   - Событие не эмитится: audit_log на attendance фиксирует каждую строку.
-- =============================================================================


-- 1. Триггер отметки: перевод снимка оплаты под флагом (Р6) ------------------------------------------

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
  v_req_pays               boolean;  -- 0112: что просили записать в pays_teacher
begin
  if tg_op = 'UPDATE' then
    v_req_pays       := new.pays_teacher;
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
      -- 0112: снимок оплаты специалисту переводится на ТЕКУЩУЮ галочку
      -- статуса — только из apply_status_pay_to_marks (транзакционный флаг) и
      -- только в значение статуса. Любое другое значение перетёрто выше.
      if v_req_pays is distinct from old.pays_teacher
         and current_setting('logocrm.status_pay_apply', true) = '1'
         and exists (
           select 1 from public.attendance_statuses s
            where s.id = new.status_id and s.center_id = new.center_id
              and s.deleted_at is null and s.pays_teacher = v_req_pays
         ) then
        new.pays_teacher := v_req_pays;
      end if;
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


-- 2. approve_salary: общий ключ с выплатой и пересчётом отметок (Р4) ---------------------------------

-- из 0027_roles_finance_rpc.sql
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
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_month >= date_trunc('month', public.center_today(v_center))::date then
    raise exception 'Утвердить зарплату можно только за полностью прошедший месяц' using errcode = '22023';
  end if;

  -- 0112: тот же ключ, что у pay_salary и apply_status_pay_to_marks — снимок
  -- не считается по отметкам, которые параллельно переводят на другую оплату.
  perform pg_advisory_xact_lock(hashtextextended('salary_payout:' || p_teacher_id::text || ':' || v_month::text, 0));

  select coalesce(sum(c.amount_tiyin), 0), coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
    into v_calc_total, v_lines
    from public.calc_salary(p_teacher_id, v_month) c;

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
revoke all on function public.approve_salary(uuid, date) from public, anon;
grant execute on function public.approve_salary(uuid, date) to authenticated;


-- 3. apply_status_pay_to_marks (Р1–Р5, Р7) -----------------------------------------------------------

create or replace function public.apply_status_pay_to_marks(
  p_status_id uuid,
  p_from      date,
  p_dry_run   boolean default false
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center         uuid := public.current_center();
  v_target         boolean;
  v_pair           record;
  v_c_ids          uuid[];
  v_c_teachers     uuid[];
  v_c_months       date[];
  v_ids            uuid[];
  v_updated        integer;
  v_skipped_salary integer;
  v_skipped_paid   integer;
  v_skipped_period integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_status_id is null or p_from is null then
    raise exception 'Укажите статус и дату' using errcode = '22023';
  end if;

  select s.pays_teacher into v_target
    from public.attendance_statuses s
   where s.id = p_status_id and s.center_id = v_center and s.deleted_at is null
   for update;
  if not found then
    raise exception 'Статус посещения не найден' using errcode = '42704';
  end if;

  if not p_dry_run and not public.center_writable(v_center) then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;

  -- Кандидаты один раз — массивами; замки и проверки ниже идут по ним.
  -- Новых кандидатов под замком статуса не появится: новая отметка и смена
  -- статуса берут текущую галочку, то есть уже совпадают с целью.
  select coalesce(array_agg(a.id order by a.id), '{}'),
         coalesce(array_agg(a.paid_teacher_id order by a.id), '{}'),
         coalesce(array_agg(date_trunc('month', (l.starts_at at time zone public.center_timezone(v_center)))::date
                            order by a.id), '{}')
    into v_c_ids, v_c_teachers, v_c_months
    from public.attendance a
    join public.lessons l on l.id = a.lesson_id
   where a.center_id = v_center
     and a.status_id = p_status_id
     and a.pays_teacher is distinct from v_target
     and l.deleted_at is null
     and l.status <> 'cancelled'
     and (l.starts_at at time zone public.center_timezone(v_center))::date >= p_from;

  -- Р4: ключи до проверок, в одном порядке у всех вызовов.
  if not p_dry_run then
    for v_pair in
      select distinct c.teacher_id, c.month
        from unnest(v_c_teachers, v_c_months) as c(teacher_id, month)
       where c.teacher_id is not null
       order by c.teacher_id, c.month
    loop
      perform pg_advisory_xact_lock(
        hashtextextended('salary_payout:' || v_pair.teacher_id::text || ':' || v_pair.month::text, 0));
    end loop;
  end if;

  with c as (
    select * from unnest(v_c_ids, v_c_teachers, v_c_months) as c(id, teacher_id, month)
  ),
  k as (
    select c.id,
           case
             when exists (select 1 from public.financial_periods fp
                           where fp.center_id = v_center and fp.month = c.month and fp.closed_at is not null)
               then 'period'
             when exists (select 1 from public.salary_runs sr
                           where sr.center_id = v_center and sr.teacher_id = c.teacher_id
                             and sr.month = c.month and sr.cancelled_at is null)
               then 'salary'
             when (select coalesce(sum(e.amount_tiyin), 0) from public.expenses e
                    where e.center_id = v_center and e.teacher_id = c.teacher_id
                      and e.salary_month = c.month) <> 0
               then 'paid'
           end as skip
      from c
  )
  select count(*) filter (where k.skip = 'salary'),
         count(*) filter (where k.skip = 'paid'),
         count(*) filter (where k.skip = 'period'),
         array_agg(k.id order by k.id) filter (where k.skip is null)
    into v_skipped_salary, v_skipped_paid, v_skipped_period, v_ids
    from k;

  if p_dry_run or v_ids is null then
    return jsonb_build_object(
      'updated', coalesce(array_length(v_ids, 1), 0),
      'skipped_salary', v_skipped_salary,
      'skipped_paid', v_skipped_paid,
      'skipped_period', v_skipped_period,
      'pays_teacher', v_target);
  end if;

  -- Р5: отметки — раньше абонементов, которые запрёт after-триггер пересчёта.
  perform 1 from public.attendance a where a.id = any(v_ids) order by a.id for update;

  perform set_config('logocrm.status_pay_apply', '1', true);
  with done as (
    update public.attendance a
       set pays_teacher = v_target
     where a.id = any(v_ids)
       and a.status_id = p_status_id
    returning a.pays_teacher
  )
  select count(*) filter (where pays_teacher is not distinct from v_target) into v_updated from done;
  perform set_config('logocrm.status_pay_apply', '', true);

  if v_updated <> array_length(v_ids, 1) then
    raise exception 'Отметки изменились во время пересчёта — попробуйте ещё раз' using errcode = '40001';
  end if;

  return jsonb_build_object(
    'updated', v_updated,
    'skipped_salary', v_skipped_salary,
    'skipped_paid', v_skipped_paid,
    'skipped_period', v_skipped_period,
    'pays_teacher', v_target);
end;
$$;
comment on function public.apply_status_pay_to_marks(uuid, date, boolean) is
  '0112: перевести снимок «оплачивается специалисту» прошлых отметок статуса (с даты занятия) на текущую галочку статуса. Без утверждённых, выплаченных и закрытых месяцев. p_dry_run — только счёт.';
revoke all on function public.apply_status_pay_to_marks(uuid, date, boolean) from public, anon;
grant execute on function public.apply_status_pay_to_marks(uuid, date, boolean) to authenticated;
