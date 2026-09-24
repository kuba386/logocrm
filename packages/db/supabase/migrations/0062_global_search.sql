-- 0062: глобальный поиск — одно поле: имя или телефон → ребёнок, родитель,
-- ближайшее занятие (Backlog.md, владелец 11.09.2026).
--
-- Главный вопрос владельца — «поиск не должен показать роли то, чего ей не
-- видно в списках» — решается не вторым набором предикатов, а SECURITY
-- INVOKER: функция читает students/payers/lessons под RLS вызывающего, и
-- границы выдачи совпадают с политиками по построению.
--
-- Решения (ревью плана и написанного SQL, architect, 24.09.2026):
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
--       lesson_participants — только связка. lp.deleted_at is null —
--       страховка (копия lessons.deleted_at), а не проверяемый сценарий:
--       выход из группы триггер выражает удалением строки lp.
--       Идущее прямо сейчас занятие — тоже «ближайшее» (ends_at >= now()):
--       родитель звонит в середине урока.
--   Р4. Телефон: полный номер — через normalize_kg_phone (по уникальному
--       индексу payers_center_phone_uniq, отдельной веткой union);
--       частичный (≥ 4 цифр, без ведущих нулей и 996) — вхождение в 9
--       местных цифр: и начало «07001234», и хвост «3456»; phone_alt тоже.
--       Уникального индекса по phone_alt нет — поиск найдёт дубль, который
--       база не запрещает; отдельный пункт.
--   Р5. Архивные ученики — в выдаче с пометкой статуса, после активных:
--       список учеников по умолчанию показывает «Все статусы», поиск не
--       должен быть уже списка. Архивность входит в единственный ключ
--       сортировки rank, который уезжает наружу (+3): клиенту хватает
--       одного числа, порядок задаёт база. Удалённые (deleted_at) — нет.
--   Р6. Неделя для ссылки на расписание считается здесь, в поясе центра
--       (week_start) — браузер администратора из другого пояса открыл бы
--       соседнюю неделю. Подсветки занятия у расписания нет — ссылка ведёт
--       на неделю; карточка ученика — отдельной строкой.
--   Р7. Вход: null/пусто/1 символ → пусто без исключения; p_limit clamp
--       1..20 (null из PostgREST обходит default); шаблон like экранирован
--       с явным escape; «ё» → «е» с обеих сторон.
--   Р8. Клиентский фильтр в списке учеников (students-table.tsx) — сужение
--       уже загруженной страницы; глобальный поиск — SQL. Зеркала в TS нет
--       и не будет: суффикс телефона в браузере — это расчёт видимости
--       контактов в браузере (CLAUDE.md).
--   Р9. Событий нет: поиск — чтение экрана, не выгрузка (report.exported —
--       про файл). Если понадобится «кто пробивал номер» — отдельное
--       решение владельца.
--   Р10. Функция обязана остаться SECURITY INVOKER: одно слово definer
--       откроет всех детей всем ролям. Забор — pgTAP на prosecdef = false.
--   Р11. Имя плательщика в предикате: для ролей с payers (owner/admin/
--       registrar, parent — своя карточка) — множество из payers под RLS,
--       не definer-вызов на каждую строку students; payer_display_name()
--       построчно — только teacher (payers ему не читаемы, а видимых
--       учеников у него единицы, RLS режет строки до предиката). В выдаче
--       имя считается lateral ПОСЛЕ limit, не для всех совпавших.
--   Р12. Группы в выдаче нет: у /app/groups нет карточки по id и гейт
--       уже RLS; владелец просил «ребёнка, родителя, занятие».

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
  v_center   uuid := public.current_center();
  v_raw      text := coalesce(trim(p_query), '');
  v_q        text;
  v_like     text;
  v_prefix   text;
  v_digits   text;
  v_full     text;
  v_limit    integer := least(greatest(coalesce(p_limit, 8), 1), 20);
  v_tz       text;
  v_payments boolean;
begin
  if auth.uid() is null or v_center is null then
    return;
  end if;
  if length(v_raw) < 2 then
    return;
  end if;

  v_q      := replace(replace(replace(lower(v_raw), '\', '\\'), '%', '\%'), '_', '\_');
  v_q      := translate(v_q, 'ё', 'е');
  v_like   := '%' || v_q || '%';
  v_prefix := v_q || '%';

  -- Цифры запроса: ведущие нули (местная запись, «00996…») и код 996 —
  -- долой; остаток сравнивается с 9 местными цифрами номера.
  v_digits := regexp_replace(regexp_replace(regexp_replace(v_raw, '\D', '', 'g'), '^0+', ''), '^996', '');
  if length(v_digits) < 4 or length(v_digits) > 9 then
    v_digits := null;
  end if;
  v_full     := public.normalize_kg_phone(v_raw);
  v_tz       := public.center_timezone(v_center);
  v_payments := public.can_payments();

  return query
  with phone_hit as (
    -- Точный номер — своей веткой: идёт по payers_center_phone_uniq.
    select p.id
      from public.payers p
     where v_full is not null
       and p.center_id = v_center and p.deleted_at is null
       and public.normalize_kg_phone(p.phone) = v_full
    union
    select p.id
      from public.payers p
     where v_full is not null
       and p.center_id = v_center and p.deleted_at is null
       and public.normalize_kg_phone(p.phone_alt) = v_full
    union
    -- Вхождение, не суффикс: оператор либо дописывает номер с начала,
    -- либо помнит хвост — оба должны находить.
    select p.id
      from public.payers p
     where v_digits is not null
       and p.center_id = v_center and p.deleted_at is null
       and (strpos(right(public.normalize_kg_phone(p.phone), 9), v_digits) > 0
            or strpos(right(public.normalize_kg_phone(p.phone_alt), 9), v_digits) > 0)
  ),
  name_hit as (
    -- Плательщики, чьё имя совпало, — под RLS payers (Р11).
    select p.id
      from public.payers p
     where p.center_id = v_center and p.deleted_at is null
       and translate(lower(p.full_name), 'ё', 'е') like v_like escape '\'
  ),
  cand as (
    select s.id, s.full_name, s.status, s.birth_date, s.payer_id,
           (s.payer_id in (select ph.id from phone_hit ph)) as by_phone
      from public.students s
     where s.center_id = v_center
       and s.deleted_at is null
       and (
         translate(lower(s.full_name), 'ё', 'е') like v_like escape '\'
         or s.payer_id in (select nh.id from name_hit nh)
         or (not v_payments
             and translate(lower(coalesce(public.payer_display_name(s.payer_id), '')), 'ё', 'е') like v_like escape '\')
         or s.payer_id in (select ph.id from phone_hit ph)
       )
  ),
  students_out as (
    select c.id, c.full_name, c.status, c.birth_date, c.payer_id,
           (case when c.by_phone then 0
                 when translate(lower(c.full_name), 'ё', 'е') like v_prefix escape '\' then 1
                 else 2 end
            + case when c.status = 'archived' then 3 else 0 end) as rnk
      from cand c
     order by rnk, c.full_name, c.id
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
       and (p.id in (select nh.id from name_hit nh)
            or p.id in (select ph.id from phone_hit ph))
     order by rnk, p.full_name, p.id
     limit v_limit
  )
  select 'student'::text, so.id, so.full_name,
         pn.payer_name,
         case when so.birth_date is null then null
              else public.age_years(so.birth_date)::text end,
         so.status, null::timestamptz, null::date, so.rnk
    from students_out so
    cross join lateral (select public.payer_display_name(so.payer_id) as payer_name) pn
  union all
  select 'payer'::text, po.id, po.full_name, po.phone,
         (select string_agg(s.full_name, ', ' order by s.full_name)
            from public.students s
           where s.payer_id = po.id and s.deleted_at is null),
         null, null::timestamptz, null::date, po.rnk
    from payers_out po
  union all
  -- Ближайшее (или идущее сейчас) запланированное занятие каждого найденного
  -- ученика (Р2, Р3).
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
         and l.status = 'planned' and l.ends_at >= now()
        left join public.teachers t
          on t.id = l.effective_teacher_id and t.deleted_at is null
       order by so.id, l.starts_at
    ) nl;
end;
$$;

comment on function public.global_search(text, integer) is
  'Глобальный поиск (0062): ученик / плательщик / ближайшее занятие по имени или телефону. SECURITY INVOKER намеренно — границы выдачи = RLS вызывающего; definer открыл бы всех детей всем ролям (Р10). finance — пусто (Р1). rank — единственный ключ порядка, архивные +3 (Р5).';

revoke execute on function public.global_search(text, integer) from public, anon;
grant  execute on function public.global_search(text, integer) to authenticated;
