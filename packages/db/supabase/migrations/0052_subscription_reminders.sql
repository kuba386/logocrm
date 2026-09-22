-- =============================================================================
-- 0052_subscription_reminders.sql — напоминания о сроке подписки, пульт
-- платформы по центрам, один trial-центр на владельца (этап 8a, шаг 4)
--
-- План — reports/stage-8.md («trial.ending», «самоподписка», /admin);
-- ревью плана архитектором 22.09.2026 (13 находок) — ниже как Р-условия.
--
--   Р1. Напоминание не выключается центром: notification_event_types.mandatory
--       + триггер на message_templates отбивает is_active = false для таких
--       типов (симметрично message_templates_platform_audience из 0051).
--       Текст править можно, молчать — нет: иначе центр уходит в read-only
--       без предупреждения и приходит с «LogoCRM всё заблокировала».
--
--   Р2. Два типа, не один: subscription.ending и subscription.expired —
--       тексты зовут к разным действиям, и выключать их (если бы было можно)
--       хотели бы порознь. {what} = «Пробный период»/«Подписка» — trial и
--       платный различаются одним словом, четыре типа не нужны. Имя
--       trial.ending из ТЗ не используется — отступление, в отчёт.
--
--   Р3. Идемпотентность — отметка subscription_reminders_sent с ключом
--       (center_id, until timestamptz, kind): по самому сроку из centers, а
--       не по дате в поясе центра — пояс правит владелец, и производная дата
--       дала бы второе сообщение за тот же срок. Продление сдвигает until →
--       новая пара → напоминание перед новым сроком придёт снова.
--
--   Р4. Пока у центра есть открытая заявка на оплату — continue БЕЗ отметки:
--       «продлите» центру, который вчера прислал чек, ведёт ко второй заявке
--       и 23505. Отзыв или отклонение заявки возвращает напоминание само.
--
--   Р5. Центр без даты (fail closed 0050 Р5) — напоминаний нет (ключу нечем
--       ключеваться), но состояние видно платформе: platform_centers() отдаёт
--       no_date и сортирует такие центры первыми.
--
--   Р6. {when} собирает SQL: «сегодня» / «завтра» / «через N дн.» — числом
--       0 и 1 текст врал бы в последний день. {until} — в поясе центра на
--       момент доставки.
--
--   Р7. Тело одного центра — в блоке исключений: мусор в settings->>'timezone'
--       одного центра не должен ронять прогон и отметки всем остальным.
--
--   Р8. Отметочная таблица — как lesson_reminders_sent/center_digest_runs:
--       revoke all, grant select, политика только select owner/admin, в списке
--       исключений guard (Р3 из 0050 — отметка воркера).
--
--   Р9. Один trial-центр на владельца — триггеры, не проверка в create_center:
--       memberships after insert OR update of role (повышение до owner через
--       change_member_role — тот же путь), centers after update of plan,
--       deleted_at (восстановление центра). Счёт включает мягко удалённые
--       trial-центры моложе 90 дней — иначе серийный trial через архивацию.
--       Без сессии (миграции, фикстуры) триггер молчит — правило анти-абьюза
--       живёт в пользовательской сессии (граница 0050 Р1); платформа
--       проходит. Путь «второй центр заводит платформа» существует:
--       platform_create_center(name, owner_email) — из платформенной сессии
--       триггер пропускает.
--
--   Р10. Деньги платформы считает SQL: platform_summary() — MRR (прайс ×
--        живые платные центры — подписочная база, не выручка; отступление от
--        «MRR по platform_payments» — в отчёт), выручка по месяцам
--        подтверждения по всем строкам без limit, счётчики центров и заявок.
--        Месяц — в поясе платформы (Asia/Bishkek): платформа одна.
--
--   Р11. platform_open_payments (0051) и platform_centers фильтруют
--        centers.deleted_at одинаково: закрытый центр не в заявках и не в
--        списке (extend_subscription ему всё равно откажет 42704).
--
--   Известные границы (в отчёт): owner/admin без Telegram получают строку
--   whatsapp_link с пустым chat_id → воркер пишет skipped — реальный канал
--   предупреждения один, Telegram, гарантия — баннер из center_limits();
--   до появления четвёртой ноды в сценарии schedule n8n напоминаний нет;
--   первый прогон после деплоя разошлёт subscription.expired всем живым
--   просроченным центрам (на staging после шва 0050 таких нет; для prod —
--   снять запрос до деплоя).

-- 1. Справочник и шаблоны (Р1, Р2) ------------------------------------------------------------------------

alter table public.notification_event_types
  add column if not exists mandatory boolean not null default false;

comment on column public.notification_event_types.mandatory is
  'Центр не может выключить рассылку этого типа (0052 Р1): триггер message_templates_mandatory_active отбивает is_active = false. Текст править можно.';

insert into public.notification_event_types (event_type, description, audience, subject_required, channels, mandatory) values
  ('subscription.ending',  'Срок подписки или пробного периода заканчивается', 'center', false, '{telegram,whatsapp_link}', true),
  ('subscription.expired', 'Срок подписки истёк — центр только читает',        'center', false, '{telegram,whatsapp_link}', true)
on conflict (event_type) do update
  set audience = excluded.audience, subject_required = excluded.subject_required,
      channels = excluded.channels, mandatory = excluded.mandatory;

create or replace function public.message_templates_mandatory_active()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.center_id is not null and not new.is_active and exists (
       select 1 from public.notification_event_types t
        where t.event_type = new.event_type and t.mandatory)
  then
    raise exception 'Это напоминание нельзя выключить — только изменить текст'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function public.message_templates_mandatory_active() from public, anon, authenticated, service_role;

drop trigger if exists message_templates_mandatory_active on public.message_templates;
create trigger message_templates_mandatory_active
  before insert or update on public.message_templates
  for each row execute function public.message_templates_mandatory_active();

insert into public.message_templates (center_id, event_type, channel, text)
select v.center_id, v.event_type, v.channel, v.text
  from (values
    (null::uuid, 'subscription.ending', 'telegram',
     '{what} заканчивается {until} ({when}). Продлите на экране «Тариф и оплата», чтобы центр не перешёл в режим только чтения.'),
    (null::uuid, 'subscription.ending', 'whatsapp_link',
     '{what} заканчивается {until} ({when}). Продлите на экране «Тариф и оплата» в LogoCRM.'),
    (null::uuid, 'subscription.expired', 'telegram',
     '{what} закончилась {until} — центр в режиме только чтения. Подайте заявку на оплату на экране «Тариф и оплата».'),
    (null::uuid, 'subscription.expired', 'whatsapp_link',
     '{what} закончилась {until} — центр в режиме только чтения. Подайте заявку на оплату в LogoCRM.')
  ) as v(center_id, event_type, channel, text)
 where not exists (
   select 1 from public.message_templates m
    where m.center_id is null
      and m.event_type = v.event_type
      and m.channel = v.channel
      and m.deleted_at is null
 );


-- 2. Отметка и планировщик (Р3–Р8) -----------------------------------------------------------------------------

create table if not exists public.subscription_reminders_sent (
  center_id uuid not null references public.centers (id) on delete cascade,
  until     timestamptz not null,
  kind      text not null check (kind in ('ending', 'expired')),
  sent_at   timestamptz not null default now(),
  primary key (center_id, until, kind)
);

comment on table public.subscription_reminders_sent is
  'Отметка планировщика subscription_reminders (0052 Р3): одно напоминание на (центр, срок, вид). Продление сдвигает срок — новая отметка. Пишет только планировщик.';

revoke all on table public.subscription_reminders_sent from public, anon, authenticated, service_role;
grant select on public.subscription_reminders_sent to authenticated;

alter table public.subscription_reminders_sent enable row level security;

drop policy if exists subscription_reminders_sent_select on public.subscription_reminders_sent;
create policy subscription_reminders_sent_select on public.subscription_reminders_sent
  for select to authenticated
  using (center_id = public.current_center() and coalesce(public.my_role(), '') in ('owner', 'admin'));

-- Из 0051; добавлена одна строка.
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
    ('subscription_reminders_sent', 'Р3: отметка планировщика (0052)')
$$;

revoke all on function public.readonly_guard_exempt_tables() from public, anon, authenticated, service_role;

create or replace function public.subscription_reminders()
  returns table (center_count integer)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer := 0;
  r       record;
  v_tz    text;
  v_until timestamptz;
  v_days  integer;
  v_kind  text;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    select c.id as center_id, c.plan, c.trial_ends_at, c.subscription_until
      from public.centers c
     where c.deleted_at is null
  loop
    -- Р7: один центр с мусором в поясе не роняет прогон остальным.
    begin
      v_tz := public.center_timezone(r.center_id);

      -- Р9 из 0032: >= 8, а не = 8 — пропущенный час не съедает напоминание.
      continue when extract(hour from (now() at time zone v_tz))::int < 8;

      v_until := case when r.plan = 'trial' then r.trial_ends_at else r.subscription_until end;
      -- Р5: без даты напоминать не о чем — видно платформе в platform_centers().
      continue when v_until is null;

      -- Р4: открытая заявка — молчим без отметки, вернёмся после её исхода.
      continue when exists (
        select 1 from public.platform_payments p
         where p.center_id = r.center_id
           and p.confirmed_at is null and p.rejected_at is null and p.withdrawn_at is null);

      v_days := (v_until at time zone v_tz)::date - public.center_today(r.center_id);
      v_kind := case
        when v_days between 0 and 3 then 'ending'
        when v_days < 0 then 'expired'
        else null
      end;
      continue when v_kind is null;

      insert into public.subscription_reminders_sent (center_id, until, kind)
      values (r.center_id, v_until, v_kind)
      on conflict (center_id, until, kind) do nothing;
      continue when not found;

      perform public.emit_event_unchecked(
        'subscription.' || v_kind,
        jsonb_build_object(
          'center_id', r.center_id,
          'plan',      r.plan,
          'is_trial',  r.plan = 'trial',
          'until',     v_until,
          'days_left', v_days
        ),
        r.center_id
      );
      v_count := v_count + 1;
    exception when others then
      -- Р7: пропускаем центр; причина — в логе Postgres, прогон идёт дальше.
      raise warning 'subscription_reminders: центр % пропущен: %', r.center_id, sqlerrm;
    end;
  end loop;

  return query select v_count;
end;
$$;

comment on function public.subscription_reminders() is
  'Планировщик (n8n schedule, раз в час): subscription.ending за 0–3 дня до срока и subscription.expired после — по одному на (центр, срок, вид), только с местного 8:00, не при открытой заявке (0052 Р3–Р7). Продление сдвигает срок — напоминание придёт снова перед новым.';

revoke all on function public.subscription_reminders() from public, anon, authenticated, service_role;
grant execute on function public.subscription_reminders() to bot_worker;


-- 3. Доставка (Р6) — event_messages из 0051, две ветки сверху ----------------------------------------------------

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
  v_days     integer;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if not found then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  v_tz := public.center_timezone(v_event.center_id);

  -- 0052: срок заканчивается / истёк — owner/admin центра. {when} и {until}
  -- считаются на момент доставки в поясе центра (Р6).
  if v_event.type in ('subscription.ending', 'subscription.expired') then
    v_days := ((v_event.payload ->> 'until')::timestamptz at time zone v_tz)::date
              - (now() at time zone v_tz)::date;
    v_vars := jsonb_build_object(
      'what',  case when (v_event.payload ->> 'is_trial')::boolean then 'Пробный период' else 'Подписка' end,
      'until', to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY'),
      'when',  case
                 when v_days <= 0 then 'сегодня'
                 when v_days = 1 then 'завтра'
                 else 'через ' || v_days::text || ' дн.'
               end
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

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
  -- диктовки, если он всё ещё сотрудник (0047 Р2) и повтор диктовки ещё
  -- имеет смысл (0047 Р4, дословно как у lesson.voice_failed — текст просит
  -- записать заново, и просить это при утверждённой заметке нельзя).
  -- {child} только в telegram.
  if v_event.type = 'subscription.voice_blocked' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

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
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4), с 0047 — только в telegram. Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. lesson.note_approved (0047) — резюме родителю, {summary} только в telegram и не длиннее 3500 символов; lesson.voice_failed (0047) — заказчику диктовки через notification_user_targets, без причины отказа и только пока повтор диктовки имеет смысл (условие ai_job_begin). 0051: platform.payment_submitted — администраторам платформы (notification_platform_targets, шаблон только дефолтный), subscription.extended — owner/admin центра с {until} в поясе центра, subscription.voice_blocked — заказчику диктовки, {child} только в telegram. 0052: subscription.ending/expired — owner/admin центра, {what}/{until}/{when} на момент доставки в поясе центра. Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;

update public.events
   set processed_at = now()
 where processed_at is null
   and type in ('subscription.ending', 'subscription.expired');


-- 4. Один trial-центр на владельца (Р9) ----------------------------------------------------------------------------

create or replace function public.assert_one_trial_center(p_user_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('trial_owner:' || p_user_id::text, 0));

  -- Мягко удалённые trial-центры моложе 90 дней считаются: иначе
  -- «закрыл — открыл новый» даёт бесконечный trial.
  if (select count(*)
        from public.centers c
        join public.memberships m on m.center_id = c.id and m.role = 'owner'
       where m.user_id = p_user_id
         and c.plan = 'trial'
         and (c.deleted_at is null or c.created_at > now() - interval '90 days')) > 1
  then
    raise exception 'У вас уже есть центр на пробном периоде. Второй центр открывает администратор платформы — напишите на kadamlogopedbishkek@gmail.com'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function public.assert_one_trial_center(uuid) from public, anon, authenticated, service_role;

create or replace function public.memberships_one_trial_per_owner()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  -- Без сессии (миграции, фикстуры) и для платформы правило не действует.
  if auth.uid() is null or public.is_platform_admin() then
    return null;
  end if;
  if new.role = 'owner' and (tg_op = 'INSERT' or old.role is distinct from new.role) then
    perform public.assert_one_trial_center(new.user_id);
  end if;
  return null;
end;
$$;

revoke all on function public.memberships_one_trial_per_owner() from public, anon, authenticated, service_role;

drop trigger if exists memberships_one_trial_per_owner on public.memberships;
create trigger memberships_one_trial_per_owner
  after insert or update of role on public.memberships
  for each row execute function public.memberships_one_trial_per_owner();

create or replace function public.centers_one_trial_per_owner()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  r record;
begin
  if auth.uid() is null or public.is_platform_admin() then
    return null;
  end if;
  if new.plan = 'trial' and new.deleted_at is null
     and (old.plan is distinct from new.plan or old.deleted_at is distinct from new.deleted_at)
  then
    for r in select m.user_id from public.memberships m where m.center_id = new.id and m.role = 'owner' loop
      perform public.assert_one_trial_center(r.user_id);
    end loop;
  end if;
  return null;
end;
$$;

revoke all on function public.centers_one_trial_per_owner() from public, anon, authenticated, service_role;

drop trigger if exists centers_one_trial_per_owner on public.centers;
create trigger centers_one_trial_per_owner
  after update of plan, deleted_at on public.centers
  for each row execute function public.centers_one_trial_per_owner();

-- Путь для второго центра: заводит платформа, владельцем становится
-- указанный пользователь (по подтверждённому email), платформа членства не
-- получает. Из 0001 create_center — та же генерация slug.
create or replace function public.platform_create_center(
  p_name        text,
  p_owner_email text,
  p_city        text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_owner  uuid;
  v_id     uuid;
  v_base   text;
  v_slug   text;
  v_suffix int := 1;
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Название центра обязательно' using errcode = '22004';
  end if;

  select u.id into v_owner
    from auth.users u
   where lower(u.email) = lower(trim(coalesce(p_owner_email, '')))
     and u.email_confirmed_at is not null;
  if v_owner is null then
    raise exception 'Пользователь с таким email не найден или email не подтверждён' using errcode = '42704';
  end if;

  v_base := coalesce(nullif(public.slugify(p_name), ''), 'center');
  v_slug := v_base;
  while exists (select 1 from public.centers c where c.slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base || '-' || v_suffix;
  end loop;

  insert into public.centers (name, slug, settings)
  values (trim(p_name), v_slug, jsonb_build_object('city', p_city, 'features', '{}'::jsonb))
  returning id into v_id;

  insert into public.memberships (user_id, center_id, role)
  values (v_owner, v_id, 'owner');

  perform public.emit_event_platform(
    'center.created',
    jsonb_build_object('center_id', v_id, 'name', trim(p_name), 'city', p_city, 'slug', v_slug),
    v_id
  );
  perform public.emit_event_platform(
    'membership.created',
    jsonb_build_object('center_id', v_id, 'user_id', v_owner, 'role', 'owner'),
    v_id
  );

  return v_id;
end;
$$;

comment on function public.platform_create_center(text, text, text) is
  'Второй (и далее) центр владельцу заводит платформа (0052 Р9): trial-лимит на владельца из платформенной сессии не действует. Владелец — по подтверждённому email; платформа членства не получает.';

revoke all on function public.platform_create_center(text, text, text) from public, anon, service_role;
grant execute on function public.platform_create_center(text, text, text) to authenticated;


-- 5. Пульт платформы: центры и сводка (Р5, Р10, Р11) --------------------------------------------------------------

create or replace function public.platform_centers()
  returns table (
    center_id         uuid,
    name              text,
    slug              text,
    plan              text,
    plan_name         text,
    is_trial          boolean,
    until             timestamptz,
    until_text        text,
    days_left         integer,
    writable          boolean,
    no_date           boolean,
    teachers          integer,
    students          integer,
    open_claims       integer,
    last_confirmed_at timestamptz,
    owner_email       text,
    created_at        timestamptz
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
    with base as (
      select c.id, c.name, c.slug, c.plan, c.created_at,
             public.center_timezone(c.id) as tz,
             case when c.plan = 'trial' then c.trial_ends_at else c.subscription_until end as until
        from public.centers c
       where c.deleted_at is null
    )
    select b.id, b.name, b.slug, b.plan,
           coalesce(p.name, b.plan),
           b.plan = 'trial',
           b.until,
           case when b.until is null then null else to_char(b.until at time zone b.tz, 'DD.MM.YYYY') end,
           case when b.until is null then null
                else ((b.until at time zone b.tz)::date - (now() at time zone b.tz)::date)::integer end,
           public.center_writable(b.id),
           b.until is null,
           (select count(*)::integer from public.teachers t where t.center_id = b.id and t.deleted_at is null),
           (select count(*)::integer from public.students s where s.center_id = b.id and s.deleted_at is null and s.status <> 'archived'),
           (select count(*)::integer from public.platform_payments pp
             where pp.center_id = b.id and pp.confirmed_at is null and pp.rejected_at is null and pp.withdrawn_at is null),
           (select max(pp.confirmed_at) from public.platform_payments pp where pp.center_id = b.id),
           (select u.email::text
              from public.memberships m
              join auth.users u on u.id = m.user_id
             where m.center_id = b.id and m.role = 'owner'
             order by m.created_at, m.user_id
             limit 1),
           b.created_at
      from base b
      left join public.plans p on p.code = b.plan
     order by (b.until is null) desc,
              ((b.until at time zone b.tz)::date - (now() at time zone b.tz)::date) nulls first,
              b.name;
end;
$$;

comment on function public.platform_centers() is
  'Все живые центры для /admin (0052): срок и дни в поясе центра, writable из center_writable, центры без даты первыми (Р5). Один email владельца — как submitted_by_email в platform_open_payments; ни телефонов, ни детей.';

revoke all on function public.platform_centers() from public, anon, service_role;
grant execute on function public.platform_centers() to authenticated;

create or replace function public.platform_summary()
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_tz constant text := 'Asia/Bishkek';
begin
  if not public.is_platform_admin() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'centers_total',   (select count(*) from public.centers c where c.deleted_at is null),
    'centers_trial',   (select count(*) from public.centers c where c.deleted_at is null and c.plan = 'trial'),
    'centers_paid',    (select count(*) from public.centers c where c.deleted_at is null and c.plan <> 'trial'),
    'centers_expired', (select count(*) from public.centers c where c.deleted_at is null and not public.center_writable(c.id)),
    'centers_no_date', (select count(*) from public.centers c where c.deleted_at is null
                          and (case when c.plan = 'trial' then c.trial_ends_at else c.subscription_until end) is null),
    'open_claims',     (select count(*) from public.platform_payments pp
                         where pp.confirmed_at is null and pp.rejected_at is null and pp.withdrawn_at is null
                           and exists (select 1 from public.centers c where c.id = pp.center_id and c.deleted_at is null)),
    -- Р10: подписочная база — прайс живых платных центров, не выручка.
    'mrr_tiyin',       (select coalesce(sum(p.price_tiyin), 0)::bigint
                          from public.centers c
                          join public.plans p on p.code = c.plan
                         where c.deleted_at is null and c.plan <> 'trial' and public.center_writable(c.id)),
    -- Выручка по месяцам подтверждения, все строки, пояс платформы.
    'revenue',         (select coalesce(jsonb_agg(jsonb_build_object(
                                 'month', x.month, 'count', x.cnt, 'total_tiyin', x.total)
                               order by x.month desc), '[]'::jsonb)
                          from (
                            select to_char(pp.confirmed_at at time zone v_tz, 'YYYY-MM') as month,
                                   count(*)::integer as cnt,
                                   sum(pp.amount_tiyin)::bigint as total
                              from public.platform_payments pp
                             where pp.confirmed_at is not null
                               and pp.confirmed_at >= date_trunc('month', now() at time zone v_tz) - interval '11 months'
                             group by 1
                          ) x)
  );
end;
$$;

comment on function public.platform_summary() is
  'Сводка платформы для /admin одним jsonb (0052 Р10): счётчики центров, открытые заявки, mrr_tiyin (прайс × живые платные центры), выручка по месяцам подтверждения за 12 месяцев в поясе платформы. Экран только рисует.';

revoke all on function public.platform_summary() from public, anon, service_role;
grant execute on function public.platform_summary() to authenticated;

-- Р11: из 0051, добавлен фильтр centers.deleted_at.
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
    center_until         timestamptz,
    center_timezone      text,
    center_until_text    text
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

  -- Даты — в поясе центра, готовой строкой: /admin показывает несколько
  -- центров сразу и не должен выбирать пояс сам (правило «время в поясе центра»).
  return query
    select p.id, p.center_id, c.name, p.claimed_plan, p.claimed_months, p.claimed_amount_tiyin,
           p.source, p.note, u.email::text, p.created_at, c.plan,
           case when c.plan = 'trial' then c.trial_ends_at else c.subscription_until end,
           public.center_timezone(c.id),
           to_char((case when c.plan = 'trial' then c.trial_ends_at else c.subscription_until end)
                     at time zone public.center_timezone(c.id), 'DD.MM.YYYY')
      from public.platform_payments p
      join public.centers c on c.id = p.center_id and c.deleted_at is null
      left join auth.users u on u.id = p.submitted_by
     where p.confirmed_at is null and p.rejected_at is null and p.withdrawn_at is null
     order by p.created_at;
end;
$$;

comment on function public.platform_open_payments() is
  'Открытые заявки живых центров для /admin (0051 Р2, 0052 Р11) — источник истины; Telegram-уведомление лишь дополнение.';

revoke all on function public.platform_open_payments() from public, anon, service_role;
grant execute on function public.platform_open_payments() to authenticated;
