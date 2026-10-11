-- 0099_platform_center_actions.sql — ручные действия платформы над центрами.
--
-- Решение владельца 11.10.2026: в /admin нужны «продлить или сменить тариф
-- вручную», «продлить пробный», «удалить центр» и «восстановить». Каждое —
-- с обязательной причиной и записью в журнал платформы. План проверен
-- architect до написания (13 находок, все учтены ниже).
--
-- Р1. Журнал platform_center_actions — append-only: пишут только RPC ниже,
--     update запрещён всегда, delete — только без сессии (каскад удаления
--     центра по будущему ADR-012). Отступление от шаблона таблиц: нет
--     updated_at/deleted_at — запись журнала не правится и не удаляется.
--     Без apply_audit и вне экспорта центра: audit_log и экспорт видят
--     owner/admin центра, причины платформы им показывать незачем.
-- Р2. Кто удалил — centers.deletion_source ('owner' | 'platform'). Правило
--     «платформенное удаление снимает только платформа» держит триггер на
--     centers, а не if в функции: иначе его обходили бы гонка с cancel,
--     любая будущая definer-функция и «спамер удалил сам — платформа не
--     может перехватить». Без сессии (миграции, фикстуры, будущая очистка)
--     триггер не судит — как center_readonly_guard (0050 Р1).
-- Р3. Решения владельца по ревью: платформа восстанавливает только то, что
--     удалила сама (удаление владельцем отменяет владелец); подаренные дни
--     не пересчитываются при смене тарифа — пульт предупреждает
--     (platform_gifted_since_payment); 90-дневный запрет на новый trial
--     после удаления (0083) остаётся, форма удаления о нём предупреждает.
-- Р4. Срок — дата в поясе центра = последний рабочий день (0050 Р11):
--     хранится момент внутри этого дня (platform_day_end), а не начало
--     следующего — иначе центр писал бы лишний день и все экраны
--     показывали бы «до» на день позже.
-- Р5. Ручное продление сверяется с тем, что видела форма (p_expected_until):
--     иначе подтверждённая в соседней вкладке оплата за год стиралась бы
--     «подарком на месяц». Сокращение срока — только явным флагом.
-- Р6. Причина — только в журнале. events читают owner/admin центра
--     (events_select_admin, 0001), поэтому в payload событий её нет.
-- Р7. Удалить центр с открытой заявкой на оплату нельзя: заявка выпала бы
--     из очереди платформы (0052 Р11), деньги остались бы без ответа.
-- Р8. Центр, удалённый платформой, получает свои тексты: «отмена в
--     настройках тарифа» для него неправда. Состояние center_write_state
--     то же ('deleted') — новое значение веб превратил бы в 'ok' (lib/plan.ts).


-- 1. Кто удалил центр (Р2) ------------------------------------------------------------------------

alter table public.centers add column if not exists deletion_source text
  constraint centers_deletion_source_values check (deletion_source in ('owner', 'platform'));

-- До 0099 удалять мог только владелец (0056).
update public.centers set deletion_source = 'owner' where deleted_at is not null and deletion_source is null;

alter table public.centers
  add constraint centers_deletion_source_matches check ((deleted_at is null) = (deletion_source is null));

comment on column public.centers.deletion_source is
  'Кто пометил центр на удаление (0099 Р2): owner — request_center_deletion, отменяет владелец; platform — platform_delete_center, снимает только платформа (триггер centers_deletion_source_guard).';

create or replace function public.centers_deletion_source_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_system boolean := auth.uid() is null;
  v_platform boolean := v_system or public.is_platform_admin();
begin
  -- Удаление без явного источника — владелец (фикстуры, request_center_deletion до переиздания).
  if new.deleted_at is not null and old.deleted_at is null and new.deletion_source is null then
    new.deletion_source := 'owner';
  end if;

  if old.deletion_source = 'platform' and not v_platform
     and (new.deleted_at is null or new.deletion_source is distinct from 'platform') then
    raise exception 'Центр удалён администратором платформы — восстановить его может только платформа: 0707 001 107'
      using errcode = '42501';
  end if;

  if new.deletion_source = 'platform' and old.deletion_source is distinct from 'platform' and not v_platform then
    raise exception 'Пометить центр удалённым платформой может только администратор платформы'
      using errcode = '42501';
  end if;

  if new.deleted_at is null then
    new.deletion_source := null;
  end if;
  return new;
end;
$$;
revoke all on function public.centers_deletion_source_guard() from public, anon, authenticated, service_role;

drop trigger if exists centers_deletion_source_guard on public.centers;
create trigger centers_deletion_source_guard
  before update of deleted_at, deletion_source on public.centers
  for each row execute function public.centers_deletion_source_guard();


-- 2. Конец дня в поясе центра (Р4) ----------------------------------------------------------------

-- Момент внутри дня p_day по поясу центра: (p_day at tz) < значение < (p_day + 1 at tz).
-- Одна формула для подписки и trial. Без грантов — зовут только функции ниже.
create or replace function public.platform_day_end(p_center_id uuid, p_day date)
  returns timestamptz
  language sql
  stable
  set search_path = ''
as $$
  select ((p_day + 1)::timestamp at time zone public.center_timezone(p_center_id)) - interval '1 microsecond';
$$;
revoke all on function public.platform_day_end(uuid, date) from public, anon, authenticated, service_role;


-- 3. Журнал ручных действий (Р1) ------------------------------------------------------------------

create table public.platform_center_actions (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null references public.centers (id) on delete cascade,
  action      text not null
    constraint platform_center_actions_action_check check (action in ('grant', 'trial', 'delete', 'restore')),
  reason      text not null
    constraint platform_center_actions_reason_check check (reason = btrim(reason) and char_length(reason) between 3 and 500),
  details     jsonb not null default '{}'::jsonb,
  created_by  uuid default auth.uid() references auth.users (id) on delete set null,
  created_at  timestamptz not null default now()
);

comment on table public.platform_center_actions is
  'Журнал ручных действий платформы над центрами (0099): продление/смена тарифа без оплаты, продление trial, удаление, восстановление. Причина и было/стало. Читает только администратор платформы; пишут только platform_*-RPC; правки и удаление записей запрещены (кроме каскада без сессии). Без аудита и вне экспорта центра (Р1).';

-- center_id — ведущая колонка составного индекса: покрывает FK и выборку по центру.
create index platform_center_actions_center_idx on public.platform_center_actions (center_id, created_at desc);
create index platform_center_actions_created_by_idx on public.platform_center_actions (created_by);

create or replace function public.platform_center_actions_immutable()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' or auth.uid() is not null then
    raise exception 'Запись журнала платформы не изменяется и не удаляется' using errcode = '42501';
  end if;
  return old;
end;
$$;
revoke all on function public.platform_center_actions_immutable() from public, anon, authenticated, service_role;

create trigger platform_center_actions_immutable
  before update or delete on public.platform_center_actions
  for each row execute function public.platform_center_actions_immutable();

alter table public.platform_center_actions enable row level security;
revoke all on table public.platform_center_actions from public, anon, authenticated, service_role;
grant select on table public.platform_center_actions to authenticated;

create policy platform_center_actions_select_platform on public.platform_center_actions
  for select to authenticated
  using ((select public.is_platform_admin()));

-- Забор 0050: под guard. Платформа проходит его всегда (0050 Р2).
call public.apply_readonly_guard('platform_center_actions');


-- 4. Действия платформы ----------------------------------------------------------------------------

-- Общая проверка причины: по-русски до check журнала.
create or replace function public.platform_reason(p_reason text)
  returns text
  language plpgsql
  immutable
  set search_path = ''
as $$
declare
  v text := btrim(coalesce(p_reason, ''));
begin
  if char_length(v) < 3 or char_length(v) > 500 then
    raise exception 'Укажите причину — от 3 до 500 символов' using errcode = '22023';
  end if;
  return v;
end;
$$;
revoke all on function public.platform_reason(text) from public, anon, authenticated, service_role;

-- 4.1. Продлить или сменить тариф вручную ---------------------------------------------------------
create or replace function public.platform_grant_subscription(
  p_center_id      uuid,
  p_plan           text,
  p_until          date,
  p_expected_until timestamptz,
  p_reason         text,
  p_allow_shorten  boolean default false
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_reason text;
  v_c      public.centers;
  v_tz     text;
  v_today  date;
  v_cur    timestamptz;
  v_new    timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  v_reason := public.platform_reason(p_reason);

  if not exists (select 1 from public.plans where code = p_plan and code <> 'trial') then
    raise exception 'Выберите платный тариф' using errcode = '22023';
  end if;

  select * into v_c from public.centers where id = p_center_id for update;
  if not found then
    raise exception 'Центр не найден' using errcode = '42704';
  end if;
  if v_c.deleted_at is not null then
    raise exception 'Центр удалён — сначала восстановите его' using errcode = '22023';
  end if;

  v_cur := case when v_c.plan = 'trial' then v_c.trial_ends_at else v_c.subscription_until end;
  if v_cur is distinct from p_expected_until then
    raise exception 'Срок центра изменился, пока была открыта форма — обновите страницу' using errcode = '40001';
  end if;

  v_tz := public.center_timezone(p_center_id);
  v_today := (now() at time zone v_tz)::date;
  if p_until is null or p_until < v_today then
    raise exception 'Дата окончания — не раньше сегодняшнего дня' using errcode = '22023';
  end if;
  if p_until > (v_today + interval '24 months')::date then
    raise exception 'Не дальше 24 месяцев от сегодня' using errcode = '22023';
  end if;

  v_new := public.platform_day_end(p_center_id, p_until);
  if v_cur is not null and v_new < v_cur and not coalesce(p_allow_shorten, false) then
    raise exception 'Новый срок раньше текущего (до %) — чтобы сократить, отметьте «Сократить срок»',
      to_char(v_cur at time zone v_tz, 'DD.MM.YYYY') using errcode = '22023';
  end if;

  -- ADR-011: план и срок одним update. trial_ends_at не трогаем — история trial.
  update public.centers set plan = p_plan, subscription_until = v_new where id = p_center_id;

  insert into public.platform_center_actions (center_id, action, reason, details)
  values (p_center_id, 'grant', v_reason, jsonb_build_object(
    'before', jsonb_build_object('plan', v_c.plan, 'until', v_cur),
    'after',  jsonb_build_object('plan', p_plan, 'until', v_new),
    'shortened', v_cur is not null and v_new < v_cur));

  -- Р6: без причины — events читает центр.
  perform public.emit_event_platform('center.subscription_granted',
    jsonb_build_object('center_id', p_center_id, 'plan', p_plan, 'until', v_new, 'by', auth.uid()), p_center_id);

  return jsonb_build_object('center_id', p_center_id, 'plan', p_plan, 'until', v_new);
end;
$$;
comment on function public.platform_grant_subscription(uuid, text, date, timestamptz, text, boolean) is
  'Ручное продление или смена платного тарифа платформой (0099): без platform_payments, в выручку не идёт. p_until — последний день в поясе центра (Р4), ≤ 24 мес.; p_expected_until — срок, который видела форма (Р5); сокращение — только p_allow_shorten. Журнал grant, событие без причины.';
revoke all on function public.platform_grant_subscription(uuid, text, date, timestamptz, text, boolean) from public, anon, service_role;
grant execute on function public.platform_grant_subscription(uuid, text, date, timestamptz, text, boolean) to authenticated;

-- 4.2. Продлить пробный период ----------------------------------------------------------------------
create or replace function public.platform_extend_trial(
  p_center_id      uuid,
  p_until          date,
  p_expected_until timestamptz,
  p_reason         text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_reason text;
  v_c      public.centers;
  v_tz     text;
  v_today  date;
  v_new    timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  v_reason := public.platform_reason(p_reason);

  select * into v_c from public.centers where id = p_center_id for update;
  if not found then
    raise exception 'Центр не найден' using errcode = '42704';
  end if;
  if v_c.deleted_at is not null then
    raise exception 'Центр удалён — сначала восстановите его' using errcode = '22023';
  end if;
  if v_c.plan <> 'trial' then
    raise exception 'Центр уже на платном тарифе — продлевайте подписку' using errcode = '22023';
  end if;
  if v_c.trial_ends_at is distinct from p_expected_until then
    raise exception 'Срок центра изменился, пока была открыта форма — обновите страницу' using errcode = '40001';
  end if;

  v_tz := public.center_timezone(p_center_id);
  v_today := (now() at time zone v_tz)::date;
  if p_until is null or p_until < v_today then
    raise exception 'Дата окончания — не раньше сегодняшнего дня' using errcode = '22023';
  end if;
  if p_until > v_today + 60 then
    raise exception 'Пробный период — не дальше 60 дней от сегодня' using errcode = '22023';
  end if;

  v_new := public.platform_day_end(p_center_id, p_until);
  if v_new < v_c.trial_ends_at then
    raise exception 'Новая дата раньше текущей (до %) — пробный период здесь только продлевается',
      to_char(v_c.trial_ends_at at time zone v_tz, 'DD.MM.YYYY') using errcode = '22023';
  end if;

  update public.centers set trial_ends_at = v_new where id = p_center_id;

  insert into public.platform_center_actions (center_id, action, reason, details)
  values (p_center_id, 'trial', v_reason, jsonb_build_object(
    'before', jsonb_build_object('until', v_c.trial_ends_at),
    'after',  jsonb_build_object('until', v_new)));

  perform public.emit_event_platform('center.trial_extended',
    jsonb_build_object('center_id', p_center_id, 'until', v_new, 'by', auth.uid()), p_center_id);

  return jsonb_build_object('center_id', p_center_id, 'until', v_new);
end;
$$;
comment on function public.platform_extend_trial(uuid, date, timestamptz, text) is
  'Продление trial платформой (0099): только trial-центр, только вперёд, ≤ 60 дней от сегодня, дата — последний день в поясе центра. Журнал trial.';
revoke all on function public.platform_extend_trial(uuid, date, timestamptz, text) from public, anon, service_role;
grant execute on function public.platform_extend_trial(uuid, date, timestamptz, text) to authenticated;

-- 4.3. Удалить центр ---------------------------------------------------------------------------------
create or replace function public.platform_delete_center(p_center_id uuid, p_confirm_name text, p_reason text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_reason text;
  v_c      public.centers;
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  v_reason := public.platform_reason(p_reason);

  select * into v_c from public.centers where id = p_center_id for update;
  if not found then
    raise exception 'Центр не найден' using errcode = '42704';
  end if;
  if v_c.deletion_source = 'platform' then
    raise exception 'Центр уже удалён платформой' using errcode = '23514';
  end if;
  if p_confirm_name is null or btrim(p_confirm_name) <> v_c.name then
    raise exception 'Название центра не совпадает — удаление не выполнено' using errcode = '22023';
  end if;
  -- Р7: заявка выпала бы из очереди платформы.
  if exists (select 1 from public.platform_payments p
              where p.center_id = p_center_id
                and p.confirmed_at is null and p.rejected_at is null and p.withdrawn_at is null) then
    raise exception 'У центра есть открытая заявка на оплату — сначала подтвердите или отклоните её' using errcode = '22023';
  end if;

  -- Центр, уже удалённый владельцем, платформа перехватывает: иначе владелец
  -- (например, спамер) отменил бы удаление сам.
  update public.centers
     set deleted_at = coalesce(deleted_at, now()), deletion_source = 'platform'
   where id = p_center_id and deletion_source is distinct from 'platform';
  if not found then
    raise exception 'Центр уже удалён платформой' using errcode = '23514';
  end if;

  insert into public.platform_center_actions (center_id, action, reason, details)
  values (p_center_id, 'delete', v_reason, jsonb_build_object(
    'before', jsonb_build_object('deleted_at', v_c.deleted_at, 'deletion_source', v_c.deletion_source, 'plan', v_c.plan)));

  perform public.emit_event_platform('center.deleted_by_platform',
    jsonb_build_object('center_id', p_center_id, 'by', auth.uid()), p_center_id);
end;
$$;
comment on function public.platform_delete_center(uuid, text, text) is
  'Мягкое удаление центра платформой (0099): имя — подтверждение, причина обязательна, при открытой заявке на оплату — отказ (Р7). deleted_at + deletion_source = platform; удаление владельцем перехватывается. Владелец его не отменит (триггер Р2). Журнал delete.';
revoke all on function public.platform_delete_center(uuid, text, text) from public, anon, service_role;
grant execute on function public.platform_delete_center(uuid, text, text) to authenticated;

-- 4.4. Восстановить центр (только удалённый платформой, Р3) --------------------------------------------
create or replace function public.platform_restore_center(p_center_id uuid, p_reason text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_reason text;
  v_c      public.centers;
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  v_reason := public.platform_reason(p_reason);

  select * into v_c from public.centers where id = p_center_id for update;
  if not found then
    raise exception 'Центр не найден' using errcode = '42704';
  end if;
  if v_c.deleted_at is null then
    raise exception 'Центр не удалён' using errcode = '23514';
  end if;
  if v_c.deletion_source <> 'platform' then
    raise exception 'Центр удалил сам владелец — отменить удаление может только он, в настройках тарифа' using errcode = '22023';
  end if;

  update public.centers set deleted_at = null where id = p_center_id and deletion_source = 'platform';
  if not found then
    raise exception 'Центр не удалён платформой' using errcode = '23514';
  end if;

  insert into public.platform_center_actions (center_id, action, reason, details)
  values (p_center_id, 'restore', v_reason, jsonb_build_object(
    'before', jsonb_build_object('deleted_at', v_c.deleted_at, 'deletion_source', v_c.deletion_source)));

  perform public.emit_event_platform('center.restored_by_platform',
    jsonb_build_object('center_id', p_center_id, 'by', auth.uid()), p_center_id);
end;
$$;
comment on function public.platform_restore_center(uuid, text) is
  'Восстановление центра, удалённого платформой (0099 Р3): удаление владельцем отменяет только владелец. Без ограничения 30 днями — физической очистки нет (ADR-012). Журнал restore.';
revoke all on function public.platform_restore_center(uuid, text) from public, anon, service_role;
grant execute on function public.platform_restore_center(uuid, text) to authenticated;

-- 4.5. Удалённые центры — раздел «Удалённые» в /admin --------------------------------------------------
create or replace function public.platform_deleted_centers()
  returns table (center_id uuid, name text, slug text, plan text, deleted_at timestamptz, deletion_source text, owner_email text)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  return query
    select c.id, c.name, c.slug, c.plan, c.deleted_at, c.deletion_source,
           (select u.email::text from public.memberships m join auth.users u on u.id = m.user_id
             where m.center_id = c.id and m.role = 'owner' order by m.created_at, m.user_id limit 1)
      from public.centers c
     where c.deleted_at is not null
     order by c.deleted_at desc;
end;
$$;
comment on function public.platform_deleted_centers() is
  'Удалённые центры для /admin (0099): кто удалил и когда, один email владельца — как platform_centers.';
revoke all on function public.platform_deleted_centers() from public, anon, service_role;
grant execute on function public.platform_deleted_centers() to authenticated;

-- 4.6. Журнал с названием центра и автором --------------------------------------------------------------
-- Прямой select журнала не покажет ни название (centers прячет RLS от
-- платформы), ни автора (auth.users закрыта).
create or replace function public.platform_center_actions_recent(p_limit integer default 30)
  returns table (id uuid, center_id uuid, center_name text, action text, reason text, details jsonb, created_by_email text, created_at timestamptz)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  return query
    select a.id, a.center_id, c.name, a.action, a.reason, a.details, u.email::text, a.created_at
      from public.platform_center_actions a
      join public.centers c on c.id = a.center_id
      left join auth.users u on u.id = a.created_by
     order by a.created_at desc
     limit least(greatest(coalesce(p_limit, 30), 1), 200);
end;
$$;
comment on function public.platform_center_actions_recent(integer) is
  'Последние ручные действия платформы (0099) с названием центра и email автора — для /admin.';
revoke all on function public.platform_center_actions_recent(integer) from public, anon, service_role;
grant execute on function public.platform_center_actions_recent(integer) to authenticated;

-- 4.7. Подарок после последней оплаты — предупреждение при подтверждении (Р3) ----------------------------
create or replace function public.platform_gifted_since_payment(p_center_id uuid)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  return exists (
    select 1 from public.platform_center_actions a
     where a.center_id = p_center_id and a.action = 'grant'
       and a.created_at > coalesce((select max(p.confirmed_at) from public.platform_payments p where p.center_id = p_center_id), '-infinity'::timestamptz)
  );
end;
$$;
comment on function public.platform_gifted_since_payment(uuid) is
  'Было ли ручное продление после последней подтверждённой оплаты (0099 Р3): подаренные дни при смене тарифа считаются как оплаченные (platform_switch_calc), пульт предупреждает.';
revoke all on function public.platform_gifted_since_payment(uuid) from public, anon, service_role;
grant execute on function public.platform_gifted_since_payment(uuid) to authenticated;


-- 5. Переиздания: удаление владельцем и тексты для центра, удалённого платформой (Р2, Р8) -----------

-- Хелпер для текстов: удалён ли центр платформой. Без грантов.
create or replace function public.center_deleted_by_platform(p_center_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (select 1 from public.centers c where c.id = p_center_id and c.deletion_source = 'platform');
$$;
revoke all on function public.center_deleted_by_platform(uuid) from public, anon, authenticated, service_role;

-- из 0056: источник 'owner' явно.
create or replace function public.request_center_deletion(p_confirm_name text)
  returns void
  language plpgsql
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
  if coalesce(public.role_in(v_center), '') <> 'owner' then
    raise exception 'Удалить центр может только владелец' using errcode = '42501';
  end if;

  select * into v_c from public.centers where id = v_center and deleted_at is null;
  if not found then
    raise exception 'Центр уже помечен на удаление' using errcode = '23514';
  end if;
  if p_confirm_name is null or trim(p_confirm_name) <> v_c.name then
    raise exception 'Название центра не совпадает — удаление не выполнено' using errcode = '22023';
  end if;

  -- Гонка (0056, ревью написанного SQL, находка 2): условие идемпотентности — в самом update.
  update public.centers set deleted_at = now(), deletion_source = 'owner' where id = v_center and deleted_at is null;
  if not found then
    raise exception 'Центр уже помечен на удаление' using errcode = '23514';
  end if;

  perform public.emit_event('center.deletion_requested',
    jsonb_build_object('center_id', v_center, 'by', auth.uid()), v_center);
end;
$$;
comment on function public.request_center_deletion(text) is
  'Заявка на удаление центра (0056 Р8) — owner, имя центра аргументом как подтверждение. deleted_at + deletion_source = owner (0099) + событие; физическая очистка через 30 дней — вне этого этапа (ADR-012).';
revoke all on function public.request_center_deletion(text) from public, anon, service_role;
grant execute on function public.request_center_deletion(text) to authenticated;

-- из 0056: отменяет только удаление владельцем — условие в самом update (Р2, урок гонки 0056).
create or replace function public.cancel_center_deletion()
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
  if coalesce(public.role_in(v_center), '') <> 'owner' then
    raise exception 'Отменить удаление может только владелец' using errcode = '42501';
  end if;

  update public.centers set deleted_at = null
   where id = v_center and deleted_at is not null and deletion_source = 'owner';
  if not found then
    if public.center_deleted_by_platform(v_center) then
      raise exception 'Центр удалён администратором платформы — восстановить его может только платформа: 0707 001 107'
        using errcode = '42501';
    end if;
    raise exception 'Центр не помечен на удаление' using errcode = '23514';
  end if;

  perform public.emit_event('center.deletion_cancelled',
    jsonb_build_object('center_id', v_center, 'by', auth.uid()), v_center);
end;
$$;
comment on function public.cancel_center_deletion() is
  'Отмена заявки на удаление (0056 Р9) — owner; только удаление владельцем (0099 Р2), платформенное снимает платформа. Без ADR-012 отмена не ограничена по времени.';
revoke all on function public.cancel_center_deletion() from public, anon, service_role;
grant execute on function public.cancel_center_deletion() to authenticated;

-- из 0056: + by_platform — веб прячет «Отменить удаление» и меняет текст баннера.
create or replace function public.center_deletion_state()
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
  if coalesce(public.role_in(v_center), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_c from public.centers where id = v_center;
  if not found then
    raise exception 'Центр не найден' using errcode = '42704';
  end if;

  return jsonb_build_object(
    'name',        v_c.name,
    'deleted',     v_c.deleted_at is not null,
    'deleted_at',  v_c.deleted_at,
    'by_platform', v_c.deletion_source = 'platform'
  );
end;
$$;
comment on function public.center_deletion_state() is
  'Имя центра и статус удаления в обход RLS (0056 Р10) — owner/admin видят собственный удалённый центр; by_platform (0099) — удалил ли платформа: отмены у владельца тогда нет.';
revoke all on function public.center_deletion_state() from public, anon, service_role;
grant execute on function public.center_deletion_state() to authenticated;

-- из 0056: текст для центра, удалённого платформой (Р8).
create or replace function public.center_readonly_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_row    jsonb;
  v_center uuid;
  v_state  text;
begin
  -- Р1: без сессии (миграции, каскады, bot_worker) — не наше дело.
  if auth.uid() is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Р4: revoke_membership гасит карточку teachers под своим флагом.
  if tg_table_name = 'teachers' and tg_op = 'UPDATE'
     and current_setting('logocrm.revoke_membership', true) = '1'
  then
    return new;
  end if;

  v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_center := (v_row ->> 'center_id')::uuid;

  -- Р6: строка платформы (center_id is null) не принадлежит центру.
  if v_center is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Р2/Р10: живой центр — дешёвая проверка по PK, без похода в auth.users.
  if public.center_writable(v_center) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Р2: платформа проходит всегда.
  if public.is_platform_admin() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  v_state := public.center_write_state(v_center);

  -- Р9: текст по роли — «оплатите» читает тот, кто может оплатить.
  if coalesce(public.my_role(), '') in ('owner', 'admin') then
    if v_state = 'deleted' then
      if public.center_deleted_by_platform(v_center) then
        raise exception 'Центр удалён администратором платформы — доступна только выгрузка данных. Вопросы: 0707 001 107'
          using errcode = 'PT402';
      end if;
      raise exception 'Центр помечен на удаление — доступны выгрузка данных и отмена в настройках тарифа'
        using errcode = 'PT402';
    end if;
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  if v_state = 'deleted' then
    raise exception 'Центр удалён — обратитесь к владельцу центра' using errcode = 'PT402';
  end if;
  raise exception 'Центр временно доступен только для чтения — обратитесь к администратору центра'
    using errcode = 'PT402';
end;
$$;
revoke all on function public.center_readonly_guard() from public, anon, authenticated, service_role;

-- из 0071: тот же текст для бота.
create or replace function public.bot_assert_writable(p_center_id uuid, p_user uuid)
  returns void
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_state text;
  v_role  text;
begin
  if public.center_writable(p_center_id) then
    return;
  end if;

  v_state := public.center_write_state(p_center_id);
  select m.role into v_role from public.memberships m
   where m.center_id = p_center_id and m.user_id = p_user;

  if coalesce(v_role, '') in ('owner', 'admin') then
    if v_state = 'deleted' then
      if public.center_deleted_by_platform(p_center_id) then
        raise exception 'Центр удалён администратором платформы — доступна только выгрузка данных. Вопросы: 0707 001 107'
          using errcode = 'PT402';
      end if;
      raise exception 'Центр помечен на удаление — доступны выгрузка данных и отмена в настройках тарифа'
        using errcode = 'PT402';
    end if;
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  if v_state = 'deleted' then
    raise exception 'Центр удалён — обратитесь к владельцу центра' using errcode = 'PT402';
  end if;
  raise exception 'Центр временно доступен только для чтения — обратитесь к администратору центра'
    using errcode = 'PT402';
end;
$$;
revoke all on function public.bot_assert_writable(uuid, uuid)
  from public, anon, authenticated, service_role, bot_worker;

-- из 0084: текст отказа в оплате для центра, удалённого платформой.
create or replace function public.submit_platform_payment(
  p_plan   text,
  p_months integer,
  p_source text,
  p_note   text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_plan   public.plans;
  v_amount integer;
  v_id     uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if public.center_write_state(v_center) = 'deleted' then
    if public.center_deleted_by_platform(v_center) then
      raise exception 'Центр удалён администратором платформы — оплата недоступна. Вопросы: 0707 001 107'
        using errcode = 'PT402';
    end if;
    raise exception 'Центр помечен на удаление — оплата недоступна. Отмените удаление в настройках тарифа'
      using errcode = 'PT402';
  end if;

  select * into v_plan from public.plans where code = p_plan;
  if not found or v_plan.code = 'trial' or not v_plan.is_public then
    raise exception 'Выберите платный тариф' using errcode = '22023';
  end if;
  if p_months is null or p_months < 1 or p_months > 24 then
    raise exception 'Срок оплаты — от 1 до 24 месяцев' using errcode = '22023';
  end if;
  if p_source not in ('mbank', 'elcart', 'cash', 'other') then
    raise exception 'Укажите способ оплаты' using errcode = '22023';
  end if;

  -- Р11: сумма — снимок прайса, посчитанный здесь, а не в браузере;
  -- со скидкой за предоплату (0084).
  v_amount := public.platform_payment_amount(v_plan.price_tiyin, p_months);

  insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source, note, submitted_by)
  values (v_center, v_plan.code, p_months, v_amount, p_source, nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  perform public.emit_event(
    'platform.payment_submitted',
    jsonb_build_object(
      'center_id',    v_center,
      'payment_id',   v_id,
      'plan',         v_plan.code,
      'months',       p_months,
      'amount_tiyin', v_amount,
      'source',       p_source
    ),
    v_center
  );

  return v_id;
end;
$$;
comment on function public.submit_platform_payment(text, integer, text, text) is
  'Заявка «я оплатил» от owner/admin центра (0051). Сумма = цена тарифа × месяцы из plans со скидкой за предоплату (platform_payment_amount, 0084; Р11 0051). Работает и в режиме только чтения: platform_payments в списке исключений guard. Вторая открытая заявка — 23505 platform_payments_one_open_per_center. Удалённый центр — PT402, платить некуда (0056 Р14); текст по тому, кто удалил (0099).';
revoke all on function public.submit_platform_payment(text, integer, text, text) from public, anon, service_role;
grant execute on function public.submit_platform_payment(text, integer, text, text) to authenticated;


-- 6. Экспорт центра: deny-list (Р1) ---------------------------------------------------------------
-- Переиздан с редакции 0098 (последняя), добавлена одна строка.
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
    ('payer_telegram_invites',     'Хеш одноразовой ссылки на бота (0098 Б6): след выдачи — в events, не данные центра'),
    ('platform_center_actions',    'Журнал ручных действий платформы (0099 Р1): причины пишет платформа, это не данные центра')
$$;
revoke all on function public.export_center_excluded_tables() from public, anon, authenticated, service_role;
