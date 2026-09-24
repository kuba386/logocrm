-- 0062: глобальный поиск — одно поле: имя или телефон → ребёнок, родитель,
-- ближайшее занятие, группа (Backlog.md, владелец 11.09.2026).
--
-- Главный вопрос владельца — «поиск не должен показать роли то, чего ей не
-- видно в списках» — решается не вторым набором предикатов, а SECURITY
-- INVOKER: функция читает students/payers/lessons/groups под RLS
-- вызывающего, и границы выдачи совпадают с политиками по построению.
-- Имя плательщика — через payer_display_name() (0026), как в
-- students_teacher_view: специалист находит «маму Гульнару» ровно там, где
-- видит её в списке, и не получает телефон (payers ему не читаемы).
--
-- Решения (ревью плана, architect, 24.09.2026 — 11 находок):
--   Р1. finance: у роли нет политик на students/payers/lessons (0031 сняла),
--       её список рисуют definer-RPC students_brief/payers_brief. Под
--       invoker поиск бухгалтеру пуст — и это записано, а не «починено»
--       definer-ом: поле поиска бухгалтеру не показывается (UI), функция
--       отдаёт ноль строк. Поиск нужен стойке на звонке, не бухгалтерии.
--   Р2. Порядок построения — сначала CTE найденных учеников (уже с limit),
--       потом занятия nested loop по lesson_participants_student_idx: иначе
--       RLS-квал parent_of_lesson()/teacher_teaches_student() считался бы на
--       каждой строке lessons центра на каждое нажатие клавиши.
--   Р3. Занятие якорится на lessons (там deleted_at, status, время);
--       lesson_participants — только связка, с обязательным
--       lp.deleted_at is null (политика lp его не проверяет, 0006:412).
--       Копия времени в lp не читается (ADR-006: lp — не источник истины).
--   Р4. Телефон: вхождение нормализованных цифр запроса (без ведущих 996/0,
--       ≥ 4 цифр) в 9 местных цифр номера — и начало «07001234», и хвост
--       «3456»; полный номер — через normalize_kg_phone в любом формате;
--       phone_alt тоже ищется.
--       Уникального индекса по phone_alt нет — поиск найдёт дубль, который
--       база не запрещает; отдельный пункт.
--   Р5. Архивные ученики — в выдаче с пометкой статуса, после активных:
--       список учеников по умолчанию показывает «Все статусы», поиск не
--       должен быть уже списка. Удалённые (deleted_at) — нет.
--   Р6. Неделя для ссылки на расписание считается здесь, в поясе центра
--       (week_start) — браузер администратора из другого пояса открыл бы
--       соседнюю неделю. Подсветки занятия у расписания нет — ссылка ведёт
--       на неделю; карточка ученика — отдельной строкой.
--   Р7. Вход: null/пусто/1 символ → пусто без исключения; p_limit clamp
--       1..20 (null из PostgREST обходит default); шаблон like экранирован
--       с явным escape; «ё» → «е» с обеих сторон ПОСЛЕ экранирования.
--   Р8. Клиентский фильтр в списке учеников (students-table.tsx) — сужение
--       уже загруженной страницы; глобальный поиск — SQL. Зеркала в TS нет
--       и не будет: суффикс телефона в браузере — это расчёт видимости
--       контактов в браузере (CLAUDE.md).
--   Р9. Событий нет: поиск — чтение экрана, не выгрузка (report.exported —
--       про файл).
--   Р10. Функция обязана остаться SECURITY INVOKER: одно слово definer
--       откроет всех детей всем ролям. Забор — pgTAP на prosecdef = false.

create or replace function public.global_search(p_query text default null, p_limit integer default 8)
  returns table (
    kind       text,
    id         uuid,
    title      text,
    subtitle   text,
    extra      text,
    status     text,
    starts_at  timestamptz,
    week_start date,
    rank       integer
  )
  language plpgsql
  stable
  security invoker
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_raw    text := coalesce(trim(p_query), '');
  v_q      text;
  v_like   text;
  v_prefix text;
  v_digits text;
  v_full   text;
  v_limit  integer := least(greatest(coalesce(p_limit, 8), 1), 20);
  v_tz     text;
begin
  if auth.uid() is null or v_center is null then
    return;
  end if;
  if length(v_raw) < 2 then
    return;
  end if;

  -- Экранирование до «ё»→«е»: порядок не коммутирует (Р7).
  v_q      := replace(replace(replace(lower(v_raw), '\', '\\'), '%', '\%'), '_', '\_');
  v_q      := translate(v_q, 'ё', 'е');
  v_like   := '%' || v_q || '%';
  v_prefix := v_q || '%';

  -- Цифры запроса без ведущих 996/0 — сравниваются с хвостом нормализованного
  -- номера (+996XXXXXXXXX → 9 местных цифр). Меньше 4 цифр — не телефон.
  v_digits := regexp_replace(regexp_replace(v_raw, '\D', '', 'g'), '^(996|0)', '');
  if length(v_digits) < 4 or length(v_digits) > 9 then
    v_digits := null;
  end if;
  v_full := public.normalize_kg_phone(v_raw);
  v_tz   := public.center_timezone(v_center);

  return query
  with phone_hit as (
    -- Плательщики, чей номер совпал: под RLS payers — у teacher/parent(чужие)
    -- строк нет, значит и «найден по телефону» нет.
    select p.id
      from public.payers p
     where p.center_id = v_center
       and p.deleted_at is null
       and (
         (v_full is not null and (public.normalize_kg_phone(p.phone) = v_full
                                  or public.normalize_kg_phone(p.phone_alt) = v_full))
         -- Вхождение, не суффикс: оператор либо дописывает номер с начала
         -- («07001234»), либо помнит хвост («3456») — оба должны находить.
         or (v_digits is not null and (
               strpos(right(public.normalize_kg_phone(p.phone), 9), v_digits) > 0
            or strpos(right(public.normalize_kg_phone(p.phone_alt), 9), v_digits) > 0))
       )
  ),
  cand as (
    select s.id, s.full_name, s.status, s.birth_date,
           public.payer_display_name(s.payer_id) as payer_name,
           (s.payer_id in (select ph.id from phone_hit ph)) as by_phone
      from public.students s
     where s.center_id = v_center
       and s.deleted_at is null
       and (
         translate(lower(s.full_name), 'ё', 'е') like v_like escape '\'
         or translate(lower(coalesce(public.payer_display_name(s.payer_id), '')), 'ё', 'е') like v_like escape '\'
         or s.payer_id in (select ph.id from phone_hit ph)
       )
  ),
  students_out as (
    select c.*,
           case when c.by_phone then 0
                when translate(lower(c.full_name), 'ё', 'е') like v_prefix escape '\' then 1
                else 2 end as rnk
      from cand c
     order by (c.status = 'archived'), rnk, c.full_name, c.id
     limit v_limit
  ),
  payers_out as (
    select p.id, p.full_name, p.phone,
           case when p.id in (select ph.id from phone_hit ph) then 0
                when translate(lower(p.full_name), 'ё', 'е') like v_prefix escape '\' then 1
                else 2 end as rnk
      from public.payers p
     where p.center_id = v_center
       and p.deleted_at is null
       and (translate(lower(p.full_name), 'ё', 'е') like v_like escape '\'
            or p.id in (select ph.id from phone_hit ph))
     order by rnk, p.full_name, p.id
     limit v_limit
  )
  select 'student'::text, so.id, so.full_name,
         so.payer_name,
         case when so.birth_date is null then null
              else public.age_years(so.birth_date)::text end,
         so.status, null::timestamptz, null::date, so.rnk
    from students_out so
  union all
  select 'payer'::text, po.id, po.full_name, po.phone,
         (select string_agg(s.full_name, ', ' order by s.full_name)
            from public.students s
           where s.payer_id = po.id and s.deleted_at is null and s.status <> 'archived'),
         null, null::timestamptz, null::date, po.rnk
    from payers_out po
  union all
  -- Ближайшее запланированное занятие каждого найденного ученика (Р2, Р3).
  select 'lesson'::text, nl.lesson_id, nl.full_name, nl.teacher_name, null, nl.status,
         nl.starts_at, nl.week_start, nl.rnk
    from (
      select distinct on (so.id)
             l.id as lesson_id, so.full_name, t.full_name as teacher_name, l.status,
             l.starts_at,
             date_trunc('week', (l.starts_at at time zone v_tz)::date)::date as week_start,
             so.rnk
        from students_out so
        join public.lesson_participants lp
          on lp.student_id = so.id and lp.deleted_at is null
        join public.lessons l
          on l.id = lp.lesson_id and l.deleted_at is null
         and l.status = 'planned' and l.starts_at >= now()
        left join public.teachers t
          on t.id = l.effective_teacher_id and t.deleted_at is null
       order by so.id, l.starts_at
    ) nl
  union all
  select 'group'::text, go.id, go.name, go.teacher_name, null, null, null::timestamptz, null::date, go.rnk
    from (
      select g.id, g.name, t.full_name as teacher_name,
             case when translate(lower(g.name), 'ё', 'е') like v_prefix escape '\' then 1 else 2 end as rnk
        from public.groups g
        left join public.teachers t on t.id = g.teacher_id and t.deleted_at is null
       where g.center_id = v_center
         and g.deleted_at is null
         and translate(lower(g.name), 'ё', 'е') like v_like escape '\'
       order by rnk, g.name, g.id
       limit v_limit
    ) go;
end;
$$;

comment on function public.global_search(text, integer) is
  'Глобальный поиск (0062): ученик / плательщик / ближайшее занятие / группа по имени или телефону. SECURITY INVOKER намеренно — границы выдачи = RLS вызывающего; definer открыл бы всех детей всем ролям (Р10). finance — пусто (Р1).';

revoke execute on function public.global_search(text, integer) from public, anon;
grant  execute on function public.global_search(text, integer) to authenticated;
