-- =============================================================================
-- 0090_close_requires_paid.sql — абонемент закрывается, только если
-- отработанное оплачено
--
-- Этап 10 (docs/Roadmap/stages.md). Ревью 0089: отмена или архив частично
-- оплаченного абонемента стирали недоплату за отработанное — «просрочка»
-- (0070) и экспорт (0058) берут только живые неотменённые, рассрочка гасится
-- при отмене (0020). Решения владельца 6.10.2026: запретить; недоплату может
-- списать только владелец, с причиной; корректировка по абонементу — только
-- владелец.
--
-- Решения:
--   Р1. Стоимость отработанного — одна функция subscription_worked_unchecked
--       с явными ветками: пакет — 0 без отметок, цена при остатке ≤ 0, иначе
--       used × цена занятия (не «цена − к возврату»: остаток от деления
--       цены на число занятий не считается отработанным); период — цена −
--       refund_calc; безлимит без срока — 0 без отметок, иначе цена (решение
--       по ревью). Перерасход сверх пакета сюда не входит: это долг за
--       занятия (0087/0089).
--   Р2. Инвариант — на строке, не на переходе. При отмене или архиве
--       неотменённого триггер пишет снимок settled_worked_tiyin; CHECK
--       «внесено + списано ≥ снимок» держит и возвраты/корректировки после
--       закрытия, и гонку платежа с архивом. Снимок нужен ещё и потому, что
--       у отменённого refund_calc = 0 — пересчитать отработанное задним
--       числом нельзя. Колонки вне грантов, пишут только триггеры.
--   Р3. Понятные тексты: при закрытии — сам триггер снимка; после закрытия —
--       recalc_subscription_paid под блокировкой, с полной суммой (не
--       прогноз в BEFORE INSERT на payments: многострочный insert и update
--       платежей его обходили). Положительный платёж на закрытый абонемент —
--       отказ: деньги застряли бы, возврат по закрытому невозможен.
--   Р4. Возврат выплачивает внесённое сверх отработанного:
--       greatest(least(paid, price) − снимок, 0) вместо least(к возврату,
--       внесено) из 0030 Р1 — иначе при частичной оплате отработанные
--       занятия уходили бы деньгами (4 000 / внесено 2 000 / отходил 2 по
--       500 → было 2 000, стало 1 000). least с ценой — переплата сверх цены
--       наличными не уходит, пока у пакета может быть долг за перерасход.
--       Выплата считается от снимка (update … returning), сверка
--       p_expected_payout_tiyin (23514). Новая сигнатура — старая удаляется,
--       иначе PGRST203.
--   Р5. Списание недоплаты — write_off_subscription, только owner, причина
--       обязательна, касса не меняется. Списание только вместе с закрытием:
--       «просрочка» и экспорт отменённые не берут, их не переиздаём.
--       Таблица subscription_shortfall_writeoffs — по образцу
--       lesson_debt_writeoffs (0087 Р6): select can_payments, запись только
--       RPC, списание не отменяется.
--   Р6. Строки 'refund' и 'correction' с subscription_id: возврат пишет только
--       refund_subscription (служебный флаг транзакции), корректировку —
--       только owner (решение владельца). Без сессии (миграции, бэкфиллы) —
--       без проверки. Флаг logocrm.subscription_transfer заложен для 0091.
--   Р7. «Сначала примите оплату» должно куда-то вести: accept_subscription_
--       payment — оплата по существующему абонементу с карточки ученика
--       (can_payments, сверка остатка к оплате, не больше остатка).
--   Р8. Браузер денег не считает: subscription_summary отдаёт отработанное,
--       выплату, недоплату и остаток к оплате; payment_state закрытого — 'closed' (иначе
--       «оплачено частично» на полностью рассчитанном пакете).
--
-- Не здесь — 0091: перенос остатка вместе с деньгами, только в пределах
-- одного плательщика, явный отказ transfer_remaining по отменённому.
-- До 0091 transfer_remaining по-прежнему начисляет перенесённое заново.
-- =============================================================================


-- 1. Стоимость отработанного (Р1) -----------------------------------------------------------------

create or replace function public.subscription_worked_unchecked(p_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select case
    -- Пакет занятий.
    when s.lessons_total is not null then
      case
        when s.lessons_used <= 0 then 0
        when s.lessons_total - s.lessons_used - s.lessons_written_off <= 0 then s.price_tiyin
        else least(s.lessons_used::bigint * coalesce(s.lesson_price_tiyin, 0), s.price_tiyin)::integer
      end
    -- Период (и безлимит со сроком): прошедшая часть срока.
    when s.ends_at is not null then
      greatest(s.price_tiyin - coalesce(public.refund_calc_unchecked(s.id), 0), 0)
    -- Безлимит без срока: lessons_used ведёт recalc_subscription_usage.
    else case when s.lessons_used > 0 then s.price_tiyin else 0 end
  end
  from public.subscriptions s
  where s.id = p_id;
$$;
comment on function public.subscription_worked_unchecked(uuid) is
  'Стоимость отработанного по абонементу (0090 Р1): пакет — 0 без отметок, цена при остатке ≤ 0, иначе used × цена занятия; период — цена − refund_calc; безлимит без срока — 0/цена по lessons_used. Для живого (неотменённого) абонемента; у закрытого — снимок settled_worked_tiyin. Без проверки сессии; грантов нет.';

revoke all on function public.subscription_worked_unchecked(uuid) from public, anon, authenticated, service_role;


-- 2. Снимок при закрытии и списанная недоплата (Р2) -----------------------------------------------

alter table public.subscriptions
  add column if not exists settled_worked_tiyin integer,
  add column if not exists shortfall_written_off_tiyin integer not null default 0;

comment on column public.subscriptions.settled_worked_tiyin is
  'Стоимость отработанного на момент отмены или архива (0090 Р2). null — абонемент не закрыт. Пишет только триггер subscriptions_settle_close.';
comment on column public.subscriptions.shortfall_written_off_tiyin is
  'Сумма списанной владельцем недоплаты (0090 Р5) — денормализация subscription_shortfall_writeoffs, пишет только триггер.';

-- Бэкфилл закрытых до 0090 — как есть, история не меняется (prod 0 строк,
-- staging 2). Отменённым — least(цена, внесено): у них written_off добит до
-- остатка, а refund_calc = 0, оценка через Р1 дала бы цену. Архивным
-- неотменённым — оценка Р1, не больше внесённого.
update public.subscriptions s
   set settled_worked_tiyin = least(s.price_tiyin, s.paid_tiyin)
 where s.status = 'cancelled' and s.settled_worked_tiyin is null;
update public.subscriptions s
   set settled_worked_tiyin = least(coalesce(public.subscription_worked_unchecked(s.id), 0), s.paid_tiyin)
 where s.deleted_at is not null and s.status <> 'cancelled' and s.settled_worked_tiyin is null;

alter table public.subscriptions drop constraint if exists subscriptions_shortfall_written_off_check;
alter table public.subscriptions add constraint subscriptions_shortfall_written_off_check
  check (shortfall_written_off_tiyin >= 0);
alter table public.subscriptions drop constraint if exists subscriptions_settled_paid;
alter table public.subscriptions add constraint subscriptions_settled_paid
  check (settled_worked_tiyin is null or paid_tiyin + shortfall_written_off_tiyin >= settled_worked_tiyin);


-- Имя после subscriptions_guard_soft_delete (0010) по алфавиту: сначала
-- «верните остаток», потом «примите оплату».
create or replace function public.subscriptions_settle_close()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_short integer;
begin
  if old.settled_worked_tiyin is not null
     and new.settled_worked_tiyin is distinct from old.settled_worked_tiyin then
    raise exception 'Расчёт закрытого абонемента не меняется' using errcode = '22023';
  end if;

  if new.settled_worked_tiyin is null and (
       (new.status = 'cancelled' and old.status is distinct from 'cancelled')
    or (new.deleted_at is not null and old.deleted_at is null)) then
    -- В BEFORE-триггере функция читает ещё старую версию строки.
    new.settled_worked_tiyin := coalesce(public.subscription_worked_unchecked(old.id), 0);
    v_short := new.settled_worked_tiyin - new.paid_tiyin - new.shortfall_written_off_tiyin;
    if v_short > 0 then
      raise exception 'За отработанные занятия не заплачено: не хватает %. Сначала примите оплату%.',
        public.format_som(v_short),
        case when public.role_in(new.center_id) = 'owner' then ' или спишите недоплату' else '' end
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
comment on function public.subscriptions_settle_close() is
  'Снимок отработанного при отмене/архиве (0090 Р2) и отказ с текстом, если внесено + списано меньше. Снимок не меняется.';
revoke all on function public.subscriptions_settle_close() from public, anon, authenticated, service_role;

drop trigger if exists subscriptions_settle_close on public.subscriptions;
create trigger subscriptions_settle_close
  before update of status, deleted_at, settled_worked_tiyin on public.subscriptions
  for each row execute function public.subscriptions_settle_close();


-- 3. Платежи по закрытому абонементу (Р3) — тело 0013 плюс проверка снимка -------------------------

create or replace function public.recalc_subscription_paid(p_subscription_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_paid integer;
  v_sub  public.subscriptions;
begin
  if p_subscription_id is null then
    return;
  end if;

  -- Блокировка строки абонемента — тот же приём, что recalc_subscription_usage
  -- (0009): без него два параллельных платежа читают один снимок и один из
  -- пересчётов проигрывает молча.
  select * into v_sub from public.subscriptions where id = p_subscription_id for update;
  if not found then
    return;
  end if;

  select coalesce(sum(amount_tiyin), 0) into v_paid
    from public.payments
   where subscription_id = p_subscription_id;

  -- 0090 Р3: закрытый абонемент — полная сумма под блокировкой, не прогноз.
  if v_sub.settled_worked_tiyin is not null then
    if v_paid > v_sub.paid_tiyin then
      raise exception 'Абонемент закрыт — оплату по нему принять нельзя' using errcode = '22023';
    end if;
    if v_paid + v_sub.shortfall_written_off_tiyin < v_sub.settled_worked_tiyin then
      raise exception 'Абонемент закрыт: вернуть можно не больше %, остальное — за отработанные занятия',
        public.format_som(greatest(v_sub.paid_tiyin + v_sub.shortfall_written_off_tiyin - v_sub.settled_worked_tiyin, 0))
        using errcode = '22023';
    end if;
  end if;

  update public.subscriptions set paid_tiyin = v_paid where id = p_subscription_id;
end;
$$;
revoke all on function public.recalc_subscription_paid(uuid) from public, anon, authenticated, service_role;


-- 4. Возврат и корректировка по абонементу (Р6) ---------------------------------------------------

create or replace function public.payments_subscription_kind_gate()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.subscription_id is null or auth.uid() is null then
    return new;
  end if;
  if new.kind = 'refund'
     and coalesce(current_setting('logocrm.subscription_refund', true), '') <> '1' then
    raise exception 'Возврат по абонементу — только кнопкой «Вернуть» в карточке ученика' using errcode = '42501';
  end if;
  if new.kind = 'correction'
     and coalesce(current_setting('logocrm.subscription_transfer', true), '') <> '1'
     and coalesce(public.role_in(new.center_id), '') <> 'owner' then
    raise exception 'Корректировку по абонементу проводит только владелец центра' using errcode = '42501';
  end if;
  return new;
end;
$$;
comment on function public.payments_subscription_kind_gate() is
  'Строки refund/correction с subscription_id (0090 Р6): возврат — только refund_subscription (флаг logocrm.subscription_refund), корректировка — только owner (или служебный перенос 0091, флаг logocrm.subscription_transfer). Без сессии — без проверки.';
revoke all on function public.payments_subscription_kind_gate() from public, anon, authenticated, service_role;

drop trigger if exists payments_subscription_kind_gate on public.payments;
create trigger payments_subscription_kind_gate
  before insert on public.payments
  for each row execute function public.payments_subscription_kind_gate();


-- 5. Возврат — внесённое сверх отработанного (Р4) --------------------------------------------------

drop function if exists public.refund_subscription(uuid, integer, uuid);

create function public.refund_subscription(
  p_id                    uuid,
  p_expected_tiyin        integer,
  p_expected_payout_tiyin integer,
  p_source_id             uuid default null
)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_sub     public.subscriptions;
  v_actual  integer;
  v_payout  integer;
  v_settled integer;
  v_left    integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_sub from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  -- 0030 Р4: явно, до расчёта — иначе status='cancelled' перезаписывался бы
  -- молча, а lessons_written_off списывались бы второй раз.
  if v_sub.status = 'cancelled' then
    raise exception 'Абонемент уже отменён' using errcode = '22023';
  end if;

  -- refund_calc — стоимость НЕОТРАБОТАННЫХ занятий: сверка с формой и событие.
  v_actual := public.refund_calc(p_id);
  if v_actual is distinct from p_expected_tiyin then
    raise exception 'Остаток изменился, пока считали возврат: сейчас %. Проверьте расчёт.', public.format_som(v_actual)
      using errcode = '23514';
  end if;

  -- Р4: деньги — внесённое (не больше цены) сверх отработанного.
  v_payout := greatest(least(v_sub.paid_tiyin, v_sub.price_tiyin)
                       - coalesce(public.subscription_worked_unchecked(p_id), 0), 0);
  if p_expected_payout_tiyin is distinct from v_payout then
    raise exception 'Сумма к выплате изменилась, пока открывали форму: сейчас %. Проверьте и повторите.', public.format_som(v_payout)
      using errcode = '23514';
  end if;
  if v_payout > 0 and p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;

  -- 0089 Р2: у перерасходованного пакета остаток отрицательный — списывать нечего.
  v_left := greatest(coalesce(public.subscription_lessons_left(p_id), 0), 0);
  update public.subscriptions
     set lessons_written_off = lessons_written_off + v_left,
         status = 'cancelled'
   where id = p_id
  returning settled_worked_tiyin into v_settled;

  -- Выплата — от снимка, который записал триггер: два расчёта не разойдутся.
  if greatest(least(v_sub.paid_tiyin, v_sub.price_tiyin) - v_settled, 0) <> v_payout then
    raise exception 'Расчёт возврата изменился — откройте форму заново' using errcode = '23514';
  end if;

  if v_payout > 0 then
    -- record_payment — тот же путь, что у любых других денег. Флаг — Р6.
    perform set_config('logocrm.subscription_refund', '1', true);
    perform public.record_payment(
      v_sub.payer_id, -v_payout, 'refund', v_sub.student_id, p_id,
      p_source_id, now(), 'Возврат при отмене абонемента'
    );
    perform set_config('logocrm.subscription_refund', '', true);
  end if;

  perform public.emit_event('subscription.refunded', jsonb_build_object('center_id', v_center, 'subscription_id', p_id, 'lessons', v_left, 'amount_tiyin', v_actual, 'refund_tiyin', v_payout), v_center);
  return v_actual;
end;
$$;
comment on function public.refund_subscription(uuid, integer, integer, uuid) is
  'Отмена абонемента с возвратом (0090 Р4): выплата — внесённое сверх отработанного, сверка p_expected_tiyin (к возврату) и p_expected_payout_tiyin (деньги), 23514. Недоплата за отработанное — отказ триггера subscriptions_settle_close.';

revoke all on function public.refund_subscription(uuid, integer, integer, uuid) from public, anon;
grant execute on function public.refund_subscription(uuid, integer, integer, uuid) to authenticated;


-- 6. Оплата по существующему абонементу (Р7) ------------------------------------------------------

create or replace function public.accept_subscription_payment(
  p_subscription_id   uuid,
  p_amount_tiyin      integer,
  p_source_id         uuid,
  p_paid_on           date,
  p_expected_due_tiyin integer
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_sub    public.subscriptions;
  v_due    integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_amount_tiyin is null or p_amount_tiyin <= 0 then
    raise exception 'Сумма должна быть больше нуля' using errcode = '22023';
  end if;
  if p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;

  -- Порядок subscriptions → payments, как у pay_installment (0030 Р5).
  select * into v_sub from public.subscriptions s
   where s.id = p_subscription_id and s.center_id = v_center and s.deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;
  if v_sub.status = 'cancelled' or v_sub.settled_worked_tiyin is not null then
    raise exception 'Абонемент закрыт — оплату по нему принять нельзя' using errcode = '22023';
  end if;

  v_due := greatest(v_sub.price_tiyin - v_sub.paid_tiyin, 0);
  if p_expected_due_tiyin is distinct from v_due then
    raise exception 'Остаток к оплате изменился, пока открывали форму: сейчас %. Проверьте сумму.', public.format_som(v_due)
      using errcode = '23514';
  end if;
  if p_amount_tiyin > v_due then
    raise exception 'Больше остатка к оплате: сейчас %', public.format_som(v_due) using errcode = '22023';
  end if;

  return public.record_payment_core(
    v_sub.payer_id, p_amount_tiyin, 'payment', v_sub.student_id, p_subscription_id,
    p_source_id, null, 'Оплата абонемента', p_paid_on, false
  );
end;
$$;
comment on function public.accept_subscription_payment(uuid, integer, uuid, date, integer) is
  'Оплата по существующему абонементу с карточки ученика (0090 Р7): can_payments, не больше остатка, сверка p_expected_due_tiyin (23514). Закрытый абонемент — отказ.';

revoke all on function public.accept_subscription_payment(uuid, integer, uuid, date, integer) from public, anon;
grant execute on function public.accept_subscription_payment(uuid, integer, uuid, date, integer) to authenticated;


-- 7. Списание недоплаты владельцем (Р5) -----------------------------------------------------------

create table if not exists public.subscription_shortfall_writeoffs (
  id              uuid primary key default gen_random_uuid(),
  center_id       uuid not null default public.current_center()
                    references public.centers (id) on delete cascade,
  subscription_id uuid not null,
  student_id      uuid not null,
  amount_tiyin    integer not null check (amount_tiyin > 0),
  reason          text not null check (length(btrim(reason)) between 1 and 500),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),
  -- По конвенции; ни один путь его не ставит — списание не отменяется.
  deleted_at      timestamptz,

  constraint subscription_shortfall_writeoffs_subscription_fk
    foreign key (subscription_id, student_id, center_id)
    references public.subscriptions (id, student_id, center_id)
);
comment on table public.subscription_shortfall_writeoffs is
  'Списанная владельцем недоплата за отработанное по абонементу (0090 Р5): только write_off_subscription, причина обязательна, касса не меняется, списание не отменяется. Политик на запись нет.';

-- Непартиальные: частичный индекс не засчитывается покрытием FK (урок 0069).
create index if not exists subscription_shortfall_writeoffs_subscription_idx
  on public.subscription_shortfall_writeoffs (subscription_id, student_id, center_id);
create index if not exists subscription_shortfall_writeoffs_center_idx
  on public.subscription_shortfall_writeoffs (center_id, student_id);

drop trigger if exists subscription_shortfall_writeoffs_set_updated_at on public.subscription_shortfall_writeoffs;
create trigger subscription_shortfall_writeoffs_set_updated_at
  before update on public.subscription_shortfall_writeoffs
  for each row execute function extensions.moddatetime(updated_at);

alter table public.subscription_shortfall_writeoffs enable row level security;

drop policy if exists subscription_shortfall_writeoffs_select on public.subscription_shortfall_writeoffs;
create policy subscription_shortfall_writeoffs_select on public.subscription_shortfall_writeoffs
  for select to authenticated
  using (center_id = public.current_center() and public.can_payments());

revoke all on table public.subscription_shortfall_writeoffs from public, anon, authenticated, service_role;
grant select on public.subscription_shortfall_writeoffs to authenticated;

call public.apply_audit('subscription_shortfall_writeoffs');
call public.apply_readonly_guard('subscription_shortfall_writeoffs');


-- Граница «не больше недоплаты» и «только у незакрытого» — под блокировкой абонемента.
create or replace function public.subscription_shortfall_writeoffs_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_sub   public.subscriptions;
  v_short integer;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    raise exception 'Списание недоплаты не меняется и не отменяется' using errcode = '22023';
  end if;

  select * into v_sub from public.subscriptions s where s.id = new.subscription_id for update;
  if v_sub.id is null or v_sub.deleted_at is not null or v_sub.status = 'cancelled'
     or v_sub.settled_worked_tiyin is not null then
    raise exception 'Списать недоплату можно только у незакрытого абонемента' using errcode = '22023';
  end if;
  v_short := coalesce(public.subscription_worked_unchecked(v_sub.id), 0) - v_sub.paid_tiyin - v_sub.shortfall_written_off_tiyin;
  if new.amount_tiyin > v_short then
    raise exception 'Списать можно не больше недоплаты: сейчас %', public.format_som(greatest(v_short, 0))
      using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function public.subscription_shortfall_writeoffs_guard() from public, anon, authenticated, service_role;

drop trigger if exists subscription_shortfall_writeoffs_guard on public.subscription_shortfall_writeoffs;
create trigger subscription_shortfall_writeoffs_guard
  before insert or update or delete on public.subscription_shortfall_writeoffs
  for each row execute function public.subscription_shortfall_writeoffs_guard();


create or replace function public.subscription_shortfall_writeoffs_recalc()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  update public.subscriptions s
     set shortfall_written_off_tiyin = (
           select coalesce(sum(w.amount_tiyin), 0)::integer
             from public.subscription_shortfall_writeoffs w
            where w.subscription_id = new.subscription_id and w.deleted_at is null)
   where s.id = new.subscription_id;
  return null;
end;
$$;
revoke all on function public.subscription_shortfall_writeoffs_recalc() from public, anon, authenticated, service_role;

drop trigger if exists subscription_shortfall_writeoffs_recalc on public.subscription_shortfall_writeoffs;
create trigger subscription_shortfall_writeoffs_recalc
  after insert on public.subscription_shortfall_writeoffs
  for each row execute function public.subscription_shortfall_writeoffs_recalc();


create or replace function public.write_off_subscription(
  p_id                       uuid,
  p_expected_shortfall_tiyin integer,
  p_reason                   text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_sub    public.subscriptions;
  v_short  integer;
  v_left   integer;
  v_id     uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.role_in(v_center), '') <> 'owner' then
    raise exception 'Списать недоплату может только владелец центра' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Укажите причину списания' using errcode = '22023';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'Причина — не длиннее 500 символов' using errcode = '22023';
  end if;

  select * into v_sub from public.subscriptions s
   where s.id = p_id and s.center_id = v_center and s.deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;
  if v_sub.status = 'cancelled' then
    raise exception 'Абонемент уже отменён' using errcode = '22023';
  end if;

  v_short := greatest(coalesce(public.subscription_worked_unchecked(p_id), 0) - v_sub.paid_tiyin - v_sub.shortfall_written_off_tiyin, 0);
  if p_expected_shortfall_tiyin is distinct from v_short then
    raise exception 'Недоплата изменилась, пока открывали форму: сейчас %. Проверьте сумму.', public.format_som(v_short)
      using errcode = '23514';
  end if;
  if v_short <= 0 then
    raise exception 'Недоплаты нет — отмените абонемент обычным возвратом' using errcode = '22023';
  end if;

  insert into public.subscription_shortfall_writeoffs (center_id, subscription_id, student_id, amount_tiyin, reason)
  values (v_center, p_id, v_sub.student_id, v_short, btrim(p_reason))
  returning id into v_id;

  -- Закрытие — как возврат с выплатой 0: внесённое целиком за отработанное.
  v_left := greatest(coalesce(public.subscription_lessons_left(p_id), 0), 0);
  update public.subscriptions
     set lessons_written_off = lessons_written_off + v_left,
         status = 'cancelled'
   where id = p_id;

  -- Причина в payload не кладётся: outbox уходит наружу.
  perform public.emit_event('subscription.shortfall_written_off', jsonb_build_object('center_id', v_center, 'subscription_id', p_id, 'student_id', v_sub.student_id, 'writeoff_id', v_id, 'amount_tiyin', v_short), v_center);

  return v_id;
end;
$$;
comment on function public.write_off_subscription(uuid, integer, text) is
  'Списать недоплату за отработанное и закрыть абонемент (0090 Р5): только owner, причина обязательна, сверка p_expected_shortfall_tiyin (23514). Касса не меняется.';

revoke all on function public.write_off_subscription(uuid, integer, text) from public, anon;
grant execute on function public.write_off_subscription(uuid, integer, text) to authenticated;


-- 8. Сводки для карточки (Р8) ---------------------------------------------------------------------

-- Тело 0018; 'closed' — у закрытого абонемента (снимок есть).
create or replace function public.subscription_payment_summary(p_subscription_id uuid)
  returns table (
    price_tiyin         integer,
    paid_tiyin          integer,
    payment_state       text,
    installments_total  integer,
    installments_unpaid integer,
    next_due            date,
    overdue_count       integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_sub public.subscriptions;
begin
  if not public.subscription_visible_to_caller(p_subscription_id) then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  select * into v_sub from public.subscriptions s where s.id = p_subscription_id;

  return query
  select
    v_sub.price_tiyin,
    v_sub.paid_tiyin,
    -- Бесплатный (цена 0) — оплачен: платить нечего, это не долг. Закрытый —
    -- рассчитан (0090). Зеркало finance.ts::paymentState.
    case
      when v_sub.settled_worked_tiyin is not null then 'closed'
      when v_sub.paid_tiyin > v_sub.price_tiyin then 'overpaid'
      when v_sub.paid_tiyin = v_sub.price_tiyin then 'paid'
      when v_sub.paid_tiyin = 0 then 'unpaid'
      else 'partial'
    end,
    (select count(*)::integer from public.installments_view v
      where v.subscription_id = v_sub.id and v.state <> 'cancelled'),
    (select count(*)::integer from public.installments_view v
      where v.subscription_id = v_sub.id and v.state in ('upcoming', 'due', 'overdue')),
    (select min(v.due_date) from public.installments_view v
      where v.subscription_id = v_sub.id and v.state in ('upcoming', 'due', 'overdue')),
    (select count(*)::integer from public.installments_view v
      where v.subscription_id = v_sub.id and v.state = 'overdue');
end;
$$;


-- Тело 0026 плюс отработанное, выплата, недоплата и остаток к оплате — форма не считает деньги.
drop function if exists public.subscription_summary(uuid);

create function public.subscription_summary(p_subscription_id uuid)
  returns table (
    lessons_left   integer,
    state          text,
    freeze_days    integer,
    refund_tiyin   integer,
    allow_negative boolean,
    freeze_from    date,
    freeze_to      date,
    worked_tiyin   integer,
    payout_tiyin   integer,
    shortfall_tiyin integer,
    due_tiyin      integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.subscriptions s
     where s.id = p_subscription_id and s.center_id = v_center
  ) then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  return query
    select public.subscription_lessons_left(s.id),
           public.subscription_state(s.id),
           public.subscription_freeze_days(s.id),
           public.refund_calc(s.id),
           s.allow_negative,
           lower(f.period),
           case when upper_inf(f.period) then null else upper(f.period) - 1 end,
           w.worked,
           case when s.settled_worked_tiyin is not null then 0
                else greatest(least(s.paid_tiyin, s.price_tiyin) - w.worked, 0) end,
           case when s.settled_worked_tiyin is not null then 0
                else greatest(w.worked - s.paid_tiyin - s.shortfall_written_off_tiyin, 0) end,
           case when s.settled_worked_tiyin is not null then 0
                else greatest(s.price_tiyin - s.paid_tiyin, 0) end
      from public.subscriptions s
      cross join lateral (
        select coalesce(s.settled_worked_tiyin, public.subscription_worked_unchecked(s.id), 0) as worked
      ) w
      left join lateral (
        select * from public.subscription_freezes sf
         where sf.subscription_id = s.id
           and (sf.period @> public.center_today(s.center_id)
                or lower(sf.period) > public.center_today(s.center_id))
         order by (sf.period @> public.center_today(s.center_id)) desc, lower(sf.period)
         limit 1
      ) f on true
     where s.id = p_subscription_id;
end;
$$;
comment on function public.subscription_summary(uuid) is
  'Сводка абонемента для карточки (0026; 0090 — worked/payout/shortfall/due): can_payments. Выплата при отмене и недоплата за отработанное считаются здесь, не в браузере.';

revoke all on function public.subscription_summary(uuid) from public, anon;
grant execute on function public.subscription_summary(uuid) to authenticated;


-- 9. Экспорт центра — allow-list 0088 плюс списания недоплаты ------------------------------------

create or replace function public.export_center_tables()
  returns table (table_name text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('attendance'), ('attendance_statuses'), ('booking_requests'), ('diagnostic_clinical_forms'),
    ('diagnostic_referrals'), ('diagnostics'), ('exercise_library'),
    ('expense_categories'), ('expenses'), ('financial_periods'), ('funnel_events'),
    ('goal_progress'), ('goal_stages'), ('goals'), ('group_students'), ('groups'),
    ('homework'), ('homework_exercises'), ('installment_plans'), ('installments'),
    ('lesson_debt_covers'), ('lesson_debt_writeoffs'),
    ('lesson_note_goal_scores'), ('lesson_notes'), ('lesson_participants'), ('lessons'),
    ('memberships'), ('message_templates'), ('monthly_reports'), ('payers'),
    ('payment_sources'), ('payments'), ('platform_payments'), ('prosody_assessments'),
    ('reading_writing_assessments'), ('rooms'),
    ('salary_adjustments'), ('salary_runs'), ('services'), ('student_anamnesis'),
    ('student_articulation'), ('student_payers'), ('students'), ('subscription_freezes'),
    ('subscription_shortfall_writeoffs'),
    ('subscription_types'), ('subscriptions'), ('syllable_assessments'), ('teacher_rates'), ('teachers')
$$;
comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. 0087: lesson_debt_writeoffs. 0088: lesson_debt_covers. 0090: subscription_shortfall_writeoffs. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
