-- =============================================================================
-- 0024_access_hygiene.sql — гигиена доступа перед ролями registrar/finance
-- (этап 5, «Доработка» п.1; architect-ревью плана ролей, находки 1, 2, 11)
--
-- Три долга, каждый держался на одной RLS:
--
--   1. DELETE у authenticated. Таблицы 0001/0004/0005/0006 создавались до
--      правила «revoke all, потом точечный grant» (впервые — 0008): Supabase
--      выдаёт authenticated полный набор прав на новую таблицу по умолчанию.
--      Сегодня DELETE /rest/v1/students?id=eq.<uuid> сдерживает только
--      tenant_admin — а она for all, то есть владельцу открыта: ребёнок
--      уходит с каскадом по занятиям, составу и посещениям без deleted_at.
--      «Ничего не удаляется» держалось на том, что кнопки нет.
--   2. anon с SELECT по грантам на 17 объектах, включая memberships. Не
--      утечка — все политики to authenticated, вью security_invoker — а
--      отсутствующий второй слой: одна будущая политика to public, и грант
--      уже есть.
--   3. Последний владелец. change_member_role и revoke_membership считают
--      владельцев в plpgsql, а accept_invitation делает on conflict do update
--      set role мимо обеих: единственный владелец, кликнувший приглашение с
--      ролью parent, оставляет центр без владельца — reopen_month,
--      centers_update_owner и обратное повышение недоступны никому. Инвариант
--      переезжает в триггер (CLAUDE.md: инвариант — констрейнт или триггер),
--      а приглашение существующему участнику — отказ, не перезапись роли.
--
-- Плюс Advisors WARN auth_rls_initplan на memberships_select_self_or_admin.
-- Остальные политики зовут role_in(center_id) по колонке строки — обернуть в
-- (select …) нельзя и не нужно.
-- =============================================================================


-- 1. Гранты: снять default privileges, вернуть ровно то, что выдавали 0001–0006

revoke all on table
  public.students, public.payers, public.rooms, public.services, public.groups,
  public.group_students, public.lessons, public.invitations,
  public.lesson_participants, public.audit_log, public.events, public.centers,
  public.memberships
  from public, anon, authenticated;

-- Как в 0004/0005/0006 — без DELETE. Удаление есть ровно в одном месте:
-- revoke_membership (definer).
grant select, insert, update on
  public.students, public.payers, public.rooms, public.services, public.groups,
  public.group_students, public.lessons, public.invitations
  to authenticated;

-- Только чтение: строки кладут definer-триггеры и emit_event.
grant select on public.lesson_participants, public.audit_log, public.events to authenticated;

-- memberships: insert/update/delete сняты в 0022, здесь — anon.
grant select on public.memberships to authenticated;

-- centers: создаётся только через create_center; настройки правит владелец
-- (centers_update_owner).
grant select, update on public.centers to authenticated;

-- Вью 0004/0005 — до 0021 без revoke; сами security_invoker, но второй слой
-- обязан быть.
revoke all on table
  public.staff_view, public.pending_invitations_view,
  public.students_teacher_view, public.payers_with_stats
  from public, anon, authenticated;

grant select on
  public.staff_view, public.pending_invitations_view,
  public.students_teacher_view, public.payers_with_stats
  to authenticated;


-- 2. memberships_select_self_or_admin — auth.uid() как InitPlan ------------------

drop policy if exists memberships_select_self_or_admin on public.memberships;
create policy memberships_select_self_or_admin on public.memberships
  for select to authenticated
  using (user_id = (select auth.uid()) or public.role_in(center_id) in ('owner', 'admin'));


-- 3. Последний владелец — триггер ------------------------------------------------

create or replace function public.memberships_last_owner_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if old.role = 'owner'
     and (tg_op = 'DELETE' or new.role <> 'owner' or new.center_id <> old.center_id)
     and not exists (
       select 1 from public.memberships m
        where m.center_id = old.center_id and m.role = 'owner' and m.user_id <> old.user_id
     ) then
    raise exception 'Нельзя понизить последнего владельца центра' using errcode = '23514';
  end if;
  return coalesce(new, old);
end;
$$;

comment on function public.memberships_last_owner_guard() is
  'В центре всегда есть хотя бы один owner. Проверки в change_member_role и revoke_membership остаются как ранний отказ с понятным текстом; этот триггер — инвариант на любом пути, включая accept_invitation.';

drop trigger if exists memberships_last_owner_guard on public.memberships;
create trigger memberships_last_owner_guard
  before delete or update of role, center_id on public.memberships
  for each row execute function public.memberships_last_owner_guard();

revoke execute on function public.memberships_last_owner_guard() from public, anon, authenticated;


-- 4. accept_invitation — существующему участнику отказ, не перезапись роли -------

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

  -- Было: on conflict (user_id, center_id) do update set role = excluded.role.
  -- Приглашение — не способ сменить роль по ссылке: роль меняет владелец.
  if exists (
    select 1 from public.memberships m
     where m.user_id = v_uid and m.center_id = v_inv.center_id
  ) then
    raise exception 'Вы уже участник этого центра — роль меняет владелец' using errcode = '23505';
  end if;

  insert into public.memberships (user_id, center_id, role, teacher_id, payer_id)
  values (v_uid, v_inv.center_id, v_inv.role, v_inv.teacher_id, v_inv.payer_id);

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

revoke execute on function public.accept_invitation(text) from public, anon, authenticated;
grant execute on function public.accept_invitation(text) to authenticated;
