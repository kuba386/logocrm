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
--       Исходная строка не меняется. Ссылка payments.voids_payment_id —
--       составной FK (id, center_id) и одна отмена на платёж (unique).
--   Р2. Отменить можно только поступление (kind = 'payment') без абонемента
--       и не оплату долга за занятия: платёж по абонементу закрывается
--       возвратом в карточке ученика (0090), оплата долга — возвратом аванса
--       (0087). Иначе отмена ломала бы paid_tiyin, рассрочку и счёт долга.
--   Р3. Только владелец центра, причина обязательна — как списание долга
--       (0087) и корректировка по абонементу (0090). Закрытый месяц исходного
--       платежа — отказ с подсказкой переоткрыть месяц (раньше вставки, чтобы
--       текст не был общим текстом financial_period_guard).
--   Р4. Граница — триггер на payments, insert И update: строка с
--       voids_payment_id обязана зеркалить исходную (сумма с минусом, те же
--       дата, плательщик, ученик, источник, без абонемента); у пары нельзя
--       менять ссылку, сумму, вид, дату, источник, ученика и плательщика —
--       иначе пара молча перестанет сходиться. Прямой insert в payments у
--       ролей приложения закрыт (0013), триггер держит postgres/service.
--   Р5. Причина — в отдельной таблице payment_voids (select can_payments,
--       записи только из RPC), а не в payments.comment: comment читает
--       родитель (payments_parent_read, 0013) и правят owner/admin (grant
--       update (comment)). Прецедент — lesson_debt_writeoffs (0087),
--       subscription_shortfall_writeoffs (0090). В comment — нейтральное
--       «Отмена ошибочного платежа».
--   Р6. Событие payment.voided — из RPC (забор 0075), без причины.
-- =============================================================================


-- 1. Ссылка на отменённый платёж (Р1) -------------------------------------------------------------

alter table public.payments
  add column if not exists voids_payment_id uuid;

comment on column public.payments.voids_payment_id is
  'Эта строка — отмена ошибочного платежа voids_payment_id (0093): корректировка на ту же сумму с минусом той же датой. Одна отмена на платёж.';

alter table public.payments drop constraint if exists payments_void_fk;
alter table public.payments add constraint payments_void_fk
  foreign key (voids_payment_id, center_id) references public.payments (id, center_id);

-- Непартиальный unique: «одна отмена на платёж» (центр зафиксирован FK) и
-- покрытие FK (урок 0069); NULL не конфликтуют.
alter table public.payments drop constraint if exists payments_voids_payment_key;
alter table public.payments add constraint payments_voids_payment_key unique (voids_payment_id, center_id);

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
  if tg_op = 'UPDATE' then
    if new.voids_payment_id is distinct from old.voids_payment_id then
      raise exception 'Ссылку отмены платежа менять нельзя' using errcode = '22023';
    end if;
    if (old.voids_payment_id is not null
        or exists (select 1 from public.payments p where p.voids_payment_id = old.id))
       and (new.amount_tiyin, new.kind, new.paid_at, new.source_id, new.student_id, new.payer_id, new.subscription_id)
           is distinct from
           (old.amount_tiyin, old.kind, old.paid_at, old.source_id, old.student_id, old.payer_id, old.subscription_id) then
      raise exception 'Отменённый платёж и его отмену менять нельзя' using errcode = '22023';
    end if;
    return new;
  end if;

  if new.voids_payment_id is null then
    return new;
  end if;

  select * into v_orig from public.payments p
   where p.id = new.voids_payment_id and p.center_id = new.center_id
     for update;
  if v_orig.id is null then
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
     or new.paid_at <> v_orig.paid_at
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
  'Граница 0093: строка с voids_payment_id зеркалит исходное поступление без абонемента (сумма с минусом, та же дата, плательщик, ученик, источник); у пары ничего денежного не меняется.';
revoke all on function public.payments_void_guard() from public, anon, authenticated, service_role;

drop trigger if exists payments_void_guard on public.payments;
create trigger payments_void_guard
  before insert or update on public.payments
  for each row execute function public.payments_void_guard();


-- 3. Причина отмены (Р5) --------------------------------------------------------------------------

create table if not exists public.payment_voids (
  payment_id         uuid primary key,
  center_id          uuid not null default public.current_center()
                       references public.centers (id) on delete cascade,
  voided_payment_id  uuid not null,
  reason             text not null check (length(btrim(reason)) between 1 and 500),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid default auth.uid(),
  -- По конвенции; ни один путь его не ставит — отмена не отменяется.
  deleted_at         timestamptz,

  constraint payment_voids_payment_fk
    foreign key (payment_id, center_id) references public.payments (id, center_id),
  constraint payment_voids_voided_fk
    foreign key (voided_payment_id, center_id) references public.payments (id, center_id)
);
comment on table public.payment_voids is
  'Причина отмены ошибочного платежа (0093 Р5): payment_id — строка отмены, voided_payment_id — исходная. Только void_payment; читает can_payments, родитель — нет.';

-- Непартиальные индексы под составные FK (урок 0069).
create index if not exists payment_voids_payment_idx on public.payment_voids (payment_id, center_id);
create index if not exists payment_voids_voided_idx on public.payment_voids (voided_payment_id, center_id);
create index if not exists payment_voids_center_idx on public.payment_voids (center_id);

drop trigger if exists payment_voids_set_updated_at on public.payment_voids;
create trigger payment_voids_set_updated_at
  before update on public.payment_voids
  for each row execute function extensions.moddatetime(updated_at);

alter table public.payment_voids enable row level security;

drop policy if exists payment_voids_select on public.payment_voids;
create policy payment_voids_select on public.payment_voids
  for select to authenticated
  using (center_id = public.current_center() and public.can_payments());

revoke all on table public.payment_voids from public, anon, authenticated, service_role;
grant select on public.payment_voids to authenticated;

call public.apply_audit('payment_voids');
call public.apply_readonly_guard('payment_voids');

create or replace function public.payment_voids_immutable()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  raise exception 'Причина отмены платежа не меняется и не удаляется' using errcode = '22023';
end;
$$;
revoke all on function public.payment_voids_immutable() from public, anon, authenticated, service_role;

drop trigger if exists payment_voids_immutable on public.payment_voids;
create trigger payment_voids_immutable
  before update or delete on public.payment_voids
  for each row execute function public.payment_voids_immutable();


-- 4. RPC (Р1–Р3, Р5, Р6) --------------------------------------------------------------------------

create or replace function public.void_payment(p_payment_id uuid, p_reason text)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_orig   public.payments;
  v_month  date;
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

  -- Р3: отмена встаёт датой исходного платежа — его месяц должен быть открыт.
  v_month := date_trunc('month', (v_orig.paid_at at time zone public.center_timezone(v_center))::date)::date;
  if exists (select 1 from public.financial_periods fp
              where fp.center_id = v_center and fp.month = v_month and fp.closed_at is not null) then
    raise exception 'Месяц платежа (%) закрыт — переоткройте его во вкладке «Периоды», затем отмените платёж',
      public.ru_month_year(v_month)
      using errcode = '22023';
  end if;

  insert into public.payments (
    center_id, payer_id, student_id, subscription_id, amount_tiyin, source_id,
    paid_at, kind, comment, created_by, covers_lesson_debt, voids_payment_id
  )
  values (
    v_center, v_orig.payer_id, v_orig.student_id, null, -v_orig.amount_tiyin, v_orig.source_id,
    v_orig.paid_at, 'correction', 'Отмена ошибочного платежа', auth.uid(), false, p_payment_id
  )
  returning id into v_id;

  insert into public.payment_voids (payment_id, center_id, voided_payment_id, reason)
  values (v_id, v_center, p_payment_id, btrim(p_reason));

  -- Причина в payload не кладётся: outbox уходит наружу.
  perform public.emit_event('payment.voided', jsonb_build_object('center_id', v_center, 'payment_id', v_id, 'voided_payment_id', p_payment_id, 'amount_tiyin', v_orig.amount_tiyin), v_center);

  return v_id;
end;
$$;
comment on function public.void_payment(uuid, text) is
  'Отменить ошибочное поступление без абонемента (0093): только owner, причина обязательна (payment_voids); пишет корректировку на ту же сумму с минусом той же датой. Исходная строка не меняется.';

revoke all on function public.void_payment(uuid, text) from public, anon;
grant execute on function public.void_payment(uuid, text) to authenticated;


-- 5. Экспорт центра — allow-list 0090 плюс причины отмены -----------------------------------------

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
    ('payment_sources'), ('payment_voids'), ('payments'), ('platform_payments'), ('prosody_assessments'),
    ('reading_writing_assessments'), ('rooms'),
    ('salary_adjustments'), ('salary_runs'), ('services'), ('student_anamnesis'),
    ('student_articulation'), ('student_payers'), ('students'), ('subscription_freezes'),
    ('subscription_shortfall_writeoffs'),
    ('subscription_types'), ('subscriptions'), ('syllable_assessments'), ('teacher_rates'), ('teachers')
$$;
comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. 0087: lesson_debt_writeoffs. 0088: lesson_debt_covers. 0090: subscription_shortfall_writeoffs. 0093: payment_voids. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
