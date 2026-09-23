-- =============================================================================
-- 0056_center_export_deletion.sql — экспорт данных центра и заявка на
-- удаление (этап 8a, шаг 7)
--
-- План — reports/stage-8.md, раздел «Функции» (export_center/
-- export_center_audit/request_center_deletion). Ревью плана архитектором
-- 24.09.2026 (13 находок) — ниже как Р-условия.
--
--   Р1. Экспорт — ЯВНЫЙ allow-list (export_center_tables()), не «каталог
--       минус deny-list». Динамический список делает забор бессмысленным:
--       новая таблица с center_id попадала бы в выгрузку молча, а pgTAP
--       «в экспорте или в deny» был бы зелёным тривиально. Забор здесь —
--       наоборот: allow ∪ deny обязаны покрыть весь каталог, а новая
--       таблица без решения роняет CI.
--
--   Р2. Секреты исключены целиком, не колонками: invitations (token,
--       единственный секрет по 0004) и lesson_voice_requests (storage-
--       путь голосового) — в deny-list. export_center_audit() тоже
--       вычёркивает audit-строки по этим двум таблицам: old_data/new_data
--       несут те же токены (apply_audit пишет их и туда).
--
--   Р3. Ни в одной функции нет параметра p_center_id. Всегда
--       current_center(): именно так закрывается межцентровая выгрузка —
--       проверка роли по my_role()/JWT при свободном p_center_id
--       открывает чужой центр целиком через один RPC-вызов из консоли
--       браузера (ADR-002: критичные операции проверяют role_in(), а не
--       JWT — здесь эта проблема снята радикальнее, самим отсутствием
--       параметра).
--
--   Р4. export_center_table(p_table text) — по одной таблице за вызов, не
--       jsonb_object_agg по всему центру разом: у платного центра за пару
--       лет attendance/lessons/notification_log вместе упёрлись бы в
--       statement_timeout, и кнопка «Экспорт» превратилась бы в кнопку
--       «ничего не делает». Веб собирает файл, обходя export_center_tables().
--
--   Р5. security definer с explicit allow-list — сознательный отход от
--       строки в reports/stage-8.md «через RLS каждой таблицы». RLS-путь
--       (invoker) тише сегодня, но исключил бы из экспорта ровно то, на
--       что у admin нет прямого гранта (ai_jobs и подобные — и так вне
--       allow-list), а при следующем сужении политики (ADR-009, клиника)
--       стал бы неотличим от «экспорт тише, чем должен быть». definer +
--       ручной allow-list даёт один явный список, который правится
--       осознанно, а не наследует чужое решение о видимости.
--
--   Р6. Центр читает свою собственную RLS-дыру: centers_update_owner
--       (0001) разрешала update owner БЕЗ ограничения по колонкам, а
--       centers_protect_plan (0049) не знает про deleted_at — прямой PATCH
--       {"deleted_at": "now()"} от owner проходил уже сегодня, в обход
--       request_center_deletion(), без события и без единообразной
--       ошибки (CLAUDE.md: прямой PATCH в обход RPC — отказ). Чинится в
--       самой политике (with check deleted_at is null) — RLS не судит
--       security definer функции, владеющие таблицей (в проекте нет ни
--       одного force row level security), поэтому GUC-флаг не нужен:
--       RPC проходит всегда, прямой PATCH — никогда.
--
--   Р7. center_write_state(uuid) returns text ('ok'|'expired'|'deleted'|
--       'missing') — единственный источник причины. center_writable()
--       становится тонкой обёрткой (state = 'ok'), чтобы не переписывать
--       вызывающих 0050/0053. center_readonly_guard() выбирает текст
--       PT402 по состоянию: «удалён» — не то же самое, что «истекла
--       подписка», и требование «оплатите» после нажатия «Удалить центр»
--       читалось бы как издевательство. center_limits() отдаёт то же
--       состояние ключом state рядом с writable — баннер получает его тем
--       же одним запросом.
--
--   Р8. request_center_deletion(p_confirm_name text) — owner (не admin):
--       admin в проекте — нанимаемая роль (заводится приглашением другого
--       admin/owner, 0004), дать ей выключить бизнес целиком — не то же
--       самое, что дать менять расписание. p_confirm_name сверяется с
--       centers.name внутри функции — диалог в React не мешает вызвать
--       RPC из консоли или кликнуть мимо, аргумент мешает. Идемпотентна
--       (where deleted_at is null) — повторное нажатие не двигает будущий
--       срок физической очистки (ADR-012, не в этом этапе) и не плодит
--       события.
--
--   Р9. cancel_center_deletion() — owner, снимает deleted_at, событие
--       center.deletion_cancelled. Без неё 30-дневная отсрочка существует
--       только в базе: centers_select_members требует deleted_at is null,
--       significant centers_update_owner (Р6) — тоже, owner не может
--       передумать ни кнопкой, ни PATCH.
--
--   Р10. center_deletion_state() — та же проблема с другой стороны: после
--        удаления owner не видит СТРОКУ своего центра через обычный
--        select (RLS её прячет), значит нечем нарисовать экран отсрочки
--        («удалён такого-то числа, доступны экспорт и отмена»). Отдельная
--        definer-функция — глазок в спрятанную RLS строку, не правка
--        общей SELECT-политики (которая используется всеми ролями, не
--        только owner).
--
--   Р11. emit_event('center.exported', {tables}, ...) — каждый вызов
--        export_center_table() ОДНОЙ строкой на весь экспорт не годится
--        (по вызову на таблицу их будет 39), поэтому событие пишет не
--        сама функция таблицы, а веб одним вызовом record_center_export()
--        после сборки файла — «вынос базы клиентов» обязан оставить след
--        (events — в списке исключений guard 0050, пишется и в
--        read-only, и в удалённом центре). Без аргументов: число строк по
--        каждой таблице функция пересчитывает сама, а не верит тому, что
--        передал вызывающий (Р7 в веб-разделе не годится тем же путём,
--        каким деньги/права не считаются в браузере).
--
--   Р12. center.deletion_requested — новый тип в notification_event_types
--        (audience center, 0037/0051), owner/admin получают уведомление:
--        второй совладелец узнаёт об удалении не из баннера «оплатите»
--        (это и был бы п.9 без этого пункта), а из отдельного сообщения.
--        event_messages() (0053) получает новую ветку — без переменных,
--        шаблон только по умолчанию.
--
--   Р13. Забор pgTAP — information_schema, но физически ПЕРВЫМ в файле,
--        до любого set role/tests_claims() (как tests/0050_center_
--        readonly.test.sql): под ролью-владельцем видно всё, а
--        information_schema фильтруется правами только у непривилегированной
--        роли. Заменить на pg_catalog (pg_class/pg_attribute) было бы
--        надёжнее к перестановке кода, но раз позиция — часть контракта,
--        а не случайность, следующий автор переносить забор ниже не
--        должен: иначе таблицы без гранта authenticated (ai_jobs,
--        lesson_voice_requests) тихо исчезнут из сравнения. Только
--        базовые таблицы (table_type = 'BASE TABLE') — иначе вью
--        (pending_invitations_view — те же токены, staff_view,
--        student_balance) попали бы в сравнение.
--
--   Р14. submit_platform_payment (0051) переиздана — отказ PT402 для
--        удалённого центра. До этой миграции centers.deleted_at не мог
--        выставить никто, поэтому взаимодействие спало: без проверки
--        владелец платит за центр, который сам же попросил удалить, а
--        заявка выпадает из очереди платформы (platform_open_payments/
--        platform_centers, 0052, фильтруют deleted_at is null) и виснет
--        неподтверждённой (ревью написанного SQL 24.09.2026, находка 5).

-- 1. Р6: RLS-дыра на centers.deleted_at ----------------------------------------------------------

drop policy if exists centers_update_owner on public.centers;
create policy centers_update_owner on public.centers
  for update to authenticated
  using (public.role_in(id) = 'owner' and deleted_at is null)
  with check (public.role_in(id) = 'owner' and deleted_at is null);


-- 2. center_write_state — источник причины для guard/limits (Р7) ---------------------------------

create or replace function public.center_write_state(p_center_id uuid)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_c     public.centers;
  v_tz    text;
  v_until timestamptz;
begin
  select * into v_c from public.centers where id = p_center_id;
  if not found then
    return 'missing';
  end if;
  if v_c.deleted_at is not null then
    return 'deleted';
  end if;

  v_until := case when v_c.plan = 'trial' then v_c.trial_ends_at else v_c.subscription_until end;
  if v_until is null then
    return 'expired';
  end if;

  -- 0050 Р11: до конца дня истечения в поясе центра.
  v_tz := public.center_timezone(p_center_id);
  if (v_until at time zone v_tz)::date >= (now() at time zone v_tz)::date then
    return 'ok';
  end if;
  return 'expired';
end;
$$;

comment on function public.center_write_state(uuid) is
  'Причина read-only одним словом: ok/expired/deleted/missing (0056 Р7) — источник и для center_writable(), и для текста PT402, и для center_limits().state.';

-- Без гранта authenticated: прямой RPC дал бы вердикт по любому UUID
-- центра (жив/удалён/просрочен) — межцентровая разведка без единой строки
-- данных (0050 Р10 — та же причина у center_writable). Зовут её guard и
-- center_writable()/center_limits() изнутри definer.
revoke all on function public.center_write_state(uuid) from public, anon, authenticated, service_role;

create or replace function public.center_writable(p_center_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select public.center_write_state(p_center_id) = 'ok';
$$;

comment on function public.center_writable(uuid) is
  'Центр может писать: живой trial/подписка, до конца дня истечения в поясе центра (0050 Р5/Р11). Тонкая обёртка над center_write_state() (0056 Р7).';

revoke all on function public.center_writable(uuid) from public, anon, authenticated, service_role;


-- 3. center_readonly_guard — текст PT402 по причине (Р7) ------------------------------------------

create or replace function public.center_readonly_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_row    jsonb;
  v_center uuid;
  v_state  text;
begin
  -- Р1: без сессии (миграции, каскады, bot_worker) — не наше дело.
  if auth.uid() is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Р4: revoke_membership гасит карточку teachers под своим флагом.
  if tg_table_name = 'teachers' and tg_op = 'UPDATE'
     and current_setting('logocrm.revoke_membership', true) = '1'
  then
    return new;
  end if;

  v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_center := (v_row ->> 'center_id')::uuid;

  -- Р6: строка платформы (center_id is null) не принадлежит центру — у неё
  -- нет подписки, и guard её не судит. Кто вправе её писать, решают
  -- триггер 0040 (exercise_library) и политики 0037 (message_templates);
  -- забор 0050 фиксирует список таких таблиц, чтобы новая получила решение.
  if v_center is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Р2/Р10: живой центр — дешёвая проверка по PK, без похода в auth.users.
  if public.center_writable(v_center) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Р2: платформа проходит всегда.
  if public.is_platform_admin() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- 0056 Р7: «удалён» — не «истекла подписка». Требование «оплатите»
  -- сразу после «Удалить центр» читалось бы как издевательство.
  v_state := public.center_write_state(v_center);

  -- Р9: текст по роли — «оплатите» читает тот, кто может оплатить; родителю
  -- и специалисту это выглядело бы как требование денег с них.
  if coalesce(public.my_role(), '') in ('owner', 'admin') then
    if v_state = 'deleted' then
      raise exception 'Центр помечен на удаление — доступны выгрузка данных и отмена в настройках тарифа'
        using errcode = 'PT402';
    end if;
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  if v_state = 'deleted' then
    raise exception 'Центр удалён — обратитесь к владельцу центра' using errcode = 'PT402';
  end if;
  raise exception 'Центр временно доступен только для чтения — обратитесь к администратору центра'
    using errcode = 'PT402';
end;
$$;

revoke all on function public.center_readonly_guard() from public, anon, authenticated, service_role;

-- 4. center_limits — добавлен state (Р7) -----------------------------------------------------------

create or replace function public.center_limits()
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_c      public.centers;
  v_p      public.plans;
  v_tz     text;
  v_today  date;
  v_until  timestamptz;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role = 'parent' or v_role = '' then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_c from public.centers where id = v_center;
  select * into v_p from public.plans where code = v_c.plan;
  if v_p.code is null then
    raise exception 'У центра не задан тариф — обратитесь к администратору платформы' using errcode = '23514';
  end if;

  v_tz    := public.center_timezone(v_center);
  v_today := (now() at time zone v_tz)::date;
  v_until := case when v_c.plan = 'trial' then v_c.trial_ends_at else v_c.subscription_until end;

  return jsonb_build_object(
    'plan',        v_p.code,
    'plan_name',   v_p.name,
    'price_tiyin', v_p.price_tiyin,
    'is_trial',    v_c.plan = 'trial',
    'until',       v_until,
    'days_left',   case when v_until is null then null
                        else ((v_until at time zone v_tz)::date - v_today) end,
    'writable',    public.center_writable(v_center),
    'state',       public.center_write_state(v_center),
    'limits',      v_p.limits,
    'usage', jsonb_build_object(
      'teachers', (select count(*) from public.teachers t where t.center_id = v_center and t.deleted_at is null),
      'students', (select count(*) from public.students s where s.center_id = v_center and s.deleted_at is null and s.status <> 'archived'),
      -- 0053 Р5: тот же счётчик, что у гейта; резерв работ в полёте не показывается.
      'ai_notes_month', public.center_ai_notes_used(v_center)
    ),
    'onboarding', jsonb_build_object(
      'teacher',    exists (select 1 from public.teachers t where t.center_id = v_center and t.deleted_at is null),
      'service',    exists (select 1 from public.services s where s.center_id = v_center and s.deleted_at is null),
      'student',    exists (select 1 from public.students s where s.center_id = v_center and s.deleted_at is null),
      'lesson',     exists (select 1 from public.lessons l where l.center_id = v_center and l.deleted_at is null),
      'attendance', exists (select 1 from public.attendance a where a.center_id = v_center)
    )
  );
end;
$$;

comment on function public.center_limits() is
  'Тариф, лимиты, использование, дни до конца, writable/state (ok/expired/deleted/missing, 0056 Р7) в поясе центра, галочки онбординга — одним запросом для экрана тарифа и баннера (0049 Р9, 0050 Р11, 0053 Р5). Родителю недоступно.';

revoke all on function public.center_limits() from public, anon, service_role;
grant execute on function public.center_limits() to authenticated;


-- 5. Экспорт — allow-list (Р1) + deny-list с причинами -------------------------------------------

-- Р1 проверяет только таблицы С center_id — у строки centers колонка id,
-- забор её никогда не увидит, и без этой функции файл «Скачать данные
-- центра» не нёс бы ни названия центра, ни его пояса (ревью написанного
-- SQL, находка 11).
create or replace function public.export_center_info()
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_c      public.centers;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_c from public.centers where id = v_center;
  if not found then
    raise exception 'Центр не найден' using errcode = '42704';
  end if;

  return jsonb_build_object(
    'id', v_c.id, 'name', v_c.name, 'slug', v_c.slug, 'plan', v_c.plan,
    'settings', v_c.settings, 'created_at', v_c.created_at
  );
end;
$$;

comment on function public.export_center_info() is
  'Своя строка centers для экспорта (0056 Р1/находка 11) — забор allow/deny видит только таблицы с center_id, у centers колонка id.';

revoke all on function public.export_center_info() from public, anon, service_role;
grant execute on function public.export_center_info() to authenticated;

create or replace function public.export_center_tables()
  returns table (table_name text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('attendance'), ('attendance_statuses'), ('diagnostics'), ('exercise_library'),
    ('expense_categories'), ('expenses'), ('financial_periods'), ('funnel_events'),
    ('goal_progress'), ('goal_stages'), ('goals'), ('group_students'), ('groups'),
    ('homework'), ('homework_exercises'), ('installment_plans'), ('installments'),
    ('lesson_note_goal_scores'), ('lesson_notes'), ('lesson_participants'), ('lessons'),
    ('memberships'), ('message_templates'), ('monthly_reports'), ('payers'),
    ('payment_sources'), ('payments'), ('platform_payments'), ('rooms'),
    ('salary_adjustments'), ('salary_runs'), ('services'), ('student_payers'),
    ('students'), ('subscription_freezes'), ('subscription_types'), ('subscriptions'),
    ('teacher_rates'), ('teachers')
$$;

comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny», иначе новая таблица с center_id молча попадала бы в выгрузку. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;

create or replace function public.export_center_excluded_tables()
  returns table (table_name text, reason text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('audit_log',                 'Своя функция export_center_audit() — за диапазон дат, у платящего центра самая большая таблица'),
    ('invitations',                'Р2: token — единственный секрет 7-дневного приглашения (0004); утечка = вход в центр ролью из приглашения'),
    ('lesson_voice_requests',      'Р2: путь к файлу голосового в Storage — секрет по факту (0041)'),
    ('ai_jobs',                    'Внутренняя очередь ИИ-обработки, не данные центра — результат уже в lesson_notes/monthly_reports'),
    ('ai_usage',                   'Внутренний учёт расхода ИИ (0053 Р3), не данные о ребёнке'),
    ('center_digest_runs',         'Отметка воркера (0050 Р3)'),
    ('events',                     'Внутренняя очередь доставки, не данные центра'),
    ('lesson_confirmations',       'Пишет только bot_worker (0050 Р3), техническая отметка подтверждения'),
    ('lesson_reminders_sent',      'Отметка воркера (0050 Р3)'),
    ('notification_log',           'Журнал доставки, не данные центра — что отправлено, не что произошло'),
    ('subscription_reminders_sent', 'Отметка воркера (0052 Р3)')
$$;

comment on function public.export_center_excluded_tables() is
  'Причины исключения из export_center_tables() (0056 Р1/Р2) — единственное место, где они записаны; забор pgTAP сверяет с каталогом.';

revoke all on function public.export_center_excluded_tables() from public, anon, authenticated, service_role;

-- Р4: по таблице за вызов — jsonb_object_agg по всему центру разом упёрся
-- бы в statement_timeout у центра с историей за пару лет. Р3: без
-- p_center_id — всегда current_center(), межцентровая выгрузка через
-- параметр невозможна структурно.
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
    'select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t where t.center_id = $1',
    p_table
  ) into v_result using v_center;

  return v_result;
end;
$$;

comment on function public.export_center_table(text) is
  'Одна таблица экспорта центра за вызов (0056 Р4) — веб собирает файл, обходя export_center_tables(). Без deleted_at is null: экспорт — вынос данных клиента целиком, включая архивное.';

revoke all on function public.export_center_table(text) from public, anon, service_role;
grant execute on function public.export_center_table(text) to authenticated;

-- Р2: audit-строки по invitations/lesson_voice_requests несут те же
-- секреты в old_data/new_data (apply_audit пишет их туда) — вычёркиваем,
-- а не просто «своя функция» без объяснения почему это не дыра.
create or replace function public.export_center_audit(p_from date, p_to date)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_tz     text;
  v_result jsonb;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Некорректный период' using errcode = '22023';
  end if;

  v_tz := public.center_timezone(v_center);

  select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) into v_result
    from public.audit_log a
   where a.center_id = v_center
     and a.table_name not in ('invitations', 'lesson_voice_requests')
     and a.at >= (p_from::timestamp at time zone v_tz)
     and a.at <  ((p_to + 1)::timestamp at time zone v_tz);

  return v_result;
end;
$$;

comment on function public.export_center_audit(date, date) is
  'audit_log за период отдельным вызовом (0056 Р4) — самая большая таблица у платящего центра. invitations/lesson_voice_requests вычеркнуты: их old_data/new_data несут те же секреты, что и сами строки (0056 Р2).';

revoke all on function public.export_center_audit(date, date) from public, anon, service_role;
grant execute on function public.export_center_audit(date, date) to authenticated;

-- Р11: одна строка на весь экспорт, не по таблице (их 39) — веб зовёт
-- после сборки файла. events — в списке исключений guard (0050), пишется
-- и в read-only, и в уже удалённом центре.
-- Число строк по каждой таблице считает сама функция, не принимает от
-- вызывающего: аргументом jsonb владелец/админ мог бы записать в
-- постоянный журнал любые числа, включая заведомо неверные (ревью
-- написанного SQL, находка 7) — «занятость и деньги не считаются в
-- браузере», применено и к следу аудита, не только к правам.
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
    execute format('select count(*) from public.%I where center_id = $1', v_table.table_name)
      into v_n using v_center;
    v_counts := v_counts || jsonb_build_object(v_table.table_name, v_n);
  end loop;

  v_id := public.emit_event('center.exported', jsonb_build_object('tables', v_counts), v_center);
  return v_id;
end;
$$;

comment on function public.record_center_export() is
  '«Вынос базы клиентов» обязан оставить след (0056 Р11) — веб зовёт одним вызовом после сборки файла. Число строк по таблице пересчитывает сама функция, не верит аргументу (0056 Р7, находка 7).';

revoke all on function public.record_center_export() from public, anon, service_role;
grant execute on function public.record_center_export() to authenticated;

-- 6. Заявка на удаление центра (Р8-Р10) -----------------------------------------------------------

-- Р8: owner, не admin — admin в проекте нанимаемая роль (0004), выключать
-- бизнес целиком не её решение. p_confirm_name сверяется с centers.name:
-- диалог в React не мешает вызвать RPC из консоли, аргумент мешает.
-- Идемпотентна (where deleted_at is null) — повтор не двигает будущий
-- срок физической очистки (ADR-012, не в этом этапе) и не плодит событий.
create or replace function public.request_center_deletion(p_confirm_name text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_c      public.centers;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.role_in(v_center), '') <> 'owner' then
    raise exception 'Удалить центр может только владелец' using errcode = '42501';
  end if;

  select * into v_c from public.centers where id = v_center and deleted_at is null;
  if not found then
    raise exception 'Центр уже помечен на удаление' using errcode = '23514';
  end if;
  if p_confirm_name is null or trim(p_confirm_name) <> v_c.name then
    raise exception 'Название центра не совпадает — удаление не выполнено' using errcode = '22023';
  end if;

  -- Гонка (ревью написанного SQL, находка 2): условие идемпотентности — в
  -- самом update, не только в select выше. Два одновременных вызова оба
  -- проходят select (общий снимок до коммита), но update сериализуется
  -- блокировкой строки; второй, перечитав предикат после снятия
  -- блокировки, видит уже выставленный deleted_at и не находит строку.
  update public.centers set deleted_at = now() where id = v_center and deleted_at is null;
  if not found then
    raise exception 'Центр уже помечен на удаление' using errcode = '23514';
  end if;

  perform public.emit_event('center.deletion_requested',
    jsonb_build_object('center_id', v_center, 'by', auth.uid()), v_center);
end;
$$;

comment on function public.request_center_deletion(text) is
  'Заявка на удаление центра (0056 Р8) — owner, имя центра аргументом как подтверждение. deleted_at + событие; физическая очистка через 30 дней — вне этого этапа (ADR-012).';

revoke all on function public.request_center_deletion(text) from public, anon, service_role;
grant execute on function public.request_center_deletion(text) to authenticated;

-- Р9: без неё 30-дневная отсрочка существует только в базе — RLS прячет
-- строку от owner (centers_select_members/centers_update_owner требуют
-- deleted_at is null), передумать нечем.
create or replace function public.cancel_center_deletion()
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
  if coalesce(public.role_in(v_center), '') <> 'owner' then
    raise exception 'Отменить удаление может только владелец' using errcode = '42501';
  end if;

  update public.centers set deleted_at = null
   where id = v_center and deleted_at is not null;
  if not found then
    raise exception 'Центр не помечен на удаление' using errcode = '23514';
  end if;

  perform public.emit_event('center.deletion_cancelled',
    jsonb_build_object('center_id', v_center, 'by', auth.uid()), v_center);
end;
$$;

comment on function public.cancel_center_deletion() is
  'Отмена заявки на удаление (0056 Р9) — owner, возвращает deleted_at в null. Без ADR-012 (физическая очистка) отмена не ограничена по времени: 30 дней — срок будущего cron, не срок этой функции.';

revoke all on function public.cancel_center_deletion() from public, anon, service_role;
grant execute on function public.cancel_center_deletion() to authenticated;

-- Р10: глазок в строку, которую RLS прячет от самого owner после
-- удаления (centers_select_members требует deleted_at is null для всех
-- ролей) — отдельная функция, а не правка общей SELECT-политики.
create or replace function public.center_deletion_state()
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_c      public.centers;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.role_in(v_center), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_c from public.centers where id = v_center;
  if not found then
    raise exception 'Центр не найден' using errcode = '42704';
  end if;

  return jsonb_build_object(
    'name',       v_c.name,
    'deleted',    v_c.deleted_at is not null,
    'deleted_at', v_c.deleted_at
  );
end;
$$;

comment on function public.center_deletion_state() is
  'Имя центра и статус удаления в обход RLS (0056 Р10) — owner/admin видят собственный удалённый центр, чтобы отменить или довыгрузить данные; обычный select .from(''centers'') после deleted_at скрыл бы строку.';

revoke all on function public.center_deletion_state() from public, anon, service_role;
grant execute on function public.center_deletion_state() to authenticated;

-- Р15: switch_center (0001) уже смотрит только на memberships, не на
-- centers.deleted_at — переключиться в удалённый центр можно, но список
-- для переключения (/select-center) строится обычным join на
-- memberships(centers(...)), а RLS-политика centers_select_members
-- прячет удалённую строку от её же владельца: окно отсрочки нечем
-- открыть, если он уже вышел из центра (ревью написанного SQL, находка 4).
create or replace function public.my_memberships()
  returns table (center_id uuid, center_name text, role text, deleted boolean)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select m.center_id, c.name, m.role, c.deleted_at is not null
    from public.memberships m
    join public.centers c on c.id = m.center_id
   where m.user_id = auth.uid()
   order by c.name;
$$;

comment on function public.my_memberships() is
  'Список центров пользователя в обход RLS (0056 Р15) — обычный join memberships→centers прячет удалённый центр от его же владельца; /select-center строится отсюда, не через .from(''memberships'').select(''centers(...)'').';

revoke all on function public.my_memberships() from public, anon, service_role;
grant execute on function public.my_memberships() to authenticated;


-- 6б. submit_platform_payment (0051) — отказ для удалённого центра (Р14) -----------------------------

-- До 0056 выставить centers.deleted_at не мог никто — эта миграция
-- начинает пускать. Без проверки здесь владелец переводит деньги на
-- уже отменённый центр: заявка создастся, платформа её не увидит
-- (platform_open_payments/platform_centers фильтруют deleted_at is null,
-- 0052), перевод останется висеть без подтверждения (ревью написанного
-- SQL, находка 5).
create or replace function public.submit_platform_payment(
  p_plan   text,
  p_months integer,
  p_source text,
  p_note   text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_plan   public.plans;
  v_id     uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if public.center_write_state(v_center) = 'deleted' then
    raise exception 'Центр помечен на удаление — оплата недоступна. Отмените удаление в настройках тарифа'
      using errcode = 'PT402';
  end if;

  select * into v_plan from public.plans where code = p_plan;
  if not found or v_plan.code = 'trial' or not v_plan.is_public then
    raise exception 'Выберите платный тариф' using errcode = '22023';
  end if;
  if p_months is null or p_months < 1 or p_months > 24 then
    raise exception 'Срок оплаты — от 1 до 24 месяцев' using errcode = '22023';
  end if;
  if p_source not in ('mbank', 'elcart', 'cash', 'other') then
    raise exception 'Укажите способ оплаты' using errcode = '22023';
  end if;

  -- Р11: сумма — снимок прайса, посчитанный здесь, а не в браузере.
  insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source, note, submitted_by)
  values (v_center, v_plan.code, p_months, v_plan.price_tiyin * p_months, p_source, nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  perform public.emit_event(
    'platform.payment_submitted',
    jsonb_build_object(
      'center_id',    v_center,
      'payment_id',   v_id,
      'plan',         v_plan.code,
      'months',       p_months,
      'amount_tiyin', v_plan.price_tiyin * p_months,
      'source',       p_source
    ),
    v_center
  );

  return v_id;
end;
$$;

comment on function public.submit_platform_payment(text, integer, text, text) is
  'Заявка «я оплатил» от owner/admin центра (0051). Сумма = цена тарифа × месяцы из plans (Р11). Работает и в режиме только чтения: platform_payments в списке исключений guard. Вторая открытая заявка — 23505 platform_payments_one_open_per_center. Удалённый центр — PT402, платить некуда (0056 Р14).';

revoke all on function public.submit_platform_payment(text, integer, text, text) from public, anon, service_role;
grant execute on function public.submit_platform_payment(text, integer, text, text) to authenticated;


-- 7. Уведомление о заявке на удаление (Р12) -------------------------------------------------------

-- mandatory = true (0052 Р1, как subscription.ending/expired): второй
-- owner/admin обязан узнать об удалении не из баннера «оплатите» — этот
-- тип не выключить через upsert_message_template(is_active => false)
-- (ревью написанного SQL, находка 6).
insert into public.notification_event_types (event_type, description, audience, subject_required, channels, mandatory) values
  ('center.deletion_requested', 'Владелец подал заявку на удаление центра', 'center', false, '{telegram,whatsapp_link}', true)
on conflict (event_type) do update
  set audience = excluded.audience, subject_required = excluded.subject_required,
      channels = excluded.channels, mandatory = excluded.mandatory;

-- Дефолты. insert … where not exists (0045: частичный индекс не даёт on conflict).
insert into public.message_templates (center_id, event_type, channel, text)
select v.center_id, v.event_type, v.channel, v.text
  from (values
    (null::uuid, 'center.deletion_requested', 'telegram',
     'Подана заявка на удаление центра. Данные доступны для экспорта и удаление можно отменить в настройках тарифа.'),
    (null::uuid, 'center.deletion_requested', 'whatsapp_link',
     'Подана заявка на удаление центра. Данные доступны для экспорта и удаление можно отменить в настройках тарифа.')
  ) as v(center_id, event_type, channel, text)
 where not exists (
   select 1 from public.message_templates m
    where m.center_id is null
      and m.event_type = v.event_type
      and m.channel = v.channel
      and m.deleted_at is null
 );

-- event_messages() (0053) переиздана целиком ради одной новой ветки
-- (Р12) — язык не даёт «добавить ветку» без create or replace всей
-- функции.
create or replace function public.event_messages(p_event_id bigint)
  returns table (
    recipient_user_id uuid,
    channel           text,
    chat_id           bigint,
    message           text,
    subject_id        uuid,
    action            jsonb
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_event    public.events;
  v_tz       text;
  v_vars     jsonb := '{}'::jsonb;
  v_student  uuid;
  v_payer    uuid;
  v_lesson   record;
  v_homework public.homework;
  v_note     public.lesson_notes;
  v_request  public.lesson_voice_requests;
  v_child    text;
  v_summary  text;
  v_days     integer;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if not found then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  v_tz := public.center_timezone(v_event.center_id);

  -- 0053 Р8/Р10: лимит голосовых резюме — заказчику диктовки ({child} только
  -- в telegram, с предлогом внутри) и owner/admin центра (без {child}, без
  -- subject), пока повтор диктовки имеет смысл (0047 Р4). Заказчик-владелец
  -- не получает двух строк.
  if v_event.type = 'ai.quota_exceeded' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    v_vars := jsonb_build_object(
      'used',  coalesce(v_event.payload ->> 'used', ''),
      'limit', coalesce(v_event.payload ->> 'limit', '')
    );

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               v_vars || jsonb_build_object('child',
                 case when r.channel = 'telegram' then ' по ' || v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r
      union all
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', '')),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r
       where r.user_id <> v_request.requested_by;
    return;
  end if;

  -- 0052: срок заканчивается / истёк — owner/admin центра. {when} и {until}
  -- считаются на момент доставки в поясе центра (Р6).
  if v_event.type in ('subscription.ending', 'subscription.expired') then
    v_days := ((v_event.payload ->> 'until')::timestamptz at time zone v_tz)::date
              - (now() at time zone v_tz)::date;
    v_vars := jsonb_build_object(
      'what',  case when (v_event.payload ->> 'is_trial')::boolean then 'Пробный период' else 'Подписка' end,
      'until', to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY')
    );
    -- {when} есть только у «заканчивается»: у истёкшего срока «сегодня» врало бы.
    if v_event.type = 'subscription.ending' then
      v_vars := v_vars || jsonb_build_object('when', case
                 when v_days <= 0 then 'сегодня'
                 when v_days = 1 then 'завтра'
                 else 'через ' || v_days::text || ' дн.'
               end);
    end if;
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0051: заявка на оплату — администраторам платформы, шаблон только
  -- дефолтный (Р10), суммы и пояс — центра-заявителя (Р12).
  if v_event.type = 'platform.payment_submitted' then
    v_vars := jsonb_build_object(
      'center_name', coalesce((select c.name from public.centers c where c.id = v_event.center_id), '—'),
      'plan_name',   coalesce((select p.name from public.plans p where p.code = v_event.payload ->> 'plan'), coalesce(v_event.payload ->> 'plan', '—')),
      'months',      coalesce(v_event.payload ->> 'months', ''),
      'amount',      public.format_som(coalesce((v_event.payload ->> 'amount_tiyin')::bigint, 0)),
      'source',      case v_event.payload ->> 'source'
                       when 'mbank' then 'Mbank' when 'elcart' then 'Elcart'
                       when 'cash' then 'наличные' else 'другое' end,
      'payment_id',  coalesce(v_event.payload ->> 'payment_id', '')
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_platform_targets(v_event.type) r;
    return;
  end if;

  -- 0051: продление — owner/admin центра; {until} в поясе центра (Р12).
  if v_event.type = 'subscription.extended' then
    v_vars := jsonb_build_object(
      'plan_name', coalesce((select p.name from public.plans p where p.code = v_event.payload ->> 'plan'), coalesce(v_event.payload ->> 'plan', '—')),
      'months',    coalesce(v_event.payload ->> 'months', ''),
      'until',     coalesce(to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY'), '—')
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0056: заявка на удаление центра — owner/admin (в т.ч. второй владелец,
  -- который её не подавал), без {until}.
  if v_event.type = 'center.deletion_requested' then
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, '{}'::jsonb),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0051 Р9: подписка истекла между диктовкой и обработкой — заказчику
  -- диктовки, если он всё ещё сотрудник (0047 Р2) и повтор диктовки ещё
  -- имеет смысл (0047 Р4, дословно как у lesson.voice_failed — текст просит
  -- записать заново, и просить это при утверждённой заметке нельзя).
  -- {child} только в telegram.
  if v_event.type = 'subscription.voice_blocked' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               jsonb_build_object('child',
                 case when r.channel = 'telegram' then v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r;
    return;
  end if;

  if v_event.type = 'lesson.reminder' then
    select l.starts_at, l.status, l.deleted_at, coalesce(t.full_name, '—') as teacher
      into v_lesson
      from public.lessons l
      left join public.teachers t on t.id = l.effective_teacher_id
     where l.id = (v_event.payload ->> 'lesson_id')::uuid;

    if not found or v_lesson.deleted_at is not null or v_lesson.status <> 'planned' then
      return;
    end if;

    v_vars := jsonb_build_object(
      'date',    to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY'),
      'time',    to_char(v_lesson.starts_at at time zone v_tz, 'HH24:MI'),
      'teacher', v_lesson.teacher
    );

    return query
      with participants as (
        select lp.student_id, s.full_name, s.payer_id
          from public.lesson_participants lp
          join public.students s on s.id = lp.student_id and s.deleted_at is null
         where lp.lesson_id = (v_event.payload ->> 'lesson_id')::uuid
           and lp.deleted_at is null
      )
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', p.full_name)),
             p.student_id,
             case when r.chat_id is null then null else jsonb_build_object(
               'label', 'Подтвердить приход',
               'callback_data', 'c:' || v_event.id::text || ':' || p.student_id::text
             ) end
        from participants p
        join lateral public.notification_targets(v_event.center_id, p.payer_id, v_event.type) r on true;
    return;
  end if;

  -- 0043: месячный отчёт. Текст уже заморожен в событии (Р4 из 0043) —
  -- здесь он только подставляется, ничего не пересчитывается.
  if v_event.type = 'report.monthly_ready' then
    v_student := (v_event.payload ->> 'student_id')::uuid;

    select s.payer_id into v_payer
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    -- 0047 Р10: текст отчёта — только в telegram, вне его пусто.
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'summary', case when r.channel = 'telegram'
                               then coalesce(v_event.payload ->> 'summary', '') else '' end,
               'month',   to_char((v_event.payload ->> 'period_month')::date, 'MM.YYYY'),
               'child',   (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0047: утверждённое резюме — родителю. Перечитывается на момент
  -- доставки (Р4); {summary} только в telegram (Р1); длина ограничена (Р5).
  if v_event.type = 'lesson.note_approved' then
    select * into v_note from public.lesson_notes n
     where n.id = (v_event.payload ->> 'lesson_note_id')::uuid
       and n.center_id = v_event.center_id
       and n.deleted_at is null
       and n.status = 'approved';
    if not found or coalesce(trim(v_note.parent_summary), '') = '' then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_note.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_note.student_id;
    select s.payer_id, s.full_name into v_payer, v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    v_summary := case
      when length(v_note.parent_summary) > 3500 then left(v_note.parent_summary, 3499) || '…'
      else v_note.parent_summary
    end;
    v_vars := jsonb_build_object(
      'child', v_child,
      'date',  to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY')
    );

    -- Р1: вне telegram переменная пуста, а не отсутствует — иначе
    -- render_template оставит «{summary}» буквально.
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               v_vars || jsonb_build_object('summary',
                 case when r.channel = 'telegram' then v_summary else '' end)),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0047: отказ обработки диктовки — заказчику диктовки, если он всё ещё
  -- сотрудник центра (Р2) и повтор диктовки ещё имеет смысл (Р4).
  -- Причина отказа в текст не идёт (Р6).
  if v_event.type = 'lesson.voice_failed' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    -- Р4: дословно условие отказа ai_job_begin (0042) — утверждено или
    -- голосовой черновик другой диктовки. Ручной черновик не гасит.
    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               jsonb_build_object('child',
                 case when r.channel = 'telegram' then v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r;
    return;
  end if;

  -- 0045: выдано родителю. Шлём независимо от текущего статуса задания —
  -- факт выдачи не перестаёт быть фактом, даже если уже сдано (Р4).
  if v_event.type = 'homework.assigned' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student),
               'due',   coalesce(to_char(v_homework.due_on, 'DD.MM.YYYY'), 'без срока')
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0045: специалисту, что сдано. Шлём, только если статус ВСЁ ЕЩЁ
  -- submitted — напоминание «проверьте» после того, как уже проверено,
  -- вводит в заблуждение (Р4, в отличие от assigned выше).
  if v_event.type = 'homework.submitted' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found or v_homework.status <> 'submitted' then
      return;
    end if;

    v_student := v_homework.student_id;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_homework_targets(v_event.center_id, v_homework.id, v_event.type) r;
    return;
  end if;

  -- 0045: специалист проверил — родителю.
  if v_event.type = 'homework.reviewed' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  if v_event.type in ('subscription.low_balance', 'subscription.exhausted', 'student.absent_streak') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'left',  coalesce(v_event.payload ->> 'lessons_left', ''),
      'count', coalesce(v_event.payload ->> 'length', '')
    );
  elsif v_event.type in ('installment.due', 'installment.overdue') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'amount', public.format_som((v_event.payload ->> 'amount_tiyin')::bigint),
      'date',   to_char((v_event.payload ->> 'due_date')::date, 'DD.MM.YYYY')
    );
  elsif v_event.type = 'digest.daily' then
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'date',    to_char((v_event.payload ->> 'date')::date, 'DD.MM.YYYY'),
               'lessons', coalesce(v_event.payload ->> 'lessons_today', '0'),
               'low',     coalesce(v_event.payload ->> 'low_balance', '0'),
               'debt',    public.format_som(coalesce((v_event.payload ->> 'debt_tiyin')::bigint, 0)),
               'overdue', coalesce(v_event.payload ->> 'installments_overdue', '0')
             )),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  else
    return;
  end if;

  select s.payer_id into v_payer
    from public.students s
   where s.id = v_student and s.deleted_at is null;

  if v_payer is null then
    return;
  end if;

  return query
    select r.user_id, r.channel, r.chat_id,
           public.render_template(r.template_text, v_vars || jsonb_build_object(
             'child', (select s.full_name from public.students s where s.id = v_student))),
           v_student,
           null::jsonb
      from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
end;
$$;

comment on function public.event_messages(bigint) is
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4), с 0047 — только в telegram. Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. lesson.note_approved (0047) — резюме родителю, {summary} только в telegram и не длиннее 3500 символов; lesson.voice_failed (0047) — заказчику диктовки через notification_user_targets, без причины отказа и только пока повтор диктовки имеет смысл (условие ai_job_begin). 0051: platform.payment_submitted — администраторам платформы (notification_platform_targets, шаблон только дефолтный), subscription.extended — owner/admin центра с {until} в поясе центра, subscription.voice_blocked — заказчику диктовки, {child} только в telegram. 0052: subscription.ending/expired — owner/admin центра, {what}/{until}/{when} на момент доставки в поясе центра. 0053: ai.quota_exceeded — заказчику диктовки ({child} с предлогом, только telegram) и owner/admin центра без {child}, {used}/{limit} в оба канала, пока повтор диктовки имеет смысл. 0056: center.deletion_requested — owner/admin центра, без переменных. Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;

grant execute on function public.event_messages(bigint) to bot_worker;
