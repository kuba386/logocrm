-- =============================================================================
-- 0091_transfer_moves_money.sql — перенос остатка вместе с деньгами
--
-- Этап 10 (docs/Roadmap/stages.md). Ревью 0090: transfer_remaining создавал
-- новый пакет с paid 0 на перенесённые занятия, а деньги за них оставались на
-- старом — уже отменённом, откуда их не вернуть. Получатель сразу попадал в
-- «просрочку» на сумму, которую семья уже внесла. Решение владельца 6.10.2026:
-- деньги идут с занятиями, перенос — только между детьми одного плательщика.
--
-- Решения:
--   Р1. Переносится внесённое сверх отработанного, не больше цены нового
--       пакета: least(greatest(least(paid, price) − отработанное, 0),
--       остаток × цена занятия). Отработанное — subscription_worked_unchecked
--       (0090 Р1), считается до закрытия старого.
--   Р2. Деньги — парой корректировок в одной транзакции: минус на старом,
--       плюс на новом, в сумме ноль. Касса не меняется. Источник — пустой:
--       денег не принимали и не выдавали. Флаг logocrm.subscription_transfer
--       (заложен в 0090 Р6) пропускает корректировку не от владельца.
--       Закрытый старый: paid − перенос ≥ снимок, потому что перенос ≤
--       внесено − отработанное.
--   Р3. Один плательщик: payer_id старого абонемента = payer_id получателя.
--       Иначе деньги одной семьи уходили бы другой.
--   Р4. Отменённый абонемент не переносится (раньше после правки отметки
--       задним числом остаток отменённого становился > 0 и переносился,
--       хотя деньги за него уже посчитаны возвратом). Проверка сессии и
--       центра — первой строкой.
--   Р5. Событие subscription.transferred несёт amount_tiyin — сколько денег
--       перешло (contracts: optional, старые события поля не несут).
--   Р6. Живая рассрочка с неоплаченными строками — отказ: закрытие старого
--       гасит план (0020), у нового плана нет, и 0070 сразу объявил бы весь
--       остаток просроченным, хотя сроки не наступили.
--   Р7. Остаток от деления цены на число занятий (5 000 / 12 → 8 тыйын)
--       переходит в цену нового пакета, если он меньше числа переносимых
--       занятий (CHECK цены занятия это допускает), — иначе он застревал бы на
--       отменённом пакете, откуда его не вернуть.
--   Р8. Сумма переноса — от снимка 0090 (update … returning), не повторным
--       расчётом: один источник.
--
-- Известное: в утренней сводке и /cash (center_payments_day, 0072) пара
-- корректировок видна как «Без источника: 0,00 сом (операций: 2)». Второй
-- плательщик через student_payers (0014) «тем же плательщиком» не считается.
-- =============================================================================


-- 1. transfer_remaining — тело 0055 плюс Р1–Р5 ---------------------------------------------------

create or replace function public.transfer_remaining(p_from uuid, p_to_student uuid)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_from    public.subscriptions;
  v_student public.students;
  v_left    integer;
  v_rem     integer;
  v_price   integer;
  v_settled integer;
  v_move    integer;
  v_from_name text;
  v_new     uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_from from public.subscriptions
   where id = p_from and center_id = v_center and deleted_at is null for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;
  -- Р4.
  if v_from.status = 'cancelled' then
    raise exception 'Абонемент уже отменён' using errcode = '22023';
  end if;

  select * into v_student from public.students
   where id = p_to_student and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;
  -- Р3.
  if v_student.payer_id is distinct from v_from.payer_id then
    raise exception 'Перенос остатка — только между детьми одного плательщика' using errcode = '22023';
  end if;

  v_left := coalesce(public.subscription_lessons_left(p_from), 0);
  if v_left <= 0 then
    raise exception 'Переносить нечего: остаток пуст' using errcode = '22023';
  end if;

  -- Р6.
  if exists (select 1 from public.installments_view v
              where v.subscription_id = p_from and v.state in ('upcoming', 'due', 'overdue')) then
    raise exception 'Сначала отмените рассрочку — график платежей не переносится' using errcode = '22023';
  end if;

  -- Р7: цена нового — остаток × цена занятия плюс остаток от деления, если он
  -- меньше числа переносимых занятий.
  v_rem := v_from.price_tiyin - v_from.lessons_total * coalesce(v_from.lesson_price_tiyin, 0);
  v_price := v_left * coalesce(v_from.lesson_price_tiyin, 0)
             + case when v_rem > 0 and v_rem < v_left then v_rem else 0 end;

  update public.subscriptions
     set lessons_written_off = lessons_written_off + v_left,
         status = 'cancelled'
   where id = p_from
  returning settled_worked_tiyin into v_settled;

  -- Р1, Р8: перенос — внесённое (не больше цены) сверх снимка, не больше цены нового.
  v_move := least(greatest(least(v_from.paid_tiyin, v_from.price_tiyin) - v_settled, 0), v_price);

  -- 0055 Р12б: следующий INSERT будит subscriptions_funnel_transition — метим
  -- служебным до него, снимаем сразу после (та же дисциплина, что и везде
  -- в файле).
  perform set_config('logocrm.funnel_transfer', '1', true);

  insert into public.subscriptions (
    center_id, student_id, payer_id, type_id,
    lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at, notes
  )
  values (
    v_center, p_to_student, v_student.payer_id, v_from.type_id,
    v_left, v_price, v_from.lesson_price_tiyin,
    public.center_today(v_center), v_from.ends_at,
    'Перенос остатка с абонемента ' || p_from::text
  )
  returning id into v_new;

  perform set_config('logocrm.funnel_transfer', '', true);

  -- Р2: деньги — парой корректировок, касса не меняется.
  if v_move > 0 then
    select st.full_name into v_from_name from public.students st where st.id = v_from.student_id;
    perform set_config('logocrm.subscription_transfer', '1', true);
    perform public.record_payment(
      v_from.payer_id, -v_move, 'correction', v_from.student_id, p_from,
      null, now(), 'Перенос остатка абонемента: ' || v_student.full_name
    );
    perform public.record_payment(
      v_from.payer_id, v_move, 'correction', p_to_student, v_new,
      null, now(), 'Перенос остатка абонемента от: ' || coalesce(v_from_name, 'ученика')
    );
    perform set_config('logocrm.subscription_transfer', '', true);
  end if;

  perform public.emit_event('subscription.transferred', jsonb_build_object('center_id', v_center, 'from_subscription_id', p_from, 'to_subscription_id', v_new, 'lessons', v_left, 'amount_tiyin', v_move), v_center);
  return v_new;
end;
$$;

comment on function public.transfer_remaining(uuid, uuid) is
  'Перенос остатка абонемента другому ребёнку того же плательщика (0026; 0055 — служебный автопереход воронки; 0091 — внесённое сверх отработанного переходит парой корректировок, отменённый не переносится).';

revoke all on function public.transfer_remaining(uuid, uuid) from public, anon, service_role;
grant execute on function public.transfer_remaining(uuid, uuid) to authenticated;
