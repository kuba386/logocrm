-- =============================================================================
-- 0104_center_kinds_modules.sql — тип центра, модули и словарь (этап 13)
--
-- Решение владельца 19.10.2026, ADR-013: один продукт для логопедических и
-- учебных центров без ветвлений в ядре. Тип центра задаёт стартовый набор,
-- модули включает владелец; данные от типа не зависят.
--
-- Решения (ревью архитектора: план этапа — 6 блокеров и 9 замечаний, план
-- миграции — 2 блокера и 4 серьёзных; учтены):
--   Р1. centers.kind → lookup center_kinds (speech, education); «тип →
--       стартовые модули» — данные center_kind_modules. Тип — обычная
--       настройка: прямой PATCH закрыт триггером centers_kind_guard (только
--       владелец ЭТОГО центра — role_in(new.id), не my_role(); платформа и
--       сессия без пользователя — пропуск; readonly — PT402). Событие —
--       в AFTER-триггере: BEFORE, идущий следом, мог бы отменить строку.
--   Р2. center_modules: выключение — disabled_at, не DELETE; частичный unique
--       по живым строкам; писать — только set_center_module (owner); у ролей
--       только select. Модули засевает AFTER INSERT триггер на centers — их
--       получают create_center, platform_create_center и тестовые фикстуры.
--       Этапы целей по-прежнему засеваются всем центрам (0036).
--   Р3. Запись в выключенный модуль запрещает триггер a01_module_guard на
--       таблицах модуля (список — module_guarded_tables), не проверка в RPC.
--       Действует и без сессии (контур бота). UPDATE, где все изменённые
--       колонки стали NULL и которое пришло изнутри другого триггера
--       (pg_trigger_depth() > 1), пропускается — каскады on delete set null
--       (удаление пользователя, специалиста, занятия); прямое обнуление из
--       RPC — отказ. lesson_voice_requests
--       — только INSERT: отмена и закрытие диктовки не блокируются.
--       goal_stages НЕ под гардом (отступление от ADR Р3): AFTER-триггеры на
--       centers идут по алфавиту, centers_seed_goal_stages раньше
--       centers_seed_modules — с гардом не создался бы ни один центр.
--       SQLSTATE PT403 (PostgREST → 403), текст по-русски.
--   Р4. approve_lesson_note: без «Клиники» заметка утверждается без переноса
--       оценок в goal_progress — оценки остаются предложениями.
--   Р5. ai_job_begin: модуль проверяется до квоты и ai_jobs — цели ребёнка не
--       уходят в модель. Тихий null без события (отступление от ADR Р5):
--       bot_voice_pending тоже смотрит модуль и не держит текстовую заметку.
--       Уже захваченная running-работа при выключении остаётся висеть —
--       принято, окно — минуты.
--   Р6. Видимость при выключенном модуле (решение владельца): клинику видят
--       только owner/admin. Restrictive-политика <tbl>_module_visible на
--       таблицах модуля через module_visible('clinic') (грант authenticated;
--       center_has_module без грантов — иначе оракул по чужим центрам).
--       Хелперы clinical_* не меняются: их используют ДЗ, заметки и
--       student_notes_brief — ядро. Definer-функции, отдающие клинику мимо
--       RLS, перевыпущены с проверкой: student_diagnostics_brief,
--       student_goals_brief, student_goal_dynamics_brief, student_conclusions,
--       goal_suggestions — пусто; student_monthly_report — отказ целиком.
--       Отчёт, поставленный в очередь до выключения (event_messages,
--       report.monthly_ready), уйдёт — принято, окно короткое.
--   Р7. create_center / platform_create_center: drop + create с p_kind в
--       конце — без перегрузки (иначе PGRST203 у онбординга).
--   Р8. Гонка «выключение модуля одновременно с записью» по READ COMMITTED
--       пропустит одну строку — принято: это граница видимости, не доступа.
-- =============================================================================


-- 1. Справочники ----------------------------------------------------------------------------------

create table if not exists public.center_kinds (
  code  text primary key,
  title text not null,
  sort  integer not null default 0
);

create table if not exists public.app_modules (
  code  text primary key,
  title text not null,
  sort  integer not null default 0
);

create table if not exists public.center_kind_modules (
  kind_code   text not null references public.center_kinds (code),
  module_code text not null references public.app_modules (code),
  primary key (kind_code, module_code)
);

insert into public.center_kinds (code, title, sort) values
  ('speech',    'Логопедический / коррекционный центр', 10),
  ('education', 'Учебный центр',                        20)
on conflict (code) do nothing;

insert into public.app_modules (code, title, sort) values
  ('clinic',   'Клиника', 10),
  ('academic', 'Учёба',   20)
on conflict (code) do nothing;

insert into public.center_kind_modules (kind_code, module_code) values
  ('speech', 'clinic'),
  ('education', 'academic')
on conflict do nothing;

comment on table public.center_kinds is 'Типы центров (0104, ADR-013). Пишет только миграция.';
comment on table public.app_modules is 'Модули продукта (0104, ADR-013): clinic — «Клиника», academic — «Учёба». Пишет только миграция.';
comment on table public.center_kind_modules is 'Стартовые модули по типу центра (0104 Р1) — данные, не if в SQL.';

alter table public.center_kinds enable row level security;
alter table public.app_modules enable row level security;
alter table public.center_kind_modules enable row level security;

drop policy if exists center_kinds_read_all on public.center_kinds;
create policy center_kinds_read_all on public.center_kinds for select to authenticated using (true);
drop policy if exists app_modules_read_all on public.app_modules;
create policy app_modules_read_all on public.app_modules for select to authenticated using (true);
drop policy if exists center_kind_modules_read_all on public.center_kind_modules;
create policy center_kind_modules_read_all on public.center_kind_modules for select to authenticated using (true);

revoke all on table public.center_kinds, public.app_modules, public.center_kind_modules
  from public, anon, authenticated, service_role;
grant select on table public.center_kinds, public.app_modules, public.center_kind_modules to authenticated;


-- 2. centers.kind ---------------------------------------------------------------------------------

-- default заполняет существующие строки без UPDATE — триггеры centers не срабатывают.
alter table public.centers
  add column if not exists kind text not null default 'speech' references public.center_kinds (code);

comment on column public.centers.kind is
  'Тип центра (0104, ADR-013): стартовый набор модулей и словарь интерфейса. Данные от него не зависят; меняет владелец (set_center_kind).';

create or replace function public.centers_kind_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.kind is not distinct from old.kind then
    return new;
  end if;
  -- Миграция и платформа — без проверки владельца (как centers_deletion_source_guard, 0099).
  if auth.uid() is null or public.is_platform_admin() then
    return new;
  end if;
  -- Р1: владелец именно ЭТОГО центра — role_in(new.id), не my_role(): текущий
  -- центр сессии может быть другим.
  if coalesce(public.role_in(new.id), '') <> 'owner' then
    raise exception 'Тип центра меняет только владелец' using errcode = '42501';
  end if;
  if not public.center_writable(new.id) then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  return new;
end;
$$;

revoke all on function public.centers_kind_guard() from public, anon, authenticated, service_role;

drop trigger if exists centers_kind_guard on public.centers;
create trigger centers_kind_guard
  before update of kind on public.centers
  for each row execute function public.centers_kind_guard();

create or replace function public.centers_kind_changed()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.kind is distinct from old.kind then
    perform public.emit_event_internal(
      'center.kind_changed',
      jsonb_build_object('center_id', new.id, 'from', old.kind, 'to', new.kind),
      new.id
    );
  end if;
  return null;
end;
$$;

revoke all on function public.centers_kind_changed() from public, anon, authenticated, service_role;

drop trigger if exists centers_kind_changed on public.centers;
create trigger centers_kind_changed
  after update of kind on public.centers
  for each row execute function public.centers_kind_changed();


-- 3. center_modules -------------------------------------------------------------------------------

create table if not exists public.center_modules (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null default public.current_center()
                references public.centers (id) on delete cascade,
  module_code text not null references public.app_modules (code),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  disabled_at timestamptz,
  disabled_by uuid,
  -- disabled_by без disabled_at не бывает; disabled_at без disabled_by — выключение без сессии.
  constraint center_modules_disabled_shape check (disabled_at is not null or disabled_by is null)
);

comment on table public.center_modules is
  'Включённые модули центра (0104 Р2): живая строка (disabled_at is null) = модуль включён. Выключение — disabled_at, не DELETE. Пишет только set_center_module и триггер centers_seed_modules.';

create unique index if not exists center_modules_live_key
  on public.center_modules (center_id, module_code) where disabled_at is null;
create index if not exists center_modules_center_idx on public.center_modules (center_id);
-- FK на справочники — индексы ради линтера unindexed_foreign_keys (долг 0069).
create index if not exists center_modules_module_idx on public.center_modules (module_code);
create index if not exists center_kind_modules_module_idx on public.center_kind_modules (module_code);
create index if not exists centers_kind_idx on public.centers (kind);

drop trigger if exists center_modules_set_updated_at on public.center_modules;
create trigger center_modules_set_updated_at
  before update on public.center_modules
  for each row execute function extensions.moddatetime(updated_at);

alter table public.center_modules enable row level security;

-- Только чтение участникам центра — без apply_tenant_rls: её FOR ALL дала бы
-- админу прямую запись мимо set_center_module.
drop policy if exists center_modules_select on public.center_modules;
create policy center_modules_select on public.center_modules
  for select to authenticated
  using (center_id = public.current_center() and public.is_member(center_id));

revoke all on table public.center_modules from public, anon, authenticated, service_role;
grant select on public.center_modules to authenticated;

call public.apply_audit('center_modules');
call public.apply_readonly_guard('center_modules');


-- 4. Функции модулей ------------------------------------------------------------------------------

create or replace function public.center_has_module(p_center uuid, p_code text)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1 from public.center_modules m
     where m.center_id = p_center and m.module_code = p_code and m.disabled_at is null
  );
$$;

comment on function public.center_has_module(uuid, text) is
  'Модуль включён у центра (0104). Без грантов: только для триггеров и definer-функций — с аргументом центра это был бы оракул по чужим центрам.';

revoke all on function public.center_has_module(uuid, text) from public, anon, authenticated, service_role;

create or replace function public.has_module(p_code text)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select auth.uid() is not null
     and public.current_center() is not null
     and public.is_member(public.current_center())
     and public.center_has_module(public.current_center(), p_code);
$$;

comment on function public.has_module(text) is 'Модуль включён у текущего центра вызывающего (0104) — для веба.';

revoke all on function public.has_module(text) from public, anon, service_role;
grant execute on function public.has_module(text) to authenticated;

create or replace function public.module_visible(p_code text)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select auth.uid() is not null
     and public.current_center() is not null
     and (
       coalesce(public.my_role(), '') in ('owner', 'admin')
       or public.has_module(p_code)
     );
$$;

comment on function public.module_visible(text) is
  'Видит ли вызывающий данные модуля (0104 Р6): owner/admin — всегда, остальные — только при включённом модуле. Зовётся из restrictive-политик и definer-функций модуля.';

revoke all on function public.module_visible(text) from public, anon, service_role;
grant execute on function public.module_visible(text) to authenticated;

create or replace function public.set_center_module(p_code text, p_enabled boolean)
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
  if coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Модули включает и выключает только владелец' using errcode = '42501';
  end if;
  if not public.center_writable(v_center) then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  if p_enabled is null then
    raise exception 'Укажите, включить модуль или выключить' using errcode = '22023';
  end if;
  if not exists (select 1 from public.app_modules m where m.code = p_code) then
    raise exception 'Модуль не найден' using errcode = '42704';
  end if;

  -- Два параллельных включения не должны упасть на частичном unique.
  perform pg_advisory_xact_lock(hashtextextended('center_module:' || v_center::text || ':' || p_code, 0));

  if p_enabled then
    if exists (select 1 from public.center_modules m
                where m.center_id = v_center and m.module_code = p_code and m.disabled_at is null) then
      return;
    end if;
    insert into public.center_modules (center_id, module_code) values (v_center, p_code);
  else
    update public.center_modules
       set disabled_at = now(), disabled_by = auth.uid()
     where center_id = v_center and module_code = p_code and disabled_at is null;
    if not found then
      return;
    end if;
  end if;

  perform public.emit_event(
    'center.module_changed',
    jsonb_build_object('center_id', v_center, 'module', p_code, 'enabled', p_enabled),
    v_center
  );
end;
$$;

revoke all on function public.set_center_module(text, boolean) from public, anon, service_role;
grant execute on function public.set_center_module(text, boolean) to authenticated;

create or replace function public.set_center_kind(p_kind text)
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
  if not exists (select 1 from public.center_kinds k where k.code = p_kind) then
    raise exception 'Неизвестный тип центра' using errcode = '22023';
  end if;
  if coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Тип центра меняет только владелец' using errcode = '42501';
  end if;
  -- Остальное (readonly, событие) — триггеры centers_kind_guard/_changed.
  update public.centers set kind = p_kind where id = v_center;
end;
$$;

revoke all on function public.set_center_kind(text) from public, anon, service_role;
grant execute on function public.set_center_kind(text) to authenticated;

create or replace function public.centers_seed_modules()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  -- created_by явным null: иначе default auth.uid() записал бы uid платформы.
  insert into public.center_modules (center_id, module_code, created_by)
  select new.id, m.module_code, null
    from public.center_kind_modules m
   where m.kind_code = new.kind;
  return null;
end;
$$;

revoke all on function public.centers_seed_modules() from public, anon, authenticated, service_role;

drop trigger if exists centers_seed_modules on public.centers;
create trigger centers_seed_modules
  after insert on public.centers
  for each row execute function public.centers_seed_modules();

-- Backfill: все центры, включая удалённые (иначе восстановленный центр
-- остался бы без клиники), — «Клиника». Без сессии readonly-guard не судит.
insert into public.center_modules (center_id, module_code, created_by)
select c.id, 'clinic', null
  from public.centers c
 where not exists (
   select 1 from public.center_modules m
    where m.center_id = c.id and m.module_code = 'clinic' and m.disabled_at is null
 );


-- 5. Гард записи модуля (Р3) ----------------------------------------------------------------------

create or replace function public.module_guarded_tables()
  returns table (table_name text, module_code text, insert_only boolean)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('diagnostics',                 'clinic', false),
    ('diagnostic_clinical_forms',   'clinic', false),
    ('diagnostic_referrals',        'clinic', false),
    ('student_anamnesis',           'clinic', false),
    ('student_articulation',        'clinic', false),
    ('syllable_assessments',        'clinic', false),
    ('prosody_assessments',         'clinic', false),
    ('reading_writing_assessments', 'clinic', false),
    ('goals',                       'clinic', false),
    ('goal_progress',               'clinic', false),
    ('monthly_reports',             'clinic', false),
    ('lesson_note_goal_scores',     'clinic', false),
    -- Только новые диктовки: отмена и закрытие не блокируются (Р3, Р5).
    ('lesson_voice_requests',       'clinic', true)
$$;

comment on function public.module_guarded_tables() is
  'Таблицы модулей под a01_module_guard (0104 Р3). goal_stages — нет: засевается всем центрам раньше модулей. Забор pgTAP: на каждой таблице списка стоит триггер.';

revoke all on function public.module_guarded_tables() from public, anon, authenticated, service_role;

create or replace function public.module_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_title text;
begin
  if public.center_has_module(new.center_id, tg_argv[0]) then
    return new;
  end if;

  -- Каскад on delete set null (удаление пользователя, специалиста, занятия):
  -- RI-действие выполняет UPDATE изнутри своего триггера (глубина ≥ 2), и все
  -- изменённые колонки стали NULL. Прямое обнуление из RPC (глубина 1) — это
  -- запись модуля и отказ: иначе выключенную клинику можно было бы стирать.
  if tg_op = 'UPDATE' and pg_trigger_depth() > 1 and not exists (
    select 1
      from jsonb_each(to_jsonb(new)) n
      join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.value <> 'null'::jsonb
  ) then
    return new;
  end if;

  select m.title into v_title from public.app_modules m where m.code = tg_argv[0];
  raise exception 'Модуль «%» выключен в настройках центра — включите его в «Настройки → Модули»',
    coalesce(v_title, tg_argv[0])
    using errcode = 'PT403';
end;
$$;

revoke all on function public.module_guard() from public, anon, authenticated, service_role;

create or replace procedure public.apply_module_guard(tbl text, module text, insert_only boolean default false)
  language plpgsql
  set search_path = ''
as $$
begin
  execute format('drop trigger if exists a01_module_guard on public.%I', tbl);
  execute format(
    'create trigger a01_module_guard before %s on public.%I for each row execute function public.module_guard(%L)',
    case when insert_only then 'insert' else 'insert or update' end,
    tbl, module
  );
end;
$$;

revoke execute on procedure public.apply_module_guard(text, text, boolean) from public, anon, authenticated, service_role;

do $$
declare
  r record;
begin
  for r in select * from public.module_guarded_tables() loop
    call public.apply_module_guard(r.table_name, r.module_code, r.insert_only);
  end loop;
end;
$$;


-- 6. Видимость при выключенном модуле (Р6) --------------------------------------------------------

-- Restrictive: ограничивает ВСЕХ читателей поверх permissive-политик; owner и
-- admin проходят через module_visible. lesson_voice_requests без грантов на
-- чтение — политика там не нужна.
do $$
declare
  r record;
begin
  for r in select * from public.module_guarded_tables() where table_name <> 'lesson_voice_requests' loop
    execute format('drop policy if exists %I on public.%I', r.table_name || '_module_visible', r.table_name);
    execute format(
      'create policy %I on public.%I as restrictive for select to authenticated using ((select public.module_visible(%L)))',
      r.table_name || '_module_visible', r.table_name, r.module_code
    );
  end loop;
end;
$$;


-- 7. Definer-функции клиники мимо RLS — перевыпуск с проверкой модуля (Р6) ------------------------

create or replace function public.student_diagnostics_brief(p_student_id uuid)
  returns table (id uuid, date date, conclusion text, teacher_name text, conclusion_name text)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  -- 0104 (ADR-013 Р6): при выключенной «Клинике» специалист и родитель её не видят.
  if not public.module_visible('clinic') then
    return;
  end if;

  if not public.clinical_visible_to_caller(p_student_id) then
    return;
  end if;

  return query
    select d.id, d.date, d.conclusion, t.full_name, c.name
      from public.diagnostics d
      left join public.teachers t on t.id = d.teacher_id
      left join public.speech_conclusions c on c.code = d.conclusion_code
     where d.student_id = p_student_id
       and d.center_id = public.current_center()
       and d.deleted_at is null
     order by d.date desc;
end;
$$;

create or replace function public.student_goals_brief(p_student_id uuid)
  returns table (
    id          uuid,
    title       text,
    area        text,
    sound       text,
    stage_title text,
    stage_sort  integer,
    status      text,
    target_date date,
    last_score  integer,
    trend       text
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  -- 0104 (ADR-013 Р6): при выключенной «Клинике» специалист и родитель её не видят.
  if not public.module_visible('clinic') then
    return;
  end if;

  if not public.clinical_visible_to_caller(p_student_id) then
    return;
  end if;

  return query
    select
      g.id, g.title, g.area, g.sound, st.title, st.sort, g.status, g.target_date,
      gp.s1,
      case
        when coalesce(public.my_role(), '') = 'parent' then null
        -- gp.n is null недостижимо: left join lateral на агрегат без
        -- group by всегда даёт ровно одну строку (count(*) = 0 на
        -- пустом входе), просто defensive на случай будущей правки.
        when gp.n is null or gp.n < 3 then null
        when gp.s1 - gp.s2 <= -10 then 'regress'
        when gp.max_score - gp.min_score <= 5 then 'stagnant'
        when gp.s1 - gp.s3 >= 10 then 'growth'
        else 'stable'
      end
    from public.goals g
    join public.goal_stages st on st.id = g.stage_id
    left join lateral (
      select
        count(*)::int                                as n,
        max(x.score) filter (where x.rn = 1)          as s1,
        max(x.score) filter (where x.rn = 2)          as s2,
        max(x.score) filter (where x.rn = 3)          as s3,
        max(x.score)                                  as max_score,
        min(x.score)                                  as min_score
      from (
        select p.score,
               row_number() over (order by p.date desc, p.created_at desc, p.id desc) as rn
          from public.goal_progress p
         where p.goal_id = g.id
           and p.center_id = g.center_id
           and p.deleted_at is null
         order by p.date desc, p.created_at desc, p.id desc
         limit 3
      ) x
    ) gp on true
    where g.student_id = p_student_id
      and g.center_id = public.current_center()
      and g.deleted_at is null
    order by st.sort, g.created_at;
end;
$$;

create or replace function public.student_goal_dynamics_brief(
  p_student_id uuid,
  p_from       date,
  p_to         date
)
  returns table (
    goal_id     uuid,
    title       text,
    stage_title text,
    score_first integer,
    score_last  integer,
    points      integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  -- 0104 (ADR-013 Р6): при выключенной «Клинике» специалист и родитель её не видят.
  if not public.module_visible('clinic') then
    return;
  end if;

  if p_from is null or p_to is null then
    raise exception 'Укажите период' using errcode = '22023';
  end if;
  if not public.clinical_visible_to_caller(p_student_id) then
    return;
  end if;

  return query
    with points as (
      select gp.goal_id, gp.score, gp.date,
             row_number() over (partition by gp.goal_id order by gp.date, gp.created_at) as first_n,
             row_number() over (partition by gp.goal_id order by gp.date desc, gp.created_at desc) as last_n,
             count(*) over (partition by gp.goal_id) as total
        from public.goal_progress gp
        join public.goals g on g.id = gp.goal_id
       where g.student_id = p_student_id
         and g.center_id = public.current_center()
         and g.deleted_at is null
         and gp.deleted_at is null
         and gp.date >= p_from and gp.date <= p_to
    )
    select g.id, g.title, st.title,
           max(case when p.first_n = 1 then p.score end)::integer,
           max(case when p.last_n  = 1 then p.score end)::integer,
           max(p.total)::integer
      from points p
      join public.goals g on g.id = p.goal_id
      join public.goal_stages st on st.id = g.stage_id
     group by g.id, g.title, st.title, st.sort
     order by st.sort, g.title;
end;
$$;

create or replace function public.student_conclusions()
  returns table (student_id uuid, conclusion_code text, conclusion_name text, date date)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin', 'teacher') then
    return;
  end if;

  -- 0104 (ADR-013 Р6): при выключенной «Клинике» специалист и родитель её не видят.
  if not public.module_visible('clinic') then
    return;
  end if;

  return query
    select l.student_id, l.conclusion_code, c.name, l.date
      from (
        -- Р17: последнее ПОСТАВЛЕННОЕ заключение — фильтр по коду ВНУТРИ
      -- distinct on, иначе новая диагностика без кода стирала бы прошлый
      -- диагноз из списка.
      select distinct on (d.student_id) d.student_id, d.conclusion_code, d.date
          from public.diagnostics d
         where d.center_id = v_center and d.deleted_at is null and d.conclusion_code is not null
         order by d.student_id, d.date desc, d.created_at desc
      ) l
      join public.speech_conclusions c on c.code = l.conclusion_code
     where v_role in ('owner', 'admin') or public.clinical_teacher_sees(l.student_id);
end;
$$;

create or replace function public.goal_suggestions(p_diagnostic_id uuid)
  returns table (
    sound                text,
    sound_status         text,
    stage_id             uuid,
    stage_title          text,
    title                text,
    already_active       boolean,
    existing_stage_title text,
    existing_status      text
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_role    text := coalesce(public.my_role(), '');
  v_student uuid;
  v_sounds  jsonb;
  v_stage   public.goal_stages;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  -- 0104 (ADR-013 Р6): при выключенной «Клинике» специалист и родитель её не видят.
  if not public.module_visible('clinic') then
    return;
  end if;

  select d.student_id, d.sounds into v_student, v_sounds
    from public.diagnostics d
    join public.students s on s.id = d.student_id and s.center_id = d.center_id and s.deleted_at is null
   where d.id = p_diagnostic_id and d.center_id = v_center and d.deleted_at is null;
  if v_student is null then
    raise exception 'Диагностика не найдена' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(v_student)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_stage
    from public.goal_stages gs
   where gs.center_id = v_center and gs.code = 'setting' and gs.deleted_at is null;
  if not found then
    return;
  end if;

  return query
    with marks as (
      -- «р» и «Р » в одной карте — один звук; карта не объект — пусто, не 22023.
      select distinct on (lower(btrim(e.key))) lower(btrim(e.key)) as snd, e.value as status
        from jsonb_each_text(
               case when jsonb_typeof(v_sounds) = 'object' then v_sounds else '{}'::jsonb end
             ) e
       where e.value in ('искажение', 'отсутствие', 'замена')
         and btrim(e.key) <> ''
       order by lower(btrim(e.key)), e.key
    )
    select m.snd,
           m.status,
           v_stage.id,
           v_stage.title,
           'Звук ' || m.snd || ': ' || lower(v_stage.title),
           exists (
             select 1 from public.goals g
              where g.student_id = v_student and g.center_id = v_center and g.deleted_at is null
                and g.status = 'active' and g.stage_id = v_stage.id
                and lower(btrim(g.sound)) = m.snd
           ),
           x.stage_title,
           x.status
      from marks m
      left join lateral (
        -- Любая живая цель по звуку (кроме достигнутых): активная раньше паузы.
        select gs.title as stage_title, g.status
          from public.goals g
          join public.goal_stages gs on gs.id = g.stage_id
         where g.student_id = v_student and g.center_id = v_center and g.deleted_at is null
           and g.status in ('active', 'paused') and lower(btrim(g.sound)) = m.snd
         order by (g.status = 'active') desc, gs.sort desc
         limit 1
      ) x on true
     order by coalesce(array_position(array['р','л','ш','ж','с','з','ц','ч','щ'], m.snd), 100), m.snd;
end;
$$;

create or replace function public.student_monthly_report(p_student_id uuid, p_month date)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_month   date := date_trunc('month', p_month)::date;
  v_to      date;
  v_att     jsonb;
  v_goals   jsonb;
  v_notes   jsonb;
  v_total   integer := 0;
  v_absent  integer := 0;
  v_tz      text;
  v_sent    public.monthly_reports;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if p_month is null then
    raise exception 'Укажите месяц' using errcode = '22023';
  end if;

  -- 0104 (ADR-013 Р6): отчёт — часть модуля «Клиника»; без модуля отказ целиком,
  -- а не отчёт с пустыми целями.
  if not public.module_visible('clinic') then
    raise exception 'Модуль «Клиника» выключен в настройках центра' using errcode = 'PT403';
  end if;

  -- Р3: читать может тот же круг, что видит клинику ребёнка, — включая
  -- родителя. Р6: по архивному ребёнку узкие функции молчат, и вместо
  -- пустой страницы, неотличимой от «занятий не было», честный отказ.
  if not public.clinical_visible_to_caller(p_student_id) then
    -- Р6: «в архиве» говорим только тому, кто и так вправе знать про этого
    -- ребёнка. Иначе по произвольному uuid любой отличал бы архивного
    -- ребёнка этого центра от всего остального — оракул существования.
    if exists (
      select 1 from public.students s
       where s.id = p_student_id and s.center_id = v_center and s.deleted_at is not null
         and (coalesce(public.my_role(), '') in ('owner', 'admin')
              or public.parent_of_student(s.id)
              or public.teacher_teaches_student(s.id))
    ) then
      raise exception 'Ребёнок в архиве — отчёт недоступен' using errcode = '42704';
    end if;
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_to := (v_month + interval '1 month' - interval '1 day')::date;
  v_tz := public.center_timezone(v_center);

  select * into v_sent from public.monthly_reports r
   where r.center_id = v_center and r.student_id = p_student_id and r.period_month = v_month;

  -- Р1: только узкие функции. Ни одного select из attendance,
  -- goal_progress, lesson_notes, diagnostics.
  select coalesce(jsonb_agg(jsonb_build_object(
           'date',   to_char(a.lesson_at at time zone v_tz, 'DD.MM.YYYY'),
           'status', a.status_name
         ) order by a.lesson_at), '[]'::jsonb),
         count(*)::integer,
         count(*) filter (where a.counts_absence)::integer
    into v_att, v_total, v_absent
    from public.student_attendance_brief(p_student_id, v_month, v_to) a;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', g.title,
           'stage', g.stage_title,
           'from',  g.score_first,
           'to',    g.score_last,
           'points', g.points
         )), '[]'::jsonb)
    into v_goals
    from public.student_goal_dynamics_brief(p_student_id, v_month, v_to) g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'date',    to_char(n.lesson_at at time zone v_tz, 'DD.MM.YYYY'),
           'summary', n.parent_summary
         ) order by n.lesson_at), '[]'::jsonb)
    into v_notes
    from public.student_notes_brief(p_student_id) n
   where (n.lesson_at at time zone v_tz)::date >= v_month
     and (n.lesson_at at time zone v_tz)::date <= v_to;

  return jsonb_build_object(
    'student_id',      p_student_id,
    'student_name',    (select s.full_name from public.students s where s.id = p_student_id),
    'period_month',    v_month,
    'lessons_total',   v_total,
    'absences',        v_absent,
    'attendance',      v_att,
    'goals',           v_goals,
    'notes',           v_notes,
    'teacher_comment', v_sent.teacher_comment,
    'is_empty',        (v_total = 0 and jsonb_array_length(v_notes) = 0),
    'generated_at',    now(),
    -- Р4 на экране: числа выше пересчитаны живьём, а это — то, что
    -- родитель реально получил. Без них экран молча показывал бы другие
    -- числа, чем лежат у родителя в переписке, и кто прав — не сказал бы
    -- никто. Интерфейс обязан показать расхождение, а не спрятать его.
    'sent',            case when v_sent.sent_count > 0 then jsonb_build_object(
                         'count',      v_sent.sent_count,
                         'last_at',    v_sent.last_sent_at,
                         'summary',    v_sent.summary_text,
                         'stats',      v_sent.stats,
                         'is_stale',   (v_sent.stats -> 'lessons_total') is distinct from to_jsonb(v_total)
                       ) else null end
  );
end;
$$;

revoke all on function public.student_diagnostics_brief(uuid) from public, anon;
grant execute on function public.student_diagnostics_brief(uuid) to authenticated;
revoke all on function public.student_goals_brief(uuid) from public, anon;
grant execute on function public.student_goals_brief(uuid) to authenticated;
revoke all on function public.student_goal_dynamics_brief(uuid, date, date) from public, anon, service_role;
grant execute on function public.student_goal_dynamics_brief(uuid, date, date) to authenticated;
revoke all on function public.student_conclusions() from public, anon, service_role;
grant execute on function public.student_conclusions() to authenticated;
revoke all on function public.goal_suggestions(uuid) from public, anon, service_role;
grant execute on function public.goal_suggestions(uuid) to authenticated;
revoke all on function public.student_monthly_report(uuid, date) from public, anon, service_role;
grant execute on function public.student_monthly_report(uuid, date) to authenticated;


-- 8. Голосовой контур и утверждение заметки (Р4, Р5) ----------------------------------------------

create or replace function public.bot_voice_pending(p_lesson_id uuid, p_student_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1 from public.lesson_voice_requests r
     where r.lesson_id = p_lesson_id
       and r.student_id = p_student_id
       and r.cancelled_at is null
       -- 0104: при выключенной «Клинике» диктовка не держит текстовую заметку.
       and public.center_has_module(r.center_id, 'clinic')
       and (
         (r.consumed_at is null and r.expires_at > now())
         or (
           r.consumed_at is not null
           and r.consumed_at > now() - interval '24 hours'
           and not exists (select 1 from public.lesson_notes n where n.conduct_key = r.id)
           and not exists (
             select 1 from public.ai_jobs j
             join public.events e on e.id = j.event_id
            where e.type = 'lesson.voice_received'
              and (e.payload ->> 'voice_request_id')::uuid = r.id
              and j.status = 'failed'
           )
         )
       )
  );
$$;

revoke all on function public.bot_voice_pending(uuid, uuid)
  from public, anon, authenticated, service_role, bot_worker;

create or replace function public.ai_job_begin(p_event_id bigint)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_event   public.events;
  v_request public.lesson_voice_requests;
  v_job     public.ai_jobs;
  v_goals   jsonb;
  v_total   integer;
  v_limit   integer;
  v_used    integer;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р3/Р7 (0042): событие принимается только живое, своё и захваченное.
  select * into v_event from public.events
   where id = p_event_id
     and type = 'lesson.voice_received'
     and processed_at is null
     and claimed_at is not null;
  if not found then
    return null;
  end if;

  select * into v_request from public.lesson_voice_requests
   where id = (v_event.payload ->> 'voice_request_id')::uuid;
  if not found then
    return null;
  end if;

  -- Р8 (0042): свежесть считается от диктовки, не от токена.
  if v_request.consumed_at is null or v_request.consumed_at < now() - interval '24 hours' then
    return null;
  end if;

  -- Б3 (0042): всё, на чём упадёт запись, проверяется ЗДЕСЬ — до Whisper
  -- и модели. Иначе отказ приходит после двух платных вызовов, работа
  -- становится терминальной, и диктовка не восстанавливается никогда.
  if v_request.center_id <> v_event.center_id then
    return null;
  end if;
  if not exists (
    select 1 from public.students s
     where s.id = v_request.student_id and s.deleted_at is null
  ) then
    return null;
  end if;
  if not exists (
    select 1 from public.lessons l
     where l.id = v_request.lesson_id and l.deleted_at is null and l.status <> 'cancelled'
  ) then
    return null;
  end if;
  if exists (
    select 1 from public.lesson_notes n
     where n.lesson_id = v_request.lesson_id and n.student_id = v_request.student_id
       and n.deleted_at is null
       and (n.status = 'approved'
            or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
  ) then
    return null;
  end if;

  -- 0051 Р8/Р9: подписка истекла между диктовкой и обработкой — деньги
  -- платформы не тратятся, специалист узнаёт один раз. После проверок выше
  -- (работа, которую всё равно отбросили бы, сообщения не заслуживает) и до
  -- insert в ai_jobs (следа в очереди работ нет). «Один раз» держит
  -- частичный unique events_voice_blocked_once, а не if — два параллельных
  -- прогона n8n иначе эмитили бы оба.
  -- 0104 (ADR-013 Р5): «Клинику» выключили после диктовки — цели ребёнка
  -- не уходят в модель, деньги не тратятся. Тихо: окно — минуты между
  -- report_voice_note и обработкой, bot_voice_pending уже не держит заметку.
  if not public.center_has_module(v_event.center_id, 'clinic') then
    return null;
  end if;

  if not public.center_writable(v_event.center_id) then
    begin
      perform public.emit_event_unchecked(
        'subscription.voice_blocked',
        jsonb_build_object(
          'center_id',        v_event.center_id,
          'voice_request_id', v_request.id,
          'reason_code',      'subscription_expired'
        ),
        v_event.center_id
      );
    exception when unique_violation then
      null;
    end;
    return null;
  end if;

  -- 0053 Р2–Р4: квота голосовых резюме. Замок тем же ключом, что лимиты 0049,
  -- до счёта и до insert ai_jobs; тарифа или ключа нет — null без события
  -- (fail closed); резерв — работы в полёте кроме своей (перезахват).
  -- Перехват сужен до 23514 (единственный исход plan_limit при отсутствии
  -- тарифа/ключа, 0049) — иначе настоящая поломка тонет молча без следа.
  perform pg_advisory_xact_lock(hashtextextended('center_limit:' || v_event.center_id::text, 0));
  begin
    v_limit := public.plan_limit(v_event.center_id, 'ai_notes_month');
  exception when sqlstate '23514' then
    return null;
  end;
  if v_limit >= 0 then
    v_used := public.center_ai_notes_used(v_event.center_id);
    if v_used + public.ai_notes_reserved(v_event.center_id, p_event_id) >= v_limit then
      begin
        perform public.emit_event_unchecked(
          'ai.quota_exceeded',
          jsonb_build_object(
            'center_id',        v_event.center_id,
            'voice_request_id', v_request.id,
            'used',             v_used,
            'limit',            v_limit
          ),
          v_event.center_id
        );
      exception when unique_violation then
        null;
      end;
      return null;
    end if;
  end if;

  select * into v_job from public.ai_jobs where event_id = p_event_id for update;

  if found then
    -- Р4 (0042): сделанное и терминальное не переигрывается — n8n сразу ack.
    if v_job.status in ('done', 'failed') then
      return null;
    end if;
    -- В2 (0042): пока прогон свеж, работа занята. Без этого
    -- release_stale_claims возвращает событие за спину живому обработчику,
    -- и Whisper с моделью оплачиваются второй раз. Порог меньше того, с
    -- которым очередь возвращает пачки (10 минут), — иначе окна не
    -- остаётся вовсе.
    if v_job.started_at > now() - interval '8 minutes' then
      return null;
    end if;
    update public.ai_jobs
       set attempts = attempts + 1, started_at = now()
     where event_id = p_event_id;
  else
    -- В7 (0042): голый insert на гонке двух прогонов падал бы на первичном
    -- ключе, и воркер разобрал бы это как сбой — терминал по причине,
    -- которой нет.
    insert into public.ai_jobs (event_id, center_id)
    values (p_event_id, v_event.center_id)
    on conflict (event_id) do nothing
    returning * into v_job;

    if v_job.event_id is null then
      return null;
    end if;
  end if;

  -- 0048 Р1–Р6: активные цели ребёнка диктовки, обезличенно, в
  -- детерминированном порядке, не больше 50, с полным числом отдельно.
  -- Один проход: предикат «активная цель» написан один раз, список и
  -- полное число не могут разойтись при следующей правке фильтра.
  select coalesce(jsonb_agg(jsonb_build_object(
           'goal_id',     x.id,
           'title',       x.title,
           'area',        x.area,
           'sound',       x.sound,
           'stage_title', x.stage_title
         ) order by x.stage_sort, x.created_at, x.id) filter (where x.rn <= 50), '[]'::jsonb),
         coalesce(max(x.total), 0)::integer
    into v_goals, v_total
    from (
      select g.id, g.title, g.area, g.sound, st.title as stage_title, st.sort as stage_sort, g.created_at,
             row_number() over (order by st.sort, g.created_at, g.id) as rn,
             count(*) over () as total
        from public.goals g
        join public.goal_stages st on st.id = g.stage_id
       where g.student_id = v_request.student_id
         and g.center_id = v_request.center_id
         and g.deleted_at is null
         and g.status = 'active'
    ) x;

  return jsonb_build_object(
    'file_id',             v_event.payload ->> 'file_id',
    'center_id',           v_request.center_id,
    'lesson_id',           v_request.lesson_id,
    'student_id',          v_request.student_id,
    'student_goals',       v_goals,
    'student_goals_total', v_total
  );
end;
$$;

revoke all on function public.ai_job_begin(bigint) from public, anon, authenticated, service_role;
grant execute on function public.ai_job_begin(bigint) to bot_worker;

create or replace function public.approve_lesson_note(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.lesson_notes;
  v_date   date;
  v_item   record;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.lesson_notes
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Заметка не найдена' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or v_row.created_by = auth.uid()) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Повторное утверждение — холостой ход, а не ошибка (0038).
  if v_row.status = 'approved' then
    return;
  end if;

  update public.lesson_notes set status = 'approved' where id = p_id;

  select (l.starts_at at time zone public.center_timezone(v_center))::date
    into v_date
    from public.lessons l where l.id = v_row.lesson_id;

  -- Б2: conduct_key оставляем пустым и пропускаем цели, по которым за это
  -- занятие оценка уже есть. Занять ключ lesson_id нельзя: им гасит повторы
  -- complete_lesson (0039), и ручная оценка, поставленная ПОСЛЕ утверждения,
  -- молча не записалась бы — ровно тот отказ, который 0039 Р3 называет
  -- недопустимым. Так ручная всегда выигрывает, а потеряться не может
  -- ничего.
  -- 0104 (ADR-013 Р4): без «Клиники» заметка утверждается без переноса оценок —
  -- они остаются предложениями, гард goal_progress не ослабляется.
  if public.center_has_module(v_center, 'clinic') then
  for v_item in
    select s.goal_id, s.score, s.note
      from public.lesson_note_goal_scores s
     where s.note_id = p_id
       and not exists (
         select 1 from public.goal_progress gp
          where gp.goal_id = s.goal_id
            and gp.lesson_id = v_row.lesson_id
            and gp.deleted_at is null
       )
  loop
    insert into public.goal_progress
      (center_id, goal_id, lesson_id, date, score, note, created_by)
    values
      (v_center, v_item.goal_id, v_row.lesson_id,
       coalesce(v_date, public.center_today(v_center)), v_item.score, v_item.note,
       coalesce(v_row.created_by, auth.uid()));
  end loop;
  end if;
end;
$$;

revoke all on function public.approve_lesson_note(uuid) from public, anon, service_role;
grant execute on function public.approve_lesson_note(uuid) to authenticated;


-- 9. create_center / platform_create_center — без перегрузки (Р7) ---------------------------------

drop function if exists public.create_center(text, text);

create function public.create_center(p_name text, p_city text default null, p_kind text default 'speech')
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_id     uuid;
  v_base   text;
  v_slug   text;
  v_suffix int := 1;
begin
  if v_uid is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'Название центра обязательно' using errcode = '22004';
  end if;
  if not exists (select 1 from public.center_kinds k where k.code = p_kind) then
    raise exception 'Неизвестный тип центра' using errcode = '22023';
  end if;

  v_base := nullif(public.slugify(p_name), '');
  if v_base is null then
    v_base := 'center';
  end if;

  v_slug := v_base;
  while exists (select 1 from public.centers c where c.slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base || '-' || v_suffix;
  end loop;

  -- 0104: модули центра засевает триггер centers_seed_modules по kind.
  insert into public.centers (name, slug, settings, kind)
  values (
    trim(p_name),
    v_slug,
    jsonb_build_object('city', p_city, 'features', '{}'::jsonb),
    p_kind
  )
  returning id into v_id;

  insert into public.memberships (user_id, center_id, role)
  values (v_uid, v_id, 'owner');

  perform public.switch_center(v_id);

  perform public.emit_event(
    'center.created',
    jsonb_build_object('center_id', v_id, 'name', trim(p_name), 'city', p_city, 'slug', v_slug, 'kind', p_kind),
    v_id
  );
  perform public.emit_event(
    'membership.created',
    jsonb_build_object('center_id', v_id, 'user_id', v_uid, 'role', 'owner'),
    v_id
  );

  return v_id;
end;
$$;

revoke all on function public.create_center(text, text, text) from public, anon, service_role;
grant execute on function public.create_center(text, text, text) to authenticated;

drop function if exists public.platform_create_center(text, text, text);

create function public.platform_create_center(
  p_name        text,
  p_owner_email text,
  p_city        text default null,
  p_kind        text default 'speech'
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_owner  uuid;
  v_id     uuid;
  v_base   text;
  v_slug   text;
  v_suffix int := 1;
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Название центра обязательно' using errcode = '22004';
  end if;
  if not exists (select 1 from public.center_kinds k where k.code = p_kind) then
    raise exception 'Неизвестный тип центра' using errcode = '22023';
  end if;

  select u.id into v_owner
    from auth.users u
   where lower(u.email) = lower(trim(coalesce(p_owner_email, '')))
     and u.email_confirmed_at is not null;
  if v_owner is null then
    raise exception 'Пользователь с таким email не найден или email не подтверждён' using errcode = '42704';
  end if;

  v_base := coalesce(nullif(public.slugify(p_name), ''), 'center');
  v_slug := v_base;
  while exists (select 1 from public.centers c where c.slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base || '-' || v_suffix;
  end loop;

  insert into public.centers (name, slug, settings, kind)
  values (trim(p_name), v_slug, jsonb_build_object('city', p_city, 'features', '{}'::jsonb), p_kind)
  returning id into v_id;

  insert into public.memberships (user_id, center_id, role)
  values (v_owner, v_id, 'owner');

  perform public.emit_event_platform(
    'center.created',
    jsonb_build_object('center_id', v_id, 'name', trim(p_name), 'city', p_city, 'slug', v_slug, 'kind', p_kind),
    v_id
  );
  perform public.emit_event_platform(
    'membership.created',
    jsonb_build_object('center_id', v_id, 'user_id', v_owner, 'role', 'owner'),
    v_id
  );

  return v_id;
end;
$$;

comment on function public.platform_create_center(text, text, text, text) is
  'Второй (и далее) центр владельцу заводит платформа (0052 Р9): trial-лимит на владельца из платформенной сессии не действует. Владелец — по подтверждённому email; платформа членства не получает. 0104: p_kind — тип центра, модули засевает триггер.';

revoke all on function public.platform_create_center(text, text, text, text) from public, anon, service_role;
grant execute on function public.platform_create_center(text, text, text, text) to authenticated;


-- 10. Заборы: readonly-исключения, экспорт центра -------------------------------------------------

create or replace function public.readonly_guard_exempt_tables()
  returns table (table_name text, reason text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('audit_log',               'Р2: аудит действия платформы, снимающего блокировку'),
    ('events',                  'Р2/Р3: события платформы и закрытие работы воркера'),
    ('notification_log',        'Р3: закрытие доставки'),
    ('lesson_reminders_sent',   'Р3: отметка воркера'),
    ('center_digest_runs',      'Р3: отметка воркера'),
    ('ai_jobs',                 'Р3: закрытие работы ИИ'),
    ('ai_usage',                'Р3: учёт уже потраченного'),
    ('lesson_confirmations',    'Р3: пишет только bot_worker'),
    ('centers',                 'Р12: нет center_id; название и пояс правятся, тариф и срок держит centers_protect_plan (0049)'),
    ('plans',                   'Р7: справочник платформы, пишет только миграция'),
    ('platform_admins',         'Р7: справочник платформы, пишет только миграция'),
    ('notification_event_types','Р7: справочник, пишет только миграция'),
    ('telegram_accounts',       'Р12: нет center_id; привязать и отвязать Telegram не зависит от оплаты'),
    ('telegram_link_codes',     'Р12: нет center_id; код привязки Telegram'),
    ('platform_payments',       'Р2/Р12: заявка на оплату — путь разблокировки (0051)'),
    ('subscription_reminders_sent', 'Р3: отметка планировщика (0052)'),
    ('funnel_stages',           'А (0055): глобальный справочник без center_id, пишет только миграция'),
    ('speech_conclusions',      'Р1 (0059): глобальный справочник без center_id, пишет только миграция'),
    ('clinical_forms',          'Р1 (0059): глобальный справочник без center_id, пишет только миграция'),
    ('referral_targets',        'Р1 (0059): глобальный справочник без center_id, пишет только миграция'),
    ('teacher_schedule_sent',   'Р3: отметка планировщика (0097)'),
    ('debt_reminder_runs',      'Р3: отметка планировщика (0097)'),
    ('subscription_period_reminders_sent', 'Р3: отметка планировщика (0097)'),
    ('bot_accounts',            'Р12: нет center_id; бот-аккаунт родителя пишет только бот (0098)'),
    ('center_kinds',            'Р7 (0104): глобальный справочник без center_id, пишет только миграция'),
    ('app_modules',             'Р7 (0104): глобальный справочник без center_id, пишет только миграция'),
    ('center_kind_modules',     'Р7 (0104): глобальный справочник без center_id, пишет только миграция')
$$;

revoke all on function public.readonly_guard_exempt_tables() from public, anon, authenticated, service_role;

create or replace function public.export_center_tables()
  returns table (table_name text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('attendance'), ('attendance_statuses'), ('booking_requests'), ('cash_counts'), ('cash_transfers'), ('center_modules'),
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
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. 0087: lesson_debt_writeoffs. 0088: lesson_debt_covers. 0090: subscription_shortfall_writeoffs. 0093: payment_voids. 0101: cash_transfers, discount_reasons. 0102: cash_counts. 0104: center_modules. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;

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
    'settings', v_c.settings, 'kind', v_c.kind, 'created_at', v_c.created_at
  );
end;
$$;

revoke all on function public.export_center_info() from public, anon, service_role;
grant execute on function public.export_center_info() to authenticated;
