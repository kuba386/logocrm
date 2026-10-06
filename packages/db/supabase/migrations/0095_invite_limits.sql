-- =============================================================================
-- 0095_invite_limits.sql — приглашение специалиста: лимит, повтор, чужая карточка
--
-- Ревью процесса приглашения 6.10.2026 (решение владельца — исправлять). На
-- prod центр Studio упёрся в лимит 5 специалистов: 2 работают, 3 места заняли
-- пустые карточки истёкших и отменённых ссылок — create_invitation создаёт
-- карточку сразу при выдаче ссылки.
--
-- Решения:
--   Р1. Место в тарифе занимает только действующая карточка (is_active, не в
--       архиве). Пустая карточка непринятого приглашения (is_active = false)
--       не считается. Триггер лимита срабатывает при входе карточки в
--       «действующие»: insert действующей, включение is_active, восстановление
--       из архива — в том числе при принятии приглашения.
--   Р2. create_invitation для специалиста заранее проверяет «работают + ждут
--       приглашения + этот» ≤ лимит под тем же advisory lock, что и триггер:
--       живое неиспользованное приглашение бронирует место, истёкшее и
--       отменённое — нет. Повторная ссылка на уже действующую карточку места
--       не требует.
--   Р3. Ссылку можно выпустить только на свободную карточку (profile_id is
--       null) — фильтр был только в интерфейсе.
--   Р4. Повторное приглашение уже работающего специалиста: принимается его
--       собственная карточка (membership.teacher_id), а не новая —
--       раньше update новой карточки ронял принятие на teachers_profile_uniq
--       сырой ошибкой. Карточку, привязанную к другому сотруднику, принять
--       нельзя — понятный отказ.
--   Р5. center_limits: usage.teachers и галочка онбординга «специалист» —
--       по действующим карточкам, как лимит.
-- =============================================================================


-- 1. Лимит специалистов — по действующим карточкам (Р1) -------------------------------------------

create or replace function public.teachers_check_limit()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer;
begin
  -- Только вход в «действующие»: живая и is_active. Выход и правки внутри
  -- «действующих» места не меняют.
  if new.deleted_at is not null or not new.is_active then
    return null;
  end if;
  if tg_op = 'UPDATE' and old.deleted_at is null and old.is_active then
    return null;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('center_limit:' || new.center_id::text, 0));

  select count(*)::integer into v_count
    from public.teachers t
   where t.center_id = new.center_id and t.deleted_at is null and t.is_active;

  perform public.assert_center_limit(new.center_id, 'teachers', v_count, 'специалистов');
  return null;
end;
$$;
comment on function public.teachers_check_limit() is
  'Лимит специалистов тарифа (0049; 0095 — только действующие карточки): AFTER insert/update deleted_at, is_active, при входе карточки в действующие.';
revoke all on function public.teachers_check_limit() from public, anon, authenticated, service_role;

drop trigger if exists teachers_check_limit on public.teachers;
create trigger teachers_check_limit
  after insert or update of deleted_at, is_active on public.teachers
  for each row execute function public.teachers_check_limit();


-- 2. Сводка тарифа (Р5) — тело 0064, счётчик специалистов по действующим ----------------------

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
      -- 0095: место занимают только действующие карточки — пустая карточка
      -- непринятого приглашения не считается.
      'teachers', (select count(*) from public.teachers t where t.center_id = v_center and t.deleted_at is null and t.is_active),
      'students', (select count(*) from public.students s where s.center_id = v_center and s.deleted_at is null and s.status <> 'archived'),
      -- 0053 Р5: тот же счётчик, что у гейта; резерв работ в полёте не показывается.
      'ai_notes_month', public.center_ai_notes_used(v_center),
      -- 0064: тот же счётчик, что у гейта ассистента; резерв не показывается.
      'ai_questions_month', public.center_ai_questions_used(v_center)
    ),
    'onboarding', jsonb_build_object(
      'teacher',    exists (select 1 from public.teachers t where t.center_id = v_center and t.deleted_at is null and t.is_active),
      'service',    exists (select 1 from public.services s where s.center_id = v_center and s.deleted_at is null),
      'student',    exists (select 1 from public.students s where s.center_id = v_center and s.deleted_at is null),
      'lesson',     exists (select 1 from public.lessons l where l.center_id = v_center and l.deleted_at is null),
      'attendance', exists (select 1 from public.attendance a where a.center_id = v_center)
    )
  );
end;
$$;


comment on function public.center_limits() is
  'Тариф, лимиты, использование, дни до конца, writable/state (ok/expired/deleted/missing, 0056 Р7) в поясе центра, галочки онбординга — одним запросом для экрана тарифа и баннера (0049 Р9, 0050 Р11, 0053 Р5, 0064 — ai_questions_month, 0095 — специалисты по действующим карточкам). Родителю недоступно.';

revoke execute on function public.center_limits() from public, anon, service_role;
grant  execute on function public.center_limits() to authenticated;


-- 3. create_invitation — тело 0060 плюс Р2, Р3 ----------------------------------------------------

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
    -- 0095 Р2: место в тарифе бронирует и живое неиспользованное приглашение —
    -- иначе пять ссылок при лимите 5 выданы, а принять смогут не все.
    perform pg_advisory_xact_lock(hashtextextended('center_limit:' || v_center::text, 0));
    v_limit := public.plan_limit(v_center, 'teachers');
    if v_limit >= 0 and not exists (
      select 1 from public.teachers t
       where t.id = v_teacher and t.center_id = v_center and t.is_active and t.deleted_at is null
    ) then
      select count(*)::integer into v_used
        from public.teachers t
       where t.center_id = v_center and t.deleted_at is null and t.is_active;
      select count(*)::integer into v_pending
        from public.invitations i
        left join public.teachers t on t.id = i.teacher_id
       where i.center_id = v_center and i.role = 'teacher'
         and i.accepted_at is null and i.expires_at > now()
         and coalesce(t.is_active, false) = false;
      if v_used + v_pending + 1 > v_limit then
        raise exception 'Лимит тарифа % — специалистов: % (работают %, ждут приглашения %). Отмените лишнее приглашение или смените тариф в настройках центра',
          public.center_plan_name(v_center), v_limit, v_used, v_pending
          using errcode = '23514';
      end if;
    end if;

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
      -- 0095 Р3: фильтр «свободных» был только в интерфейсе.
      if exists (select 1 from public.teachers t where t.id = v_teacher and t.profile_id is not null) then
        raise exception 'Эта карточка уже привязана к сотруднику — выберите свободную или создайте новую' using errcode = '22023';
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

  insert into public.invitations (center_id, role, teacher_id, payer_id, phone, email, expires_at)
  values (v_center, p_role, v_teacher, v_payer, v_phone, p_email, v_expires)
  returning id, invitations.token into v_id, v_token;

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
  'Приглашение по ссылке (0060; 0095 — лимит специалистов с учётом живых приглашений, только свободная карточка). Родитель — к живой или новой карточке плательщика, ссылка 3 дня. owner/admin.';

revoke execute on function public.create_invitation(text, text, text, text, uuid, uuid) from public, anon;
grant  execute on function public.create_invitation(text, text, text, text, uuid, uuid) to authenticated;


-- 4. accept_invitation — тело 0060 плюс Р4 --------------------------------------------------------

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

  if found then
    update public.memberships
       set teacher_id = coalesce(teacher_id, v_inv.teacher_id),
           payer_id   = coalesce(payer_id, v_inv.payer_id)
     where user_id = v_uid and center_id = v_inv.center_id;
  else
    insert into public.memberships (user_id, center_id, role, teacher_id, payer_id)
    values (v_uid, v_inv.center_id, v_inv.role, v_inv.teacher_id, v_inv.payer_id);
  end if;

  -- 0095 Р4: участник уже привязан к своей карточке — привязываем ЕЁ, а не
  -- новую карточку приглашения (иначе teachers_profile_uniq ронял принятие
  -- сырой ошибкой). Новая карточка остаётся пустой и места не занимает.
  -- v_existing пуст (все поля null), если участника не было: select into без строки.
  v_teacher := coalesce(v_existing.teacher_id, v_inv.teacher_id);
  if v_teacher is not null then
    if exists (select 1 from public.teachers t
                where t.id = v_teacher and t.profile_id is not null and t.profile_id <> v_uid) then
      raise exception 'Карточка специалиста уже привязана к другому сотруднику — попросите администратора прислать новую ссылку'
        using errcode = '22023';
    end if;
    update public.teachers
       set profile_id = v_uid, is_active = true
     where id = v_teacher and center_id = v_inv.center_id;
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
