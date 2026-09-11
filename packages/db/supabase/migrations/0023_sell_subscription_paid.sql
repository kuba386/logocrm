-- =============================================================================
-- 0023_sell_subscription_paid.sql — продажа абонемента с оплатой и рассрочкой
-- одной транзакцией (этап 5, промт, блок UI: «Продать абонемент → сразу
-- форма оплаты»; чек-лист п.1)
--
-- Architect-ревью плана: 12 находок, учтены. Решения:
--
--   Р1. Обёртка над sell_subscription + record_payment +
--       create_installment_plan, существующие функции не меняются. Три RPC
--       из server action оставили бы абонемент без платежа при отказе
--       второго шага; здесь отказ любого шага откатывает всю продажу.
--       Расширить sell_subscription нельзя: create or replace с новыми
--       параметрами создаёт перегрузку, и PostgREST перестаёт выбирать
--       кандидата по ключам JSON.
--   Р2. Строки графика — в ответе (returns table), не предпросмотр из
--       браузера: 0020 сменила тип возврата create_installment_plan ровно
--       ради этого, обёртка их не глотает.
--   Р3. Двойной клик «Продать» — хранимый инвариант, не disabled на кнопке:
--       subscriptions.sale_key (частичный unique) + advisory-замок на ключ
--       внутри транзакции; повтор с тем же ключом — 22023, ни второго
--       абонемента, ни второго платежа.
--   Р4. Оплата > 0 без источника — отказ: платёж без source_id выпадает из
--       сверки кассы (cash_by_source, «источник не указан»). У record_payment
--       null остаётся — корректировкам и бэкфиллу он нужен.
--   Р5. Дата оплаты — день по поясу центра (p_paid_on date, полночь по
--       центру, как record_expense), не момент из браузера; будущее — отказ.
--       Замок месяца видит тот же месяц, что витрина.
--   Р6. p_expected_remaining_tiyin — не от гонки (её нет: остаток известен
--       в той же транзакции), а от расхождения браузерного и серверного
--       представления суммы: иначе отказ приходит как «платежей больше, чем
--       тыйынов» на форме продажи за 4 000.
--   Р7. p_installments = 0 — отказ; «без рассрочки» — только null.
--   Р8. Переплата при продаже — отказ 22023, но это проверка ввода, не
--       инвариант: record_payment по-прежнему принимает любую сумму
--       (overpaid в subscription_payment_summary). Записано в отчёт этапа.
--   Р9. Архивный ученик (students.status = 'archived') и архивный источник —
--       продажа проходит (sell_subscription смотрит только deleted_at,
--       record_payment — известное ограничение 0016). Закреплено тестом как
--       текущее поведение, чтобы будущая правка не изменила его молча.
--   Р10. Форма даёт только первую дату и шаг в месяцах — как у
--       create_installment_plan; массив дат — другая сигнатура плана, не
--       эта миграция.
-- =============================================================================


-- 1. subscriptions.sale_key — ключ идемпотентности продажи -----------------------

alter table public.subscriptions add column if not exists sale_key uuid;

comment on column public.subscriptions.sale_key is
  'Ключ идемпотентности продажи (sell_subscription_paid): форма генерирует uuid при открытии, повторная отправка с тем же ключом отбивается. null у абонементов, проданных через sell_subscription.';

-- Частичный: старые продажи и sell_subscription без ключа не конфликтуют.
create unique index if not exists subscriptions_sale_key_key
  on public.subscriptions (sale_key) where sale_key is not null;


-- 2. sell_subscription_paid --------------------------------------------------------

create or replace function public.sell_subscription_paid(
  p_type_id                  uuid,
  p_student_id               uuid,
  p_sale_key                 uuid,
  p_price_tiyin              integer  default null,
  p_starts_at                date     default null,
  -- Внесено сразу; null/0 — без платежа.
  p_paid_tiyin               integer  default null,
  p_source_id                uuid     default null,
  -- День оплаты по поясу центра; null — сегодня.
  p_paid_on                  date     default null,
  -- Число платежей рассрочки; null — без рассрочки, 0 — отказ.
  p_installments             integer  default null,
  p_first_due                date     default null,
  p_step_months              smallint default 1,
  -- Остаток, который видел администратор (цена − внесено).
  p_expected_remaining_tiyin integer  default null
)
  returns table (
    subscription_id uuid,
    payment_id      uuid,
    seq             smallint,
    due_date        date,
    amount_tiyin    integer
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_sub       public.subscriptions;
  v_id        uuid;
  v_payment   uuid;
  v_today     date;
  v_paid_on   date;
  v_paid_at   timestamptz;
  v_paid      integer := coalesce(p_paid_tiyin, 0);
  v_remaining integer;
begin
  if auth.uid() is null or coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_sale_key is null then
    raise exception 'sell_subscription_paid: не передан ключ продажи' using errcode = '22004';
  end if;
  if v_paid < 0 then
    raise exception 'Внесённая сумма не может быть отрицательной' using errcode = '22023';
  end if;
  if v_paid > 0 and p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;
  if p_installments is not null and p_installments < 1 then
    raise exception 'Число платежей рассрочки — от 1; без рассрочки поле не передаётся' using errcode = '22023';
  end if;

  v_today   := public.center_today(v_center);
  v_paid_on := coalesce(p_paid_on, v_today);
  if v_paid_on > v_today then
    raise exception 'Дата оплаты не может быть в будущем' using errcode = '22023';
  end if;

  -- Р3: двойной клик. Замок на ключ держит параллельную транзакцию до
  -- конца этой; проверка после замка видит её результат.
  perform pg_advisory_xact_lock(hashtextextended(p_sale_key::text, 0));
  if exists (select 1 from public.subscriptions s where s.sale_key = p_sale_key) then
    raise exception 'Эта продажа уже проведена — обновите страницу' using errcode = '22023';
  end if;

  -- Все проверки типа/ученика/центра — внутри (42704 на чужое).
  v_id := public.sell_subscription(p_type_id, p_student_id, p_price_tiyin, p_starts_at);

  update public.subscriptions s set sale_key = p_sale_key where s.id = v_id;
  select s.* into v_sub from public.subscriptions s where s.id = v_id;

  if v_paid > v_sub.price_tiyin then
    raise exception 'Оплата больше цены абонемента' using errcode = '22023';
  end if;

  v_remaining := v_sub.price_tiyin - v_paid;
  if p_expected_remaining_tiyin is not null and p_expected_remaining_tiyin <> v_remaining then
    raise exception 'Остаток изменился, пока готовили продажу: сейчас % тыйын. Проверьте суммы.', v_remaining
      using errcode = '23514';
  end if;

  if v_paid > 0 then
    -- Полночь дня оплаты по поясу центра — как record_expense (0016).
    v_paid_at := (v_paid_on::timestamp) at time zone public.center_timezone(v_center);
    v_payment := public.record_payment(
      v_sub.payer_id, v_paid, 'payment', p_student_id, v_id,
      p_source_id, v_paid_at, 'Оплата при продаже абонемента'
    );
    -- payments_recalc_paid — after-триггер, синхронно: paid_tiyin уже
    -- пересчитан, create_installment_plan ниже видит остаток.
  end if;

  if p_installments is not null then
    return query
      select v_id, v_payment, v.seq, v.due_date, v.amount_tiyin
        from public.create_installment_plan(v_id, p_installments, p_first_due, p_step_months, v_remaining) v
       order by v.seq;
  else
    return query select v_id, v_payment, null::smallint, null::date, null::integer;
  end if;
end;
$$;


-- Гранты -------------------------------------------------------------------------

revoke execute on function
  public.sell_subscription_paid(uuid, uuid, uuid, integer, date, integer, uuid, date, integer, date, smallint, integer)
  from public, anon, authenticated;

grant execute on function
  public.sell_subscription_paid(uuid, uuid, uuid, integer, date, integer, uuid, date, integer, date, smallint, integer)
  to authenticated;
