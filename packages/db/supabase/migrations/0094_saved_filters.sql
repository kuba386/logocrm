-- 0094_saved_filters.sql — сохранённые фильтры расписания и долгов.
--
-- Просьба владельца (docs/Backlog.md, 11.09.2026): расписание и долги каждый
-- раз фильтруют заново одними и теми же наборами — «мои занятия на неделе»,
-- «долги больше 5 000». Набор сохраняется под именем и открывается одним
-- кликом. Это личное предпочтение сотрудника в центре, не данные центра.
--
-- Решения (план проверен architect до написания):
-- Р1. Строка принадлежит паре (user_id, center_id). Видит её только автор и
--     только в том центре, где сохранил; apply_tenant_rls не вызывается —
--     он открыл бы owner/admin личные наборы сотрудников.
-- Р2. Страница — CHECK, а не lookup: это список экранов кода, новый экран
--     всё равно требует миграции. Неделя расписания не хранится — набор
--     открывается на текущей неделе центра.
-- Р3. Значения params проверяет база, а не функция: CHECK через
--     saved_filter_params_ok() — ключи по странице, uuid по регулярке,
--     перечни, min — целые сомы до 9 999 999 (в тыйынах укладывается в int4).
--     Существование teacher/room не проверяется: устаревший uuid безвреден,
--     а проверка сделала бы definer-функцию оракулом существования uuid.
-- Р4. Роль — по странице, одинаково в политике и в save_filter:
--     saved_filter_pages(). Расписание — owner/admin/registrar/teacher
--     (finance на /app/schedule не пускает страница, у него нет lessons),
--     долги — can_payments(). Отозванный участник со старым claim center_id
--     и человек, понижённый до parent, своих прежних наборов не видят.
-- Р5. Запись только через RPC: у authenticated — SELECT, у service_role —
--     ничего (как bot_pending_actions, 0071). Не больше 20 живых наборов на
--     страницу; перезапись по имени (без учёта регистра) лимитом не режется.
--     Advisory-lock на (центр, пользователь, страница) в обеих RPC: два
--     сохранения одного нового имени и сохранение против архивации не
--     проскакивают друг мимо друга.
-- Р6. Аудита нет намеренно: audit_log читают owner/admin, личные наборы
--     сотрудников им незачем (как bot_pending_actions и telegram_accounts).
--     По той же причине таблица в deny-list экспорта центра.
-- Р7. Под readonly-guard: в просроченном центре сохранение и удаление набора
--     отказывают PT402, как любая запись. Гасить наборы при отзыве членства не
--     нужно — видимость режет политика (Р4), а триггер на memberships сломал
--     бы отзыв доступа в read-only центре (0050 Р12).


-- 1. Валидатор params (Р3) ------------------------------------------------------------------------

create or replace function public.saved_filter_params_ok(p_page text, p_params jsonb)
  returns boolean
  language sql
  immutable
  set search_path = ''
as $$
  select p_params is not null
     and jsonb_typeof(p_params) = 'object'
     and not exists (
       select 1
         from jsonb_each(p_params) e
        where jsonb_typeof(e.value) <> 'string'
           or not coalesce(
                case
                  when p_page = 'schedule' and e.key = 'teacher' then
                    (e.value #>> '{}') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  when p_page = 'schedule' and e.key = 'room' then
                    (e.value #>> '{}') = 'none'
                    or (e.value #>> '{}') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  when p_page = 'debts' and e.key = 'filter' then (e.value #>> '{}') in ('all', 'debt', 'zero')
                  when p_page = 'debts' and e.key = 'sort' then (e.value #>> '{}') in ('amount', 'name')
                  when p_page = 'debts' and e.key = 'min' then (e.value #>> '{}') ~ '^[1-9][0-9]{0,6}$'
                  else false
                end,
                false)
     );
$$;

comment on function public.saved_filter_params_ok(text, jsonb) is
  'Допустимые params сохранённого фильтра по странице (0094 Р3): schedule — teacher (uuid), room (uuid или none); debts — filter, sort, min (целые сомы 1…9 999 999). Источник истины; зеркало — packages/core/src/saved-filters.ts, общий набор случаев в Vitest и pgTAP.';

-- CHECK и save_filter исполняют его от владельца таблицы — ролям приложения не нужен.
revoke all on function public.saved_filter_params_ok(text, jsonb) from public, anon, authenticated, service_role;


-- 2. Какие страницы доступны роли (Р4) ------------------------------------------------------------

create or replace function public.saved_filter_pages()
  returns text[]
  language sql
  stable
  set search_path = ''
as $$
  select array_remove(array[
    case when coalesce(public.my_role(), '') in ('owner', 'admin', 'registrar', 'teacher') then 'schedule' end,
    case when public.can_payments() then 'debts' end
  ], null);
$$;

comment on function public.saved_filter_pages() is
  'Страницы, чьи сохранённые фильтры доступны вызывающему в текущем центре (0094 Р4): schedule — owner/admin/registrar/teacher, debts — can_payments(). Одна правда для политики чтения и save_filter.';

revoke all on function public.saved_filter_pages() from public, anon, service_role;
grant execute on function public.saved_filter_pages() to authenticated;


-- 3. Таблица ---------------------------------------------------------------------------------------

create table public.saved_filters (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null default public.current_center()
                references public.centers (id) on delete cascade,
  user_id     uuid not null default auth.uid()
                references auth.users (id) on delete cascade,
  page        text not null
    constraint saved_filters_page_check check (page in ('schedule', 'debts')),
  name        text not null
    constraint saved_filters_name_check
    check (name = btrim(name) and char_length(name) between 1 and 60 and name !~ '[[:cntrl:]]'),
  params      jsonb not null default '{}'::jsonb
    constraint saved_filters_params_check check (public.saved_filter_params_ok(page, params)),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  deleted_at  timestamptz
);

comment on table public.saved_filters is
  'Личные сохранённые фильтры сотрудника в центре (0094): расписание и долги. Видит только автор в том центре, где сохранил, и только для страниц своей роли. Запись — save_filter/archive_saved_filter; у authenticated только SELECT, у service_role ничего. Аудита нет намеренно (Р6), в экспорт центра не входит.';

-- Одно живое имя на (центр, пользователь, страница) без учёта регистра — повтор
-- имени в save_filter перезаписывает набор.
create unique index saved_filters_live_name_idx
  on public.saved_filters (center_id, user_id, page, lower(name)) where deleted_at is null;
-- Покрытие FK — непартиальные btree (конвенция 0069): каскады удаления центра и пользователя.
create index saved_filters_center_fk_idx on public.saved_filters (center_id);
create index saved_filters_user_fk_idx on public.saved_filters (user_id);

create trigger saved_filters_set_updated_at
  before update on public.saved_filters
  for each row execute function extensions.moddatetime(updated_at);

alter table public.saved_filters enable row level security;
revoke all on table public.saved_filters from public, anon, authenticated, service_role;
grant select on table public.saved_filters to authenticated;

-- (select …) — initplan: функции вычисляются раз на запрос, а не на строку
-- (советник auth_rls_initplan, прецедент 0024).
create policy saved_filters_select_own on public.saved_filters
  for select to authenticated
  using (
    user_id = (select auth.uid())
    and center_id = (select public.current_center())
    and deleted_at is null
    and page = any ((select public.saved_filter_pages()))
  );

-- Р7: под guard — забор 0050 (каждая таблица либо под guard, либо в исключениях).
call public.apply_readonly_guard('saved_filters');


-- 4. save_filter — сохранить или перезаписать набор по имени (Р5) ---------------------------------

create or replace function public.save_filter(p_page text, p_name text, p_params jsonb)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user   uuid := auth.uid();
  v_center uuid := public.current_center();
  v_name   text := btrim(coalesce(p_name, ''));
  v_params jsonb := coalesce(p_params, '{}'::jsonb);
  v_id     uuid;
  v_live   integer;
begin
  if v_user is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null or not (coalesce(p_page, '') = any (public.saved_filter_pages())) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if char_length(v_name) = 0 then
    raise exception 'Укажите название фильтра' using errcode = '23514';
  end if;
  if char_length(v_name) > 60 or v_name ~ '[[:cntrl:]]' then
    raise exception 'Название фильтра — до 60 символов, одной строкой' using errcode = '23514';
  end if;
  if not public.saved_filter_params_ok(p_page, v_params) then
    raise exception 'Фильтр не сохранён: в нём есть недопустимое значение' using errcode = '23514';
  end if;

  -- После проверки центра: hashtextextended(NULL) дал бы NULL и не заблокировал ничего.
  perform pg_advisory_xact_lock(
    hashtextextended('saved_filters:' || v_center::text || ':' || v_user::text || ':' || p_page, 0));

  select f.id into v_id
    from public.saved_filters f
   where f.center_id = v_center and f.user_id = v_user and f.page = p_page
     and lower(f.name) = lower(v_name) and f.deleted_at is null;

  if v_id is not null then
    update public.saved_filters
       set name = v_name, params = v_params
     where id = v_id and deleted_at is null;
    return v_id;
  end if;

  select count(*) into v_live
    from public.saved_filters f
   where f.center_id = v_center and f.user_id = v_user and f.page = p_page and f.deleted_at is null;
  if v_live >= 20 then
    raise exception 'Не больше 20 сохранённых фильтров на странице — удалите ненужный' using errcode = '23514';
  end if;

  insert into public.saved_filters (center_id, user_id, page, name, params, created_by)
  values (v_center, v_user, p_page, v_name, v_params, v_user)
  returning id into v_id;
  return v_id;
exception
  when unique_violation then
    raise exception 'Фильтр изменился одновременно в другой вкладке — попробуйте ещё раз' using errcode = '40001';
end;
$$;

comment on function public.save_filter(text, text, jsonb) is
  'Сохранить набор фильтров страницы под именем (0094). Повтор имени без учёта регистра перезаписывает набор и возвращает его id; новых — не больше 20 на страницу. Права — saved_filter_pages(), значения — saved_filter_params_ok().';

revoke execute on function public.save_filter(text, text, jsonb) from public, anon, service_role;
grant execute on function public.save_filter(text, text, jsonb) to authenticated;


-- 5. archive_saved_filter — убрать свой набор -----------------------------------------------------

create or replace function public.archive_saved_filter(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user   uuid := auth.uid();
  v_center uuid := public.current_center();
  v_page   text;
begin
  if v_user is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  -- Чужой, архивный, несуществующий и набор страницы, которой роль больше не
  -- видит, — неотличимы: один и тот же 42704.
  select f.page into v_page
    from public.saved_filters f
   where f.id = p_id and f.user_id = v_user and f.center_id = v_center and f.deleted_at is null;
  if v_page is null or not (v_page = any (public.saved_filter_pages())) then
    raise exception 'Фильтр не найден' using errcode = '42704';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('saved_filters:' || v_center::text || ':' || v_user::text || ':' || v_page, 0));

  update public.saved_filters
     set deleted_at = now()
   where id = p_id and deleted_at is null;
  if not found then
    raise exception 'Фильтр не найден' using errcode = '42704';
  end if;
end;
$$;

comment on function public.archive_saved_filter(uuid) is
  'Убрать свой сохранённый фильтр (0094): deleted_at, строка не удаляется. Чужой, архивный и несуществующий — один и тот же 42704.';

revoke execute on function public.archive_saved_filter(uuid) from public, anon, service_role;
grant execute on function public.archive_saved_filter(uuid) to authenticated;


-- 6. Экспорт центра: deny-list (Р6) ---------------------------------------------------------------
-- Переиздан с редакции 0071 (последняя), добавлена одна строка. Забор 0056 требует,
-- чтобы каждая таблица с center_id была ровно в одном из двух списков.

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
    ('assistant_requests',         'Внутренний учёт попыток ассистента (0064): текста вопроса нет, расход — в ai_usage, тоже исключён'),
    ('bot_pending_actions',        'Контекст шага в Telegram-боте (0071 Р16): chat_id специалиста — не данные центра, результат действия уже в attendance/lesson_notes'),
    ('center_digest_runs',         'Отметка воркера (0050 Р3)'),
    ('events',                     'Внутренняя очередь доставки, не данные центра'),
    ('lesson_confirmations',       'Пишет только bot_worker (0050 Р3), техническая отметка подтверждения'),
    ('lesson_reminders_sent',      'Отметка воркера (0050 Р3)'),
    ('notification_log',           'Журнал доставки, не данные центра — что отправлено, не что произошло'),
    ('saved_filters',              'Личные наборы фильтров сотрудника (0094 Р6), не данные центра: имя — свободный текст, владельцу центра его видеть незачем'),
    ('subscription_reminders_sent', 'Отметка воркера (0052 Р3)')
$$;

revoke all on function public.export_center_excluded_tables() from public, anon, authenticated, service_role;
