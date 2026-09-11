-- =============================================================================
-- 0016_expenses.sql — расходы (этап 5, промт п.3)
--
-- Устройство целиком по образцу payment_sources/payments (0013, поправленных
-- 0014), а не изобретено заново — architect-ревью плана в истории сессии
-- нашло 11 дыр именно там, где план расходился с уже работающим образцом.
--
--   1. expense_categories — справочник по образцу payment_sources: сид при
--      create_center, архив/восстановление через RPC, а не свободный текст
--      (переименование категории задним числом иначе невозможно — тот же
--      повод, что у payment_sources.code в 0013).
--   2. expenses — kind + знак суммы, как у payments: ошибочный расход
--      правится строкой kind='correction' с обратным знаком, а не update
--      (прямая запись закрыта совсем). source_id — иначе «касса по
--      источникам» из промта (п.9) не сможет учесть расход, вынутый из
--      той же кассы, что и приход.
--   3. record_expense — RPC, не прямой insert: событие обязано быть в одной
--      транзакции со вставкой (иначе подделываемо), created_by не должен
--      подделываться колоночным грантом, а kind/знак — не клиентская
--      ответственность. Дата — p_paid_on date, не timestamptz с клиента:
--      расход, собранный в браузере не по часовому поясу центра, рискует
--      попасть не в тот месяц замка.
--   4. financial_period_guard расширен веткой expenses и телом СТРОГО из
--      0014 (там уже исправлены падение 55000 на DELETE и англ. месяц из
--      локали) — переписывать с тела 0013 значило бы вернуть обе находки.
--      Добавлена ветка else raise exception: триггер на таблице без ветки
--      в этой функции раньше молча не проверял вообще ничего.
--
-- Второй раунд (архитектор против написанного выше, до коммита):
--   Б1. expense_categories осталась с дефолтными грантами Supabase (включая
--       DELETE) — буквальный повтор находки 0014 про payment_sources.
--       Добавлен revoke all + точечные гранты.
--   Б2. expense_categories_read_all копировала приём payment_sources без
--       копии причины: parent там видит свои платежи и должен понимать,
--       чем платил, у expenses такого читателя нет и не планируется по ТЗ
--       ("RLS admin"). Заменена на read-only архив для owner/admin (живые
--       строки уже видны через apply_tenant_rls) — по образцу
--       subscription_types (0012), не attendance_statuses.
--   Б3. Знак amount_tiyin у expenses и payments одинаковый по устройству,
--       но противоположный по смыслу — комментарий ошибочно утверждал
--       прямую совместимость. Уточнён comment on column: будущая витрина
--       "касса по источникам" обязана инвертировать один из знаков.
--   Б4. Пустая category_id давала английский 23502 напрямую пользователю.
--       Добавлена ветка в errors.ts (apps/web/lib/errors.ts).
--   Б5. Недостающие индексы под составные FK (category_id, source_id) —
--       Advisor находил бы unindexed_foreign_keys.
-- =============================================================================


-- 1. expense_categories — справочник статей расхода ------------------------------

create table if not exists public.expense_categories (
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

  constraint expense_categories_id_center_key unique (id, center_id)
);

create unique index if not exists expense_categories_center_code_idx
  on public.expense_categories (center_id, code) where deleted_at is null;

drop trigger if exists expense_categories_set_updated_at on public.expense_categories;
create trigger expense_categories_set_updated_at before update on public.expense_categories
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('expense_categories');
call public.apply_audit('expense_categories');

-- В отличие от payment_sources, читатель шире owner/admin здесь не нужен:
-- expenses (в отличие от payments) не видна ни teacher, ни parent вообще —
-- у payment_sources широкий read_all оправдан тем, что родитель видит свои
-- платежи и должен понимать, чем платил; у расходов такого потребителя нет
-- и по ТЗ не планируется (docs/Roadmap/stages.md, этап 5: "expenses ...
-- RLS admin"). tenant_admin (apply_tenant_rls) уже даёт owner/admin доступ
-- к живым строкам; отдельная политика — только на архивные, тем же owner/
-- admin, для экрана архива в настройках (subscription_types, 0012, а не
-- attendance_statuses — тот тоже был неоправданно широким).
drop policy if exists expense_categories_read_archived on public.expense_categories;
create policy expense_categories_read_archived on public.expense_categories
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() in ('owner', 'admin')
    and deleted_at is not null
  );

-- Supabase выдаёт authenticated полный набор прав на новую таблицу по
-- умолчанию, включая DELETE (та же находка, что 0014 закрывала для
-- payment_sources, 0014_finance_core_fixes.sql:268-275, там же — payment_
-- sources прожила без этого revoke всю 0013). Прямая запись — только
-- справочные поля; deleted_at меняют только RPC ниже.
revoke all on public.expense_categories from anon, authenticated;
grant select, insert on public.expense_categories to authenticated;
grant update (code, name, is_active, sort) on public.expense_categories to authenticated;

-- Проверка — по происхождению вызова (pg_trigger_depth), не по роли: центр
-- только что создан, my_role() для него ещё законно null. Прежняя ошибка
-- этого же вида (seed_payment_sources, 0014, находка Б1) проверяла
-- coalesce(my_role(),'') not in (...) — отбивала ровно вызов из триггера
-- и пропускала прямой вызов без auth.uid(), ломая любую регистрацию.
create or replace function public.seed_expense_categories(p_center_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if pg_trigger_depth() = 0 and auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  insert into public.expense_categories (center_id, code, name, sort) values
    (p_center_id, 'rent',      'Аренда',              10),
    (p_center_id, 'utilities', 'Коммунальные услуги', 20),
    (p_center_id, 'salary',    'Зарплата',            30),
    (p_center_id, 'supplies',  'Материалы',           40),
    (p_center_id, 'marketing', 'Реклама',             50),
    (p_center_id, 'other',     'Прочее',              60)
  on conflict do nothing;
end;
$$;

create or replace function public.centers_seed_expense_categories()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform public.seed_expense_categories(new.id);
  return null;
end;
$$;

drop trigger if exists centers_seed_expense_categories on public.centers;
create trigger centers_seed_expense_categories
  after insert on public.centers
  for each row execute function public.centers_seed_expense_categories();

-- Существующим центрам категории тоже нужны — staging не пустой.
do $$
declare v_id uuid;
begin
  for v_id in select id from public.centers where deleted_at is null loop
    perform public.seed_expense_categories(v_id);
  end loop;
end $$;

create or replace function public.archive_expense_category(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.expense_categories
     set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Статья расхода не найдена' using errcode = '42704';
  end if;

  perform public.emit_event('expense_category.archived',
    jsonb_build_object('center_id', v_center, 'category_id', p_id), v_center);
end;
$$;

create or replace function public.restore_expense_category(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_code   text;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select code into v_code
    from public.expense_categories
   where id = p_id and center_id = v_center and deleted_at is not null;

  if not found then
    raise exception 'Статья расхода не найдена в архиве' using errcode = '42704';
  end if;

  begin
    update public.expense_categories
       set deleted_at = null
     where id = p_id and center_id = v_center;
  exception
    when unique_violation then
      raise exception 'Код «%» уже занят другой статьёй — переименуйте перед восстановлением', v_code
        using errcode = '22023';
  end;

  perform public.emit_event('expense_category.restored',
    jsonb_build_object('center_id', v_center, 'category_id', p_id), v_center);
end;
$$;


-- 2. expenses — сам факт расхода ---------------------------------------------------

create table if not exists public.expenses (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  category_id   uuid not null,
  source_id     uuid,
  -- Знак — часть суммы, не отдельный флаг: sum(amount_tiyin) внутри ЭТОЙ
  -- таблицы в любом отчёте (расходы по категориям, за месяц) всегда даёт
  -- правильный итог без отдельного filter по kind — тот же приём, что
  -- payments.amount_tiyin. Знак НЕ совместим с payments напрямую: у payments
  -- плюс — деньги пришли, здесь плюс — деньги ушли. Будущая витрина "касса
  -- по источникам" (docs/Roadmap/stages.md, этап 5, п.9), объединяющая обе
  -- таблицы, обязана инвертировать один из знаков перед суммированием —
  -- иначе расход задвоится вместо вычитания. См. comment on column ниже.
  amount_tiyin  integer not null,
  paid_at       timestamptz not null default now(),
  kind          text not null default 'expense',
  comment       text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),

  constraint expenses_id_center_key unique (id, center_id),
  constraint expenses_category_fk
    foreign key (category_id, center_id) references public.expense_categories (id, center_id),
  constraint expenses_source_fk
    foreign key (source_id, center_id) references public.payment_sources (id, center_id),
  constraint expenses_amount_not_zero check (amount_tiyin <> 0),
  constraint expenses_kind_known check (kind in ('expense', 'refund', 'correction')),
  constraint expenses_sign_matches_kind check (
    (kind = 'expense' and amount_tiyin > 0) or
    (kind = 'refund' and amount_tiyin < 0) or
    (kind = 'correction')
  )
);

-- (center_id, paid_at), не отдельный center_id: страница расходов запрашивает
-- диапазон месяца, отдельный индекс по одному center_id был бы избыточен.
create index if not exists expenses_center_paid_at_idx on public.expenses (center_id, paid_at);
-- Под составные FK — иначе Advisor находит unindexed_foreign_keys, а правка
-- строки справочника (архив/переименование) проверяет ссылки seq-сканом.
create index if not exists expenses_category_idx on public.expenses (category_id);
create index if not exists expenses_source_idx on public.expenses (source_id);

comment on column public.expenses.amount_tiyin is
  'Положительная сумма = деньги ушли из кассы. Знак не совместим с payments.amount_tiyin напрямую (там плюс — деньги пришли) — сводная витрина по обеим таблицам обязана инвертировать один из знаков перед суммированием.';

drop trigger if exists expenses_set_updated_at on public.expenses;
create trigger expenses_set_updated_at before update on public.expenses
  for each row execute function extensions.moddatetime(updated_at);

-- Нет deleted_at: ничего не редактируется и не удаляется, ошибку правит
-- новая строка с kind='correction' — как у payments, и по той же причине:
-- financial_period_guard ниже смотрит и на old.paid_at, значит update
-- deleted_at на расходе из уже закрытого месяца всё равно был бы отбит
-- замком, и soft-delete не дал бы того, ради чего его обычно заводят.
call public.apply_tenant_rls('expenses', false);
call public.apply_audit('expenses');

-- Вставка закрыта совсем — только через record_expense: event обязан быть
-- в одной транзакции со вставкой, а created_by не должен подделываться
-- клиентом (колоночный грант на insert это разрешил бы). Из update открыт
-- только comment — как у payments, поправить опечатку без отдельной
-- корректировки; сумму, дату и категорию правит новая kind='correction'.
revoke all on public.expenses from anon, authenticated;
grant select on public.expenses to authenticated;
grant update (comment) on public.expenses to authenticated;


-- 3. record_expense ------------------------------------------------------------

-- p_paid_on — дата, не timestamptz: момент собирается здесь, по часовому
-- поясу центра, а не в браузере клиента. Расход, датированный в браузере не
-- по поясу центра, рисковал бы попасть не в тот календарный месяц замка
-- (тот же класс бага, что чинили в этой сессии для e2e-фикстуры — два
-- разных вычисления "какой это день" расходятся на границе суток).
--
-- Сознательно не проверяет, что category_id/source_id не архивные —
-- унаследованная, не новая дыра: record_payment точно так же не проверяет
-- payment_sources.deleted_at. Архивная запись продолжает принимать новые
-- расходы/платежи, пока кто-то не построит для обоих отдельный инвариант.
-- Не относится к 0016 точечно — фиксируется как известное ограничение
-- целиком для payment_sources/expense_categories в отчёте по этапу.
create or replace function public.record_expense(
  p_category_id uuid,
  p_amount_tiyin integer,
  p_kind        text default 'expense',
  p_source_id   uuid default null,
  p_paid_on     date default null,
  p_comment     text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_paid_on date;
  v_id      uuid;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_paid_on := coalesce(p_paid_on, public.center_today(v_center));

  insert into public.expenses (
    center_id, category_id, source_id, amount_tiyin, paid_at, kind, comment, created_by
  )
  values (
    v_center, p_category_id, p_source_id, p_amount_tiyin,
    (v_paid_on::timestamp) at time zone public.center_timezone(v_center),
    p_kind, p_comment, auth.uid()
  )
  returning id into v_id;

  perform public.emit_event('expense.recorded',
    jsonb_build_object(
      'center_id', v_center, 'expense_id', v_id, 'category_id', p_category_id,
      'amount_tiyin', p_amount_tiyin, 'kind', p_kind
    ),
    v_center
  );

  return v_id;
end;
$$;


-- 4. financial_period_guard — ветка expenses, плюс else на молчание --------------

-- Тело — из 0014 (financial_period_guard_lessons и 0014_finance_core_fixes.
-- sql:284-355), не из 0013: там уже исправлены падение 55000 на DELETE
-- (new/old неназначены) и английское название месяца из локали сервера.
-- Переписать с тела 0013 значило бы молча вернуть обе находки.
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
    -- Триггер на таблице без ветки здесь раньше молча пропускал бы любую
    -- операцию — замок бы не работал, и ни ошибки, ни предупреждения.
    -- Громкий отказ вместо тихого no-op: опечатка в tg_table_name или
    -- забытая ветка обнаружится на первом же прогоне pgTAP, а не после
    -- того, как сойдутся две ведомости.
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

drop trigger if exists financial_period_guard_expenses on public.expenses;
create trigger financial_period_guard_expenses
  before insert or update or delete on public.expenses
  for each row execute function public.financial_period_guard();


-- Гранты -------------------------------------------------------------------------

revoke execute on function
  public.centers_seed_expense_categories()
  from public, anon, authenticated;

revoke execute on function
  public.seed_expense_categories(uuid),
  public.archive_expense_category(uuid),
  public.restore_expense_category(uuid),
  public.record_expense(uuid, integer, text, uuid, date, text)
  from public, anon, authenticated;

grant execute on function
  public.archive_expense_category(uuid),
  public.restore_expense_category(uuid),
  public.record_expense(uuid, integer, text, uuid, date, text)
  to authenticated;
