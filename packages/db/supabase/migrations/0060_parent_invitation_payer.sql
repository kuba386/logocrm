-- 0060: приглашение родителя — только с карточкой плательщика.
--
-- Backlog.md, находка владельца 18.09.2026 (приёмка этапа 6): пригласили
-- родителя, он вошёл и увидел «Детей пока не привязано». Причина глубже,
-- чем «телефон не заполнили»: create_invitation (0004 → 0028) вообще не
-- заполняет invitations.payer_id — ни по телефону, ни иначе. Каждый
-- приглашённый родитель приходил в центр «ничьим», а чинилось это
-- запросом в базу.
--
-- Что меняется:
--   1. invitations: CHECK «родитель — только с payer_id» (NOT VALID — история
--      уже нарушает, а править её нельзя; для новых строк и update
--      констрейнт работает в полную силу). Прямого insert у authenticated нет
--      с 0024 — констрейнт держит service_role, миграции и любой будущий
--      грант, а не «PostgREST пускает».
--   2. Висящие parent-приглашения без плательщика протухают: принять их —
--      значит завести ещё одного «ничьего» родителя. Владелец перевыпускает
--      ссылку уже с карточкой.
--   3. create_invitation(+ p_payer_id): для родителя — либо существующая
--      живая карточка, либо ФИО + телефон → новая карточка (нормализованный
--      номер, событие payer.created — как в create_student_with_payer).
--      Телефон, который уже есть у живой карточки, — отказ «выберите из
--      списка», а не молчаливая привязка: стандарт — явный выбор (0057,
--      booking_request_payer_match); create_student_with_payer со старым
--      поведением «привязаться молча» остаётся до отдельной миграции.
--      Возвращает payer_id и payer_created — форма показывает то, что
--      сделала база, а не то, что было в селекте.
--   4. accept_invitation: карточка, архивированная после выдачи ссылки, —
--      отказ, не membership с payer_id на архивную строку (FK и CHECK
--      deleted_at не видят).
--   5. change_member_role: перевод В роль parent закрыт — это второй путь к
--      «ничьему» родителю (payer_id некому заполнить). Родителя заводит
--      приглашение или «Привязать плательщика». Перевод ИЗ parent зануляет
--      payer_id — симметрично teacher_id.
--   6. link_parent_payer(user, payer|null): починка существующих «ничьих»
--      родителей и исправление ошибочной привязки; owner и admin наравне —
--      запрет второго шага admin'у ничего не защищал бы (revoke + новое
--      приглашение дают тот же результат), а контроль здесь — событие
--      membership.payer_linked с previous_payer_id и аудит memberships.
--      null — отвязать: путь «родитель видит чужого ребёнка» должен
--      закрываться одним действием.
--   7. staff_view / pending_invitations_view: + payer_id, payer_name.
--      full_name остаётся «ФИО специалиста» — семантику существующей
--      колонки не подменяем.
--
-- Решения (записаны, чтобы не всплыли в проде):
--   Р1. Срок parent-приглашения — 3 дня, не 7: с этой миграции ссылка
--       открывает клинические записи конкретной семьи. Сверки email/телефона
--       принявшего нет — у родителей на момент приглашения email часто нет;
--       короче срок + текст «ссылка личная» в форме. Срок держит CHECK
--       invitations_parent_ttl_check, не if в функции: прямой PATCH expires_at
--       (грант 0024) иначе продлил бы ссылку.
--   Р7. accept_invitation для участника, уже привязанного к ДРУГОЙ карточке,
--       — отказ 22023, не coalesce: новая ссылка «к правильному плательщику»
--       иначе отвечала бы успехом, ничего не меняя.
--   Р2. Телефон в invitations.phone у родителя — нормализованный телефон
--       карточки плательщика (и при выборе существующей, и при создании):
--       контакт в «Ожидающих приглашениях» и в карточке — один.
--   Р3. Отказ «телефон уже есть» — 22023, не 23505: 23505 в общем разборе
--       ошибок (lib/errors.ts) зарезервирован под нативные уникальные
--       индексы и разбирается по имени констрейнта; собственный raise с этим
--       кодом читался бы как «такая запись уже есть» и терял бы подсказку
--       «выберите из списка».
--   Р4. Гонка «предпроверка → insert» ловится exception unique_violation
--       с тем же текстом — иначе наружу уйдёт голый текст индекса.
--   Р5. В замороженном центре (0050) insert в payers под readonly-guard:
--       приглашение родителя с новой карточкой упадёт текстом про «только
--       чтение» — ожидаемо, приглашения там не выдаются.
--   Р6. Архивация плательщика с уже привязанным родителем — не здесь:
--       memberships.payer_id остаётся, payers_read_self его не отдаёт;
--       дашборд родителя покажет «карточка недоступна». Отдельный пункт.
--
-- Ревью плана (architect, 24.09.2026): 15 находок, все учтены выше.

-- 1. Висящие приглашения без карточки — протухают -------------------------------------------

-- ДО констрейнта: NOT VALID отключает только сканирование истории, а любой
-- update исторической строки проверяется в полную силу — этот update и есть
-- такие строки (ревью написанного SQL, Б1: в CI база пустая и не заметила бы).
update public.invitations
   set expires_at = now()
 where role = 'parent'
   and payer_id is null
   and accepted_at is null
   and expires_at > now();

-- 2. Инварианты --------------------------------------------------------------------------

alter table public.invitations
  drop constraint if exists invitations_parent_payer_check;
alter table public.invitations
  add constraint invitations_parent_payer_check
  check (role <> 'parent' or payer_id is not null) not valid;

comment on constraint invitations_parent_payer_check on public.invitations is
  'Родитель приглашается только к карточке плательщика (0060). NOT VALID: исторические строки без payer_id остаются, новые не проходят.';

-- Р1 держится не на if в функции: у owner/admin есть update (expires_at) на
-- invitations (0024), прямой PATCH продлил бы ссылку на семью на год.
alter table public.invitations
  drop constraint if exists invitations_parent_ttl_check;
alter table public.invitations
  add constraint invitations_parent_ttl_check
  check (role <> 'parent' or expires_at <= created_at + interval '3 days') not valid;

comment on constraint invitations_parent_ttl_check on public.invitations is
  'Ссылка родителя живёт не дольше 3 дней от выдачи (0060, Р1) — отмена (expires_at = now()) проходит, продление нет.';


-- 3. create_invitation — плательщик для родителя ---------------------------------------------

-- Замена сигнатуры, не перегрузка (0030 Р9): старая осталась бы исполняемым
-- RPC с грантом, который выдаёт «ничьих» родителей.
drop function if exists public.create_invitation(text, text, text, text, uuid);

create function public.create_invitation(
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
  'Приглашение по ссылке (0060): родитель — только к живой карточке плательщика (p_payer_id) или к новой (ФИО + телефон, дубль номера — отказ «выберите из списка»). Ссылка родителя живёт 3 дня. owner/admin.';

revoke execute on function public.create_invitation(text, text, text, text, uuid, uuid) from public, anon;
grant  execute on function public.create_invitation(text, text, text, text, uuid, uuid) to authenticated;


-- 4. accept_invitation — карточка должна быть живой в момент принятия (тело из 0024) ----------

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
grant  execute on function public.accept_invitation(text) to authenticated;


-- 5. change_member_role — в parent не переводим, из parent — без payer_id (тело из 0028) ------

create or replace function public.change_member_role(p_user_id uuid, p_role text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_actor  text := coalesce(public.my_role(), '');
  v_target public.memberships;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_actor not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_role not in ('owner', 'admin', 'teacher', 'parent', 'registrar', 'finance') then
    raise exception 'Неизвестная роль %', p_role using errcode = '22023';
  end if;

  if v_actor = 'admin' and p_role not in ('teacher', 'registrar', 'finance') then
    raise exception 'Администратор может назначать только роли специалиста, регистратора и бухгалтера' using errcode = '42501';
  end if;

  -- 0060: перевод в parent оставил бы payer_id пустым — второй путь к
  -- «ничьему» родителю. Родителя заводит приглашение с карточкой.
  if p_role = 'parent' then
    raise exception 'Роль «Родитель» назначается приглашением с карточкой плательщика — отправьте ссылку заново' using errcode = '22023';
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
         teacher_id = case when p_role = 'teacher' then teacher_id else null end,
         payer_id   = null
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
grant  execute on function public.change_member_role(uuid, text) to authenticated;


-- 6. link_parent_payer — привязать / перепривязать / отвязать --------------------------------

-- default null: отвязка не должна зависеть от того, как клиент сериализует
-- пустое значение (PostgREST без ключа ищет одноаргументную сигнатуру).
create or replace function public.link_parent_payer(p_user_id uuid, p_payer_id uuid default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_actor  text := coalesce(public.my_role(), '');
  v_target public.memberships;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_actor not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Один код для «нет такого», «чужой центр» и «это не родитель» — наличие
  -- участника в чужом центре не раскрывается.
  select * into v_target
    from public.memberships
   where user_id = p_user_id and center_id = v_center and role = 'parent'
   for update;
  if not found then
    raise exception 'Родитель не найден в этом центре' using errcode = '42704';
  end if;

  if p_payer_id is not null and not exists (
    select 1 from public.payers p
     where p.id = p_payer_id and p.center_id = v_center and p.deleted_at is null
  ) then
    raise exception 'Карточка плательщика не найдена в этом центре' using errcode = '42704';
  end if;

  if v_target.payer_id is not distinct from p_payer_id then
    return;
  end if;

  update public.memberships
     set payer_id = p_payer_id
   where user_id = p_user_id and center_id = v_center;

  perform public.emit_event(
    'membership.payer_linked',
    jsonb_build_object('center_id', v_center, 'user_id', p_user_id,
                       'payer_id', p_payer_id, 'previous_payer_id', v_target.payer_id),
    v_center
  );
end;
$$;

comment on function public.link_parent_payer(uuid, uuid) is
  'Привязка родителя к карточке плательщика (0060): null — отвязать. owner/admin наравне; контроль — событие membership.payer_linked с previous_payer_id и аудит memberships.';

revoke execute on function public.link_parent_payer(uuid, uuid) from public, anon;
grant  execute on function public.link_parent_payer(uuid, uuid) to authenticated;


-- 7. Витрины: плательщик рядом с участником и приглашением ----------------------------------

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
  m.created_at                      as joined_at,
  m.payer_id,
  p.full_name                       as payer_name
from public.memberships m
left join public.teachers t
       on t.id = m.teacher_id and t.deleted_at is null
left join public.payers p
       on p.id = m.payer_id and p.deleted_at is null
where m.center_id = public.current_center();

comment on view public.staff_view is
  'Участники текущего центра. Специалист видит только собственную строку — так работает RLS на memberships. payer_name — карточка родителя (0060); у finance всегда null — политика на payers снята в 0031.';

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
  i.created_at,
  i.payer_id,
  p.full_name as payer_name
from public.invitations i
left join public.teachers t on t.id = i.teacher_id
left join public.payers   p on p.id = i.payer_id and p.deleted_at is null
where i.accepted_at is null
  and i.expires_at > now();

comment on view public.pending_invitations_view is
  'Неиспользованные и непросроченные приглашения. Виден только владельцу/админу — политика tenant_admin на invitations. payer_name — карточка приглашённого родителя (0060).';

-- drop/create теряет revoke из 0024 — второй слой обязателен: на витрине лежит
-- invitations.token.
revoke all on table public.staff_view, public.pending_invitations_view
  from public, anon, authenticated;
grant select on public.staff_view, public.pending_invitations_view to authenticated;
