-- =============================================================================
-- 0096_plan_switch_proration.sql — пересчёт остатка при смене тарифа
--
-- Решения владельца 6.10.2026. Раньше при смене тарифа посреди оплаченного
-- срока оставшиеся дни старого тарифа просто переходили на новый: повышение
-- Studio → Center давало дни Center по цене Studio, понижение — центр терял
-- деньги.
--
-- Решения:
--   Р1. При подтверждении оплаты другого платного тарифа, пока старый
--       оплачен (subscription_until > сейчас), оставшиеся дни старого
--       пересчитываются в дни нового: дни × цена месяца старого / цена месяца
--       нового, до дня. Новый срок = сегодня + пересчитанные дни + оплаченные
--       месяцы. Тот же тариф, trial (0051 Р14) и просроченный центр — как
--       раньше.
--   Р2. Цена — фактически уплаченная (решение владельца): у старого тарифа —
--       последняя подтверждённая оплата этого тарифа (сумма / месяцы, со
--       скидкой 0084), если её нет — прайс; у нового — сумма этой оплаты /
--       месяцы. Скидка за долгий срок не переезжает на другой тариф.
--   Р3. Потолок (решение владельца): при смене тарифа новый срок — не дальше
--       24 месяцев от подтверждения (максимум оплаты). Излишек в днях и
--       ориентировочная сумма к возврату по цене дня нового тарифа уходят в
--       событие и предпросмотр /admin — возврат платформа делает вручную.
--   Р4. Остаток бесплатного тарифа (цена 0) не переносится (решение
--       владельца) — сегодня такой только trial, он идёт своей веткой.
--   Р5. Дни остатка — тот же счёт, что days_left в center_limits (даты в
--       поясе центра).
--   Р6. Расчёт — одна функция platform_switch_calc: её зовут и
--       extend_subscription, и platform_payment_preview (/admin видит итог до
--       подтверждения — исправить подтверждение нечем, ADR-011). TS-зеркало
--       planSwitchDays — только подсказка центру, общий набор случаев.
--   Р7. Понижение ниже текущего наполнения по-прежнему разрешено (0049):
--       центр правит и архивирует, но не растёт. Форма предупреждает заранее.
-- =============================================================================


-- 1. Пересчёт дней (Р1, Р4) -----------------------------------------------------------------------

create or replace function public.plan_switch_days(p_remaining_days integer, p_old_price integer, p_new_price integer)
  returns integer
  language sql
  immutable
  set search_path = ''
as $$
  select case
    when coalesce(p_remaining_days, 0) <= 0 then 0
    when coalesce(p_old_price, 0) <= 0 then 0
    when coalesce(p_new_price, 0) <= 0 then p_remaining_days
    else round(p_remaining_days::numeric * p_old_price / p_new_price)::integer
  end;
$$;
comment on function public.plan_switch_days(integer, integer, integer) is
  'Оставшиеся оплаченные дни старого тарифа в днях нового (0096): дни × цена месяца старого / нового, округление до дня; бесплатный старый — 0. TS-зеркало — planSwitchDays (packages/core).';

revoke all on function public.plan_switch_days(integer, integer, integer) from public, anon, authenticated, service_role;


-- 2. Расчёт нового срока (Р1–Р6) ------------------------------------------------------------------

create or replace function public.platform_switch_calc(
  p_center_id    uuid,
  p_plan         text,
  p_months       integer,
  p_amount_tiyin integer
)
  returns table (
    switching       boolean,
    remaining_days  integer,
    old_month_tiyin integer,
    new_month_tiyin integer,
    converted_days  integer,
    new_until       timestamptz,
    excess_days     integer,
    excess_tiyin    integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_c      public.centers;
  v_base   timestamptz;
  v_until  timestamptz;
  v_cap    timestamptz;
  v_old    integer;
  v_new    integer;
  v_left   integer;
  v_days   integer;
  v_excess integer := 0;
begin
  select * into v_c from public.centers c where c.id = p_center_id;

  v_base := case
    when v_c.plan = 'trial' then greatest(now(), coalesce(v_c.trial_ends_at, now()))
    else greatest(now(), coalesce(v_c.subscription_until, now()))
  end;

  if v_c.plan <> 'trial' and v_c.plan <> p_plan and v_c.subscription_until > now() then
    -- Р2: цена месяца — уплаченная.
    select (pp.amount_tiyin / pp.months) into v_old
      from public.platform_payments pp
     where pp.center_id = p_center_id and pp.confirmed_at is not null and pp.plan = v_c.plan
       and pp.months > 0
     order by pp.confirmed_at desc
     limit 1;
    if v_old is null then
      select p.price_tiyin into v_old from public.plans p where p.code = v_c.plan;
    end if;
    v_new := case when coalesce(p_months, 0) > 0 then p_amount_tiyin / p_months end;
    -- Р5: тот же счёт, что days_left в center_limits.
    v_left := greatest((v_c.subscription_until at time zone public.center_timezone(p_center_id))::date
                       - public.center_today(p_center_id), 0);
    v_days := public.plan_switch_days(v_left, v_old, v_new);
    v_base := now() + make_interval(days => v_days);
    v_until := v_base + make_interval(months => p_months);

    -- Р3: потолок 24 месяца.
    v_cap := now() + interval '24 months';
    if v_until > v_cap then
      v_excess := ceil(extract(epoch from (v_until - v_cap)) / 86400)::integer;
      v_until := v_cap;
    end if;

    return query select true, v_left, v_old, v_new, v_days, v_until, v_excess,
      case when coalesce(v_new, 0) > 0 then round(v_excess::numeric * v_new / 30)::integer else 0 end;
    return;
  end if;

  return query select false, null::integer, null::integer, null::integer, null::integer,
    v_base + make_interval(months => p_months), 0, 0;
end;
$$;
comment on function public.platform_switch_calc(uuid, text, integer, integer) is
  'Новый срок подписки центра при подтверждении оплаты (0096): тот же тариф/trial/просрочка — как 0051 Р14; смена платного — пересчёт остатка по уплаченной цене, потолок 24 месяца, излишек в днях и тыйынах. Один расчёт для extend_subscription и platform_payment_preview. Без проверки сессии; грантов нет.';

revoke all on function public.platform_switch_calc(uuid, text, integer, integer) from public, anon, authenticated, service_role;


-- 3. extend_subscription — тело 0051 плюс Р6 ------------------------------------------------------

create or replace function public.extend_subscription(
  p_payment_id       uuid,
  p_plan             text,
  p_months           integer,
  p_amount_tiyin     integer,
  p_receipt_received boolean default false
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid;
  v_c      public.centers;
  v_until  timestamptz;
  v_calc   record;
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р5: те же правила стоят констрейнтами на колонках; здесь — русский текст.
  if not exists (select 1 from public.plans where code = p_plan and code <> 'trial') then
    raise exception 'Выберите платный тариф' using errcode = '22023';
  end if;
  if p_months is null or p_months < 1 or p_months > 24 then
    raise exception 'Срок продления — от 1 до 24 месяцев' using errcode = '22023';
  end if;
  if p_amount_tiyin is null or p_amount_tiyin <= 0 then
    raise exception 'Сумма должна быть больше нуля' using errcode = '22023';
  end if;

  -- Идемпотентность: подтверждается только открытая заявка, одним update.
  update public.platform_payments
     set confirmed_at = now(), confirmed_by = auth.uid(),
         plan = p_plan, months = p_months, amount_tiyin = p_amount_tiyin,
         receipt_received = coalesce(p_receipt_received, false)
   where id = p_payment_id
     and confirmed_at is null and rejected_at is null and withdrawn_at is null
  returning center_id into v_center;

  if v_center is null then
    if exists (select 1 from public.platform_payments p where p.id = p_payment_id) then
      raise exception 'Заявка уже закрыта' using errcode = '22023';
    end if;
    raise exception 'Заявка не найдена' using errcode = '42704';
  end if;

  select * into v_c from public.centers where id = v_center and deleted_at is null for update;
  if not found then
    raise exception 'Центр не найден или закрыт' using errcode = '42704';
  end if;

  -- Р14 (0051): остаток trial не сгорает; просроченный — от сегодня; живой
  -- того же тарифа — от текущего срока. 0096: смена платного тарифа —
  -- пересчёт остатка по уплаченной цене и потолок 24 месяца. Один расчёт с
  -- предпросмотром /admin — platform_switch_calc.
  select * into v_calc from public.platform_switch_calc(v_center, p_plan, p_months, p_amount_tiyin);
  v_until := v_calc.new_until;

  -- ADR-011: план и срок одним update — между ними центр читал бы.
  -- Понижение тарифа ниже текущего наполнения разрешено: центр остаётся
  -- выше лимита, правит и архивирует, но не растёт (BUSINESS_RULES, 0049).
  -- Коррекции ошибочного подтверждения в 8a нет — решение в ADR-011.
  update public.centers
     set plan = p_plan, subscription_until = v_until
   where id = v_center;

  perform public.emit_event_platform(
    'subscription.extended',
    jsonb_build_object(
      'center_id',  v_center,
      'payment_id', p_payment_id,
      'plan',       p_plan,
      'months',     p_months,
      'until',      v_until,
      'previous_until', v_c.subscription_until,
      'converted_days', v_calc.converted_days,
      'excess_days',    v_calc.excess_days,
      'excess_tiyin',   v_calc.excess_tiyin
    ),
    v_center
  );

  return jsonb_build_object('center_id', v_center, 'plan', p_plan, 'subscription_until', v_until);
end;
$$;

comment on function public.extend_subscription(uuid, text, integer, integer, boolean) is
  'Подтверждение оплаты тарифа платформой (0051): только is_platform_admin; подтверждается только открытая заявка (повтор по тому же payment_id — 22023, centers не тронуты); тариф и срок одним update. Срок — platform_switch_calc (0096): тот же тариф — от greatest(сейчас, текущий срок) (Р14), смена платного — пересчёт остатка по уплаченной цене, потолок 24 месяца.';

revoke all on function public.extend_subscription(uuid, text, integer, integer, boolean) from public, anon, service_role;
grant execute on function public.extend_subscription(uuid, text, integer, integer, boolean) to authenticated;


-- 4. Предпросмотр для /admin (Р6) -----------------------------------------------------------------

create or replace function public.platform_payment_preview(
  p_payment_id   uuid,
  p_plan         text default null,
  p_months       integer default null,
  p_amount_tiyin integer default null
)
  returns table (
    current_plan    text,
    current_until   timestamptz,
    switching       boolean,
    remaining_days  integer,
    converted_days  integer,
    new_until       timestamptz,
    excess_days     integer,
    excess_tiyin    integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_pp public.platform_payments;
  v_c  public.centers;
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  select * into v_pp from public.platform_payments p where p.id = p_payment_id;
  if not found then
    raise exception 'Заявка не найдена' using errcode = '42704';
  end if;
  select * into v_c from public.centers c where c.id = v_pp.center_id;

  return query
    select v_c.plan, v_c.subscription_until, x.switching, x.remaining_days, x.converted_days,
           x.new_until, x.excess_days, x.excess_tiyin
      from public.platform_switch_calc(
             v_pp.center_id,
             coalesce(p_plan, v_pp.claimed_plan),
             coalesce(p_months, v_pp.claimed_months),
             coalesce(p_amount_tiyin, v_pp.claimed_amount_tiyin)) x;
end;
$$;
comment on function public.platform_payment_preview(uuid, text, integer, integer) is
  'Что сделает подтверждение заявки (0096 Р6): текущий и новый срок, пересчёт остатка, излишек сверх 24 месяцев. Только is_platform_admin; по умолчанию — заявленные тариф, месяцы и сумма.';

revoke all on function public.platform_payment_preview(uuid, text, integer, integer) from public, anon;
grant execute on function public.platform_payment_preview(uuid, text, integer, integer) to authenticated;
