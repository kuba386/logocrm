-- =============================================================================
-- 0073_digest_payments.sql — утренняя сводка: поступления за вчера
--
-- Решение владельца 27.09.2026 (вторая половина «финансы в Telegram»): к
-- сводке владельцу/администраторам (digest.daily) добавляется строка про
-- поступления за день ДО даты сводки. Только просмотр — как /cash (0072).
--
-- Ревью architect (план) нашёл восемь мест; ниже решения.
--
--   Р1. Сумма считается в event_messages ПРИ ДОСТАВКЕ, а не кладётся в
--       payload. emit_event открыта любой роли центра и проверяет только
--       членство, не тип события: родитель мог бы отправить digest.daily с
--       подделанной цифрой, и владелец прочитал бы её под подписью
--       настоящей сводки. Центр берётся из строки events (проверен при
--       emit), дата — из payload: подделка даты ничего не раскрывает —
--       получатели те же owner/admin, которым это видно и так. Побочные
--       плюсы: daily_digest не переиздаётся (0032 остаётся последней), у
--       событий, уже стоящих в очереди, будет настоящая цифра, контракт
--       payload не меняется. Отдельная задача, не здесь: запретить
--       emit_event системные типы при auth.uid() is not null.
--   Р2. event_messages переиздаётся побайтово от последней редакции (0057,
--       проверено поиском по всем миграциям): отличие — только ветка
--       digest.daily (ключ payments + lateral-вызов center_payments_day) и
--       текст comment on function. center_payments_day (0072, SECURITY
--       INVOKER, без грантов) зовётся из definer-функции от имени
--       владельца — гранта воркеру не нужно.
--   Р3. Текст переменной {payments}: «за ДД.ММ: 1 250,00 сом (операций: N)»
--       или «за ДД.ММ: платежей не было». Дата — в самой строке: сводка,
--       доставленная после простоя воркера, иначе сказала бы «за вчера»
--       про позавчера. Слово «касса» не используется (docs/Database.md,
--       «Два слова, два определения») — «Поступления».
--   Р4. preview_message (экран настроек) переиздана с образцом payments:
--       иначе предпросмотр показал бы «{payments}» буквально, нарушив
--       собственное обещание «тот же рендер, что уходит в сообщении».
--       Тело — от 0034 побайтово плюс один ключ.
--   Р5. Дефолты платформы обновляются по ТОЧНОМУ совпадению старого текста
--       (deleted_at is null, оба канала): кто правил дефолт руками, не
--       затрагивается. Если обновлено не две строки — warning, а не тихий
--       ноль. Строки центров с ТОЧНОЙ копией старого дефолта обновляются
--       тоже: saveTemplate при любом сохранении (даже переключении
--       «Отправлять») пишет строку центра с полным текстом формы, и
--       владелец, ничего не менявший, иначе остался бы без новой строки
--       молча, хотя экран показывает текст как «свой». Тексты центров,
--       где хоть один знак отличается, не тронуты. Правки в audit_log с
--       user_id = null. Выбор записан в CHANGELOG и docs/Database.md (у
--       вспомогательной работы вне этапа отчёта reports/ нет).
--   Р6. Старое расхождение, не чинится здесь: {debt} сводки — только
--       debt_tiyin (daily_digest, 0032), без перерасхода и просрочки по
--       абонементам, а /debts (0072) показывает «долг за занятия» = долг +
--       перерасход и отдельно просрочку. В отчёте записано как долг.
--
--   Р7. Центр в вызове center_payments_day — ТОЛЬКО events.center_id (его
--       проверяет emit_event), не payload->>'center_id': payload кладётся как
--       есть, и иначе родитель центра A читал бы поступления центра Б через
--       владельца A. pgTAP держит событие с чужим center_id в payload.
--
-- Таблиц нет — deny-list экспорта не затрагивается.
-- =============================================================================


-- 1. event_messages: ветка digest.daily (Р1–Р3) ---------------------------------------

-- Переиздаётся целиком от последней редакции (0057): поиск
-- "create or replace function public.event_messages" по всем миграциям.
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

  -- 0053 Р8/Р10: лимит голосовых резюме — заказчику диктовки ({child} только
  -- в telegram, с предлогом внутри) и owner/admin центра (без {child}, без
  -- subject), пока повтор диктовки имеет смысл (0047 Р4). Заказчик-владелец
  -- не получает двух строк.
  if v_event.type = 'ai.quota_exceeded' then
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

    v_vars := jsonb_build_object(
      'used',  coalesce(v_event.payload ->> 'used', ''),
      'limit', coalesce(v_event.payload ->> 'limit', '')
    );

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               v_vars || jsonb_build_object('child',
                 case when r.channel = 'telegram' then ' по ' || v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r
      union all
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', '')),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r
       where r.user_id <> v_request.requested_by;
    return;
  end if;

  -- 0052: срок заканчивается / истёк — owner/admin центра. {when} и {until}
  -- считаются на момент доставки в поясе центра (Р6).
  if v_event.type in ('subscription.ending', 'subscription.expired') then
    v_days := ((v_event.payload ->> 'until')::timestamptz at time zone v_tz)::date
              - (now() at time zone v_tz)::date;
    v_vars := jsonb_build_object(
      'what',  case when (v_event.payload ->> 'is_trial')::boolean then 'Пробный период' else 'Подписка' end,
      'until', to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY')
    );
    -- {when} есть только у «заканчивается»: у истёкшего срока «сегодня» врало бы.
    if v_event.type = 'subscription.ending' then
      v_vars := v_vars || jsonb_build_object('when', case
                 when v_days <= 0 then 'сегодня'
                 when v_days = 1 then 'завтра'
                 else 'через ' || v_days::text || ' дн.'
               end);
    end if;
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

  -- 0056: заявка на удаление центра — owner/admin (в т.ч. второй владелец,
  -- который её не подавал), без {until}.
  if v_event.type = 'center.deletion_requested' then
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, '{}'::jsonb),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0057: заявка с публичной витрины записи — стойке (owner/admin/
  -- registrar, notification_front_desk_targets — не notification_admin_
  -- targets, регистратор реально разбирает очередь). {child}/{teacher}/
  -- {when}/{phone} читаются заново на момент доставки, не из payload —
  -- заявку могли обработать до отправки, а специалиста переименовать.
  if v_event.type = 'booking.requested' then
    declare
      v_booking      public.booking_requests;
      v_teacher_name text;
    begin
      -- emit_event открыта authenticated и проверяет только center_id
      -- аргумента — payload не доверенный ключ, откуда читать. Без фильтра
      -- по center_id участник центра X мог бы эмитировать событие с
      -- request_id чужой заявки и получить в свой телеграм имя ребёнка и
      -- телефон родителя центра Y (архитектор, раунд 3, п.3).
      select * into v_booking from public.booking_requests
       where id = (v_event.payload ->> 'request_id')::uuid
         and center_id = v_event.center_id
         and deleted_at is null;
      if not found then
        return;
      end if;

      select t.full_name into v_teacher_name from public.teachers t where t.id = v_booking.teacher_id;

      v_vars := jsonb_build_object(
        'child', v_booking.child_name,
        'teacher', coalesce(v_teacher_name, 'специалист'),
        'when', to_char(v_booking.starts_at at time zone v_tz, 'DD.MM HH24:MI'),
        'phone', v_booking.parent_phone
      );

      return query
        select r.user_id, r.channel, r.chat_id,
               public.render_template(r.template_text, v_vars),
               null::uuid,
               null::jsonb
          from public.notification_front_desk_targets(v_event.center_id, v_event.type) r;
      return;
    end;
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
               'overdue', coalesce(v_event.payload ->> 'installments_overdue', '0'),
               -- 0073: поступления за день ДО даты сводки — из базы на момент
               -- доставки, не из payload (emit_event открыта любой роли центра:
               -- цифра из payload подделывалась бы). Дата в самой строке —
               -- доставка бывает позже утра.
               'payments', 'за ' || to_char((v_event.payload ->> 'date')::date - 1, 'DD.MM') || ': '
                           || case when (pay.p ->> 'ops')::integer = 0
                                   then 'платежей не было'
                                   else public.format_som((pay.p ->> 'total_tiyin')::bigint)
                                        || ' (операций: ' || (pay.p ->> 'ops') || ')' end
             )),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r
       cross join lateral (
         select public.center_payments_day(v_event.center_id, (v_event.payload ->> 'date')::date - 1) as p
         offset 0
       ) pay;
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
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4), с 0047 — только в telegram. Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. lesson.note_approved (0047) — резюме родителю, {summary} только в telegram и не длиннее 3500 символов; lesson.voice_failed (0047) — заказчику диктовки через notification_user_targets, без причины отказа и только пока повтор диктовки имеет смысл (условие ai_job_begin). 0051: platform.payment_submitted — администраторам платформы (notification_platform_targets, шаблон только дефолтный), subscription.extended — owner/admin центра с {until} в поясе центра, subscription.voice_blocked — заказчику диктовки, {child} только в telegram. 0052: subscription.ending/expired — owner/admin центра, {what}/{until}/{when} на момент доставки в поясе центра. 0053: ai.quota_exceeded — заказчику диктовки ({child} с предлогом, только telegram) и owner/admin центра без {child}, {used}/{limit} в оба канала, пока повтор диктовки имеет смысл. 0056: center.deletion_requested — owner/admin центра, без переменных. 0057: booking.requested — стойке (owner/admin/registrar) через notification_front_desk_targets, {child}/{teacher}/{when}/{phone} читаются заново из booking_requests на момент доставки, не из payload. Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать. 0073: digest.daily — {payments} («за ДД.ММ: сумма (операций: N)» или «платежей не было») считается из платежей на момент доставки (center_payments_day), не из payload.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;


-- 2. preview_message: образец {payments} (Р4) --------------------------------------------

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
      'debt', public.format_som(70000), 'overdue', '0',
      'payments', 'за 30.09: ' || public.format_som(1250000) || ' (операций: 7)'
    ))
  );
end;
$$;

comment on function public.preview_message(text, jsonb) is 'Предпросмотр шаблона на образцовых данных — тем же рендером, что и отправка.';

revoke all on function public.preview_message(text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.preview_message(text, jsonb) to authenticated;


-- 3. Тексты сводки (Р5) ----------------------------------------------------------------

do $$
declare
  v_old   constant text := 'Сводка на {date}: занятий сегодня — {lessons}, заканчивается абонементов — {low}, долг — {debt}, просроченных рассрочек — {overdue}.';
  v_new   constant text := v_old || ' Поступления {payments}.';
  v_n_def integer;
begin
  update public.message_templates
     set text = v_new
   where center_id is null
     and event_type = 'digest.daily'
     and channel in ('telegram', 'whatsapp_link')
     and deleted_at is null
     and text = v_old;
  get diagnostics v_n_def = row_count;

  if v_n_def <> 2 then
    raise warning '0073: обновлено % дефолтов сводки вместо 2 — текст дефолта правили вручную? Проверить message_templates', v_n_def;
  end if;

  -- Центры с точной копией старого дефолта (Р5).
  update public.message_templates
     set text = v_new
   where center_id is not null
     and event_type = 'digest.daily'
     and channel in ('telegram', 'whatsapp_link')
     and deleted_at is null
     and text = v_old;
end;
$$;

comment on function public.center_payments_day(uuid, date) is
  'Поступления центра за день: сумма payments по paid_at в поясе центра, полуинтервал [день, день+1), знак — часть суммы, расходы не входят (0072 Р8/Р9). Внутренняя (SECURITY INVOKER, 0072 Р13): без сессии и без грантов, зовут bot_cash (0072) и ветка digest.daily в event_messages (0073) от имени владельца; центр — только из вызывающей definer-функции (для сводки — events.center_id, не payload), никогда от пользователя.';
