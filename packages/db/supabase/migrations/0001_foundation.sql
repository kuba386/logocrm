-- =============================================================================
-- 0001_foundation.sql — фундамент мультитенантного LogoCRM
--
-- Что здесь:
--   1. расширения
--   2. centers            — тенант (логопедический центр)
--   3. memberships        — кто и с какой ролью состоит в центре
--   4. helper-функции     — current_center / my_role / has_feature / switch_center
--   5. apply_tenant_rls   — единая политика доступа для всех будущих таблиц
--   6. audit_log + apply_audit
--   7. events + emit_event (outbox)
--   8. RLS на служебные таблицы
--   9. create_center      — регистрация нового центра
--
-- Соглашения для всех новых таблиц: см. docs/Database.md
-- =============================================================================

-- 1. Расширения ---------------------------------------------------------------

create schema if not exists extensions;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists moddatetime with schema extensions;


-- 2. centers ------------------------------------------------------------------

create table if not exists public.centers (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null,
  slug               text not null unique,
  plan               text not null default 'trial'
                       check (plan in ('trial', 'solo', 'studio', 'ai')),
  trial_ends_at      timestamptz default (now() + interval '14 days'),
  subscription_until timestamptz,
  -- settings.features — набор включённых фич (см. has_feature)
  -- settings.city     — город центра (Бишкек, Ош, ...)
  settings           jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz
);

comment on table public.centers is 'Тенант: логопедический центр или частный кабинет.';
comment on column public.centers.settings is 'Настройки центра. Ключи: features (jsonb), city (text).';

create index if not exists centers_slug_idx on public.centers (slug) where deleted_at is null;

drop trigger if exists centers_set_updated_at on public.centers;
create trigger centers_set_updated_at
  before update on public.centers
  for each row execute function extensions.moddatetime(updated_at);


-- 3. memberships --------------------------------------------------------------

create table if not exists public.memberships (
  user_id    uuid not null references auth.users (id) on delete cascade,
  center_id  uuid not null references public.centers (id) on delete cascade,
  role       text not null check (role in ('owner', 'admin', 'teacher', 'parent')),
  -- teacher_id / payer_id заполняются, когда пользователь привязан
  -- к строке в будущих таблицах teachers / payers своего центра
  teacher_id uuid,
  payer_id   uuid,
  created_at timestamptz not null default now(),
  primary key (user_id, center_id)
);

comment on table public.memberships is 'Связь пользователь ↔ центр с ролью. Один пользователь может состоять в нескольких центрах.';

create index if not exists memberships_center_idx on public.memberships (center_id);


-- 4. Helper-функции -----------------------------------------------------------

-- Текущий центр берётся из JWT (app_metadata.center_id), который проставляет
-- switch_center. Никогда не из тела запроса — иначе тенант подделывается.
create or replace function public.current_center()
  returns uuid
  language sql
  stable
  set search_path = ''
as $$
  select nullif(auth.jwt() -> 'app_metadata' ->> 'center_id', '')::uuid;
$$;

comment on function public.current_center() is 'ID центра текущего пользователя из JWT app_metadata.';

-- security definer: функция читает memberships в обход RLS, иначе политики
-- на самой memberships уходят в бесконечную рекурсию.
create or replace function public.role_in(p_center_id uuid)
  returns text
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select m.role
    from public.memberships m
   where m.user_id = auth.uid()
     and m.center_id = p_center_id;
$$;

create or replace function public.is_member(p_center_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m
     where m.user_id = auth.uid() and m.center_id = p_center_id
  );
$$;

create or replace function public.my_role()
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select public.role_in(public.current_center());
$$;

create or replace function public.my_teacher_id()
  returns uuid
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select m.teacher_id
    from public.memberships m
   where m.user_id = auth.uid()
     and m.center_id = public.current_center();
$$;

create or replace function public.my_payer_id()
  returns uuid
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select m.payer_id
    from public.memberships m
   where m.user_id = auth.uid()
     and m.center_id = public.current_center();
$$;

-- Фича-флаги тарифа. settings->'features' поддерживает две формы:
--   массив:  ["ai_reports", "whatsapp"]
--   объект:  {"ai_reports": true, "whatsapp": false}
create or replace function public.has_feature(p_feature text)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_features jsonb;
begin
  select c.settings -> 'features'
    into v_features
    from public.centers c
   where c.id = public.current_center();

  if v_features is null then
    return false;
  end if;

  if jsonb_typeof(v_features) = 'array' then
    return v_features ? p_feature;
  end if;

  return coalesce((v_features ->> p_feature)::boolean, false);
end;
$$;

-- Переключение активного центра: пишем center_id в app_metadata.
-- Клиент обязан после вызова сделать refreshSession() — иначе в старом JWT
-- останется прежний center_id.
create or replace function public.switch_center(p_center_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.memberships m
     where m.user_id = v_uid and m.center_id = p_center_id
  ) then
    raise exception 'Нет доступа к центру %', p_center_id using errcode = '42501';
  end if;

  update auth.users
     set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
                             || jsonb_build_object('center_id', p_center_id)
   where id = v_uid;
end;
$$;


-- 5. apply_tenant_rls ---------------------------------------------------------

-- Включает RLS и вешает базовую политику тенанта на таблицу.
-- Таблица обязана иметь колонки center_id и deleted_at.
--
-- USING содержит `deleted_at is null` (мягко удалённые строки невидимы),
-- а WITH CHECK — нет: иначе UPDATE ... SET deleted_at = now() (наш soft delete)
-- был бы запрещён собственной же политикой.
create or replace procedure public.apply_tenant_rls(tbl text)
  language plpgsql
as $$
begin
  execute format('alter table public.%I enable row level security', tbl);
  execute format('drop policy if exists tenant_admin on public.%I', tbl);
  execute format(
    'create policy tenant_admin on public.%I for all to authenticated
       using (center_id = public.current_center()
              and public.my_role() in (''owner'', ''admin'')
              and deleted_at is null)
       with check (center_id = public.current_center()
                   and public.my_role() in (''owner'', ''admin''))',
    tbl
  );
end;
$$;

comment on procedure public.apply_tenant_rls(text) is
  'call apply_tenant_rls(''students'') — включает RLS и политику tenant_admin.';


-- 6. audit_log ----------------------------------------------------------------

create table if not exists public.audit_log (
  id         bigserial primary key,
  center_id  uuid,
  table_name text not null,
  row_id     uuid,
  action     text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data   jsonb,
  new_data   jsonb,
  user_id    uuid,
  at         timestamptz not null default now()
);

create index if not exists audit_log_center_at_idx on public.audit_log (center_id, at desc);
create index if not exists audit_log_row_idx on public.audit_log (table_name, row_id);

create or replace function public.audit_trigger()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_old    jsonb;
  v_new    jsonb;
  v_row    uuid;
  v_center uuid;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;

  v_row := coalesce(v_new ->> 'id', v_old ->> 'id')::uuid;

  if tg_table_name = 'centers' then
    v_center := v_row;
  else
    v_center := coalesce(v_new ->> 'center_id', v_old ->> 'center_id')::uuid;
  end if;

  insert into public.audit_log (center_id, table_name, row_id, action, old_data, new_data, user_id)
  values (v_center, tg_table_name, v_row, tg_op, v_old, v_new, auth.uid());

  return null; -- after-триггер
end;
$$;

create or replace procedure public.apply_audit(tbl text)
  language plpgsql
as $$
begin
  execute format('drop trigger if exists %I on public.%I', tbl || '_audit', tbl);
  execute format(
    'create trigger %I after insert or update or delete on public.%I
       for each row execute function public.audit_trigger()',
    tbl || '_audit', tbl
  );
end;
$$;

call public.apply_audit('centers');
call public.apply_audit('memberships');


-- 7. events (outbox) ----------------------------------------------------------

create table if not exists public.events (
  id           bigserial primary key,
  center_id    uuid not null,
  type         text not null,
  payload      jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  processed_at timestamptz
);

comment on table public.events is
  'Transactional outbox. Пишется только через emit_event, вычитывается воркером по processed_at is null.';

create index if not exists events_unprocessed_idx
  on public.events (processed_at) where processed_at is null;
create index if not exists events_center_type_idx on public.events (center_id, type, created_at desc);

-- p_center_id нужен только вызовам изнутри security definer-функций
-- (например create_center), когда JWT ещё не содержит новый center_id.
create or replace function public.emit_event(
  p_type      text,
  p_payload   jsonb default '{}'::jsonb,
  p_center_id uuid default null
)
  returns bigint
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := coalesce(p_center_id, public.current_center());
  v_id     bigint;
begin
  if v_center is null then
    raise exception 'emit_event: не определён center_id' using errcode = '22004';
  end if;

  insert into public.events (center_id, type, payload)
  values (v_center, p_type, coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;

  return v_id;
end;
$$;


-- 8. RLS на служебные таблицы -------------------------------------------------

alter table public.centers enable row level security;

drop policy if exists centers_select_members on public.centers;
create policy centers_select_members on public.centers
  for select to authenticated
  using (public.is_member(id) and deleted_at is null);

drop policy if exists centers_update_owner on public.centers;
create policy centers_update_owner on public.centers
  for update to authenticated
  using (public.role_in(id) = 'owner' and deleted_at is null)
  with check (public.role_in(id) = 'owner');

-- INSERT/DELETE напрямую запрещены: центр создаётся только через create_center().

alter table public.memberships enable row level security;

drop policy if exists memberships_select_self_or_admin on public.memberships;
create policy memberships_select_self_or_admin on public.memberships
  for select to authenticated
  using (user_id = auth.uid() or public.role_in(center_id) in ('owner', 'admin'));

drop policy if exists memberships_write_admin on public.memberships;
create policy memberships_write_admin on public.memberships
  for all to authenticated
  using (public.role_in(center_id) in ('owner', 'admin'))
  with check (public.role_in(center_id) in ('owner', 'admin'));

alter table public.audit_log enable row level security;

drop policy if exists audit_log_select_admin on public.audit_log;
create policy audit_log_select_admin on public.audit_log
  for select to authenticated
  using (center_id = public.current_center() and public.my_role() in ('owner', 'admin'));

alter table public.events enable row level security;

drop policy if exists events_select_admin on public.events;
create policy events_select_admin on public.events
  for select to authenticated
  using (center_id = public.current_center() and public.my_role() in ('owner', 'admin'));


-- 9. create_center ------------------------------------------------------------

-- Транслитерация кириллицы в slug: «Логопед Плюс» → logoped-plyus
create or replace function public.slugify(p_text text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select trim(both '-' from regexp_replace(
    translate(
      replace(replace(replace(replace(replace(replace(replace(replace(replace(
        lower(coalesce(p_text, '')),
        'ж', 'zh'), 'ц', 'c'), 'ч', 'ch'), 'ш', 'sh'), 'щ', 'sch'),
        'ъ', ''), 'ь', ''), 'ю', 'yu'), 'я', 'ya'),
      'абвгдеёзийклмнопрстуфхыэ',
      'abvgdeezijklmnoprstufhye'
    ),
    '[^a-z0-9]+', '-', 'g'
  ));
$$;

create or replace function public.create_center(p_name text, p_city text default null)
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

  v_base := nullif(public.slugify(p_name), '');
  if v_base is null then
    v_base := 'center';
  end if;

  v_slug := v_base;
  while exists (select 1 from public.centers c where c.slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base || '-' || v_suffix;
  end loop;

  insert into public.centers (name, slug, settings)
  values (
    trim(p_name),
    v_slug,
    jsonb_build_object('city', p_city, 'features', '{}'::jsonb)
  )
  returning id into v_id;

  insert into public.memberships (user_id, center_id, role)
  values (v_uid, v_id, 'owner');

  perform public.switch_center(v_id);

  perform public.emit_event(
    'center.created',
    jsonb_build_object('center_id', v_id, 'name', trim(p_name), 'city', p_city, 'slug', v_slug),
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


-- Права -----------------------------------------------------------------------

grant usage on schema public to authenticated;
grant select on public.centers, public.memberships, public.audit_log, public.events to authenticated;
grant update on public.centers to authenticated;
grant insert, update, delete on public.memberships to authenticated;

revoke all on function public.switch_center(uuid) from public;
revoke all on function public.create_center(text, text) from public;
revoke all on function public.emit_event(text, jsonb, uuid) from public;

grant execute on function public.current_center()        to authenticated;
grant execute on function public.my_role()               to authenticated;
grant execute on function public.my_teacher_id()         to authenticated;
grant execute on function public.my_payer_id()           to authenticated;
grant execute on function public.role_in(uuid)           to authenticated;
grant execute on function public.is_member(uuid)         to authenticated;
grant execute on function public.has_feature(text)       to authenticated;
grant execute on function public.switch_center(uuid)     to authenticated;
grant execute on function public.create_center(text, text) to authenticated;
grant execute on function public.emit_event(text, jsonb, uuid) to authenticated;
