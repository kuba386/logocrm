-- =============================================================================
-- 0084_platform_prepay_discount.sql — скидка за предоплату тарифа платформы
--
-- Решение владельца платформы (1.10.2026): при оплате сразу от 6 месяцев —
-- скидка 10 %, от 12 месяцев — 20 % (срок и так ограничен 1..24).
--
-- Ревью плана — architect:
--   Р1. Сумму заявки пишет одна функция — submit_platform_payment (последнее
--       определение 0056); тело перенесено посимвольно, меняется только
--       формула: v_amount := platform_payment_amount(...) в insert и в
--       payload события. Схема не меняется, platform_payments по-прежнему
--       закрыта на запись. extend_subscription не трогаем: сумму
--       подтверждения вводит администратор платформы (форма /admin
--       подставляет claimed_amount_tiyin — значит, уже со скидкой).
--   Р2. Скидка — функция, а не данные в plans: claimed_amount — снимок, смена
--       порогов будущим релизом историю не перепишет; в данные — если
--       владелец захочет менять пороги без релиза.
--   Р3. Округление — до тыйына, половина вверх: (x·(100−p) + 50) / 100 в
--       bigint. Текущие цены дают точные суммы; случаи с половиной тыйына —
--       в общем наборе Vitest (packages/core/src/platform-payment.test.ts)
--       и tests/0084, одинаковые входы.
--   Р4. Хелперы strict (null → null, а не голая 23502 где-то ниже), вызовы с
--       public. при search_path = ''. Гранты: revoke у всех — функцию зовёт
--       только security definer submit_platform_payment, браузеру хватает
--       TS-зеркала (0007 по authenticated не меняется).
--   Р5. Открытые заявки до 0084 не пересчитываются: сумма — снимок (0051
--       Р11). Центр, подавший 6+ месяцев до выката, может отозвать и подать
--       заново.
-- =============================================================================


-- 1. Скидка и сумма ----------------------------------------------------------------------------------------

create or replace function public.platform_prepay_discount_pct(p_months integer)
  returns integer
  language sql
  immutable
  strict
  set search_path = ''
as $$
  select case when p_months >= 12 then 20 when p_months >= 6 then 10 else 0 end;
$$;

comment on function public.platform_prepay_discount_pct(integer) is
  'Скидка за предоплату тарифа платформы, % (0084): от 6 месяцев — 10, от 12 — 20. TS-зеркало — prepayDiscountPercent (packages/core).';

revoke all on function public.platform_prepay_discount_pct(integer) from public, anon, authenticated, service_role;

create or replace function public.platform_payment_amount(p_price_tiyin integer, p_months integer)
  returns integer
  language sql
  immutable
  strict
  set search_path = ''
as $$
  select ((p_price_tiyin::bigint * p_months * (100 - public.platform_prepay_discount_pct(p_months)) + 50) / 100)::integer;
$$;

comment on function public.platform_payment_amount(integer, integer) is
  'Сумма заявки на оплату тарифа в тыйынах (0084): цена × месяцы со скидкой за предоплату, округление до тыйына, половина вверх. TS-зеркало — platformPaymentAmountTiyin (packages/core).';

revoke all on function public.platform_payment_amount(integer, integer) from public, anon, authenticated, service_role;


-- 2. submit_platform_payment (0056) — сумма со скидкой --------------------------------------------------

create or replace function public.submit_platform_payment(
  p_plan   text,
  p_months integer,
  p_source text,
  p_note   text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_plan   public.plans;
  v_amount integer;
  v_id     uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if public.center_write_state(v_center) = 'deleted' then
    raise exception 'Центр помечен на удаление — оплата недоступна. Отмените удаление в настройках тарифа'
      using errcode = 'PT402';
  end if;

  select * into v_plan from public.plans where code = p_plan;
  if not found or v_plan.code = 'trial' or not v_plan.is_public then
    raise exception 'Выберите платный тариф' using errcode = '22023';
  end if;
  if p_months is null or p_months < 1 or p_months > 24 then
    raise exception 'Срок оплаты — от 1 до 24 месяцев' using errcode = '22023';
  end if;
  if p_source not in ('mbank', 'elcart', 'cash', 'other') then
    raise exception 'Укажите способ оплаты' using errcode = '22023';
  end if;

  -- Р11: сумма — снимок прайса, посчитанный здесь, а не в браузере;
  -- со скидкой за предоплату (0084).
  v_amount := public.platform_payment_amount(v_plan.price_tiyin, p_months);

  insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source, note, submitted_by)
  values (v_center, v_plan.code, p_months, v_amount, p_source, nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  perform public.emit_event(
    'platform.payment_submitted',
    jsonb_build_object(
      'center_id',    v_center,
      'payment_id',   v_id,
      'plan',         v_plan.code,
      'months',       p_months,
      'amount_tiyin', v_amount,
      'source',       p_source
    ),
    v_center
  );

  return v_id;
end;
$$;

comment on function public.submit_platform_payment(text, integer, text, text) is
  'Заявка «я оплатил» от owner/admin центра (0051). Сумма = цена тарифа × месяцы из plans со скидкой за предоплату (platform_payment_amount, 0084; Р11 0051). Работает и в режиме только чтения: platform_payments в списке исключений guard. Вторая открытая заявка — 23505 platform_payments_one_open_per_center. Удалённый центр — PT402, платить некуда (0056 Р14).';

revoke all on function public.submit_platform_payment(text, integer, text, text) from public, anon, service_role;
grant execute on function public.submit_platform_payment(text, integer, text, text) to authenticated;
