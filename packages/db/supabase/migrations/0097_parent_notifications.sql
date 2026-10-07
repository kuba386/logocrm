-- =============================================================================
-- 0097_parent_notifications.sql — этап 11: уведомления по часам центра,
-- долг раз в неделю, срок абонемента, отметка посещения, расписание специалисту
--
-- Решения владельца (7.10.2026, не пересматриваются здесь):
--   В1. Напоминание о занятии — накануне в 18:00 по часам центра. Было: за 18
--       часов (0032), и занятие в 20:00 получало «завтра в 20:00» в 02:00
--       ночи того же дня.
--   В2. Долг родителю — раз в неделю, понедельник с 10:00 по часам центра,
--       пока долг есть. Шаблон включён по умолчанию, центр может выключить.
--   В3. Абонемент на срок — родителю за 3 дня до окончания.
--   В4. Галочка «Уведомлять родителя» у статуса посещения начинает работать.
--       Сидовые «Болел»/«Прогул» = true снимаются: центры их не выбирали,
--       флаг до сих пор ничего не делал. Новым центрам — false.
--   В5. Специалисту — его занятия на завтра, вечером в Telegram.
--   Отключение напоминаний самим родителем — не в этапе.
--
-- Ревью плана — architect, 4 блокера и 12 находок, учтены:
--   Б1. Время — параметр. Каждый планировщик — внутренняя *_at(p_now) без
--       грантов (SECURITY INVOKER, как bot_balance_center: ошибочный будущий
--       grant не даст табличных прав); внутри ни now(), ни center_today() —
--       только (p_now at time zone tz). Публичные lesson_reminders() и
--       notification_schedules() — обёртки с now(). Слово дня {day} —
--       lesson_reminder_day(starts_at, tz, p_now), event_messages зовёт её с now().
--   Б2. Новые рассылки — отдельный вход notification_schedules() и отдельная
--       нода n8n (ручной шаг владельца, как subscription_reminders в 0052).
--       lesson_reminders() возвращает только свои напоминания: медленный
--       расчёт долга (statement_timeout не ловится exception when others) не
--       откатывает напоминания о занятиях. Долг ищется ОДНИМ расчётом на центр
--       (student_debt_problems под подменой на владельца, как digest_debt_text),
--       не по расчёту на плательщика.
--   Б3. Отметка посещения — свой триггер attendance_status_notice (definer,
--       через emit_event_internal; attendance_recalc_trigger не тронут):
--       INSERT и реальная смена status_id, и только если у статуса
--       notify_parent. status_id — в payload. Доставка: текущий статус ≠
--       статусу события → пусто (перекрыто правкой); тому же получателю уже
--       уходило то же (attendance, status) → пусто; событие старше 12 часов
--       или занятие старше 3 суток → пусто (очередь после простоя и
--       миграции-бэкфиллы не рассылают историю).
--   Б4. Заборы: readonly_guard_exempt_tables (от 0063),
--       export_center_excluded_tables (от 0094); tests/0007, tests/0079.
--   5.  *_at и помощники: revoke у public, anon, authenticated, service_role,
--       bot_worker и auth.uid() is not null → 42501 внутри.
--   6.  Просрочка по абонементу — только если её плательщик = текущий
--       плательщик ребёнка (0070): так видит её родитель в bot_balance_center.
--   7.  Отметка недели — на центр, не на плательщика: расчёт раз в неделю,
--       снимок в момент первого прогона. Пропущенный понедельник наверстывается
--       в любой день недели с 10 до 20, неделя без напоминания — только если
--       n8n лежал всю неделю.
--   8.  У subscriptions нет kind: срочный — ends_at is not null (0054 Р4).
--       Продление — другой живой абонемент ребёнка, созданный позже, с
--       ends_at позже или бессрочный. Получатель — текущий students.payer_id.
--   9.  Перенос после напоминания: отметка по (lesson_id, starts_at). Новое
--       время — новое напоминание; при доставке starts_at из payload ≠
--       текущему или занятие уже началось → пусто.
--   10. Плейсхолдеры предпросмотра не пересекаются: {lesson_count},
--       {lesson_list}, {center} — новые имена ({count}, {lessons} заняты).
--   11. Канал шаблона сверяется с notification_event_types.channels
--       (триггер message_templates_channel_allowed, только новые записи).
--   12. Каждая ветка доставки читает строки с center_id = events.center_id.
--   13. Сбой расчёта долга при доставке всплывает (fail_events → event.failed),
--       а не превращается в «получателей нет».
--   14. Планировщики не эмитят, если у центра тип выключен во всех каналах
--       или получателя заведомо нет — журнал не забивается skipped/no_channel.
--   16. {center} в расписании специалиста (у специалиста бывает два центра);
--       список — не длиннее 30 строк.
--
-- Записано, не чинится:
--   - Одно напоминание на занятие, а не одна сводка на все завтрашние: кнопка
--     «Подтвердить приход» привязана к событию и ребёнку (0035).
--   - На втором пропуске подряд родитель может получить и отметку статуса
--     (В4), и student.absent_streak.
--   - Кастомные тексты lesson.reminder центров со словом «завтра» не
--     переписываются (на проде таких 0): {day} — только в дефолтах.
-- =============================================================================


-- 1. Справочник типов и шаблоны по умолчанию -------------------------------------------------

insert into public.notification_event_types (event_type, description, audience, subject_required, channels, mandatory) values
  ('debt.reminder',               'Напоминание о долге (раз в неделю)',      'center', true,  array['telegram', 'whatsapp_link'], false),
  ('subscription.period_ending',  'Абонемент на срок заканчивается',         'center', true,  array['telegram', 'whatsapp_link'], false),
  ('attendance.status_changed',   'Отметка посещения (статусы с галочкой)',  'center', true,  array['telegram', 'whatsapp_link'], false),
  ('teacher.schedule',            'Расписание специалисту на завтра',        'center', false, array['telegram'],                  false)
on conflict (event_type) do nothing;

insert into public.message_templates (center_id, event_type, channel, text) values
  (null, 'debt.reminder', 'telegram',
   'Напоминаем о задолженности. {child}: {debt}. Оплатить можно у администратора центра.'),
  (null, 'debt.reminder', 'whatsapp_link',
   'Здравствуйте! Напоминаем о задолженности. {child}: {debt}. Оплатить можно у администратора центра.'),
  (null, 'subscription.period_ending', 'telegram',
   '{child}: абонемент действует до {date}. Чтобы занятия продолжились без перерыва, продлите его у администратора.'),
  (null, 'subscription.period_ending', 'whatsapp_link',
   'Здравствуйте! {child}: абонемент действует до {date}. Чтобы занятия продолжились без перерыва, продлите его у администратора.'),
  (null, 'attendance.status_changed', 'telegram',
   '{child}: занятие {date} в {time} отмечено — «{status}».'),
  (null, 'attendance.status_changed', 'whatsapp_link',
   'Здравствуйте! {child}: занятие {date} в {time} отмечено — «{status}».'),
  (null, 'teacher.schedule', 'telegram',
   'Завтра, {date}, в «{center}» у вас {lesson_count}:' || chr(10) || '{lesson_list}');

-- В1: дефолт говорит {day} — «сегодня», «завтра» или дату, на момент доставки.
update public.message_templates
   set text = replace(text, 'завтра в {time}', '{day} в {time}')
 where center_id is null
   and event_type = 'lesson.reminder'
   and deleted_at is null;


-- 2. Канал шаблона — из справочника (п.11) ----------------------------------------------------

-- Definer: справочник закрыт для authenticated, и invoker-триггер на прямой
-- вставке отвечал бы «permission denied» раньше политик (tests/0050).
-- Проверяются только новые пары (тип, канал) строк центра: дефолты платформы
-- пишет только миграция, их сверяет забор 0034. Неизвестный тип пропускается
-- — на него отвечает FK (23503, tests/0037).
create or replace function public.message_templates_channel_allowed()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.center_id is null then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and new.channel is not distinct from old.channel
     and new.event_type is not distinct from old.event_type then
    return new;
  end if;

  if not exists (select 1 from public.notification_event_types t where t.event_type = new.event_type) then
    return new;
  end if;

  if not exists (
    select 1 from public.notification_event_types t
     where t.event_type = new.event_type
       and new.channel = any (t.channels)
  ) then
    raise exception 'Этот тип уведомления не отправляется в канал %', new.channel
      using errcode = '22023';
  end if;
  return new;
end;
$$;

comment on function public.message_templates_channel_allowed() is
  'Шаблон заводится только в канал из notification_event_types.channels (0097 п.11): иначе центр заводит whatsapp_link для teacher.schedule, и в журнал копятся no_channel со списком детей.';

revoke all on function public.message_templates_channel_allowed() from public, anon, authenticated, service_role;

drop trigger if exists message_templates_channel_allowed on public.message_templates;
create trigger message_templates_channel_allowed
  before insert or update on public.message_templates
  for each row execute function public.message_templates_channel_allowed();


-- 3. Галочка «Уведомлять родителя» — сидовые значения снимаются (В4) ------------------------

-- Дословно 0055, кроме notify_parent у sick/absent.
create or replace function public.seed_attendance_statuses(p_center_id uuid)
  returns void
  language sql
  security definer
  set search_path = ''
as $$
  insert into public.attendance_statuses
    (center_id, code, name, color, deducts_lesson, pays_teacher, counts_absence, notify_parent, is_default, sort, is_present)
  values
    (p_center_id, 'present', 'Пришёл',  'green',  true,  true,  false, false, true,  10, true),
    (p_center_id, 'late',    'Опоздал', 'amber',  true,  true,  false, false, false, 20, true),
    (p_center_id, 'sick',    'Болел',   'sky',    false, false, true,  false, false, 30, false),
    (p_center_id, 'absent',  'Прогул',  'rose',   true,  true,  true,  false, false, 40, false)
  on conflict do nothing;
$$;

comment on function public.seed_attendance_statuses(uuid) is
  'Четыре статуса новому центру. С 0055 — и is_present (Д): присутствие, не «списывает» и не «обратное пропуску» — статус «Прогул» списывает занятие (deducts_lesson=true) и присутствием не является. С 0097 notify_parent у всех false: сообщение родителю об отметке центр включает сам (В4).';

revoke all on function public.seed_attendance_statuses(uuid) from public, anon, authenticated, service_role;

-- Только сидовые коды: свой статус с галочкой центр мог завести осознанно.
update public.attendance_statuses
   set notify_parent = false
 where code in ('sick', 'absent')
   and notify_parent;


-- 4. Общие помощники ---------------------------------------------------------------------------

-- «Слать ли этот тип центру хоть в один канал» — тот же resolve_template, что
-- при доставке (п.14). Канал — из справочника.
create or replace function public.center_notification_enabled(p_center_id uuid, p_event_type text)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select exists (
    select 1
      from public.notification_event_types t
      cross join lateral unnest(t.channels) ch
      cross join lateral public.resolve_template(p_center_id, p_event_type, ch) rt
     where t.event_type = p_event_type
       and rt.should_send
  );
$$;

comment on function public.center_notification_enabled(uuid, text) is
  'Включён ли тип уведомления у центра хоть в одном канале справочника (0097 п.14). Планировщики не эмитят выключенное — журнал не забивается skipped. При доставке решает resolve_template, как раньше.';

revoke all on function public.center_notification_enabled(uuid, text)
  from public, anon, authenticated, service_role, bot_worker;


-- «Сегодня» / «завтра» / дата — в поясе центра на момент p_now (Б1).
create or replace function public.lesson_reminder_day(p_starts_at timestamptz, p_tz text, p_now timestamptz)
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select case ((p_starts_at at time zone p_tz)::date - (p_now at time zone p_tz)::date)
           when 0 then 'сегодня'
           when 1 then 'завтра'
           else to_char(p_starts_at at time zone p_tz, 'DD.MM')
         end;
$$;

comment on function public.lesson_reminder_day(timestamptz, text, timestamptz) is
  'Слово дня {day} в напоминании о занятии (0097 Б1): локальная дата занятия против локальной даты p_now в поясе центра. event_messages зовёт с now(), pgTAP — с фиксированным моментом.';

revoke all on function public.lesson_reminder_day(timestamptz, text, timestamptz)
  from public, anon, authenticated, service_role, bot_worker;


-- Продлён ли абонемент: у ребёнка есть другой живой абонемент, купленный
-- позже, который заканчивается позже или бессрочный (п.8).
create or replace function public.subscription_renewed(p_subscription_id uuid)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select exists (
    select 1
      from public.subscriptions s
      join public.subscriptions n
        on n.student_id = s.student_id
       and n.center_id = s.center_id
       and n.id <> s.id
       and n.deleted_at is null
       and n.status <> 'cancelled'
       and (n.created_at, n.id) > (s.created_at, s.id)
       and (n.ends_at is null or n.ends_at > s.ends_at)
     where s.id = p_subscription_id
  );
$$;

comment on function public.subscription_renewed(uuid) is
  'Абонемент на срок уже продлён (0097 п.8): у того же ребёнка есть другой не отменённый, не архивный абонемент, созданный позже (при равном created_at — по id), с ends_at позже или без срока (пакет занятий). Тип не сравнивается: продлевают и другим типом.';

revoke all on function public.subscription_renewed(uuid)
  from public, anon, authenticated, service_role, bot_worker;


-- 5. Напоминание о занятии накануне в 18:00 (В1, Б1, п.9) ------------------------------------

-- Отметка — по (занятие, время): перенос даёт новое напоминание о новом времени.
alter table public.lesson_reminders_sent add column if not exists starts_at timestamptz;

update public.lesson_reminders_sent s
   set starts_at = l.starts_at
  from public.lessons l
 where l.id = s.lesson_id
   and s.starts_at is null;

alter table public.lesson_reminders_sent alter column starts_at set not null;
alter table public.lesson_reminders_sent drop constraint lesson_reminders_sent_pkey;
alter table public.lesson_reminders_sent add constraint lesson_reminders_sent_pkey primary key (lesson_id, starts_at);

comment on table public.lesson_reminders_sent is
  'Напоминание по занятию отправлено. Первичный ключ (lesson_id, starts_at) — инвариант «одно напоминание на время занятия» (0032 Р8, 0097 п.9: перенос — новое время, новое напоминание); строки кладёт только lesson_reminders_at().';


create or replace function public.lesson_reminders_at(p_now timestamptz)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_count integer := 0;
  r       record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    select l.id, l.center_id, l.starts_at, l.student_id, l.group_id, l.effective_teacher_id
      from public.lessons l
      join public.centers c on c.id = l.center_id and c.deleted_at is null
      cross join lateral (
        select (p_now at time zone public.center_timezone(c.id)) as local_now,
               (l.starts_at at time zone public.center_timezone(c.id))::date as lesson_day
      ) z
     where l.status = 'planned'
       and l.deleted_at is null
       and l.starts_at > p_now
       -- Грубое окно по индексу starts_at: дальше послезавтра не смотрим.
       and l.starts_at < p_now + interval '48 hours'
       and (
         -- Накануне, 18:00–20:59 местного: пропущенный запуск наверстывается,
         -- поставленное на завтра в 19:30 уходит в ближайший час.
         (z.lesson_day = z.local_now::date + 1
          and extract(hour from z.local_now) between 18 and 20)
         -- Догоняющий путь: занятие поставили после 21:00 накануне или сегодня
         -- на сегодня — утром с 8:00, если до начала больше часа.
         or (z.lesson_day = z.local_now::date
             and extract(hour from z.local_now) between 8 and 20
             and l.starts_at > p_now + interval '1 hour')
       )
       and not exists (
         select 1 from public.lesson_reminders_sent s
          where s.lesson_id = l.id and s.starts_at = l.starts_at
       )
     order by l.starts_at, l.id
  loop
    -- on conflict, а не проверка выше: два прогона одновременно — вставит один.
    insert into public.lesson_reminders_sent (lesson_id, center_id, starts_at)
    values (r.id, r.center_id, r.starts_at)
    on conflict (lesson_id, starts_at) do nothing;

    if found then
      perform public.emit_event_unchecked(
        'lesson.reminder',
        jsonb_build_object(
          'center_id', r.center_id,
          'lesson_id', r.id,
          'starts_at', r.starts_at,
          'student_id', r.student_id,
          'group_id', r.group_id,
          'teacher_id', r.effective_teacher_id
        ),
        r.center_id
      );
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

comment on function public.lesson_reminders_at(timestamptz) is
  'Напоминания о занятиях на момент p_now (0097 В1): завтрашние — с 18 до 21 по часам центра; сегодняшние, ещё не напомненные, — с 8 до 21, если до начала больше часа. Ночью — ничего. Отметка (lesson_id, starts_at). Внутренняя: SECURITY INVOKER, грантов нет ни у кого; зовёт lesson_reminders() с now(), pgTAP — с фиксированным моментом.';

revoke all on function public.lesson_reminders_at(timestamptz)
  from public, anon, authenticated, service_role, bot_worker;


create or replace function public.lesson_reminders()
  returns table (sent_count integer)
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return query select public.lesson_reminders_at(now());
end;
$$;

comment on function public.lesson_reminders() is
  'Напоминания о занятиях — накануне в 18:00 по часам центра (0097). Запуск раз в час из сценария n8n schedule; считает только напоминания о занятиях — остальные рассылки в notification_schedules() (0097 Б2).';

revoke all on function public.lesson_reminders() from public, anon, authenticated, service_role;
grant execute on function public.lesson_reminders() to bot_worker;


-- 6. Расписание специалисту на завтра (В5) ----------------------------------------------------

create table if not exists public.teacher_schedule_sent (
  teacher_id uuid not null,
  center_id  uuid not null references public.centers (id) on delete cascade,
  day        date not null,
  sent_at    timestamptz not null default now(),
  primary key (teacher_id, day),
  constraint teacher_schedule_sent_teacher_fk
    foreign key (teacher_id, center_id) references public.teachers (id, center_id) on delete cascade
);

comment on table public.teacher_schedule_sent is
  'Расписание на day специалисту отправлено (0097 В5). Первичный ключ — «одно сообщение на день»; строки кладёт только teacher_schedules_at().';

create index if not exists teacher_schedule_sent_center_idx on public.teacher_schedule_sent (center_id);

alter table public.teacher_schedule_sent enable row level security;

drop policy if exists teacher_schedule_sent_read on public.teacher_schedule_sent;
create policy teacher_schedule_sent_read on public.teacher_schedule_sent
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() in ('owner', 'admin')
  );

revoke all on table public.teacher_schedule_sent from public, anon, authenticated, service_role;
grant select on public.teacher_schedule_sent to authenticated;


create or replace function public.teacher_schedules_at(p_now timestamptz)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_count integer := 0;
  r       record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    select t.id as teacher_id, t.center_id, z.tomorrow
      from public.teachers t
      join public.centers c on c.id = t.center_id and c.deleted_at is null
      cross join lateral (
        select (p_now at time zone public.center_timezone(c.id)) as local_now,
               (p_now at time zone public.center_timezone(c.id))::date + 1 as tomorrow
      ) z
     where t.deleted_at is null
       and t.profile_id is not null
       and extract(hour from z.local_now) between 18 and 20
       -- Только telegram (справочник): без привязки сообщения не будет —
       -- и событие не нужно (п.14).
       and exists (
         select 1 from public.telegram_accounts a
          where a.user_id = t.profile_id and a.unlinked_at is null
       )
       and exists (
         select 1 from public.memberships m
          where m.user_id = t.profile_id and m.center_id = t.center_id
       )
       and exists (
         select 1 from public.lessons l
          where l.center_id = t.center_id
            and l.effective_teacher_id = t.id
            and l.status = 'planned'
            and l.deleted_at is null
            and l.starts_at > p_now
            and l.starts_at < p_now + interval '48 hours'
            and (l.starts_at at time zone public.center_timezone(c.id))::date = z.tomorrow
       )
       and public.center_notification_enabled(t.center_id, 'teacher.schedule')
       and not exists (
         select 1 from public.teacher_schedule_sent s
          where s.teacher_id = t.id and s.day = z.tomorrow
       )
     order by t.center_id, t.id
  loop
    insert into public.teacher_schedule_sent (teacher_id, center_id, day)
    values (r.teacher_id, r.center_id, r.tomorrow)
    on conflict (teacher_id, day) do nothing;

    if found then
      perform public.emit_event_unchecked(
        'teacher.schedule',
        jsonb_build_object('center_id', r.center_id, 'teacher_id', r.teacher_id, 'date', r.tomorrow),
        r.center_id
      );
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

comment on function public.teacher_schedules_at(timestamptz) is
  'Расписание на завтра специалистам (0097 В5): с 18 до 21 по часам центра, живая карточка с аккаунтом и привязанным Telegram, хоть одно planned-занятие завтра (effective_teacher_id — с заменами). Список собирается при доставке. Внутренняя: SECURITY INVOKER, грантов нет ни у кого.';

revoke all on function public.teacher_schedules_at(timestamptz)
  from public, anon, authenticated, service_role, bot_worker;


-- 7. Долг — раз в неделю (В2, Б2, п.6, п.7) ---------------------------------------------------

create table if not exists public.debt_reminder_runs (
  center_id  uuid not null references public.centers (id) on delete cascade,
  week_start date not null,
  sent_at    timestamptz not null default now(),
  primary key (center_id, week_start)
);

comment on table public.debt_reminder_runs is
  'Недельный проход по должникам центра выполнен (0097 п.7): один расчёт на центр в неделю, снимок в момент первого прогона. Строки кладёт только debt_reminders_at().';

alter table public.debt_reminder_runs enable row level security;

drop policy if exists debt_reminder_runs_read on public.debt_reminder_runs;
create policy debt_reminder_runs_read on public.debt_reminder_runs
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() in ('owner', 'admin')
  );

revoke all on table public.debt_reminder_runs from public, anon, authenticated, service_role;
grant select on public.debt_reminder_runs to authenticated;

-- Текущая неделя отмечена у всех живых центров: первая рассылка — в ближайший
-- понедельник, как решил владелец, а не в день выкатки (ревью, п.3).
insert into public.debt_reminder_runs (center_id, week_start)
select c.id,
       (now() at time zone public.center_timezone(c.id))::date
         - (extract(isodow from (now() at time zone public.center_timezone(c.id)))::integer - 1)
  from public.centers c
 where c.deleted_at is null
on conflict (center_id, week_start) do nothing;


-- Плательщики-должники центра — одним расчётом под ЛОКАЛЬНО подменённой
-- сессией сотрудника с can_payments (прецедент bot_debts_center 0072/0076).
-- Долг за занятия и перерасход — текущему плательщику ребёнка; просрочка по
-- абонементу — только если её плательщик он же (п.6, 0070).
create or replace function public.debt_payers_center(p_user uuid, p_center uuid)
  returns table (payer_id uuid)
  language plpgsql
  set search_path = ''
as $$
declare
  v_prev text;
  v_ok   boolean;
begin
  -- Подмена на владельца — только из контура воркера без сессии: ошибочный
  -- будущий grant не должен открыть должников любого центра.
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.memberships m
     where m.user_id = p_user and m.center_id = p_center
       and m.role in ('owner', 'admin', 'registrar', 'finance')
  ) then
    return;
  end if;

  v_prev := coalesce(current_setting('request.jwt.claims', true), '');

  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);

  v_ok := coalesce(auth.uid() = p_user
                   and public.current_center() = p_center
                   and public.can_payments(), false);

  if v_ok then
    return query
      select distinct d.payer_id
        from public.student_debt_problems() d
       where d.payer_id is not null
         and (d.debt_tiyin + d.overdrawn_tiyin > 0
              or (d.overdue_tiyin > 0 and d.overdue_payer_id = d.payer_id));
  end if;

  perform set_config('request.jwt.claims', v_prev, true);

  if not v_ok then
    raise exception 'Не удалось определить права в центре — обратитесь к администратору'
      using errcode = '42501';
  end if;
end;
$$;

comment on function public.debt_payers_center(uuid, uuid) is
  'Плательщики с долгом в центре (0097 Б2): student_debt_problems под локально подменённой сессией сотрудника с can_payments — одно определение долга с /app/debts. Долг за занятия и перерасход — текущему плательщику ребёнка, просрочка по абонементу — только её плательщику (0070). SECURITY INVOKER, грантов нет ни у кого; роль проверяется до подмены, самопроверка после, claims возвращаются перед raise.';

revoke all on function public.debt_payers_center(uuid, uuid)
  from public, anon, authenticated, service_role, bot_worker;


create or replace function public.debt_reminders_at(p_now timestamptz)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_count integer := 0;
  v_user  uuid;
  c       record;
  p       record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for c in
    select x.id, x.week_start
      from (
        select ce.id,
               (p_now at time zone public.center_timezone(ce.id)) as local_now
          from public.centers ce
         where ce.deleted_at is null
      ) y
      cross join lateral (
        select y.id,
               y.local_now::date - (extract(isodow from y.local_now)::integer - 1) as week_start,
               extract(isodow from y.local_now)::integer as dow,
               extract(hour from y.local_now)::integer as hr
      ) x
     -- Понедельник с 10:00; пропущенный — наверстывается в любой день той же
     -- недели с 10 до 20 (п.7). Ночью — ничего.
     where x.hr between 10 and 19
       and not exists (
         select 1 from public.debt_reminder_runs r
          where r.center_id = x.id and r.week_start = x.week_start
       )
     order by x.id
  loop
    -- Сбой одного центра не отменяет остальные; отметка недели откатывается
    -- вместе с ним — центр перепробуется в следующий час (как 0052 Р7).
    begin
      insert into public.debt_reminder_runs (center_id, week_start)
      values (c.id, c.week_start)
      on conflict (center_id, week_start) do nothing;
      if not found then
        continue;
      end if;

      -- Выключенный тип — неделя отмечена, событий нет (п.14).
      if not public.center_notification_enabled(c.id, 'debt.reminder') then
        continue;
      end if;

      -- Сотрудник для подмены — детерминированно, как digest_debt_text (0077 Р2).
      v_user := null;
      select m.user_id into v_user
        from public.memberships m
       where m.center_id = c.id and m.role in ('owner', 'admin')
       order by (m.role = 'owner') desc, m.user_id
       limit 1;
      if v_user is null then
        continue;
      end if;

      for p in
        select d.payer_id
          from public.debt_payers_center(v_user, c.id) d
         -- Без живого родителя сообщение некому (п.14).
         where exists (
           select 1 from public.memberships m
            where m.center_id = c.id and m.role = 'parent' and m.payer_id = d.payer_id
         )
         order by d.payer_id
      loop
        perform public.emit_event_unchecked(
          'debt.reminder',
          jsonb_build_object('center_id', c.id, 'payer_id', p.payer_id, 'week_start', c.week_start),
          c.id
        );
        v_count := v_count + 1;
      end loop;
    exception when others then
      raise warning 'debt_reminders_at: центр %, %', c.id, sqlerrm;
    end;
  end loop;

  return v_count;
end;
$$;

comment on function public.debt_reminders_at(timestamptz) is
  'Напоминания о долге раз в неделю (0097 В2): первый прогон недели с понедельника 10:00 (пропущенный — в любой день недели с 10 до 20) по часам центра; один расчёт должников на центр (debt_payers_center), отметка debt_reminder_runs на центр и неделю; событие debt.reminder на плательщика с живым родителем. Сумма — при доставке. Внутренняя: SECURITY INVOKER, грантов нет ни у кого.';

revoke all on function public.debt_reminders_at(timestamptz)
  from public, anon, authenticated, service_role, bot_worker;


-- 8. Абонемент на срок заканчивается (В3, п.8) ------------------------------------------------

create table if not exists public.subscription_period_reminders_sent (
  subscription_id uuid not null,
  center_id       uuid not null references public.centers (id) on delete cascade,
  ends_at         date not null,
  sent_at         timestamptz not null default now(),
  primary key (subscription_id, ends_at),
  constraint subscription_period_reminders_sent_sub_fk
    foreign key (subscription_id, center_id) references public.subscriptions (id, center_id) on delete cascade
);

comment on table public.subscription_period_reminders_sent is
  'Напоминание об окончании абонемента на срок отправлено (0097 В3). ends_at в ключе: заморозка сдвинула срок — новое напоминание к новой дате. Строки кладёт только period_subscription_reminders_at().';

create index if not exists subscription_period_reminders_sent_center_idx
  on public.subscription_period_reminders_sent (center_id);

alter table public.subscription_period_reminders_sent enable row level security;

drop policy if exists subscription_period_reminders_sent_read on public.subscription_period_reminders_sent;
create policy subscription_period_reminders_sent_read on public.subscription_period_reminders_sent
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() in ('owner', 'admin')
  );

revoke all on table public.subscription_period_reminders_sent from public, anon, authenticated, service_role;
grant select on public.subscription_period_reminders_sent to authenticated;


create or replace function public.period_subscription_reminders_at(p_now timestamptz)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_count integer := 0;
  r       record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    select s.id, s.center_id, s.student_id, s.ends_at
      from public.subscriptions s
      join public.centers c on c.id = s.center_id and c.deleted_at is null
      join public.students st on st.id = s.student_id and st.deleted_at is null and st.status <> 'archived'
      cross join lateral (
        select (p_now at time zone public.center_timezone(c.id)) as local_now
      ) z
     where s.status = 'active'
       and s.deleted_at is null
       and s.ends_at is not null
       and s.ends_at - z.local_now::date between 0 and 3
       and extract(hour from z.local_now) between 10 and 19
       -- Идущая заморозка: срок ещё сдвинется, напоминать рано.
       and not exists (
         select 1 from public.subscription_freezes f
          where f.subscription_id = s.id and f.period @> z.local_now::date
       )
       and not public.subscription_renewed(s.id)
       and exists (
         select 1 from public.memberships m
          where m.center_id = s.center_id and m.role = 'parent' and m.payer_id = st.payer_id
       )
       and public.center_notification_enabled(s.center_id, 'subscription.period_ending')
       and not exists (
         select 1 from public.subscription_period_reminders_sent x
          where x.subscription_id = s.id and x.ends_at = s.ends_at
       )
     order by s.center_id, s.id
  loop
    insert into public.subscription_period_reminders_sent (subscription_id, center_id, ends_at)
    values (r.id, r.center_id, r.ends_at)
    on conflict (subscription_id, ends_at) do nothing;

    if found then
      perform public.emit_event_unchecked(
        'subscription.period_ending',
        jsonb_build_object('center_id', r.center_id, 'subscription_id', r.id,
                           'student_id', r.student_id, 'ends_at', r.ends_at),
        r.center_id
      );
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

comment on function public.period_subscription_reminders_at(timestamptz) is
  'Абонемент на срок (ends_at is not null) заканчивается через 0–3 дня (0097 В3): с 10 до 20 по часам центра, активный, без идущей заморозки, не продлён (subscription_renewed), у плательщика ребёнка есть родитель. Отметка (subscription_id, ends_at). Внутренняя: SECURITY INVOKER, грантов нет ни у кого.';

revoke all on function public.period_subscription_reminders_at(timestamptz)
  from public, anon, authenticated, service_role, bot_worker;


-- 9. Вход для n8n: новые рассылки отдельно от напоминаний о занятиях (Б2) --------------------

create or replace function public.notification_schedules()
  returns table (teacher_schedules integer, debt_reminders integer, period_reminders integer)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_teacher integer := 0;
  v_debt    integer := 0;
  v_period  integer := 0;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Каждая рассылка в своей подтранзакции: ошибка одной не отменяет остальные.
  -- Отмена по statement_timeout откатит весь вызов — поэтому напоминания о
  -- занятиях живут в lesson_reminders(), отдельной нодой (Б2).
  begin
    v_teacher := public.teacher_schedules_at(now());
  exception when others then
    raise warning 'notification_schedules: teacher.schedule — %', sqlerrm;
  end;

  begin
    v_debt := public.debt_reminders_at(now());
  exception when others then
    raise warning 'notification_schedules: debt.reminder — %', sqlerrm;
  end;

  begin
    v_period := public.period_subscription_reminders_at(now());
  exception when others then
    raise warning 'notification_schedules: subscription.period_ending — %', sqlerrm;
  end;

  return query select v_teacher, v_debt, v_period;
end;
$$;

comment on function public.notification_schedules() is
  'Плановые рассылки этапа 11 (0097): расписание специалистам, долг раз в неделю, окончание абонемента на срок. Запуск раз в час отдельной нодой сценария n8n schedule под bot_worker. Каждая рассылка — в своей подтранзакции; напоминания о занятиях — в lesson_reminders() (Б2).';

revoke all on function public.notification_schedules() from public, anon, authenticated, service_role;
grant execute on function public.notification_schedules() to bot_worker;


-- 10. Отметка посещения со статусом «Уведомлять родителя» (В4, Б3) ----------------------------

create or replace function public.attendance_status_notice()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.status_id is not distinct from old.status_id then
    return null;
  end if;

  if not exists (
    select 1 from public.attendance_statuses st
     where st.id = new.status_id and st.notify_parent
  ) then
    return null;
  end if;

  perform public.emit_event_internal('attendance.status_changed',
    jsonb_build_object('center_id', new.center_id, 'attendance_id', new.id,
                       'lesson_id', new.lesson_id, 'student_id', new.student_id,
                       'status_id', new.status_id), new.center_id);
  return null;
end;
$$;

comment on function public.attendance_status_notice() is
  'Событие attendance.status_changed (0097 В4, Б3): отметка поставлена или статус реально сменился, и у статуса notify_parent. status_id — в payload: доставка сверяет его с текущим. Отдельно от attendance_recalc_trigger (тот эмитит attendance.marked и на смену цены/абонемента). Центр — из строки attendance.';

revoke all on function public.attendance_status_notice() from public, anon, authenticated, service_role, bot_worker;

drop trigger if exists attendance_status_notice on public.attendance;
create trigger attendance_status_notice
  after insert or update of status_id on public.attendance
  for each row execute function public.attendance_status_notice();


-- 11. event_messages: новые ветки и {day} -----------------------------------------------------

-- Переиздаётся целиком от последней редакции (0077): поиск
-- "create or replace function public.event_messages" по всем миграциям.
-- Отличия от 0077: объявления v_lesson_id/v_starts/v_status/v_att/v_teacher/v_list/v_n,
-- ветка lesson.reminder (center_id, starts_at из payload, {day}) и ветки
-- debt.reminder, subscription.period_ending, attendance.status_changed,
-- teacher.schedule перед общим хвостом.
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
  v_debt_text text;
  v_user     uuid;
  v_ends     date;
  v_starts   timestamptz;
  v_status   text;
  v_day      date;
  v_n        integer;
  v_list     text;
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
     where l.id = (v_event.payload ->> 'lesson_id')::uuid
       and l.center_id = v_event.center_id;

    -- 0097 п.9: занятие перенесли после напоминания (у нового времени своё
    -- напоминание) или оно уже началось — пусто. starts_at в payload кладёт
    -- lesson_reminders с 0032; событие без него (вставленное руками в тестах
    -- до 0075) сверяется только по началу.
    if not found or v_lesson.deleted_at is not null or v_lesson.status <> 'planned'
       or (v_event.payload ? 'starts_at'
           and v_lesson.starts_at is distinct from (v_event.payload ->> 'starts_at')::timestamptz)
       or v_lesson.starts_at <= now() then
      return;
    end if;

    -- 0097 В1: {day} — «сегодня», «завтра» или дата на момент доставки.
    v_vars := jsonb_build_object(
      'date',    to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY'),
      'time',    to_char(v_lesson.starts_at at time zone v_tz, 'HH24:MI'),
      'day',     public.lesson_reminder_day(v_lesson.starts_at, v_tz, now()),
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

  -- 0097 В2: долг раз в неделю — сумма на момент доставки тем же расчётом,
  -- что /balance в боте (bot_balance_center от имени родителя плательщика):
  -- долг за занятия с перерасходом и просрочка по абонементу — отдельно, не
  -- складываются (0077 Р6). Ошибка расчёта всплывает (п.13): fail_events
  -- повторит доставку, а не запишет «получателей нет».
  if v_event.type = 'debt.reminder' then
    v_payer := (v_event.payload ->> 'payer_id')::uuid;

    select m.user_id into v_user
      from public.memberships m
     where m.center_id = v_event.center_id
       and m.role = 'parent'
       and m.payer_id = v_payer
     order by m.user_id
     limit 1;
    if v_user is null then
      return;
    end if;

    return query
      with b as (
        select x.student_id, x.full_name,
               x.debt_tiyin, x.overdue_tiyin
          from public.bot_balance_center(v_user, v_event.center_id) x
         where x.debt_tiyin > 0 or x.overdue_tiyin > 0
      )
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', b.full_name,
               'debt', concat_ws('; ',
                 case when b.debt_tiyin > 0 then 'долг за занятия — ' || public.format_som(b.debt_tiyin) end,
                 case when b.overdue_tiyin > 0 then 'просрочка по абонементу — ' || public.format_som(b.overdue_tiyin) end)
             )),
             b.student_id,
             null::jsonb
        from b
        cross join lateral public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0097 В3: абонемент на срок заканчивается. Всё перечитывается на момент
  -- доставки: отменён, в архиве, срок сдвинут или продлён — пусто.
  -- Получатель — текущий плательщик ребёнка (п.8).
  if v_event.type = 'subscription.period_ending' then
    select s.student_id, st.full_name, st.payer_id, s.ends_at
      into v_student, v_child, v_payer, v_ends
      from public.subscriptions s
      join public.students st on st.id = s.student_id and st.deleted_at is null and st.status <> 'archived'
     where s.id = (v_event.payload ->> 'subscription_id')::uuid
       and s.center_id = v_event.center_id
       and s.status = 'active'
       and s.deleted_at is null
       and s.ends_at = (v_event.payload ->> 'ends_at')::date
       and s.ends_at >= (now() at time zone v_tz)::date;
    if v_student is null or public.subscription_renewed((v_event.payload ->> 'subscription_id')::uuid) then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', v_child,
               'date',  to_char(v_ends, 'DD.MM.YYYY')
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0097 В4, Б3: отметка со статусом «Уведомлять родителя». Пусто, если
  -- событие старше 12 часов, занятию больше 3 суток, статус с тех пор
  -- сменили (уйдёт по своему событию) или галочку сняли; тому же получателю
  -- то же (отметка, статус) уже уходило — не повторяем.
  if v_event.type = 'attendance.status_changed' then
    if v_event.created_at < now() - interval '12 hours' then
      return;
    end if;

    select a.student_id, st.full_name, st.payer_id, l.starts_at, ast.name
      into v_student, v_child, v_payer, v_starts, v_status
      from public.attendance a
      join public.attendance_statuses ast on ast.id = a.status_id and ast.notify_parent
      join public.lessons l on l.id = a.lesson_id and l.deleted_at is null
      join public.students st on st.id = a.student_id and st.deleted_at is null
     where a.id = (v_event.payload ->> 'attendance_id')::uuid
       and a.center_id = v_event.center_id
       and a.status_id = (v_event.payload ->> 'status_id')::uuid
       and l.starts_at >= now() - interval '3 days';
    if v_student is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child',  v_child,
               'date',   to_char(v_starts at time zone v_tz, 'DD.MM.YYYY'),
               'time',   to_char(v_starts at time zone v_tz, 'HH24:MI'),
               'status', v_status
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r
       where not exists (
         select 1
           from public.events e2
           join public.notification_log nl on nl.event_id = e2.id
          where e2.center_id = v_event.center_id
            and e2.type = 'attendance.status_changed'
            and e2.created_at >= now() - interval '4 days'
            and e2.id <> v_event.id
            and e2.payload ->> 'attendance_id' = v_event.payload ->> 'attendance_id'
            and e2.payload ->> 'status_id' = v_event.payload ->> 'status_id'
            and nl.recipient_user_id = r.user_id
            and nl.status in ('pending', 'sent', 'no_channel')
       );
    return;
  end if;

  -- 0097 В5: расписание специалисту на завтра — список на момент доставки
  -- (отмены и переносы учтены), только telegram, не длиннее 30 строк; {center}
  -- — у специалиста бывает два центра (п.16). Карточка и занятия — только
  -- центра события (п.12).
  if v_event.type = 'teacher.schedule' then
    -- Текст говорит «Завтра»: доставка в сам день занятий или позже (простой
    -- n8n за полночь) — пусто.
    v_day := (v_event.payload ->> 'date')::date;
    if v_day <= (now() at time zone v_tz)::date then
      return;
    end if;

    select t.profile_id into v_user
      from public.teachers t
     where t.id = (v_event.payload ->> 'teacher_id')::uuid
       and t.center_id = v_event.center_id
       and t.deleted_at is null;
    if v_user is null then
      return;
    end if;

    select count(*)::integer,
           string_agg(x.line, chr(10) order by x.starts_at, x.id) filter (where x.rn <= 30)
      into v_n, v_list
      from (
        select l.id, l.starts_at,
               row_number() over (order by l.starts_at, l.id) as rn,
               to_char(l.starts_at at time zone v_tz, 'HH24:MI') || ' — '
                 || coalesce(s.full_name, 'группа «' || g.name || '»', '—') as line
          from public.lessons l
          left join public.students s on s.id = l.student_id
          left join public.groups g on g.id = l.group_id
         where l.center_id = v_event.center_id
           and l.effective_teacher_id = (v_event.payload ->> 'teacher_id')::uuid
           and l.status = 'planned'
           and l.deleted_at is null
           and (l.starts_at at time zone v_tz)::date = v_day
      ) x;
    if coalesce(v_n, 0) = 0 then
      return;
    end if;
    if v_n > 30 then
      v_list := v_list || chr(10) || '…и ещё ' || (v_n - 30)::text;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'date',         to_char(v_day, 'DD.MM.YYYY'),
               'center',       coalesce((select c.name from public.centers c where c.id = v_event.center_id), ''),
               'lesson_count', v_n::text || ' ' || case
                                 when v_n % 10 = 1 and v_n % 100 <> 11 then 'занятие'
                                 when v_n % 10 between 2 and 4 and v_n % 100 not between 12 and 14 then 'занятия'
                                 else 'занятий' end,
               'lesson_list',  v_list
             )),
             null::uuid,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_user, v_event.type) r
       where r.channel = 'telegram';
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
    -- 0077: {debt} — общее определение «должника» (student_debt_summary через
    -- digest_debt_text), на момент доставки, а не payload.debt_tiyin (0032:
    -- только debt_tiyin, без перерасхода и просрочки). Центр — events.center_id.
    v_debt_text := public.digest_debt_text(v_event.center_id);
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'date',    to_char((v_event.payload ->> 'date')::date, 'DD.MM.YYYY'),
               'lessons', coalesce(v_event.payload ->> 'lessons_today', '0'),
               'low',     coalesce(v_event.payload ->> 'low_balance', '0'),
               'debt',    v_debt_text,
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
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4), с 0047 — только в telegram. Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. lesson.note_approved (0047) — резюме родителю, {summary} только в telegram и не длиннее 3500 символов; lesson.voice_failed (0047) — заказчику диктовки через notification_user_targets, без причины отказа и только пока повтор диктовки имеет смысл (условие ai_job_begin). 0051: platform.payment_submitted — администраторам платформы (notification_platform_targets, шаблон только дефолтный), subscription.extended — owner/admin центра с {until} в поясе центра, subscription.voice_blocked — заказчику диктовки, {child} только в telegram. 0052: subscription.ending/expired — owner/admin центра, {what}/{until}/{when} на момент доставки в поясе центра. 0053: ai.quota_exceeded — заказчику диктовки ({child} с предлогом, только telegram) и owner/admin центра без {child}, {used}/{limit} в оба канала, пока повтор диктовки имеет смысл. 0056: center.deletion_requested — owner/admin центра, без переменных. 0057: booking.requested — стойке (owner/admin/registrar) через notification_front_desk_targets, {child}/{teacher}/{when}/{phone} читаются заново из booking_requests на момент доставки, не из payload. Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать. 0073: digest.daily — {payments} («за ДД.ММ: сумма (операций: N)» или «платежей не было») считается из платежей на момент доставки (center_payments_day), не из payload. 0077: {debt} в digest.daily — общее определение «должника» из student_debt_summary (долг за занятия с перерасходом; при просрочке по абонементам — «; просрочка по абонементам — сумма», суммы не складываются), считается на момент доставки через digest_debt_text от имени владельца центра (events.center_id), payload.debt_tiyin не читается; при сбое расчёта — «не удалось посчитать — см. /debts», а не ноль. {overdue} — по-прежнему число просроченных рассрочек из payload. 0097: lesson.reminder — {day} («сегодня»/«завтра»/дата на момент доставки), занятие только центра события, пусто при переносе после напоминания (starts_at из payload) и после начала; debt.reminder — родителям плательщика, сумма на момент доставки через bot_balance_center (долг за занятия и просрочка по абонементу раздельно), ошибка расчёта всплывает; subscription.period_ending — перечитывает абонемент (активен, срок тот же, не продлён), получатель — текущий плательщик ребёнка; attendance.status_changed — только пока статус тот же и с галочкой, событие моложе 12 часов, занятие моложе 3 суток, без повтора той же пары (отметка, статус) тому же получателю; teacher.schedule — специалисту только в telegram, список занятий на дату на момент доставки, не длиннее 30 строк.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;


-- 12. preview_message: образцы новых переменных (п.10) ------------------------------------------

-- От последней редакции (0077); добавлены только образцы day/debt.reminder/status/center/lesson_*.
-- {debt} у debt.reminder и у digest.daily — разный по смыслу, образец общий:
-- предпросмотр вызывается без p_vars (settings/notifications/actions.ts).
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
      'debt', public.format_som(70000) || '; просрочка по абонементам — ' || public.format_som(120000),
      'overdue', '0',
      'payments', 'за 30.09: ' || public.format_som(1250000) || ' (операций: 7)',
      'day', 'завтра',
      'status', 'Прогул',
      'center', 'Логопедический центр',
      'lesson_count', '3 занятия',
      'lesson_list', '09:00 — Айдана' || chr(10) || '10:00 — Тимур' || chr(10) || '11:00 — группа «Звуки»'
    ))
  );
end;
$$;

comment on function public.preview_message(text, jsonb) is 'Предпросмотр шаблона на образцовых данных — тем же рендером, что и отправка.';

revoke all on function public.preview_message(text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.preview_message(text, jsonb) to authenticated;


-- 13. Заборы-каталоги (Б4) ---------------------------------------------------------------------

-- От последних редакций: readonly_guard_exempt_tables — 0063, export_center_excluded_tables — 0094.
-- Три новые отметки планировщика — под guard не ставятся (он срабатывает
-- только при auth.uid() is not null, а пишет их только воркер) и в выгрузку
-- центра не идут (не данные центра).
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
    ('subscription_period_reminders_sent', 'Р3: отметка планировщика (0097)')
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
    ('subscription_period_reminders_sent', 'Отметка планировщика (0097)')
$$;

revoke all on function public.export_center_excluded_tables() from public, anon, authenticated, service_role;
