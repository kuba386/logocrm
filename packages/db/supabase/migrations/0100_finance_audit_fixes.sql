-- =============================================================================
-- 0100_finance_audit_fixes.sql — аудит финансов 16.10.2026: суммы рассрочки,
-- просрочка по абонементу, CSV долгов, дата расхода; сводка денег семьи и
-- поступления за день в вебе
--
-- План — architect-ревью (12 находок, все учтены, номера Аn ниже).
--
-- Что чиним:
--   Р1. Рассрочка проводила одну сумму, а показывала другую. pay_installment
--       (0026) проводит накопительно: base_paid + cumulative(seq ≤ строки) −
--       paid. Оплата строки №2 при неоплаченной №1 проводила обе (4 000 под
--       надписью «Принять · 2 000»), после частичной оплаты через
--       accept_subscription_payment строка «Принять · 2 000» проводила 500.
--       Сверки суммы не было.
--       - installments_view: две новые колонки в конце (прежние на месте):
--         due_through_tiyin — сколько провести, чтобы закрыть всё по эту
--         строку включительно (ровно то, что проведёт pay_installment);
--         row_remaining_tiyin — остаток именно этой строки (А9: не
--         remaining_tiyin — так уже называется остаток долга за занятия в
--         lesson_debt_accounts_unchecked). У отменённого плана обе — 0 (А9).
--         security_invoker повторён явно: create or replace view заменяет
--         опции целиком (А9).
--       - pay_installment: новая сигнатура (p_installment_id,
--         p_expected_amount_tiyin, p_source_id, p_paid_on, p_comment), старая
--         удалена (иначе перегрузка → PGRST203). Сумма к оплате обязательна
--         (А5): без неё следующая кнопка снова провела бы 4 000 под «2 000».
--         Сначала «уже оплачен» (22023), потом сверка (23514) — иначе «сумма
--         изменилась: сейчас 0». Сверка — после блокировок. Дата — днём
--         (p_paid_on), её проверяет record_payment_core: момент p_paid_at
--         пропускал платёж в 2027 год (А7). Источник обязателен (А7), как у
--         accept_subscription_payment: иначе в /cash «Без источника».
--       - Веб-читатели плановой суммы строки (кабинет родителя, карточки
--         ученика и плательщика, «Рассрочки», WhatsApp) переведены на
--         row_remaining_tiyin — иначе на одном экране две цифры (А3).
--       - installments_notify: в событии amount_tiyin — остаток строки на
--         момент уведомления, а не плановая сумма (родителю не напомним
--         2 000, когда осталось 500). Дедупликация — по *_notified_at, payload
--         её не трогает (А10). Гранты — как в 0032: только bot_worker (А10).
--   Р2. «Просрочка по абонементу» завышалась при частично оплаченной строке:
--       0070 брала least(Σ amount просроченных строк, price − paid) — внесено
--       1 500 из 6 000, просрочена только №1 → 2 000 вместо 500. Цифра уходит
--       в /app/debts, дашборд, бот, сводку, debt.reminder родителям (0097).
--       - subscription_overdue_unchecked(p_center) — одна копия формулы:
--         с живым планом — недобор до графика greatest(base − paid, 0) плюс Σ
--         row_remaining строк state = 'overdue', не больше price − paid (А4:
--         не base + max(cumulative), та молча требует, чтобы даты шли вместе с
--         seq, — немонотонные даты есть в фикстуре 0018); без плана — вся
--         недоплата. SECURITY INVOKER (А2, прецедент 0072 Р13): гранта нет ни
--         у кого; из definer-обёрток работает от владельца, а случайный
--         будущий grant упрётся в RLS current_center(), а не отдаст чужой
--         центр по p_center. Без «NULL = все плательщики» (А1): фильтр по
--         плательщику — у вызывающего.
--       - student_subscriptions_overdue — поверх неё, сигнатура, роли и
--         правило payer_id (NULL при разных плательщиках) — как в 0070.
--   Р3. CSV долгов не видел перерасход: export_debts (0058) брала
--       student_debts(), с 0087 это только debt. lessons_debt_tiyin = долг +
--       перерасход (remaining из lesson_debt_accounts_unchecked) — как «долг
--       за занятия» на /app/debts (student_debt_summary: usage).
--   Р4. record_expense не проверял дату: «не в будущем» и «не старше года» —
--       те же границы, что у record_payment_core (тексты свои: «Дата
--       расхода…»); первая строка — сессия и центр. tests/0073 звал его с фиксированной датой — переведён на сырую
--       вставку (А8), иначе с 15.06.2027 джоб db покраснел бы у всех.
--
-- Что добавляем (определения существующие, новых денег нет):
--   Р5. payer_money_summary(p_payer_id) — деньги семьи на карточке
--       плательщика: строка на ребёнка с ненулевыми суммами и строка итога
--       (student_id IS NULL) — итог всегда есть у того, кому можно, даже из
--       нулей; «нельзя» — ноль строк (А6). Определения (А6, Database.md):
--       долг за занятия и аванс — детей, чей ТЕКУЩИЙ плательщик p (как
--       student_debt_problems: payer_id ребёнка); просрочка и недоплата по
--       абонементам — абонементов, КУПЛЕННЫХ p (subscriptions.payer_id, как
--       0070) — поэтому ребёнок, переведённый к другому плательщику, может
--       быть в строках с одной недоплатой. Ближайший платёж — минимальная дата
--       среди неоплаченных строк живых планов (upcoming/due/overdue, как
--       subscription_payment_summary 0090), сумма — Σ row_remaining на эту
--       дату. Порядок проверок (А1): p_payer_id is null → пусто; плательщик
--       живой и этого центра; can_payments — любой; parent — только свой
--       (v_payer is null or v_payer <> p → пусто, сравнение позитивное).
--   Р6. payments_day_summary(p_day) — поступления за день в вебе, как /cash
--       в боте (0072): обёртка над center_payments_day(current_center(), day).
--       SECURITY DEFINER (А11: center_payments_day — invoker без грантов,
--       invoker-обёртка упала бы на permission denied), can_payments иначе
--       42501 (Р8; бот /cash — can_finance, 0072 Р7); NULL и день позже center_today центра —
--       22023 (А11: не current_date — с 00:00 до 06:00 по Бишкеку UTC ещё
--       вчера). Без «не старше года» — чтение, как export_payments (А11).
--
-- Решение владельца 16.10.2026 (дельта — architect-ревью):
--   Р8. «Поступления за день» — и стойке: payments_day_summary под can_payments
--       (регистратор и так читает все платежи по RLS, 0028; расходов там нет,
--       касса с расходами cash_by_source — по-прежнему can_finance). Бот /cash —
--       как был, can_finance (0072 Р7): расхождение записано в Database.md.
--   Аванс без долга (тоже решение владельца) сюда не вошёл: дельта-ревью нашло
--   двойной аванс без сверки и аванс, невидимый после списания долга, — нужна
--   отдельная RPC со сверкой аванса (следующая миграция).
--
-- Таблиц нет — deny-list экспорта не меняется. Порядок объектов (А12): вью →
-- помощник → обёртки (тела language sql проверяются при CREATE).
-- После применения — get_advisors (линтер Supabase).
-- =============================================================================


-- 1. installments_view — сумма к оплате по строке (Р1) -----------------------------------------

create or replace view public.installments_view
  with (security_invoker = true)
as
select i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id, i.plan_id,
       p.base_paid_tiyin, p.cancelled_at,
       i.seq, i.due_date, i.amount_tiyin,
       i.due_notified_at, i.overdue_notified_at, i.created_at, i.updated_at,
       s.price_tiyin, s.paid_tiyin,
       c.cumulative_tiyin,
       case
         when p.cancelled_at is not null then 'cancelled'
         when s.paid_tiyin >= p.base_paid_tiyin + c.cumulative_tiyin then 'paid'
         when i.due_date > public.center_today(i.center_id) then 'upcoming'
         when i.due_date = public.center_today(i.center_id) then 'due'
         else 'overdue'
       end as state,
       -- 0100 Р1: ровно то, что проведёт pay_installment по этой строке.
       case
         when p.cancelled_at is not null then 0
         else greatest(p.base_paid_tiyin + c.cumulative_tiyin - s.paid_tiyin, 0)
       end::integer as due_through_tiyin,
       -- 0100 Р1: остаток именно этой строки (частичная оплата видна по строке).
       case
         when p.cancelled_at is not null then 0
         else least(i.amount_tiyin, greatest(p.base_paid_tiyin + c.cumulative_tiyin - s.paid_tiyin, 0))
       end::integer as row_remaining_tiyin
  from public.installments i
  join public.installment_plans p on p.id = i.plan_id
  join public.subscriptions s on s.id = i.subscription_id
  join lateral (
    select coalesce(sum(j.amount_tiyin), 0)::integer as cumulative_tiyin
      from public.installments j
     where j.plan_id = i.plan_id and j.seq <= i.seq
  ) c on true;

comment on column public.installments_view.due_through_tiyin is
  'Сколько провести, чтобы закрыть всё по эту строку включительно: greatest(base_paid + cumulative − paid, 0); у отменённого плана 0 (0100 Р1). Ровно сумма pay_installment.';
comment on column public.installments_view.row_remaining_tiyin is
  'Остаток этой строки: least(amount, due_through); у отменённого плана 0 (0100 Р1).';

-- create or replace сохраняет ACL; повторяем явно (правило 0010).
revoke all on public.installments_view from anon, authenticated;
grant select on public.installments_view to authenticated;


-- 2. Просрочка по абонементу — одна копия формулы (Р2) ------------------------------------------

create or replace function public.subscription_overdue_unchecked(p_center uuid)
  returns table (subscription_id uuid, student_id uuid, payer_id uuid, overdue_tiyin integer)
  language sql
  stable
  security invoker
  set search_path = ''
as $$
  with plan_subs as (
    -- Абонементы с живым планом: недобор до графика плюс остатки просроченных
    -- строк — порядок дат строк значения не имеет (А4).
    select s.id, s.student_id, s.payer_id,
           least(
             greatest(min(iv.base_paid_tiyin) - s.paid_tiyin, 0)
               + coalesce(sum(iv.row_remaining_tiyin) filter (where iv.state = 'overdue'), 0),
             greatest(s.price_tiyin - s.paid_tiyin, 0)
           )::integer as amt
      from public.subscriptions s
      join public.students st on st.id = s.student_id and st.center_id = s.center_id
      join public.installments_view iv on iv.subscription_id = s.id and iv.cancelled_at is null
     where s.center_id = p_center
       and s.deleted_at is null
       and st.deleted_at is null
       and s.status <> 'cancelled'
     group by s.id, s.student_id, s.payer_id, s.paid_tiyin, s.price_tiyin
  ),
  plain_subs as (
    -- Без живого плана: вся недоплата срочна немедленно (как 0070).
    select s.id, s.student_id, s.payer_id, (s.price_tiyin - s.paid_tiyin)::integer as amt
      from public.subscriptions s
      join public.students st on st.id = s.student_id and st.center_id = s.center_id
     where s.center_id = p_center
       and s.deleted_at is null
       and st.deleted_at is null
       and s.status <> 'cancelled'
       and s.paid_tiyin < s.price_tiyin
       and not exists (
         select 1 from public.installment_plans p
          where p.subscription_id = s.id and p.cancelled_at is null
       )
  )
  select x.id, x.student_id, x.payer_id, x.amt
    from (select * from plan_subs union all select * from plain_subs) x
   where x.amt > 0;
$$;

comment on function public.subscription_overdue_unchecked(uuid) is
  'Просрочка по каждому абонементу центра (0100 Р2): с живым планом — greatest(base_paid − paid, 0) + Σ row_remaining строк overdue, не больше price − paid; без плана — price − paid. SECURITY INVOKER без грантов: только для definer-обёрток (student_subscriptions_overdue, payer_money_summary); случайный grant упрётся в RLS current_center(). Фильтр по плательщику — у вызывающего, NULL «всех» не означает.';

revoke all on function public.subscription_overdue_unchecked(uuid) from public, anon, authenticated, service_role, bot_worker;


-- 3. student_subscriptions_overdue — поверх помощника (Р2) --------------------------------------

create or replace function public.student_subscriptions_overdue()
  returns table (student_id uuid, overdue_tiyin integer, payer_id uuid)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
declare
  v_center uuid := public.current_center();
  v_payer  uuid;
begin
  if auth.uid() is null or v_center is null then
    return;
  end if;

  if public.can_payments() then
    return query
      select o.student_id,
             sum(o.overdue_tiyin)::integer,
             -- «Взять единственное значение», а не содержательный минимум:
             -- при разных плательщиках — NULL (0070, находка №6).
             case when count(distinct o.payer_id) = 1 then min(o.payer_id::text)::uuid else null end
        from public.subscription_overdue_unchecked(v_center) o
       group by o.student_id;
    return;
  end if;

  if coalesce(public.my_role(), '') = 'parent' then
    v_payer := public.my_payer_id();
    if v_payer is null then
      return;
    end if;

    return query
      select o.student_id,
             sum(o.overdue_tiyin)::integer,
             case when count(distinct o.payer_id) = 1 then min(o.payer_id::text)::uuid else null end
        from public.subscription_overdue_unchecked(v_center) o
       where o.payer_id = v_payer
       group by o.student_id;
    return;
  end if;
  -- teacher и прочие роли — пусто.
end;
$$;

comment on function public.student_subscriptions_overdue() is
  'Просроченная оплата абонемента, строка на ребёнка текущего центра (0070, формула — 0100 Р2 через subscription_overdue_unchecked): с живым планом рассрочки — недобор до графика плюс остатки просроченных строк (row_remaining), не больше фактического остатка; без плана — вся недоплата немедленно. НЕ то же самое, что export_debts().subscriptions_unpaid_tiyin (0058). payer_id — плательщик абонемента (subscriptions.payer_id); NULL, если просрочены абонементы разных плательщиков. owner/admin/registrar/finance — весь центр, parent — по subscriptions.payer_id = my_payer_id(), остальным пусто.';

revoke all on function public.student_subscriptions_overdue() from public, anon, service_role;
grant execute on function public.student_subscriptions_overdue() to authenticated;


-- 4. pay_installment — сумма к оплате обязательна (Р1, А5, А7) ---------------------------------

drop function if exists public.pay_installment(uuid, uuid, timestamptz, text);

create function public.pay_installment(
  p_installment_id        uuid,
  p_expected_amount_tiyin integer,
  p_source_id             uuid,
  p_paid_on               date default null,
  p_comment               text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center     uuid := public.current_center();
  v_inst       public.installments;
  v_sub        public.subscriptions;
  v_plan       public.installment_plans;
  v_cumulative integer;
  v_amount     integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_expected_amount_tiyin is null then
    raise exception 'Не передана сумма к оплате — обновите страницу' using errcode = '22023';
  end if;
  if p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;

  select * into v_inst from public.installments
   where id = p_installment_id and center_id = v_center;
  if not found then
    raise exception 'Платёж рассрочки не найден' using errcode = '42704';
  end if;

  -- Р12 из 0020: сначала абонемент, затем строка.
  select * into v_sub from public.subscriptions
   where id = v_inst.subscription_id
   for update;
  if v_sub.deleted_at is not null or v_sub.status = 'cancelled' then
    raise exception 'Абонемент отменён — платёж по рассрочке невозможен' using errcode = '22023';
  end if;

  select * into v_inst from public.installments where id = p_installment_id for update;
  select * into v_plan from public.installment_plans where id = v_inst.plan_id;
  if v_plan.cancelled_at is not null then
    raise exception 'Рассрочка отменена' using errcode = '22023';
  end if;

  select coalesce(sum(x.amount_tiyin), 0) into v_cumulative
    from public.installments x
   where x.plan_id = v_inst.plan_id and x.seq <= v_inst.seq;

  -- Накопительно: закрыть всё по эту строку включительно (= installments_view.due_through_tiyin).
  v_amount := v_plan.base_paid_tiyin + v_cumulative - v_sub.paid_tiyin;
  if v_amount <= 0 then
    raise exception 'Этот платёж рассрочки уже оплачен' using errcode = '22023';
  end if;
  if p_expected_amount_tiyin is distinct from v_amount then
    raise exception 'Сумма к оплате изменилась: сейчас %. Проверьте и повторите.', public.format_som(v_amount)
      using errcode = '23514';
  end if;

  -- Дата днём — проверка «не в будущем, не старше года» в record_payment_core (А7).
  return public.record_payment_core(
    v_inst.payer_id, v_amount, 'payment', v_inst.student_id, v_inst.subscription_id,
    p_source_id, null, p_comment, coalesce(p_paid_on, public.center_today(v_center)), false
  );
end;
$$;

comment on function public.pay_installment(uuid, integer, uuid, date, text) is
  'Платёж по строке рассрочки (0018/0026; 0100 Р1): проводит накопительно — всё по эту строку включительно (installments_view.due_through_tiyin). p_expected_amount_tiyin обязателен: ≠ сумме — 23514 со свежей суммой; уже оплачено — 22023. Источник обязателен, дата — днём центра (record_payment_core). can_payments.';

revoke all on function public.pay_installment(uuid, integer, uuid, date, text) from public, anon;
grant execute on function public.pay_installment(uuid, integer, uuid, date, text) to authenticated;


-- 5. installments_notify — в событии остаток строки (Р1, А10) -----------------------------------

create or replace function public.installments_notify()
  returns table (due_count integer, overdue_count integer)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_due     integer := 0;
  v_overdue integer := 0;
  r         record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    with today as (
      select c.id as center_id, public.center_today(c.id) as d from public.centers c
    )
    update public.installments i
       set due_notified_at = now()
      from today t,
           public.installments_view v
           join public.subscriptions s on s.id = v.subscription_id
           join public.students st on st.id = v.student_id
     where i.id = v.id
       and i.center_id = t.center_id and i.due_date = t.d
       and v.state = 'due'
       and i.due_notified_at is null
       and s.deleted_at is null and s.status <> 'cancelled'
       and st.deleted_at is null and st.status <> 'archived'
     -- 0100: остаток строки на момент уведомления, а не плановая сумма.
     returning i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id,
               i.seq, i.due_date, v.row_remaining_tiyin as amount_tiyin
  loop
    perform public.emit_event_unchecked('installment.due',
      jsonb_build_object(
        'center_id', r.center_id, 'installment_id', r.id,
        'subscription_id', r.subscription_id, 'student_id', r.student_id,
        'payer_id', r.payer_id, 'seq', r.seq, 'due_date', r.due_date,
        'amount_tiyin', r.amount_tiyin
      ),
      r.center_id);
    v_due := v_due + 1;
  end loop;

  for r in
    with today as (
      select c.id as center_id, public.center_today(c.id) as d from public.centers c
    )
    update public.installments i
       set overdue_notified_at = now()
      from today t,
           public.installments_view v
           join public.subscriptions s on s.id = v.subscription_id
           join public.students st on st.id = v.student_id
     where i.id = v.id
       and i.center_id = t.center_id
       -- Окно 30 дней (Р9 0020): первый запуск планировщика не даёт залп по истории.
       and i.due_date < t.d and i.due_date >= t.d - 30
       and v.state = 'overdue'
       and i.overdue_notified_at is null
       and s.deleted_at is null and s.status <> 'cancelled'
       and st.deleted_at is null and st.status <> 'archived'
     returning i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id,
               i.seq, i.due_date, v.row_remaining_tiyin as amount_tiyin
  loop
    perform public.emit_event_unchecked('installment.overdue',
      jsonb_build_object(
        'center_id', r.center_id, 'installment_id', r.id,
        'subscription_id', r.subscription_id, 'student_id', r.student_id,
        'payer_id', r.payer_id, 'seq', r.seq, 'due_date', r.due_date,
        'amount_tiyin', r.amount_tiyin
      ),
      r.center_id);
    v_overdue := v_overdue + 1;
  end loop;

  return query select v_due, v_overdue;
end;
$$;

-- Гранты — как в 0032: только bot_worker (А10).
revoke all on function public.installments_notify() from public, anon, authenticated, service_role;
grant execute on function public.installments_notify() to bot_worker;


-- 6. export_debts — долг за занятия с перерасходом (Р3) ----------------------------------------

create or replace function public.export_debts()
  returns table (
    student_name               text,
    student_status             text,
    payer_name                 text,
    payer_phone                text,
    lessons_debt_tiyin         integer,
    subscriptions_unpaid_tiyin integer
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_today  date;
  v_rows   integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  v_today := public.center_today(v_center);

  -- lessons_debt — «долг за занятия» с /app/debts: долг по отметкам без
  -- абонемента плюс перерасход (remaining счёта занятий, 0087/0089). До 0100
  -- брался student_debts() — с 0087 он без перерасхода, и ребёнок с одним
  -- перерасходом в CSV не попадал вовсе. subscriptions_unpaid — недоплата по
  -- живым абонементам: с рассрочкой или без неё.
  return query
    with lessons_debt as (
      select la.student_id, la.remaining_tiyin as debt_tiyin
        from public.lesson_debt_accounts_unchecked(v_center) la
    ),
    unpaid as (
      select s.student_id, sum(s.price_tiyin - s.paid_tiyin)::integer as unpaid_tiyin
        from public.subscriptions s
       where s.center_id = v_center
         and s.deleted_at is null
         and s.status <> 'cancelled'
         and s.paid_tiyin < s.price_tiyin
       group by s.student_id
    )
    select st.full_name,
           st.status,
           py.full_name,
           py.phone,
           coalesce(ld.debt_tiyin, 0),
           coalesce(u.unpaid_tiyin, 0)
      from public.students st
      left join lessons_debt ld on ld.student_id = st.id
      left join unpaid u        on u.student_id = st.id
      left join public.payers py on py.id = st.payer_id
     where st.center_id = v_center
       and st.deleted_at is null
       and (coalesce(ld.debt_tiyin, 0) > 0 or coalesce(u.unpaid_tiyin, 0) > 0)
     order by st.full_name, st.id;
  get diagnostics v_rows = row_count;

  perform public.emit_event('report.exported',
    jsonb_build_object('report', 'debts', 'from', v_today, 'to', v_today,
                       'rows', v_rows, 'by', auth.uid(), 'role', public.my_role()),
    v_center);
end;
$$;

comment on function public.export_debts() is
  'Долги на сегодня (0058; 0100 Р3): по занятиям — долг без абонемента плюс перерасход (как «долг за занятия» на /app/debts), и недоплата по абонементам (price − paid) — двумя колонками, без сложения (docs/Database.md). Контакт — текущий плательщик ребёнка. can_finance.';

revoke all on function public.export_debts() from public, anon, service_role;
grant execute on function public.export_debts() to authenticated;


-- 7. record_expense — проверка даты (Р4) -------------------------------------------------------

create or replace function public.record_expense(
  p_category_id uuid,
  p_amount_tiyin integer,
  p_kind        text default 'expense',
  p_source_id   uuid default null,
  p_paid_on     date default null,
  p_comment     text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_today   date;
  v_paid_on date;
  v_id      uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_today := public.center_today(v_center);
  v_paid_on := coalesce(p_paid_on, v_today);
  -- Те же границы, что у платежей (record_payment_core, 0087): опечатка в
  -- годе не должна уносить расход в будущее или в прошлый год.
  if v_paid_on > v_today then
    raise exception 'Дата расхода не может быть в будущем' using errcode = '22023';
  end if;
  if v_paid_on < v_today - interval '1 year' then
    raise exception 'Дата расхода старше года — проверьте год' using errcode = '22023';
  end if;

  insert into public.expenses (
    center_id, category_id, source_id, amount_tiyin, paid_at, kind, comment, created_by
  )
  values (
    v_center, p_category_id, p_source_id, p_amount_tiyin,
    (v_paid_on::timestamp) at time zone public.center_timezone(v_center),
    p_kind, p_comment, auth.uid()
  )
  returning id into v_id;

  perform public.emit_event('expense.recorded',
    jsonb_build_object(
      'center_id', v_center, 'expense_id', v_id, 'category_id', p_category_id,
      'amount_tiyin', p_amount_tiyin, 'kind', p_kind
    ),
    v_center
  );

  return v_id;
end;
$$;

revoke execute on function public.record_expense(uuid, integer, text, uuid, date, text) from public, anon, authenticated;
grant execute on function public.record_expense(uuid, integer, text, uuid, date, text) to authenticated;


-- 8. Деньги семьи на карточке плательщика (Р5) ------------------------------------------------

create or replace function public.payer_money_summary(p_payer_id uuid)
  returns table (
    student_id        uuid,
    lesson_debt_tiyin bigint,
    credit_tiyin      bigint,
    overdue_tiyin     bigint,
    unpaid_tiyin      bigint,
    next_due_date     date,
    next_due_tiyin    bigint
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
declare
  v_center uuid := public.current_center();
  v_mine   uuid;
begin
  -- Порядок проверок (А1): NULL — ничей, не «весь центр»; плательщик живой и
  -- этого центра — до любых сумм; родитель — только свой, сравнение позитивное.
  if auth.uid() is null or v_center is null or p_payer_id is null then
    return;
  end if;

  perform 1 from public.payers py
   where py.id = p_payer_id and py.center_id = v_center and py.deleted_at is null;
  if not found then
    return;
  end if;

  if not public.can_payments() then
    if coalesce(public.my_role(), '') <> 'parent' then
      return;
    end if;
    v_mine := public.my_payer_id();
    if v_mine is null or v_mine <> p_payer_id then
      return;
    end if;
  end if;

  return query
    with kids_lessons as (
      -- Долг за занятия (долг + перерасход) и аванс — детей, чей ТЕКУЩИЙ плательщик p.
      select la.student_id,
             la.remaining_tiyin::bigint as lesson_debt,
             la.credit_tiyin::bigint    as credit
        from public.lesson_debt_accounts_unchecked(v_center) la
        join public.students st on st.id = la.student_id
       where st.payer_id = p_payer_id and st.deleted_at is null
    ),
    overdue as (
      -- Просрочка — абонементов, КУПЛЕННЫХ p (0070), одна формула (0100 Р2).
      select o.student_id, sum(o.overdue_tiyin)::bigint as overdue
        from public.subscription_overdue_unchecked(v_center) o
       where o.payer_id = p_payer_id
       group by o.student_id
    ),
    unpaid as (
      -- Недоплата («сколько всего должны») — тех же абонементов, фильтры как в export_debts.
      select s.student_id, sum(s.price_tiyin - s.paid_tiyin)::bigint as unpaid
        from public.subscriptions s
        join public.students st on st.id = s.student_id and st.center_id = s.center_id
       where s.center_id = v_center
         and s.payer_id = p_payer_id
         and s.deleted_at is null
         and st.deleted_at is null
         and s.status <> 'cancelled'
         and s.paid_tiyin < s.price_tiyin
       group by s.student_id
    ),
    rows_due as (
      -- Неоплаченные строки живых планов абонементов p (как subscription_payment_summary, 0090).
      select iv.student_id, iv.due_date, iv.row_remaining_tiyin::bigint as amount
        from public.installments_view iv
        join public.subscriptions s on s.id = iv.subscription_id
        join public.students st on st.id = s.student_id and st.center_id = s.center_id
       where s.center_id = v_center
         and s.payer_id = p_payer_id
         and s.deleted_at is null
         and st.deleted_at is null
         and s.status <> 'cancelled'
         and iv.cancelled_at is null
         and iv.state in ('upcoming', 'due', 'overdue')
    ),
    next_kid as (
      select r.student_id, min(r.due_date) as d from rows_due r group by r.student_id
    ),
    next_kid_amt as (
      select n.student_id, n.d, sum(r.amount)::bigint as amt
        from next_kid n
        join rows_due r on r.student_id = n.student_id and r.due_date = n.d
       group by n.student_id, n.d
    ),
    ids as (
      select k.student_id from kids_lessons k where k.lesson_debt > 0 or k.credit > 0
      union select o.student_id from overdue o
      union select u.student_id from unpaid u
      union select n.student_id from next_kid n
    ),
    per_kid as (
      select i.student_id,
             coalesce(k.lesson_debt, 0)::bigint as lesson_debt,
             coalesce(k.credit, 0)::bigint      as credit,
             coalesce(o.overdue, 0)::bigint     as overdue,
             coalesce(u.unpaid, 0)::bigint      as unpaid,
             na.d                               as next_d,
             na.amt                             as next_amt
        from ids i
        left join kids_lessons k on k.student_id = i.student_id
        left join overdue o      on o.student_id = i.student_id
        left join unpaid u       on u.student_id = i.student_id
        left join next_kid_amt na on na.student_id = i.student_id
    ),
    family_next as (
      select min(r.due_date) as d from rows_due r
    )
    select pk.student_id, pk.lesson_debt, pk.credit, pk.overdue, pk.unpaid, pk.next_d, pk.next_amt
      from per_kid pk
    union all
    -- Итог семьи — всегда одна строка, даже из нулей (А6).
    select null::uuid,
           coalesce((select sum(pk.lesson_debt) from per_kid pk), 0)::bigint,
           coalesce((select sum(pk.credit) from per_kid pk), 0)::bigint,
           coalesce((select sum(pk.overdue) from per_kid pk), 0)::bigint,
           coalesce((select sum(pk.unpaid) from per_kid pk), 0)::bigint,
           (select fn.d from family_next fn),
           (select sum(r.amount) from rows_due r, family_next fn where r.due_date = fn.d)::bigint;
end;
$$;

comment on function public.payer_money_summary(uuid) is
  'Деньги семьи на карточке плательщика (0100 Р5): строка на ребёнка с ненулевыми суммами и строка итога (student_id IS NULL, всегда — даже из нулей). Долг за занятия (долг + перерасход) и аванс — детей, чей текущий плательщик p; просрочка (subscription_overdue_unchecked) и недоплата (price − paid) — абонементов, купленных p; ближайший платёж — минимальная дата неоплаченных строк живых планов и Σ их остатков. can_payments — любой живой плательщик центра; parent — только свой; NULL, чужой, удалённый — ноль строк.';

revoke all on function public.payer_money_summary(uuid) from public, anon;
grant execute on function public.payer_money_summary(uuid) to authenticated;


-- 9. Поступления за день в вебе (Р6) -----------------------------------------------------------

create or replace function public.payments_day_summary(p_day date)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  -- Р8: всем, кто принимает оплату (стойке — сдать кассу вечером), не только can_finance.
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_day is null then
    raise exception 'Укажите день' using errcode = '22023';
  end if;
  -- День центра, не UTC: с 00:00 до 06:00 по Бишкеку current_date ещё вчера (А11).
  if p_day > public.center_today(v_center) then
    raise exception 'День ещё не наступил' using errcode = '22023';
  end if;

  return public.center_payments_day(v_center, p_day);
end;
$$;

comment on function public.payments_day_summary(date) is
  'Поступления за день центра в вебе (0100 Р6) — то же число, что /cash в боте (center_payments_day, 0072): total_tiyin, ops, by_source; только payments, расходы не входят. can_payments (Р8: и стойке; бот /cash — can_finance); NULL и день позже center_today — 22023.';

revoke all on function public.payments_day_summary(date) from public, anon;
grant execute on function public.payments_day_summary(date) to authenticated;
