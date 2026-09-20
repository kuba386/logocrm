-- =============================================================================
-- 0043_monthly_report.sql — месячный отчёт родителю (этап 7c, часть 1)
--
-- Родитель раз в месяц получает связную картину: сколько занятий было и
-- сколько пропущено, что с целями, что писал специалист. Формирует
-- специалист или администрация; на экране печатная версия, в Telegram —
-- короткая выжимка через существующую очередь.
--
-- Решения (план и его ревью — reports/stage-7.md, «Plan — 7c, часть 1»):
--   Р1. Сборщик отчёта НЕ ходит в goal_progress, lesson_notes, diagnostics
--       и attendance напрямую — только через узкие функции. Если собирать
--       прямыми запросами внутри definer-функции, первая же правка
--       «добавим ещё поле» вынесет наружу расшифровку голосового или
--       внутреннюю пометку специалиста, и заметит это не тест, а родитель.
--       Проверяется канарейками в pgTAP, а не глазами.
--   Р2. Динамику целей существующие функции не отдают: student_goals_brief
--       не принимает период и знает только последнюю оценку. Отчёт за
--       сентябрь, открытый в ноябре, показал бы ноябрьскую оценку и цель,
--       заведённую в октябре. Отсюда student_goal_dynamics_brief с
--       периодом — и без колонки note в возвращаемом типе физически.
--   Р3. Чтение и отправка — разные функции с разными правами. Любой
--       единственный гейт неверен: пропустить родителя значит дать ему
--       рассылать себе сообщения мимо решения центра, не пропустить —
--       лишить его собственного отчёта. Бессрочный доступ специалиста
--       (0036 Р3) на исходящие сообщения семье не переносится: читать
--       историю через год нормально, писать семье от имени центра — нет.
--   Р4. Снимок, а не пересчёт. 25 сентября ушло «достигнуто целей: 1»,
--       5 октября специалист утвердил запоздавшую заметку и закрыл вторую
--       — родитель открывает страницу и видит другие числа, а кто прав, не
--       скажет никто. Текст и числа замораживаются в реестре, событие
--       несёт тот же снимок.
--   Р5. Реестр, а не отметка «отправлено». Булево не держит ни повтор
--       (месяц приходит датой: 1-е и 17-е дают две строки), ни гонку (два
--       администратора жмут одновременно), ни историю повторных отправок.
--   Р6. Архивный ребёнок: отчёт недоступен. clinical_visible_to_caller
--       содержит проверку «не в архиве», и по архивному ребёнку все узкие
--       функции молчат — получилась бы пустая страница, неотличимая от
--       «занятий не было». Править видимость ради отчёта нельзя: на ней
--       держится вся клиника 7a.
--   Р7. Пустой месяц: формировать можно, отправлять нечего. Отчёт «0
--       занятий, 0 целей» семье, которая болела весь месяц, читается как
--       поломка.
--   Р8. Границы месяца — в поясе центра, и дата занятия берётся из
--       lessons.starts_at, а не из времени отметки: занятие 30 сентября,
--       отмеченное 1 октября, обязано остаться в сентябре.
--   Р9. «Строка от специалиста» — колонка в реестре, а не догадка. Иначе
--       один автор подставит резюме последнего занятия как итог месяца,
--       другой заведёт поле, текст которого нигде не сохранится.
--  Р10. Реестр закрыт на запись: политика только на чтение, руками, а не
--       через apply_tenant_rls — она дала бы owner/admin право обнулить
--       счётчик отправок и разослать второй раз (довод 0032).
-- =============================================================================


-- 1. Посещаемость за период — узко ------------------------------------------------------------------

-- Возвращает ровно дату, статус и признак пропуска. Ни цены занятия, ни
-- абонемента, ни того, кто отметил, ни комментария — там свободный текст
-- стойки («мама опоздала, ребёнок плакал»).
--
-- Честно: эта функция НЕ сужает приватность attendance. Политика
-- attendance_parent_read (0009) жива, и комментарий родитель может
-- прочитать прямым запросом уже сегодня — это закрывает следующая
-- миграция, отдельным решением со своим тестом.
create or replace function public.student_attendance_brief(
  p_student_id uuid,
  p_from       date,
  p_to         date
)
  returns table (lesson_at timestamptz, status_name text, counts_absence boolean)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_tz     text;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'Укажите период' using errcode = '22023';
  end if;

  -- Явным списком, а не через clinical_visible_to_caller: посещаемость и
  -- клиника — разные классы, и смешивать их гейты значит однажды открыть
  -- не то. Стойке и бухгалтеру эта функция не нужна: у них своя работа с
  -- attendance, и она идёт мимо отчёта родителю.
  if not (
    v_role in ('owner', 'admin')
    or (v_role = 'teacher' and public.clinical_teacher_sees(p_student_id))
    or (v_role = 'parent'  and public.parent_of_student(p_student_id))
  ) then
    return;
  end if;

  v_tz := public.center_timezone(v_center);

  return query
    select l.starts_at, st.name, a.counts_absence
      from public.attendance a
      join public.lessons l on l.id = a.lesson_id
      join public.attendance_statuses st on st.id = a.status_id
     where a.student_id = p_student_id
       and a.center_id = v_center
       and l.deleted_at is null
       -- Р8: по дате занятия, а не по времени отметки.
       and (l.starts_at at time zone v_tz)::date >= p_from
       and (l.starts_at at time zone v_tz)::date <= p_to
     order by l.starts_at;
end;
$$;

comment on function public.student_attendance_brief(uuid, date, date) is
  'Посещения за период: дата занятия, статус, признак пропуска. Ни цены, ни абонемента, ни комментария к отметке — там свободный текст стойки (0043 Р1).';

revoke all on function public.student_attendance_brief(uuid, date, date) from public, anon, service_role;
grant execute on function public.student_attendance_brief(uuid, date, date) to authenticated;


-- 2. Динамика целей за период -----------------------------------------------------------------------

-- Р2: student_goals_brief периода не принимает и знает только последнюю
-- оценку. Колонки note здесь нет физически — это внутренняя пометка
-- специалиста, тот же класс, что payers.notes у бухгалтера (0031).
create or replace function public.student_goal_dynamics_brief(
  p_student_id uuid,
  p_from       date,
  p_to         date
)
  returns table (
    goal_id     uuid,
    title       text,
    stage_title text,
    score_first integer,
    score_last  integer,
    points      integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if not public.clinical_visible_to_caller(p_student_id) then
    return;
  end if;
  if p_from is null or p_to is null then
    raise exception 'Укажите период' using errcode = '22023';
  end if;

  return query
    with points as (
      select gp.goal_id, gp.score, gp.date,
             row_number() over (partition by gp.goal_id order by gp.date, gp.created_at) as first_n,
             row_number() over (partition by gp.goal_id order by gp.date desc, gp.created_at desc) as last_n,
             count(*) over (partition by gp.goal_id) as total
        from public.goal_progress gp
        join public.goals g on g.id = gp.goal_id
       where g.student_id = p_student_id
         and g.center_id = public.current_center()
         and g.deleted_at is null
         and gp.deleted_at is null
         and gp.date >= p_from and gp.date <= p_to
    )
    select g.id, g.title, st.title,
           max(case when p.first_n = 1 then p.score end)::integer,
           max(case when p.last_n  = 1 then p.score end)::integer,
           max(p.total)::integer
      from points p
      join public.goals g on g.id = p.goal_id
      join public.goal_stages st on st.id = g.stage_id
     group by g.id, g.title, st.title, st.sort
     order by st.sort, g.title;
end;
$$;

comment on function public.student_goal_dynamics_brief(uuid, date, date) is
  'Динамика целей за период: первая и последняя оценка, число точек. Колонки note нет физически — это пометка специалиста, а не текст для родителя (ADR-005, четвёртое применение).';

revoke all on function public.student_goal_dynamics_brief(uuid, date, date) from public, anon, service_role;
grant execute on function public.student_goal_dynamics_brief(uuid, date, date) to authenticated;


-- 3. Реестр отчётов ----------------------------------------------------------------------------------

create table if not exists public.monthly_reports (
  id              uuid primary key default gen_random_uuid(),
  center_id       uuid not null references public.centers (id) on delete cascade,
  student_id      uuid not null,
  -- Р5: месяц нормализован. Иначе вызовы с 1-м и 17-м числом дадут две
  -- строки, уникальность промолчит, и родитель получит два сообщения.
  period_month    date not null check (period_month = date_trunc('month', period_month)::date),

  generated_at    timestamptz not null default now(),
  generated_by    uuid,
  -- Р9: то, что специалист хочет сказать родителю от себя.
  teacher_comment text,
  -- Р4: снимок на момент отправки, а не пересчёт при каждом открытии.
  summary_text    text,
  stats           jsonb not null default '{}'::jsonb,

  -- Р5: «поставлено в очередь» и факт доставки — разное. Доставку знает
  -- notification_log, здесь только намерение.
  queued_at       timestamptz,
  sent_count      integer not null default 0 check (sent_count >= 0),
  first_sent_at   timestamptz,
  last_sent_at    timestamptz,
  last_event_id   bigint,

  constraint monthly_reports_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade,
  constraint monthly_reports_period_key unique (center_id, student_id, period_month)
);

comment on table public.monthly_reports is
  'Реестр месячных отчётов: снимок текста и чисел на момент отправки плюс счётчик отправок. Не отметка «отправлено» — булево не держит ни повтор, ни гонку двух администраторов (0043 Р5). Закрыт на запись: пишет только send_monthly_report.';

create index if not exists monthly_reports_student_idx
  on public.monthly_reports (student_id, period_month desc);

alter table public.monthly_reports enable row level security;

-- Р10: политика руками, только чтение. apply_tenant_rls дала бы owner/admin
-- право на update, а обнуление sent_count вернуло бы вторую отправку.
drop policy if exists monthly_reports_admin_read on public.monthly_reports;
create policy monthly_reports_admin_read on public.monthly_reports
  for select to authenticated
  using (
    center_id = public.current_center()
    and coalesce(public.my_role(), '') in ('owner', 'admin')
  );

revoke all on table public.monthly_reports from public, anon, authenticated, service_role;
grant select on public.monthly_reports to authenticated;


-- 4. Чтение отчёта -------------------------------------------------------------------------------

create or replace function public.student_monthly_report(p_student_id uuid, p_month date)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_month   date := date_trunc('month', p_month)::date;
  v_to      date;
  v_att     jsonb;
  v_goals   jsonb;
  v_notes   jsonb;
  v_total   integer := 0;
  v_absent  integer := 0;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if p_month is null then
    raise exception 'Укажите месяц' using errcode = '22023';
  end if;

  -- Р3: читать может тот же круг, что видит клинику ребёнка, — включая
  -- родителя. Р6: по архивному ребёнку узкие функции молчат, и вместо
  -- пустой страницы, неотличимой от «занятий не было», честный отказ.
  if not public.clinical_visible_to_caller(p_student_id) then
    if exists (select 1 from public.students s
                where s.id = p_student_id and s.center_id = v_center and s.deleted_at is not null) then
      raise exception 'Ребёнок в архиве — отчёт недоступен' using errcode = '42704';
    end if;
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  v_to := (v_month + interval '1 month' - interval '1 day')::date;

  -- Р1: только узкие функции. Ни одного select из attendance,
  -- goal_progress, lesson_notes, diagnostics.
  select coalesce(jsonb_agg(jsonb_build_object(
           'date',   to_char(a.lesson_at at time zone public.center_timezone(v_center), 'DD.MM.YYYY'),
           'status', a.status_name
         ) order by a.lesson_at), '[]'::jsonb),
         count(*)::integer,
         count(*) filter (where a.counts_absence)::integer
    into v_att, v_total, v_absent
    from public.student_attendance_brief(p_student_id, v_month, v_to) a;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', g.title,
           'stage', g.stage_title,
           'from',  g.score_first,
           'to',    g.score_last,
           'points', g.points
         )), '[]'::jsonb)
    into v_goals
    from public.student_goal_dynamics_brief(p_student_id, v_month, v_to) g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'date',    to_char(n.lesson_at at time zone public.center_timezone(v_center), 'DD.MM.YYYY'),
           'summary', n.parent_summary
         ) order by n.lesson_at), '[]'::jsonb)
    into v_notes
    from public.student_notes_brief(p_student_id) n
   where (n.lesson_at at time zone public.center_timezone(v_center))::date >= v_month
     and (n.lesson_at at time zone public.center_timezone(v_center))::date <= v_to;

  return jsonb_build_object(
    'student_id',      p_student_id,
    'student_name',    (select s.full_name from public.students s where s.id = p_student_id),
    'period_month',    v_month,
    'lessons_total',   v_total,
    'absences',        v_absent,
    'attendance',      v_att,
    'goals',           v_goals,
    'notes',           v_notes,
    'teacher_comment', (select r.teacher_comment from public.monthly_reports r
                         where r.center_id = v_center and r.student_id = p_student_id
                           and r.period_month = v_month),
    'is_empty',        (v_total = 0 and jsonb_array_length(v_notes) = 0),
    'generated_at',    now()
  );
end;
$$;

comment on function public.student_monthly_report(uuid, date) is
  'Отчёт за месяц для экрана. Собран только из узких функций (Р1): прямых обращений к attendance, goal_progress и lesson_notes здесь нет, чтобы правка «добавим ещё поле» не вынесла наружу рабочий материал специалиста.';

revoke all on function public.student_monthly_report(uuid, date) from public, anon, service_role;
grant execute on function public.student_monthly_report(uuid, date) to authenticated;


-- 5. Отправка ------------------------------------------------------------------------------------

create or replace function public.send_monthly_report(
  p_student_id uuid,
  p_month      date,
  p_comment    text default null,
  p_force      boolean default false
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_month  date := date_trunc('month', p_month)::date;
  v_to     date;
  v_report jsonb;
  v_row    public.monthly_reports;
  v_text   text;
  v_event  bigint;
  v_goals  text;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  -- Р3: отправлять — не то же, что читать. Специалист вправе написать
  -- семье, только если вёл ребёнка В ЭТОМ месяце; бессрочный доступ к
  -- истории (0036 Р3) исходящих сообщений не даёт. Родителю — явный
  -- отказ, а не пустой результат: иначе он не поймёт, почему ничего не
  -- произошло.
  v_to := (v_month + interval '1 month' - interval '1 day')::date;

  if v_role not in ('owner', 'admin') then
    if v_role <> 'teacher' then
      raise exception 'Отчёт отправляет специалист или администрация' using errcode = '42501';
    end if;
    if not exists (
      select 1
        from public.lesson_participants lp
        join public.lessons l on l.id = lp.lesson_id
       where lp.student_id = p_student_id
         and lp.deleted_at is null
         and l.deleted_at is null
         and l.status <> 'cancelled'
         and l.center_id = v_center
         and (l.teacher_id = public.my_teacher_id() or l.substitute_teacher_id = public.my_teacher_id())
         and (l.starts_at at time zone public.center_timezone(v_center))::date between v_month and v_to
    ) then
      raise exception 'В этом месяце занятий с ребёнком не было' using errcode = '42501';
    end if;
  end if;

  v_report := public.student_monthly_report(p_student_id, v_month);

  -- Р7: пустой месяц формируется, но не рассылается.
  if (v_report ->> 'is_empty')::boolean then
    raise exception 'За этот месяц отправлять нечего: занятий не было' using errcode = '22023';
  end if;

  -- Р5: вставка и событие в одной транзакции, ветвление по факту вставки.
  insert into public.monthly_reports
    (center_id, student_id, period_month, generated_by, teacher_comment)
  values
    (v_center, p_student_id, v_month, auth.uid(), nullif(trim(coalesce(p_comment, '')), ''))
  on conflict (center_id, student_id, period_month) do nothing
  returning * into v_row;

  if not found then
    select * into v_row from public.monthly_reports
     where center_id = v_center and student_id = p_student_id and period_month = v_month
     for update;

    if v_row.sent_count > 0 and not p_force then
      raise exception 'Отчёт за этот месяц уже отправляли % — повторите с явным подтверждением',
        to_char(v_row.last_sent_at at time zone public.center_timezone(v_center), 'DD.MM.YYYY HH24:MI')
        using errcode = '23505';
    end if;

    if v_row.sent_count > 0 and v_role not in ('owner', 'admin') then
      raise exception 'Повторную отправку делает администрация' using errcode = '42501';
    end if;

    update public.monthly_reports
       set teacher_comment = coalesce(nullif(trim(coalesce(p_comment, '')), ''), teacher_comment),
           generated_at = now(), generated_by = auth.uid()
     where id = v_row.id;
  end if;

  -- Р4: текст замораживается здесь и уходит в событие целиком. Иначе
  -- доставка через минуту после правки заметки даст третий вариант.
  select string_agg(
           format('%s: %s→%s', g ->> 'title', coalesce(g ->> 'from', '—'), coalesce(g ->> 'to', '—')),
           '; ' order by ord
         )
    into v_goals
    from (
      select value as g, row_number() over () as ord
        from jsonb_array_elements(v_report -> 'goals')
       limit 3
    ) s;

  v_text := left(format(
    'Отчёт за %s по %s. Занятий: %s, пропусков: %s.%s%s',
    to_char(v_month, 'MM.YYYY'),
    v_report ->> 'student_name',
    v_report ->> 'lessons_total',
    v_report ->> 'absences',
    case when v_goals is null then '' else ' Цели — ' || v_goals || '.' end,
    case when v_row.teacher_comment is null then '' else ' ' || v_row.teacher_comment end
  ), 3500);

  update public.monthly_reports
     set summary_text  = v_text,
         stats         = jsonb_build_object(
                           'lessons_total', v_report -> 'lessons_total',
                           'absences',      v_report -> 'absences',
                           'goals',         v_report -> 'goals'),
         queued_at     = now(),
         sent_count    = sent_count + 1,
         first_sent_at = coalesce(first_sent_at, now()),
         last_sent_at  = now()
   where id = v_row.id;

  v_event := public.emit_event(
    'report.monthly_ready',
    jsonb_build_object(
      'student_id',   p_student_id,
      'period_month', v_month,
      'summary',      v_text
    ),
    v_center
  );

  update public.monthly_reports set last_event_id = v_event where id = v_row.id;

  return jsonb_build_object('report_id', v_row.id, 'event_id', v_event, 'summary', v_text);
end;
$$;

comment on function public.send_monthly_report(uuid, date, text, boolean) is
  'Поставить отчёт в очередь на отправку. Права шире чтения не делают: специалист отправляет, только если вёл ребёнка в этом месяце (Р3). Пустой месяц не рассылается (Р7), повтор — только с явным подтверждением и только администрацией (Р5).';

revoke all on function public.send_monthly_report(uuid, date, text, boolean) from public, anon, service_role;
grant execute on function public.send_monthly_report(uuid, date, text, boolean) to authenticated;


-- 6. Доставка ------------------------------------------------------------------------------------

-- Без строки в белом списке шаблон не вставить вовсе: message_templates
-- ссылается на него внешним ключом (0037 Р4), и миграция упала бы здесь.
insert into public.notification_event_types (event_type, description) values
  ('report.monthly_ready', 'Месячный отчёт родителю')
on conflict (event_type) do nothing;

-- Два шаблона, а не один: notification_targets выбирает канал по наличию
-- чата, и родитель без Telegram получил бы ноль строк — «отправлено» на
-- экране, тишина у родителя и строка skipped в журнале, которую никто не
-- читает.
--
-- Текст whatsapp намеренно пустой по содержанию: он попадает в кнопку
-- копирования на экране администратора, то есть клиника покидает
-- защищённый канал руками. Выжимка с числами — только в Telegram.
insert into public.message_templates (center_id, event_type, channel, text) values
  (null, 'report.monthly_ready', 'telegram', '{summary}'),
  (null, 'report.monthly_ready', 'whatsapp_link',
   'Здравствуйте! Отчёт за {month} по {child} готов — расскажем на занятии или пришлём в приложении.')
on conflict do nothing;


-- Переиздание целиком: у event_messages нельзя изменить тело через
-- create or replace без потери ветвления, а состав колонок тот же, что в
-- 0035 — значит create or replace достаточно, drop не нужен.
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

  -- 0043: месячный отчёт. Текст уже заморожен в событии (Р4) — здесь он
  -- только подставляется, ничего не пересчитывается.
  if v_event.type = 'report.monthly_ready' then
    v_student := (v_event.payload ->> 'student_id')::uuid;

    select s.payer_id into v_payer
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'summary', coalesce(v_event.payload ->> 'summary', ''),
               'month',   to_char((v_event.payload ->> 'period_month')::date, 'MM.YYYY'),
               'child',   (select s.full_name from public.students s where s.id = v_student)
             )),
             -- Обязательно: notification_log_subject_required (0035 Р5)
             -- работает по обратному списку, и null здесь уронил бы
             -- доставку на каждом сообщении.
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
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). Ветка report.monthly_ready подставляет готовый текст из события, а не пересчитывает отчёт (0043 Р4).';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;
