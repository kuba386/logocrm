-- =============================================================================
-- 0058_report_exports.sql — выгрузка отчётов в CSV
-- (docs/Backlog.md, «Отчёты с экспортом CSV/XLSX», владелец 11.09.2026)
--
-- Платежи за период, зарплата за месяц (сводка и детализация),
-- посещаемость за период, долги на сегодня. Файл собирает веб; здесь —
-- строки и след.
--
-- Решения владельца 24.09.2026 (не пересматриваются):
--   В1. Формат — CSV, без новых зависимостей.
--   В2. Деньги (платежи, зарплата, долги) — owner/admin/finance (can_finance);
--       посещаемость — только owner/admin (бухгалтеру attendance закрыта, 0031).
--       Регистратору выгрузка не положена: он видит /app/finance, но
--       выносить базу плательщиков — не его роль.
--   В3. «Долги» — два разных долга двумя колонками, без сложения: по
--       занятиям без абонемента (student_debts, 0031) и недоплата по
--       абонементу (price − paid). Сложить их — третье определение слова
--       «долг» (docs/Database.md, «Два слова, два определения»).
--   В4. След — событие report.exported без адресата (как center.exported,
--       0056); уведомление владельцу не заводится.
--   В5. Период одной выгрузки — не больше года.
--
-- Architect-ревью плана — 14 находок, учтены так:
--   Р1. returns table, не jsonb: порядок и типы колонок фиксирует схема и
--       попадают в database.types.ts — переименование колонки ловит
--       typecheck, а не пустой столбец в CSV.
--   Р2. В payload события — 'by' (auth.uid()) и роль: без актора след не
--       отвечает на вопрос бэклога «кому доступна» (прецедент —
--       center.deletion_requested).
--   Р3. Период проверяется до чтения: null, from > to, дольше года — 22023
--       с текстом, не пустой файл (пусто читается как «платежей не было») и
--       не statement_timeout (0056 Р4).
--   Р4. Имена — только full_name/phone прямым join, без notes/custom_fields
--       (0031); набор колонок зафиксирован сигнатурой returns table и
--       забором pgTAP по точному множеству. Не students_brief()/
--       payers_brief(): те режут deleted_at, а платёж архивного плательщика
--       — всё ещё платёж (Р7), и в отчёте у него должно быть имя.
--   Р5. Обе зарплатные выгрузки — из одного источника: набор специалистов
--       и суммы берёт salary_summary(); детализация для утверждённого
--       месяца — снимок salary_runs.lines, для неутверждённого —
--       calc_salary; колонка approved говорит, что перед тобой.
--   Р6. Посещаемость: и специалист занятия (effective_teacher_id), и кому
--       оплачено (attendance.paid_teacher_id) — иначе после замены файл
--       «не сходится» с зарплатой без колонки, которая это объясняет.
--       Статус занятия — колонкой: planned/cancelled не входят ни в
--       выручку, ни в зарплату.
--   Р7. В денежных отчётах справочники — left join и без deleted_at:
--       архивная карточка — не признак несуществования платежа, иначе
--       итог файла расходится с cash_by_source.
--   Р8. Экранирование формул (=, +, -, @) — в csv.ts на вебе, общий набор
--       случаев в Vitest.
--   Р9. Доставка — server action + Blob, как экспорт центра (0056), не
--       GET-route: ошибка через toAppError на экране, протухшая сессия не
--       превращается в CSV с HTML внутри, префетч ссылки не пишет след.
--   Р10. Даты и время в строках — уже в поясе центра (center_timezone,
--       0052); имя файла — от center_today().
--   Р12. Пояс — один раз на запрос, границы — timestamptz-полуинтервал
--       [from, to+1): фильтр по индексу, а не приведение на строку.
--   Р13. Отказ — всегда исключение 42501; пустой результат значит ровно
--       «строк за период нет». student_debts()/students_brief() отдают
--       пусто без прав по решению 0031 Р3 — здесь гейт свой, до них.
--   Р14. Кнопка на вебе — по тому же предикату, что гейт в SQL.
--   Число строк в событии считает та же функция, что отдаёт данные
--   (get diagnostics после return query) — вызывающий не может подсунуть
--   своё (0056 Р7/Р11). Событие означает «данные покинули базу», а не
--   «файл скачан»: если веб упадёт при сборке CSV, след останется — и это
--   правильно.
-- =============================================================================


-- 1. Проверка периода — общая для платежей и посещаемости ------------------------

-- Внутренний хелпер: без грантов ни одной прикладной роли (та же схема, что
-- refund_calc_unchecked, 0054). Год — цифра владельца (В5).
create or replace function public.report_period_check(p_from date, p_to date)
  returns void
  language plpgsql
  immutable
  set search_path = ''
as $$
begin
  if p_from is null or p_to is null then
    raise exception 'Укажите период выгрузки' using errcode = '22023';
  end if;
  if p_from > p_to then
    raise exception 'Начало периода позже его конца' using errcode = '22023';
  end if;
  if p_to - p_from >= 366 then
    raise exception 'Период выгрузки — не больше года' using errcode = '22023';
  end if;
end;
$$;

revoke all on function public.report_period_check(date, date) from public, anon, authenticated, service_role;


-- 2. Платежи за период ---------------------------------------------------------------

create or replace function public.export_payments(p_from date, p_to date)
  returns table (
    paid_on           date,
    paid_time         text,
    kind              text,
    amount_tiyin      integer,
    payer_name        text,
    payer_phone       text,
    student_name      text,
    subscription_type text,
    source_name       text,
    comment           text
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_tz     text;
  v_start  timestamptz;
  v_end    timestamptz;
  v_rows   integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  perform public.report_period_check(p_from, p_to);

  -- Пояс — один раз (Р12); границы — полуинтервал по paid_at, как в
  -- cash_by_source, чтобы месяц в файле совпадал с месяцем на экране.
  v_tz    := public.center_timezone(v_center);
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;

  -- payments.comment — операционная пометка («наличными», «Возврат при
  -- отмене абонемента»), не свободный текст о семье; notes плательщика и
  -- ребёнка сюда не попадают (0031, Р4).
  return query
    select (p.paid_at at time zone v_tz)::date,
           to_char(p.paid_at at time zone v_tz, 'HH24:MI'),
           p.kind,
           p.amount_tiyin,
           py.full_name,
           py.phone,
           st.full_name,
           sty.name,
           ps.name,
           p.comment
      from public.payments p
      left join public.payers py            on py.id = p.payer_id
      left join public.students st          on st.id = p.student_id
      left join public.subscriptions s      on s.id = p.subscription_id
      left join public.subscription_types sty on sty.id = s.type_id
      left join public.payment_sources ps   on ps.id = p.source_id
     where p.center_id = v_center
       and p.paid_at >= v_start
       and p.paid_at <  v_end
     order by p.paid_at, p.id;
  get diagnostics v_rows = row_count;

  perform public.emit_event('report.exported',
    jsonb_build_object('report', 'payments', 'from', p_from, 'to', p_to,
                       'rows', v_rows, 'by', auth.uid(), 'role', public.my_role()),
    v_center);
end;
$$;

comment on function public.export_payments(date, date) is
  'Платежи центра за период по paid_at в поясе центра (0058). can_finance. Имена — только full_name/phone, notes нет (0031). Событие report.exported со счётом строк и актором.';


-- 3. Зарплата за месяц: сводка и детализация ---------------------------------------

create or replace function public.export_salary_summary(p_month date)
  returns table (
    teacher_name      text,
    calc_tiyin        integer,
    adjustments_tiyin integer,
    total_tiyin       integer,
    approved          boolean,
    approved_on       date
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_tz     text;
  v_month  date;
  v_rows   integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_month is null then
    raise exception 'Укажите месяц' using errcode = '22023';
  end if;
  v_month := date_trunc('month', p_month)::date;
  v_tz    := public.center_timezone(v_center);

  -- Тот же salary_summary, что на /app/salary: утверждённый месяц отдаёт
  -- замороженный total_tiyin снимка, неутверждённый — расчёт (Р5).
  -- approved_on — день по поясу центра (Р10): утверждение в 02:00 по
  -- Бишкеку в UTC ещё вчера, а в споре с сотрудником смотрят на эту дату.
  return query
    select t.full_name,
           ss.calc_tiyin,
           ss.adjustments_tiyin,
           ss.total_tiyin,
           ss.approved_run_id is not null,
           (ss.approved_at at time zone v_tz)::date
      from public.salary_summary(v_month) ss
      join public.teachers t on t.id = ss.teacher_id
     order by t.full_name, t.id;
  get diagnostics v_rows = row_count;

  perform public.emit_event('report.exported',
    jsonb_build_object('report', 'salary_summary',
                       'from', v_month, 'to', (v_month + interval '1 month' - interval '1 day')::date,
                       'rows', v_rows, 'by', auth.uid(), 'role', public.my_role()),
    v_center);
end;
$$;

comment on function public.export_salary_summary(date) is
  'Сводка зарплаты за месяц по специалистам — те же числа, что salary_summary на экране (0058). can_finance.';

create or replace function public.export_salary_details(p_month date)
  returns table (
    teacher_name       text,
    lesson_date        date,
    model              text,
    lesson_price_tiyin integer,
    amount_tiyin       integer,
    note               text,
    approved           boolean
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_month  date;
  v_rows   integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_month is null then
    raise exception 'Укажите месяц' using errcode = '22023';
  end if;
  v_month := date_trunc('month', p_month)::date;

  -- Набор специалистов — из salary_summary (один запрос на обе выгрузки,
  -- Р5). Утверждённый месяц — снимок lines (то, что видел утверждавший),
  -- неутверждённый — calc_salary сейчас; иначе детализация могла бы
  -- разойтись со сводкой после правки отметки задним числом.
  -- Имени ребёнка здесь нет намеренно: finance не видит посещений (0031,
  -- В2), а «дата — ребёнок — сумма» за месяц и есть журнал посещений.
  -- Экран /app/salary (DetailsTable) его тоже не показывает.
  begin
    return query
      select t.full_name,
             d.lesson_date,
             d.model,
             d.lesson_price_tiyin,
             d.amount_tiyin,
             d.note,
             ss.approved_run_id is not null
        from public.salary_summary(v_month) ss
        join public.teachers t on t.id = ss.teacher_id
        cross join lateral (
          select ln.lesson_date, ln.student_id, ln.model, ln.lesson_price_tiyin, ln.amount_tiyin, ln.note
            from public.salary_runs sr,
                 jsonb_to_recordset(sr.lines) as ln(
                   lesson_date date, student_id uuid, model text,
                   lesson_price_tiyin integer, amount_tiyin integer, note text)
           where sr.id = ss.approved_run_id
          union all
          select c.lesson_date, c.student_id, c.model, c.lesson_price_tiyin, c.amount_tiyin, c.note
            from public.calc_salary(ss.teacher_id, v_month) c
           where ss.approved_run_id is null
        ) d
       order by t.full_name, d.lesson_date, d.student_id;
    -- Внутри блока, сразу за return query: за границей блока счёт строк
    -- держится только на том, что release субтранзакции его не трогает.
    get diagnostics v_rows = row_count;
  exception
    when sqlstate '22023' then
      -- calc_salary отбивает ставку с неизвестной моделью — в выгрузке «за
      -- всех» одна кривая ставка не должна ронять файл без объяснения.
      raise exception 'Не удалось собрать детализацию: %', sqlerrm using errcode = '22023';
  end;

  perform public.emit_event('report.exported',
    jsonb_build_object('report', 'salary_details',
                       'from', v_month, 'to', (v_month + interval '1 month' - interval '1 day')::date,
                       'rows', v_rows, 'by', auth.uid(), 'role', public.my_role()),
    v_center);
end;
$$;

comment on function public.export_salary_details(date) is
  'Детализация зарплаты за месяц по отметкам (0058). Утверждённый месяц — из снимка salary_runs.lines, иначе calc_salary; approved отличает одно от другого. can_finance.';


-- 4. Посещаемость за период — только owner/admin (В2) -------------------------------

create or replace function public.export_attendance(p_from date, p_to date)
  returns table (
    lesson_date       date,
    lesson_time       text,
    lesson_status     text,
    teacher_name      text,
    paid_teacher_name text,
    student_name      text,
    service_name      text,
    group_name        text,
    status_name       text,
    is_present        boolean,
    deducted          boolean,
    pays_teacher      boolean,
    price_tiyin       integer
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_tz     text;
  v_start  timestamptz;
  v_end    timestamptz;
  v_rows   integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  -- Не can_front_desk: регистратор по решению владельца не выгружает (В2);
  -- бухгалтеру attendance закрыта целиком (0031).
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  perform public.report_period_check(p_from, p_to);

  v_tz    := public.center_timezone(v_center);
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;

  -- attendance.comment не выгружается — свободный текст (класс 0031/0044).
  -- Два специалиста (Р6): кто вёл (effective_teacher_id — уже с учётом
  -- замены) и кому оплачено (paid_teacher_id, заморожен при отметке).
  return query
    select (l.starts_at at time zone v_tz)::date,
           to_char(l.starts_at at time zone v_tz, 'HH24:MI'),
           l.status,
           t1.full_name,
           t2.full_name,
           st.full_name,
           sv.name,
           g.name,
           ast.name,
           a.is_present,
           a.deducted,
           a.pays_teacher,
           a.price_tiyin
      from public.attendance a
      join public.lessons l                 on l.id = a.lesson_id
      left join public.teachers t1          on t1.id = l.effective_teacher_id
      left join public.teachers t2          on t2.id = a.paid_teacher_id
      left join public.students st          on st.id = a.student_id
      left join public.services sv          on sv.id = l.service_id
      left join public.groups g             on g.id = l.group_id
      left join public.attendance_statuses ast on ast.id = a.status_id
     where a.center_id = v_center
       and l.deleted_at is null
       and l.starts_at >= v_start
       and l.starts_at <  v_end
     order by l.starts_at, l.id, st.full_name, a.student_id;
  get diagnostics v_rows = row_count;

  perform public.emit_event('report.exported',
    jsonb_build_object('report', 'attendance', 'from', p_from, 'to', p_to,
                       'rows', v_rows, 'by', auth.uid(), 'role', public.my_role()),
    v_center);
end;
$$;

comment on function public.export_attendance(date, date) is
  'Отметки посещений за период по lessons.starts_at в поясе центра (0058). Только owner/admin. Без attendance.comment. Специалист занятия и кому оплачено — отдельно (сверка с зарплатой).';


-- 5. Долги на сегодня — два долга двумя колонками (В3) -------------------------------

create or replace function public.export_debts()
  returns table (
    student_name               text,
    student_status             text,
    payer_name                 text,
    payer_phone                text,
    lessons_debt_tiyin         integer,
    subscriptions_unpaid_tiyin integer
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_today  date;
  v_rows   integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_finance() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  v_today := public.center_today(v_center);

  -- lessons_debt — ровно то, что показывает /app/debts (student_balance
  -- берёт долг из той же student_debts, 0031). subscriptions_unpaid —
  -- недоплата по живым абонементам: с рассрочкой или без неё — если
  -- внесено меньше цены, это долг семьи перед центром.
  return query
    with lessons_debt as (
      select sd.student_id, sd.debt_tiyin
        from public.student_debts() sd
    ),
    unpaid as (
      select s.student_id, sum(s.price_tiyin - s.paid_tiyin)::integer as unpaid_tiyin
        from public.subscriptions s
       where s.center_id = v_center
         and s.deleted_at is null
         and s.status <> 'cancelled'
         and s.paid_tiyin < s.price_tiyin
       group by s.student_id
    )
    select st.full_name,
           st.status,
           py.full_name,
           py.phone,
           coalesce(ld.debt_tiyin, 0),
           coalesce(u.unpaid_tiyin, 0)
      from public.students st
      left join lessons_debt ld on ld.student_id = st.id
      left join unpaid u        on u.student_id = st.id
      left join public.payers py on py.id = st.payer_id
     where st.center_id = v_center
       and st.deleted_at is null
       and (coalesce(ld.debt_tiyin, 0) > 0 or coalesce(u.unpaid_tiyin, 0) > 0)
     order by st.full_name, st.id;
  get diagnostics v_rows = row_count;

  perform public.emit_event('report.exported',
    jsonb_build_object('report', 'debts', 'from', v_today, 'to', v_today,
                       'rows', v_rows, 'by', auth.uid(), 'role', public.my_role()),
    v_center);
end;
$$;

comment on function public.export_debts() is
  'Долги на сегодня (0058): по занятиям без абонемента (student_debts) и недоплата по абонементам (price − paid) — двумя колонками, без сложения (два определения слова «долг», docs/Database.md). can_finance.';


-- Гранты ---------------------------------------------------------------------------------

revoke all on function
  public.export_payments(date, date),
  public.export_salary_summary(date),
  public.export_salary_details(date),
  public.export_attendance(date, date),
  public.export_debts()
  from public, anon, service_role;

grant execute on function
  public.export_payments(date, date),
  public.export_salary_summary(date),
  public.export_salary_details(date),
  public.export_attendance(date, date),
  public.export_debts()
  to authenticated;
