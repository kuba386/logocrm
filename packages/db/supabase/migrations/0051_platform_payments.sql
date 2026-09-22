-- =============================================================================
-- 0051_platform_payments.sql — заявки на оплату, продление подписки платформой,
-- долг контура бота из ADR-011 (этап 8a, шаг 3)
--
-- План — reports/stage-8.md, «Платежи — без Storage в 8a»; ревью плана
-- архитектором 22.09.2026 (14 находок) — все ниже как Р-условия.
--
--   Р1. Оба новых типа события — не о ребёнке. Триггер 0035
--       notification_log_subject_required держал список исключений литералом
--       в теле; третий «не про ребёнка» тип повторял бы миграцию. Признак
--       переезжает в справочник: notification_event_types.subject_required.
--       Тип вне справочника защищён по умолчанию (coalesce … true).
--
--   Р2. Уведомление платформе — дополнение, а не единственный путь: источник
--       истины — список открытых заявок по is_platform_admin()
--       (platform_open_payments), экран /admin читает его. Условие выката,
--       не кода: аккаунт владельца платформы зарегистрирован, email
--       подтверждён, Telegram привязан — иначе notification_platform_targets
--       честно отдаёт ноль строк (воркер пишет skipped), а extend_subscription
--       отвечает 42501 всем.
--
--   Р3. Ошибочную заявку можно закрыть: withdrawn_at (центр отзывает свою
--       открытую заявку), rejected_at/rejected_by/reject_reason (платформа
--       отклоняет). Частичный unique «одна открытая заявка на центр» смотрит
--       на все три исхода. Удаления нет — только отметки.
--
--   Р4. «Подтверждение целиком или ничего» — num_nonnulls(...) in (0, 4) на
--       confirmed_at/plan/months/amount_tiyin, а не цепочка равенств
--       (в PG она либо не парсится, либо проверяет не то). confirmed_by и
--       rejected_by вне счётчика: FK on delete set null не должен ронять
--       удаление пользователя на check.
--
--   Р5. Инварианты подтверждения — на колонках (months 1..24, amount > 0,
--       plan <> 'trial'), функция повторяет их только ради русского текста.
--
--   Р6. Платформа пишет в outbox через emit_event_platform с
--       is_platform_admin() первой строкой — не прямым insert: будущие
--       инварианты на events и реестр 0007 видят и её.
--
--   Р7. notification_platform_targets отдаёт чаты платформы — проверка
--       auth.uid() is null внутри, как у notification_user_targets (0047 Р2),
--       не только отсутствием гранта.
--
--   Р8. Контур бота при просрочке: ai_job_begin отдаёт null ДО insert в
--       ai_jobs и эмитит subscription.voice_blocked один раз на диктовку —
--       дедупликация по данным events (повторный вход после
--       release_stale_claims второго сообщения не даёт). Эта ветка ловит
--       только гонку «подписка истекла между диктовкой и обработкой»:
--       основной путь закрыт guard'ом на lesson_voice_requests (PT402 на
--       экране). Ветка не мёртвая — не снимать.
--
--   Р9. Отдельный тип subscription.voice_blocked со своим дефолтом, а не
--       {reason_text} в шаблоне 0047: «попробуйте ещё раз» при просрочке
--       ведёт специалиста в отказ. Признак в payload — reason_code.
--
--   Р10. Центр не подменяет текст, который читает платформа:
--        notification_event_types.audience = 'platform', триггер на
--        message_templates отбивает строку центра для такого типа (42501),
--        платформенная ветка резолвит шаблон с center_id = null. Гарантия в
--        SQL, а не в аргументе вызова.
--
--   Р11. Сумма заявки считается в SQL: submit_platform_payment принимает
--        тариф и месяцы, claimed_amount_tiyin = plans.price_tiyin × months —
--        снимок прайса на момент заявки, не число из браузера.
--
--   Р12. {until} в текстах — в поясе центра (center_timezone), как везде в
--        event_messages; для сообщения платформе — тоже пояс центра-заявителя.
--
--   Р13. Таблица по шаблону Database.md: created_at/updated_at + moddatetime,
--        submitted_by; отдельного submitted_at нет — это created_at.
--
--   Р14. Продление: база — greatest(now(), trial_ends_at) для trial и
--        greatest(now(), subscription_until) для платных (остаток trial не
--        сгорает); мягко удалённый центр не продлевается (42704); план и
--        срок — одним update (ADR-011); is_platform_admin() в политике
--        select — последним в or. Заявку подают owner и admin: центр, где
--        владелец потерял доступ, не должен терять и возможность платить.
--        Отклонение заявки центр видит в истории на экране тарифа;
--        отдельного уведомления об отклонении в 8a нет (решение).
--        recipient_user_id платформенного администратора попадает в
--        notification_log центра-заявителя — известное поведение.
--        apply_audit пишет user_id платформенного администратора в
--        audit_log центра; user_email() его центру не отдаст — в аудите
--        центра будет uuid (известное поведение).

-- 1. Справочник событий: адресат и обязательность subject (Р1, Р10) ---------------------------------

alter table public.notification_event_types
  add column if not exists audience text not null default 'center',
  add column if not exists subject_required boolean not null default true;

alter table public.notification_event_types drop constraint if exists notification_event_types_audience_check;
alter table public.notification_event_types
  add constraint notification_event_types_audience_check check (audience in ('center', 'platform'));

comment on column public.notification_event_types.audience is
  'center — читает центр (шаблон центр правит); platform — читает администратор платформы (шаблон только дефолтный, 0051 Р10).';
comment on column public.notification_event_types.subject_required is
  'Сообщение о ребёнке: строка notification_log обязана нести subject_id (0035; с 0051 признак здесь, а не литералом в триггере).';

update public.notification_event_types
   set subject_required = false
 where event_type in ('digest.daily', 'event.failed');

-- event.failed в справочнике не было (0037 заводил только типы с шаблонами),
-- а исключение 0035 на него распространялось — без строки признак по
-- умолчанию (true) потребовал бы subject у сообщения об ошибке.
insert into public.notification_event_types (event_type, description, audience, subject_required) values
  ('event.failed',               'Событие не обработано после трёх попыток', 'center',   false),
  ('platform.payment_submitted', 'Центр подал заявку на оплату',            'platform', false),
  ('subscription.extended',      'Подписка центра продлена',                'center',   false),
  ('subscription.voice_blocked', 'Голосовое не расшифровано: подписка истекла', 'center', true)
on conflict (event_type) do update
  set audience = excluded.audience, subject_required = excluded.subject_required;

-- Из 0035; список исключений заменён признаком справочника (Р1).
create or replace function public.notification_log_subject_required()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.subject_id is null
     and new.channel in ('telegram', 'whatsapp_link')
     and exists (
       select 1 from public.events e
        where e.id = new.event_id
          and coalesce(
                (select t.subject_required from public.notification_event_types t where t.event_type = e.type),
                true)
     )
  then
    raise exception 'Уведомление о ребёнке не может быть без subject_id'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

revoke all on function public.notification_log_subject_required() from public, anon, authenticated, service_role;

-- Р10: строка центра для платформенного типа невозможна — триггер, не
-- проверка в upsert_message_template.
create or replace function public.message_templates_platform_audience()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.center_id is not null and exists (
       select 1 from public.notification_event_types t
        where t.event_type = new.event_type and t.audience = 'platform')
  then
    raise exception 'Шаблон сообщения платформе центр не правит'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function public.message_templates_platform_audience() from public, anon, authenticated, service_role;

drop trigger if exists message_templates_platform_audience on public.message_templates;
create trigger message_templates_platform_audience
  before insert or update on public.message_templates
  for each row execute function public.message_templates_platform_audience();

-- Дефолты. insert … where not exists (0045: частичный индекс не даёт on conflict).
insert into public.message_templates (center_id, event_type, channel, text)
select v.center_id, v.event_type, v.channel, v.text
  from (values
    (null::uuid, 'platform.payment_submitted', 'telegram',
     E'Заявка на оплату: {center_name} — {plan_name} × {months} мес., {amount}, {source}.\nНомер заявки: {payment_id}\nПодтвердите в /admin после проверки чека.'),
    (null::uuid, 'subscription.extended', 'telegram',
     'Подписка продлена: тариф {plan_name}, оплачено {months} мес., действует до {until}.'),
    (null::uuid, 'subscription.extended', 'whatsapp_link',
     'Подписка продлена: тариф {plan_name}, оплачено {months} мес., действует до {until}.'),
    -- Р9: без «попробуйте ещё раз». {child} только в telegram (0047 Р1).
    (null::uuid, 'subscription.voice_blocked', 'telegram',
     'Голосовое по {child} не расшифровано: подписка центра истекла. Сообщите администратору центра — после оплаты диктовку нужно записать заново.'),
    (null::uuid, 'subscription.voice_blocked', 'whatsapp_link',
     'Голосовое не расшифровано: подписка центра истекла. Откройте LogoCRM.')
  ) as v(center_id, event_type, channel, text)
 where not exists (
   select 1 from public.message_templates m
    where m.center_id is null
      and m.event_type = v.event_type
      and m.channel = v.channel
      and m.deleted_at is null
 );


-- 2. platform_payments (Р3, Р4, Р5, Р13) ------------------------------------------------------------

create table if not exists public.platform_payments (
  id                   uuid primary key default gen_random_uuid(),
  center_id            uuid not null references public.centers (id) on delete cascade,

  -- Заявка центра.
  claimed_plan         text not null references public.plans (code),
  claimed_months       integer not null,
  claimed_amount_tiyin integer not null,
  source               text not null,
  note                 text,
  submitted_by         uuid references auth.users (id) on delete set null,

  -- Исходы: отзыв центром, отклонение платформой, подтверждение платформой.
  withdrawn_at         timestamptz,
  rejected_at          timestamptz,
  rejected_by          uuid references auth.users (id) on delete set null,
  reject_reason        text,
  confirmed_at         timestamptz,
  confirmed_by         uuid references auth.users (id) on delete set null,
  plan                 text references public.plans (code),
  months               integer,
  amount_tiyin         integer,
  receipt_received     boolean not null default false,

  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint platform_payments_claimed_months_range  check (claimed_months between 1 and 24),
  constraint platform_payments_claimed_amount_positive check (claimed_amount_tiyin > 0),
  constraint platform_payments_claimed_not_trial     check (claimed_plan <> 'trial'),
  constraint platform_payments_source_known          check (source in ('mbank', 'elcart', 'cash', 'other')),
  constraint platform_payments_confirmation_whole    check (num_nonnulls(confirmed_at, plan, months, amount_tiyin) in (0, 4)),
  constraint platform_payments_confirmed_by_needs_at check (confirmed_by is null or confirmed_at is not null),
  constraint platform_payments_rejected_by_needs_at  check (rejected_by is null or rejected_at is not null),
  constraint platform_payments_reject_reason_needs_at check (reject_reason is null or rejected_at is not null),
  constraint platform_payments_one_outcome           check (num_nonnulls(confirmed_at, rejected_at, withdrawn_at) <= 1),
  constraint platform_payments_months_range          check (months is null or months between 1 and 24),
  constraint platform_payments_amount_positive       check (amount_tiyin is null or amount_tiyin > 0),
  constraint platform_payments_plan_not_trial        check (plan is null or plan <> 'trial')
);

comment on table public.platform_payments is
  'Заявка центра «я оплатил» и решение платформы в одной строке (0051). Центр пишет claimed_*/source/note через submit_platform_payment, платформа — confirmed_*/plan/months/amount_tiyin через extend_subscription или rejected_* через reject_platform_payment. Чек не хранится — фото уходит платформе в Telegram с номером заявки. Открытая заявка — все три исхода пусты; одна на центр.';

create unique index if not exists platform_payments_one_open_per_center
  on public.platform_payments (center_id)
  where confirmed_at is null and rejected_at is null and withdrawn_at is null;

create index if not exists platform_payments_center_created_idx
  on public.platform_payments (center_id, created_at desc);

create index if not exists platform_payments_open_idx
  on public.platform_payments (created_at)
  where confirmed_at is null and rejected_at is null and withdrawn_at is null;

drop trigger if exists platform_payments_set_updated_at on public.platform_payments;
create trigger platform_payments_set_updated_at
  before update on public.platform_payments
  for each row execute function extensions.moddatetime(updated_at);

alter table public.platform_payments enable row level security;

-- Только чтение: owner/admin своего центра и платформа (последним — Р14).
-- apply_tenant_rls намеренно не применяется: её for all с with check дал бы
-- владельцу центра дописать себе подтверждение прямым insert.
drop policy if exists platform_payments_select on public.platform_payments;
create policy platform_payments_select on public.platform_payments
  for select to authenticated
  using (
    (center_id = public.current_center() and coalesce(public.my_role(), '') in ('owner', 'admin'))
    or public.is_platform_admin()
  );

grant select on public.platform_payments to authenticated;

call public.apply_audit('platform_payments');

-- Р2 из 0050: путь оплаты не может быть под блокировкой — просроченный центр
-- обязан мочь подать заявку. Из 0050; добавлена одна строка.
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
    ('platform_payments',       'Р2/Р12: заявка на оплату — путь разблокировки (0051)')
$$;

revoke all on function public.readonly_guard_exempt_tables() from public, anon, authenticated, service_role;


-- 3. Outbox платформы и адресация платформе (Р6, Р7) -------------------------------------------------

create or replace function public.emit_event_platform(
  p_type      text,
  p_payload   jsonb,
  p_center_id uuid
)
  returns bigint
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_id bigint;
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_center_id is null then
    raise exception 'emit_event_platform: не определён center_id' using errcode = '22004';
  end if;

  insert into public.events (center_id, type, payload)
  values (p_center_id, p_type, coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.emit_event_platform(text, jsonb, uuid) is
  'Запись в outbox от администратора платформы (0051 Р6): у него нет членства для emit_event и есть сессия, которую отвергает emit_event_unchecked. Зовут только definer-функции платформы.';

revoke all on function public.emit_event_platform(text, jsonb, uuid) from public, anon, authenticated, service_role;

create or replace function public.notification_platform_targets(p_event_type text)
  returns table (user_id uuid, channel text, chat_id bigint, template_text text)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  -- Р7: отдаёт личные чаты платформы — только контуру воркера без сессии.
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Только telegram: телефона у платформы нет, whatsapp_link не строится.
  -- Шаблон — только дефолт (center_id null), Р10.
  return query
    select u.id, 'telegram'::text, a.chat_id, rt.message_text
      from public.platform_admins pa
      join auth.users u on lower(u.email) = pa.email and u.email_confirmed_at is not null
      join public.telegram_accounts a on a.user_id = u.id and a.unlinked_at is null
      join lateral public.resolve_template(null, p_event_type, 'telegram') rt on true
     where rt.should_send;
end;
$$;

revoke all on function public.notification_platform_targets(text) from public, anon, authenticated, service_role;


-- 4. RPC центра: подать и отозвать заявку (Р3, Р11, Р14) ---------------------------------------------

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
  v_id     uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
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

  -- Р11: сумма — снимок прайса, посчитанный здесь, а не в браузере.
  insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source, note, submitted_by)
  values (v_center, v_plan.code, p_months, v_plan.price_tiyin * p_months, p_source, nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  perform public.emit_event(
    'platform.payment_submitted',
    jsonb_build_object(
      'center_id',    v_center,
      'payment_id',   v_id,
      'plan',         v_plan.code,
      'months',       p_months,
      'amount_tiyin', v_plan.price_tiyin * p_months,
      'source',       p_source
    ),
    v_center
  );

  return v_id;
end;
$$;

comment on function public.submit_platform_payment(text, integer, text, text) is
  'Заявка «я оплатил» от owner/admin центра (0051). Сумма = цена тарифа × месяцы из plans (Р11). Работает и в режиме только чтения: platform_payments в списке исключений guard. Вторая открытая заявка — 23505 platform_payments_one_open_per_center.';

revoke all on function public.submit_platform_payment(text, integer, text, text) from public, anon, service_role;
grant execute on function public.submit_platform_payment(text, integer, text, text) to authenticated;

create or replace function public.withdraw_platform_payment(p_payment_id uuid)
  returns void
  language plpgsql
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
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.platform_payments
     set withdrawn_at = now()
   where id = p_payment_id
     and center_id = v_center
     and confirmed_at is null and rejected_at is null and withdrawn_at is null;

  if not found then
    if exists (select 1 from public.platform_payments p where p.id = p_payment_id and p.center_id = v_center) then
      raise exception 'Заявка уже закрыта' using errcode = '22023';
    end if;
    raise exception 'Заявка не найдена' using errcode = '42704';
  end if;
end;
$$;

comment on function public.withdraw_platform_payment(uuid) is
  'Центр отзывает свою открытую заявку (0051 Р3) — после этого можно подать новую. Закрытую (подтверждённую, отклонённую, отозванную) — 22023.';

revoke all on function public.withdraw_platform_payment(uuid) from public, anon, service_role;
grant execute on function public.withdraw_platform_payment(uuid) to authenticated;


-- 5. RPC платформы: список, отклонение, продление (Р2, Р5, Р14) --------------------------------------

create or replace function public.platform_open_payments()
  returns table (
    payment_id           uuid,
    center_id            uuid,
    center_name          text,
    claimed_plan         text,
    claimed_months       integer,
    claimed_amount_tiyin integer,
    source               text,
    note                 text,
    submitted_by_email   text,
    created_at           timestamptz,
    center_plan          text,
    center_until         timestamptz
  )
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
    select p.id, p.center_id, c.name, p.claimed_plan, p.claimed_months, p.claimed_amount_tiyin,
           p.source, p.note, u.email::text, p.created_at, c.plan,
           case when c.plan = 'trial' then c.trial_ends_at else c.subscription_until end
      from public.platform_payments p
      join public.centers c on c.id = p.center_id
      left join auth.users u on u.id = p.submitted_by
     where p.confirmed_at is null and p.rejected_at is null and p.withdrawn_at is null
     order by p.created_at;
end;
$$;

comment on function public.platform_open_payments() is
  'Открытые заявки всех центров для /admin (0051 Р2) — источник истины; Telegram-уведомление лишь дополнение.';

revoke all on function public.platform_open_payments() from public, anon, service_role;
grant execute on function public.platform_open_payments() to authenticated;

create or replace function public.reject_platform_payment(p_payment_id uuid, p_reason text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if trim(coalesce(p_reason, '')) = '' then
    raise exception 'Укажите причину отклонения' using errcode = '22023';
  end if;

  update public.platform_payments
     set rejected_at = now(), rejected_by = auth.uid(), reject_reason = trim(p_reason)
   where id = p_payment_id
     and confirmed_at is null and rejected_at is null and withdrawn_at is null;

  if not found then
    if exists (select 1 from public.platform_payments p where p.id = p_payment_id) then
      raise exception 'Заявка уже закрыта' using errcode = '22023';
    end if;
    raise exception 'Заявка не найдена' using errcode = '42704';
  end if;
end;
$$;

comment on function public.reject_platform_payment(uuid, text) is
  'Платформа отклоняет открытую заявку с причиной (0051 Р3). Центр видит причину в истории на экране тарифа; отдельного уведомления в 8a нет (Р14).';

revoke all on function public.reject_platform_payment(uuid, text) from public, anon, service_role;
grant execute on function public.reject_platform_payment(uuid, text) to authenticated;

create or replace function public.extend_subscription(
  p_payment_id       uuid,
  p_plan             text,
  p_months           integer,
  p_amount_tiyin     integer,
  p_receipt_received boolean default false
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid;
  v_c      public.centers;
  v_base   timestamptz;
  v_until  timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р5: те же правила стоят констрейнтами на колонках; здесь — русский текст.
  if not exists (select 1 from public.plans where code = p_plan and code <> 'trial') then
    raise exception 'Выберите платный тариф' using errcode = '22023';
  end if;
  if p_months is null or p_months < 1 or p_months > 24 then
    raise exception 'Срок продления — от 1 до 24 месяцев' using errcode = '22023';
  end if;
  if p_amount_tiyin is null or p_amount_tiyin <= 0 then
    raise exception 'Сумма должна быть больше нуля' using errcode = '22023';
  end if;

  -- Идемпотентность: подтверждается только открытая заявка, одним update.
  update public.platform_payments
     set confirmed_at = now(), confirmed_by = auth.uid(),
         plan = p_plan, months = p_months, amount_tiyin = p_amount_tiyin,
         receipt_received = coalesce(p_receipt_received, false)
   where id = p_payment_id
     and confirmed_at is null and rejected_at is null and withdrawn_at is null
  returning center_id into v_center;

  if v_center is null then
    if exists (select 1 from public.platform_payments p where p.id = p_payment_id) then
      raise exception 'Заявка уже закрыта' using errcode = '22023';
    end if;
    raise exception 'Заявка не найдена' using errcode = '42704';
  end if;

  select * into v_c from public.centers where id = v_center and deleted_at is null for update;
  if not found then
    raise exception 'Центр не найден или закрыт' using errcode = '42704';
  end if;

  -- Р14: остаток trial не сгорает; просроченный — от сегодня.
  v_base := case
    when v_c.plan = 'trial' then greatest(now(), coalesce(v_c.trial_ends_at, now()))
    else greatest(now(), coalesce(v_c.subscription_until, now()))
  end;
  v_until := v_base + make_interval(months => p_months);

  -- ADR-011: план и срок одним update — между ними центр читал бы.
  update public.centers
     set plan = p_plan, subscription_until = v_until
   where id = v_center;

  perform public.emit_event_platform(
    'subscription.extended',
    jsonb_build_object(
      'center_id',  v_center,
      'payment_id', p_payment_id,
      'plan',       p_plan,
      'months',     p_months,
      'until',      v_until
    ),
    v_center
  );

  return jsonb_build_object('center_id', v_center, 'plan', p_plan, 'subscription_until', v_until);
end;
$$;

comment on function public.extend_subscription(uuid, text, integer, integer, boolean) is
  'Платформа подтверждает заявку и продлевает центр (0051): тариф, месяцы и сумма — параметры действия, не поля заявки. Повтор по тому же payment_id — 22023, centers не тронуты. База срока: greatest(now(), текущий срок) (Р14). План и срок одним update (ADR-011).';

revoke all on function public.extend_subscription(uuid, text, integer, integer, boolean) from public, anon, service_role;
grant execute on function public.extend_subscription(uuid, text, integer, integer, boolean) to authenticated;


-- 6. Контур бота при просрочке (Р8, Р9) — ai_job_begin из 0048, добавлен один блок ------------------

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

  -- 0051 Р8/Р9: подписка истекла между диктовкой и обработкой — деньги
  -- платформы не тратятся, специалист узнаёт один раз. До insert в ai_jobs:
  -- следа в очереди работ нет, дедупликация — по данным events.
  if not public.center_writable(v_event.center_id) then
    if not exists (
      select 1 from public.events e
       where e.type = 'subscription.voice_blocked'
         and e.center_id = v_event.center_id
         and e.payload ->> 'voice_request_id' = v_request.id::text
    ) then
      perform public.emit_event_unchecked(
        'subscription.voice_blocked',
        jsonb_build_object(
          'center_id',        v_event.center_id,
          'voice_request_id', v_request.id,
          'reason_code',      'subscription_expired'
        ),
        v_event.center_id
      );
    end if;
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

comment on function public.ai_job_begin(bigint) is
  'Занять событие до похода в платные API. null значит «не работай»: событие чужое, устаревшее, уже сделанное, терминальное, запись всё равно упадёт (0042 Б3) или подписка центра истекла (0051 Р8 — событие subscription.voice_blocked один раз на диктовку). С 0048 отдаёт student_goals — активные цели ребёнка диктовки без чего-либо, идентифицирующего ребёнка (goal_id, title, area, sound, stage_title; порядок этап→дата→id; не больше 50, полное число в student_goals_total). Место для квоты этапа 8 — здесь, до траты.';

revoke all on function public.ai_job_begin(bigint) from public, anon, authenticated, service_role;
grant execute on function public.ai_job_begin(bigint) to bot_worker;


-- 7. Доставка: три новые ветки перед общей цепочкой (Р10, Р12) — из 0047 ------------------------------

create or replace function public.event_messages(p_event_id bigint)
  returns table (
    recipient_user_id uuid,
    channel           text,
    chat_id           bigint,
    message           text,
    subject_id        uuid,
    action            jsonb
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_event    public.events;
  v_tz       text;
  v_vars     jsonb := '{}'::jsonb;
  v_student  uuid;
  v_payer    uuid;
  v_lesson   record;
  v_homework public.homework;
  v_note     public.lesson_notes;
  v_request  public.lesson_voice_requests;
  v_child    text;
  v_summary  text;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if not found then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  v_tz := public.center_timezone(v_event.center_id);

  -- 0051: заявка на оплату — администраторам платформы, шаблон только
  -- дефолтный (Р10), суммы и пояс — центра-заявителя (Р12).
  if v_event.type = 'platform.payment_submitted' then
    v_vars := jsonb_build_object(
      'center_name', coalesce((select c.name from public.centers c where c.id = v_event.center_id), '—'),
      'plan_name',   coalesce((select p.name from public.plans p where p.code = v_event.payload ->> 'plan'), coalesce(v_event.payload ->> 'plan', '—')),
      'months',      coalesce(v_event.payload ->> 'months', ''),
      'amount',      public.format_som(coalesce((v_event.payload ->> 'amount_tiyin')::bigint, 0)),
      'source',      case v_event.payload ->> 'source'
                       when 'mbank' then 'Mbank' when 'elcart' then 'Elcart'
                       when 'cash' then 'наличные' else 'другое' end,
      'payment_id',  coalesce(v_event.payload ->> 'payment_id', '')
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_platform_targets(v_event.type) r;
    return;
  end if;

  -- 0051: продление — owner/admin центра; {until} в поясе центра (Р12).
  if v_event.type = 'subscription.extended' then
    v_vars := jsonb_build_object(
      'plan_name', coalesce((select p.name from public.plans p where p.code = v_event.payload ->> 'plan'), coalesce(v_event.payload ->> 'plan', '—')),
      'months',    coalesce(v_event.payload ->> 'months', ''),
      'until',     coalesce(to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY'), '—')
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0051 Р9: подписка истекла между диктовкой и обработкой — заказчику
  -- диктовки, если он всё ещё сотрудник (0047 Р2). {child} только в telegram.
  if v_event.type = 'subscription.voice_blocked' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               jsonb_build_object('child',
                 case when r.channel = 'telegram' then v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r;
    return;
  end if;

  if v_event.type = 'lesson.reminder' then
    select l.starts_at, l.status, l.deleted_at, coalesce(t.full_name, '—') as teacher
      into v_lesson
      from public.lessons l
      left join public.teachers t on t.id = l.effective_teacher_id
     where l.id = (v_event.payload ->> 'lesson_id')::uuid;

    if not found or v_lesson.deleted_at is not null or v_lesson.status <> 'planned' then
      return;
    end if;

    v_vars := jsonb_build_object(
      'date',    to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY'),
      'time',    to_char(v_lesson.starts_at at time zone v_tz, 'HH24:MI'),
      'teacher', v_lesson.teacher
    );

    return query
      with participants as (
        select lp.student_id, s.full_name, s.payer_id
          from public.lesson_participants lp
          join public.students s on s.id = lp.student_id and s.deleted_at is null
         where lp.lesson_id = (v_event.payload ->> 'lesson_id')::uuid
           and lp.deleted_at is null
      )
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', p.full_name)),
             p.student_id,
             case when r.chat_id is null then null else jsonb_build_object(
               'label', 'Подтвердить приход',
               'callback_data', 'c:' || v_event.id::text || ':' || p.student_id::text
             ) end
        from participants p
        join lateral public.notification_targets(v_event.center_id, p.payer_id, v_event.type) r on true;
    return;
  end if;

  -- 0043: месячный отчёт. Текст уже заморожен в событии (Р4 из 0043) —
  -- здесь он только подставляется, ничего не пересчитывается.
  if v_event.type = 'report.monthly_ready' then
    v_student := (v_event.payload ->> 'student_id')::uuid;

    select s.payer_id into v_payer
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    -- 0047 Р10: текст отчёта — только в telegram, вне его пусто.
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'summary', case when r.channel = 'telegram'
                               then coalesce(v_event.payload ->> 'summary', '') else '' end,
               'month',   to_char((v_event.payload ->> 'period_month')::date, 'MM.YYYY'),
               'child',   (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0047: утверждённое резюме — родителю. Перечитывается на момент
  -- доставки (Р4); {summary} только в telegram (Р1); длина ограничена (Р5).
  if v_event.type = 'lesson.note_approved' then
    select * into v_note from public.lesson_notes n
     where n.id = (v_event.payload ->> 'lesson_note_id')::uuid
       and n.center_id = v_event.center_id
       and n.deleted_at is null
       and n.status = 'approved';
    if not found or coalesce(trim(v_note.parent_summary), '') = '' then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_note.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_note.student_id;
    select s.payer_id, s.full_name into v_payer, v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    v_summary := case
      when length(v_note.parent_summary) > 3500 then left(v_note.parent_summary, 3499) || '…'
      else v_note.parent_summary
    end;
    v_vars := jsonb_build_object(
      'child', v_child,
      'date',  to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY')
    );

    -- Р1: вне telegram переменная пуста, а не отсутствует — иначе
    -- render_template оставит «{summary}» буквально.
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               v_vars || jsonb_build_object('summary',
                 case when r.channel = 'telegram' then v_summary else '' end)),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0047: отказ обработки диктовки — заказчику диктовки, если он всё ещё
  -- сотрудник центра (Р2) и повтор диктовки ещё имеет смысл (Р4).
  -- Причина отказа в текст не идёт (Р6).
  if v_event.type = 'lesson.voice_failed' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    -- Р4: дословно условие отказа ai_job_begin (0042) — утверждено или
    -- голосовой черновик другой диктовки. Ручной черновик не гасит.
    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               jsonb_build_object('child',
                 case when r.channel = 'telegram' then v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r;
    return;
  end if;

  -- 0045: выдано родителю. Шлём независимо от текущего статуса задания —
  -- факт выдачи не перестаёт быть фактом, даже если уже сдано (Р4).
  if v_event.type = 'homework.assigned' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student),
               'due',   coalesce(to_char(v_homework.due_on, 'DD.MM.YYYY'), 'без срока')
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0045: специалисту, что сдано. Шлём, только если статус ВСЁ ЕЩЁ
  -- submitted — напоминание «проверьте» после того, как уже проверено,
  -- вводит в заблуждение (Р4, в отличие от assigned выше).
  if v_event.type = 'homework.submitted' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found or v_homework.status <> 'submitted' then
      return;
    end if;

    v_student := v_homework.student_id;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_homework_targets(v_event.center_id, v_homework.id, v_event.type) r;
    return;
  end if;

  -- 0045: специалист проверил — родителю.
  if v_event.type = 'homework.reviewed' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  if v_event.type in ('subscription.low_balance', 'subscription.exhausted', 'student.absent_streak') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'left',  coalesce(v_event.payload ->> 'lessons_left', ''),
      'count', coalesce(v_event.payload ->> 'length', '')
    );
  elsif v_event.type in ('installment.due', 'installment.overdue') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'amount', public.format_som((v_event.payload ->> 'amount_tiyin')::bigint),
      'date',   to_char((v_event.payload ->> 'due_date')::date, 'DD.MM.YYYY')
    );
  elsif v_event.type = 'digest.daily' then
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'date',    to_char((v_event.payload ->> 'date')::date, 'DD.MM.YYYY'),
               'lessons', coalesce(v_event.payload ->> 'lessons_today', '0'),
               'low',     coalesce(v_event.payload ->> 'low_balance', '0'),
               'debt',    public.format_som(coalesce((v_event.payload ->> 'debt_tiyin')::bigint, 0)),
               'overdue', coalesce(v_event.payload ->> 'installments_overdue', '0')
             )),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  else
    return;
  end if;

  select s.payer_id into v_payer
    from public.students s
   where s.id = v_student and s.deleted_at is null;

  if v_payer is null then
    return;
  end if;

  return query
    select r.user_id, r.channel, r.chat_id,
           public.render_template(r.template_text, v_vars || jsonb_build_object(
             'child', (select s.full_name from public.students s where s.id = v_student))),
           v_student,
           null::jsonb
      from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
end;
$$;

comment on function public.event_messages(bigint) is
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4), с 0047 — только в telegram. Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. lesson.note_approved (0047) — резюме родителю, {summary} только в telegram и не длиннее 3500 символов; lesson.voice_failed (0047) — заказчику диктовки через notification_user_targets, без причины отказа и только пока повтор диктовки имеет смысл (условие ai_job_begin). 0051: platform.payment_submitted — администраторам платформы (notification_platform_targets, шаблон только дефолтный), subscription.extended — owner/admin центра с {until} в поясе центра, subscription.voice_blocked — заказчику диктовки, {child} только в telegram. Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;


-- 8. Шов (правило Database.md) ---------------------------------------------------------------------------

update public.events
   set processed_at = now()
 where processed_at is null
   and type in ('platform.payment_submitted', 'subscription.extended', 'subscription.voice_blocked');
