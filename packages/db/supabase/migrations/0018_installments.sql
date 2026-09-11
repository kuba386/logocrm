-- =============================================================================
-- 0018_installments.sql — рассрочка (этап 5, промт п.6) и статус оплаты
-- абонемента (долг промта п.5, не сделанный в 0013/0014)
--
-- Architect-ревью плана: 16 находок, все учтены. Решения, которые НЕ
-- выводятся из промта напрямую:
--
--   Р1. Строка рассрочки НЕ хранит «оплачено» (ни payment_id, ни paid_at).
--       Оплаченность выводится из subscriptions.paid_tiyin: строка k плана
--       оплачена, когда paid_tiyin >= base_paid_tiyin + сумма строк плана с
--       seq <= k. base_paid_tiyin — сколько было оплачено на момент создания
--       плана (аванс до рассрочки: чек-лист «оплата 2 000 + рассрочка
--       2×1 000»); это замороженный факт плана, как price_tiyin при
--       продаже, а не копия, которой есть с чем разойтись. plan_id
--       группирует строки одного плана: после отмены и нового плана их
--       нарастающие итоги не смешиваются. Любой платёж — через рассрочку
--       или мимо неё («Добавить платёж» на /app/finance) — закрывает самые
--       ранние строки сам, возврат сам их открывает (ADR-006; так же
--       lessons_used выведен из attendance, paid_tiyin — из payments).
--       Собственное состояние строки — только cancelled_at и отметки об
--       уведомлениях.
--   Р2. installments ВНЕ financial_period_guard — сознательно. Денежный
--       факт — платёж, он под замком сам; pay_installment зовёт
--       record_payment, и платёж датой в закрытом месяце откатывает всё.
--       Строка рассрочки — график, не факт. Не навешивать триггер «для
--       полноты»: у financial_period_guard ветка else raise 42704 на
--       неизвестной таблице, и вся таблица встанет. Первый платёж плана
--       не может быть в прошлом (находка 9) — это и страховка от «плана,
--       меняющего уже закрытую картину дебиторки».
--   Р3. Планировщика в этапе 5 нет (pg_cron — этап 6, stages.md:195).
--       installments_notify() готова и покрыта тестом, вызывается напрямую;
--       расписание — этап 6. Она и emit_event_unchecked работают ТОЛЬКО без
--       auth.uid() (обратная проверка, паттерн backfill_* 0014:171): живой
--       пользователь получает 42501 независимо от грантов — иначе любой
--       будущий grant открыл бы outbox всех центров (инцидент ADR-002).
--   Р4. Отмена абонемента (status='cancelled' или deleted_at) гасит
--       неоплаченные строки плана ТРИГГЕРОМ на subscriptions, а не правкой
--       refund_subscription/transfer_remaining: любой путь отмены, включая
--       будущие, не оставит живой план на мёртвом абонементе.
--   Р5. Остаток от деления — первым платежам (100000/3 → 33334/33333/33333),
--       зафиксировано зеркалом core/finance.ts::splitInstallments. Платежей
--       больше, чем тыйынов в остатке, — читаемый 22023 в обеих реализациях.
--   Р6. Состояние строки (paid/upcoming/due/overdue/cancelled) считается в
--       ОДНОМ месте — installments_view, от center_today(center_id). Список
--       для вкладки «Рассрочки», уведомления и отмена читают его оттуда;
--       finance.ts::installmentState — зеркало для подрисовки, не источник.
-- =============================================================================


-- 1. installments — график платежей -------------------------------------------

create table if not exists public.installments (
  id              uuid primary key default gen_random_uuid(),
  center_id       uuid not null default public.current_center()
                    references public.centers (id) on delete cascade,
  subscription_id uuid not null,
  student_id      uuid not null,
  -- Плательщик абонемента на момент плана — родителю строка видна по нему.
  payer_id        uuid not null,
  -- Один вызов create_installment_plan = один plan_id (Р1).
  plan_id         uuid not null,
  -- Оплачено на момент создания плана — точка отсчёта нарастающего итога.
  base_paid_tiyin integer not null,
  seq             smallint not null,
  due_date        date not null,
  amount_tiyin    integer not null,
  cancelled_at    timestamptz,
  -- Уведомления — по одному разу на переход; отметка ставится тем же
  -- update, что отбирает строку (installments_notify).
  due_notified_at     timestamptz,
  overdue_notified_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),

  constraint installments_id_center_key unique (id, center_id),
  constraint installments_subscription_fk
    foreign key (subscription_id, student_id, center_id)
    references public.subscriptions (id, student_id, center_id),
  -- «Этот плательщик действительно платит за этого ребёнка» — как у
  -- payments_student_payer_fk (0014): отказ виден при создании плана, а не
  -- через месяц в pay_installment у стойки с деньгами.
  constraint installments_student_payer_fk
    foreign key (student_id, payer_id, center_id)
    references public.student_payers (student_id, payer_id, center_id),
  constraint installments_amount_positive check (amount_tiyin > 0),
  constraint installments_base_not_negative check (base_paid_tiyin >= 0),
  constraint installments_seq_positive check (seq >= 1),
  constraint installments_plan_seq_key unique (plan_id, seq)
);

-- «Один живой план на абонемент» — проверка в create_installment_plan под
-- for update по строке абонемента: второй план ждёт первого и видит его
-- строки. Хранимого инварианта тут нет намеренно: после отмены плана
-- оплаченные строки остаются историей рядом со строками нового плана.

create index if not exists installments_center_idx on public.installments (center_id);
create index if not exists installments_center_due_idx
  on public.installments (center_id, due_date) where cancelled_at is null;
create index if not exists installments_subscription_idx on public.installments (subscription_id);

drop trigger if exists installments_set_updated_at on public.installments;
create trigger installments_set_updated_at before update on public.installments
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('installments', false);
call public.apply_audit('installments');

-- Дословное зеркало payments_parent_read (0013:248-254), включая роль:
-- без coalesce(my_role(),'') = 'parent' область политики определялась бы
-- не родством, а заполненностью memberships.payer_id — и специалист, чей
-- ребёнок ходит в тот же центр, увидел бы график платежей.
drop policy if exists installments_parent_read on public.installments;
create policy installments_parent_read on public.installments
  for select to authenticated
  using (
    center_id = public.current_center()
    and coalesce(public.my_role(), '') = 'parent'
    and (payer_id = public.my_payer_id() or public.parent_of_student(student_id))
  );

-- teacher — ни одной политики: деньги специалисту не показываются (0008:696,
-- 0013:256, 0017 salary_runs).

-- Никакой прямой записи: только RPC ниже и триггеры.
revoke all on public.installments from anon, authenticated;
grant select on public.installments to authenticated;


-- 2. installments_view — состояние строки, посчитанное в SQL --------------------

-- security_invoker: RLS installments и subscriptions работают от вызывающего.
-- Функции внутри вью исполняются от вызывающего же (0010:579) —
-- center_today(uuid) выдана authenticated (0007).
create or replace view public.installments_view
  with (security_invoker = true)
as
select i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id,
       i.plan_id, i.base_paid_tiyin,
       i.seq, i.due_date, i.amount_tiyin, i.cancelled_at,
       i.due_notified_at, i.overdue_notified_at, i.created_at, i.updated_at,
       s.price_tiyin, s.paid_tiyin,
       c.cumulative_tiyin,
       case
         when i.cancelled_at is not null then 'cancelled'
         when s.paid_tiyin >= i.base_paid_tiyin + c.cumulative_tiyin then 'paid'
         when i.due_date > public.center_today(i.center_id) then 'upcoming'
         when i.due_date = public.center_today(i.center_id) then 'due'
         else 'overdue'
       end as state
  from public.installments i
  join public.subscriptions s on s.id = i.subscription_id
  -- Нарастающий итог по живым строкам ЭТОГО плана до этой включительно (Р1).
  join lateral (
    select coalesce(sum(j.amount_tiyin), 0)::integer as cumulative_tiyin
      from public.installments j
     where j.plan_id = i.plan_id
       and j.cancelled_at is null
       and j.seq <= i.seq
  ) c on true;

revoke all on public.installments_view from anon, authenticated;
grant select on public.installments_view to authenticated;


-- 3. emit_event_unchecked — outbox из контекста без пользователя ------------------

-- emit_event (0002) требует auth.uid() и членство — из cron/service_role
-- его не позвать. Отдельная функция, а не insert в events из тела RPC:
-- docs/Database.md держит «emit_event — единственный способ записи».
-- Суффикс _unchecked — как у subscription_state_unchecked (0015): гейт
-- снят, вызывающий отвечает сам. Обратная проверка (Р3): живой пользователь
-- отбивается независимо от грантов.
create or replace function public.emit_event_unchecked(
  p_type      text,
  p_payload   jsonb,
  p_center_id uuid
)
  returns bigint
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_id bigint;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_center_id is null then
    raise exception 'emit_event_unchecked: не определён center_id' using errcode = '22004';
  end if;

  insert into public.events (center_id, type, payload)
  values (p_center_id, p_type, coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.emit_event_unchecked(text, jsonb, uuid) from public, anon, authenticated;


-- 4. create_installment_plan ----------------------------------------------------

create or replace function public.create_installment_plan(
  p_subscription_id uuid,
  p_n               integer,
  p_first_due       date     default null,
  p_step_months     smallint default 1
)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_sub       public.subscriptions;
  v_plan      uuid := gen_random_uuid();
  v_today     date;
  v_first_due date;
  v_remaining integer;
  v_base      integer;
  v_extra     integer;
  i           integer;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_n is null or p_n < 1 or p_n > 24 then
    raise exception 'Число платежей — от 1 до 24' using errcode = '22023';
  end if;
  if p_step_months is null or p_step_months < 1 then
    raise exception 'Шаг рассрочки — целое число месяцев, не меньше одного' using errcode = '22023';
  end if;

  -- for update: остаток считается под блокировкой — параллельный платёж
  -- или второй план ждут и видят итог, а не снимок.
  select * into v_sub from public.subscriptions
   where id = p_subscription_id and center_id = v_center and deleted_at is null
   for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;
  if v_sub.status = 'cancelled' then
    raise exception 'Абонемент отменён — рассрочка невозможна' using errcode = '22023';
  end if;
  -- Живой план = хоть одна неоплаченная строка (по состоянию из вью, одно
  -- определение на всех). Оплаченные строки прошлого плана не мешают.
  if exists (
    select 1 from public.installments_view v
     where v.subscription_id = v_sub.id and v.state in ('upcoming', 'due', 'overdue')
  ) then
    raise exception 'По абонементу уже есть рассрочка — сначала отмените её' using errcode = '22023';
  end if;

  v_remaining := v_sub.price_tiyin - v_sub.paid_tiyin;
  if v_remaining <= 0 then
    raise exception 'Абонемент оплачен — рассрочивать нечего' using errcode = '22023';
  end if;
  -- Иначе хвостовые строки получили бы 0 и упали на installments_amount_
  -- positive с нечитаемым текстом; зеркало finance.ts бросает RangeError.
  if p_n > v_remaining then
    raise exception 'Платежей больше, чем тыйынов в остатке' using errcode = '22023';
  end if;

  v_today     := public.center_today(v_center);
  v_first_due := coalesce(p_first_due, v_today);
  if v_first_due < v_today then
    raise exception 'Первый платёж рассрочки не может быть в прошлом' using errcode = '22023';
  end if;

  -- Остаток от деления — первым платежам (Р5).
  v_base  := v_remaining / p_n;
  v_extra := v_remaining % p_n;

  for i in 1..p_n loop
    insert into public.installments
      (center_id, subscription_id, student_id, payer_id, plan_id, base_paid_tiyin,
       seq, due_date, amount_tiyin, created_by)
    values
      (v_center, v_sub.id, v_sub.student_id, v_sub.payer_id, v_plan, v_sub.paid_tiyin,
       i,
       (v_first_due + make_interval(months => (i - 1) * p_step_months))::date,
       v_base + (case when i <= v_extra then 1 else 0 end),
       auth.uid());
  end loop;

  return p_n;
end;
$$;


-- 5. pay_installment — платёж «по строку k включительно» -------------------------

create or replace function public.pay_installment(
  p_installment_id uuid,
  p_source_id      uuid        default null,
  p_paid_at        timestamptz default now(),
  p_comment        text        default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center     uuid := public.current_center();
  v_inst       public.installments;
  v_sub        public.subscriptions;
  v_cumulative integer;
  v_amount     integer;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_inst from public.installments
   where id = p_installment_id and center_id = v_center
   for update;
  if not found then
    raise exception 'Платёж рассрочки не найден' using errcode = '42704';
  end if;
  if v_inst.cancelled_at is not null then
    raise exception 'Рассрочка отменена' using errcode = '22023';
  end if;

  -- Абонемент под блокировкой: два «Оплатить» подряд не создадут два
  -- платежа — второй дождётся первого, увидит выросший paid_tiyin и
  -- получит 22023. recalc_subscription_paid внутри триггера платежей
  -- берёт ту же строку for update — та же транзакция, не взаимоблокировка.
  select * into v_sub from public.subscriptions
   where id = v_inst.subscription_id
   for update;
  if v_sub.deleted_at is not null or v_sub.status = 'cancelled' then
    raise exception 'Абонемент отменён — платёж по рассрочке невозможен' using errcode = '22023';
  end if;

  select coalesce(sum(x.amount_tiyin), 0) into v_cumulative
    from public.installments x
   where x.plan_id = v_inst.plan_id
     and x.cancelled_at is null
     and x.seq <= v_inst.seq;

  -- Сколько не хватает до порога этой строки (Р1: base + нарастающий итог
  -- плана): свободный платёж мимо плана уже мог закрыть часть — доплата
  -- только разница.
  v_amount := v_inst.base_paid_tiyin + v_cumulative - v_sub.paid_tiyin;
  if v_amount <= 0 then
    raise exception 'Этот платёж рассрочки уже оплачен' using errcode = '22023';
  end if;

  -- record_payment: свой ролевой чек, paid_tiyin штатным триггером,
  -- payment.received штатно, замок месяца на payments штатно — при
  -- p_paid_at в закрытом месяце откатывается вся транзакция.
  return public.record_payment(
    v_inst.payer_id, v_amount, 'payment', v_inst.student_id,
    v_inst.subscription_id, p_source_id, p_paid_at, p_comment
  );
end;
$$;


-- 6. Отмена плана: RPC и триггер на subscriptions --------------------------------

-- Общее ядро: гасит неоплаченные живые строки (по состоянию из вью — одно
-- определение «оплачено» на всех). Закрыта для всех ролей: зовётся только
-- из cancel_installment_plan (с ролевым чеком) и из триггера.
create or replace function public.installments_cancel_unpaid(p_subscription_id uuid)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.installments i
     set cancelled_at = now()
   where i.id in (
     select v.id from public.installments_view v
      where v.subscription_id = p_subscription_id
        and v.state in ('upcoming', 'due', 'overdue')
   );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.installments_cancel_unpaid(uuid) from public, anon, authenticated;

create or replace function public.cancel_installment_plan(p_subscription_id uuid)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_count  integer;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.subscriptions s
     where s.id = p_subscription_id and s.center_id = v_center and s.deleted_at is null
  ) then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  v_count := public.installments_cancel_unpaid(p_subscription_id);
  if v_count = 0 then
    raise exception 'По абонементу нет неоплаченных платежей рассрочки' using errcode = '22023';
  end if;
  return v_count;
end;
$$;

-- Р4: отмена или мягкое удаление абонемента гасит его план любым путём —
-- refund_subscription, transfer_remaining, будущие RPC. Оплаченные строки
-- остаются историей.
create or replace function public.subscriptions_cancel_installments()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if (new.status = 'cancelled' and old.status is distinct from 'cancelled')
     or (new.deleted_at is not null and old.deleted_at is null) then
    perform public.installments_cancel_unpaid(new.id);
  end if;
  return new;
end;
$$;

revoke all on function public.subscriptions_cancel_installments() from public, anon, authenticated;

drop trigger if exists subscriptions_cancel_installments on public.subscriptions;
create trigger subscriptions_cancel_installments
  after update of status, deleted_at on public.subscriptions
  for each row execute function public.subscriptions_cancel_installments();


-- 7. installments_notify — installment.due / installment.overdue -----------------

-- Р3: только без auth.uid() (cron/service_role, этап 6). Отметка и есть
-- блокировка: update ... returning — параллельный запуск дождётся первого и
-- получит 0 строк, двойных сообщений родителю не будет. Абонемент отменён/
-- удалён или ученик в архиве (students.status = 'archived') — не уведомляем
-- (в интерфейсе строки уже нет).
create or replace function public.installments_notify()
  returns table (due_count integer, overdue_count integer)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_due     integer := 0;
  v_overdue integer := 0;
  r         record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    update public.installments i
       set due_notified_at = now()
      from public.installments_view v
      join public.subscriptions s on s.id = v.subscription_id
      join public.students st on st.id = v.student_id
     where i.id = v.id
       and v.state = 'due'
       and i.due_notified_at is null
       and s.deleted_at is null and s.status <> 'cancelled'
       -- Архив ученика — status = 'archived' (archive_student, 0011), не
       -- deleted_at: первый прогон CI слал due по архивному ребёнку.
       and st.deleted_at is null and st.status <> 'archived'
     returning i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id,
               i.seq, i.due_date, i.amount_tiyin
  loop
    perform public.emit_event_unchecked('installment.due',
      jsonb_build_object(
        'center_id', r.center_id, 'installment_id', r.id,
        'subscription_id', r.subscription_id, 'student_id', r.student_id,
        'payer_id', r.payer_id, 'seq', r.seq, 'due_date', r.due_date,
        'amount_tiyin', r.amount_tiyin
      ),
      r.center_id);
    v_due := v_due + 1;
  end loop;

  for r in
    update public.installments i
       set overdue_notified_at = now()
      from public.installments_view v
      join public.subscriptions s on s.id = v.subscription_id
      join public.students st on st.id = v.student_id
     where i.id = v.id
       and v.state = 'overdue'
       and i.overdue_notified_at is null
       and s.deleted_at is null and s.status <> 'cancelled'
       -- Архив ученика — status = 'archived' (archive_student, 0011), не
       -- deleted_at: первый прогон CI слал due по архивному ребёнку.
       and st.deleted_at is null and st.status <> 'archived'
     returning i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id,
               i.seq, i.due_date, i.amount_tiyin
  loop
    perform public.emit_event_unchecked('installment.overdue',
      jsonb_build_object(
        'center_id', r.center_id, 'installment_id', r.id,
        'subscription_id', r.subscription_id, 'student_id', r.student_id,
        'payer_id', r.payer_id, 'seq', r.seq, 'due_date', r.due_date,
        'amount_tiyin', r.amount_tiyin
      ),
      r.center_id);
    v_overdue := v_overdue + 1;
  end loop;

  return query select v_due, v_overdue;
end;
$$;

revoke all on function public.installments_notify() from public, anon, authenticated;


-- 8. subscription_payment_summary — статус оплаты абонемента (промт п.5) ---------

-- Новая функция, не расширение subscription_summary: смена returns table
-- требует drop function и повторных грантов. Видимость — через
-- subscription_visible_to_caller (0015): auth, центр, роль, deleted_at,
-- родитель — одним вызовом; teacher и чужой центр получают 42704, не данные.
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
    -- Бесплатный (цена 0) — оплачен: платить нечего, это не долг. Зеркало
    -- finance.ts::paymentState.
    case
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


-- Гранты -------------------------------------------------------------------------

revoke execute on function
  public.create_installment_plan(uuid, integer, date, smallint),
  public.pay_installment(uuid, uuid, timestamptz, text),
  public.cancel_installment_plan(uuid),
  public.subscription_payment_summary(uuid)
  from public, anon, authenticated;

grant execute on function
  public.create_installment_plan(uuid, integer, date, smallint),
  public.pay_installment(uuid, uuid, timestamptz, text),
  public.cancel_installment_plan(uuid),
  public.subscription_payment_summary(uuid)
  to authenticated;
