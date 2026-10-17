-- =============================================================================
-- 0102_cash_balances.sql — остатки касс и сверка кассы
--
-- Решение владельца 17.10.2026 («сделай остатки касс и сверку кассы»); в 0101
-- Р10 отложено: без начального остатка накопительный итог — мусор.
--
-- Решения (architect-ревью плана: 1 блокер, 8 важных — учтены):
--   Р1. Сверка — якорь. Остаток кассы S на конец дня D = посчитано на последней
--       неотменённой сверке S с днём ≤ D + движения S «после неё» по день D.
--       Без сверки — Σ всех движений S. Первая сверка — начальный остаток.
--   Р2. «После сверки» (Б1): день движения позже дня сверки, ЛИБО тот же день и
--       движение внесено в тот же день центра позже момента сверки
--       (created_at > counted_at). counted_at = clock_timestamp() после
--       advisory-блокировки, не now(): порядок двух сверок — порядок блокировки.
--       Внесённое позже задним числом датой ≤ дня сверки считается «до» неё —
--       пересчитанные деньги — правда. Одна копия правила — cash_after_count.
--   Р3. Расхождение считается при чтении (В1): d_k = посчитано_k − (предыдущий
--       якорь + движения между сверками по текущим данным). Тогда всегда
--       остаток на конец = остаток на начало + обороты + поправка начального
--       остатка + Σ расхождений сверок месяца, и при движениях задним числом,
--       и при void_payment/void_expense. expected_tiyin в строке — «что видел
--       кассир»: для аудита и сверки 23514.
--   Р4. Первая неотменённая сверка кассы — «начальный остаток» (В2), признак
--       выводится, а не хранится; в отчёте отдельной колонкой, в расхождения
--       не входит.
--   Р5. Ошибочная сверка отменяется (В3): только owner, причина обязательна,
--       однократный переход cancelled_at null → значение, остальное
--       неизменяемо триггером. Отменённую сверку формула не видит.
--   Р6. Деньги без кассы в остатки не входят; в отчёте — строка «без кассы» с
--       оборотами, чтобы сумма сходилась с cash_by_source (В4). Требование
--       кассы для живых денег — в вебе; в базе не вводится (корректировки без
--       кассы — штатный путь 0091, старые строки).
--   Р7. Движения — одна функция cash_movements_unchecked (В5); обороты отчёта
--       классифицируются как в cash_by_source, pgTAP сверяет их построчно.
--   Р8. Касса своего центра в каждой ветке и в каждой RPC (В6). Суммы — bigint
--       (В7). Границы суток — один раз в timestamptz, сравнение по paid_at
--       идёт по индексам (center_id, paid_at) (В8).
--   Р9. Сверяет can_finance (owner/admin/finance): остаток раскрывает расходы и
--       выплаты, стойка их не читает. Отмена — owner.
--   Р10. Переоткрытие месяца меняет остатки и расхождения более поздних
--        месяцев — остаток переносится; «закрытый месяц неизменен» для вкладки
--        «Касса» неверно. Параллельный сверке платёж правило Р2 относит к одной
--        из сторон; динамическое расхождение это выправляет само.
-- =============================================================================


-- 1. Таблица сверок (Р1, Р5) ------------------------------------------------------------------

create table if not exists public.cash_counts (
  id               uuid primary key default gen_random_uuid(),
  center_id        uuid not null default public.current_center()
                     references public.centers (id) on delete cascade,
  source_id        uuid not null,
  counted_on       date not null,
  -- Момент сверки (Р2): clock_timestamp() после блокировки, ставит только RPC.
  counted_at       timestamptz not null,
  counted_tiyin    bigint not null,
  -- Остаток по учёту на момент сверки — что видел кассир (Р3). Расхождение —
  -- только при чтении: снимок разошёлся бы с учётом после движений задним числом.
  expected_tiyin   bigint not null,
  comment          text,
  count_key        uuid not null,
  cancelled_at     timestamptz,
  cancelled_by     uuid,
  cancel_reason    text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),

  constraint cash_counts_id_center_key unique (id, center_id),
  constraint cash_counts_count_key unique (center_id, count_key),
  constraint cash_counts_source_fk
    foreign key (source_id, center_id) references public.payment_sources (id, center_id),
  constraint cash_counts_counted_not_negative check (counted_tiyin >= 0),
  constraint cash_counts_comment_length check (comment is null or length(comment) <= 500),
  constraint cash_counts_cancel_shape check (
    (cancelled_at is null and cancelled_by is null and cancel_reason is null)
    or (cancelled_at is not null and cancel_reason is not null and length(btrim(cancel_reason)) between 1 and 500)
  )
);
comment on table public.cash_counts is
  'Сверка кассы (0102): посчитано по кассе на момент counted_at дня counted_on — якорь остатка. Неизменяема, кроме однократной отмены владельцем. Пишут только RPC, читает can_finance.';

create index if not exists cash_counts_center_source_idx on public.cash_counts (center_id, source_id, counted_on);
create index if not exists cash_counts_source_idx on public.cash_counts (source_id, center_id);

drop trigger if exists cash_counts_set_updated_at on public.cash_counts;
create trigger cash_counts_set_updated_at
  before update on public.cash_counts
  for each row execute function extensions.moddatetime(updated_at);

alter table public.cash_counts enable row level security;

-- Только чтение финансовым ролям своего центра; apply_tenant_rls/apply_role_rls
-- не зовутся: for all открыл бы запись, tenant_finance_select уронил бы забор 0031.
drop policy if exists cash_counts_select on public.cash_counts;
create policy cash_counts_select on public.cash_counts
  for select to authenticated
  using (center_id = public.current_center() and public.can_finance());

revoke all on table public.cash_counts from public, anon, authenticated, service_role;
grant select on public.cash_counts to authenticated;

call public.apply_audit('cash_counts');
call public.apply_readonly_guard('cash_counts');

create or replace function public.cash_counts_immutable()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Сверка кассы не удаляется — ошибочную отменяет владелец' using errcode = '22023';
  end if;
  if old.cancelled_at is not null then
    raise exception 'Отменённая сверка неизменяема' using errcode = '22023';
  end if;
  if new.cancelled_at is null then
    raise exception 'Сверка кассы неизменяема — ошибочную отменяет владелец' using errcode = '22023';
  end if;
  -- Вся строка минус колонки отмены и служебный updated_at — не белый список:
  -- колонка будущей миграции защищена по умолчанию.
  if (to_jsonb(new) - array['cancelled_at', 'cancelled_by', 'cancel_reason', 'updated_at'])
     is distinct from (to_jsonb(old) - array['cancelled_at', 'cancelled_by', 'cancel_reason', 'updated_at']) then
    raise exception 'У сверки меняется только отметка отмены' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function public.cash_counts_immutable() from public, anon, authenticated, service_role;

drop trigger if exists cash_counts_immutable on public.cash_counts;
create trigger cash_counts_immutable
  before update or delete on public.cash_counts
  for each row execute function public.cash_counts_immutable();


-- 2. Замок месяца: ветка cash_counts (тело из 0101) -------------------------------------------

-- из 0101_finance_ops.sql; добавлена только ветка cash_counts
create or replace function public.financial_period_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid;
  v_old_date date;
  v_new_date date;
  v_blocked  date;
begin
  if tg_op = 'DELETE' then
    v_center := old.center_id;
  else
    v_center := new.center_id;
  end if;

  if tg_table_name = 'payments' then
    if tg_op <> 'DELETE' then
      v_new_date := (new.paid_at at time zone public.center_timezone(v_center))::date;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := (old.paid_at at time zone public.center_timezone(v_center))::date;
    end if;

  elsif tg_table_name = 'expenses' then
    if tg_op <> 'DELETE' then
      v_new_date := (new.paid_at at time zone public.center_timezone(v_center))::date;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := (old.paid_at at time zone public.center_timezone(v_center))::date;
    end if;

  elsif tg_table_name = 'cash_transfers' then
    if tg_op <> 'DELETE' then
      v_new_date := (new.transferred_at at time zone public.center_timezone(v_center))::date;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := (old.transferred_at at time zone public.center_timezone(v_center))::date;
    end if;

  elsif tg_table_name = 'cash_counts' then
    -- 0102: сверка датой закрытого месяца — ни новая, ни отмена.
    if tg_op <> 'DELETE' then
      v_new_date := new.counted_on;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := old.counted_on;
    end if;

  elsif tg_table_name = 'salary_adjustments' then
    if tg_op <> 'DELETE' then
      v_new_date := new.month;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := old.month;
    end if;

  elsif tg_table_name = 'teacher_rates' then
    -- Только insert: у teacher_rates нет update/delete гранта, old не бывает.
    -- valid_from — произвольный день, до месяца его доводит общий
    -- date_trunc в сравнении ниже, как и у остальных веток.
    v_new_date := new.valid_from;

  elsif tg_table_name = 'attendance' then
    if tg_op <> 'DELETE' then
      select (l.starts_at at time zone public.center_timezone(v_center))::date into v_new_date
        from public.lessons l where l.id = new.lesson_id;
    end if;
    if tg_op <> 'INSERT' then
      select (l.starts_at at time zone public.center_timezone(v_center))::date into v_old_date
        from public.lessons l where l.id = old.lesson_id;
    end if;

  elsif tg_table_name = 'lessons' then
    if tg_op <> 'DELETE' then
      v_new_date := (new.starts_at at time zone public.center_timezone(v_center))::date;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := (old.starts_at at time zone public.center_timezone(v_center))::date;
    end if;

  else
    raise exception 'financial_period_guard: неизвестная таблица %', tg_table_name
      using errcode = '42704';
  end if;

  if v_new_date is not null and exists (
       select 1 from public.financial_periods fp
        where fp.center_id = v_center
          and fp.month = date_trunc('month', v_new_date)::date
          and fp.closed_at is not null
     ) then
    v_blocked := v_new_date;
  elsif v_old_date is not null and exists (
       select 1 from public.financial_periods fp
        where fp.center_id = v_center
          and fp.month = date_trunc('month', v_old_date)::date
          and fp.closed_at is not null
     ) then
    v_blocked := v_old_date;
  end if;

  if v_blocked is not null then
    raise exception 'Месяц % закрыт — операции с этой датой запрещены', public.ru_month_year(v_blocked)
      using errcode = '22023';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.financial_period_guard() from public, anon, authenticated;

drop trigger if exists financial_period_guard_cash_counts on public.cash_counts;
create trigger financial_period_guard_cash_counts
  before insert or update or delete on public.cash_counts
  for each row execute function public.financial_period_guard();


-- 3. Движения и правило «после сверки» (Р2, Р7) ------------------------------------------------

-- Все движения денег центра с моментом до p_until: знак — «в кассу +».
create or replace function public.cash_movements_unchecked(p_center_id uuid, p_until timestamptz)
  returns table (
    source_id  uuid,
    src        text,
    kind       text,
    delta      bigint,
    at         timestamptz,
    created_at timestamptz
  )
  language sql
  stable
  set search_path = ''
as $$
  select p.source_id, 'payment'::text, p.kind, p.amount_tiyin::bigint, p.paid_at, p.created_at
    from public.payments p
   where p.center_id = p_center_id and p.paid_at < p_until
  union all
  select e.source_id, 'expense', e.kind, -(e.amount_tiyin::bigint), e.paid_at, e.created_at
    from public.expenses e
   where e.center_id = p_center_id and e.paid_at < p_until
  union all
  select ct.from_source_id, 'transfer', 'transfer_out', -(ct.amount_tiyin::bigint), ct.transferred_at, ct.created_at
    from public.cash_transfers ct
   where ct.center_id = p_center_id and ct.transferred_at < p_until
  union all
  select ct.to_source_id, 'transfer', 'transfer_in', ct.amount_tiyin::bigint, ct.transferred_at, ct.created_at
    from public.cash_transfers ct
   where ct.center_id = p_center_id and ct.transferred_at < p_until;
$$;
comment on function public.cash_movements_unchecked(uuid, timestamptz) is
  'Движения денег центра до момента (0102 Р7): платежи (+), расходы (−), переводы (две ноги). Одна копия для остатков, расхождений и оборотов. Без сессии и без грантов.';
revoke all on function public.cash_movements_unchecked(uuid, timestamptz) from public, anon, authenticated, service_role;

-- Движение «после» сверки (Р2): позже дня сверки, либо в её день и внесено в
-- тот же день после момента сверки. p_day_start/p_day_end — границы дня сверки.
create or replace function public.cash_after_count(
  p_at timestamptz, p_created_at timestamptz,
  p_counted_at timestamptz, p_day_start timestamptz, p_day_end timestamptz
)
  returns boolean
  language sql
  immutable
  set search_path = ''
as $$
  select p_at >= p_day_end
      or (p_at >= p_day_start and p_created_at > p_counted_at and p_created_at < p_day_end);
$$;
revoke all on function public.cash_after_count(timestamptz, timestamptz, timestamptz, timestamptz, timestamptz)
  from public, anon, authenticated, service_role;


-- 4. Сверки с расхождением при чтении и остатки (Р3, Р4) ----------------------------------------

-- Неотменённые сверки центра (или одной кассы) с предыдущим якорем, ожидаемым
-- по текущим данным и расхождением. p_center_id — current_center вызывающего.
create or replace function public.cash_count_diffs_unchecked(p_center_id uuid, p_source_id uuid default null)
  returns table (
    count_id         uuid,
    source_id        uuid,
    counted_on       date,
    counted_at       timestamptz,
    counted_tiyin    bigint,
    expected_tiyin   bigint,
    difference_tiyin bigint,
    is_opening       boolean
  )
  language sql
  stable
  set search_path = ''
as $$
  with tz as (
    select public.center_timezone(p_center_id) as name
  ),
  k as (
    select c.id, c.source_id, c.counted_on, c.counted_at, c.counted_tiyin,
           (c.counted_on::timestamp at time zone tz.name)       as day_start,
           ((c.counted_on + 1)::timestamp at time zone tz.name) as day_end
      from public.cash_counts c
      cross join tz
     where c.center_id = p_center_id
       and c.cancelled_at is null
       and (p_source_id is null or c.source_id = p_source_id)
  ),
  kp as (
    select k.*, prev.counted_tiyin as prev_counted, prev.counted_at as prev_counted_at,
           prev.day_start as prev_day_start, prev.day_end as prev_day_end
      from k
      left join lateral (
        select p.counted_tiyin, p.counted_at, p.day_start, p.day_end
          from k p
         where p.source_id = k.source_id
           and (p.counted_on, p.counted_at) < (k.counted_on, k.counted_at)
         order by p.counted_on desc, p.counted_at desc
         limit 1
      ) prev on true
  )
  select kp.id, kp.source_id, kp.counted_on, kp.counted_at, kp.counted_tiyin,
         e.expected,
         kp.counted_tiyin - e.expected,
         kp.prev_counted_at is null
    from kp
    cross join lateral (
      select coalesce(kp.prev_counted, 0) + coalesce(sum(m.delta), 0) as expected
        from public.cash_movements_unchecked(p_center_id, kp.day_end) m
       where m.source_id = kp.source_id
         and (kp.prev_counted_at is null
              or public.cash_after_count(m.at, m.created_at, kp.prev_counted_at, kp.prev_day_start, kp.prev_day_end))
         and not public.cash_after_count(m.at, m.created_at, kp.counted_at, kp.day_start, kp.day_end)
    ) e;
$$;
comment on function public.cash_count_diffs_unchecked(uuid, uuid) is
  'Неотменённые сверки с ожидаемым по текущим данным и расхождением (0102 Р3); is_opening — первая сверка кассы, начальный остаток (Р4). Без сессии и без грантов.';
revoke all on function public.cash_count_diffs_unchecked(uuid, uuid) from public, anon, authenticated, service_role;

-- Остаток каждой кассы центра на конец дня p_day (Р1); для сегодняшнего дня — на сейчас.
create or replace function public.cash_balances_unchecked(p_center_id uuid, p_day date)
  returns table (
    source_id     uuid,
    balance_tiyin bigint,
    anchor_on     date,
    verified      boolean
  )
  language sql
  stable
  set search_path = ''
as $$
  with tz as (
    select public.center_timezone(p_center_id) as name
  ),
  b as (
    select ((p_day + 1)::timestamp at time zone tz.name) as day_end from tz
  ),
  src as (
    select ps.id from public.payment_sources ps where ps.center_id = p_center_id
  ),
  anchor as (
    select distinct on (c.source_id)
           c.source_id, c.counted_on, c.counted_at, c.counted_tiyin,
           (c.counted_on::timestamp at time zone tz.name)       as day_start,
           ((c.counted_on + 1)::timestamp at time zone tz.name) as day_end
      from public.cash_counts c
      cross join tz
     where c.center_id = p_center_id and c.cancelled_at is null and c.counted_on <= p_day
     order by c.source_id, c.counted_on desc, c.counted_at desc
  ),
  mv as (
    select m.source_id, m.delta, m.at, m.created_at
      from b, public.cash_movements_unchecked(p_center_id, b.day_end) m
     where m.source_id is not null
  )
  select s.id,
         coalesce(a.counted_tiyin, 0)
           + coalesce((select sum(mv.delta) from mv
                        where mv.source_id = s.id
                          and (a.source_id is null
                               or public.cash_after_count(mv.at, mv.created_at, a.counted_at, a.day_start, a.day_end))), 0),
         a.counted_on,
         a.source_id is not null
    from src s
    left join anchor a on a.source_id = s.id;
$$;
comment on function public.cash_balances_unchecked(uuid, date) is
  'Остаток каждой кассы центра на конец дня (0102 Р1): последняя неотменённая сверка ≤ дня плюс движения после неё; без сверки — все движения. Без сессии и без грантов.';
revoke all on function public.cash_balances_unchecked(uuid, date) from public, anon, authenticated, service_role;


-- 5. RPC (Р9) ---------------------------------------------------------------------------------

create or replace function public.cash_count_preview(p_source_id uuid, p_day date default null)
  returns table (day date, expected_tiyin bigint, last_count_on date, today date)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_today  date;
  v_day    date;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_source_id is null or not exists (
       select 1 from public.payment_sources ps where ps.id = p_source_id and ps.center_id = v_center
     ) then
    raise exception 'Касса не найдена' using errcode = '42704';
  end if;
  v_today := public.center_today(v_center);
  v_day := coalesce(p_day, v_today);
  if v_day > v_today then
    raise exception 'Дата сверки не может быть в будущем' using errcode = '22023';
  end if;

  return query
    select v_day,
           coalesce((select b.balance_tiyin from public.cash_balances_unchecked(v_center, v_day) b
                      where b.source_id = p_source_id), 0),
           (select max(c.counted_on) from public.cash_counts c
             where c.center_id = v_center and c.source_id = p_source_id and c.cancelled_at is null),
           v_today;
end;
$$;
comment on function public.cash_count_preview(uuid, date) is
  'Предпросмотр сверки (0102): остаток кассы по учёту на конец дня (сегодня — на сейчас), дата последней сверки, сегодня по центру. can_finance.';
revoke all on function public.cash_count_preview(uuid, date) from public, anon;
grant execute on function public.cash_count_preview(uuid, date) to authenticated;


create or replace function public.record_cash_count(
  p_source_id      uuid,
  p_counted_on     date,
  p_counted_tiyin  bigint,
  p_expected_tiyin bigint,
  p_count_key      uuid,
  p_comment        text default null
)
  returns table (count_id uuid, difference_tiyin bigint, is_opening boolean)
  language plpgsql
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
declare
  v_center   uuid := public.current_center();
  v_today    date;
  v_last     date;
  v_expected bigint;
  v_opening  boolean;
  v_id       uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_counted_tiyin is null or p_counted_tiyin < 0 then
    raise exception 'Укажите, сколько посчитали: сумма не может быть отрицательной' using errcode = '22023';
  end if;
  if p_expected_tiyin is null then
    raise exception 'Обновите страницу: остаток по учёту не передан' using errcode = '22023';
  end if;
  if p_count_key is null then
    raise exception 'Обновите страницу и повторите сверку' using errcode = '22023';
  end if;
  if p_comment is not null and length(btrim(p_comment)) > 500 then
    raise exception 'Комментарий — не длиннее 500 символов' using errcode = '22023';
  end if;
  -- Архивную кассу сверить можно — зафиксировать ноль при закрытии счёта.
  if p_source_id is null or not exists (
       select 1 from public.payment_sources ps where ps.id = p_source_id and ps.center_id = v_center
     ) then
    raise exception 'Касса не найдена' using errcode = '42704';
  end if;

  v_today := public.center_today(v_center);
  if p_counted_on is null or p_counted_on > v_today then
    raise exception 'Дата сверки не может быть в будущем' using errcode = '22023';
  end if;
  if p_counted_on < v_today - interval '1 year' then
    raise exception 'Дата сверки старше года — проверьте год' using errcode = '22023';
  end if;
  if exists (select 1 from public.financial_periods fp
              where fp.center_id = v_center and fp.month = date_trunc('month', p_counted_on)::date
                and fp.closed_at is not null) then
    raise exception 'Месяц % закрыт — переоткройте его во вкладке «Периоды», затем сверяйте',
      public.ru_month_year(p_counted_on) using errcode = '22023';
  end if;

  -- Ключ — раньше сверки суммы: повтор после потерянного ответа не должен получить 23514.
  perform pg_advisory_xact_lock(hashtextextended('cash_count_key:' || p_count_key::text, 0));
  if exists (select 1 from public.cash_counts c where c.center_id = v_center and c.count_key = p_count_key) then
    raise exception 'Эта сверка уже сохранена — обновите страницу' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('cash_count_source:' || p_source_id::text, 0));

  select max(c.counted_on) into v_last
    from public.cash_counts c
   where c.center_id = v_center and c.source_id = p_source_id and c.cancelled_at is null;
  if v_last is not null and v_last > p_counted_on then
    raise exception 'Есть более поздняя сверка этой кассы (%) — сверяйте не раньше неё', to_char(v_last, 'DD.MM.YYYY')
      using errcode = '22023';
  end if;
  v_opening := v_last is null;

  -- Пересчёт под блокировкой, отдельным оператором — видит закоммиченное к этому моменту.
  select coalesce(max(b.balance_tiyin), 0) into v_expected
    from public.cash_balances_unchecked(v_center, p_counted_on) b
   where b.source_id = p_source_id;
  if v_expected is distinct from p_expected_tiyin then
    raise exception 'Остаток по учёту изменился, пока открывали форму: сейчас %. Проверьте и сверьте ещё раз.',
      public.format_som(v_expected) using errcode = '23514';
  end if;

  insert into public.cash_counts (
    center_id, source_id, counted_on, counted_at, counted_tiyin, expected_tiyin, comment, count_key, created_by
  )
  values (
    v_center, p_source_id, p_counted_on, clock_timestamp(), p_counted_tiyin, v_expected,
    nullif(btrim(p_comment), ''), p_count_key, auth.uid()
  )
  returning id into v_id;

  return query select v_id, p_counted_tiyin - v_expected, v_opening;
end;
$$;
comment on function public.record_cash_count(uuid, date, bigint, bigint, uuid, text) is
  'Сверка кассы (0102): can_finance; касса своя (архивная — можно); день не в будущем и не раньше последней сверки; ключ идемпотентности; остаток по учёту пересчитывается под блокировкой кассы и сверяется с p_expected (23514). Возвращает расхождение и признак начального остатка.';
revoke all on function public.record_cash_count(uuid, date, bigint, bigint, uuid, text) from public, anon;
grant execute on function public.record_cash_count(uuid, date, bigint, bigint, uuid, text) to authenticated;


create or replace function public.cancel_cash_count(p_count_id uuid, p_reason text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_row    public.cash_counts;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.role_in(v_center), '') <> 'owner' then
    raise exception 'Отменить сверку может только владелец центра' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Укажите причину отмены' using errcode = '22023';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'Причина — не длиннее 500 символов' using errcode = '22023';
  end if;

  select * into v_row from public.cash_counts c
   where c.id = p_count_id and c.center_id = v_center
     for update;
  if not found then
    raise exception 'Сверка не найдена' using errcode = '42704';
  end if;
  if v_row.cancelled_at is not null then
    raise exception 'Сверка уже отменена' using errcode = '22023';
  end if;
  if exists (select 1 from public.financial_periods fp
              where fp.center_id = v_center and fp.month = date_trunc('month', v_row.counted_on)::date
                and fp.closed_at is not null) then
    raise exception 'Месяц сверки (%) закрыт — переоткройте его во вкладке «Периоды», затем отмените сверку',
      public.ru_month_year(v_row.counted_on) using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('cash_count_source:' || v_row.source_id::text, 0));

  update public.cash_counts
     set cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = btrim(p_reason)
   where id = p_count_id;
end;
$$;
comment on function public.cancel_cash_count(uuid, text) is
  'Отмена ошибочной сверки (0102 Р5): только owner, причина обязательна, месяц открыт. Отменённую сверку формула остатка не видит.';
revoke all on function public.cancel_cash_count(uuid, text) from public, anon;
grant execute on function public.cancel_cash_count(uuid, text) to authenticated;


-- Сверки месяца для списка: что видел кассир и расхождение по текущим данным.
create or replace function public.cash_counts_list(p_month date)
  returns table (
    count_id             uuid,
    source_id            uuid,
    counted_on           date,
    counted_tiyin        bigint,
    expected_at_count    bigint,
    expected_tiyin       bigint,
    difference_tiyin     bigint,
    is_opening           boolean,
    comment              text,
    counted_by_name      text,
    counted_by_role      text,
    cancelled_at         timestamptz,
    cancel_reason        text
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
declare
  v_center uuid := public.current_center();
  v_month  date;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_month is null then
    raise exception 'Укажите месяц' using errcode = '22023';
  end if;
  v_month := date_trunc('month', p_month)::date;

  return query
    select c.id, c.source_id, c.counted_on, c.counted_tiyin, c.expected_tiyin,
           d.expected_tiyin, d.difference_tiyin, coalesce(d.is_opening, false),
           c.comment, tch.full_name, m.role, c.cancelled_at, c.cancel_reason
      from public.cash_counts c
      left join public.cash_count_diffs_unchecked(v_center) d on d.count_id = c.id
      left join public.memberships m on m.user_id = c.created_by and m.center_id = c.center_id
      left join public.teachers tch on tch.id = m.teacher_id and tch.deleted_at is null
     where c.center_id = v_center
       and c.counted_on >= v_month and c.counted_on < (v_month + interval '1 month')::date
     order by c.counted_on desc, c.counted_at desc;
end;
$$;
comment on function public.cash_counts_list(date) is
  'Сверки месяца (0102): посчитано, что видел кассир, ожидаемое и расхождение по текущим данным, начальный остаток, автор (имя карточки и роль, без email), отмена. can_finance.';
revoke all on function public.cash_counts_list(date) from public, anon;
grant execute on function public.cash_counts_list(date) to authenticated;


-- Касса за месяц: остаток на начало и конец, обороты, расхождения (Р3, Р4, Р6).
create or replace function public.cash_report(p_month date)
  returns table (
    source_id                uuid,
    opening_tiyin            bigint,
    received_tiyin           bigint,
    refunded_tiyin           bigint,
    corrections_tiyin        bigint,
    spent_tiyin              bigint,
    transfers_in_tiyin       bigint,
    transfers_out_tiyin      bigint,
    other_tiyin              bigint,
    turnover_tiyin           bigint,
    opening_adjustment_tiyin bigint,
    counts_difference_tiyin  bigint,
    closing_tiyin            bigint,
    opening_verified         boolean,
    closing_verified         boolean,
    last_count_on            date
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
declare
  v_center uuid := public.current_center();
  v_tz     text;
  v_today  date;
  v_first  date;
  v_last   date;
  v_start  timestamptz;
  v_end    timestamptz;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  v_today := public.center_today(v_center);
  if p_month is null or date_trunc('month', p_month)::date > date_trunc('month', v_today)::date then
    raise exception 'Месяц — не позже текущего' using errcode = '22023';
  end if;
  v_tz    := public.center_timezone(v_center);
  v_first := date_trunc('month', p_month)::date;
  v_last  := least((v_first + interval '1 month' - interval '1 day')::date, v_today);
  v_start := v_first::timestamp at time zone v_tz;
  v_end   := (v_last + 1)::timestamp at time zone v_tz;

  return query
  with mv as (
    select m.source_id, m.src, m.kind, m.delta
      from public.cash_movements_unchecked(v_center, v_end) m
     where m.at >= v_start
  ),
  turn as (
    select mv.source_id,
           coalesce(sum(mv.delta) filter (where mv.src = 'payment' and mv.kind = 'payment'), 0)::bigint    as received,
           coalesce(sum(mv.delta) filter (where mv.src = 'payment' and mv.kind = 'refund'), 0)::bigint     as refunded,
           coalesce(sum(mv.delta) filter (where mv.src = 'payment' and mv.kind = 'correction'), 0)::bigint as corrections,
           coalesce(sum(mv.delta) filter (where mv.src = 'expense'
                                            and mv.kind in ('expense', 'refund', 'correction')), 0)::bigint as spent,
           coalesce(sum(mv.delta) filter (where mv.src = 'transfer' and mv.kind = 'transfer_in'), 0)::bigint  as t_in,
           coalesce(sum(mv.delta) filter (where mv.src = 'transfer' and mv.kind = 'transfer_out'), 0)::bigint as t_out,
           coalesce(sum(mv.delta) filter (where (mv.src = 'payment' and mv.kind not in ('payment', 'refund', 'correction'))
                                             or (mv.src = 'expense' and mv.kind not in ('expense', 'refund', 'correction'))), 0)::bigint as other,
           coalesce(sum(mv.delta), 0)::bigint as total
      from mv
     group by mv.source_id
  ),
  op as (
    select b.source_id, b.balance_tiyin, b.verified from public.cash_balances_unchecked(v_center, v_first - 1) b
  ),
  cl as (
    select b.source_id, b.balance_tiyin, b.verified from public.cash_balances_unchecked(v_center, v_last) b
  ),
  cnt as (
    select d.source_id,
           coalesce(sum(d.difference_tiyin) filter (where d.is_opening), 0)::bigint     as opening_adj,
           coalesce(sum(d.difference_tiyin) filter (where not d.is_opening), 0)::bigint as diffs,
           max(d.counted_on) as last_on
      from public.cash_count_diffs_unchecked(v_center) d
     where d.counted_on >= v_first and d.counted_on <= v_last
     group by d.source_id
  ),
  last_any as (
    select c.source_id, max(c.counted_on) as last_on
      from public.cash_counts c
     where c.center_id = v_center and c.cancelled_at is null and c.counted_on <= v_last
     group by c.source_id
  ),
  sources as (
    select ps.id, ps.deleted_at, ps.sort, ps.name from public.payment_sources ps where ps.center_id = v_center
  )
  select s.id,
         coalesce(op.balance_tiyin, 0), coalesce(t.received, 0), coalesce(t.refunded, 0), coalesce(t.corrections, 0),
         coalesce(t.spent, 0), coalesce(t.t_in, 0), coalesce(t.t_out, 0), coalesce(t.other, 0), coalesce(t.total, 0),
         coalesce(cnt.opening_adj, 0), coalesce(cnt.diffs, 0), coalesce(cl.balance_tiyin, 0),
         coalesce(op.verified, false), coalesce(cl.verified, false), la.last_on
    from sources s
    left join turn t     on t.source_id = s.id
    left join op         on op.source_id = s.id
    left join cl         on cl.source_id = s.id
    left join cnt        on cnt.source_id = s.id
    left join last_any la on la.source_id = s.id
   -- Архивная касса без остатка и без движений месяца — не показывается.
   where s.deleted_at is null or coalesce(cl.balance_tiyin, 0) <> 0 or t.source_id is not null or cnt.source_id is not null
  union all
  -- Деньги без кассы (Р6): только обороты — чтобы сумма сходилась с cash_by_source.
  select null::uuid, null::bigint, t.received, t.refunded, t.corrections, t.spent, t.t_in, t.t_out, t.other, t.total,
         null::bigint, null::bigint, null::bigint, null::boolean, null::boolean, null::date
    from turn t
   where t.source_id is null;
end;
$$;
comment on function public.cash_report(date) is
  'Касса за месяц (0102): по кассе — остаток на начало (конец предыдущего дня) и конец (конец месяца или сейчас), обороты как cash_by_source, поправка начального остатка, расхождения сверок месяца; строка без кассы — только обороты. Тождество: конец = начало + обороты + поправка + расхождения. can_finance.';
revoke all on function public.cash_report(date) from public, anon;
grant execute on function public.cash_report(date) to authenticated;


-- 6. Экспорт центра — allow-list 0101 плюс сверки --------------------------------------------

create or replace function public.export_center_tables()
  returns table (table_name text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('attendance'), ('attendance_statuses'), ('booking_requests'), ('cash_counts'), ('cash_transfers'),
    ('diagnostic_clinical_forms'), ('diagnostic_referrals'), ('diagnostics'), ('discount_reasons'),
    ('exercise_library'),
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
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. 0087: lesson_debt_writeoffs. 0088: lesson_debt_covers. 0090: subscription_shortfall_writeoffs. 0093: payment_voids. 0101: cash_transfers, discount_reasons. 0102: cash_counts. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
