-- =============================================================================
-- 0047_lesson_note_delivery.sql — резюме занятия родителю, отказ диктовки
-- специалисту
--
-- Живая приёмка 22.09.2026 (этап 7, чек-лист п. 3): голосовое → черновик
-- заработало, а дальше цепочка рвётся в двух местах.
--
--   1. Утверждение заметки эмитит lesson.note_approved (триггер
--      lesson_notes_approval_transition, 0038), но в event_messages для
--      него нет ветки, в notification_event_types и message_templates —
--      строк. Родитель резюме не получает, событие уходит в skipped.
--   2. ai_job_fail (0042) эмитит lesson.voice_failed — та же судьба.
--      n8n/README.md обещал «доставка специалисту идёт обычным путём»,
--      обещание висело без реализации: специалист весь день видел
--      «нет ответа» и не знал, что диктовка упала.
--
-- Решения (ревью архитектора до написания):
--
--   Р1. {summary} — только в канал telegram. Переменные для render_template
--       собираются по каналу, а не один раз на ветку: иначе центр допишет
--       {summary} в шаблон whatsapp_link, n8n закроет строку как
--       no_channel с полным текстом резюме в notification_log.text, и
--       клиническое заключение окажется в журнале, который читает вся
--       администрация и копирует в личный WhatsApp. Дефолтный текст без
--       резюме — не защита (его перетирают), защита — то, что в этот канал
--       переменная приходит ПУСТОЙ (тот же принцип, что 0045 Р7). Именно
--       пустой, а не отсутствующей: render_template (0034) оставляет
--       неизвестный плейсхолдер в тексте буквально, и родитель без
--       Telegram получил бы «…готово: {summary}». Зеркало в интерфейсе —
--       whatsappPlaceholders без {summary}. Для lesson.voice_failed по той
--       же логике {child} пуст вне telegram.
--
--   Р2. Адресат lesson.voice_failed — не requested_by из строки запроса, а
--       результат запроса к memberships центра события на момент
--       доставки. Между диктовкой и доставкой — очередь и ретраи;
--       revoke_membership не трогает telegram_accounts (0033 Р1), и
--       уволенный получил бы в личный чат имя ребёнка центра. Для этого
--       заведён notification_user_targets(center, user, event_type):
--       plpgsql с проверкой auth.uid() is null (принимает произвольный
--       user_id, шире notification_targets по плательщику), без грантов
--       — её зовёт только definer event_messages. Правило «получатель
--       жив» — то же, что у круга 2 в 0045 Р12: owner/admin — по роли,
--       teacher — только с живой карточкой teachers через profile_id
--       (архивированная карточка при ещё не снятом членстве — период
--       оформления ухода, и имя ребёнка туда идти не должно). Инлайн был
--       бы второй копией этого правила, а 0045 Р9/Р10/Р12 — история именно
--       про разъехавшиеся копии.
--
--   Р3. Утвердить резюме без текста для родителя нельзя — в самом
--       триггере перехода, а не в approve_lesson_note. Прямой update от
--       authenticated закрыт с 0038 (revoke insert, update), но триггер
--       нужен не от него: инвариант держится и при гонке двух транзакций,
--       и при любом будущем пути к status='approved' не через эту RPC
--       (бэкфилл, definer-функция следующего этапа, возвращённый грант).
--       Триггер, а не check: констрейнт проверяется на существующих
--       строках и упал бы на уже утверждённых заметках без резюме в
--       staging. Проверка в ветке доставки остаётся вторым рубежом. Тест
--       0038 заводил заметку без parent_summary и утверждал её —
--       фикстура дополнена текстом.
--
--       Следствие, записанное как решение: «утверждено» теперь значит
--       одновременно «заморожено» (0038) и «резюме ушло родителю».
--       Чисто клиническая заметка без текста для родителя остаётся
--       черновиком — её никто не рассылает, и правки ей не мешают.
--       Отдельного статуса «заморожено без родителя» не заводится, пока
--       его не попросит владелец.
--
--   Р4. Обе новые ветки перечитывают состояние на момент доставки (как
--       0045 Р4). note_approved: заметка жива и утверждена, занятие не
--       отменено и не удалено (тот же фильтр, что student_notes_brief),
--       ребёнок не архивирован. voice_failed: не слать, если повтор
--       диктовки уже бессмыслен — условие дословно то же, по которому
--       ai_job_begin (0042) отказывается работать: заметка утверждена или
--       есть голосовой черновик ДРУГОЙ диктовки (специалист успел
--       надиктовать заново, и «попробуйте ещё раз» подвёл бы его к 23505).
--       Ручной черновик, начатый до диктовки, доставку НЕ гасит: голос
--       дополняет его (0042), повтор законен, и молчать здесь — значит
--       вернуть «нет ответа», ради которого миграция и написана.
--
--   Р5. Длина {summary} ограничена в SQL: Telegram режет сообщение на
--       4096 символах ошибкой 400, три попытки — и родителю ничего, а в
--       журнале английский текст Telegram. Обрезка в узле n8n была бы
--       логикой доставки вне SQL. Граница 3500 символов (length, не
--       octet_length — лимит Telegram в символах) с многоточием — запас
--       под остальной текст шаблона.
--
--   Р6. Сырая причина отказа (payload.reason — английский текст axios или
--       Postgres) в чат не идёт: правило «все тексты — на русском». Она
--       остаётся в ai_jobs.last_error и notification_log.
--
--   Р7. Шов: накопленные события обоих типов закрываются здесь же
--       (processed_at = now()), иначе первый claim_events после деплоя
--       разошлёт родителям резюме недельной давности, а специалистам —
--       «не удалось» про давно переписанные диктовки (0032 Р7, 0035 Р6).
--       На момент написания в staging необработанных нет (проверено
--       запросом), но деплой в другую базу этого не гарантирует.
--
--   Р8. subject_id = student_id в обеих ветках — обязанность, не опция:
--       notification_log_subject_required (0035) уронит вставку 22023 для
--       любого типа вне digest.daily/event.failed без subject_id.
--       Совпадение центра запроса и события в voice_failed — несущее:
--       notification_log_subject_fk ссылается на students (id, center_id).
--
--   Р9. Вторая утверждённая заметка по тому же занятию возможна
--       (lesson_notes_lesson_student_key частичный, where deleted_at is
--       null): архивировали, написали новую, утвердили — родитель получит
--       второе «Резюме занятия {date}». Это исправление, и оно должно
--       дойти; сознательно не гасится.
--
--  Р10. Та же дыра, что Р1, была открыта веткой выше в этой же функции:
--       report.monthly_ready (0043) отдавал {summary} в оба канала, а
--       интерфейс предлагал плейсхолдер для WhatsApp. Два соседних
--       правила в одной функции не могут противоречить друг другу — ветка
--       выровнена: текст отчёта только в telegram, вне его переменная
--       пуста. Зеркало в интерфейсе — whatsappPlaceholders без {summary}.
--
-- event_messages переиздаётся с базы 0045 (цепочка 0034 → 0035 drop+create
-- → 0043 → 0045; 0046 её не трогала). Сигнатура и состав колонок не
-- меняются — create or replace.

-- 1. Типы и шаблоны по умолчанию ---------------------------------------------------------------

insert into public.notification_event_types (event_type, description) values
  ('lesson.note_approved', 'Специалист утвердил резюме занятия'),
  ('lesson.voice_failed',  'Голосовое резюме не обработалось')
on conflict (event_type) do nothing;

-- insert … where not exists, а не on conflict — см. 0045: частичный индекс
-- по умолчанию 0034 не даёт вывести конфликт (42P10).
insert into public.message_templates (center_id, event_type, channel, text)
select v.center_id, v.event_type, v.channel, v.text
  from (values
    (null::uuid, 'lesson.note_approved', 'telegram',
     E'Резюме занятия {date} для {child}:\n\n{summary}'),
    -- Р1: без {summary} — канал no_channel, строка живёт в журнале и в
    -- интерфейсе; сам текст резюме туда не подставится даже если центр
    -- допишет плейсхолдер.
    (null::uuid, 'lesson.note_approved', 'whatsapp_link',
     'Здравствуйте! Резюме занятия {date} для {child} готово. Посмотрите в приложении LogoCRM.'),
    -- Р6: без причины. Р1: {child} только в telegram.
    (null::uuid, 'lesson.voice_failed', 'telegram',
     'Голосовое по {child} обработать не удалось. Попробуйте записать ещё раз с экрана занятия.'),
    (null::uuid, 'lesson.voice_failed', 'whatsapp_link',
     'Голосовое обработать не удалось — откройте LogoCRM.')
  ) as v(center_id, event_type, channel, text)
 where not exists (
   select 1 from public.message_templates m
    where m.center_id is null
      and m.event_type = v.event_type
      and m.channel = v.channel
      and m.deleted_at is null
 );


-- 2. Адресация конкретному пользователю центра (Р2) --------------------------------------------

create or replace function public.notification_user_targets(
  p_center_id  uuid,
  p_user_id    uuid,
  p_event_type text
)
  returns table (user_id uuid, channel text, chat_id bigint, template_text text)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  -- Функция принимает произвольный user_id — доступна только контуру
  -- воркера без сессии, как event_messages.
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return query
    select m.user_id,
           case when a.chat_id is null then 'whatsapp_link' else 'telegram' end,
           a.chat_id,
           rt.message_text
      from public.memberships m
      left join public.telegram_accounts a
             on a.user_id = m.user_id and a.unlinked_at is null
      join lateral public.resolve_template(
             p_center_id, p_event_type,
             case when a.chat_id is null then 'whatsapp_link' else 'telegram' end
           ) rt on true
     where m.center_id = p_center_id
       and m.user_id = p_user_id
       -- Р2: то же правило «специалист жив», что у круга 2 в 0045 —
       -- owner/admin по роли, teacher только с живой карточкой.
       and (
         m.role in ('owner', 'admin')
         or (m.role = 'teacher' and exists (
              select 1 from public.teachers t
               where t.profile_id = m.user_id
                 and t.center_id = p_center_id
                 and t.deleted_at is null))
       )
       and rt.should_send;
end;
$$;

comment on function public.notification_user_targets(uuid, uuid, text) is
  'Получатель — конкретный сотрудник центра, живой на момент доставки (0047 Р2): членство и живая карточка специалиста проверяются здесь, а не берутся из payload события. Грантов нет — зовёт только event_messages.';

revoke all on function public.notification_user_targets(uuid, uuid, text)
  from public, anon, authenticated, service_role;


-- 3. Утверждение без резюме для родителя невозможно (Р3) ---------------------------------------

create or replace function public.lesson_notes_approval_transition()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.status = 'approved' and new.status <> 'approved' then
    raise exception 'Утверждённое резюме нельзя вернуть в черновик: родитель его уже видел'
      using errcode = '23514';
  end if;

  if new.status = 'approved' then
    if tg_op = 'INSERT' or old.status <> 'approved' then
      -- 0047 Р3: утверждение — момент, после которого резюме уходит
      -- родителю; без текста утверждать нечего.
      if coalesce(trim(new.parent_summary), '') = '' then
        raise exception 'Нельзя утвердить заметку без резюме для родителя'
          using errcode = '23514';
      end if;
      new.approved_at := now();
      new.approved_by := auth.uid();
      perform public.emit_clinical_event('lesson.note_approved',
        jsonb_build_object('center_id', new.center_id, 'lesson_note_id', new.id,
          'student_id', new.student_id, 'lesson_id', new.lesson_id),
        new.center_id);
    else
      -- Уже было утверждено: метку и автора не переписывают.
      new.approved_at := old.approved_at;
      new.approved_by := old.approved_by;
    end if;
  else
    new.approved_at := null;
    new.approved_by := null;
  end if;

  return new;
end;
$$;

revoke all on function public.lesson_notes_approval_transition() from public, anon, authenticated, service_role;


-- 4. Доставка: две новые ветки перед общей цепочкой --------------------------------------------

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
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4), с 0047 — только в telegram. Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. lesson.note_approved (0047) — резюме родителю, {summary} только в telegram и не длиннее 3500 символов; lesson.voice_failed (0047) — заказчику диктовки через notification_user_targets, без причины отказа и только пока повтор диктовки имеет смысл (условие ai_job_begin). Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;


-- 5. Шов (Р7) -----------------------------------------------------------------------------------

update public.events
   set processed_at = now()
 where processed_at is null
   and type in ('lesson.note_approved', 'lesson.voice_failed');
