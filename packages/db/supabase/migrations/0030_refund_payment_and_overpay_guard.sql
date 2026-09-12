-- =============================================================================
-- 0030_refund_payment_and_overpay_guard.sql — возврат платёжной строкой,
-- переплата как инвариант («Доработка» п.2, часть (б); docs/Roadmap/
-- stages.md:352-356 — обе формулировки уже в спеке, не решение с нуля)
--
-- Architect-ревью плана 0030 (после мержа 0026-0029) — решения:
--
--   Р1. Деньги возврата ≠ refund_calc. refund_calc считает стоимость
--       НЕОТРАБОТАННЫХ занятий (lessons_left × lesson_price) — она и
--       раньше была единственным числом функции, используется как есть
--       для p_expected_tiyin (сверка «остаток не изменился», текст и
--       23514 — без изменений) и для события subscription.refunded. Но
--       столько денег могло и не быть внесено: по частично оплаченному
--       абонементу (продажа 4 000 / оплата 2 000) refund_calc даст 3 000
--       неотработанных, а вернуть можно не больше 2 000 — иначе
--       отрицательный платёж роняет subscriptions_paid_not_negative без
--       текста, и возврат по главному сценарию этапа станет недоступен.
--       Возвращаемая сумма — least(refund_calc, paid_tiyin).
--   Р2. Платёж — через record_payment(kind='refund'), а не прямой insert:
--       тот же путь, что и у всех остальных денег (paid_tiyin
--       пересчитывается тем же триггером, событие payment.refunded —
--       тем же RPC, схема в contracts не меняется). source обязателен,
--       только если сумма возврата больше нуля — как у продажи (0023):
--       абонемент без единого платежа возвращать нечего, источник не
--       нужен.
--   Р3. Повторный возврат — не if в функции, а частичный unique
--       (payments (subscription_id) where kind = 'refund' and
--       subscription_id is not null): понятный текст даёт другая проверка
--       ниже (Р4, status = 'cancelled' — повторный возврат возможен только
--       на уже отменённом абонементе), а гарантия — в индексе, переживает
--       любой будущий обход через прямой RPC.
--   Р4. Абонемент уже отменён — отдельная явная проверка status до
--       расчёта (раньше функция молча перезаписывала status='cancelled'
--       и list ещё раз списывала lessons_written_off).
--   Р5. Замок — одной инструкцией select … for update (не perform +
--       отдельный select): порядок subscriptions → payments, тот же, что
--       у pay_installment/sell_subscription_paid — записано ниже как
--       правило.
--   Р6. Переплата — инвариант только для kind = 'payment' с
--       subscription_id, НЕ для 'correction': это разошлось бы со
--       spec — «переплата — только correction с явным комментарием»
--       (stages.md) — correction сознательно остаётся путём, которым
--       переплату проводят намеренно. Запрещать её тоже значило бы
--       убрать единственный санкционированный путь записи переплаты.
--       Механизм триггера — см. Р13-Р14 (первая реализация, описанная
--       здесь на плане, оказалась неполной и переписана вторым раундом
--       ревью).
--   Р7. 0018-тест «переплата мимо плана» (record_payment kind='payment'
--       на уже оплаченном абонементе) правится на kind='correction' —
--       иначе он же теперь бросает 22023 вместо создания overpaid-
--       сценария, который проверяет следующий блок (родитель видит
--       payment_state).
--   Р8. Форма возврата — источник оплаты (subscription-actions.ts,
--       subscriptions-panel.tsx) в этой же миграции: обязательность
--       source на сервере без поля в форме мгновенно ломала бы кнопку
--       «Вернуть».
--
-- Ревью НАПИСАННОГО кода (после Р1-Р8, тот же PR) — четыре блокера:
--
--   Р9. create or replace с новым списком типов — не REPLACE, а вторая
--       перегрузка: старая refund_subscription(uuid,integer) из 0026
--       осталась бы жить рядом с грантом to authenticated (прецедент
--       0029 — record_payment там менялся через явный drop). PostgREST на
--       два подходящих кандидата отвечает PGRST203, а старое тело — ровно
--       тот обход, который эта миграция закрывает (без
--       payments_refund_once_key и без проверки status='cancelled'). Ниже
--       — явный drop перед create.
--   Р10. payments_no_overpay читал абонемент без center_id — подбором
--       суммы в kind='payment' на чужой subscription_id различим остаток
--       чужого центра до того, как FK успеет отбить (FK — AFTER, триггер
--       — BEFORE). Добавлен фильтр center_id = new.center_id; чужая или
--       несуществующая строка — not found, дальше отбивает FK.
--   Р11 (снята следующим раундом ревью, см. Р13-Р14 ниже — оставлено для
--       истории, что промежуточный фикс был неполным). v_prior в ветке
--       UPDATE вычитался из paid_tiyin НОВОГО subscription_id, даже когда
--       менялся сам subscription_id.
--   Р12. Событие subscription.refunded с новым полем refund_tiyin не было
--       отражено в contracts — zod без .strict() молча срезал бы поле у
--       любого потребителя. Добавлено в subscriptionRefundedSchema (как
--       optional — см. Р15: старые события этого поля не содержат).
--
-- Второй раунд ревью написанного кода (после Р9-Р12) — ещё три блокера:
--
--   Р13. BEFORE-ROW триггер с ручным прогнозом (v_paid − v_prior + new)
--       ловится многострочным INSERT: все BEFORE успевают отработать до
--       единственного AFTER-пересчёта payments_recalc_paid, и вторая
--       строка того же INSERT проверяется по тому же «до», что и первая
--       (одна прошла бы, другая — нет по отдельности, но вместе обе
--       проходят). Весь ручной прогноз (Р6/Р11, v_prior/v_next) снят:
--       payments_no_overpay переехал в AFTER, с именем
--       payments_recalc_paid_overpay_guard — по алфавиту после
--       payments_recalc_paid. Держится на двух вещах: (а) к моменту, когда
--       AFTER-события начинают исполняться, ВСЕ строки многострочного
--       INSERT уже физически вставлены, и payments_recalc_paid считает
--       ПОЛНЫЙ sum(amount_tiyin), а не инкремент — значит уже на первой же
--       очереди событий paid_tiyin равен итогу всей команды; (б) имя
--       гарантирует, что для каждой строки recalc отрабатывает раньше
--       guard. Проверка read-after-recalc, а не собственный подсчёт —
--       не расходится с тем, как считает recalc, по построению.
--   Р14. Список колонок update of amount_tiyin, subscription_id не включал
--       kind — update payments set kind='payment' на уже существующей
--       переплаченной correction-строке проходил бы мимо триггера вовсе.
--       Список колонок снят целиком: первая строка функции и так дёшево
--       отсеивает kind <> 'payment' — второй раз наступать на список
--       колонок как на оптимизацию себе дороже.
--   Р15. refund_tiyin в contracts сделан optional, не required: события
--       subscription.refunded, записанные до 0030, этого поля не содержат,
--       а прошлые события не переписываются (deleted_at-правило и на
--       payload).
--
-- Третий раунд ревью (после Р13-Р15) — один блокер:
--
--   Р16. Guard сравнивал абсолютное paid_tiyin > price_tiyin на КАЖДЫЙ
--       update строки kind='payment', а не только на ту, что увеличивает
--       оплату. После санкционированной переплаты через correction (Р6)
--       paid_tiyin > price_tiyin держится постоянно и намеренно — правка
--       comment у существующей kind='payment' строки того же абонемента
--       (грант на это есть, 0013) или уменьшение её суммы получали 22023
--       ни за что. Добавлен ранний выход: на UPDATE, если kind,
--       subscription_id не изменились и amount_tiyin не вырос — проверка
--       пропускается. INSERT проверяется всегда; смена kind (в т.ч.
--       correction → payment той же суммой) и рост суммы — тоже, это и
--       есть случаи, которые инвариант обязан ловить.
-- =============================================================================


-- 1. Идемпотентность возврата — частичный unique -----------------------------------

create unique index if not exists payments_refund_once_key
  on public.payments (subscription_id)
  where kind = 'refund' and subscription_id is not null;

comment on index public.payments_refund_once_key is
  'Один возврат на абонемент. Явная проверка в refund_subscription — для текста; гарантия здесь, переживает прямой RPC и будущий обход.';


-- 2. Переплата — инвариант для kind=payment, не для correction (Р6, Р13-Р14) ------

create or replace function public.payments_no_overpay()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_paid  integer;
  v_price integer;
begin
  if new.kind <> 'payment' or new.subscription_id is null then
    return new;
  end if;

  -- Р16: реагируем на РОСТ оплаты, а не на абсолютное paid_tiyin.
  -- Санкционированная переплата через correction (Р6) держит
  -- paid_tiyin > price_tiyin постоянно и намеренно — абсолютная проверка
  -- ловила бы после неё любую другую правку той же строки (comment,
  -- уменьшение суммы), не только ту, что увеличивает оплату. insert
  -- проверяем всегда; update — только если операция МОГЛА увеличить долю
  -- этой строки в paid_tiyin (сменился kind, сменился subscription_id,
  -- выросла сумма). Правка kind с 'correction' на 'payment' при той же
  -- сумме по этой проверке НЕ пропускается — kind поменялся, значит ниже
  -- всё равно считаем (задним числом объявлять переплату «настоящим»
  -- платежом инвариант обязан заметить).
  if tg_op = 'UPDATE'
     and new.kind is not distinct from old.kind
     and new.subscription_id is not distinct from old.subscription_id
     and new.amount_tiyin <= old.amount_tiyin
  then
    return new;
  end if;

  -- AFTER, после payments_recalc_paid (алфавитный порядок имён триггеров на
  -- одной строке — Р13): paid_tiyin здесь уже пересчитан С УЧЁТОМ этой
  -- строки, полным sum(amount_tiyin), а не прогнозом — сравниваем готовое
  -- число, вместо того чтобы считать его самим (риск разойтись с тем, как
  -- считает recalc). center_id = new.center_id (Р10) — иначе подбором суммы
  -- различим остаток по абонементу чужого центра раньше, чем составной FK
  -- успеет отбить чужую строку.
  select paid_tiyin, price_tiyin into v_paid, v_price
    from public.subscriptions
   where id = new.subscription_id
     and center_id = new.center_id
     for update;
  if not found then
    return new;  -- составной FK payments_subscription_fk отобьёт сам, если абонемент чужой/не существует
  end if;

  if v_paid > v_price then
    raise exception 'Оплата больше остатка по абонементу — переплату проводите корректировкой'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

revoke all on function public.payments_no_overpay() from public, anon, authenticated;

-- Р14: без списка колонок — kind тоже должен перепроверяться (update payments
-- set kind='payment' на переплаченной correction-строке), а список колонок
-- как «оптимизация» здесь уже дважды создавал дыру.
drop trigger if exists payments_no_overpay on public.payments;
drop trigger if exists payments_recalc_paid_overpay_guard on public.payments;
create trigger payments_recalc_paid_overpay_guard
  after insert or update on public.payments
  for each row execute function public.payments_no_overpay();


-- 3. refund_subscription — платёжная строка (тело из 0026, Р1-Р5) -----------------------

-- Р9: новый параметр — не REPLACE, а вторая перегрузка (типы аргументов
-- разные), старая двухпараметровая осталась бы исполняемым RPC с грантом.
drop function if exists public.refund_subscription(uuid, integer);

create function public.refund_subscription(
  p_id             uuid,
  p_expected_tiyin integer,
  p_source_id      uuid default null
)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_sub    public.subscriptions;
  v_actual integer;
  v_refund integer;
  v_left   integer;
begin
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_sub from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  -- Р4: явно, до расчёта — иначе status='cancelled' перезаписывался бы
  -- молча, а lessons_written_off списывались бы второй раз.
  if v_sub.status = 'cancelled' then
    raise exception 'Абонемент уже отменён' using errcode = '22023';
  end if;

  -- refund_calc — стоимость НЕОТРАБОТАННЫХ занятий (сверка с формой и
  -- событие остаются про это же число, как раньше); деньги, которые
  -- реально возвращаются, — Р1.
  v_actual := public.refund_calc(p_id);
  if v_actual is distinct from p_expected_tiyin then
    raise exception 'Остаток изменился, пока считали возврат: сейчас % тыйын. Проверьте расчёт.', v_actual
      using errcode = '23514';
  end if;

  v_refund := least(v_actual, v_sub.paid_tiyin);
  if v_refund > 0 and p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;

  v_left := coalesce(public.subscription_lessons_left(p_id), 0);
  update public.subscriptions
     set lessons_written_off = lessons_written_off + v_left,
         status = 'cancelled'
   where id = p_id;

  if v_refund > 0 then
    -- record_payment — тот же путь, что у любых других денег: пересчёт
    -- paid_tiyin и событие payment.refunded достаются отсюда, не
    -- дублируются вручную.
    perform public.record_payment(
      v_sub.payer_id, -v_refund, 'refund', v_sub.student_id, p_id,
      p_source_id, now(), 'Возврат при отмене абонемента'
    );
  end if;

  perform public.emit_event('subscription.refunded',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id,
                       'lessons', v_left, 'amount_tiyin', v_actual,
                       'refund_tiyin', v_refund), v_center);
  return v_actual;
end;
$$;

-- drop+create (Р9) не наследует ACL старой перегрузки — явные гранты здесь
-- обязательны, а не «дубль ради правила» из CLAUDE.md.
revoke execute on function public.refund_subscription(uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.refund_subscription(uuid, integer, uuid) to authenticated;
