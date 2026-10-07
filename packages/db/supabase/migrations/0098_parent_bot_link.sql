-- =============================================================================
-- 0098_parent_bot_link.sql — этап 12: родитель подключается к Telegram-боту
-- по ссылке с карточки плательщика, без почты и пароля
--
-- Причина: на prod 7.10.2026 ноль родительских членств при 26 плательщиках —
-- все уведомления родителям (этапы 6 и 11) без адресата. Вход родителя был
-- только приглашением на почту и регистрацией в вебе.
--
-- Решения владельца (7.10.2026, не пересматриваются здесь):
--   В1. Личная ссылка на бота с карточки плательщика (и QR), администратор
--       отправляет её в WhatsApp; родитель жмёт Start — подключён.
--   В2. Выдают ссылку только владелец и администратор (тот же круг, что
--       приглашает родителя, 0060/0095).
--   В3. Телефон не сверяется; на карточке видно, кто подключился (имя в
--       Telegram, когда) и есть «Отключить». Ссылка одноразовая, 3 дня.
--
-- Схема (вариант А, принят архитектором): ссылка создаёт «бот-аккаунт» —
-- строку auth.users без почты, пароля и identities + memberships(parent,
-- payer) + telegram_accounts. Весь существующий контур работает без правок:
-- notification_targets, notification_begin (n8n не трогается), bot_balance,
-- confirm_lesson, bot_today. Вариант Б (чат плательщика без пользователя)
-- потребовал бы второго типа получателя и ручной правки n8n.
--
-- Ревью плана — architect, 6 блокеров и 9 находок, учтены:
--   Б1. Выдача — owner/admin (В2), не can_payments: бухгалтер и регистратор
--       открыли бы ссылку сами и читали заметки занятий в обход ADR-005.
--   Б2. Отзыв — своя колонка revoked_at; живая ссылка = used_at и revoked_at
--       пусты (partial unique). Повторная выдача не упирается в 23505.
--   Б3. Эмиттеры: RPC под сессией — emit_event (канон после 0075), бот без
--       сессии — emit_event_unchecked.
--   Б4. Подключение только при center_write_state = 'ok' (0056 Р7): guard 0050
--       без сессии не срабатывает, а приём нового в read-only запрещён (0050 Р4).
--   Б5. bot_accounts — признак бот-аккаунта в public (не raw_app_meta_data:
--       его правят дашборд и Admin API). change_member_role отказывает:
--       сотрудника приглашают по почте, а за бот-аккаунтом — тот, кому
--       переслали ссылку.
--   Б6. Хранится sha256 кода; открытый код возвращается один раз. Политик
--       нет ни одной, грантов нет никому; статус для карточки — definer-
--       функция без кода. Под аудит таблица не ставится (код в audit_log
--       не нужен даже хешем — события дают след).
--   7.  Родитель без карточки (payer_id null, 0060) — payer дописывается;
--       сравнения через is distinct from.
--   8.  /stop — bot_unlink_telegram(chat); link_telegram веб-кодом
--       перехватывает чат у бот-аккаунта (иначе тупик «чат уже привязан»).
--       Членства бот-аккаунта остаются — их видно и отключают на карточке.
--   9.  Имя в Telegram (first_name / username) — в приглашении и bot_accounts,
--       на карточке список подключённых с «Отключить» (revoke_membership).
--   10. pg_advisory_xact_lock по чату (прецедент 0071 Р5); повтор апдейта
--       Telegram — «уже подключены», а не «ссылка недействительна».
--   11. Вставка в auth.users — одна функция-помощник без грантов, явный
--       список колонок как seed.sql (восемь токен-колонок '' — NULL ломает
--       GoTrue listUsers), is_anonymous = false (чистка анонимов в Supabase
--       удалила бы родителей каскадом). created_by/used_by — on delete set null.
--   12. Срок — CHECK expires_at <= created_at + 3 дня, не только функция.
--   13. payer.telegram_link_created — схема в contracts; membership.created
--       из бота несёт payer_id и via = 'telegram_link'.
--   14. Чат пользователя без единого членства — «не привязан», а не пустой
--       список («сегодня выходной», 0033 Р5): telegram_user требует членство.
--
-- Ревью написанного: telegram_user не отрезает центр на удалении (объяснение
-- 0056 Р7 даёт bot_*-функция); /start после /stop возвращает прежний бот-аккаунт
-- чата; событие — по действию (created / payer_linked / ничего); email в статусе
-- карточки не отдаётся; /stop различает родителя и сотрудника; индексы под FK.
--
-- Записано, не чинится: уведомление администрации о новом подключении (список
-- на карточке закрывает «кто подключился»); сверка телефона (В3); после
-- перехвата чата веб-кодом членства бот-аккаунта остаются — на карточке он
-- виден с пометкой «Telegram отключён», администратор его отключает.
-- =============================================================================


-- 1. Бот-аккаунты -----------------------------------------------------------------------------

create table if not exists public.bot_accounts (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  tg_name    text,
  created_at timestamptz not null default now()
);

comment on table public.bot_accounts is
  'Пользователь создан ссылкой на бота (0098): без почты, пароля и входа в веб. Признак для change_member_role (Б5) и link_telegram (п.8). Пишет только link_payer_telegram.';

alter table public.bot_accounts enable row level security;
-- Политик нет ни одной: таблица не читается и не пишется через PostgREST.
revoke all on table public.bot_accounts from public, anon, authenticated, service_role;


-- 2. Ссылки «Подключить Telegram» -------------------------------------------------------------

create table if not exists public.payer_telegram_invites (
  id           uuid primary key default gen_random_uuid(),
  code_hash    text not null unique,
  center_id    uuid not null references public.centers (id) on delete cascade,
  payer_id     uuid not null,
  created_by   uuid references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  revoked_at   timestamptz,
  used_at      timestamptz,
  used_by      uuid references auth.users (id) on delete set null,
  used_chat_id bigint,
  used_tg_name text,

  constraint payer_telegram_invites_payer_fk
    foreign key (payer_id, center_id) references public.payers (id, center_id) on delete cascade,
  -- п.12: срок держит строка, а не только выдающая функция.
  constraint payer_telegram_invites_ttl_check
    check (expires_at > created_at and expires_at <= created_at + interval '3 days'),
  constraint payer_telegram_invites_used_check
    check (used_at is null or used_chat_id is not null)
);

comment on table public.payer_telegram_invites is
  'Личные ссылки на бота для родителя (0098 В1). Хранится sha256 кода (Б6), открытый код отдаётся один раз. Живая ссылка — used_at и revoked_at пусты; одна живая на плательщика. Политик и грантов нет: статус — payer_telegram_status().';

create unique index if not exists payer_telegram_invites_live_idx
  on public.payer_telegram_invites (payer_id)
  where used_at is null and revoked_at is null;

create index if not exists payer_telegram_invites_center_idx on public.payer_telegram_invites (center_id);
-- Покрытие внешних ключей: партиальный live_idx им не считается (tests/0069).
create index if not exists payer_telegram_invites_payer_idx on public.payer_telegram_invites (payer_id, center_id);
create index if not exists payer_telegram_invites_created_by_idx on public.payer_telegram_invites (created_by);
create index if not exists payer_telegram_invites_used_by_idx on public.payer_telegram_invites (used_by);

alter table public.payer_telegram_invites enable row level security;
revoke all on table public.payer_telegram_invites from public, anon, authenticated, service_role;

-- Выдача — запись центра: в read-only её нет (0050).
call public.apply_readonly_guard('payer_telegram_invites');


-- 3. Помощник: бот-аккаунт в auth.users (п.11) ------------------------------------------------

create or replace function public.create_bot_parent_user(p_full_name text)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Явный список колонок, как seed.sql: токен-колонки '' — NULL GoTrue читает
  -- в Go-строку и отвечает 500 на списке пользователей.
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change,
    email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token,
    is_sso_user, is_anonymous,
    created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', null, null,
    jsonb_build_object('provider', 'telegram', 'providers', jsonb_build_array('telegram'), 'bot_only', true),
    jsonb_build_object('full_name', coalesce(nullif(trim(p_full_name), ''), 'Родитель')),
    '', '', '',
    '', '',
    '', '', '',
    false, false,
    now(), now()
  );

  return v_id;
end;
$$;

comment on function public.create_bot_parent_user(text) is
  'Строка auth.users бот-аккаунта родителя (0098 п.11): без почты, пароля и identities — войти в веб нельзя. Единственное место вставки в auth.users: если Supabase сузит права postgres на auth, чинить здесь. Без грантов ни у кого; зовёт только link_payer_telegram.';

revoke all on function public.create_bot_parent_user(text)
  from public, anon, authenticated, service_role, bot_worker;


-- 4. telegram_user: чат пользователя без членств — не привязан (п.14) ------------------------

create or replace function public.telegram_user(p_chat_id bigint)
  returns uuid
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select a.user_id
    from public.telegram_accounts a
   where a.chat_id = p_chat_id and a.unlinked_at is null
     -- 0098 п.14: отключённый родитель (членство снято) не получает пустой
     -- список «занятий нет» — бот отвечает «чат не привязан».
     -- Центр на удалении не отрезает: объяснение 0056 Р7 даёт сама bot_*-функция.
     and exists (select 1 from public.memberships m where m.user_id = a.user_id);
$$;

comment on function public.telegram_user(bigint) is
  'Внутренняя: чат → пользователь. Наружу не выдаётся, чтобы бот не мог спросить «а чей это чат». С 0098 — только пользователь хотя бы с одним членством (живость центра проверяет каждая bot_*-функция).';

revoke all on function public.telegram_user(bigint) from public, anon, authenticated, service_role;


-- 5. link_telegram: веб-аккаунт перехватывает чат у бот-аккаунта (п.8) -----------------------

-- Дословно 0033, кроме ветки v_other: чат бот-аккаунта закрывается и уходит
-- веб-аккаунту, иначе родитель с почтой, раньше открывший ссылку, упирается
-- в «чат уже привязан к другому аккаунту» навсегда.
create or replace function public.link_telegram(p_code text, p_chat_id bigint)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user  uuid;
  v_other uuid;
begin
  -- Р4: вызывает бот, не пользователь.
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р3: одним атомарным update — ретрай вебхука Telegram не должен
  -- проходить дважды.
  update public.telegram_link_codes
     set used_at = now()
   where code = p_code
     and used_at is null
     and expires_at > now()
  returning user_id into v_user;

  if v_user is null then
    raise exception 'Код недействителен или уже использован' using errcode = '22023';
  end if;

  select a.user_id into v_other
    from public.telegram_accounts a
   where a.chat_id = p_chat_id and a.unlinked_at is null;

  if v_other is not null and v_other <> v_user then
    if exists (select 1 from public.bot_accounts b where b.user_id = v_other) then
      update public.telegram_accounts
         set unlinked_at = now()
       where user_id = v_other and unlinked_at is null;
      v_other := null;
    else
      raise exception 'Этот чат уже привязан к другому аккаунту' using errcode = '22023';
    end if;
  end if;

  -- v_other здесь либо null (чат свободен), либо тот же пользователь —
  -- сравнение через `=` дало бы NULL и молча провалилось дальше.
  if v_other is not null then
    return v_user;
  end if;

  -- Смена чата: прежняя привязка закрывается, а не переписывается (Р2).
  update public.telegram_accounts
     set unlinked_at = now()
   where user_id = v_user and unlinked_at is null;

  insert into public.telegram_accounts (user_id, chat_id) values (v_user, p_chat_id);

  return v_user;
end;
$$;

comment on function public.link_telegram(text, bigint) is
  'Привязка чата к веб-аккаунту по коду /start (0033). С 0098 чат бот-аккаунта родителя перехватывается веб-аккаунтом: бот-привязка закрывается, членства бот-аккаунта остаются (их отключают на карточке плательщика).';

revoke all on function public.link_telegram(text, bigint) from public, anon, authenticated, service_role;
grant execute on function public.link_telegram(text, bigint) to bot_worker;


-- 6. change_member_role: бот-аккаунт сотрудником не становится (Б5) --------------------------

-- Дословно 0060, кроме проверки bot_accounts перед поиском членства.
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

  -- 0098 Б5: за бот-аккаунтом — тот, кому переслали ссылку, личность не
  -- проверена. Сотрудника приглашают по почте.
  if exists (select 1 from public.bot_accounts b where b.user_id = p_user_id) then
    raise exception 'Этот родитель подключён только через Telegram — сотрудника приглашают по почте' using errcode = '22023';
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

revoke all on function public.change_member_role(uuid, text) from public, anon;
grant execute on function public.change_member_role(uuid, text) to authenticated;


-- 7. Выдача ссылки (В1, В2, Б1–Б3, Б6) --------------------------------------------------------

create or replace function public.create_payer_telegram_link(p_payer_id uuid)
  returns table (code text, expires_at timestamptz)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_code    text;
  v_expires timestamptz := now() + interval '3 days';
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Подключить родителя к боту может владелец или администратор' using errcode = '42501';
  end if;

  -- Блокировка карточки: две выдачи подряд не упираются в partial unique.
  perform 1 from public.payers p
   where p.id = p_payer_id and p.center_id = v_center and p.deleted_at is null
     for update;
  if not found then
    raise exception 'Плательщик не найден или в архиве' using errcode = '22023';
  end if;

  update public.payer_telegram_invites i
     set revoked_at = now()
   where i.payer_id = p_payer_id
     and i.used_at is null
     and i.revoked_at is null;

  v_code := encode(extensions.gen_random_bytes(12), 'hex');

  insert into public.payer_telegram_invites (code_hash, center_id, payer_id, created_by, expires_at)
  values (encode(extensions.digest(v_code, 'sha256'), 'hex'), v_center, p_payer_id, auth.uid(), v_expires);

  perform public.emit_event(
    'payer.telegram_link_created',
    jsonb_build_object('center_id', v_center, 'payer_id', p_payer_id,
                       'created_by', auth.uid(), 'expires_at', v_expires),
    v_center
  );

  return query select v_code, v_expires;
end;
$$;

comment on function public.create_payer_telegram_link(uuid) is
  'Личная ссылка на бота для родителя плательщика (0098 В1): только owner/admin (Б1), прежняя живая ссылка отзывается (revoked_at, Б2), срок 3 дня. Открытый код — только в ответе этой функции, в базе sha256 (Б6). В read-only центре отказ даёт guard 0050.';

revoke all on function public.create_payer_telegram_link(uuid) from public, anon, service_role, bot_worker;
grant execute on function public.create_payer_telegram_link(uuid) to authenticated;


-- 8. Подключение по ссылке (бот, без сессии) --------------------------------------------------

create or replace function public.link_payer_telegram(p_code text, p_chat_id bigint, p_tg_name text default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_inv      public.payer_telegram_invites;
  v_payer    public.payers;
  v_center   text;
  v_user     uuid;
  v_member   public.memberships;
  v_tg_name  text := left(nullif(trim(coalesce(p_tg_name, '')), ''), 100);
  -- created | payer_linked | already — какое событие и какой ответ (ревью, п.6).
  v_action   text := 'created';
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_chat_id is null or p_chat_id <= 0 then
    raise exception 'Подключение — только в личной переписке с ботом' using errcode = '22023';
  end if;

  -- п.10: два Start с одного чата (ретрай вебхука, две ссылки) — по очереди.
  perform pg_advisory_xact_lock(7098, hashtext(p_chat_id::text));

  select * into v_inv
    from public.payer_telegram_invites i
   where i.code_hash = encode(extensions.digest(coalesce(p_code, ''), 'sha256'), 'hex')
     for update;

  if not found then
    raise exception 'Ссылка недействительна — попросите в центре новую' using errcode = '22023';
  end if;

  select c.name into v_center from public.centers c where c.id = v_inv.center_id;
  select * into v_payer from public.payers p where p.id = v_inv.payer_id;

  -- п.10: повтор апдейта Telegram после «Готово!» — тот же ответ, без ошибки.
  if v_inv.used_at is not null then
    if v_inv.used_chat_id = p_chat_id then
      return jsonb_build_object('center_name', v_center, 'payer_name', v_payer.full_name, 'already', true);
    end if;
    raise exception 'Ссылка уже использована — попросите в центре новую' using errcode = '22023';
  end if;

  if v_inv.revoked_at is not null or v_inv.expires_at <= now() then
    raise exception 'Ссылка устарела — попросите в центре новую' using errcode = '22023';
  end if;

  -- Б4: приём нового — только в центре, который пишет (0056 Р7).
  if public.center_write_state(v_inv.center_id) <> 'ok' then
    raise exception 'Центр сейчас не подключает родителей — обратитесь в центр' using errcode = '22023';
  end if;

  if v_payer.id is null or v_payer.deleted_at is not null then
    raise exception 'Карточка семьи в архиве — обратитесь в центр' using errcode = '22023';
  end if;

  -- Владелец чата — напрямую, а не telegram_user(): родитель, которого
  -- отключили (членств ноль), подключается снова тем же аккаунтом.
  select a.user_id into v_user
    from public.telegram_accounts a
   where a.chat_id = p_chat_id and a.unlinked_at is null;

  begin
    -- Ревью п.5: чат после /stop — прежний бот-аккаунт этого чата, а не новый
    -- пользователь (иначе старый остаётся членом семьи без Telegram, и
    -- администратор получает WhatsApp-задачи для родителя, который в Telegram).
    if v_user is null then
      select a.user_id into v_user
        from public.telegram_accounts a
        join public.bot_accounts b on b.user_id = a.user_id
       where a.chat_id = p_chat_id
         and a.unlinked_at is not null
         and not exists (
           select 1 from public.telegram_accounts x
            where x.user_id = a.user_id and x.unlinked_at is null
         )
       order by a.unlinked_at desc, a.id
       limit 1;
      if v_user is not null then
        insert into public.telegram_accounts (user_id, chat_id) values (v_user, p_chat_id);
      end if;
    end if;

    if v_user is not null then
      select * into v_member
        from public.memberships m
       where m.user_id = v_user and m.center_id = v_inv.center_id;

      if found then
        if v_member.role <> 'parent' then
          raise exception 'К этому Telegram привязан сотрудник центра — подключите родителя с другого аккаунта Telegram'
            using errcode = '22023';
        end if;
        -- п.7: «ничей» родитель (0060) — дописываем карточку.
        if v_member.payer_id is null then
          update public.memberships
             set payer_id = v_inv.payer_id
           where user_id = v_user and center_id = v_inv.center_id;
          v_action := 'payer_linked';
        elsif v_member.payer_id is distinct from v_inv.payer_id then
          raise exception 'Этот Telegram уже подключён к другой семье в этом центре' using errcode = '22023';
        else
          v_action := 'already';
        end if;
      else
        insert into public.memberships (user_id, center_id, role, payer_id)
        values (v_user, v_inv.center_id, 'parent', v_inv.payer_id);
      end if;

      update public.bot_accounts
         set tg_name = coalesce(v_tg_name, tg_name)
       where user_id = v_user;
    else
      v_user := public.create_bot_parent_user(v_payer.full_name);
      insert into public.bot_accounts (user_id, tg_name) values (v_user, v_tg_name);
      insert into public.telegram_accounts (user_id, chat_id) values (v_user, p_chat_id);
      insert into public.memberships (user_id, center_id, role, payer_id)
      values (v_user, v_inv.center_id, 'parent', v_inv.payer_id);
    end if;
  exception when unique_violation then
    -- Без автоповтора (CLAUDE.md): гонка с веб-привязкой того же чата.
    raise exception 'Не получилось подключить — попробуйте ещё раз' using errcode = '22023';
  end;

  update public.payer_telegram_invites
     set used_at = now(), used_by = v_user, used_chat_id = p_chat_id, used_tg_name = v_tg_name
   where id = v_inv.id;

  if v_action = 'created' then
    perform public.emit_event_unchecked(
      'membership.created',
      jsonb_build_object('center_id', v_inv.center_id, 'user_id', v_user, 'role', 'parent',
                         'payer_id', v_inv.payer_id, 'via', 'telegram_link'),
      v_inv.center_id
    );
  elsif v_action = 'payer_linked' then
    -- Контракт 0060: родителя привязали к карточке (контроль 0060 Р6 видит это событие).
    perform public.emit_event_unchecked(
      'membership.payer_linked',
      jsonb_build_object('center_id', v_inv.center_id, 'user_id', v_user,
                         'payer_id', v_inv.payer_id, 'previous_payer_id', null),
      v_inv.center_id
    );
  end if;

  return jsonb_build_object('center_name', v_center, 'payer_name', v_payer.full_name,
                            'already', v_action = 'already');
end;
$$;

comment on function public.link_payer_telegram(text, bigint, text) is
  'Родитель жмёт Start по личной ссылке (0098). Только bot_worker, только личный чат, блокировка по чату. Код гасится при успехе; повтор с того же чата — already. Центр должен писать (Б4), карточка — не в архиве. Чат без пользователя — бот-аккаунт (create_bot_parent_user + bot_accounts + telegram_accounts); пользователь чата без членства в центре — новое членство parent; parent без карточки — дописывается payer; другая семья или сотрудник этого центра — отказ.';

revoke all on function public.link_payer_telegram(text, bigint, text) from public, anon, authenticated, service_role;
grant execute on function public.link_payer_telegram(text, bigint, text) to bot_worker;


-- 9. /stop — отключить свой чат (п.8) ---------------------------------------------------------

create or replace function public.bot_unlink_telegram(p_chat_id bigint)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.telegram_accounts
     set unlinked_at = now()
   where chat_id = p_chat_id and unlinked_at is null
  returning user_id into v_user;

  -- bot_only — какой текст показать: родителю «попросите новую ссылку»,
  -- сотруднику «LogoCRM → Telegram → Получить код» (ревью, п.8).
  return jsonb_build_object(
    'unlinked', v_user is not null,
    'bot_only', v_user is not null and exists (select 1 from public.bot_accounts b where b.user_id = v_user)
  );
end;
$$;

comment on function public.bot_unlink_telegram(bigint) is
  'Команда /stop (0098 п.8): чат перестаёт получать сообщения. Членства не трогаются — у бот-аккаунта нет сессии, и отписаться иначе нельзя. Ответ {unlinked, bot_only}: повтор — unlinked false; bot_only выбирает текст бота.';

revoke all on function public.bot_unlink_telegram(bigint) from public, anon, authenticated, service_role;
grant execute on function public.bot_unlink_telegram(bigint) to bot_worker;


-- 10. Статус для карточки плательщика (п.9) ---------------------------------------------------

create or replace function public.payer_telegram_status(p_payer_id uuid)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  -- Тот же круг, что видит бейдж payer_telegram_linked (0033).
  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if not exists (select 1 from public.payers p where p.id = p_payer_id and p.center_id = v_center) then
    raise exception 'Плательщик не найден' using errcode = '42704';
  end if;

  return jsonb_build_object(
    'link', (
      select jsonb_build_object('created_at', i.created_at, 'expires_at', i.expires_at)
        from public.payer_telegram_invites i
       where i.payer_id = p_payer_id and i.center_id = v_center
         and i.used_at is null and i.revoked_at is null and i.expires_at > now()
    ),
    'parents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id',     m.user_id,
               -- Ревью п.7: без email — его видят registrar/finance, а user_email() отдаёт его только owner/admin.
               'name',        coalesce(b.tg_name, u.raw_user_meta_data ->> 'full_name', 'Родитель'),
               'via_bot',     b.user_id is not null,
               'telegram',    a.user_id is not null,
               'linked_at',   coalesce(a.linked_at, m.created_at)
             ) order by coalesce(a.linked_at, m.created_at), m.user_id)
        from public.memberships m
        join auth.users u on u.id = m.user_id
        left join public.bot_accounts b on b.user_id = m.user_id
        left join public.telegram_accounts a on a.user_id = m.user_id and a.unlinked_at is null
       where m.center_id = v_center and m.role = 'parent' and m.payer_id = p_payer_id
    ), '[]'::jsonb)
  );
end;
$$;

comment on function public.payer_telegram_status(uuid) is
  'Карточка плательщика (0098 п.9): живая ссылка (без кода — Б6) и подключённые родители — имя в Telegram или ФИО, через бота или веб, есть ли Telegram, когда подключён. Круг — can_payments, как бейдж; отключение — revoke_membership (owner/admin).';

revoke all on function public.payer_telegram_status(uuid) from public, anon, service_role, bot_worker;
grant execute on function public.payer_telegram_status(uuid) to authenticated;


-- 11. Заборы-каталоги --------------------------------------------------------------------------

-- От последних редакций (0097). bot_accounts — без center_id, пишет только
-- бот; payer_telegram_invites — под guard (выдача — запись центра), в выгрузку
-- не идёт: хеш кода не данные центра.

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
    ('bot_accounts',            'Р12: нет center_id; бот-аккаунт родителя пишет только бот (0098)')
$$;

revoke all on function public.readonly_guard_exempt_tables() from public, anon, authenticated, service_role;


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
    ('subscription_reminders_sent', 'Отметка воркера (0052 Р3)'),
    ('teacher_schedule_sent',      'Отметка планировщика (0097)'),
    ('debt_reminder_runs',         'Отметка планировщика (0097)'),
    ('subscription_period_reminders_sent', 'Отметка планировщика (0097)'),
    ('payer_telegram_invites',     'Хеш одноразовой ссылки на бота (0098 Б6): след выдачи — в events, не данные центра')
$$;

revoke all on function public.export_center_excluded_tables() from public, anon, authenticated, service_role;
