-- =============================================================================
-- 0054_period_subscription_refund.sql — возврат за period-абонемент
-- (docs/Backlog.md, «Отмену абонемента на срок нечем сделать», 19.09.2026)
--
-- Проблема: refund_calc считал только lessons_left × lesson_price_tiyin.
-- У kind='period' lessons_total всегда null → lessons_left null →
-- refund_calc всегда 0 → кнопка «Вернуть» на карточке ребёнка
-- (refundTiyin > 0) не появлялась никогда, оплаченный month-абонемент
-- нельзя было ни закрыть, ни вернуть по нему деньги.
--
-- Решения владельца (не пересматриваются здесь):
--   Р0а. Возврат за period — пропорционально оставшимся дням, не больше
--        внесённого (least(refund_calc, paid_tiyin) в refund_subscription,
--        0030, без изменений).
--   Р0б. «Отменить» доступно всегда, даже при возврате 0. «Вернуть деньги»
--        (поле источника оплаты) — только когда есть что возвращать.
--        refund_subscription (0030) это уже умеет: source обязателен, только
--        если v_refund > 0 (Р2, 0030). Проблема была чисто в том, что вся
--        RefundForm пряталась за refundTiyin > 0 на карточке — правится
--        ниже без новой RPC.
--
-- Architect-ревью плана — 9 находок, все учтены:
--
--   Р1. Открытая (незакрытая) заморозка не двигает ends_at —
--       subscriptions_apply_freeze_shift (0015) пересчитывает ends_at только
--       по ЗАКРЫТЫМ периодам (subscription_freeze_days_unchecked суммирует
--       upper(period)-lower(period), а upper() открытого диапазона — NULL,
--       sum() его пропускает). Без поправки семья, ушедшая ПРЯМО из
--       заморозки — типовой случай, — получила бы 0: ends_at ещё старый,
--       "остаток" ушёл в минус, greatest(0,...) обнулил. Поправка: дни
--       открытой заморозки (center_today - lower(period), если есть
--       незакрытая) прибавляются к остатку явным подзапросом.
--   Р2. left join subscription_types из security invoker читал бы каталог
--       под RLS вызывающего: родитель (subscriptions_parent_read пускает) и
--       subscription_types закрыта tenant_admin/apply_role_rls — join пустой,
--       tiyin считается от ends_at-starts_at (с заморозкой внутри, Р3) вместо
--       period_days типа — молчаливый второй источник правды о деньгах
--       (та же болезнь, что 0015 уже чинила для subscription_freeze_days).
--       Решение: refund_calc переезжает на definer + explicit-гейт
--       (subscription_visible_to_caller), тот же приём, что
--       subscription_freeze_days/subscription_freeze_days_unchecked (0015).
--       _unchecked-часть без грантов, публичная обёртка — с проверкой
--       видимости, NULL для невидимого/несуществующего (регрессия
--       0010_stage4_hardening.test.sql:104 не ломается).
--   Р3. Знаменатель — total_days = subscription_types.period_days (заморожен
--       после первой продажи, subscription_types_guard_sold_fields, 0015), а
--       не ends_at - starts_at: та растёт с каждой ЗАКРЫТОЙ заморозкой и
--       занижала бы долю на дни, которые семья не обязана оплачивать.
--   Р4 (было П3 в вопросе, снято архитектором). Дискриминатор ветки —
--       ends_at is not null, не kind = 'period' буквально: constraint
--       "kind <> 'lessons' or period_days is null" (0015:122) гарантирует,
--       что lessons НИКОГДА не получает ends_at, а sell_subscription ставит
--       ends_at по period_days типа независимо от kind (0008:419-421) — то
--       есть "unlimited на месяц" (unlimited + period_days) тоже календарный
--       продукт и справедливо получает тот же пропорциональный возврат, что
--       и period. Отдельного решения владельца не требует: возврат
--       определяется тем, что продано (время до даты или пакет занятий), а
--       не ярлыком kind.
--   Р5. После отмены (status='cancelled') refund_calc для period продолжал
--       бы таять по дням дальше (в отличие от lessons, где lessons_written_off
--       держит lessons_left=0 сам). Явный short-circuit: status='cancelled'
--       → 0, одной веткой на все kind (для lessons/unlimited она просто
--       не нужна, но безопасна).
--   Р6. price_tiyin * days в int4 переполняется на реалистичных цифрах
--       (60 000 сом × 365 дней > int4). Умножение в bigint, ::integer —
--       на выходе.
--   Р7. TransferForm сидел в одном блоке с RefundForm под тем же условием
--       (refundTiyin > 0) — снятие условия открыло бы «Перенести остаток» и
--       на period/unlimited/исчерпанном lessons, где transfer_remaining
--       откажет «переносить нечего». Условия разделены на UI-стороне.
--   Р8. Хвост рассрочки на отменённом period — ПРОВЕРЕНО, не требует правки:
--       subscriptions_cancel_installments (0018/0020) — уже AFTER UPDATE OF
--       status TRIGGER на subscriptions, гасит installment_plans любым путём
--       смены status на 'cancelled', включая update внутри refund_subscription
--       (0030:264-267). Регрессия покрыта тестом ниже, а не новым кодом.
--   Р9. Событие subscription.refunded: для period amount_tiyin/refund_tiyin —
--       деньги за срок, lessons=0 — буквально верно (ни одного занятия не
--       списывалось), новое поле не нужно; contracts не меняются.
--
-- Гонка "предпросмотр -> запись" (p_expected_tiyin) для period случается
-- чаще, чем у lessons — сумма "протухает" каждый день и на любом закрытии
-- заморозки, не только по действию пользователя. Существующий текст 23514
-- ("остаток изменился, пока считали возврат: сейчас % тыйын") и подсказка в
-- форме (refundHint: "пересчитайте и повторите") уже покрывают это без
-- тупика — отдельный путь ошибки не заводится (Architect, п.5 плана).
--
-- TS-зеркало (packages/core/src/subscription.ts::refundAmount) НЕ трогается:
-- у него нет потребителя в apps/web (карточка показывает готовое число с
-- сервера), а второй источник правды без потребителя — ровно то, от чего
-- предостерегает комментарий перед canDeduct в том же файле. Если появится
-- клиентский предпросмотр — тогда и переносить формулу.
-- =============================================================================


-- 1. refund_calc_unchecked — арифметика без проверки видимости ------------------

create or replace function public.refund_calc_unchecked(p_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  with sub as (
    select
      s.id, s.center_id, s.status, s.lessons_total, s.lesson_price_tiyin,
      s.price_tiyin, s.starts_at, s.ends_at,
      coalesce(t.period_days, greatest(s.ends_at - s.starts_at, 1)) as total_days,
      -- Незакрытая заморозка не сдвинула ends_at (Р1) — её дни, ещё не
      -- отражённые там, добавляются к остатку явно. greatest(0,...): если
      -- заморозка ещё не началась (lower(period) в будущем), это 0, не минус.
      coalesce((
        select greatest(0, public.center_today(s.center_id) - lower(f.period))
          from public.subscription_freezes f
         where f.subscription_id = s.id
           and upper_inf(f.period)
         limit 1
      ), 0) as open_freeze_days
    from public.subscriptions s
    left join public.subscription_types t on t.id = s.type_id
    where s.id = p_id
  )
  select case
    -- Р5: после отмены возврат не течёт дальше ни для одного kind.
    when sub.status = 'cancelled' then 0
    -- lessons/unlimited-без-срока (ends_at null) — как раньше: стоимость
    -- неотработанных занятий. lessons_total is not null покрывает lessons;
    -- ends_at is null отсекает unlimited без периода (см. Р4 — unlimited
    -- С периодом ниже, в else, наравне с period).
    when sub.lessons_total is not null or sub.ends_at is null then
      coalesce(public.subscription_lessons_left(p_id), 0) * coalesce(sub.lesson_price_tiyin, 0)
    -- period (или unlimited с ends_at, Р4) — пропорционально дням, что
    -- останутся до ends_at от сегодня центра, плюс дни ЕЩЁ не закрытой
    -- заморозки (Р1), от знаменателя period_days типа (Р3), не ends_at-
    -- starts_at. bigint — иначе int4 переполняется на реалистичных цифрах
    -- (Р6): 60 000 сом * 365 дней = 21 900 000 000 > 2^31.
    else
      (
        sub.price_tiyin::bigint
        * greatest(0, least(
            (sub.ends_at - public.center_today(sub.center_id)) + sub.open_freeze_days,
            sub.total_days
          ))
        / sub.total_days
      )::integer
  end
  from sub;
$$;

revoke all on function public.refund_calc_unchecked(uuid) from public, anon, authenticated;


-- 2. refund_calc — публичная обёртка с проверкой видимости (Р2) ----------------

-- Тот же приём, что subscription_freeze_days/subscription_freeze_days_unchecked
-- (0015): invoker+RLS заменяется на definer+explicit-гейт, потому что
-- арифметика внутри должна читать subscription_types и subscription_freezes,
-- закрытые для part родителя/registrar/finance напрямую, а не только
-- subscriptions. subscription_visible_to_caller (0026) — тот же критерий
-- видимости, что уже использует subscription_summary для этого же
-- subscription_id, так что калькулятор через RPC и через сводку больше не
-- смогут разойтись по двум разным механизмам.
create or replace function public.refund_calc(p_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select case when not public.subscription_visible_to_caller(p_id) then null
    else public.refund_calc_unchecked(p_id)
  end;
$$;

-- security invoker -> definer меняет модель доступа только у единственного
-- прямого потребителя грантом — вызовов из refund_subscription/
-- subscription_summary (обе definer) это не касается. Явные гранты заново
-- (create or replace ACL не трогает, но подтверждать правило дешевле, чем
-- полагаться на "и так было" — 0030 Р9).
revoke all on function public.refund_calc(uuid) from public, anon;
grant execute on function public.refund_calc(uuid) to authenticated;
