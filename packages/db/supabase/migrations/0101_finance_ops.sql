-- =============================================================================
-- 0101_finance_ops.sql — аванс без долга, выплата зарплаты из кассы, переводы
-- между кассами, скидки с причиной и отчётом
--
-- Решения владельца 16.10.2026 (аудит финансов, «как в топовых CRM»): принять
-- аванс за занятия, когда долга нет; выплачивать зарплату из кассы с остатком
-- «к выплате»; переводить деньги между способами оплаты; скидки — с причиной
-- и отчётом. Касса за день для стойки сделана в 0100.
--
-- Решения:
--   Р1. Аванс — отдельная RPC accept_lesson_advance (не переплата через оплату
--       долга): сверка текущего аванса p_expected_credit_tiyin под
--       lesson_debt_lock — второе нажатие получает 23514, а не второй аванс.
--       Флаг covers_lesson_debt ставит только она и RPC 0087 (0087 Р1).
--   Р2. Когда аванс принять нельзя, решает одна функция
--       lesson_advance_block_unchecked (код причины): её зовут RPC под
--       блокировкой и предпросмотр lesson_advance_preview для кнопки на
--       карточке — браузер не повторяет арифметику (CLAUDE.md, правило денег).
--       Причины: архив, нет плательщика, долг (его гасит оплата долга),
--       списание (paid < accrued + overdrawn_gross — аванс съелся бы списанием:
--       credit по 0087 Р2 «сначала деньги, потом списание»; отказ постоянный,
--       пока не изменятся начисления), недоплаченный живой абонемент (аванс
--       легко принять за оплату абонемента — деньги легли бы не туда; строго,
--       и при рассрочке по графику). Формула кредита 0087 не меняется.
--   Р3. Аванс принадлежит счёту ребёнка, не плательщику: при смене плательщика
--       остаётся у ребёнка, вернуть — текущему плательщику (так устроен
--       refund_lesson_debt_credit). Ошибочный аванс — «Вернуть аванс»:
--       void_payment оплату долга не отменяет (0093 Р2).
--   Р4. Выплата зарплаты — строка expenses по статье «Зарплата» со
--       специалистом и месяцем (teacher_id, salary_month): сама попадает в
--       кассу (cash_by_source.spent), «Расходы», сводку месяца по статьям.
--       Переплаты нет: сумма ≤ «к выплате»; сверка p_expected_due_tiyin под
--       advisory-блокировкой специалиста-месяца.
--   Р5. «Начислено / выплачено / к выплате» — одна функция
--       salary_totals_unchecked(center, month, teacher?) без грантов: на ней
--       salary_summary (DROP+CREATE — новые колонки paid_tiyin, due_tiyin) и
--       pay_salary, считающая только своего специалиста.
--   Р6. Статья «Зарплата» ищется по code = 'salary' — код теперь неизменяем
--       триггером (иначе PATCH code='salary' на «Аренду» увёл бы выплаты туда).
--       Выбор детерминированный: живая, иначе последняя архивная; нет совсем —
--       вставка on conflict do nothing и повторный select.
--   Р7. void_expense — отмена любого ошибочного расхода (только owner, причина
--       обязательна): зеркальная корректировка той же датой, как 0093 у
--       платежей. Причина — в comment отменяющей строки: expenses не читают ни
--       родитель, ни специалист, а строку отмены триггер делает неизменяемой.
--   Р8. Границы expenses — триггер expenses_links_guard: отмена зеркалит
--       исходную (nullable-колонки через is distinct from), пара не меняется,
--       специалист/месяц/ссылка неизменяемы, выплата — только в статье salary.
--       CHECK: корректировка со специалистом — только отмена.
--   Р9. cash_transfers — перевод между кассами (откуда, куда, сумма > 0),
--       неизменяем триггером, чтение — только can_finance (select-политика без
--       apply_tenant_rls: её for all открыла бы запись), service_role без
--       прав. Ключ идемпотентности transfer_key (unique по центру, как
--       sale_key) — две вкладки не проведут один перевод дважды. Ошибочный
--       перевод исправляется обратным. Под readonly-guard и замком месяца.
--   Р10. cash_by_source: переводы — две ноги в flows; итог источника честный,
--        сумма по центру не меняется; transfers_in/out — новые колонки в
--        конце. Остатки касс на дату (начальный остаток, сверка) — не здесь:
--        без начального остатка накопительный итог был бы мусором.
--   Р11. Скидка: list_price_tiyin (цена типа на момент продажи) и
--        discount_reason_id — ссылка на справочник причин центра
--        discount_reasons (lookup, как статьи расходов). Текст причины в
--        subscriptions читал бы родитель (subscriptions_parent_read) — в
--        справочник родителю доступа нет. CHECK: скидка требует причину,
--        причина — только при скидке. Проверка с понятным текстом — в
--        sell_subscription (только он знает цену типа).
--   Р12. Отчёт по скидкам — subscription_discounts (строки) и
--        subscription_discount_totals (итоги по причинам, grouping sets) под
--        can_finance; автор продажи — имя карточки специалиста и роль из
--        memberships (бухгалтеру staff_view отдаёт только его строку), без email.
--
-- Architect-ревью плана (11 находок, все учтены):
--   А1 readonly-guard на cash_transfers; А2 export_salary_summary не
--   трогается (CSV — как был, иначе DROP и правка теста 0058); А3 NULL в
--   «выплачено» выключал все проверки pay_salary — coalesce в функции итогов
--   и is distinct from в RPC; А4 причина скидки — в sell_subscription и
--   CHECK; А5 причину не видит родитель (справочник); А6 автор продажи для
--   бухгалтера; А7 неизменяемость переводов триггером; А8 is distinct from в
--   зеркале отмены и CHECK корректировки со специалистом; А9 признак «аванс
--   нельзя» из SQL; А10 code статьи неизменяем, выбор статьи детерминирован;
--   А11 ключ идемпотентности перевода. Мелочи: индексы под составные FK,
--   «нечего выплачивать» отдельным текстом, auth.uid() в sell_subscription,
--   длины текстов — 22023 из функций, чужой id — 42704, гранты триггерных
--   функций, явные гранты вью.
-- =============================================================================


-- 1. Аванс за занятия без долга (Р1–Р3) ---------------------------------------------------------

create or replace function public.lesson_advance_block_unchecked(p_center_id uuid, p_student_id uuid)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_status  text;
  v_payer   uuid;
  v_found   boolean;
  v_acc     record;
begin
  select s.status, s.payer_id into v_status, v_payer
    from public.students s
   where s.id = p_student_id and s.center_id = p_center_id and s.deleted_at is null;
  if not found then
    return 'not_found';
  end if;
  if v_status = 'archived' then
    return 'archived';
  end if;
  if v_payer is null then
    return 'no_payer';
  end if;

  select x.accrued_tiyin, x.overdrawn_gross_tiyin, x.paid_tiyin, x.remaining_tiyin
    into v_acc
    from public.lesson_debt_accounts_unchecked(p_center_id, p_student_id) x;
  v_found := found;
  -- Строки нет — у ребёнка ни начислений, ни оплат: аванс отразится целиком.
  if v_found then
    if v_acc.remaining_tiyin > 0 then
      return 'debt';
    end if;
    -- После проверки долга paid < accrued + over значит: долг закрыт списанием,
    -- и credit (0087 Р2) покажет меньше внесённого (Р2).
    if v_acc.paid_tiyin < v_acc.accrued_tiyin + v_acc.overdrawn_gross_tiyin then
      return 'writeoff';
    end if;
  end if;

  if exists (
    select 1 from public.subscriptions s
     where s.center_id = p_center_id and s.student_id = p_student_id
       and s.deleted_at is null and s.status <> 'cancelled'
       and s.settled_worked_tiyin is null
       and s.paid_tiyin < s.price_tiyin
  ) then
    return 'unpaid_subscription';
  end if;

  return null;
end;
$$;
comment on function public.lesson_advance_block_unchecked(uuid, uuid) is
  'Почему нельзя принять аванс за занятия (0101 Р2): not_found | archived | no_payer | debt | writeoff | unpaid_subscription | null. Без проверки сессии и без грантов — зовут accept_lesson_advance (под lesson_debt_lock) и lesson_advance_preview.';

revoke all on function public.lesson_advance_block_unchecked(uuid, uuid) from public, anon, authenticated, service_role;


create or replace function public.lesson_advance_preview(p_student_id uuid)
  returns table (block_reason text, credit_tiyin integer)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_student_id is null or not exists (
       select 1 from public.students s
        where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null
     ) then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  return query
    select public.lesson_advance_block_unchecked(v_center, p_student_id),
           coalesce((select max(x.credit_tiyin)
                       from public.lesson_debt_accounts_unchecked(v_center, p_student_id) x), 0)::integer;
end;
$$;
comment on function public.lesson_advance_preview(uuid) is
  'Предпросмотр «Внести аванс» на карточке (0101 Р2): причина отказа из lesson_advance_block_unchecked (null — можно) и текущий аванс для сверки. can_payments.';

revoke all on function public.lesson_advance_preview(uuid) from public, anon;
grant execute on function public.lesson_advance_preview(uuid) to authenticated;


create or replace function public.accept_lesson_advance(
  p_student_id            uuid,
  p_amount_tiyin          integer,
  p_source_id             uuid,
  p_paid_on               date,
  p_expected_credit_tiyin integer,
  p_comment               text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_block  text;
  v_credit integer;
  v_payer  uuid;
  v_type   text;
  v_unpaid integer;
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
  if p_expected_credit_tiyin is null then
    raise exception 'Обновите страницу: текущий аванс не передан' using errcode = '22023';
  end if;
  if p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;
  if p_comment is not null and length(btrim(p_comment)) > 500 then
    raise exception 'Комментарий — не длиннее 500 символов' using errcode = '22023';
  end if;
  if not exists (select 1 from public.payment_sources ps where ps.id = p_source_id and ps.center_id = v_center) then
    raise exception 'Источник оплаты не найден' using errcode = '42704';
  end if;

  -- Блокировка раньше проверок: вторая вкладка дождётся первой и увидит её аванс.
  perform public.lesson_debt_lock(p_student_id);

  v_block := public.lesson_advance_block_unchecked(v_center, p_student_id);
  case v_block
    when 'not_found' then
      raise exception 'Ученик не найден' using errcode = '42704';
    when 'archived' then
      raise exception 'Ученик в архиве — восстановите его, чтобы принять аванс' using errcode = '22023';
    when 'no_payer' then
      raise exception 'У ученика нет плательщика — привяжите его в карточке ученика' using errcode = '22023';
    when 'debt' then
      raise exception 'У ученика долг за занятия — примите оплату долга, переплата станет авансом' using errcode = '22023';
    when 'writeoff' then
      raise exception 'Аванс не отразится на счёте: у ученика списан долг за занятия. Предложите абонемент' using errcode = '22023';
    when 'unpaid_subscription' then
      select coalesce(t.name, 'Абонемент'), s.price_tiyin - s.paid_tiyin
        into v_type, v_unpaid
        from public.subscriptions s
        left join public.subscription_types t on t.id = s.type_id
       where s.center_id = v_center and s.student_id = p_student_id
         and s.deleted_at is null and s.status <> 'cancelled'
         and s.settled_worked_tiyin is null
         and s.paid_tiyin < s.price_tiyin
       order by s.created_at
       limit 1;
      raise exception 'Не доплачен абонемент «%»: % — примите оплату абонемента', v_type, public.format_som(v_unpaid)
        using errcode = '22023';
    else
      null;
  end case;

  select coalesce(max(x.credit_tiyin), 0) into v_credit
    from public.lesson_debt_accounts_unchecked(v_center, p_student_id) x;
  if p_expected_credit_tiyin is distinct from v_credit then
    raise exception 'Аванс изменился, пока открывали форму: сейчас %. Проверьте сумму.', public.format_som(v_credit)
      using errcode = '23514';
  end if;

  select s.payer_id into v_payer
    from public.students s
   where s.id = p_student_id and s.center_id = v_center;

  return public.record_payment_core(
    v_payer, p_amount_tiyin, 'payment', p_student_id, null, p_source_id,
    null, coalesce(nullif(btrim(p_comment), ''), 'Аванс за занятия'),
    coalesce(p_paid_on, public.center_today(v_center)), true
  );
end;
$$;
comment on function public.accept_lesson_advance(uuid, integer, uuid, date, integer, text) is
  'Аванс за занятия без абонемента, когда долга нет (0101 Р1–Р3): can_payments, lesson_debt_lock, отказы по lesson_advance_block_unchecked, сверка p_expected_credit_tiyin (23514 со свежей суммой). Платёж covers_lesson_debt — гасит будущие занятия.';

revoke all on function public.accept_lesson_advance(uuid, integer, uuid, date, integer, text) from public, anon;
grant execute on function public.accept_lesson_advance(uuid, integer, uuid, date, integer, text) to authenticated;


-- 2. Статья «Зарплата»: код неизменяем (Р6) -------------------------------------------------------

create or replace function public.expense_categories_code_immutable()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.code is distinct from old.code then
    raise exception 'Код статьи расхода не меняется: по нему отчёты и выплаты зарплаты находят статью'
      using errcode = '22023';
  end if;
  return new;
end;
$$;
comment on function public.expense_categories_code_immutable() is
  'Код статьи расхода неизменяем (0101 Р6): pay_salary ищет статью по code = salary, выплаты не должны уехать в «Аренду» правкой кода. Новый код — только при создании.';
revoke all on function public.expense_categories_code_immutable() from public, anon, authenticated, service_role;

drop trigger if exists expense_categories_code_immutable on public.expense_categories;
create trigger expense_categories_code_immutable
  before update on public.expense_categories
  for each row execute function public.expense_categories_code_immutable();


create or replace function public.salary_expense_category_unchecked(p_center_id uuid)
  returns uuid
  language plpgsql
  volatile
  set search_path = ''
as $$
declare
  v_id uuid;
begin
  -- Живая статья, иначе последняя архивная: архивная принимает расходы (0016).
  select c.id into v_id
    from public.expense_categories c
   where c.center_id = p_center_id and c.code = 'salary'
   order by (c.deleted_at is not null), c.deleted_at desc nulls last, c.created_at desc
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  -- Статьи нет совсем: две выплаты разным специалистам параллельно — вторая
  -- не падает голой 23505, а берёт строку первой.
  insert into public.expense_categories (center_id, code, name, sort)
  values (p_center_id, 'salary', 'Зарплата', 30)
  on conflict (center_id, code) where deleted_at is null do nothing;

  select c.id into v_id
    from public.expense_categories c
   where c.center_id = p_center_id and c.code = 'salary' and c.deleted_at is null;
  return v_id;
end;
$$;
comment on function public.salary_expense_category_unchecked(uuid) is
  'Статья «Зарплата» центра для pay_salary (0101 Р6): живая, иначе последняя архивная, иначе создаётся. Без сессии и без грантов.';
revoke all on function public.salary_expense_category_unchecked(uuid) from public, anon, authenticated, service_role;


-- 3. Выплаты и отмены расходов: колонки и границы expenses (Р4, Р7, Р8) ---------------------------

alter table public.expenses
  add column if not exists teacher_id       uuid,
  add column if not exists salary_month     date,
  add column if not exists voids_expense_id uuid;

comment on column public.expenses.teacher_id is
  'Выплата зарплаты этому специалисту (0101 Р4) — вместе с salary_month; ставит только pay_salary (и зеркалит void_expense).';
comment on column public.expenses.salary_month is
  'За какой месяц выплата (первое число, 0101 Р4); paid_at — когда деньги ушли.';
comment on column public.expenses.voids_expense_id is
  'Эта строка — отмена ошибочного расхода (0101 Р7): корректировка на ту же сумму с минусом той же датой. Одна отмена на расход.';

alter table public.expenses drop constraint if exists expenses_teacher_fk;
alter table public.expenses add constraint expenses_teacher_fk
  foreign key (teacher_id, center_id) references public.teachers (id, center_id);

alter table public.expenses drop constraint if exists expenses_void_fk;
alter table public.expenses add constraint expenses_void_fk
  foreign key (voids_expense_id, center_id) references public.expenses (id, center_id);

-- Непартиальный unique: «одна отмена на расход» и покрытие FK (урок 0069); NULL не конфликтуют.
alter table public.expenses drop constraint if exists expenses_voids_expense_key;
alter table public.expenses add constraint expenses_voids_expense_key unique (voids_expense_id, center_id);

alter table public.expenses drop constraint if exists expenses_salary_shape;
alter table public.expenses add constraint expenses_salary_shape check (
  (teacher_id is null) = (salary_month is null)
  and (salary_month is null or salary_month = date_trunc('month', salary_month)::date)
);

alter table public.expenses drop constraint if exists expenses_void_is_correction;
alter table public.expenses add constraint expenses_void_is_correction
  check (voids_expense_id is null or kind = 'correction');

-- Корректировка со специалистом без ссылки на отмену молча меняла бы «Выплачено» (А8).
alter table public.expenses drop constraint if exists expenses_salary_kind;
alter table public.expenses add constraint expenses_salary_kind
  check (teacher_id is null or kind = 'expense' or voids_expense_id is not null);

-- Под FK на teachers и под сумму выплат специалиста за месяц.
create index if not exists expenses_teacher_month_idx
  on public.expenses (teacher_id, center_id, salary_month);


create or replace function public.expenses_links_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_orig public.expenses;
  v_code text;
begin
  if tg_op = 'UPDATE' then
    if (new.voids_expense_id, new.teacher_id, new.salary_month)
       is distinct from (old.voids_expense_id, old.teacher_id, old.salary_month) then
      raise exception 'Специалиста, месяц зарплаты и ссылку отмены у расхода менять нельзя' using errcode = '22023';
    end if;
    if old.voids_expense_id is not null then
      raise exception 'Отмену расхода менять нельзя' using errcode = '22023';
    end if;
    if exists (select 1 from public.expenses e where e.voids_expense_id = old.id)
       and (new.amount_tiyin, new.kind, new.paid_at, new.source_id, new.category_id)
           is distinct from (old.amount_tiyin, old.kind, old.paid_at, old.source_id, old.category_id) then
      raise exception 'Отменённый расход менять нельзя' using errcode = '22023';
    end if;
    return new;
  end if;

  if new.voids_expense_id is not null then
    select * into v_orig from public.expenses e
     where e.id = new.voids_expense_id and e.center_id = new.center_id
       for update;
    if v_orig.id is null then
      raise exception 'Расход не найден' using errcode = '42704';
    end if;
    if v_orig.voids_expense_id is not null then
      raise exception 'Отмену расхода отменить нельзя' using errcode = '22023';
    end if;
    if v_orig.kind <> 'expense' then
      raise exception 'Отменить можно только расход' using errcode = '22023';
    end if;
    if new.amount_tiyin <> -v_orig.amount_tiyin
       or new.paid_at <> v_orig.paid_at
       or new.category_id is distinct from v_orig.category_id
       or new.source_id is distinct from v_orig.source_id
       or new.teacher_id is distinct from v_orig.teacher_id
       or new.salary_month is distinct from v_orig.salary_month then
      raise exception 'Отмена должна зеркалить исходный расход' using errcode = '22023';
    end if;
    return new;
  end if;

  if new.teacher_id is not null then
    select c.code into v_code
      from public.expense_categories c
     where c.id = new.category_id and c.center_id = new.center_id;
    if v_code is distinct from 'salary' then
      raise exception 'Выплата зарплаты проводится только по статье «Зарплата»' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
comment on function public.expenses_links_guard() is
  'Граница 0101 Р8: отмена зеркалит исходный расход (сумма с минусом, дата, статья, источник, специалист, месяц); пара и отмена не меняются; специалист, месяц и ссылка неизменяемы; выплата — только по статье salary.';
revoke all on function public.expenses_links_guard() from public, anon, authenticated, service_role;

drop trigger if exists expenses_links_guard on public.expenses;
create trigger expenses_links_guard
  before insert or update on public.expenses
  for each row execute function public.expenses_links_guard();


-- 4. Начислено, выплачено, к выплате — одна функция (Р5, А3) ----------------------------------------

-- calc_salary проверяет роль по сессии и берёт current_center(): p_center_id
-- обязан совпадать с ним — зовут только salary_summary и pay_salary.
create or replace function public.salary_totals_unchecked(p_center_id uuid, p_month date, p_teacher_id uuid default null)
  returns table (
    teacher_id        uuid,
    calc_tiyin        integer,
    adjustments_tiyin integer,
    total_tiyin       integer,
    approved_run_id   uuid,
    approved_at       timestamptz,
    cancelled_runs    integer,
    paid_tiyin        integer,
    due_tiyin         integer
  )
  language sql
  stable
  set search_path = ''
as $$
  with m as (
    select date_trunc('month', p_month)::date as month
  ),
  scope as (
    select t.id as teacher_id
      from public.teachers t
     where t.center_id = p_center_id
       and t.deleted_at is null
       and (p_teacher_id is null or t.id = p_teacher_id)
  ),
  calc as (
    select s.teacher_id, coalesce(sum(c.amount_tiyin), 0)::integer as calc_tiyin
      from scope s
      cross join m
      left join lateral public.calc_salary(s.teacher_id, m.month) c on true
     group by s.teacher_id
  ),
  adj as (
    select s.teacher_id, coalesce(sum(sa.amount_tiyin), 0)::integer as adjustments_tiyin
      from scope s
      cross join m
      left join public.salary_adjustments sa
        on sa.teacher_id = s.teacher_id and sa.center_id = p_center_id and sa.month = m.month
     group by s.teacher_id
  ),
  run as (
    select sr.teacher_id, sr.id as approved_run_id, sr.approved_at, sr.total_tiyin
      from public.salary_runs sr
      cross join m
     where sr.center_id = p_center_id and sr.month = m.month and sr.cancelled_at is null
  ),
  cancelled as (
    select sr.teacher_id, count(*)::integer as cancelled_runs
      from public.salary_runs sr
      cross join m
     where sr.center_id = p_center_id and sr.month = m.month and sr.cancelled_at is not null
     group by sr.teacher_id
  ),
  -- А3: coalesce — у специалиста без выплат «выплачено» 0, а не NULL; иначе
  -- «к выплате» = total − NULL выключало бы все проверки pay_salary.
  paid as (
    select s.teacher_id, coalesce(sum(e.amount_tiyin), 0)::integer as paid_tiyin
      from scope s
      cross join m
      left join public.expenses e
        on e.teacher_id = s.teacher_id and e.center_id = p_center_id and e.salary_month = m.month
     group by s.teacher_id
  )
  select
    s.teacher_id,
    c.calc_tiyin,
    a.adjustments_tiyin,
    coalesce(r.total_tiyin, c.calc_tiyin + a.adjustments_tiyin),
    r.approved_run_id,
    r.approved_at,
    coalesce(x.cancelled_runs, 0),
    p.paid_tiyin,
    coalesce(r.total_tiyin, c.calc_tiyin + a.adjustments_tiyin) - p.paid_tiyin
  from scope s
  join calc c on c.teacher_id = s.teacher_id
  join adj a on a.teacher_id = s.teacher_id
  join paid p on p.teacher_id = s.teacher_id
  left join run r on r.teacher_id = s.teacher_id
  left join cancelled x on x.teacher_id = s.teacher_id
  order by s.teacher_id;
$$;
comment on function public.salary_totals_unchecked(uuid, date, uuid) is
  'Зарплата месяца по специалистам (0101 Р5): расчёт, корректировки, итог (снимок или расчёт + корректировки), выплачено (expenses со специалистом и месяцем, отмены с минусом), к выплате. Одна копия формулы для salary_summary и pay_salary. Без сессии и без грантов.';
revoke all on function public.salary_totals_unchecked(uuid, date, uuid) from public, anon, authenticated, service_role;


-- Тело 0029 (can_finance / teacher) поверх функции итогов; тип возврата меняется → DROP + CREATE.
drop function if exists public.salary_summary(date);

create function public.salary_summary(p_month date)
  returns table (
    teacher_id        uuid,
    calc_tiyin        integer,
    adjustments_tiyin integer,
    total_tiyin       integer,
    approved_run_id   uuid,
    approved_at       timestamptz,
    cancelled_runs    integer,
    paid_tiyin        integer,
    due_tiyin         integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
#variable_conflict use_column
declare
  v_center  uuid := public.current_center();
  v_month   date := date_trunc('month', p_month)::date;
  v_role    text := coalesce(public.my_role(), '');
  v_teacher uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not (public.can_finance() or v_role = 'teacher') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if public.can_finance() then
    return query select * from public.salary_totals_unchecked(v_center, v_month, null);
    return;
  end if;

  -- Специалист — только своя строка. Без карточки — пусто, а не «все»:
  -- NULL в p_teacher_id значит «все специалисты центра».
  v_teacher := public.my_teacher_id();
  if v_teacher is null then
    return;
  end if;
  return query select * from public.salary_totals_unchecked(v_center, v_month, v_teacher);
end;
$$;
comment on function public.salary_summary(date) is
  'Зарплата месяца (0029 + 0101): can_finance — все живые специалисты, teacher — своя строка. paid_tiyin — выплачено из кассы, due_tiyin — к выплате (минус — переплата).';

revoke execute on function public.salary_summary(date) from public, anon, authenticated;
grant execute on function public.salary_summary(date) to authenticated;


-- 5. Выплата зарплаты и отмена расхода (Р4, Р7) ---------------------------------------------------

create or replace function public.pay_salary(
  p_teacher_id         uuid,
  p_month              date,
  p_amount_tiyin       integer,
  p_source_id          uuid,
  p_paid_on            date,
  p_expected_due_tiyin integer,
  p_comment            text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid := public.current_center();
  v_today    date;
  v_month    date;
  v_paid_on  date;
  v_total    integer;
  v_due      integer;
  v_category uuid;
  v_id       uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_teacher_id is null then
    raise exception 'Укажите специалиста' using errcode = '22023';
  end if;
  if p_month is null then
    raise exception 'Укажите месяц зарплаты' using errcode = '22023';
  end if;
  if p_amount_tiyin is null or p_amount_tiyin <= 0 then
    raise exception 'Сумма должна быть больше нуля' using errcode = '22023';
  end if;
  if p_source_id is null then
    raise exception 'Укажите, из какой кассы выплата' using errcode = '22023';
  end if;
  if p_expected_due_tiyin is null then
    raise exception 'Обновите страницу: сумма к выплате не передана' using errcode = '22023';
  end if;
  if p_comment is not null and length(btrim(p_comment)) > 500 then
    raise exception 'Комментарий — не длиннее 500 символов' using errcode = '22023';
  end if;

  v_today := public.center_today(v_center);
  v_month := date_trunc('month', p_month)::date;
  if v_month > date_trunc('month', v_today)::date then
    raise exception 'За будущий месяц зарплату не выплачивают' using errcode = '22023';
  end if;
  v_paid_on := coalesce(p_paid_on, v_today);
  if v_paid_on > v_today then
    raise exception 'Дата выплаты не может быть в будущем' using errcode = '22023';
  end if;
  if v_paid_on < v_today - interval '1 year' then
    raise exception 'Дата выплаты старше года — проверьте год' using errcode = '22023';
  end if;
  if v_paid_on < v_month then
    raise exception 'Дата выплаты раньше месяца зарплаты — проверьте месяц и дату' using errcode = '22023';
  end if;

  if not exists (
       select 1 from public.teachers t
        where t.id = p_teacher_id and t.center_id = v_center and t.deleted_at is null
     ) then
    raise exception 'Специалист не найден' using errcode = '42704';
  end if;
  if not exists (select 1 from public.payment_sources ps where ps.id = p_source_id and ps.center_id = v_center) then
    raise exception 'Касса не найдена' using errcode = '42704';
  end if;

  -- Две вкладки и выплата с отменой по одному специалисту-месяцу — по очереди.
  perform pg_advisory_xact_lock(hashtextextended('salary_payout:' || p_teacher_id::text || ':' || v_month::text, 0));

  select x.total_tiyin, x.due_tiyin into v_total, v_due
    from public.salary_totals_unchecked(v_center, v_month, p_teacher_id) x;
  if not found then
    raise exception 'Специалист не найден' using errcode = '42704';
  end if;

  if v_total <= 0 then
    raise exception 'Нечего выплачивать: за % начислено %', public.ru_month_year(v_month), public.format_som(v_total)
      using errcode = '22023';
  end if;
  if v_due <= 0 then
    raise exception 'Зарплата за % уже выплачена', public.ru_month_year(v_month) using errcode = '22023';
  end if;
  if p_expected_due_tiyin is distinct from v_due then
    raise exception 'Сумма к выплате изменилась, пока открывали форму: сейчас %. Проверьте сумму.', public.format_som(v_due)
      using errcode = '23514';
  end if;
  if p_amount_tiyin > v_due then
    raise exception 'Больше, чем к выплате: %', public.format_som(v_due) using errcode = '22023';
  end if;

  v_category := public.salary_expense_category_unchecked(v_center);

  insert into public.expenses (
    center_id, category_id, source_id, amount_tiyin, paid_at, kind, comment, created_by,
    teacher_id, salary_month
  )
  values (
    v_center, v_category, p_source_id, p_amount_tiyin,
    (v_paid_on::timestamp) at time zone public.center_timezone(v_center),
    'expense', nullif(btrim(p_comment), ''), auth.uid(),
    p_teacher_id, v_month
  )
  returning id into v_id;

  perform public.emit_event('salary.paid',
    jsonb_build_object('center_id', v_center, 'expense_id', v_id, 'teacher_id', p_teacher_id,
                       'month', v_month, 'amount_tiyin', p_amount_tiyin),
    v_center);

  return v_id;
end;
$$;
comment on function public.pay_salary(uuid, date, integer, uuid, date, integer, text) is
  'Выплата зарплаты из кассы (0101 Р4): can_finance; расход по статье «Зарплата» со специалистом и месяцем; не больше «к выплате» (salary_totals_unchecked), сверка p_expected_due_tiyin под блокировкой специалиста-месяца (23514 со свежей суммой).';

revoke all on function public.pay_salary(uuid, date, integer, uuid, date, integer, text) from public, anon;
grant execute on function public.pay_salary(uuid, date, integer, uuid, date, integer, text) to authenticated;


create or replace function public.void_expense(p_expense_id uuid, p_reason text)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_orig   public.expenses;
  v_month  date;
  v_id     uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.role_in(v_center), '') <> 'owner' then
    raise exception 'Отменить расход может только владелец центра' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Укажите причину отмены' using errcode = '22023';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'Причина — не длиннее 500 символов' using errcode = '22023';
  end if;

  -- Только свой центр: на чужой id — 42704, а не 23503 от FK.
  select * into v_orig from public.expenses e
   where e.id = p_expense_id and e.center_id = v_center
     for update;
  if not found then
    raise exception 'Расход не найден' using errcode = '42704';
  end if;
  if v_orig.teacher_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('salary_payout:' || v_orig.teacher_id::text || ':' || v_orig.salary_month::text, 0));
  end if;
  if exists (select 1 from public.expenses e where e.voids_expense_id = p_expense_id) then
    raise exception 'Расход уже отменён' using errcode = '22023';
  end if;
  if v_orig.voids_expense_id is not null then
    raise exception 'Отмену расхода отменить нельзя' using errcode = '22023';
  end if;
  if v_orig.kind <> 'expense' then
    raise exception 'Отменить можно только расход — возврат и корректировку исправляют новой строкой' using errcode = '22023';
  end if;

  -- Отмена встаёт датой исходного расхода — его месяц должен быть открыт (как 0093 Р3).
  v_month := date_trunc('month', (v_orig.paid_at at time zone public.center_timezone(v_center))::date)::date;
  if exists (select 1 from public.financial_periods fp
              where fp.center_id = v_center and fp.month = v_month and fp.closed_at is not null) then
    raise exception 'Месяц расхода (%) закрыт — переоткройте его во вкладке «Периоды», затем отмените расход',
      public.ru_month_year(v_month)
      using errcode = '22023';
  end if;

  insert into public.expenses (
    center_id, category_id, source_id, amount_tiyin, paid_at, kind, comment, created_by,
    teacher_id, salary_month, voids_expense_id
  )
  values (
    v_center, v_orig.category_id, v_orig.source_id, -v_orig.amount_tiyin, v_orig.paid_at,
    'correction', 'Отмена: ' || btrim(p_reason), auth.uid(),
    v_orig.teacher_id, v_orig.salary_month, p_expense_id
  )
  returning id into v_id;

  -- Причина в payload не кладётся: outbox уходит наружу.
  perform public.emit_event('expense.voided',
    jsonb_build_object('center_id', v_center, 'expense_id', v_id, 'voided_expense_id', p_expense_id,
                       'amount_tiyin', v_orig.amount_tiyin),
    v_center);

  return v_id;
end;
$$;
comment on function public.void_expense(uuid, text) is
  'Отменить ошибочный расход (0101 Р7): только owner, причина обязательна (в comment отменяющей строки — её не меняет триггер); корректировка на ту же сумму с минусом той же датой. У выплаты зарплаты уменьшает «Выплачено».';

revoke all on function public.void_expense(uuid, text) from public, anon;
grant execute on function public.void_expense(uuid, text) to authenticated;


-- 6. Переводы между кассами (Р9) ------------------------------------------------------------------

create table if not exists public.cash_transfers (
  id              uuid primary key default gen_random_uuid(),
  center_id       uuid not null default public.current_center()
                    references public.centers (id) on delete cascade,
  from_source_id  uuid not null,
  to_source_id    uuid not null,
  amount_tiyin    integer not null,
  transferred_at  timestamptz not null,
  comment         text,
  -- Ключ идемпотентности формы (А11): повтор с тем же ключом — отказ, не второй перевод.
  transfer_key    uuid not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),

  constraint cash_transfers_id_center_key unique (id, center_id),
  constraint cash_transfers_transfer_key unique (center_id, transfer_key),
  constraint cash_transfers_from_fk
    foreign key (from_source_id, center_id) references public.payment_sources (id, center_id),
  constraint cash_transfers_to_fk
    foreign key (to_source_id, center_id) references public.payment_sources (id, center_id),
  constraint cash_transfers_distinct_sources check (from_source_id <> to_source_id),
  constraint cash_transfers_amount_positive check (amount_tiyin > 0),
  constraint cash_transfers_comment_length check (comment is null or length(comment) <= 500)
);
comment on table public.cash_transfers is
  'Перевод денег между кассами (способами оплаты) центра (0101 Р9): наличные сдали в банк, терминал перечислил на счёт. Неизменяем — ошибку исправляет обратный перевод. Пишет только record_cash_transfer, читает can_finance.';

-- Под составные FK — ведущие колонки FK (Database.md); (center_id, transferred_at) — под месяц и FK на centers.
create index if not exists cash_transfers_center_at_idx on public.cash_transfers (center_id, transferred_at);
create index if not exists cash_transfers_from_idx on public.cash_transfers (from_source_id, center_id);
create index if not exists cash_transfers_to_idx on public.cash_transfers (to_source_id, center_id);

drop trigger if exists cash_transfers_set_updated_at on public.cash_transfers;
create trigger cash_transfers_set_updated_at
  before update on public.cash_transfers
  for each row execute function extensions.moddatetime(updated_at);

alter table public.cash_transfers enable row level security;

-- Только чтение финансовым ролям своего центра. apply_tenant_rls намеренно не
-- применяется: её for all открыла бы запись в обход RPC (как 0087 Р6).
drop policy if exists cash_transfers_select on public.cash_transfers;
create policy cash_transfers_select on public.cash_transfers
  for select to authenticated
  using (center_id = public.current_center() and public.can_finance());

revoke all on table public.cash_transfers from public, anon, authenticated, service_role;
grant select on public.cash_transfers to authenticated;

call public.apply_audit('cash_transfers');
call public.apply_readonly_guard('cash_transfers');

create or replace function public.cash_transfers_immutable()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  raise exception 'Перевод между кассами не меняется и не удаляется — ошибку исправляет обратный перевод'
    using errcode = '22023';
end;
$$;
revoke all on function public.cash_transfers_immutable() from public, anon, authenticated, service_role;

drop trigger if exists cash_transfers_immutable on public.cash_transfers;
create trigger cash_transfers_immutable
  before update or delete on public.cash_transfers
  for each row execute function public.cash_transfers_immutable();


-- из 0017_teacher_rates_and_salary.sql; добавлена только ветка cash_transfers
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

drop trigger if exists financial_period_guard_cash_transfers on public.cash_transfers;
create trigger financial_period_guard_cash_transfers
  before insert or update or delete on public.cash_transfers
  for each row execute function public.financial_period_guard();


create or replace function public.record_cash_transfer(
  p_from_source_id uuid,
  p_to_source_id   uuid,
  p_amount_tiyin   integer,
  p_transfer_key   uuid,
  p_transferred_on date default null,
  p_comment        text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_today  date;
  v_day    date;
  v_id     uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_amount_tiyin is null or p_amount_tiyin <= 0 then
    raise exception 'Сумма должна быть больше нуля' using errcode = '22023';
  end if;
  if p_from_source_id is null or p_to_source_id is null then
    raise exception 'Укажите, откуда и куда переводите' using errcode = '22023';
  end if;
  if p_from_source_id = p_to_source_id then
    raise exception 'Откуда и куда — разные кассы' using errcode = '22023';
  end if;
  if p_transfer_key is null then
    raise exception 'Обновите страницу и повторите перевод' using errcode = '22023';
  end if;
  if p_comment is not null and length(btrim(p_comment)) > 500 then
    raise exception 'Комментарий — не длиннее 500 символов' using errcode = '22023';
  end if;

  v_today := public.center_today(v_center);
  v_day := coalesce(p_transferred_on, v_today);
  if v_day > v_today then
    raise exception 'Дата перевода не может быть в будущем' using errcode = '22023';
  end if;
  if v_day < v_today - interval '1 year' then
    raise exception 'Дата перевода старше года — проверьте год' using errcode = '22023';
  end if;

  -- Архивные кассы не отбиваются, как у платежей и расходов (0016): иначе не
  -- вывести остаток с закрытого счёта. Чужая касса — 42704, а не 23503 от FK.
  if not exists (select 1 from public.payment_sources ps where ps.id = p_from_source_id and ps.center_id = v_center)
     or not exists (select 1 from public.payment_sources ps where ps.id = p_to_source_id and ps.center_id = v_center) then
    raise exception 'Касса не найдена' using errcode = '42704';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('cash_transfer:' || p_transfer_key::text, 0));
  if exists (select 1 from public.cash_transfers ct
              where ct.center_id = v_center and ct.transfer_key = p_transfer_key) then
    raise exception 'Этот перевод уже проведён — обновите страницу' using errcode = '22023';
  end if;

  insert into public.cash_transfers (
    center_id, from_source_id, to_source_id, amount_tiyin, transferred_at, comment, transfer_key, created_by
  )
  values (
    v_center, p_from_source_id, p_to_source_id, p_amount_tiyin,
    (v_day::timestamp) at time zone public.center_timezone(v_center),
    nullif(btrim(p_comment), ''), p_transfer_key, auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;
comment on function public.record_cash_transfer(uuid, uuid, integer, uuid, date, text) is
  'Перевод между кассами (0101 Р9): can_finance, сумма > 0, кассы разные и свои, день по поясу центра, ключ идемпотентности p_transfer_key. Событие не шлётся — потребителя нет.';

revoke all on function public.record_cash_transfer(uuid, uuid, integer, uuid, date, text) from public, anon;
grant execute on function public.record_cash_transfer(uuid, uuid, integer, uuid, date, text) to authenticated;


-- 7. cash_by_source: переводы в итогах касс (Р10) -------------------------------------------------

-- из 0028_roles_policies.sql; добавлены две ветки переводов и две колонки в конце
create or replace view public.cash_by_source
  with (security_invoker = true)
as
with tz as (
  select public.center_timezone(public.current_center()) as tz
),
flows as (
  select p.center_id, p.source_id, p.kind,
         p.amount_tiyin::bigint                                   as delta,
         date_trunc('month', (p.paid_at at time zone t.tz))::date as month,
         'payment'                                                as src
    from public.payments p
    cross join tz t
   where p.center_id = public.current_center()
     and public.can_finance()
  union all
  select e.center_id, e.source_id, e.kind,
         -(e.amount_tiyin::bigint),
         date_trunc('month', (e.paid_at at time zone t.tz))::date,
         'expense'
    from public.expenses e
    cross join tz t
   where e.center_id = public.current_center()
     and public.can_finance()
  union all
  -- Перевод — две ноги одной датой: из кассы с минусом, в кассу с плюсом.
  select ct.center_id, ct.from_source_id, 'transfer_out',
         -(ct.amount_tiyin::bigint),
         date_trunc('month', (ct.transferred_at at time zone t.tz))::date,
         'transfer'
    from public.cash_transfers ct
    cross join tz t
   where ct.center_id = public.current_center()
     and public.can_finance()
  union all
  select ct.center_id, ct.to_source_id, 'transfer_in',
         ct.amount_tiyin::bigint,
         date_trunc('month', (ct.transferred_at at time zone t.tz))::date,
         'transfer'
    from public.cash_transfers ct
    cross join tz t
   where ct.center_id = public.current_center()
     and public.can_finance()
)
select f.center_id,
       f.month,
       f.source_id,
       coalesce(sum(f.delta) filter (where f.src = 'payment' and f.kind = 'payment'),    0)::bigint as received_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'payment' and f.kind = 'refund'),     0)::bigint as refunded_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'payment' and f.kind = 'correction'), 0)::bigint as corrections_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'expense'
                                       and f.kind in ('expense', 'refund', 'correction')),  0)::bigint as spent_tiyin,
       coalesce(sum(f.delta) filter (where (f.src = 'payment' and f.kind not in ('payment', 'refund', 'correction'))
                                        or (f.src = 'expense' and f.kind not in ('expense', 'refund', 'correction'))),
                0)::bigint as other_tiyin,
       coalesce(sum(f.delta), 0)::bigint                                                            as total_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'transfer' and f.kind = 'transfer_in'),  0)::bigint as transfers_in_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'transfer' and f.kind = 'transfer_out'), 0)::bigint as transfers_out_tiyin
  from flows f
 group by f.center_id, f.month, f.source_id;

revoke all on table public.cash_by_source from public, anon, authenticated;
grant select on public.cash_by_source to authenticated;


-- 8. Справочник причин скидок (Р11) ---------------------------------------------------------------

create table if not exists public.discount_reasons (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null default public.current_center()
                references public.centers (id) on delete cascade,
  code        text not null,
  name        text not null,
  is_active   boolean not null default true,
  sort        integer not null default 100,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  deleted_at  timestamptz,

  constraint discount_reasons_id_center_key unique (id, center_id),
  constraint discount_reasons_name_length check (length(btrim(name)) between 2 and 60)
);
comment on table public.discount_reasons is
  'Причины скидок центра (0101 Р11): справочник, как статьи расходов. На абонементе — ссылка discount_reason_id; родителю справочник не виден. Пишут owner/admin/finance, читают ещё и стойка (форма продажи).';

create unique index if not exists discount_reasons_center_code_idx
  on public.discount_reasons (center_id, code) where deleted_at is null;
-- Частичный unique выше не засчитывается покрытием FK на centers (урок 0069).
create index if not exists discount_reasons_center_idx on public.discount_reasons (center_id);

drop trigger if exists discount_reasons_set_updated_at on public.discount_reasons;
create trigger discount_reasons_set_updated_at before update on public.discount_reasons
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('discount_reasons');
call public.apply_role_rls('discount_reasons', 'finance', 'write', true);
call public.apply_role_rls('discount_reasons', 'registrar', 'read', true);

-- Названия архивных причин нужны истории (карточка абонемента, отчёт) — тем,
-- кто видит деньги абонементов.
drop policy if exists discount_reasons_read_archived on public.discount_reasons;
create policy discount_reasons_read_archived on public.discount_reasons
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.can_payments()
    and deleted_at is not null
  );

-- Supabase выдаёт authenticated полный набор прав по умолчанию, включая DELETE.
-- Прямая запись — справочные поля; code — только при создании, deleted_at — RPC.
revoke all on public.discount_reasons from anon, authenticated, service_role;
grant select, insert on public.discount_reasons to authenticated;
grant update (name, is_active, sort) on public.discount_reasons to authenticated;

call public.apply_audit('discount_reasons');
call public.apply_readonly_guard('discount_reasons');

-- Как seed_expense_categories (0016): из триггера создания центра my_role() ещё null.
create or replace function public.seed_discount_reasons(p_center_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if pg_trigger_depth() = 0 and auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  insert into public.discount_reasons (center_id, code, name, sort) values
    (p_center_id, 'second_child', 'Второй ребёнок',     10),
    (p_center_id, 'large_family', 'Многодетная семья',  20),
    (p_center_id, 'regular',      'Постоянный клиент',  30),
    (p_center_id, 'promo',        'Акция',              40),
    (p_center_id, 'other',        'Другое',             90)
  on conflict do nothing;
end;
$$;
revoke all on function public.seed_discount_reasons(uuid) from public, anon, authenticated, service_role;

create or replace function public.centers_seed_discount_reasons()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform public.seed_discount_reasons(new.id);
  return null;
end;
$$;
revoke all on function public.centers_seed_discount_reasons() from public, anon, authenticated, service_role;

drop trigger if exists centers_seed_discount_reasons on public.centers;
create trigger centers_seed_discount_reasons
  after insert on public.centers
  for each row execute function public.centers_seed_discount_reasons();

-- Существующим центрам — тоже (без сессии readonly-guard не мешает).
do $$
declare v_id uuid;
begin
  for v_id in select id from public.centers where deleted_at is null loop
    perform public.seed_discount_reasons(v_id);
  end loop;
end $$;

create or replace function public.archive_discount_reason(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.discount_reasons
     set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Причина скидки не найдена' using errcode = '42704';
  end if;
end;
$$;

create or replace function public.restore_discount_reason(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_name   text;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select name into v_name
    from public.discount_reasons
   where id = p_id and center_id = v_center and deleted_at is not null;
  if not found then
    raise exception 'Причина скидки не найдена в архиве' using errcode = '42704';
  end if;

  begin
    update public.discount_reasons
       set deleted_at = null
     where id = p_id and center_id = v_center;
  exception
    when unique_violation then
      raise exception 'Причина «%» уже есть среди действующих — восстановить вторую нельзя', v_name
        using errcode = '22023';
  end;
end;
$$;

revoke all on function public.archive_discount_reason(uuid), public.restore_discount_reason(uuid) from public, anon;
grant execute on function public.archive_discount_reason(uuid), public.restore_discount_reason(uuid) to authenticated;


-- 9. Скидка на абонементе и продажа (Р11, А4, А5) ---------------------------------------------------

alter table public.subscriptions
  add column if not exists list_price_tiyin   integer,
  add column if not exists discount_reason_id uuid;

comment on column public.subscriptions.list_price_tiyin is
  'Цена типа на момент продажи (0101 Р11) — пишет sell_subscription. null: продан до 0101 или создан переносом остатка; без цены типа это не скидка.';
comment on column public.subscriptions.discount_reason_id is
  'Причина скидки из справочника discount_reasons (0101 Р11). Обязательна, если цена ниже цены типа; родителю виден только id.';

alter table public.subscriptions drop constraint if exists subscriptions_list_price_not_negative;
alter table public.subscriptions add constraint subscriptions_list_price_not_negative
  check (list_price_tiyin is null or list_price_tiyin >= 0);

alter table public.subscriptions drop constraint if exists subscriptions_discount_reason_fk;
alter table public.subscriptions add constraint subscriptions_discount_reason_fk
  foreign key (discount_reason_id, center_id) references public.discount_reasons (id, center_id);

-- Скидка без причины невозможна физически (А4): прямой insert закрыт с 0010,
-- цену после продажи не меняет ни одна RPC, а CHECK держит и postgres.
alter table public.subscriptions drop constraint if exists subscriptions_discount_needs_reason;
alter table public.subscriptions add constraint subscriptions_discount_needs_reason
  check (list_price_tiyin is null or price_tiyin >= list_price_tiyin or discount_reason_id is not null);

alter table public.subscriptions drop constraint if exists subscriptions_reason_only_with_discount;
alter table public.subscriptions add constraint subscriptions_reason_only_with_discount
  check (discount_reason_id is null or (list_price_tiyin is not null and price_tiyin < list_price_tiyin));

create index if not exists subscriptions_discount_reason_idx
  on public.subscriptions (discount_reason_id, center_id);


-- из 0026_roles_registrar_rpc.sql; + auth.uid(), цена типа и причина скидки.
-- Новый аргумент меняет сигнатуру → DROP + CREATE (иначе две перегрузки, PGRST203).
drop function if exists public.sell_subscription(uuid, uuid, integer, date);

create function public.sell_subscription(
  p_type_id            uuid,
  p_student_id         uuid,
  p_price_tiyin        integer default null,
  p_starts_at          date default null,
  p_discount_reason_id uuid default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_type    public.subscription_types;
  v_student public.students;
  v_price   integer;
  v_reason  uuid;
  v_starts  date;
  v_ends    date;
  v_total   integer;
  v_id      uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_type from public.subscription_types
   where id = p_type_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Тип абонемента не найден' using errcode = '42704';
  end if;

  select * into v_student from public.students
   where id = p_student_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  v_price  := coalesce(p_price_tiyin, v_type.price_tiyin);

  -- Скидка — только с причиной из справочника (А4); без скидки причина не пишется.
  if v_price < v_type.price_tiyin then
    if p_discount_reason_id is null then
      raise exception 'Укажите причину скидки: цена % ниже цены типа %',
        public.format_som(v_price), public.format_som(v_type.price_tiyin)
        using errcode = '22023';
    end if;
    if not exists (
         select 1 from public.discount_reasons dr
          where dr.id = p_discount_reason_id and dr.center_id = v_center and dr.deleted_at is null
       ) then
      raise exception 'Причина скидки не найдена или в архиве' using errcode = '22023';
    end if;
    v_reason := p_discount_reason_id;
  end if;

  v_starts := coalesce(p_starts_at, public.center_today(v_center));
  v_total  := case when v_type.kind = 'unlimited' then null else v_type.lessons_count end;
  v_ends   := case when v_type.period_days is null then null
                   else v_starts + v_type.period_days end;

  insert into public.subscriptions (
    center_id, student_id, payer_id, type_id,
    lessons_total, price_tiyin, lesson_price_tiyin,
    starts_at, ends_at, list_price_tiyin, discount_reason_id
  )
  values (
    v_center, p_student_id, v_student.payer_id, p_type_id,
    v_total, v_price, public.calc_lesson_price(v_price, v_total),
    v_starts, v_ends, v_type.price_tiyin, v_reason
  )
  returning id into v_id;

  perform public.emit_event('subscription.created',
    jsonb_build_object('center_id', v_center, 'subscription_id', v_id,
                       'student_id', p_student_id, 'price_tiyin', v_price,
                       'list_price_tiyin', v_type.price_tiyin,
                       'lessons_total', v_total), v_center);
  return v_id;
end;
$$;

revoke execute on function public.sell_subscription(uuid, uuid, integer, date, uuid) from public, anon, authenticated;
grant execute on function public.sell_subscription(uuid, uuid, integer, date, uuid) to authenticated;


-- из 0029_salary_runs_and_payment_date.sql; + p_discount_reason_id в sell_subscription
drop function if exists public.sell_subscription_paid(uuid, uuid, uuid, integer, date, integer, uuid, date, integer, date, smallint, integer);

create function public.sell_subscription_paid(
  p_type_id                  uuid,
  p_student_id               uuid,
  p_sale_key                 uuid,
  p_price_tiyin              integer  default null,
  p_starts_at                date     default null,
  p_paid_tiyin               integer  default null,
  p_source_id                uuid     default null,
  p_paid_on                  date     default null,
  p_installments             integer  default null,
  p_first_due                date     default null,
  p_step_months              smallint default 1,
  p_expected_remaining_tiyin integer  default null,
  p_discount_reason_id       uuid     default null
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
  v_paid      integer := coalesce(p_paid_tiyin, 0);
  v_remaining integer;
begin
  if auth.uid() is null or not public.can_front_desk() then
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

  perform pg_advisory_xact_lock(hashtextextended(p_sale_key::text, 0));
  if exists (select 1 from public.subscriptions s where s.sale_key = p_sale_key) then
    raise exception 'Эта продажа уже проведена — обновите страницу' using errcode = '22023';
  end if;

  v_id := public.sell_subscription(p_type_id, p_student_id, p_price_tiyin, p_starts_at, p_discount_reason_id);

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
    v_payment := public.record_payment(
      v_sub.payer_id, v_paid, 'payment', p_student_id, v_id,
      p_source_id, null, 'Оплата при продаже абонемента', v_paid_on
    );
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

revoke execute on function
  public.sell_subscription_paid(uuid, uuid, uuid, integer, date, integer, uuid, date, integer, date, smallint, integer, uuid)
  from public, anon, authenticated;
grant execute on function
  public.sell_subscription_paid(uuid, uuid, uuid, integer, date, integer, uuid, date, integer, date, smallint, integer, uuid)
  to authenticated;


-- 10. Отчёт по скидкам (Р12, А6) ------------------------------------------------------------------

create or replace function public.subscription_discounts(p_from date, p_to date)
  returns table (
    subscription_id  uuid,
    sold_on          date,
    student_id       uuid,
    student_name     text,
    type_name        text,
    list_price_tiyin integer,
    price_tiyin      integer,
    discount_tiyin   integer,
    reason_id        uuid,
    reason_name      text,
    sold_by          uuid,
    sold_by_name     text,
    sold_by_role     text,
    status           text,
    archived         boolean
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
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  perform public.report_period_check(p_from, p_to);

  v_tz := public.center_timezone(v_center);

  -- Продажа со скидкой — уже факт, поэтому архивные и отменённые тоже в отчёте.
  -- Автор — имя карточки специалиста и роль (А6): email наружу не идёт.
  return query
    select s.id,
           (s.created_at at time zone v_tz)::date,
           s.student_id,
           st.full_name,
           sty.name,
           s.list_price_tiyin,
           s.price_tiyin,
           s.list_price_tiyin - s.price_tiyin,
           s.discount_reason_id,
           dr.name,
           s.created_by,
           tch.full_name,
           m.role,
           s.status,
           s.deleted_at is not null
      from public.subscriptions s
      left join public.students st            on st.id = s.student_id
      left join public.subscription_types sty on sty.id = s.type_id
      left join public.discount_reasons dr    on dr.id = s.discount_reason_id
      left join public.memberships m          on m.user_id = s.created_by and m.center_id = s.center_id
      left join public.teachers tch           on tch.id = m.teacher_id
     where s.center_id = v_center
       and s.list_price_tiyin is not null
       and s.price_tiyin < s.list_price_tiyin
       and s.created_at >= (p_from::timestamp at time zone v_tz)
       and s.created_at <  ((p_to + 1)::timestamp at time zone v_tz)
     order by s.created_at desc;
end;
$$;
comment on function public.subscription_discounts(date, date) is
  'Продажи абонементов со скидкой за период включительно (0101 Р12): цена типа, цена, скидка, причина, автор (имя карточки и роль, без email). can_finance.';

create or replace function public.subscription_discount_totals(p_from date, p_to date)
  returns table (
    is_total       boolean,
    reason_id      uuid,
    reason_name    text,
    sales          integer,
    discount_tiyin bigint
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
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  perform public.report_period_check(p_from, p_to);

  v_tz := public.center_timezone(v_center);

  -- Строка итога есть всегда (grouping sets с ()), различается по is_total, не по NULL причины.
  return query
    select grouping(s.discount_reason_id) = 1,
           s.discount_reason_id,
           case when grouping(s.discount_reason_id) = 1 then null else max(dr.name) end,
           count(s.id)::integer,
           coalesce(sum(s.list_price_tiyin - s.price_tiyin), 0)::bigint
      from public.subscriptions s
      left join public.discount_reasons dr on dr.id = s.discount_reason_id
     where s.center_id = v_center
       and s.list_price_tiyin is not null
       and s.price_tiyin < s.list_price_tiyin
       and s.created_at >= (p_from::timestamp at time zone v_tz)
       and s.created_at <  ((p_to + 1)::timestamp at time zone v_tz)
     group by grouping sets ((s.discount_reason_id), ())
     order by 1, 5 desc;
end;
$$;
comment on function public.subscription_discount_totals(date, date) is
  'Итоги скидок за период (0101 Р12): по причинам и строка итога (is_total). Суммы считает база — браузер не складывает деньги. can_finance.';

revoke all on function public.subscription_discounts(date, date), public.subscription_discount_totals(date, date) from public, anon;
grant execute on function public.subscription_discounts(date, date), public.subscription_discount_totals(date, date) to authenticated;


-- 11. Экспорт центра — allow-list 0093 плюс переводы и причины скидок -----------------------------

create or replace function public.export_center_tables()
  returns table (table_name text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('attendance'), ('attendance_statuses'), ('booking_requests'), ('cash_transfers'),
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
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. 0087: lesson_debt_writeoffs. 0088: lesson_debt_covers. 0090: subscription_shortfall_writeoffs. 0093: payment_voids. 0101: cash_transfers, discount_reasons. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
