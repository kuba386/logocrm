-- =============================================================================
-- 0095_invite_limits.sql — приглашение специалиста: карточка при принятии
--
-- Ревью процесса приглашения 6.10.2026 (решение владельца — исправлять). На
-- prod центр Studio упёрся в лимит 5 специалистов при двух работающих: места
-- заняли пустые карточки истёкших и отменённых ссылок — create_invitation
-- (0060) создавал карточку сразу при выдаче ссылки. Первая редакция (считать
-- место только по is_active) отвергнута ревью: is_active открыт на запись
-- (0017), выключенная карточка остаётся рабочей — лимит обходился.
--
-- Решения:
--   Р1. Карточку специалиста создаёт accept_invitation, а не create_invitation:
--       ФИО ждёт в invitations.full_name. Пустых карточек больше не бывает,
--       лимит считается как раньше — все живые карточки (0049), без лазеек.
--       Отказ лимита при принятии — текст для приглашённого, а не «освободите
--       место в архиве».
--   Р2. Живое приглашение без карточки бронирует место: «карточки + живые
--       приглашения без карточки» ≤ лимит, под тем же advisory lock. Проверка
--       после insert приглашения — при просрочке первым отвечает режим «только
--       чтение» (0050 Р8). Срок приглашения нельзя продлить (только сократить —
--       отмена): иначе бронь обходилась бы PATCH-ем expires_at.
--   Р3. Ссылку на существующую карточку можно выпустить, только если карточка
--       свободна и на неё нет другой живой ссылки.
--   Р4. Принятие: прежняя карточка участника (повторное приглашение
--       работающего больше не падает на teachers_profile_uniq), иначе карточка
--       приглашения — архивная отказывает, иначе живая карточка этого
--       аккаунта, иначе новая (лимит заранее, текст для приглашённого). Если
--       прежняя карточка участника в архиве — членство перепривязывается.
--       Чужую карточку (profile_id другого) привязать нельзя. Одна карточка — одно членство: частичный unique на
--       memberships (center_id, teacher_id).
--   Р5. Пустые карточки прошлых ссылок (не привязаны, выключены, без занятий,
--       членств и живых приглашений) уходят в архив — prod 6.10.2026: 1.
-- =============================================================================


-- 1. ФИО в приглашении (Р1) -----------------------------------------------------------------------

alter table public.invitations
  add column if not exists full_name text check (full_name is null or length(btrim(full_name)) between 1 and 200);
comment on column public.invitations.full_name is
  'ФИО специалиста для новой карточки (0095 Р1): карточку создаёт accept_invitation. null — карточка уже есть (teacher_id) или роль не специалист.';


-- 2. Срок приглашения только сокращается (Р2) -----------------------------------------------------

create or replace function public.invitations_expires_only_shorten()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.expires_at > old.expires_at then
    raise exception 'Срок приглашения продлить нельзя — отправьте новое приглашение' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function public.invitations_expires_only_shorten() from public, anon, authenticated, service_role;

drop trigger if exists invitations_expires_only_shorten on public.invitations;
create trigger invitations_expires_only_shorten
  before update of expires_at on public.invitations
  for each row execute function public.invitations_expires_only_shorten();


-- 3. Одна карточка — одно членство (Р4) -----------------------------------------------------------

create unique index if not exists memberships_center_teacher_key
  on public.memberships (center_id, teacher_id) where teacher_id is not null;


-- 4. Пустые карточки прошлых ссылок — в архив (Р5) ------------------------------------------------

update public.teachers t
   set deleted_at = now()
 where t.deleted_at is null and t.profile_id is null and not t.is_active
   and not exists (select 1 from public.lessons l where l.teacher_id = t.id or l.substitute_teacher_id = t.id)
   and not exists (select 1 from public.memberships m where m.teacher_id = t.id)
   and not exists (select 1 from public.groups g where g.teacher_id = t.id)
   and not exists (select 1 from public.students st where st.primary_teacher_id = t.id)
   and not exists (select 1 from public.invitations i where i.teacher_id = t.id and i.accepted_at is null and i.expires_at > now());


-- 5. Список ожидающих: ФИО из приглашения, если карточки ещё нет ----------------------------------

create or replace view public.pending_invitations_view
  with (security_invoker = true)
as
select
  i.id,
  i.center_id,
  i.role,
  i.teacher_id,
  coalesce(t.full_name, i.full_name) as full_name,
  i.phone,
  i.email,
  i.token,
  i.expires_at,
  i.created_at,
  i.payer_id,
  p.full_name as payer_name
from public.invitations i
left join public.teachers t on t.id = i.teacher_id
left join public.payers   p on p.id = i.payer_id and p.deleted_at is null
where i.accepted_at is null
  and i.expires_at > now();


-- 6. create_invitation — тело 0060 плюс Р1–Р3 -----------------------------------------------------

create or replace function public.create_invitation(
  p_role       text,
  p_full_name  text default null,
  p_phone      text default null,
  p_email      text default null,
  p_teacher_id uuid default null,
  p_payer_id   uuid default null
)
  returns table (invitation_id uuid, token text, teacher_id uuid, payer_id uuid, payer_created boolean)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_actor   text := coalesce(public.my_role(), '');
  v_teacher uuid := p_teacher_id;
  v_payer   uuid;
  v_created boolean := false;
  v_phone   text := p_phone;
  v_norm    text;
  v_expires timestamptz := now() + interval '7 days';
  v_id      uuid;
  v_token   text;
  v_limit   integer;
  v_used    integer;
  v_pending integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_actor not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_role not in ('admin', 'teacher', 'parent', 'registrar', 'finance') then
    raise exception 'Неизвестная роль %', p_role using errcode = '22023';
  end if;

  if v_actor = 'admin' and p_role = 'admin' then
    raise exception 'Администратор не может приглашать администраторов' using errcode = '42501';
  end if;

  if p_role = 'teacher' then
    if v_teacher is null then
      -- 0095 Р1: карточку создаёт принятие, а не выдача ссылки — ФИО ждёт в
      -- приглашении.
      if coalesce(trim(p_full_name), '') = '' then
        raise exception 'Укажите ФИО специалиста' using errcode = '22004';
      end if;
    else
      if not exists (
        select 1 from public.teachers t
         where t.id = v_teacher and t.center_id = v_center and t.deleted_at is null
      ) then
        raise exception 'Карточка специалиста не найдена в этом центре' using errcode = '42704';
      end if;
      -- 0095 Р3: фильтр «свободных» был только в интерфейсе.
      if exists (select 1 from public.teachers t where t.id = v_teacher and t.profile_id is not null) then
        raise exception 'Эта карточка уже привязана к сотруднику — выберите свободную или создайте новую' using errcode = '22023';
      end if;
      if exists (select 1 from public.invitations i
                  where i.teacher_id = v_teacher and i.accepted_at is null and i.expires_at > now()) then
        raise exception 'На эту карточку уже есть действующее приглашение — отправьте его или отмените' using errcode = '22023';
      end if;
    end if;
  elsif p_role = 'parent' then
    v_teacher := null;
    -- Р1: ссылка родителя открывает записи семьи — живёт 3 дня.
    v_expires := now() + interval '3 days';

    if p_payer_id is not null then
      -- Карточки, заведённые прямым insert, хранят номер как ввели —
      -- в приглашение кладём нормализованный (Р2), сырой только если
      -- нормализовать нечего.
      select p.id, coalesce(public.normalize_kg_phone(p.phone), p.phone) into v_payer, v_phone
        from public.payers p
       where p.id = p_payer_id and p.center_id = v_center and p.deleted_at is null;
      if not found then
        raise exception 'Карточка плательщика не найдена в этом центре' using errcode = '42704';
      end if;
    else
      -- Новая карточка: те же проверки и тот же нормализованный номер, что в
      -- create_student_with_payer (0026), — иначе один номер лежал бы в двух
      -- форматах и не находился.
      v_norm := public.normalize_kg_phone(p_phone);
      if v_norm is null then
        raise exception 'Некорректный номер телефона плательщика' using errcode = '22023';
      end if;
      if coalesce(trim(p_full_name), '') = '' then
        raise exception 'Укажите ФИО плательщика' using errcode = '22004';
      end if;
      if exists (
        select 1 from public.payers p
         where p.center_id = v_center and p.deleted_at is null
           and public.normalize_kg_phone(p.phone) = v_norm
      ) then
        raise exception 'Плательщик с этим телефоном уже есть — выберите его из списка' using errcode = '22023';
      end if;

      begin
        insert into public.payers (center_id, full_name, phone)
        values (v_center, trim(p_full_name), v_norm)
        returning id into v_payer;
      exception
        when unique_violation then
          -- Р4: параллельная вставка того же номера (второй админ, стойка).
          raise exception 'Плательщик с этим телефоном уже есть — выберите его из списка' using errcode = '22023';
      end;

      v_created := true;
      v_phone   := v_norm;
      perform public.emit_event('payer.created',
        jsonb_build_object('center_id', v_center, 'payer_id', v_payer,
                           'full_name', trim(p_full_name)), v_center);
    end if;
  else
    v_teacher := null;
  end if;

  insert into public.invitations (center_id, role, teacher_id, payer_id, phone, email, expires_at, full_name)
  values (v_center, p_role, v_teacher, v_payer, v_phone, p_email, v_expires,
          case when p_role = 'teacher' and v_teacher is null then trim(p_full_name) end)
  returning id, invitations.token into v_id, v_token;

  -- 0095 Р2: живое приглашение без карточки бронирует место. Проверка ПОСЛЕ
  -- insert: режим «только чтение» (0050, guard на invitations) отвечает
  -- первым (0050 Р8). Тот же advisory lock, что у триггера лимита.
  if p_role = 'teacher' and v_teacher is null then
    perform pg_advisory_xact_lock(hashtextextended('center_limit:' || v_center::text, 0));
    v_limit := public.plan_limit(v_center, 'teachers');
    if v_limit >= 0 then
      select count(*)::integer into v_used
        from public.teachers t
       where t.center_id = v_center and t.deleted_at is null;
      select count(*)::integer into v_pending
        from public.invitations i
       where i.center_id = v_center and i.role = 'teacher' and i.teacher_id is null
         and i.accepted_at is null and i.expires_at > now();
      if v_used + v_pending > v_limit then
        raise exception 'Лимит тарифа % — специалистов: % (карточек %, ждут приглашения %). Отмените лишнее приглашение или смените тариф в настройках центра',
          public.center_plan_name(v_center), v_limit, v_used, v_pending - 1
          using errcode = '23514';
      end if;
    end if;
  end if;

  perform public.emit_event(
    'invitation.created',
    jsonb_build_object('center_id', v_center, 'invitation_id', v_id,
                       'role', p_role, 'teacher_id', v_teacher, 'payer_id', v_payer),
    v_center
  );

  return query select v_id, v_token, v_teacher, v_payer, v_created;
end;
$$;

comment on function public.create_invitation(text, text, text, text, uuid, uuid) is
  'Приглашение по ссылке (0060; 0095 — карточку специалиста создаёт принятие, живое приглашение бронирует место, ссылка только на свободную карточку). Родитель — к живой или новой карточке плательщика, 3 дня. owner/admin.';

revoke execute on function public.create_invitation(text, text, text, text, uuid, uuid) from public, anon;
grant  execute on function public.create_invitation(text, text, text, text, uuid, uuid) to authenticated;


-- 7. accept_invitation — тело 0060 плюс Р1, Р4 ----------------------------------------------------

create or replace function public.accept_invitation(p_token text)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_inv      public.invitations;
  v_existing public.memberships;
  v_teacher  uuid;
  v_card     public.teachers;
  v_limit    integer;
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

  -- 0060: между выдачей ссылки и принятием карточку могли архивировать;
  -- FK и CHECK этого не видят, а membership на архивную карточку — родитель
  -- «с карточкой, без детей» без объяснения.
  if v_inv.payer_id is not null and not exists (
    select 1 from public.payers p
     where p.id = v_inv.payer_id and p.center_id = v_inv.center_id and p.deleted_at is null
  ) then
    raise exception 'Карточка плательщика архивирована — попросите администратора прислать новую ссылку' using errcode = '22023';
  end if;

  select m.* into v_existing
    from public.memberships m
   where m.user_id = v_uid and m.center_id = v_inv.center_id
   for update;

  if found and v_existing.role <> v_inv.role then
    raise exception 'Вы уже участник этого центра с ролью «%». Чтобы сменить роль, владелец отключает участника и отправляет приглашение заново', v_existing.role
      using errcode = '23505';
  end if;

  -- 0060: coalesce ниже молча оставил бы прежнюю карточку — новая ссылка «к
  -- правильному плательщику» отвечала бы успехом, а родитель продолжал бы
  -- видеть чужих детей. Явный отказ, как для роли выше.
  if found and v_existing.payer_id is not null and v_inv.payer_id is not null
     and v_existing.payer_id <> v_inv.payer_id then
    raise exception 'Вы уже привязаны к другой карточке плательщика — привязку меняет администратор в «Сотрудниках»'
      using errcode = '22023';
  end if;

  -- 0095 Р4: карточка специалиста — по порядку: прежняя живая карточка
  -- участника; карточка приглашения; живая карточка, уже привязанная к этому
  -- аккаунту (рассинхрон до 0095); новая. v_existing пуст (все поля null),
  -- если участника нет.
  if v_inv.role = 'teacher' then
    if v_existing.teacher_id is not null then
      select t.id into v_teacher from public.teachers t
       where t.id = v_existing.teacher_id and t.center_id = v_inv.center_id and t.deleted_at is null;
    end if;
    if v_teacher is null and v_inv.teacher_id is not null then
      select * into v_card from public.teachers t
       where t.id = v_inv.teacher_id and t.center_id = v_inv.center_id;
      if v_card.id is null or v_card.deleted_at is not null then
        raise exception 'Карточка специалиста из приглашения в архиве — попросите администратора прислать новую ссылку' using errcode = '22023';
      end if;
      v_teacher := v_card.id;
    end if;
    if v_teacher is null then
      select t.id into v_teacher from public.teachers t
       where t.center_id = v_inv.center_id and t.profile_id = v_uid and t.deleted_at is null
       limit 1;
    end if;

    if v_teacher is not null then
      select * into v_card from public.teachers t where t.id = v_teacher for update;
      if v_card.profile_id is not null and v_card.profile_id <> v_uid then
        raise exception 'Карточка специалиста уже привязана к другому сотруднику — попросите администратора прислать новую ссылку'
          using errcode = '22023';
      end if;
      update public.teachers
         set profile_id = v_uid, is_active = true
       where id = v_teacher;
    else
      -- Р1: новая карточка. Лимит — заранее, тем же счётом и замком, что
      -- триггер 0049, с текстом для приглашённого; триггер — страховка.
      perform pg_advisory_xact_lock(hashtextextended('center_limit:' || v_inv.center_id::text, 0));
      v_limit := public.plan_limit(v_inv.center_id, 'teachers');
      if v_limit >= 0 and (select count(*) from public.teachers t
                            where t.center_id = v_inv.center_id and t.deleted_at is null) + 1 > v_limit then
        raise exception 'В центре закончились места специалистов по тарифу — попросите администратора освободить место или сменить тариф'
          using errcode = '23514';
      end if;
      insert into public.teachers (center_id, full_name, phone, profile_id, is_active)
      values (v_inv.center_id, coalesce(nullif(v_inv.full_name, ''), 'Специалист'), v_inv.phone, v_uid, true)
      returning id into v_teacher;
    end if;
  end if;

  if v_existing.user_id is not null then
    -- Специалисту — актуальная карточка (прежняя могла уйти в архив).
    update public.memberships
       set teacher_id = case when v_inv.role = 'teacher' then v_teacher else coalesce(teacher_id, v_teacher) end,
           payer_id   = coalesce(payer_id, v_inv.payer_id)
     where user_id = v_uid and center_id = v_inv.center_id;
  else
    insert into public.memberships (user_id, center_id, role, teacher_id, payer_id)
    values (v_uid, v_inv.center_id, v_inv.role, v_teacher, v_inv.payer_id);
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
grant  execute on function public.accept_invitation(text) to authenticated;
