-- =============================================================================
-- 0035_reminder_confirm_button.sql — кнопка «Подтвердить приход» под
-- напоминанием (этап 6, доделка после приёмки)
--
-- Найдено на живой приёмке 18.09.2026: напоминание родителю доходит, а
-- ответить на него нечем. Бот умеет принимать нажатие (0033,
-- confirm_lesson), таблица подтверждений есть, карточка занятия их
-- показывает — но прикрепляет кнопку n8n, а данных для неё в ответе
-- event_messages не было вовсе. pgTAP этого не поймал: он проверял
-- confirm_lesson напрямую, а не путь «событие → сообщение с кнопкой».
--
-- Решения:
--   Р1. Данные кнопки отдаёт SQL целиком — строкой callback_data и
--       подписью. n8n копирует их в reply_markup как есть, ничего не
--       собирая: формат callback_data разбирает бот, и чем меньше мест,
--       где он пишется руками, тем лучше.
--   Р2. Формат — `c:<event_id>:<student_id>`, а НЕ пара uuid занятия и
--       ребёнка. Telegram ограничивает callback_data 64 байтами, а два
--       uuid с префиксом дают 81: кнопка из первой редакции не отправилась
--       бы вовсе, и это выяснилось бы уже на живом чате. event_id —
--       bigint, занятие из него достаёт confirm_lesson_by_event.
--   Р3. Уникальность в журнале получает ребёнка. Было
--       `(event_id, recipient_user_id, channel)`; у родителя двоих детей в
--       одном групповом занятии второе сообщение попадало на ту же строку
--       и молча не отправлялось — notification_begin отвечал «уже ушло».
--       Нашлось при разборе кнопки, не тестом: 0034 проверял двух РАЗНЫХ
--       родителей, а не одного с двумя детьми.
--   Р4. `subject_id` — nullable и с `nulls not distinct`: у сводки и у
--       строки «получателей нет» ребёнка нет, и они не должны копиться.
--   Р5. Обязательность ребёнка — триггер, а не строчка в инструкции n8n.
--       Иначе узел сценария, потерявший маппинг `p_subject_id`, вернул бы
--       дедуп к прежнему поведению: второе сообщение родителю молча не
--       уходит, и в журнале этого не видно. Список исключений — обратный
--       (сводка и отказ обработки), чтобы новый тип события был защищён по
--       умолчанию, а не забыт.
--   Р6. Строки, записанные ДО этой миграции, имеют пустой `subject_id` и по
--       новому ключу не находятся. Если в этот момент в очереди висит
--       необработанное напоминание, родитель получил бы его второй раз —
--       ключи разные, констрейнт молчит. Поэтому `notification_begin`
--       сначала ищет по новому ключу, а затем — старую строку без ребёнка
--       в терминальном статусе. Шов временный: он перестанет что-либо
--       находить, как только такие строки состарятся.
--   Р7. Кнопка живёт не вечно. Событие уходит за 18 часов до занятия, и без
--       проверки родитель мог бы подтвердить приход на вчерашнее занятие,
--       уже проведённое или отменённое.
-- =============================================================================


-- 1. Журнал: ребёнок как часть ключа ---------------------------------------------------------

alter table public.notification_log
  add column if not exists subject_id uuid;

comment on column public.notification_log.subject_id is
  'О ком сообщение. Часть ключа против дубля: у родителя двоих детей в одном занятии сообщений два, и они не должны схлопнуться в одно (0035 Р3).';

alter table public.notification_log
  drop constraint if exists notification_log_once;

alter table public.notification_log
  add constraint notification_log_once
  unique nulls not distinct (event_id, recipient_user_id, channel, subject_id);

-- Составной FK, как во всех таблицах после 0022: ошибка маппинга в сценарии
-- иначе положила бы в журнал центра ребёнка другого центра, а журнал читает
-- администрация.
alter table public.notification_log
  drop constraint if exists notification_log_subject_fk;
alter table public.notification_log
  add constraint notification_log_subject_fk
  foreign key (subject_id, center_id) references public.students (id, center_id) on delete cascade;


-- Р5: список обратный — тип, которого здесь нет, считается сообщением о
-- ребёнке и обязан нести subject_id. Так новый тип события защищён по
-- умолчанию, а не забыт, — тот же приём, что у забора политик в 0031.
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
          and e.type not in ('digest.daily', 'event.failed')
     )
  then
    raise exception 'Уведомление о ребёнке не может быть без subject_id'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists notification_log_subject_required on public.notification_log;
create trigger notification_log_subject_required
  before insert or update on public.notification_log
  for each row execute function public.notification_log_subject_required();

revoke all on function public.notification_log_subject_required() from public, anon, authenticated, service_role;


-- 2. Событие → сообщения, теперь с ребёнком и кнопкой -----------------------------------------

-- Меняется состав возвращаемых колонок, поэтому drop + create, а не
-- create or replace: у второго нельзя изменить тип результата.
drop function if exists public.event_messages(bigint);

create function public.event_messages(p_event_id bigint)
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
  v_event   public.events;
  v_tz      text;
  v_vars    jsonb := '{}'::jsonb;
  v_student uuid;
  v_payer   uuid;
  v_lesson  record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if not found then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  v_tz := public.center_timezone(v_event.center_id);

  -- Р3 из 0034: белый список. Всё, чего здесь нет, получателей не имеет, и
  -- воркер обязан записать это в журнал строкой skipped, а не промолчать.
  if v_event.type = 'lesson.reminder' then
    select l.starts_at, l.status, l.deleted_at, coalesce(t.full_name, '—') as teacher
      into v_lesson
      from public.lessons l
      left join public.teachers t on t.id = l.effective_teacher_id
     where l.id = (v_event.payload ->> 'lesson_id')::uuid;

    -- Событие ставится в очередь за 18 часов, и занятие успевают отменить
    -- или удалить. «Напоминаем, завтра занятие» в этом случае — неправда,
    -- а раньше отсутствие строки просто обнуляло v_vars, и родителю уходил
    -- текст с неподставленными {time} и {child}.
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
             -- Р1, Р2: n8n копирует это в reply_markup как есть.
             case when r.chat_id is null then null else jsonb_build_object(
               'label', 'Подтвердить приход',
               'callback_data', 'c:' || v_event.id::text || ':' || p.student_id::text
             ) end
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
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). subject_id — о ком сообщение, часть ключа журнала; action — готовые данные кнопки, которые n8n кладёт в reply_markup как есть (0035). Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;


-- 3. Захват отправки — с ребёнком ---------------------------------------------------------------

drop function if exists public.notification_begin(bigint, uuid, text);

create function public.notification_begin(
  p_event_id   bigint,
  p_recipient  uuid,
  p_channel    text,
  p_subject_id uuid default null
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
     and l.channel = p_channel
     and l.subject_id is not distinct from p_subject_id;

  if not found and p_subject_id is not null then
    -- Р6: строка, записанная до 0035, ребёнка не знает. Если она уже
    -- терминальная, сообщение уходило — второй раз не шлём.
    select * into v_row from public.notification_log l
     where l.event_id = p_event_id
       and l.recipient_user_id is not distinct from p_recipient
       and l.channel = p_channel
       and l.subject_id is null
       and l.status in ('sent', 'no_channel', 'skipped');

    if found then
      return null;
    end if;
  end if;

  if v_row.id is null then
    -- on conflict, а не голый insert: два прогона по одному событию видят
    -- «строки нет» одновременно, и второй получил бы 23505 без объяснения.
    insert into public.notification_log (center_id, event_id, recipient_user_id, channel, status, subject_id)
    values (v_center, p_event_id, p_recipient, p_channel, 'pending', p_subject_id)
    on conflict on constraint notification_log_once do nothing
    returning id into v_row.id;

    if v_row.id is not null then
      return v_row.id;
    end if;

    select * into v_row from public.notification_log l
     where l.event_id = p_event_id
       and l.recipient_user_id is not distinct from p_recipient
       and l.channel = p_channel
       and l.subject_id is not distinct from p_subject_id;
  end if;

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

comment on function public.notification_begin(bigint, uuid, text, uuid) is
  'Захватить отправку: заводит строку pending или возвращает null, если сообщение уже ушло либо исчерпало попытки. Вызывается ДО отправки — иначе защиты от дубля нет (0034 Р4). subject_id — ребёнок, о котором сообщение (0035 Р3).';

revoke all on function public.notification_begin(bigint, uuid, text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.notification_begin(bigint, uuid, text, uuid) to bot_worker;


-- 4. Подтверждение по событию -------------------------------------------------------------------

-- Бот получает из кнопки событие и ребёнка; занятие достаётся отсюда.
-- Проверки прав не дублируются — вся работа у confirm_lesson (0033).
create or replace function public.confirm_lesson_by_event(
  p_chat_id    bigint,
  p_event_id   bigint,
  p_student_id uuid
)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_lesson uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select (e.payload ->> 'lesson_id')::uuid into v_lesson
    from public.events e
   where e.id = p_event_id and e.type = 'lesson.reminder';

  if v_lesson is null then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;

  -- Р7: кнопка в переписке остаётся навсегда, занятие — нет.
  if not exists (
    select 1 from public.lessons l
     where l.id = v_lesson
       and l.deleted_at is null
       and l.status = 'planned'
       and l.starts_at > now()
  ) then
    raise exception 'Занятие уже прошло или отменено' using errcode = '22023';
  end if;

  return public.confirm_lesson(p_chat_id, v_lesson, p_student_id);
end;
$$;

comment on function public.confirm_lesson_by_event(bigint, bigint, uuid) is
  'Подтверждение прихода из кнопки: занятие достаётся из события, потому что пара uuid в callback_data не помещается в лимит Telegram (0035 Р2).';

revoke all on function public.confirm_lesson_by_event(bigint, bigint, uuid) from public, anon, authenticated, service_role;
grant execute on function public.confirm_lesson_by_event(bigint, bigint, uuid) to bot_worker;
