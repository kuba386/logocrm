-- =============================================================================
-- 0040_exercise_library_rpcs.sql — библиотека упражнений: RPC вместо прямой
-- записи (этап 7a, экран /app/library, PR #83)
--
-- 0038 (Р10) прямым текстом отложила этот шаг: «goal_stages и exercise_library
-- НЕ получают RPC в этой миграции... Когда появится экран, блокировку и RPC
-- заводить тем же приёмом, что здесь». Экран построен и смержен — приходит
-- этот приём.
--
-- Решения (план прошёл architect, замечания учтены):
--   Р1. save_exercise — единая точка insert/update: параметр по id читает и
--       правит только строку своего центра одним атомарным UPDATE ... WHERE
--       ... RETURNING (не select-then-update — незачем читать строку заранее,
--       если ни один другой RPC её не архивирует и не подменяет параллельно).
--   Р2. Прямой insert/update на exercise_library закрыт тем же revoke, что и
--       у остальных клинических таблиц (0038). Экран /app/library в этом же
--       PR переведён на RPC — иначе grant без веб-правки воспроизвёл бы живой
--       баг message_templates (0037), только наоборот: кнопка «Добавить»
--       начала бы отдавать голый Postgres-текст вместо русского сообщения.
--   Р3. Границу «center_id is null — платформенная строка» держит не только
--       save_exercise (он её никогда не трогает), но и триггер
--       exercise_library_center_required: любая запись под ролью
--       authenticated (так подключается PostgREST/RPC живого пользователя),
--       пишущая center_id => null, отбивается на уровне таблицы. Проверка —
--       по роли подключения, а не по auth.uid()/claims: фикстуры pgTAP
--       заводят платформенные строки уже после того, как claims выставлены
--       для другого поля, под тестовой (не authenticated) ролью — auth.uid()
--       там ложно «не null». Без триггера будущий grant insert «впрок» (как
--       в 0036) или новая RPC, не подставившая центр, создали бы упражнение,
--       видимое всем центрам сразу — не баг, а межцентровая утечка, и
--       функция-фасад её не ловит.
--   Р4. archive_exercise НЕ заводится. Таблица уже несёт is_active — ровно то
--       поле, которое означает «не предлагать в новых ДЗ, не путать со
--       soft-delete». Настоящий deleted_at здесь завёл бы дыру, которую нашёл
--       архитектор: homework_exercises_check_center_refs (0036) требует
--       e.deleted_at is null при КАЖДОЙ пересборке состава (update_homework
--       всегда переinsert'ит весь список), и архивация уже выданного
--       упражнения тихо стирала бы его из старых ДЗ или ломала их правку.
--       Закрывать это — переписывать триггер 0036, отдельная задача не этого
--       PR. is_active вместо архива достаточен для сценария «мы больше не
--       используем эту карточку» и не касается этого триггера вовсе.
--   Р5. stage_code проверяется по факту (goal_stages своего центра), а не
--       произвольным текстом: иначе опечатка в поле сохраняется, но не
--       находится ни одним фильтром и показывается сырым кодом — тот же
--       класс, что Р4 в 0037 про event_type.
--   Р6. Констрейнты на возраст и на схему ссылки — на таблице, а не в
--       функции: другой будущий писатель (миграция, бэкфилл) их не обойдёт.
--   Р7. Частичный уникальный индекс с nulls not distinct — двойной клик
--       «Добавить» не заводит дубль ни в центре, ни в платформенной
--       библиотеке (там center_id у всех строк NULL, и без nulls not
--       distinct индекс их вообще не различал бы).
-- =============================================================================

-- 1. Границы центра — триггер, не только проверка в функции (Р3) ------------------------------------

create or replace function public.exercise_library_center_required()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  -- Граница — по фактической роли подключения (as PostgREST/RPC её
  -- выставляет через SET ROLE authenticated), а не по auth.uid(): фикстуры
  -- pgTAP заводят платформенные строки уже после того, как в этой же
  -- транзакции выставлены чужие request.jwt.claims (для других полей —
  -- created_by и т.п.), под ролью тестового раннера, не authenticated —
  -- auth.uid() к этому моменту непуст, а живой сессии всё ещё нет. Роль —
  -- граница, которую действительно проверяют RLS и grants в этом проекте.
  if new.center_id is null and current_setting('role', true) = 'authenticated' then
    raise exception 'Упражнение платформы заводится только миграцией' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists exercise_library_center_required on public.exercise_library;
create trigger exercise_library_center_required
  before insert or update on public.exercise_library
  for each row execute function public.exercise_library_center_required();

revoke all on function public.exercise_library_center_required() from public, anon, authenticated, service_role;


-- 2. Констрейнты (Р6) ---------------------------------------------------------------------------

alter table public.exercise_library
  drop constraint if exists exercise_library_age_not_negative,
  add constraint exercise_library_age_not_negative check (age_from is null or age_from >= 0);

alter table public.exercise_library
  drop constraint if exists exercise_library_age_range,
  add constraint exercise_library_age_range check (age_from is null or age_to is null or age_from <= age_to);

alter table public.exercise_library
  drop constraint if exists exercise_library_media_url_scheme,
  add constraint exercise_library_media_url_scheme check (media_url is null or media_url ~ '^https?://');

-- Двойной клик «Добавить» на форме без оптимистичного UI (правило проекта —
-- ответа сервера ждём, но пока ждём, кнопка не блокирована) не должен
-- заводить дубль. nulls not distinct — иначе две платформенные строки
-- (center_id у обеих NULL) индекс не различал бы вовсе.
create unique index if not exists exercise_library_center_title_uniq
  on public.exercise_library (center_id, lower(title))
  nulls not distinct
  where deleted_at is null;


-- 3. save_exercise — единая точка insert/update (Р1, Р2, Р5) -----------------------------------------

create or replace function public.save_exercise(
  p_title        text,
  p_id           uuid default null,
  p_area         text default null,
  p_sound        text default null,
  p_stage_code   text default null,
  p_instructions text default null,
  p_media_url    text default null,
  p_age_from     integer default null,
  p_age_to       integer default null,
  p_tags         text[] default '{}'::text[],
  p_is_active    boolean default true
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_title  text := trim(p_title);
  v_id     uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр — перезайдите' using errcode = '42501';
  end if;
  -- Каталог правят owner/admin — тот же круг, что у services/rooms (settings).
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if length(v_title) < 2 then
    raise exception 'Укажите название упражнения' using errcode = '22023';
  end if;

  if p_stage_code is not null and not exists (
    select 1 from public.goal_stages gs
     where gs.code = p_stage_code and gs.center_id = v_center and gs.deleted_at is null
  ) then
    raise exception 'Этап не найден' using errcode = '42704';
  end if;

  if p_id is null then
    insert into public.exercise_library
      (center_id, title, area, sound, stage_code, instructions, media_url, age_from, age_to, tags, is_active)
    values
      (v_center, v_title, p_area, p_sound, p_stage_code, p_instructions, p_media_url, p_age_from, p_age_to,
       coalesce(p_tags, '{}'::text[]), p_is_active)
    returning id into v_id;
  else
    -- Один атомарный UPDATE, а не select-then-update: чужой центр и
    -- платформенная строка (center_id is null, WHERE её не найдёт) дают один
    -- и тот же код ошибки — не устраивать RPC оракулом существования id.
    update public.exercise_library
       set title        = v_title,
           area         = p_area,
           sound        = p_sound,
           stage_code   = p_stage_code,
           instructions = p_instructions,
           media_url    = p_media_url,
           age_from     = p_age_from,
           age_to       = p_age_to,
           tags         = coalesce(p_tags, '{}'::text[]),
           is_active    = p_is_active
     where id = p_id and center_id = v_center and deleted_at is null
    returning id into v_id;

    if not found then
      raise exception 'Упражнение не найдено' using errcode = '42704';
    end if;
  end if;

  return v_id;
end;
$$;

revoke all on function public.save_exercise(text, uuid, text, text, text, text, text, integer, integer, text[], boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.save_exercise(text, uuid, text, text, text, text, text, integer, integer, text[], boolean)
  to authenticated;


-- 4. Прямая запись закрыта (Р2) -----------------------------------------------------------------

revoke insert, update on public.exercise_library from authenticated;
