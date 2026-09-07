-- =============================================================================
-- 0004_staff.sql — сотрудники и приглашения
--
--   1. apply_tenant_rls получает параметр p_soft_delete
--   2. teachers      — карточка специалиста центра
--   3. invitations   — приглашение по ссылке
--   4. invitation_preview  — публичный предпросмотр (без авторизации)
--   5. accept_invitation   — приём приглашения
--   6. revoke_membership   — отключение доступа
--   7. change_member_role  — смена роли
--   8. create_invitation   — атомарное создание карточки + приглашения
--   9. staff_view / pending_invitations_view
--
-- Нумерация: 0002 и 0003 заняты миграциями безопасности (см. ADR-002).
-- =============================================================================


-- 1. apply_tenant_rls с параметром p_soft_delete ------------------------------

-- Старую одноаргументную версию удаляем: иначе call apply_tenant_rls('t')
-- становится неоднозначным (procedure name is not unique).
drop procedure if exists public.apply_tenant_rls(text);

create or replace procedure public.apply_tenant_rls(
  tbl           text,
  p_soft_delete boolean default true
)
  language plpgsql
  set search_path = ''
as $$
declare
  v_tenant text := 'center_id = public.current_center() and public.my_role() in (''owner'', ''admin'')';
  v_using  text;
begin
  execute format('alter table public.%I enable row level security', tbl);
  execute format('drop policy if exists tenant_admin on public.%I', tbl);

  -- deleted_at is null только в USING: в WITH CHECK он запретил бы сам
  -- soft delete (update ... set deleted_at = now()).
  v_using := case when p_soft_delete then v_tenant || ' and deleted_at is null' else v_tenant end;

  execute format(
    'create policy tenant_admin on public.%I for all to authenticated using (%s) with check (%s)',
    tbl, v_using, v_tenant
  );
end;
$$;

comment on procedure public.apply_tenant_rls(text, boolean) is
  'call apply_tenant_rls(''students'') — RLS для owner/admin. Второй аргумент false для таблиц без deleted_at.';

revoke execute on procedure public.apply_tenant_rls(text, boolean) from public, anon, authenticated;


-- 2. teachers -----------------------------------------------------------------

create table if not exists public.teachers (
  id                uuid primary key default gen_random_uuid(),
  center_id         uuid not null default public.current_center()
                      references public.centers (id) on delete cascade,
  full_name         text not null,
  phone             text,
  specialization    text,
  -- Заполняется в accept_invitation, когда специалист принял приглашение.
  profile_id        uuid references auth.users (id) on delete set null,
  is_active         boolean not null default true,
  hourly_rate_tiyin integer check (hourly_rate_tiyin is null or hourly_rate_tiyin >= 0),
  custom_fields     jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid default auth.uid(),
  deleted_at        timestamptz
);

comment on table public.teachers is 'Специалист центра. Карточка живёт отдельно от аккаунта: её заводят до приглашения.';
comment on column public.teachers.hourly_rate_tiyin is 'Ставка в тыйынах (1 сом = 100 тыйынов).';

create index if not exists teachers_center_idx
  on public.teachers (center_id) where deleted_at is null;

-- Один аккаунт — максимум одна карточка специалиста в центре.
create unique index if not exists teachers_profile_uniq
  on public.teachers (center_id, profile_id)
  where profile_id is not null and deleted_at is null;

drop trigger if exists teachers_set_updated_at on public.teachers;
create trigger teachers_set_updated_at
  before update on public.teachers
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('teachers');
call public.apply_audit('teachers');

-- Специалист видит только собственную карточку.
drop policy if exists teachers_read_self on public.teachers;
create policy teachers_read_self on public.teachers
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'teacher'
    and id = public.my_teacher_id()
    and deleted_at is null
  );


-- 3. invitations --------------------------------------------------------------

create table if not exists public.invitations (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null default public.current_center()
                references public.centers (id) on delete cascade,
  role        text not null check (role in ('admin', 'teacher', 'parent')),
  teacher_id  uuid references public.teachers (id) on delete cascade,
  payer_id    uuid,
  phone       text,
  email       text,
  token       text not null unique default encode(extensions.gen_random_bytes(24), 'hex'),
  expires_at  timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  accepted_by uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid()
);

comment on table public.invitations is 'Приглашение по ссылке. Токен — 48 hex-символов, единственный секрет.';

create index if not exists invitations_pending_idx
  on public.invitations (center_id, expires_at)
  where accepted_at is null;

-- deleted_at у таблицы нет — приглашения не удаляются мягко, они истекают.
call public.apply_tenant_rls('invitations', false);
call public.apply_audit('invitations');


-- 4. invitation_preview — публичная, без авторизации --------------------------

-- Отдаёт ровно три поля. Неизвестный токен не отличим от чужого: возвращаются
-- NULL-ы, чтобы нельзя было перебором узнать названия центров.
create or replace function public.invitation_preview(p_token text)
  returns table (center_name text, role text, valid boolean)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_name text;
  v_role text;
  v_ok   boolean;
begin
  select c.name, i.role, (i.accepted_at is null and i.expires_at > now())
    into v_name, v_role, v_ok
    from public.invitations i
    join public.centers c on c.id = i.center_id
   where i.token = p_token;

  if not found then
    return query select null::text, null::text, false;
  else
    return query select v_name, v_role, v_ok;
  end if;
end;
$$;

revoke execute on function public.invitation_preview(text) from public;
grant execute on function public.invitation_preview(text) to anon, authenticated;


-- 5. accept_invitation --------------------------------------------------------

create or replace function public.accept_invitation(p_token text)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_inv public.invitations;
begin
  if v_uid is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  select * into v_inv from public.invitations where token = p_token for update;

  if not found then
    raise exception 'Приглашение не найдено' using errcode = '42704';
  end if;

  if v_inv.accepted_at is not null then
    raise exception 'Приглашение уже использовано' using errcode = '22023';
  end if;

  if v_inv.expires_at <= now() then
    raise exception 'Срок действия приглашения истёк' using errcode = '22023';
  end if;

  insert into public.memberships (user_id, center_id, role, teacher_id, payer_id)
  values (v_uid, v_inv.center_id, v_inv.role, v_inv.teacher_id, v_inv.payer_id)
  on conflict (user_id, center_id) do update
    set role       = excluded.role,
        teacher_id = excluded.teacher_id,
        payer_id   = excluded.payer_id;

  if v_inv.teacher_id is not null then
    update public.teachers
       set profile_id = v_uid, is_active = true
     where id = v_inv.teacher_id and center_id = v_inv.center_id;
  end if;

  update public.invitations
     set accepted_at = now(), accepted_by = v_uid
   where id = v_inv.id;

  perform public.emit_event(
    'membership.created',
    jsonb_build_object('center_id', v_inv.center_id, 'user_id', v_uid, 'role', v_inv.role),
    v_inv.center_id
  );

  perform public.switch_center(v_inv.center_id);

  return v_inv.center_id;
end;
$$;

revoke execute on function public.accept_invitation(text) from public, anon;
grant execute on function public.accept_invitation(text) to authenticated;


-- 6. revoke_membership --------------------------------------------------------

create or replace function public.revoke_membership(p_user_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_actor  text := public.my_role();
  v_target public.memberships;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_actor not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_target
    from public.memberships
   where user_id = p_user_id and center_id = v_center;

  if not found then
    raise exception 'Участник не найден в этом центре' using errcode = '42704';
  end if;

  if v_target.role = 'owner' then
    if v_actor <> 'owner' then
      raise exception 'Только владелец может отключить другого владельца' using errcode = '42501';
    end if;

    if (select count(*) from public.memberships
         where center_id = v_center and role = 'owner') <= 1 then
      raise exception 'Нельзя отключить последнего владельца центра' using errcode = '23514';
    end if;
  end if;

  delete from public.memberships where user_id = p_user_id and center_id = v_center;

  if v_target.teacher_id is not null then
    update public.teachers
       set is_active = false, profile_id = null
     where id = v_target.teacher_id and center_id = v_center;
  end if;

  perform public.emit_event(
    'membership.revoked',
    jsonb_build_object('center_id', v_center, 'user_id', p_user_id, 'role', v_target.role),
    v_center
  );
end;
$$;

revoke execute on function public.revoke_membership(uuid) from public, anon;
grant execute on function public.revoke_membership(uuid) to authenticated;


-- 7. change_member_role -------------------------------------------------------

create or replace function public.change_member_role(p_user_id uuid, p_role text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_actor  text := public.my_role();
  v_target public.memberships;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_actor not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_role not in ('owner', 'admin', 'teacher', 'parent') then
    raise exception 'Неизвестная роль %', p_role using errcode = '22023';
  end if;

  -- Администратор не может ни назначить owner/admin, ни трогать их самих:
  -- иначе он повышает себя до владельца через подставного пользователя.
  if v_actor = 'admin' and p_role <> 'teacher' then
    raise exception 'Администратор может назначать только роль специалиста' using errcode = '42501';
  end if;

  select * into v_target
    from public.memberships
   where user_id = p_user_id and center_id = v_center;

  if not found then
    raise exception 'Участник не найден в этом центре' using errcode = '42704';
  end if;

  if v_actor = 'admin' and v_target.role in ('owner', 'admin') then
    raise exception 'Администратор не может менять роль владельца или администратора' using errcode = '42501';
  end if;

  if v_target.role = 'owner' and p_role <> 'owner'
     and (select count(*) from public.memberships
           where center_id = v_center and role = 'owner') <= 1 then
    raise exception 'Нельзя понизить последнего владельца центра' using errcode = '23514';
  end if;

  update public.memberships
     set role = p_role,
         teacher_id = case when p_role = 'teacher' then teacher_id else null end
   where user_id = p_user_id and center_id = v_center;

  perform public.emit_event(
    'membership.role_changed',
    jsonb_build_object('center_id', v_center, 'user_id', p_user_id,
                       'role', p_role, 'previous_role', v_target.role),
    v_center
  );
end;
$$;

revoke execute on function public.change_member_role(uuid, text) from public, anon;
grant execute on function public.change_member_role(uuid, text) to authenticated;


-- 8. create_invitation --------------------------------------------------------

-- Карточка специалиста и приглашение создаются одной транзакцией: иначе при
-- падении второго шага в центре остаётся карточка-сирота без приглашения.
create or replace function public.create_invitation(
  p_role       text,
  p_full_name  text default null,
  p_phone      text default null,
  p_email      text default null,
  p_teacher_id uuid default null
)
  returns table (invitation_id uuid, token text, teacher_id uuid)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_actor   text := public.my_role();
  v_teacher uuid := p_teacher_id;
  v_id      uuid;
  v_token   text;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_actor not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_role not in ('admin', 'teacher', 'parent') then
    raise exception 'Неизвестная роль %', p_role using errcode = '22023';
  end if;

  if v_actor = 'admin' and p_role = 'admin' then
    raise exception 'Администратор не может приглашать администраторов' using errcode = '42501';
  end if;

  if p_role = 'teacher' then
    if v_teacher is null then
      if coalesce(trim(p_full_name), '') = '' then
        raise exception 'Укажите ФИО специалиста' using errcode = '22004';
      end if;

      insert into public.teachers (center_id, full_name, phone, is_active)
      values (v_center, trim(p_full_name), p_phone, false)
      returning id into v_teacher;
    else
      if not exists (
        select 1 from public.teachers t
         where t.id = v_teacher and t.center_id = v_center and t.deleted_at is null
      ) then
        raise exception 'Карточка специалиста не найдена в этом центре' using errcode = '42704';
      end if;
    end if;
  else
    v_teacher := null;
  end if;

  insert into public.invitations (center_id, role, teacher_id, phone, email)
  values (v_center, p_role, v_teacher, p_phone, p_email)
  returning id, invitations.token into v_id, v_token;

  perform public.emit_event(
    'invitation.created',
    jsonb_build_object('center_id', v_center, 'invitation_id', v_id,
                       'role', p_role, 'teacher_id', v_teacher),
    v_center
  );

  return query select v_id, v_token, v_teacher;
end;
$$;

revoke execute on function public.create_invitation(text, text, text, text, uuid) from public, anon;
grant execute on function public.create_invitation(text, text, text, text, uuid) to authenticated;


-- 9. Витрины ------------------------------------------------------------------

-- auth.users не выдаётся роли authenticated целиком (там хеши паролей всех
-- пользователей сервиса). Email отдаёт отдельная функция со своей проверкой:
-- владелец/админ видит почту участников своего центра, любой — свою.
create or replace function public.user_email(p_user_id uuid)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_email text;
begin
  if auth.uid() is null then
    return null;
  end if;

  if p_user_id <> auth.uid() then
    if public.my_role() not in ('owner', 'admin') then
      return null;
    end if;

    if not exists (
      select 1 from public.memberships m
       where m.user_id = p_user_id and m.center_id = public.current_center()
    ) then
      return null;
    end if;
  end if;

  select u.email into v_email from auth.users u where u.id = p_user_id;
  return v_email;
end;
$$;

revoke execute on function public.user_email(uuid) from public, anon;
grant execute on function public.user_email(uuid) to authenticated;

-- security_invoker: RLS нижележащих таблиц применяется к вызывающему,
-- а не к владельцу вью. Без этого вью стала бы дырой в изоляции тенантов.
drop view if exists public.staff_view;
create view public.staff_view
  with (security_invoker = true)
as
select
  m.user_id,
  m.center_id,
  public.user_email(m.user_id)      as email,
  m.role,
  m.teacher_id,
  t.full_name,
  coalesce(t.is_active, true)       as is_active,
  m.created_at                      as joined_at
from public.memberships m
left join public.teachers t
       on t.id = m.teacher_id and t.deleted_at is null
where m.center_id = public.current_center();

comment on view public.staff_view is 'Участники текущего центра. Специалист видит только собственную строку — так работает RLS на memberships.';

drop view if exists public.pending_invitations_view;
create view public.pending_invitations_view
  with (security_invoker = true)
as
select
  i.id,
  i.center_id,
  i.role,
  i.teacher_id,
  t.full_name,
  i.phone,
  i.email,
  i.token,
  i.expires_at,
  i.created_at
from public.invitations i
left join public.teachers t on t.id = i.teacher_id
where i.accepted_at is null
  and i.expires_at > now();

comment on view public.pending_invitations_view is 'Неиспользованные и непросроченные приглашения. Виден только владельцу/админу — политика tenant_admin на invitations.';


-- Права -----------------------------------------------------------------------

grant select, insert, update on public.teachers    to authenticated;
grant select, insert, update on public.invitations to authenticated;
grant select on public.staff_view                  to authenticated;
grant select on public.pending_invitations_view    to authenticated;
