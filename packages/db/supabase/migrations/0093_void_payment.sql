-- =============================================================================
-- 0093_void_payment.sql — отмена ошибочного платежа
--
-- Решение владельца 6.10.2026. Случай на prod: перевод 6 400 из Mbank внесли
-- дважды — в «Финансах» без абонемента и при продаже абонемента. Удалить
-- платёж нельзя (история денег), отрицательную корректировку форма не даёт, а
-- «Возврат» показал бы в отчётах деньги, которые никто не возвращал.
--
-- Решения:
--   Р1. Отмена — строка-корректировка на ту же сумму с минусом, тот же
--       плательщик, ученик, источник и ДАТА исходного платежа: итог месяца и
--       кассы по источнику сходится в ноль там же, где был ошибочный платёж.
--       Исходная строка не меняется. Ссылка payments.voids_payment_id — одна
--       отмена на платёж (unique).
--   Р2. Отменить можно только поступление (kind = 'payment') без абонемента
--       и не оплату долга за занятия: платёж по абонементу закрывается
--       возвратом в карточке ученика (0090), оплата долга — возвратом аванса
--       (0087). Иначе отмена ломала бы paid_tiyin, рассрочку и счёт долга.
--   Р3. Только владелец центра, причина обязательна — как списание долга
--       (0087) и корректировка по абонементу (0090). Закрытый месяц —
--       отказ financial_period_guard (сначала переоткрыть месяц).
--   Р4. Граница — триггер на payments: строка с voids_payment_id обязана
--       зеркалить исходную (сумма с минусом, те же плательщик, ученик,
--       источник, без абонемента). Прямой insert в payments у ролей
--       приложения и так закрыт (0013), триггер держит и postgres/service.
--   Р5. Событие payment.voided — из RPC (забор 0075), без причины в payload.
-- =============================================================================


-- 1. Ссылка на отменённый платёж (Р1) -------------------------------------------------------------

alter table public.payments
  add column if not exists voids_payment_id uuid references public.payments (id);

comment on column public.payments.voids_payment_id is
  'Эта строка — отмена ошибочного платежа voids_payment_id (0093): корректировка на ту же сумму с минусом. Одна отмена на платёж.';

-- Непартиальный unique: он же покрывает FK (урок 0069); NULL не конфликтуют.
alter table public.payments drop constraint if exists payments_voids_payment_id_key;
alter table public.payments add constraint payments_voids_payment_id_key unique (voids_payment_id);

alter table public.payments drop constraint if exists payments_void_is_correction;
alter table public.payments add constraint payments_void_is_correction
  check (voids_payment_id is null or kind = 'correction');


-- 2. Граница отмены (Р2, Р4) ----------------------------------------------------------------------

create or replace function public.payments_void_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_orig public.payments;
begin
  if new.voids_payment_id is null then
    return new;
  end if;

  select * into v_orig from public.payments p where p.id = new.voids_payment_id for update;
  if v_orig.id is null or v_orig.center_id <> new.center_id then
    raise exception 'Платёж не найден' using errcode = '42704';
  end if;
  if v_orig.voids_payment_id is not null then
    raise exception 'Отмену платежа отменить нельзя' using errcode = '22023';
  end if;
  if v_orig.kind <> 'payment' or v_orig.subscription_id is not null or v_orig.covers_lesson_debt then
    raise exception 'Отменить можно только поступление без абонемента и не оплату долга' using errcode = '22023';
  end if;
  if new.subscription_id is not null
     or new.amount_tiyin <> -v_orig.amount_tiyin
     or new.payer_id <> v_orig.payer_id
     or new.student_id is distinct from v_orig.student_id
     or new.source_id is distinct from v_orig.source_id
     or new.covers_lesson_debt then
    raise exception 'Отмена должна зеркалить исходный платёж' using errcode = '22023';
  end if;
  return new;
end;
$$;
comment on function public.payments_void_guard() is
  'Граница 0093: строка с voids_payment_id зеркалит исходное поступление без абонемента (сумма с минусом, те же плательщик, ученик, источник).';
revoke all on function public.payments_void_guard() from public, anon, authenticated, service_role;

drop trigger if exists payments_void_guard on public.payments;
create trigger payments_void_guard
  before insert on public.payments
  for each row execute function public.payments_void_guard();


-- 3. RPC (Р1–Р3, Р5) ------------------------------------------------------------------------------

create or replace function public.void_payment(p_payment_id uuid, p_reason text)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_orig   public.payments;
  v_id     uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.role_in(v_center), '') <> 'owner' then
    raise exception 'Отменить платёж может только владелец центра' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Укажите причину отмены' using errcode = '22023';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'Причина — не длиннее 500 символов' using errcode = '22023';
  end if;

  select * into v_orig from public.payments p
   where p.id = p_payment_id and p.center_id = v_center
     for update;
  if not found then
    raise exception 'Платёж не найден' using errcode = '42704';
  end if;
  if exists (select 1 from public.payments p where p.voids_payment_id = p_payment_id) then
    raise exception 'Платёж уже отменён' using errcode = '22023';
  end if;
  if v_orig.voids_payment_id is not null then
    raise exception 'Отмену платежа отменить нельзя' using errcode = '22023';
  end if;
  if v_orig.subscription_id is not null then
    raise exception 'Платёж по абонементу отменяется возвратом в карточке ученика' using errcode = '22023';
  end if;
  if v_orig.covers_lesson_debt then
    raise exception 'Оплату долга за занятия отменить нельзя — оформите возврат аванса' using errcode = '22023';
  end if;
  if v_orig.kind <> 'payment' then
    raise exception 'Отменить можно только поступление' using errcode = '22023';
  end if;

  insert into public.payments (
    center_id, payer_id, student_id, subscription_id, amount_tiyin, source_id,
    paid_at, kind, comment, created_by, covers_lesson_debt, voids_payment_id
  )
  values (
    v_center, v_orig.payer_id, v_orig.student_id, null, -v_orig.amount_tiyin, v_orig.source_id,
    v_orig.paid_at, 'correction', 'Отмена платежа: ' || btrim(p_reason), auth.uid(), false, p_payment_id
  )
  returning id into v_id;

  -- Причина в payload не кладётся: outbox уходит наружу.
  perform public.emit_event('payment.voided', jsonb_build_object('center_id', v_center, 'payment_id', v_id, 'voided_payment_id', p_payment_id, 'amount_tiyin', v_orig.amount_tiyin), v_center);

  return v_id;
end;
$$;
comment on function public.void_payment(uuid, text) is
  'Отменить ошибочное поступление без абонемента (0093): только owner, причина обязательна; пишет корректировку на ту же сумму с минусом той же датой. Исходная строка не меняется.';

revoke all on function public.void_payment(uuid, text) from public, anon;
grant execute on function public.void_payment(uuid, text) to authenticated;
