-- =============================================================================
-- 0033_telegram.sql — привязка Telegram, команды бота, подтверждение прихода
-- (этап 6, шаг 2 из 3)
--
-- Шаг 1 — 0032 (очередь и планировщики). Шаг 3 — 0034 (шаблоны сообщений и
-- журнал отправок). Здесь: кто такой этот чат и что ему можно ответить.
--
-- Решения:
--   Р1. Таблица привязок НЕ центровая и не проходит apply_tenant_rls.
--       Привязка живёт на пользователе: один человек бывает специалистом в
--       одном центре и родителем в другом, а чат у него один. Политика —
--       только своя строка. Следствие, о котором нельзя забывать:
--       revoke_membership (0028) удаляет членство физически, а привязка это
--       переживает, поэтому каждая bot_*-функция пересчитывает членства при
--       каждом вызове и никогда не считает факт привязки пропуском.
--   Р2. Уникальность привязки — частичными индексами where unlinked_at is
--       null, а не PK по user_id и unique по chat_id. Иначе: отвязал и
--       привязал снова — 23505, потому что строка никуда не делась; сменил
--       аккаунт Telegram — прежний chat_id занят навсегда. Строки не
--       переиспользуются, история привязок остаётся.
--   Р3. Код привязки гасится атомарным update ... returning, а не проверкой
--       через select. Telegram повторяет апдейт при таймауте вебхука, и две
--       параллельные /start <code> прошли бы обе.
--   Р4. bot_*-функции исполняются только вне пользовательской сессии
--       (обратная проверка auth.uid(), как у очереди 0032) и только ролью
--       bot_worker. Они ходят мимо RLS, поэтому видимость воспроизводят
--       сами: специалисту — его занятия, родителю — его дети, стойке и
--       администрации — центр. finance не получает ничего: 0031 закрыл ему
--       lessons и students, и бот не может быть дверью в обход.
--   Р5. Чат, который никому не привязан, получает отказ, а не пустой ответ.
--       Пустой список занятий читается как «сегодня выходной», пустой
--       баланс — как «долгов нет»; и то и другое — неправда о чужих данных.
--   Р6. Подтверждение прихода принимает ребёнка отдельным параметром. У
--       родителя двое детей в одной группе: кнопка одна, а unique
--       (lesson_id, student_id) требует выбрать конкретного — без параметра
--       функция подтвердила бы произвольного.
--   Р7. События telegram.linked нет. Все события центровые (events.center_id
--       not null), а привязка чата к человеку — факт не центра, а
--       пользователя; эмитить его в каждый центр, где человек состоит, —
--       шум. Отступление от плана этапа, где событие было перечислено.
-- =============================================================================


-- 1. Привязка чата --------------------------------------------------------------------------------

create table if not exists public.telegram_accounts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  chat_id     bigint not null,
  linked_at   timestamptz not null default now(),
  unlinked_at timestamptz
);

comment on table public.telegram_accounts is
  'Чат Telegram ↔ пользователь. Не центровая (Р1): чат один, а членств у человека может быть несколько. Отвязка — unlinked_at, строки не переиспользуются.';

-- Р2: живой может быть только одна привязка на пользователя и одна на чат.
create unique index if not exists telegram_accounts_user_live_idx
  on public.telegram_accounts (user_id) where unlinked_at is null;
create unique index if not exists telegram_accounts_chat_live_idx
  on public.telegram_accounts (chat_id) where unlinked_at is null;

alter table public.telegram_accounts enable row level security;

drop policy if exists telegram_accounts_self on public.telegram_accounts;
create policy telegram_accounts_self on public.telegram_accounts
  for select to authenticated
  using (user_id = auth.uid());

revoke all on table public.telegram_accounts from public, anon, authenticated, service_role;
grant select on public.telegram_accounts to authenticated;


create table if not exists public.telegram_link_codes (
  code       text primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz
);

comment on table public.telegram_link_codes is
  'Одноразовые коды для /start. Читать таблицу нельзя никому: код возвращается один раз из create_telegram_link_code и дальше живёт только у пользователя.';

create index if not exists telegram_link_codes_user_idx on public.telegram_link_codes (user_id);

alter table public.telegram_link_codes enable row level security;

-- Политик нет ни одной: таблица не читается и не пишется через PostgREST.
revoke all on table public.telegram_link_codes from public, anon, authenticated, service_role;


-- 2. Выдача и гашение кода ------------------------------------------------------------------------

create or replace function public.create_telegram_link_code()
  returns text
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_code text;
begin
  if v_uid is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  -- Прежние невыданные коды гасятся: у пользователя одновременно живёт
  -- ровно один код, иначе старая ссылка из переписки остаётся рабочей.
  update public.telegram_link_codes
     set used_at = now()
   where user_id = v_uid and used_at is null;

  -- 12 байт в hex — 24 символа: перебором в открытом боте не берётся,
  -- в deep-link t.me/bot?start=<code> уходит без экранирования.
  v_code := encode(extensions.gen_random_bytes(12), 'hex');

  insert into public.telegram_link_codes (code, user_id, expires_at)
  values (v_code, v_uid, now() + interval '15 minutes');

  return v_code;
end;
$$;

comment on function public.create_telegram_link_code() is
  'Одноразовый код для /start, живёт 15 минут. Выдача нового гасит предыдущий.';


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
    raise exception 'Этот чат уже привязан к другому аккаунту' using errcode = '22023';
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
  'Привязка чата по одноразовому коду. Код гасится атомарно (Р3); занятый чужим аккаунтом чат — отказ, а не молчаливая перепривязка.';


create or replace function public.unlink_telegram()
  returns boolean
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

  update public.telegram_accounts
     set unlinked_at = now()
   where user_id = v_uid and unlinked_at is null;

  return found;
end;
$$;

comment on function public.unlink_telegram() is 'Отвязать свой чат. Повторный вызов — false, не ошибка.';


-- 3. Кто этот чат ---------------------------------------------------------------------------------

create or replace function public.telegram_user(p_chat_id bigint)
  returns uuid
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select a.user_id
    from public.telegram_accounts a
   where a.chat_id = p_chat_id and a.unlinked_at is null;
$$;

comment on function public.telegram_user(bigint) is 'Внутренняя: чат → пользователь. Наружу не выдаётся, чтобы бот не мог спросить «а чей это чат».';

revoke all on function public.telegram_user(bigint) from public, anon, authenticated, service_role;


-- Бейдж «Telegram привязан» на карточке плательщика. Стойке он нужен, а
-- таблица привязок — нет: функция отвечает только про плательщика своего
-- центра и только «да/нет».
create or replace function public.payer_telegram_linked(p_payer_id uuid)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if not public.can_payments() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return exists (
    select 1
      from public.memberships m
      join public.telegram_accounts a on a.user_id = m.user_id and a.unlinked_at is null
      join public.payers p on p.id = m.payer_id
     where m.center_id = v_center
       and m.payer_id = p_payer_id
       and p.center_id = v_center
       and p.deleted_at is null
  );
end;
$$;

comment on function public.payer_telegram_linked(uuid) is
  'Привязан ли Telegram у плательщика своего центра — «да/нет» без доступа к таблице привязок. owner/admin/registrar/finance.';


-- 4. Подбор абонемента без пользовательской сессии ---------------------------------------------------

-- из 0015_freeze_state_unification.sql; меняется ровно одно: внутри
-- вызывается subscription_state_unchecked вместо гейтованной
-- subscription_state.
--
-- Почему это безопасно и почему обязательно. Функция объявлена security
-- invoker, то есть строки из subscriptions ей и так режет RLS вызывающего:
-- специалист не увидит ни одного абонемента, родитель — только своих детей.
-- Гейт внутри subscription_state (0015:197) нужен там, где пользователь
-- спрашивает про произвольный id, а не здесь — здесь он дублирует RLS.
-- Зато при вызове из definer-функции без пользователя (бот, планировщик)
-- subscription_visible_to_caller возвращает false на auth.uid() is null, все
-- состояния становятся NULL, фильтр state in (...) не проходит ни одна
-- строка — и бот отвечал бы «абонемента нет» любому родителю. Найдено CI:
-- тесты 26-27 в 0033.
create or replace function public.student_balance_pick(p_student_id uuid)
  returns table (subscription_id uuid, ends_at date, lesson_price_tiyin integer, state text)
  language sql
  stable
  security invoker
  set search_path = ''
as $$
  select c.id, c.ends_at, c.lesson_price_tiyin, c.state
    from (
      select s2.id, s2.ends_at, s2.created_at, s2.lesson_price_tiyin,
             public.subscription_state_unchecked(s2.id) as state
        from public.subscriptions s2
       where s2.student_id = p_student_id
         and s2.deleted_at is null
         and s2.status <> 'cancelled'
    ) c
   where c.state in ('active', 'exhausted', 'frozen')
   order by (c.state = 'frozen') asc, c.ends_at asc nulls last, c.created_at, c.id
   limit 1;
$$;

revoke all on function public.student_balance_pick(uuid) from public, anon;
grant execute on function public.student_balance_pick(uuid) to authenticated;


-- 5. Команды бота ----------------------------------------------------------------------------------

create or replace function public.bot_today(p_chat_id bigint)
  returns table (
    center_id    uuid,
    center_name  text,
    lesson_id    uuid,
    starts_at    timestamptz,
    title        text,
    teacher_name text
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_user uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_user := public.telegram_user(p_chat_id);
  -- Р5: пустой список читается как «сегодня выходной».
  if v_user is null then
    raise exception 'Чат не привязан' using errcode = '42501';
  end if;

  return query
    select c.id,
           c.name,
           l.id,
           l.starts_at,
           coalesce(g.name, s.full_name, 'Занятие'),
           t.full_name
      from public.memberships m
      join public.centers c on c.id = m.center_id and c.deleted_at is null
      join public.lessons l on l.center_id = m.center_id
       and l.deleted_at is null
       and l.status <> 'cancelled'
       and (l.starts_at at time zone public.center_timezone(c.id))::date = public.center_today(c.id)
      left join public.students s on s.id = l.student_id
      left join public.groups   g on g.id = l.group_id
      left join public.teachers t on t.id = l.effective_teacher_id
     where m.user_id = v_user
       -- Р4: та же видимость, что дают политики, только выписанная руками.
       -- Родитель — через состав занятия, а не через lessons.student_id:
       -- у группового занятия student_id пуст, и по нему родитель не увидел
       -- бы групповые занятия собственного ребёнка (ADR-006).
       and (
         (m.role in ('owner', 'admin', 'registrar'))
         or (m.role = 'teacher' and l.effective_teacher_id = m.teacher_id)
         or (m.role = 'parent' and exists (
               select 1
                 from public.lesson_participants lp
                 join public.students ps on ps.id = lp.student_id
                where lp.lesson_id = l.id
                  and lp.deleted_at is null
                  and ps.payer_id = m.payer_id
                  and ps.deleted_at is null
             ))
       )
     order by l.starts_at;
end;
$$;

comment on function public.bot_today(bigint) is
  'Занятия на сегодня для владельца чата: администрации — центр, специалисту — свои, родителю — детей. finance не получает ничего (0031). Непривязанный чат — отказ, не пустой список (Р5).';


create or replace function public.bot_balance(p_chat_id bigint)
  returns table (
    center_name        text,
    student_id         uuid,
    full_name          text,
    has_subscription   boolean,
    lessons_left       integer,
    debt_tiyin         integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_user uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_user := public.telegram_user(p_chat_id);
  if v_user is null then
    raise exception 'Чат не привязан' using errcode = '42501';
  end if;

  -- Только родитель: остаток числом — это его данные. Специалисту в
  -- приложении показывают слово (student_subscription_badge), и заводить
  -- второй канал к тем же числам в боте незачем.
  return query
    select c.name,
           s.id,
           s.full_name,
           b.subscription_id is not null,
           public.subscription_lessons_left(b.subscription_id),
           coalesce((
             select sum(a.price_tiyin)::integer
               from public.attendance a
              where a.student_id = s.id
                and a.center_id = s.center_id
                and a.subscription_id is null
                and a.deducted
           ), 0)
      from public.memberships m
      join public.centers c on c.id = m.center_id and c.deleted_at is null
      join public.students s on s.center_id = m.center_id
       and s.payer_id = m.payer_id
       and s.deleted_at is null
      left join lateral public.student_balance_pick(s.id) b on true
     where m.user_id = v_user
       and m.role = 'parent'
       and m.payer_id is not null
     order by c.name, s.full_name;
end;
$$;

comment on function public.bot_balance(bigint) is
  'Остаток и долг по детям владельца чата — только для роли parent. has_subscription отделяет «безлимит» от «нет абонемента»: в lessons_left и то и другое даёт NULL (0010).';


-- 6. Подтверждение прихода --------------------------------------------------------------------------

create table if not exists public.lesson_confirmations (
  id           uuid primary key default gen_random_uuid(),
  center_id    uuid not null references public.centers (id) on delete cascade,
  lesson_id    uuid not null,
  student_id   uuid not null,
  confirmed_by uuid references auth.users (id) on delete set null,
  confirmed_at timestamptz not null default now(),
  source       text not null default 'telegram' check (source in ('telegram', 'web')),

  constraint lesson_confirmations_lesson_student_key unique (lesson_id, student_id),
  constraint lesson_confirmations_lesson_fk
    foreign key (lesson_id, center_id) references public.lessons (id, center_id) on delete cascade,
  constraint lesson_confirmations_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade
);

comment on table public.lesson_confirmations is
  'Родитель подтвердил, что ребёнок придёт. Заполняется только confirm_lesson; грант — select. Составные FK по (id, center_id) — конвенция 0022.';

create index if not exists lesson_confirmations_lesson_idx on public.lesson_confirmations (lesson_id);

alter table public.lesson_confirmations enable row level security;

drop policy if exists lesson_confirmations_read on public.lesson_confirmations;
create policy lesson_confirmations_read on public.lesson_confirmations
  for select to authenticated
  using (
    center_id = public.current_center()
    and (
      public.my_role() in ('owner', 'admin', 'registrar')
      or (public.my_role() = 'teacher' and public.teacher_of_lesson(lesson_id))
      or (public.my_role() = 'parent'  and public.parent_of_student(student_id))
    )
  );

revoke all on table public.lesson_confirmations from public, anon, authenticated, service_role;
grant select on public.lesson_confirmations to authenticated;


create or replace function public.confirm_lesson(
  p_chat_id    bigint,
  p_lesson_id  uuid,
  p_student_id uuid
)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user   uuid;
  v_center uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_user := public.telegram_user(p_chat_id);
  if v_user is null then
    raise exception 'Чат не привязан' using errcode = '42501';
  end if;

  -- Р6: ребёнок задан явно. Проверяется всё разом: он есть в составе
  -- этого занятия, занятие живо, и платит за него именно тот, чей чат.
  select l.center_id into v_center
    from public.lesson_participants lp
    join public.lessons  l on l.id = lp.lesson_id and l.deleted_at is null and l.status <> 'cancelled'
    join public.students s on s.id = lp.student_id and s.deleted_at is null
    join public.memberships m on m.center_id = l.center_id
                             and m.user_id = v_user
                             and m.role = 'parent'
                             and m.payer_id = s.payer_id
   where lp.lesson_id = p_lesson_id
     and lp.student_id = p_student_id
     and lp.deleted_at is null;

  if v_center is null then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;

  insert into public.lesson_confirmations (center_id, lesson_id, student_id, confirmed_by, source)
  values (v_center, p_lesson_id, p_student_id, v_user, 'telegram')
  on conflict (lesson_id, student_id) do nothing;

  if not found then
    return false;
  end if;

  perform public.emit_event_unchecked(
    'lesson.confirmed',
    jsonb_build_object(
      'center_id', v_center,
      'lesson_id', p_lesson_id,
      'student_id', p_student_id
    ),
    v_center
  );

  return true;
end;
$$;

comment on function public.confirm_lesson(bigint, uuid, uuid) is
  'Родитель подтверждает приход ребёнка на занятие. Ребёнок — отдельным параметром (Р6): у родителя может быть двое детей в одной группе. Повторное подтверждение — false, не ошибка.';


-- 7. Гранты ------------------------------------------------------------------------------------------

revoke all on function public.create_telegram_link_code()                from public, anon, authenticated, service_role;
revoke all on function public.unlink_telegram()                          from public, anon, authenticated, service_role;
revoke all on function public.payer_telegram_linked(uuid)                from public, anon, authenticated, service_role;
revoke all on function public.link_telegram(text, bigint)                from public, anon, authenticated, service_role;
revoke all on function public.bot_today(bigint)                          from public, anon, authenticated, service_role;
revoke all on function public.bot_balance(bigint)                        from public, anon, authenticated, service_role;
revoke all on function public.confirm_lesson(bigint, uuid, uuid)         from public, anon, authenticated, service_role;

grant execute on function public.create_telegram_link_code()     to authenticated;
grant execute on function public.unlink_telegram()               to authenticated;
grant execute on function public.payer_telegram_linked(uuid)     to authenticated;

grant execute on function public.link_telegram(text, bigint)     to bot_worker;
grant execute on function public.bot_today(bigint)               to bot_worker;
grant execute on function public.bot_balance(bigint)             to bot_worker;
grant execute on function public.confirm_lesson(bigint, uuid, uuid) to bot_worker;
