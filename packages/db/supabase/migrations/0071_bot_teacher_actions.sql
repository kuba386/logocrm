-- =============================================================================
-- 0071_bot_teacher_actions.sql — два действия специалиста в Telegram-боте:
-- отметить посещение кнопками и заметка к занятию текстом
--
-- Решение владельца 26.09.2026: работать с телефона — через бот, но только
-- там, где действие укладывается в кнопку или одно сообщение; формы
-- (речевая карта, расписание, деньги) остаются на экране. Ровно два
-- действия, ДЗ и напоминания отклонены на этом шаге.
--
-- Два раунда ревью architect (план и написанный SQL). Первый раунд нашёл
-- два блокера, из-за которых план в исходном виде не работал бы вовсе:
--
--   Р1. Отметка из контура без сессии падала бы на 42501 «Требуется
--       авторизация» в 100% случаев: AFTER-триггер attendance_recalc_trigger
--       (0010) и check_absent_streak (0010) зовут emit_event, а emit_event
--       (0002) первой строкой требует auth.uid(). Сессия у бота — bot_worker
--       без JWT пользователя. Гейт emit_event нужен, чтобы authenticated не
--       подделывал события прямым RPC; триггеру (security definer, огонь
--       только от записи, уже прошедшей свои проверки) он не нужен.
--       Раздел 0: emit_event_internal без проверки сессии, без грантов
--       вообще — вызывается только из тел definer-триггеров; оба триггера
--       переизданы ДОСЛОВНО с последних редакций 0010, заменён только
--       эмиттер. emit_event_unchecked не подходит: он, наоборот, отвергает
--       сессию, а те же триггеры идут и с экрана.
--   Р2. События посещения (attendance.marked, attendance.no_subscription,
--       subscription.low_balance/exhausted/overdrawn, student.absent_streak)
--       эмитит ТРИГГЕР, а не mark_attendance — поэтому в редакции 0026 их не
--       видно. Путь бота обязан давать тот же набор событий, что экран:
--       родителю уходит «абонемент заканчивается» из шаблонов 0034/0037.
--       Ничего не подавляется и не дублируется — pgTAP держит.
--   Р3. Заметка из бота — с явным created_by = пользователь чата и явным
--       center_id: дефолты auth.uid()/current_center() в контуре бота пусты,
--       а approve_lesson_note (0042) пускает утверждение только автору или
--       owner/admin — специалист не смог бы утвердить собственную заметку
--       (та же ловушка, что 0041 Р2, прецедент — ai_write_lesson_note).
--   Р4. Контекст «чат X ждёт следующего шага» — таблица bot_pending_actions,
--       обобщение lesson_voice_requests (0041) на два вида действий. Нужна
--       из-за лимита 64 байта на callback_data (0035 Р2): пара uuid в кнопку
--       не помещается, кнопка несёт один uuid, второй лежит в контексте.
--       Один живой контекст на чат (частичный unique), новое армирование
--       гасит предыдущее. Строки не удаляются никогда (правило проекта;
--       уборки нет и у telegram_link_codes/lesson_voice_requests) — это
--       единственный след действий с телефона, аудита на таблице нет (0042
--       В4: chat_id не должен попадать в audit_log, который читают
--       owner/admin). Под readonly guard — ради двустороннего забора 0050
--       (для бота триггер no-op, решение записано).
--   Р5. Все мутирующие bot_*-функции начинаются с pg_advisory_xact_lock по
--       чату (двухаргументная форма, своё пространство ключей, не
--       пересекается с check_absent_streak): вебхук отвечает 200 сразу и
--       доигрывает в фоне, Telegram повторяет апдейты — параллельные вызовы
--       одного чата реальны. Без блокировки гонка на частичном unique
--       отдала бы наружу голый 23505, а for update skip locked — текст про
--       другое действие.
--   Р6. Бот НЕ переписывает существующую отметку другим статусом: тот же
--       статус — идемпотентный успех (changed=false), другой — читаемый
--       отказ «изменить можно на экране». Смена статуса — запись о деньгах
--       (deducted следует за статусом, lessons_used пересчитывается), а
--       автора смены в контуре бота не фиксирует ничто: marked_by заморожен
--       триггером на первом человеке, audit_log.user_id пуст. Решение (а) из
--       ревью — дешевле и совпадает с «ровно два действия».
--   Р7. Гашение контекста — последним шагом ПОСЛЕ успешной записи, а
--       обработчик unique_violation (гонка двух чатов на одной паре
--       занятие/ребёнок) — вложенным блоком только вокруг insert. Блок с
--       exception на уровне функции (стиль mark_attendance 0026) — это
--       подтранзакция: при перехвате откатилось бы и гашение контекста, и
--       «один живой контекст на чат» стал бы ложью.
--   Р8. Занятие должно быть СЕГОДНЯШНИМ в поясе центра — на armировании и
--       повторно на каждом шаге. Кнопка в переписке живёт дольше занятия
--       (0035 Р7): через неделю нажатие под старым /today поставило бы
--       посещение задним числом со списанием абонемента. Для заметки — то
--       же окно, сознательно: заметка «по горячим следам» с телефона, всё
--       остальное — на экране.
--   Р9. Права — только белым списком ролей (0026 добавил registrar/finance,
--       «не parent» открыл бы finance, которому 0031 закрыл lessons):
--       посещение — owner/admin/registrar или ведущий специалист
--       (membership.teacher_id = lessons.effective_teacher_id, замена
--       считается ведущим), как у экрана mark_attendance; заметка —
--       owner/admin или ведущий, как у write_lesson_note. Права
--       перепроверяются на КАЖДОМ шаге (arm/pick/mark/write): отзыв
--       членства между шагами (revoke_membership удаляет строку физически,
--       0033 Р1) не должен проходить через уже выданный список детей.
--   Р10. Архивный ребёнок не выдаётся в список участников и отказывается на
--       выборе/записи — как clinical_teacher_sees на экране заметок; для
--       посещения экран (mark_attendance) архив не проверяет, бот здесь
--       строже сознательно: список детей формируется ботом, а не человеком.
--   Р11. Read-only центр: guard 0050 контур бота не покрывает (ADR-011,
--       «Известные границы»), поэтому center_writable проверяется явно в
--       каждой мутирующей функции, код PT402 (тот же, что у guard, errors.ts
--       его знает), текст — по center_write_state и роли, как в guard 0056
--       Р7/Р9: «удалён» — не «истекла подписка», «оплатите» читает только
--       тот, кто может оплатить.
--   Р12. Печатный текст не затирает оплаченную диктовку: ai_write_lesson_note
--       (0042) пишет SOAP только в ПУСТОЙ черновик. Если по паре
--       занятие/ребёнок есть живой lesson_voice_requests — отказ «ждём
--       голосовое»; иначе набранная в чате строка сделала бы разбор
--       Whisper+Claude (уже оплаченный) молча выброшенным. Текст ложится в
--       soap.objective («Что делали»): raw_transcript — расшифровка голоса,
--       parent_summary уходит родителю после утверждения. В существующий
--       черновик — дописывается через перевод строки, source не меняется
--       (признак происхождения ПЕРВОЙ версии); утверждённый — 23514, тот же
--       текст, что у write_lesson_note. Заметка из бота остаётся черновиком:
--       утверждение требует parent_summary (0047 Р3), а его бот не пишет —
--       резюме родителю пишет человек на экране; бот так и отвечает.
--   Р13. bot_today переиздана (drop+create — return table меняется):
--       can_mark/can_note для кнопок и starts_local — метка времени из SQL
--       в поясе центра (`to_char(... at time zone center_timezone)`). До
--       этого бот форматировал сырой timestamptz с timeZone 'UTC' под
--       комментарием «база уже отдаёт в поясе центра» — комментарий не
--       соответствовал коду, Бишкек видел 09:00 вместо 15:00. Правило 9
--       общего списка: время рендерится в поясе центра, и раз кнопки
--       различаются по времени занятия — оно обязано быть верным.
--   Р14. TTL контекста: посещение — 15 минут, заметка — 3: «любой текст без
--       `/` в течение окна → в карту ребёнка» без корреляции по reply, и
--       сообщение, адресованное человеку, не должно лечь в клиническую
--       запись, которую нельзя удалить (только архивировать RPC owner/admin).
--       Эхо с именем ребёнка и первыми словами — обязательная часть ответа.
--   Р15. Инвариант «выбранный ребёнок — участник этого занятия» держат
--       bot_pick_student/bot_mark_attendance/bot_write_note, НЕ составной FK
--       (student_id, center_id): при student_id is null FK (MATCH SIMPLE)
--       не проверяется вовсе, а сам по себе он говорит только «ребёнок того
--       же центра». Вторые рубежи — триггеры attendance_fill_and_check и
--       lesson_notes_check_participant.
--
-- Второй раунд ревью (написанный SQL) добавил:
--   Р16. bot_pending_actions — в deny-list экспорта export_center_excluded_
--       tables() (переиздан с редакции 0064, не 0056 — иначе молча выпала бы
--       assistant_requests): chat_id не должен уезжать в выгрузку, которую
--       скачивает owner/admin (тот же аргумент, что отказ от аудита в Р4);
--       результат действия уже в attendance/lesson_notes, они в allow-list.
--       Без этого забор 0056 «каждая таблица с center_id — в одном из двух
--       списков» красный.
--   Р17. «Ждём диктовку» — весь жизненный цикл запроса, не «до прихода
--       файла»: report_voice_note (0042) ставит consumed_at в момент прихода
--       голосового, ДО Whisper+Claude. С прежним предикатом специалист, не
--       дождавшийся 40 секунд, набирал текст, а пришедший следом
--       ai_write_lesson_note молча выбрасывал SOAP модели (пишет только в
--       пустой soap). Живой = не отменён и (не погашен и не протух, ЛИБО
--       погашен < 24 ч назад — окно ai_write_lesson_note — и заметки с
--       conduct_key = request.id ещё нет, и работа ИИ не failed).
--   Р18. bot_write_note: (а) вложенный обработчик unique_violation вокруг
--       insert — owner и ведущий из двух чатов одновременно (advisory lock
--       по чату разные чаты не сериализует), иначе наружу уходил бы голый
--       23505 латиницей; (б) дописать чужой черновик нельзя — created_by
--       остался бы первым автором, audit_log.user_id в контуре бота пуст,
--       колонки «кто правил» нет: автор утвердил бы слова, которых не
--       писал; (в) корреляция ForceReply — prompt_message_id в контексте и
--       p_reply_to из апдейта: ответ на устаревший промпт (нажали «Заметка»
--       под A, потом под B, ответили на первый) иначе ложился бы в карту
--       не того ребёнка, а удалить клиническую запись нельзя.
--   Р19. attendance_recalc_trigger/check_absent_streak — без грантов ни у
--       кого, включая bot_worker и service_role: check_absent_streak берёт
--       center_id ПАРАМЕТРОМ, и раньше за ней стоял role_in() в emit_event;
--       теперь единственный рубеж — «эту функцию не вызывает никто, кроме
--       триггера». Контракт emit_event_internal: center_id только из строки,
--       породившей событие, никогда из параметра вызывающего.
--
-- Разделы:
--   0. emit_event_internal + переиздание attendance_recalc_trigger и
--      check_absent_streak с последних редакций 0010 (Р1/Р2/Р19).
--   1. bot_pending_actions (Р4, Р15, конвенция 0069 для индексов) +
--      deny-list экспорта (Р16).
--   2. Внутренние помощники: bot_lesson_rights, bot_assert_writable,
--      bot_voice_pending (Р17), bot_lesson_participants.
--   3. bot_today — переиздание (Р13).
--   4. bot_arm_action, bot_pick_student, bot_bind_prompt, bot_mark_attendance,
--      bot_write_note (Р18).
--   5. Гранты: шесть функций — только bot_worker; помощники и эмиттер —
--      никому.
-- =============================================================================


-- 0. Эмиттер для триггеров и переиздание триггеров посещения (Р1/Р2) --------

create or replace function public.emit_event_internal(
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
  if p_center_id is null then
    raise exception 'emit_event_internal: не определён center_id' using errcode = '22004';
  end if;

  insert into public.events (center_id, type, payload)
  values (p_center_id, p_type, coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.emit_event_internal(text, jsonb, uuid) is
  'Эмиттер для тел definer-триггеров (0071 Р1): без проверки сессии — запись, породившая событие, уже прошла свои проверки; и с экрана, и из контура bot_worker. Грантов нет ни у кого: наружу не выдаётся, чтобы не стал дверью для подделки событий (гейт emit_event 0002 остаётся для RPC). Контракт (Р19): p_center_id — только из строки, породившей событие (new.center_id / строка attendance), никогда из параметра вызывающего; функция, которая зовёт этот эмиттер, сама не должна иметь грантов ни у одной прикладной роли.';

revoke all on function public.emit_event_internal(text, jsonb, uuid)
  from public, anon, authenticated, service_role, bot_worker;

-- Дословно с 0010_stage4_hardening.sql (последняя редакция), заменён
-- только public.emit_event → public.emit_event_internal.
create or replace function public.attendance_recalc_trigger()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_left     integer;
  v_sub      uuid;
  v_material boolean;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.recalc_subscription_usage(old.subscription_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform public.recalc_subscription_usage(new.subscription_id);
  end if;
  if tg_op = 'DELETE' then
    return null;
  end if;

  v_material := tg_op = 'INSERT'
             or new.status_id       is distinct from old.status_id
             or new.deducted        is distinct from old.deducted
             or new.subscription_id is distinct from old.subscription_id
             or new.price_tiyin     is distinct from old.price_tiyin;
  if not v_material then
    return null;
  end if;

  v_sub := new.subscription_id;

  if v_sub is null and new.deducted and not exists (
    select 1 from public.events e
     where e.type = 'attendance.no_subscription'
       and e.payload ->> 'attendance_id' = new.id::text
  ) then
    perform public.emit_event_internal('attendance.no_subscription',
      jsonb_build_object('center_id', new.center_id, 'attendance_id', new.id,
                         'lesson_id', new.lesson_id, 'student_id', new.student_id,
                         'debt_tiyin', new.price_tiyin), new.center_id);
  end if;

  perform public.emit_event_internal('attendance.marked',
    jsonb_build_object('center_id', new.center_id, 'attendance_id', new.id,
                       'lesson_id', new.lesson_id, 'student_id', new.student_id,
                       'subscription_id', v_sub, 'deducted', new.deducted), new.center_id);

  if v_sub is not null then
    v_left := public.subscription_lessons_left(v_sub);

    -- Ровно на границе и один раз: остаток — величина пересчитываемая, и без
    -- дедупликации по данным правка «болел» → «пришёл» слала бы второе.
    if v_left = 2 and not exists (
      select 1 from public.events e
       where e.type = 'subscription.low_balance'
         and e.payload ->> 'subscription_id' = v_sub::text
         and (e.payload ->> 'lessons_left')::int = 2
    ) then
      perform public.emit_event_internal('subscription.low_balance',
        jsonb_build_object('center_id', new.center_id, 'subscription_id', v_sub,
                           'student_id', new.student_id, 'lessons_left', v_left), new.center_id);
    elsif v_left = 0 and not exists (
      select 1 from public.events e
       where e.type = 'subscription.exhausted'
         and e.payload ->> 'subscription_id' = v_sub::text
    ) then
      perform public.emit_event_internal('subscription.exhausted',
        jsonb_build_object('center_id', new.center_id, 'subscription_id', v_sub,
                           'student_id', new.student_id), new.center_id);
    -- allow_negative без этого события списывал бы молча: no_subscription не
    -- шлётся (абонемент есть), debt_tiyin не растёт (считается по
    -- subscription_id is null), exhausted ушло один раз на нуле.
    elsif v_left < 0 and not exists (
      select 1 from public.events e
       where e.type = 'subscription.overdrawn'
         and e.payload ->> 'subscription_id' = v_sub::text
    ) then
      perform public.emit_event_internal('subscription.overdrawn',
        jsonb_build_object('center_id', new.center_id, 'subscription_id', v_sub,
                           'student_id', new.student_id, 'lessons_left', v_left), new.center_id);
    end if;
  end if;

  if tg_op = 'INSERT' or new.counts_absence is distinct from old.counts_absence then
    perform public.check_absent_streak(new.center_id, new.student_id, new.lesson_id);
  end if;
  return null;
end;
$$;

-- Дословно с 0010_stage4_hardening.sql (последняя редакция), заменён
-- только public.emit_event → public.emit_event_internal.
create or replace function public.check_absent_streak(
  p_center uuid, p_student uuid, p_lesson uuid
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_prev record;
  v_curr record;
  v_pp   record;
  v_gap  boolean;
begin
  -- Сериализация проверок серии по ребёнку. Две почти одновременные отметки
  -- соседних занятий на снимке read committed не видят друг друга, и событие
  -- о реальных двух пропусках подряд не уходит вовсе. Advisory lock, а не
  -- `for update` на students: тот конфликтует с for key share, который берёт
  -- вставка любой строки с FK на ребёнка — массовая отметка группы вешала бы
  -- создание расписания.
  perform pg_advisory_xact_lock(hashtextextended(p_student::text, 0));

  select a.counts_absence, l.starts_at into v_curr
    from public.attendance a join public.lessons l on l.id = a.lesson_id
   where a.lesson_id = p_lesson and a.student_id = p_student;

  if not found or not v_curr.counts_absence then
    return;
  end if;

  -- Предыдущее отмеченное занятие этого ребёнка.
  select a.counts_absence, l.starts_at, l.id into v_prev
    from public.attendance a join public.lessons l on l.id = a.lesson_id
   where a.student_id = p_student
     and l.starts_at < v_curr.starts_at
     and l.deleted_at is null and l.status <> 'cancelled'
   order by l.starts_at desc limit 1;

  if not found or not v_prev.counts_absence then
    return;
  end if;

  -- Между ними не должно быть прошедшего, но неотмеченного занятия.
  select exists (
    select 1 from public.lesson_participants p
    join public.lessons l on l.id = p.lesson_id
    left join public.attendance a on a.lesson_id = l.id and a.student_id = p_student
   where p.student_id = p_student
     and l.starts_at > v_prev.starts_at and l.starts_at < v_curr.starts_at
     and l.deleted_at is null and l.status <> 'cancelled'
     and a.id is null
  ) into v_gap;
  if v_gap then
    return;
  end if;

  -- Ровно длина 2: на третьем и четвёртом пропуске событие не повторяется.
  -- Смотрится занятие, непосредственно предшествующее v_prev, а не «любой
  -- пропуск когда-либо раньше»: в 0009 было второе, и один прогул полгода
  -- назад навсегда глушил бы событие для этого ребёнка.
  select a.counts_absence into v_pp
    from public.attendance a join public.lessons l on l.id = a.lesson_id
   where a.student_id = p_student
     and l.starts_at < v_prev.starts_at
     and l.deleted_at is null and l.status <> 'cancelled'
   order by l.starts_at desc limit 1;
  if found and v_pp.counts_absence then
    return;
  end if;

  -- Дедупликация по данным, а не по памяти: повторный пересчёт не должен
  -- слать второе сообщение о том же факте.
  if exists (
    select 1 from public.events e
     where e.type = 'student.absent_streak'
       and e.payload ->> 'streak_start_lesson_id' = v_prev.id::text
       and e.payload ->> 'student_id' = p_student::text
  ) then
    return;
  end if;

  perform public.emit_event_internal('student.absent_streak',
    jsonb_build_object('center_id', p_center, 'student_id', p_student,
                       'streak_start_lesson_id', v_prev.id,
                       'lesson_id', p_lesson, 'length', 2), p_center);
end;
$$;

-- Р19: ни у кого, включая bot_worker и service_role — вызывает только триггер.
revoke all on function public.attendance_recalc_trigger() from public, anon, authenticated, service_role, bot_worker;
revoke all on function public.check_absent_streak(uuid, uuid, uuid) from public, anon, authenticated, service_role, bot_worker;


-- 1. bot_pending_actions — «чат X ждёт следующего шага» (Р4, Р15) ----------

create table if not exists public.bot_pending_actions (
  id          uuid primary key default gen_random_uuid(),
  chat_id     bigint not null,
  user_id     uuid not null references auth.users (id) on delete cascade,
  center_id   uuid not null references public.centers (id) on delete cascade,
  kind        text not null
    constraint bot_pending_actions_kind_check
    check (kind in ('attendance', 'note')),
  lesson_id   uuid not null,
  -- null, пока ребёнок не выбран (групповое занятие). Р15: «участник этого
  -- занятия» держат RPC, не FK — при null FK не проверяется вовсе.
  student_id  uuid,
  -- Р18в: message_id промпта ForceReply — ответ на другой промпт отвергается.
  prompt_message_id bigint,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  consumed_at timestamptz,

  constraint bot_pending_actions_lesson_fk
    foreign key (lesson_id, center_id) references public.lessons (id, center_id) on delete cascade,
  constraint bot_pending_actions_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade
);

comment on table public.bot_pending_actions is
  'Контекст следующего шага в Telegram-боте (0071 Р4): чат нажал «Отметить»/«Заметка» под занятием, и кнопки/текст дальше несут один uuid, второй лежит здесь (лимит callback_data 64 байта). Один живой контекст на чат, новое армирование гасит старое. Строки не удаляются — единственный след действий с телефона; аудита нет намеренно (chat_id не должен попадать в audit_log). Политик и грантов нет: только через bot_*-RPC.';

-- Один живой контекст на чат (Р4).
create unique index if not exists bot_pending_actions_chat_live_idx
  on public.bot_pending_actions (chat_id) where consumed_at is null;
-- Покрытие составных FK и одноколоночных ссылок — непартиальные btree
-- (конвенция 0069, docs/Database.md): каскады удаления центра (0056),
-- пользователя, занятия и ребёнка обслуживаются индексом, а не seq scan.
create index if not exists bot_pending_actions_lesson_fk_idx
  on public.bot_pending_actions (lesson_id, center_id);
create index if not exists bot_pending_actions_student_fk_idx
  on public.bot_pending_actions (student_id, center_id);
create index if not exists bot_pending_actions_center_fk_idx
  on public.bot_pending_actions (center_id);
create index if not exists bot_pending_actions_user_fk_idx
  on public.bot_pending_actions (user_id);

alter table public.bot_pending_actions enable row level security;
revoke all on table public.bot_pending_actions from public, anon, authenticated, service_role;

-- Р4: под guard ради забора 0050 (каждая таблица либо под guard, либо в
-- исключениях с причиной); для bot_worker без auth.uid() триггер — no-op,
-- read-only держит явная проверка в функциях (Р11).
call public.apply_readonly_guard('bot_pending_actions');

-- Р16: deny-list экспорта — переиздан с редакции 0064 (последняя), добавлена
-- одна строка. Забор 0056 требует, чтобы каждая таблица с center_id была
-- ровно в одном из двух списков.
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
    ('subscription_reminders_sent', 'Отметка воркера (0052 Р3)')
$$;

revoke all on function public.export_center_excluded_tables() from public, anon, authenticated, service_role;


-- 2. Внутренние помощники (грантов нет ни у кого) ---------------------------

-- Права и состояние занятия для пользователя чата (Р8, Р9). Роли — только
-- белым списком. may_* — про роль; alive/started/is_today — про занятие;
-- bot_today собирает из них can_mark/can_note, мутирующие функции дают по
-- ним читаемые отказы.
create or replace function public.bot_lesson_rights(p_user uuid, p_lesson_id uuid)
  returns table (
    center_id uuid,
    alive     boolean,
    started   boolean,
    is_today  boolean,
    may_mark  boolean,
    may_note  boolean,
    teacher_id uuid
  )
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select l.center_id,
         (l.deleted_at is null and l.status <> 'cancelled')                          as alive,
         (l.starts_at <= now())                                                       as started,
         ((l.starts_at at time zone public.center_timezone(l.center_id))::date
            = public.center_today(l.center_id))                                       as is_today,
         (m.role in ('owner', 'admin', 'registrar')
          or (m.role = 'teacher' and m.teacher_id is not null
              and m.teacher_id = l.effective_teacher_id))                            as may_mark,
         (m.role in ('owner', 'admin')
          or (m.role = 'teacher' and m.teacher_id is not null
              and m.teacher_id = l.effective_teacher_id))                            as may_note,
         case when m.role = 'teacher' then m.teacher_id end                           as teacher_id
    from public.lessons l
    -- Центр с deleted_at здесь не отсеивается намеренно: отказ приходит из
    -- bot_assert_writable текстом «помечен на удаление» (как guard 0056 Р7),
    -- а не «занятие не найдено».
    join public.memberships m on m.center_id = l.center_id and m.user_id = p_user
   where l.id = p_lesson_id;
$$;

revoke all on function public.bot_lesson_rights(uuid, uuid)
  from public, anon, authenticated, service_role, bot_worker;

-- Р11: явная проверка read-only в контуре бота, текст как у guard 0056.
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

-- Р12/Р17: по паре занятие/ребёнок ждут голосовое — печатный текст не
-- должен опередить и обесценить оплаченный разбор. Живой запрос — весь
-- цикл: до прихода файла (consumed_at is null, не протух) И пока
-- ai_write_lesson_note не записал заметку (conduct_key = request.id) в
-- своём 24-часовом окне; провал работы ИИ (ai_jobs.status = failed) окно
-- закрывает.
create or replace function public.bot_voice_pending(p_lesson_id uuid, p_student_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1 from public.lesson_voice_requests r
     where r.lesson_id = p_lesson_id
       and r.student_id = p_student_id
       and r.cancelled_at is null
       and (
         (r.consumed_at is null and r.expires_at > now())
         or (
           r.consumed_at is not null
           and r.consumed_at > now() - interval '24 hours'
           and not exists (select 1 from public.lesson_notes n where n.conduct_key = r.id)
           and not exists (
             select 1 from public.ai_jobs j
             join public.events e on e.id = j.event_id
            where e.type = 'lesson.voice_received'
              and (e.payload ->> 'voice_request_id')::uuid = r.id
              and j.status = 'failed'
           )
         )
       )
  );
$$;

revoke all on function public.bot_voice_pending(uuid, uuid)
  from public, anon, authenticated, service_role, bot_worker;

-- Р10: живые участники занятия с текущим статусом посещения (если есть).
create or replace function public.bot_lesson_participants(p_lesson_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id',  s.id,
           'full_name',   s.full_name,
           'status_name', st.name
         ) order by s.full_name), '[]'::jsonb)
    from public.lesson_participants lp
    join public.students s on s.id = lp.student_id and s.deleted_at is null
    left join public.attendance a on a.lesson_id = lp.lesson_id and a.student_id = lp.student_id
    left join public.attendance_statuses st on st.id = a.status_id
   where lp.lesson_id = p_lesson_id
     and lp.deleted_at is null;
$$;

revoke all on function public.bot_lesson_participants(uuid)
  from public, anon, authenticated, service_role, bot_worker;


-- 3. bot_today — переиздание с кнопками и локальным временем (Р13) ----------

drop function if exists public.bot_today(bigint);

create or replace function public.bot_today(p_chat_id bigint)
  returns table (
    center_id    uuid,
    center_name  text,
    lesson_id    uuid,
    starts_at    timestamptz,
    starts_local text,
    title        text,
    teacher_name text,
    can_mark     boolean,
    can_note     boolean
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
  -- 0033 Р5: пустой список читается как «сегодня выходной».
  if v_user is null then
    raise exception 'Чат не привязан' using errcode = '42501';
  end if;

  return query
    select c.id,
           c.name,
           l.id,
           l.starts_at,
           to_char(l.starts_at at time zone public.center_timezone(c.id), 'HH24:MI'),
           coalesce(g.name, s.full_name, 'Занятие'),
           t.full_name,
           -- Р13: кнопка только там, где действие пройдёт: роль, занятие
           -- началось, живо и сегодняшнее (последнее здесь тавтология —
           -- список и так за сегодня — но собирается тем же помощником, что
           -- перепроверяет на каждом шаге, чтобы правила не разошлись).
           (r.may_mark and r.alive and r.started and r.is_today),
           (r.may_note and r.alive and r.is_today)
      from public.memberships m
      join public.centers c on c.id = m.center_id and c.deleted_at is null
      join public.lessons l on l.center_id = m.center_id
       and l.deleted_at is null
       and l.status <> 'cancelled'
       and (l.starts_at at time zone public.center_timezone(c.id))::date = public.center_today(c.id)
      left join public.students s on s.id = l.student_id
      left join public.groups   g on g.id = l.group_id
      left join public.teachers t on t.id = l.effective_teacher_id
      left join lateral public.bot_lesson_rights(v_user, l.id) r on true
     where m.user_id = v_user
       -- 0033 Р4: та же видимость, что дают политики, только выписанная руками.
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
  'Занятия на сегодня для владельца чата: администрации — центр, специалисту — свои, родителю — детей. finance не получает ничего (0031). Непривязанный чат — отказ, не пустой список (0033 Р5). starts_local — время в поясе центра, бот его не пересчитывает (0071 Р13); can_mark/can_note — кнопки «Отметить»/«Заметка» (0071), родителю всегда false.';


-- 4. Пять шагов бота ----------------------------------------------------------

-- Шаг 1: нажали «Отметить» / «Заметка» под занятием.
create or replace function public.bot_arm_action(p_chat_id bigint, p_kind text, p_lesson_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user         uuid;
  v_r            record;
  v_participants jsonb;
  v_student      uuid;
  v_title        text;
  v_ttl          interval;
  v_statuses     jsonb := null;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_kind not in ('attendance', 'note') then
    raise exception 'Неизвестное действие' using errcode = '22023';
  end if;

  -- Р5: сериализация по чату.
  perform pg_advisory_xact_lock(7070, hashtext(p_chat_id::text));

  v_user := public.telegram_user(p_chat_id);
  if v_user is null then
    raise exception 'Чат не привязан к аккаунту LogoCRM' using errcode = '42501';
  end if;

  select * into v_r from public.bot_lesson_rights(v_user, p_lesson_id);
  if not found then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;
  if (p_kind = 'attendance' and not v_r.may_mark) or (p_kind = 'note' and not v_r.may_note) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not v_r.alive then
    raise exception 'Занятие отменено' using errcode = '22023';
  end if;
  -- Р8: только сегодняшнее в поясе центра.
  if not v_r.is_today then
    raise exception 'Из бота доступны только занятия за сегодня — остальное на экране расписания'
      using errcode = '22023';
  end if;
  if p_kind = 'attendance' and not v_r.started then
    raise exception 'Занятие ещё не началось' using errcode = '22023';
  end if;

  perform public.bot_assert_writable(v_r.center_id, v_user);

  v_participants := public.bot_lesson_participants(p_lesson_id);
  if jsonb_array_length(v_participants) = 0 then
    raise exception 'В занятии нет участников' using errcode = '22023';
  end if;
  if jsonb_array_length(v_participants) = 1 then
    v_student := (v_participants -> 0 ->> 'student_id')::uuid;
    if p_kind = 'note' and public.bot_voice_pending(p_lesson_id, v_student) then
      raise exception 'По этому занятию ждём голосовое — дождитесь черновика или отмените диктовку на экране'
        using errcode = '22023';
    end if;
  end if;

  select coalesce(g.name, s.full_name, 'Занятие') into v_title
    from public.lessons l
    left join public.students s on s.id = l.student_id
    left join public.groups   g on g.id = l.group_id
   where l.id = p_lesson_id;

  -- Р4: один живой контекст на чат — прежние гасятся, не удаляются.
  update public.bot_pending_actions
     set consumed_at = now()
   where chat_id = p_chat_id and consumed_at is null;

  -- Р14: заметка — короткое окно.
  v_ttl := case when p_kind = 'note' then interval '3 minutes' else interval '15 minutes' end;

  insert into public.bot_pending_actions (chat_id, user_id, center_id, kind, lesson_id, student_id, expires_at)
  values (p_chat_id, v_user, v_r.center_id, p_kind, p_lesson_id, v_student, now() + v_ttl);

  if p_kind = 'attendance' then
    select coalesce(jsonb_agg(jsonb_build_object('status_id', st.id, 'name', st.name)
                              order by st.sort, st.name), '[]'::jsonb)
      into v_statuses
      from public.attendance_statuses st
     where st.center_id = v_r.center_id and st.deleted_at is null;
  end if;

  return jsonb_build_object(
    'kind',         p_kind,
    'lesson_title', v_title,
    'student_id',   v_student,
    'student_name', case when v_student is not null then v_participants -> 0 ->> 'full_name' end,
    'students',     v_participants,
    'statuses',     v_statuses,
    'ttl_seconds',  extract(epoch from v_ttl)::int
  );
end;
$$;

comment on function public.bot_arm_action(bigint, text, uuid) is
  'Шаг 1 действия в боте (0071): нажали «Отметить» (attendance) или «Заметка» (note) под сегодняшним занятием. Проверяет роль (Р9), занятие (Р8), read-only (Р11), заводит контекст чата (Р4); при одном участнике сразу выбирает ребёнка. Возвращает участников и — для attendance — статусы центра для кнопок.';

-- Шаг 2 (только групповое занятие): выбрали ребёнка.
create or replace function public.bot_pick_student(p_chat_id bigint, p_student_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user     uuid;
  v_ctx      public.bot_pending_actions;
  v_r        record;
  v_name     text;
  v_statuses jsonb := null;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(7070, hashtext(p_chat_id::text));

  v_user := public.telegram_user(p_chat_id);
  if v_user is null then
    raise exception 'Чат не привязан к аккаунту LogoCRM' using errcode = '42501';
  end if;

  select * into v_ctx from public.bot_pending_actions
   where chat_id = p_chat_id and consumed_at is null and expires_at > now()
   for update;
  if not found then
    raise exception 'Нет активного действия — начните с /today' using errcode = '42704';
  end if;

  -- Р9: права перепроверяются на каждом шаге.
  select * into v_r from public.bot_lesson_rights(v_user, v_ctx.lesson_id);
  if not found
     or (v_ctx.kind = 'attendance' and not v_r.may_mark)
     or (v_ctx.kind = 'note' and not v_r.may_note)
  then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not (v_r.alive and v_r.is_today) then
    raise exception 'Занятие уже недоступно из бота' using errcode = '22023';
  end if;

  perform public.bot_assert_writable(v_ctx.center_id, v_user);

  -- Р10/Р15: ребёнок — живой участник именно этого занятия.
  select s.full_name into v_name
    from public.lesson_participants lp
    join public.students s on s.id = lp.student_id and s.deleted_at is null
   where lp.lesson_id = v_ctx.lesson_id
     and lp.student_id = p_student_id
     and lp.deleted_at is null;
  if v_name is null then
    raise exception 'Этот ребёнок не участник занятия' using errcode = '22023';
  end if;

  if v_ctx.kind = 'note' and public.bot_voice_pending(v_ctx.lesson_id, p_student_id) then
    raise exception 'По этому занятию ждём голосовое — дождитесь черновика или отмените диктовку на экране'
      using errcode = '22023';
  end if;

  update public.bot_pending_actions set student_id = p_student_id where id = v_ctx.id;

  if v_ctx.kind = 'attendance' then
    select coalesce(jsonb_agg(jsonb_build_object('status_id', st.id, 'name', st.name)
                              order by st.sort, st.name), '[]'::jsonb)
      into v_statuses
      from public.attendance_statuses st
     where st.center_id = v_ctx.center_id and st.deleted_at is null;
  end if;

  return jsonb_build_object(
    'kind',         v_ctx.kind,
    'student_id',   p_student_id,
    'student_name', v_name,
    'statuses',     v_statuses
  );
end;
$$;

comment on function public.bot_pick_student(bigint, uuid) is
  'Шаг 2 действия в боте (0071): на групповом занятии выбрали ребёнка. Ребёнок обязан быть живым участником занятия из контекста (Р10/Р15); права и read-only перепроверяются (Р9/Р11).';

-- Шаг 2б (заметка): бот отправил ForceReply-промпт и привязывает его
-- message_id к живому контексту (Р18в).
create or replace function public.bot_bind_prompt(p_chat_id bigint, p_message_id bigint)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_message_id is null then
    raise exception 'Нет message_id промпта' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(7070, hashtext(p_chat_id::text));

  update public.bot_pending_actions
     set prompt_message_id = p_message_id
   where chat_id = p_chat_id and kind = 'note' and consumed_at is null and expires_at > now();

  if not found then
    raise exception 'Нет активной заметки — нажмите «Заметка» под занятием в /today' using errcode = '42704';
  end if;
end;
$$;

comment on function public.bot_bind_prompt(bigint, bigint) is
  'Привязка ForceReply-промпта к живому контексту заметки (0071 Р18в): bot_write_note отвергает ответ на другой промпт, чтобы текст не лёг в карту не того ребёнка.';

-- Шаг 3а: нажали статус посещения.
create or replace function public.bot_mark_attendance(p_chat_id bigint, p_status_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user     uuid;
  v_ctx      public.bot_pending_actions;
  v_r        record;
  v_status   public.attendance_statuses;
  v_existing public.attendance;
  v_name     text;
  v_changed  boolean := true;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(7070, hashtext(p_chat_id::text));

  v_user := public.telegram_user(p_chat_id);
  if v_user is null then
    raise exception 'Чат не привязан к аккаунту LogoCRM' using errcode = '42501';
  end if;

  select * into v_ctx from public.bot_pending_actions
   where chat_id = p_chat_id and kind = 'attendance' and consumed_at is null and expires_at > now()
   for update;
  if not found then
    raise exception 'Нет активной отметки — нажмите «Отметить» под занятием в /today' using errcode = '42704';
  end if;
  if v_ctx.student_id is null then
    raise exception 'Сначала выберите ребёнка' using errcode = '22023';
  end if;

  select * into v_r from public.bot_lesson_rights(v_user, v_ctx.lesson_id);
  if not found or not v_r.may_mark then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not (v_r.alive and v_r.is_today) then
    raise exception 'Занятие уже недоступно из бота' using errcode = '22023';
  end if;

  perform public.bot_assert_writable(v_ctx.center_id, v_user);

  select s.full_name into v_name
    from public.lesson_participants lp
    join public.students s on s.id = lp.student_id and s.deleted_at is null
   where lp.lesson_id = v_ctx.lesson_id and lp.student_id = v_ctx.student_id and lp.deleted_at is null;
  if v_name is null then
    raise exception 'Этот ребёнок не участник занятия' using errcode = '22023';
  end if;

  select * into v_status from public.attendance_statuses
   where id = p_status_id and center_id = v_ctx.center_id and deleted_at is null;
  if not found then
    raise exception 'Статус посещения не найден' using errcode = '42704';
  end if;

  -- Р6: существующую отметку бот не переписывает.
  select * into v_existing from public.attendance
   where lesson_id = v_ctx.lesson_id and student_id = v_ctx.student_id
   for update;
  if found then
    if v_existing.status_id = v_status.id then
      v_changed := false;
    else
      raise exception 'Отметка уже стоит — изменить её можно на экране занятия' using errcode = '22023';
    end if;
  else
    -- Р7: обработчик гонки — только вокруг insert, гашение контекста ниже
    -- остаётся в силе. Триггеры attendance_fill_and_check (началось,
    -- участник, абонемент), financial_period_guard (закрытый месяц) и
    -- attendance_recalc_trigger (события, Р1/Р2) — вторые рубежи.
    begin
      insert into public.attendance (center_id, lesson_id, student_id, status_id, marked_by)
      values (v_ctx.center_id, v_ctx.lesson_id, v_ctx.student_id, v_status.id, v_user);
    exception when unique_violation then
      select * into v_existing from public.attendance
       where lesson_id = v_ctx.lesson_id and student_id = v_ctx.student_id;
      if v_existing.status_id = v_status.id then
        v_changed := false;
      else
        raise exception 'Отметка уже стоит — изменить её можно на экране занятия' using errcode = '22023';
      end if;
    end;
  end if;

  update public.bot_pending_actions set consumed_at = now() where id = v_ctx.id;

  return jsonb_build_object(
    'student_name', v_name,
    'status_name',  v_status.name,
    'changed',      v_changed
  );
end;
$$;

comment on function public.bot_mark_attendance(bigint, uuid) is
  'Шаг 3 (посещение) в боте (0071): ставит отметку ребёнку из контекста статусом центра. Тот же статус повторно — идемпотентный успех (changed=false), другой — отказ «на экране» (Р6). События посещения — от триггера, как с экрана (Р1/Р2). marked_by — пользователь чата.';

-- Шаг 3б: прислали текст заметки.
create or replace function public.bot_write_note(p_chat_id bigint, p_text text, p_reply_to bigint default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user     uuid;
  v_text     text := trim(coalesce(p_text, ''));
  v_ctx      public.bot_pending_actions;
  v_r        record;
  v_name     text;
  v_note     public.lesson_notes;
  v_prev     text;
  v_appended boolean := false;
  v_inserted boolean := false;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(7070, hashtext(p_chat_id::text));

  v_user := public.telegram_user(p_chat_id);
  if v_user is null then
    raise exception 'Чат не привязан к аккаунту LogoCRM' using errcode = '42501';
  end if;

  select * into v_ctx from public.bot_pending_actions
   where chat_id = p_chat_id and kind = 'note' and consumed_at is null and expires_at > now()
   for update;
  if not found then
    raise exception 'Нет активной заметки — нажмите «Заметка» под занятием в /today' using errcode = '42704';
  end if;

  -- Р18в: ответ на другой (устаревший) промпт — не этот контекст. Обычное
  -- сообщение без reply в окне — принимается.
  if p_reply_to is not null and v_ctx.prompt_message_id is not null
     and p_reply_to <> v_ctx.prompt_message_id
  then
    raise exception 'Это окно уже закрыто — нажмите «Заметка» под нужным занятием ещё раз'
      using errcode = '22023';
  end if;

  if v_text = '' then
    raise exception 'Пустая заметка' using errcode = '22023';
  end if;
  if length(v_text) > 2000 then
    raise exception 'Заметка длиннее 2000 знаков — сократите' using errcode = '22023';
  end if;
  if v_ctx.student_id is null then
    raise exception 'Сначала выберите ребёнка' using errcode = '22023';
  end if;

  select * into v_r from public.bot_lesson_rights(v_user, v_ctx.lesson_id);
  if not found or not v_r.may_note then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not (v_r.alive and v_r.is_today) then
    raise exception 'Занятие уже недоступно из бота' using errcode = '22023';
  end if;

  perform public.bot_assert_writable(v_ctx.center_id, v_user);

  select s.full_name into v_name
    from public.lesson_participants lp
    join public.students s on s.id = lp.student_id and s.deleted_at is null
   where lp.lesson_id = v_ctx.lesson_id and lp.student_id = v_ctx.student_id and lp.deleted_at is null;
  if v_name is null then
    raise exception 'Этот ребёнок не участник занятия' using errcode = '22023';
  end if;

  -- Р12: живая диктовка по той же паре — отказ.
  if public.bot_voice_pending(v_ctx.lesson_id, v_ctx.student_id) then
    raise exception 'По этому занятию ждём голосовое — дождитесь черновика или отмените диктовку на экране'
      using errcode = '22023';
  end if;

  select * into v_note from public.lesson_notes
   where lesson_id = v_ctx.lesson_id and student_id = v_ctx.student_id
     and center_id = v_ctx.center_id and deleted_at is null
   for update;

  if not found then
    -- Р3: created_by и center_id явно — дефолты в контуре бота пусты.
    -- Р18а: гонка двух чатов на одной паре — вложенный блок только вокруг
    -- insert; по unique_violation перечитываем и идём в ветку дописывания.
    begin
      insert into public.lesson_notes
        (center_id, lesson_id, student_id, teacher_id, created_by, soap, source, status)
      values
        (v_ctx.center_id, v_ctx.lesson_id, v_ctx.student_id, v_r.teacher_id, v_user,
         jsonb_build_object('objective', v_text), 'text', 'draft');
      v_inserted := true;
    exception when unique_violation then
      select * into v_note from public.lesson_notes
       where lesson_id = v_ctx.lesson_id and student_id = v_ctx.student_id
         and center_id = v_ctx.center_id and deleted_at is null
       for update;
      if not found then
        raise exception 'Заметка не записалась — попробуйте ещё раз' using errcode = '40001';
      end if;
    end;
  end if;

  if not v_inserted then
    if v_note.status = 'approved' then
      raise exception 'Утверждённую заметку нельзя изменить — заведите новую на следующем занятии'
        using errcode = '23514';
    end if;
    -- Р18б: чужой черновик из бота не дописывается — автора дописки в
    -- контуре бота не фиксирует ничто.
    if v_note.created_by is distinct from v_user then
      raise exception 'Черновик по этому занятию начал другой специалист — допишите на экране занятия'
        using errcode = '22023';
    end if;
    v_prev := nullif(trim(coalesce(v_note.soap ->> 'objective', '')), '');
    update public.lesson_notes
       set soap = jsonb_set(coalesce(soap, '{}'::jsonb), '{objective}',
                            to_jsonb(case when v_prev is null then v_text else v_prev || E'\n' || v_text end))
     where id = v_note.id;
    v_appended := v_prev is not null;
  end if;

  update public.bot_pending_actions set consumed_at = now() where id = v_ctx.id;

  return jsonb_build_object(
    'student_name', v_name,
    'appended',     v_appended,
    'preview',      left(v_text, 60)
  );
end;
$$;

comment on function public.bot_write_note(bigint, text, bigint) is
  'Шаг 3 (заметка) в боте (0071): текст одним сообщением → черновик lesson_notes (source text, soap.objective) или дописывание в СВОЙ существующий черновик (чужой — отказ, Р18б); утверждённый — 23514; живая диктовка по той же паре — отказ (Р12/Р17); ответ на устаревший ForceReply-промпт — отказ (Р18в). created_by — пользователь чата (Р3), чтобы автор мог утвердить на экране.';


-- 5. Гранты: шесть функций — только bot_worker ------------------------------

revoke all on function public.bot_today(bigint) from public, anon, authenticated, service_role;
grant execute on function public.bot_today(bigint) to bot_worker;

revoke all on function public.bot_bind_prompt(bigint, bigint) from public, anon, authenticated, service_role;
grant execute on function public.bot_bind_prompt(bigint, bigint) to bot_worker;

revoke all on function public.bot_arm_action(bigint, text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.bot_arm_action(bigint, text, uuid) to bot_worker;

revoke all on function public.bot_pick_student(bigint, uuid) from public, anon, authenticated, service_role;
grant execute on function public.bot_pick_student(bigint, uuid) to bot_worker;

revoke all on function public.bot_mark_attendance(bigint, uuid) from public, anon, authenticated, service_role;
grant execute on function public.bot_mark_attendance(bigint, uuid) to bot_worker;

revoke all on function public.bot_write_note(bigint, text, bigint) from public, anon, authenticated, service_role;
grant execute on function public.bot_write_note(bigint, text, bigint) to bot_worker;
