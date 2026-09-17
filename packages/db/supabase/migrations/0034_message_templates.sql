-- =============================================================================
-- 0034_message_templates.sql — шаблоны сообщений и журнал отправок
-- (этап 6, шаг 3 из 3)
--
-- 0032 научил очередь отдавать события, 0033 — понимать, чей это чат. Здесь
-- событие превращается в конкретные сообщения конкретным людям.
--
-- Решения:
--   Р1. Дефолтные шаблоны лежат строками с center_id is null, а не
--       копируются в каждый центр при create_center (как предполагал промт
--       этапа). Копия замораживает формулировку на дату создания центра:
--       улучшили текст — старые центры остались со старым, а новый тип
--       события требует бэкфилла, забыть который означает тишину вместо
--       сообщений. Центр создаёт свою строку только когда правит текст, и
--       она перекрывает дефолт.
--       Цена: center_id nullable, то есть таблица не проходит целиком под
--       apply_tenant_rls — дефолты читаются отдельной политикой, а писать
--       их нельзя никому, кроме миграции.
--   Р2. Получателей считает SQL, а не n8n. «Кому можно знать этот факт» —
--       правило приватности, и ему место рядом с остальными такими
--       правилами, а не в JSON сценария, который не проверяется pgTAP.
--       Там же подстановка и формат денег: иначе тыйыны превратятся в
--       float в JS, а предпросмотр в интерфейсе разойдётся с отправкой.
--   Р3. Белый список типов. parseAppEvent (ADR-003) неизвестный тип молча
--       пропускает, и до этого этапа это ничего не стоило. Теперь событие,
--       которому некому уйти, обязано оставить строку в журнале — иначе
--       «уведомления включены, никто ничего не получил» выглядит как
--       «сегодня ничего не происходило».
--   Р4. Статус в журнале — машина состояний с триггером, а не отметка
--       постфактум. Строка «до отправки» защищает от дубля, но теряет
--       сообщение при сбое (повтор упрётся в unique); строка «после
--       отправки» защиты от дубля не даёт вовсе. Нужны оба свойства:
--       pending при захвате, затем sent/failed/no_channel/skipped, и
--       failed → pending только пока attempts меньше порога.
--   Р5. unique ... nulls not distinct: строка «получателей нет» имеет
--       recipient_user_id = null, и без этого их накопилось бы по одной на
--       каждый повтор обработки.
-- =============================================================================


-- 1. Шаблоны --------------------------------------------------------------------------------------

create table if not exists public.message_templates (
  id            uuid primary key default gen_random_uuid(),
  -- null — дефолт платформы (Р1), а не «центр не указан».
  center_id     uuid references public.centers (id) on delete cascade,
  event_type    text not null,
  channel       text not null check (channel in ('telegram', 'whatsapp_link')),
  text          text not null,
  is_active     boolean not null default true,
  custom_fields jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz
);

comment on table public.message_templates is
  'Тексты уведомлений. Строка с center_id is null — дефолт платформы; строка центра перекрывает её (0034 Р1). Плейсхолдеры вида {child} подставляет render_template.';

create unique index if not exists message_templates_center_key
  on public.message_templates (center_id, event_type, channel)
  where center_id is not null and deleted_at is null;
create unique index if not exists message_templates_default_key
  on public.message_templates (event_type, channel)
  where center_id is null and deleted_at is null;
create index if not exists message_templates_center_idx
  on public.message_templates (center_id) where deleted_at is null;

drop trigger if exists message_templates_set_updated_at on public.message_templates;
create trigger message_templates_set_updated_at
  before update on public.message_templates
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('message_templates');
call public.apply_audit('message_templates');

-- Дефолты платформы: читают все администрации центров, не правит никто —
-- политики на запись для center_id is null нет, а tenant_admin требует
-- center_id = current_center().
drop policy if exists message_templates_read_defaults on public.message_templates;
create policy message_templates_read_defaults on public.message_templates
  for select to authenticated
  using (
    center_id is null
    and deleted_at is null
    and public.my_role() in ('owner', 'admin')
  );

revoke all on table public.message_templates from public, anon, authenticated, service_role;
grant select, insert, update on public.message_templates to authenticated;


insert into public.message_templates (center_id, event_type, channel, text) values
  (null, 'lesson.reminder', 'telegram',
   'Напоминаем: завтра в {time} занятие у {child}. Специалист — {teacher}. Если планы изменились, сообщите нам.'),
  (null, 'lesson.reminder', 'whatsapp_link',
   'Здравствуйте! Напоминаем: завтра в {time} занятие у {child}. Специалист — {teacher}.'),

  (null, 'subscription.low_balance', 'telegram',
   'У {child} осталось занятий: {left}. Пора продлить абонемент.'),
  (null, 'subscription.low_balance', 'whatsapp_link',
   'Здравствуйте! У {child} осталось занятий: {left}. Пора продлить абонемент.'),

  (null, 'subscription.exhausted', 'telegram',
   'Абонемент у {child} закончился. Следующее занятие нужно оплатить.'),
  (null, 'subscription.exhausted', 'whatsapp_link',
   'Здравствуйте! Абонемент у {child} закончился. Следующее занятие нужно оплатить.'),

  (null, 'student.absent_streak', 'telegram',
   '{child} пропустил занятий подряд: {count}. Всё ли в порядке?'),
  (null, 'student.absent_streak', 'whatsapp_link',
   'Здравствуйте! {child} пропустил занятий подряд: {count}. Всё ли в порядке?'),

  (null, 'installment.due', 'telegram',
   'Сегодня платёж по рассрочке за занятия {child}: {amount}.'),
  (null, 'installment.due', 'whatsapp_link',
   'Здравствуйте! Сегодня платёж по рассрочке за занятия {child}: {amount}.'),

  (null, 'installment.overdue', 'telegram',
   'Платёж по рассрочке за занятия {child} просрочен с {date}: {amount}.'),
  (null, 'installment.overdue', 'whatsapp_link',
   'Здравствуйте! Платёж по рассрочке за занятия {child} просрочен с {date}: {amount}.'),

  (null, 'digest.daily', 'telegram',
   'Сводка на {date}: занятий сегодня — {lessons}, заканчивается абонементов — {low}, долг — {debt}, просроченных рассрочек — {overdue}.'),
  (null, 'digest.daily', 'whatsapp_link',
   'Сводка на {date}: занятий сегодня — {lessons}, заканчивается абонементов — {low}, долг — {debt}, просроченных рассрочек — {overdue}.')
on conflict do nothing;


-- 2. Подстановка и деньги ---------------------------------------------------------------------------

create or replace function public.format_som(p_tiyin bigint)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  -- Деньги форматируются один раз и в SQL: в JS тыйыны превратятся во
  -- float, а предпросмотр в интерфейсе разойдётся с отправленным текстом.
  select case when p_tiyin < 0 then '−' else '' end
      || (abs(p_tiyin) / 100)::text
      || ',' || lpad((abs(p_tiyin) % 100)::text, 2, '0')
      || ' сом';
$$;

comment on function public.format_som(bigint) is 'Тыйыны → «1234,50 сом». Единственный формат денег в сообщениях.';


create or replace function public.render_template(p_text text, p_vars jsonb)
  returns text
  language plpgsql
  immutable
  set search_path = ''
as $$
declare
  v_out text := p_text;
  v_key text;
begin
  for v_key in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    v_out := replace(v_out, '{' || v_key || '}', coalesce(p_vars ->> v_key, ''));
  end loop;
  return v_out;
end;
$$;

comment on function public.render_template(text, jsonb) is
  'Подстановка {ключ} из jsonb. Незаполненный ключ превращается в пустую строку, неизвестный плейсхолдер остаётся в тексте как есть — видно, что шаблон просит то, чего событие не даёт.';


-- 3. Журнал отправок --------------------------------------------------------------------------------

create table if not exists public.notification_log (
  id                uuid primary key default gen_random_uuid(),
  center_id         uuid not null references public.centers (id) on delete cascade,
  event_id          bigint not null references public.events (id) on delete cascade,
  recipient_user_id uuid references auth.users (id) on delete set null,
  channel           text not null check (channel in ('telegram', 'whatsapp_link', 'none')),
  status            text not null default 'pending'
                      check (status in ('pending', 'sent', 'failed', 'no_channel', 'skipped')),
  attempts          smallint not null default 0,
  text              text,
  error             text,
  sent_at           timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  -- Р5: у строки «получателей нет» recipient_user_id пуст, и без nulls not
  -- distinct их копилось бы по одной на каждый повтор обработки.
  constraint notification_log_once unique nulls not distinct (event_id, recipient_user_id, channel)
);

comment on table public.notification_log is
  'Что кому ушло. Единственная защита от повторной отправки при доставке at-least-once (ADR-003) — constraint notification_log_once плюс машина состояний (0034 Р4). Пишется только через RPC воркера.';

create index if not exists notification_log_center_idx on public.notification_log (center_id, created_at desc);
create index if not exists notification_log_event_idx  on public.notification_log (event_id);

drop trigger if exists notification_log_set_updated_at on public.notification_log;
create trigger notification_log_set_updated_at
  before update on public.notification_log
  for each row execute function extensions.moddatetime(updated_at);

alter table public.notification_log enable row level security;

-- Читает администрация центра. Политики finance нет: в text лежит имя
-- ребёнка и остаток, а бухгалтеру свободный текст о семье закрыт (0031).
drop policy if exists notification_log_read on public.notification_log;
create policy notification_log_read on public.notification_log
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() in ('owner', 'admin')
  );

revoke all on table public.notification_log from public, anon, authenticated, service_role;
grant select on public.notification_log to authenticated;


-- Р4: допустимые переходы — инвариант, а не порядок нод в сценарии n8n.
create or replace function public.notification_log_transition()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status not in ('pending', 'skipped', 'no_channel') then
      raise exception 'Уведомление заводится как pending, skipped или no_channel, а не % ', new.status
        using errcode = '22023';
    end if;
    return new;
  end if;

  if old.status = new.status then
    return new;
  end if;

  if old.status = 'pending' and new.status in ('sent', 'failed', 'no_channel', 'skipped') then
    return new;
  end if;

  -- Повтор после неудачи — единственный путь назад, и только пока не
  -- исчерпан порог: иначе обработчик крутил бы одно сообщение вечно.
  if old.status = 'failed' and new.status = 'pending' and old.attempts < 3 then
    return new;
  end if;

  raise exception 'Недопустимый переход уведомления: % → %', old.status, new.status
    using errcode = '22023';
end;
$$;

drop trigger if exists notification_log_transition on public.notification_log;
create trigger notification_log_transition
  before insert or update on public.notification_log
  for each row execute function public.notification_log_transition();

revoke all on function public.notification_log_transition() from public, anon, authenticated, service_role;


-- 4. Кому уходит сообщение -----------------------------------------------------------------------------

-- Про ребёнка — родителю, который за него платит, и никому больше. Канал:
-- telegram, если чат привязан; иначе whatsapp_link, и интерфейс покажет
-- кнопку с готовым текстом.
create or replace function public.notification_targets(
  p_center_id  uuid,
  p_payer_id   uuid,
  p_event_type text
)
  returns table (user_id uuid, channel text, chat_id bigint, template_text text)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select m.user_id,
         case when a.chat_id is null then 'whatsapp_link' else 'telegram' end,
         a.chat_id,
         t.text
    from public.memberships m
    left join public.telegram_accounts a
           on a.user_id = m.user_id and a.unlinked_at is null
    join lateral (
      select mt.text
        from public.message_templates mt
       where mt.event_type = p_event_type
         and mt.channel = case when a.chat_id is null then 'whatsapp_link' else 'telegram' end
         and mt.is_active
         and mt.deleted_at is null
         and (mt.center_id = p_center_id or mt.center_id is null)
       order by mt.center_id nulls last
       limit 1
    ) t on true
   where m.center_id = p_center_id
     and m.role = 'parent'
     and m.payer_id = p_payer_id;
$$;

comment on function public.notification_targets(uuid, uuid, text) is
  'Родители-получатели по плательщику: канал и текст шаблона. order by center_id nulls last — своя строка центра перекрывает дефолт платформы (Р1).';


create or replace function public.notification_admin_targets(p_center_id uuid, p_event_type text)
  returns table (user_id uuid, channel text, chat_id bigint, template_text text)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select m.user_id,
         case when a.chat_id is null then 'whatsapp_link' else 'telegram' end,
         a.chat_id,
         t.text
    from public.memberships m
    left join public.telegram_accounts a
           on a.user_id = m.user_id and a.unlinked_at is null
    join lateral (
      select mt.text
        from public.message_templates mt
       where mt.event_type = p_event_type
         and mt.channel = case when a.chat_id is null then 'whatsapp_link' else 'telegram' end
         and mt.is_active
         and mt.deleted_at is null
         and (mt.center_id = p_center_id or mt.center_id is null)
       order by mt.center_id nulls last
       limit 1
    ) t on true
   where m.center_id = p_center_id
     and m.role in ('owner', 'admin');
$$;

comment on function public.notification_admin_targets(uuid, text) is 'Получатели сводок: владелец и администраторы центра.';


-- 5. Событие → сообщения -----------------------------------------------------------------------------

create or replace function public.event_messages(p_event_id bigint)
  returns table (
    recipient_user_id uuid,
    channel           text,
    chat_id           bigint,
    message           text
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_event   public.events;
  v_tz      text;
  v_vars    jsonb := '{}'::jsonb;
  v_student uuid;
  v_payer   uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if not found then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  v_tz := public.center_timezone(v_event.center_id);

  -- Р3: белый список. Всё, чего здесь нет, получателей не имеет, и воркер
  -- обязан записать это в журнал строкой skipped, а не промолчать.
  if v_event.type = 'lesson.reminder' then
    select jsonb_build_object(
             'date',    to_char(l.starts_at at time zone v_tz, 'DD.MM.YYYY'),
             'time',    to_char(l.starts_at at time zone v_tz, 'HH24:MI'),
             'teacher', coalesce(t.full_name, '—')
           )
      into v_vars
      from public.lessons l
      left join public.teachers t on t.id = l.effective_teacher_id
     where l.id = (v_event.payload ->> 'lesson_id')::uuid;

    return query
      with participants as (
        select lp.student_id, s.full_name, s.payer_id
          from public.lesson_participants lp
          join public.students s on s.id = lp.student_id and s.deleted_at is null
         where lp.lesson_id = (v_event.payload ->> 'lesson_id')::uuid
           and lp.deleted_at is null
      )
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', p.full_name))
        from participants p
        join lateral public.notification_targets(v_event.center_id, p.payer_id, v_event.type) r on true;
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
             ))
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
             'child', (select s.full_name from public.students s where s.id = v_student)))
      from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
end;
$$;

comment on function public.event_messages(bigint) is
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped (Р3).';



-- 6. Журнал: RPC воркера ------------------------------------------------------------------------------

create or replace function public.notification_begin(
  p_event_id  bigint,
  p_recipient uuid,
  p_channel   text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid;
  v_row    public.notification_log;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select e.center_id into v_center from public.events e where e.id = p_event_id;
  if v_center is null then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  select * into v_row from public.notification_log l
   where l.event_id = p_event_id
     and l.recipient_user_id is not distinct from p_recipient
     and l.channel = p_channel;

  if not found then
    insert into public.notification_log (center_id, event_id, recipient_user_id, channel, status)
    values (v_center, p_event_id, p_recipient, p_channel, 'pending')
    returning id into v_row.id;
    return v_row.id;
  end if;

  -- Уже доставлено — второй раз не шлём: ровно ради этого случая журнал и
  -- пишется до отправки, а не после.
  if v_row.status in ('sent', 'skipped', 'no_channel') then
    return null;
  end if;

  if v_row.status = 'failed' then
    if v_row.attempts >= 3 then
      return null;
    end if;
    update public.notification_log set status = 'pending' where id = v_row.id;
  end if;

  return v_row.id;
end;
$$;

comment on function public.notification_begin(bigint, uuid, text) is
  'Захватить отправку: заводит строку pending или возвращает null, если сообщение уже ушло либо исчерпало попытки. Вызывается ДО отправки — иначе защиты от дубля нет (Р4).';


create or replace function public.notification_finish(
  p_id     uuid,
  p_status text,
  p_error  text default null,
  p_text   text default null
)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.notification_log
     set status   = p_status,
         attempts = case when p_status = 'failed' then attempts + 1 else attempts end,
         sent_at  = case when p_status = 'sent' then now() else sent_at end,
         error    = left(nullif(p_error, ''), 1000),
         text     = coalesce(p_text, text)
   where id = p_id;

  return found;
end;
$$;

comment on function public.notification_finish(uuid, text, text, text) is
  'Закрыть отправку: sent, failed, no_channel или skipped. Недопустимый переход отбивает триггер, а не эта функция.';


create or replace function public.notification_skip(p_event_id bigint, p_reason text)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid;
  v_id     uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select e.center_id into v_center from public.events e where e.id = p_event_id;
  if v_center is null then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  insert into public.notification_log (center_id, event_id, recipient_user_id, channel, status, error)
  values (v_center, p_event_id, null, 'none', 'skipped', left(p_reason, 1000))
  on conflict on constraint notification_log_once do nothing
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.notification_skip(bigint, text) is
  'Событие обработано, но сообщений не породило: нет шаблона, нет получателей, тип без обработчика. Строка в журнале обязательна — тишина неотличима от «всё доставлено» (Р3).';


-- Предпросмотр шаблона на экране настроек: тот же рендер, что уходит в
-- сообщении, иначе интерфейс показывал бы не то, что отправится.
create or replace function public.preview_message(p_text text, p_vars jsonb default null)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return public.render_template(
    p_text,
    coalesce(p_vars, jsonb_build_object(
      'child', 'Айдана', 'date', '01.10.2026', 'time', '10:00',
      'teacher', 'Нургуль Абдырахманова', 'left', '2', 'count', '2',
      'amount', public.format_som(200000), 'lessons', '5', 'low', '1',
      'debt', public.format_som(70000), 'overdue', '0'
    ))
  );
end;
$$;

comment on function public.preview_message(text, jsonb) is 'Предпросмотр шаблона на образцовых данных — тем же рендером, что и отправка.';


-- 7. Гранты -------------------------------------------------------------------------------------------

revoke all on function public.format_som(bigint)                             from public, anon, authenticated, service_role;
revoke all on function public.render_template(text, jsonb)                   from public, anon, authenticated, service_role;
revoke all on function public.event_messages(bigint)                         from public, anon, authenticated, service_role;
revoke all on function public.notification_targets(uuid, uuid, text)         from public, anon, authenticated, service_role;
revoke all on function public.notification_admin_targets(uuid, text)         from public, anon, authenticated, service_role;
revoke all on function public.notification_begin(bigint, uuid, text)         from public, anon, authenticated, service_role;
revoke all on function public.notification_finish(uuid, text, text, text)    from public, anon, authenticated, service_role;
revoke all on function public.notification_skip(bigint, text)                from public, anon, authenticated, service_role;
revoke all on function public.preview_message(text, jsonb)                   from public, anon, authenticated, service_role;

grant execute on function public.event_messages(bigint)                      to bot_worker;
grant execute on function public.notification_begin(bigint, uuid, text)      to bot_worker;
grant execute on function public.notification_finish(uuid, text, text, text) to bot_worker;
grant execute on function public.notification_skip(bigint, text)             to bot_worker;

grant execute on function public.preview_message(text, jsonb)                to authenticated;
