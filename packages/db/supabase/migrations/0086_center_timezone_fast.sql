-- =============================================================================
-- 0086_center_timezone_fast.sql — пояс центра без скана tzdata на каждый вызов
--
-- Проблема. center_timezone() из 0052 (Р7) при каждом вызове проверяла имя
-- через pg_catalog.pg_timezone_names — это чтение каталога tzdata с диска,
-- ~53 мс на вызов (замер на staging: 80 вызовов — 4,2 с). Функция security
-- definer не инлайнится и зовётся построчно: calc_salary (0027) — по 2–3 раза
-- на каждую отметку посещения в предикате WHERE, salary_summary (0029) —
-- calc_salary на каждого специалиста. В e2e /app/salary упала в
-- `canceling statement due to statement timeout` при паре десятков отметок;
-- на проде то же наступило бы с ростом посещений, и не только в зарплате.
--
-- Решения:
--   Р1. Инвариант «в settings->>'timezone' — только имя из pg_timezone_names»
--       держит триггер на запись (CLAUDE.md: инвариант — триггер, не проверка в
--       функции), а не center_timezone() при каждом чтении. Проверка стоит
--       ~50 мс один раз на запись, чтение — один поиск по первичному ключу.
--   Р2. Триггер проверяет только INSERT и UPDATE, меняющий сам пояс: иначе
--       set_booking_enabled (0057, settings || {booking_enabled}) у центра со
--       старым значением отказывал бы «Неизвестный часовой пояс» на кнопку,
--       которая пояс не трогала, и платил бы лишние 50 мс на каждый вызов.
--   Р3. Точное совпадение с pg_timezone_names, без учёта регистра — нет: в
--       Postgres «asia/bishkek» работает, а SQL до 0086 считал его мусором,
--       одна форма записи на весь проект. Строки POSIX вида «UTC+6» и
--       аббревиатуры «MSK» Postgres принимает (с обратным знаком у POSIX!),
--       а Intl в браузере — нет: имя из списка — единственная форма, которую
--       одинаково понимают SQL и apps/web/lib/timezone.ts.
--   Р4. Существующие значения нормализуются ДО создания триггера: совпадение
--       без учёта регистра — к каноническому имени (Intl в браузере принимает
--       «asia/almaty» и показывал время по Алматы — подмена на Бишкек молча
--       сдвинула бы интерфейс на час); остальное — ключ удаляется (подставленный
--       Asia/Bishkek выглядел бы выбором владельца). Только для settings-объекта:
--       `-` на скаляре падает. 3.10.2026 и на prod, и на staging таких строк 0 —
--       шаг страховочный; старое значение сохраняет centers_audit.
--   Р5. Триггерная функция — security invoker: pg_timezone_names читают все, а
--       definer требовал бы проверки auth.uid() по CLAUDE.md и ломал бы
--       вставки без сессии (фикстуры). EXECUTE снят у всех ролей, как у
--       триггерных функций 0049/0036.
--   Р6. center_timezone() — тело 0006 без проверки при чтении. Сигнатура,
--       stable, security definer, search_path, гранты — как в 0052.
--       Инлайнинг не нужен и невозможен: definer и set search_path его
--       блокируют, а снимать их — риск подмены через search_path и RLS
--       centers_select_members в invoker-контексте вью.
--
-- Остаточный риск (принят осознанно). Триггер видит только записи. Имя может
-- стать невалидным без записи — при обновлении образа Postgres с другим tzdata
-- (бывало: US/Pacific-New, Canada/East-Saskatchewan). Тогда `at time zone`
-- упадёт с 22023 у этого центра, а ежедневный дайджест (0032) — у всех.
-- Проверочный запрос после каждого обновления Postgres в проекте — в
-- docs/Database.md, раздел «Часовой пояс».
--
-- Известный остаток (не в этой миграции). Предикаты по дате в calc_salary
-- (0027), close_month (0031) и др. по-прежнему вычисляют пояс построчно и не
-- используют индекс по starts_at. После 0086 вызов — микросекунды, но цена
-- растёт линейно с историей; переписать на границы timestamptz с поясом в
-- переменной (как 0027:618) — отдельной миграцией.
-- =============================================================================


-- Р4. Нормализация существующих значений (до триггера) ---------------------------------------------

update public.centers c
   set settings = jsonb_set(c.settings, '{timezone}', to_jsonb(z.name))
  from pg_catalog.pg_timezone_names z
 where jsonb_typeof(c.settings) = 'object'
   and jsonb_typeof(c.settings -> 'timezone') = 'string'
   and lower(z.name) = lower(c.settings ->> 'timezone')
   and z.name <> (c.settings ->> 'timezone')
   and not exists (
     select 1 from pg_catalog.pg_timezone_names e where e.name = c.settings ->> 'timezone');

update public.centers c
   set settings = c.settings - 'timezone'
 where jsonb_typeof(c.settings) = 'object'
   and c.settings ? 'timezone'
   and (jsonb_typeof(c.settings -> 'timezone') <> 'string'
        or not exists (
          select 1 from pg_catalog.pg_timezone_names z where z.name = c.settings ->> 'timezone'));


-- Р1–Р3, Р5. Триггер на запись -----------------------------------------------------------------------

create or replace function public.centers_validate_timezone()
  returns trigger
  language plpgsql
  security invoker
  set search_path = ''
as $$
declare
  v_tz jsonb := case when jsonb_typeof(new.settings) = 'object' then new.settings -> 'timezone' end;
begin
  -- Р2: UPDATE, не меняющий пояс, не проверяется — ни отказа, ни скана tzdata.
  if tg_op = 'UPDATE'
     and v_tz is not distinct from
         (case when jsonb_typeof(old.settings) = 'object' then old.settings -> 'timezone' end) then
    return new;
  end if;

  if v_tz is null then
    return new;
  end if;

  if jsonb_typeof(v_tz) <> 'string'
     or not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz #>> '{}') then
    raise exception 'Неизвестный часовой пояс: %. Укажите имя из списка, например Asia/Bishkek', coalesce(v_tz #>> '{}', 'пусто')
      using errcode = '22023';
  end if;

  return new;
end;
$$;
comment on function public.centers_validate_timezone() is
  'Триггер centers: settings->>''timezone'' — только точное имя из pg_timezone_names. Проверяется на INSERT и на UPDATE, меняющем пояс (0086 Р1–Р3). Держит инвариант, на который опирается center_timezone() без проверки при чтении.';

revoke all on function public.centers_validate_timezone() from public, anon, authenticated, service_role;

drop trigger if exists centers_validate_timezone on public.centers;
create trigger centers_validate_timezone
  before insert or update of settings on public.centers
  for each row execute function public.centers_validate_timezone();


-- Р6. center_timezone — один поиск по ключу ------------------------------------------------------------

create or replace function public.center_timezone(p_center_id uuid default null)
  returns text
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(
    (select c.settings ->> 'timezone'
       from public.centers c
      where c.id = coalesce(p_center_id, public.current_center())),
    'Asia/Bishkek'
  );
$$;
comment on function public.center_timezone(uuid) is
  'Пояс центра из settings->>''timezone'', дефолт Asia/Bishkek. Проверки имени при чтении нет (с 0086): валидность держит триггер centers_validate_timezone на запись. Имя может устареть при обновлении tzdata без записи — проверочный запрос в docs/Database.md, «Часовой пояс».';

revoke all on function public.center_timezone(uuid) from public, anon;
grant execute on function public.center_timezone(uuid) to authenticated;

comment on column public.centers.settings is
  'Настройки центра (jsonb): city, features (меняет только платформа — centers_protect_plan), booking_enabled (set_booking_enabled), timezone — имя из pg_timezone_names (centers_validate_timezone, 0086), по умолчанию Asia/Bishkek.';
