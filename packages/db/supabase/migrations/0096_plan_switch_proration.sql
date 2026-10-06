-- =============================================================================
-- 0096_plan_switch_proration.sql — пересчёт остатка при смене тарифа
--
-- Решение владельца 6.10.2026. Раньше при смене тарифа посреди оплаченного
-- срока оставшиеся дни старого тарифа просто переходили на новый: повышение
-- Studio → Center давало дни Center по цене Studio, понижение — центр терял
-- деньги.
--
-- Решения:
--   Р1. При подтверждении оплаты другого платного тарифа, пока старый
--       оплачен (subscription_until > сейчас), оставшиеся дни старого
--       пересчитываются в дни нового по цене: дни × цена старого / цена
--       нового, округление до дня. Новый срок = сегодня + пересчитанные дни
--       + оплаченные месяцы. Тот же тариф, trial (Р14 из 0051 — остаток trial
--       не сгорает) и просроченный центр — как раньше.
--   Р2. Дни остатка — тот же счёт, что days_left в center_limits (даты в
--       поясе центра), чтобы форма и подтверждение говорили одно и то же.
--   Р3. Счёт — одна функция plan_switch_days; TS-зеркало planSwitchDays
--       (packages/core) только для подсказки в форме, общий набор случаев в
--       Vitest и pgTAP.
--   Р4. Понижение ниже текущего наполнения по-прежнему разрешено (0049):
--       центр правит и архивирует, но не растёт. Форма предупреждает заранее.
-- =============================================================================


-- 1. Пересчёт дней (Р1, Р3) -----------------------------------------------------------------------

create or replace function public.plan_switch_days(p_remaining_days integer, p_old_price integer, p_new_price integer)
  returns integer
  language sql
  immutable
  set search_path = ''
as $$
  select case
    when coalesce(p_remaining_days, 0) <= 0 then 0
    when coalesce(p_old_price, 0) <= 0 or coalesce(p_new_price, 0) <= 0 then p_remaining_days
    else round(p_remaining_days::numeric * p_old_price / p_new_price)::integer
  end;
$$;
comment on function public.plan_switch_days(integer, integer, integer) is
  'Оставшиеся оплаченные дни старого тарифа в днях нового (0096): дни × цена старого / цена нового, округление до дня. TS-зеркало — planSwitchDays (packages/core).';

revoke all on function public.plan_switch_days(integer, integer, integer) from public, anon, authenticated, service_role;


-- 2. extend_subscription — тело 0051 плюс Р1 ------------------------------------------------------

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
  v_base   timestamptz;
  v_until  timestamptz;
  v_old    integer;
  v_new    integer;
  v_left   integer;
  v_days   integer;
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

  -- Р14: остаток trial не сгорает; просроченный — от сегодня.
  v_base := case
    when v_c.plan = 'trial' then greatest(now(), coalesce(v_c.trial_ends_at, now()))
    else greatest(now(), coalesce(v_c.subscription_until, now()))
  end;

  -- 0096 Р1: смена платного тарифа посреди срока — оставшиеся дни старого
  -- пересчитываются в дни нового по цене (повышение — срок короче, понижение —
  -- длиннее). Тот же счёт дней, что days_left в center_limits (пояс центра).
  if v_c.plan <> 'trial' and v_c.plan <> p_plan and v_c.subscription_until > now() then
    select p.price_tiyin into v_old from public.plans p where p.code = v_c.plan;
    select p.price_tiyin into v_new from public.plans p where p.code = p_plan;
    v_left := greatest((v_c.subscription_until at time zone public.center_timezone(v_center))::date
                       - public.center_today(v_center), 0);
    v_days := public.plan_switch_days(v_left, v_old, v_new);
    v_base := now() + make_interval(days => v_days);
  end if;
  v_until := v_base + make_interval(months => p_months);

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
      'converted_days', v_days
    ),
    v_center
  );

  return jsonb_build_object('center_id', v_center, 'plan', p_plan, 'subscription_until', v_until);
end;
$$;

comment on function public.extend_subscription(uuid, text, integer, integer, boolean) is
  'Подтверждение оплаты тарифа платформой (0051; 0096 — при смене платного тарифа посреди срока остаток пересчитывается по цене). Тариф и срок одним update.';

revoke all on function public.extend_subscription(uuid, text, integer, integer, boolean) from public, anon, service_role;
grant execute on function public.extend_subscription(uuid, text, integer, integer, boolean) to authenticated;
