-- =============================================================================
-- 0080_export_platform_exercises.sql — выгрузка центра с платформенными
-- упражнениями из его домашних заданий
--
-- Долг из 0074 Р8: export_center_table отдаёт строки center_id = центра, а
-- homework_exercises.exercise_id центра ссылается и на упражнения общей
-- библиотеки (center_id is null, 0074). В архиве ДЗ висели ссылки без названий.
--
-- Ревью плана — architect (блокеров нет):
--   Р1. Какие строки — одна функция export_center_predicate(p_table): её зовут и
--       export_center_table (файл), и record_center_export (счётчик в
--       center.exported). Дублировать case нельзя — файл и журнал разъехались бы
--       снова. Предикат опирается на алиас t и параметр $1 (центр) и
--       подставляется в format аргументом через %s, не склейкой шаблона.
--   Р2. Для exercise_library: свои строки ИЛИ (center_id is null И id из
--       homework_exercises этого центра). Явное center_id is null — чтобы даже
--       битая ссылка на упражнение чужого центра не вытащила чужую строку.
--       Включая удалённые ДЗ и неактивные/удалённые платформенные строки —
--       экспорт «целиком, включая архивное» (0056).
--   Р3. Другие таблицы не затронуты: nullable center_id в export_center_tables()
--       только у exercise_library и message_templates; на message_templates
--       никто не ссылается (центр перекрывает дефолт по event_type/channel).
--   Р4. Платформенные строки — данные платформы, данных детей в них нет.
--       Живые owner/admin и так читают через RLS 0036; удалённые RLS скрывает,
--       а выгрузка отдаёт (архив целиком, как для строк центра).
--   Р5. export_center_table и record_center_export переизданы от 0056 (других
--       определений нет); отличия — только строка execute format и comment.
--
-- Записано: при будущем импорте архива строки с center_id null в
-- exercise_library нужно пропускать, а не вставлять.
-- =============================================================================

create function public.export_center_predicate(p_table text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case p_table
    when 'exercise_library' then
      '(t.center_id = $1 or (t.center_id is null and t.id in '
      || '(select he.exercise_id from public.homework_exercises he where he.center_id = $1)))'
    else 't.center_id = $1'
  end;
$$;

comment on function public.export_center_predicate(text) is
  'Условие отбора строк выгрузки центра (0080 Р1) — общее для export_center_table и record_center_export, чтобы файл и счётчик в center.exported не расходились. Алиас t, параметр $1 = центр. exercise_library — ещё платформенные упражнения из ДЗ центра.';

revoke all on function public.export_center_predicate(text) from public, anon, authenticated, service_role;


create or replace function public.export_center_table(p_table text)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_result jsonb;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not exists (select 1 from public.export_center_tables() t where t.table_name = p_table) then
    raise exception 'Таблица недоступна для экспорта' using errcode = '42501';
  end if;

  -- p_table проверен по allow-list выше; format(%I) — вторым рубежом
  -- против инъекции, не единственным.
  execute format(
    'select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t where %s',
    p_table, public.export_center_predicate(p_table)
  ) into v_result using v_center;

  return v_result;
end;
$$;

comment on function public.export_center_table(text) is
  'Одна таблица экспорта центра за вызов (0056 Р4) — веб собирает файл, обходя export_center_tables(). Без deleted_at is null: экспорт — вынос данных клиента целиком, включая архивное. Какие строки — export_center_predicate (0080: в exercise_library ещё платформенные упражнения из ДЗ центра).';

revoke all on function public.export_center_table(text) from public, anon, service_role;
grant execute on function public.export_center_table(text) to authenticated;


create or replace function public.record_center_export()
  returns bigint
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_id     bigint;
  v_counts jsonb := '{}'::jsonb;
  v_table  record;
  v_n      integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for v_table in select table_name from public.export_center_tables() loop
    execute format('select count(*) from public.%I t where %s',
                   v_table.table_name, public.export_center_predicate(v_table.table_name))
      into v_n using v_center;
    v_counts := v_counts || jsonb_build_object(v_table.table_name, v_n);
  end loop;

  v_id := public.emit_event('center.exported', jsonb_build_object('tables', v_counts), v_center);
  return v_id;
end;
$$;

comment on function public.record_center_export() is
  '«Вынос базы клиентов» обязан оставить след (0056 Р11) — веб зовёт одним вызовом после сборки файла. Число строк по таблице пересчитывает сама функция, не верит аргументу (0056 Р7, находка 7); строки — тем же export_center_predicate, что и файл (0080).';

revoke all on function public.record_center_export() from public, anon, service_role;
grant execute on function public.record_center_export() to authenticated;
