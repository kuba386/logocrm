-- =============================================================================
-- 0086_center_timezone_fast.sql — center_timezone() без pg_timezone_names
--
-- Инцидент. С 0052 center_timezone() проверяла имя пояса через
-- pg_catalog.pg_timezone_names, а это представление на каждом обращении
-- перечитывает каталог tzdata с диска: ~50 мс на вызов (staging, 80 вызовов —
-- 4 с). Функция стоит в 126 местах 38 миграций, в том числе по строке в WHERE
-- calc_salary (0027, три вызова на посещение): salary_summary в CI падал
-- «canceling statement due to statement timeout» — на проде это наступило бы
-- примерно при 50 посещениях специалиста за месяц.
--
--   Р1. Проверка — в два шага, оба за микросекунды (замер staging: 11 мкс на
--       валидном имени, 30 мкс на мусорном):
--       1) шаблон IANA «Область/Место» или «UTC», не длиннее 64 символов;
--       2) `now() at time zone` в блоке исключений — имя, похожее на IANA, но
--          неизвестное tzdata («Mars/Olympus»), даёт 22023.
--       Шаг 1 обязателен, а не украшение: `at time zone` принимает и
--       аббревиатуры (MSK — ещё и в зависимости от сессионной
--       timezone_abbreviations), и смещения/POSIX (+6, UTC+6, +06:00), где знак
--       обратный: «+6» — это UTC−6. Без шаблона владелец, написавший «+6» вместо
--       Asia/Bishkek, получил бы расчёты на 12 часов в сторону, а «MSK» уронил
--       бы Intl на странице платформы (platform_open_payments отдаёт пояс туда)
--       — ровно межтенантный отказ, который закрывала 0052 Р7.
--   Р2. Семантика 0052 сохранена для всех прежних входов: нет центра, нет
--       ключа, пустая строка, число, мусор — Asia/Bishkek. pgTAP 0052
--       (Mars/Olympus) зелёный без правок.
--   Р3. TS-зеркало — packages/core/src/timezone.ts (то же выражение и Intl
--       вместо `at time zone`), общий набор случаев в Vitest и pgTAP 0086.
--       apps/web/lib/timezone.ts centerTimeZone() раньше пояс не проверял и
--       падал на мусоре RangeError'ом во всём /app центра.
--   Р4. Ловим только invalid_parameter_value: F0000 (сломанный файл
--       timezone_abbreviations) — ошибка конфигурации, её надо видеть громко.
--   Р5. Блок исключений — субтранзакция на вызов; в параллельном режиме она
--       запрещена («cannot start subtransactions during a parallel
--       operation»). Функция обязана остаться PARALLEL UNSAFE (по умолчанию) —
--       пометка parallel safe уронила бы calc_salary, витрины 0021/0028 и
--       политики на любом плане с Gather. pgTAP держит proparallel = 'u'.
--   Р6. Без проверки auth.uid() и прав на центр — исключение из правила
--       CLAUDE.md, как во всех версиях с 0006: её зовут планировщики без
--       сессии (n8n), platform_* (администратор платформы не участник центра)
--       и invoker-витрины. Отдаёт только имя пояса, для чужого/несуществующего
--       центра ответ совпадает с дефолтом — это не данные и не оракул.
--   Р7. Смена language sql → plpgsql ничего не меняет в планах: definer-
--       функцию с SET Postgres не инлайнит и раньше. create or replace
--       сохраняет OID — витрины и тела функций, где она вызвана, не трогаются.
-- =============================================================================

create or replace function public.center_timezone(p_center_id uuid default null)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_tz text;
begin
  select c.settings ->> 'timezone'
    into v_tz
    from public.centers c
   where c.id = coalesce(p_center_id, public.current_center());

  -- Р1, шаг 1: только IANA «Область/Место» или UTC. То же выражение —
  -- CENTER_TIME_ZONE_PATTERN в packages/core/src/timezone.ts.
  if v_tz is null
     or length(v_tz) > 64
     or v_tz !~ '^(UTC|[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+)+)$' then
    return 'Asia/Bishkek';
  end if;

  -- Р1, шаг 2: tzdata знает это имя.
  begin
    perform pg_catalog.now() at time zone v_tz;
    return v_tz;
  exception when invalid_parameter_value then
    return 'Asia/Bishkek';
  end;
end;
$$;

comment on function public.center_timezone(uuid) is
  'Пояс центра из settings->>''timezone''. Только имя IANA «Область/Место» или UTC, известное tzdata; иначе (нет, пусто, мусор, аббревиатура, смещение) — Asia/Bishkek. С 0086 без pg_timezone_names (50 мс на вызов). PARALLEL UNSAFE обязательно: блок исключений. Без проверки auth.uid() намеренно — зовут планировщики и platform_*. Зеркало — packages/core/src/timezone.ts.';

revoke all on function public.center_timezone(uuid) from public, anon;
grant execute on function public.center_timezone(uuid) to authenticated;
