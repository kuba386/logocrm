-- =============================================================================
-- 0068_reading_writing_assessments.sql — чтение-письмо: пятый, последний
-- раздел речевой карты
--
-- Фаза 3.5. ИСТОРИЯ, как слоговая структура (0066) и просодика (0067), не
-- профиль — владелец подтвердил явно. Самый сложный из пяти разделов:
-- сочетает ОБЕ формы данных, которые в 0066/0067 были разделены —
-- скалярные категориальные поля (как 0067) И два независимых text[] (как
-- 0066), потому что чтение и письмо оцениваются вместе на одном
-- обследовании, но имеют разную структуру находок.
--
-- Ревью плана архитектором, решения:
--
--   Р1. Смоделировано на 0067 (RPC-триплет, сентинелы, student_alive,
--       архивный специалист) + 0066 (форма двух text[]-полей). НЕ слепое
--       копирование — см. Р2-Р9.
--   Р2. num_nonnulls() принимает VARIADIC "any" и МОЛЧА принимает массивы,
--       считая '{}' за non-null — сунуть reading_errors/writing_errors
--       внутрь num_nonnulls дало бы констрейнт, который ВСЕГДА истинен
--       (не падает — врёт, хуже отсутствия). Инвариант «хотя бы одно
--       содержательное поле» — раздельная формула:
--       num_nonnulls(<пять скаляров>) >= 1
--       or coalesce(cardinality(reading_errors), 0) > 0
--       or coalesce(cardinality(writing_errors), 0) > 0.
--       coalesce обязателен даже при not null default '{}' сегодня —
--       иначе снятие not null следующей миграцией тихо превращает
--       `false or NULL or false` (= NULL, CHECK пропускает) в дыру,
--       которую CI не заметит, пока кто-то явно не протестирует пустую
--       строку.
--   Р3. writing_quality (normal/impaired) — НОВОЕ поле, не было в
--       исходном плане. Без него '{}' в writing_errors означает
--       ОДНОВРЕМЕННО «не оценивалось» и «оценено, ошибок нет» — ровно
--       цена ошибки student_balance.lessons_left, только у письма не
--       было вообще никакой скалярной оси, чтобы её различить (у чтения
--       есть reading_pace/reading_comprehension с честным NULL). Теперь
--       '{}' + null(writing_quality) = не оценивалось, '{}' +
--       'normal' = оценено, ошибок нет.
--   Р4. reading_method (letter_by_letter/syllable_by_syllable/
--       whole_word_syllable/whole_word) — ОПИСАТЕЛЬНАЯ шкала прогрессии
--       навыка чтения, не ось «норма/нарушение»: способ чтения ожидаемо
--       разный по возрасту/классу, поэтому кода 'normal' здесь НЕТ, в
--       отличие от reading_pace/reading_comprehension/writing_quality.
--       Явно ВЫВЕДЕНО из контракта 0067 Р2 («единый normal во всех
--       категориальных полях») — будущая функция «раздел в норме?»
--       обязана перечислять оси нормы явным списком колонок
--       (reading_pace, reading_comprehension, writing_quality), не
--       перебором всех текстовых полей строки, иначе ребёнок, достигший
--       чтения целыми словами, пометится как «нарушение».
--   Р5. reading_errors может содержать 'stumbling' (побуквенное
--       спотыкание) ОДНОВРЕМЕННО с reading_method = 'whole_word' —
--       сознательно НЕ связано констрейнтом: это два разных наблюдения
--       (способ чтения в целом и конкретные затруднения на отдельных
--       словах), не противоречие. Табличный CHECK между ними не пишем —
--       набор «несовместимых» комбинаций пришлось бы расширять каждой
--       новой миграцией.
--   Р6. reading_errors и writing_errors — РАЗНЫЕ множества кодов, хотя
--       некоторые текстовые коды совпадают ('omission', 'permutation') и
--       пересекаются с syllable_assessments.error_types ('substitution').
--       Каждый CHECK проверяет только свою колонку — на уровне схемы это
--       безопасно; риск — в UI (общая TS-константа кодов между чтением и
--       письмом, общий Record<code,label>, общий префикс имени поля
--       формы) — отдельная задача при добавлении UI, не эта миграция.
--       Верхние границы cardinality (6 и 8) равны числу кодов в своих же
--       списках — после дедупа в RPC они сегодня недостижимы; при
--       добавлении нового кода в список поднимать кап синхронно (pgTAP
--       держит границу самосогласованной — см. тест).
--   Р7. Сентинел — ОДНО правило для всех семи текстовых/массивных полей
--       записи (на уровне «поле целиком»), не два протокола: null — не
--       трогать; пустое значение ('' и голый пробел для текста, '{}' для
--       массива) — снять; любое другое — заменить целиком. record_
--       нормализует '' → null (nullif(trim(...),'')) и
--       дедуплицирует+сортирует массивы ДО guard'а; update_ — то же
--       самое, но условно: null-параметр оставляет текущее значение
--       колонки, иначе применяет то же правило (0067 Р3). ЭЛЕМЕНТЫ
--       массивов НЕ триммятся (только текстовые скаляры целиком) — как в
--       0066, паритет, не регресс: array[' omission'] даёт 23514, а не
--       тихую нормализацию. apps/web/lib/errors.ts + clinical-actions.ts
--       НЕ используют optional() ни на одном из этих полей в update_ —
--       optional() превращает '' в undefined («не трогать» вместо
--       «снять»), находка второго прохода 0067.
--   Р11. writing_quality = 'normal' одновременно с непустым writing_errors
--        — ИМЕНОВАННЫЙ CHECK запрещает: 'normal' объявлен Р3 как «оценено,
--        ошибок нет», и схема не должна разрешать одновременно «в норме»
--        и список нарушений — второй проход ревью показал, что полный-
--        снимок форма может забыть переключить один из двух после правки
--        другого. writing_quality is null при непустом writing_errors —
--        разрешено осознанно (не оценивалось целостно, но конкретные
--        ошибки уже зафиксированы) — не противоречие, констрейнтом не
--        закрыто.
--   Р12. Индекс на teacher_id — Supabase Advisors иначе бьёт
--        unindexed_foreign_keys на составном FK. Тот же пробел уже есть у
--        0066/0067 — не чинится этой миграцией (долг, отдельная задача).
--   Р13. Порядок проверок в record_/update_ — существование ученика ДО
--        роли (как в 0065/0066/0067, унаследовано дословно): посторонний
--        различает 42704 («такого нет») от 42501 («есть, но нельзя»),
--        подобрав uuid. Не факт содержимого, только факт существования —
--        цена признана, решать для всех пяти разделов сразу, не здесь
--        поодиночке.
--   Р8. Проверка архивного специалиста (`teachers.deleted_at is null`) —
--       ОДНА, после ветвления teacher/owner-admin (0067 Р6, найдено
--       вторым проходом: первая редакция проверяла только путь
--       owner/admin).
--   Р9. student_alive(v_row.student_id) — общее предусловие в update_ для
--       ВСЕХ ролей, включая owner/admin (0067 Р10) — restrictive-политика
--       уже держит эту границу на чтение для всех без исключения, запись
--       не должна быть шире. archive_ этой проверки не получает
--       сознательно — архивировать старую запись удалённого ребёнка не
--       запрещено.
--   Р10. Составной FK на teachers — `on delete set null (teacher_id)` со
--        списком колонок (0022, 0067 Р5), не голый `on delete set null`
--        (иначе зануляет center_id not null — долг 0036/0066).
--
-- record_ дублирует формулу CHECK ровно, над теми же нормализованными
-- значениями (не сырыми параметрами) — иначе RPC-guard и table-level CHECK
-- расходятся на пробеле/массиве с NULL-элементом (0066 Р18: RPC не должна
-- подменять код ошибки констрейнта своим).
--
-- Закрытый список кодов в CHECK вместо lookup-таблицы — тот же паттерн,
-- что 0065/0066/0067 для клинических находок (в отличие от статусов,
-- CLAUDE.md); цена — новый код требует миграции, у пяти полей это будет
-- случаться чаще, чем у одного. Осознанно, не пересматривать здесь.
--
-- current_date + 1 в CHECK даты — тот же унаследованный UTC-vs-center_today
-- зазор у полуночи, что 0065 Р7/0067; не чинится этой миграцией.
-- =============================================================================

create table if not exists public.reading_writing_assessments (
  id                     uuid primary key default gen_random_uuid(),
  center_id              uuid not null default public.current_center()
                           references public.centers (id) on delete cascade,
  student_id             uuid not null,
  teacher_id             uuid,
  date                   date not null default public.center_today(public.current_center())
    constraint reading_writing_assessments_date_check
    check (date between date '2000-01-01' and current_date + 1),

  -- Р4: описательная шкала прогрессии, НЕ ось «норма/нарушение» — кода
  -- 'normal' здесь нет сознательно, в отличие от полей ниже.
  reading_method         text
    constraint reading_writing_assessments_reading_method_check
    check (reading_method is null or reading_method in
      ('letter_by_letter', 'syllable_by_syllable', 'whole_word_syllable', 'whole_word')),
  reading_pace           text
    constraint reading_writing_assessments_reading_pace_check
    check (reading_pace is null or reading_pace in ('normal', 'slowed', 'accelerated')),
  reading_comprehension  text
    constraint reading_writing_assessments_reading_comprehension_check
    check (reading_comprehension is null or reading_comprehension in ('normal', 'impaired')),
  -- Р6: множество кодов СВОЁ, не общее с writing_errors, хотя некоторые
  -- текстовые коды совпадают ('omission', 'permutation').
  reading_errors         text[] not null default '{}'
    constraint reading_writing_assessments_reading_errors_check
    check (
      reading_errors <@ array['substitution', 'omission', 'permutation', 'guessing', 'repetition', 'stumbling']
      and cardinality(reading_errors) <= 6
    ),

  -- Р3: writing_quality — ось «норма/нарушение» у письма, симметричная
  -- reading_comprehension. Без неё '{}' в writing_errors был бы
  -- неотличим от «не оценивалось».
  writing_quality        text
    constraint reading_writing_assessments_writing_quality_check
    check (writing_quality is null or writing_quality in ('normal', 'impaired')),
  writing_errors         text[] not null default '{}'
    constraint reading_writing_assessments_writing_errors_check
    check (
      writing_errors <@ array['acoustic_substitution', 'optical_substitution', 'omission', 'permutation',
                               'word_boundary', 'mirror_writing', 'agrammatism', 'incomplete_elements']
      and cardinality(writing_errors) <= 8
    ),

  conclusion             text
    constraint reading_writing_assessments_conclusion_check
    check (conclusion is null or length(conclusion) <= 2000),

  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid default auth.uid(),
  deleted_at             timestamptz,

  -- Р2: раздельная формула для скаляров и массивов — num_nonnulls не
  -- разворачивает массивы (VARIADIC "any" принимает их как один
  -- non-null аргумент, '{}' включительно). coalesce(cardinality(...),0)
  -- держит инвариант, даже если not null снимут следующей миграцией.
  constraint reading_writing_assessments_not_empty
    check (
      num_nonnulls(reading_method, reading_pace, reading_comprehension, writing_quality, conclusion) >= 1
      or coalesce(cardinality(reading_errors), 0) > 0
      or coalesce(cardinality(writing_errors), 0) > 0
    ),
  -- Р11: 'normal' — «оценено, ошибок нет» (Р3); строка не может
  -- одновременно утверждать «в норме» и перечислять нарушения.
  -- writing_quality is null при непустом writing_errors разрешён
  -- осознанно — не эта пара конфликтна.
  constraint reading_writing_assessments_writing_consistency
    check (writing_quality is distinct from 'normal' or cardinality(writing_errors) = 0),

  constraint reading_writing_assessments_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade,
  -- Р10: список колонок у SET NULL — без него Postgres зануляет весь
  -- составной FK, включая center_id not null.
  constraint reading_writing_assessments_teacher_fk
    foreign key (teacher_id, center_id) references public.teachers (id, center_id) on delete set null (teacher_id)
);

comment on table public.reading_writing_assessments is
  'Чтение-письмо — пятый, последний раздел речевой карты (0068, Фаза 3.5). ИСТОРИЯ (решение владельца), не профиль. Сочетает скалярные категориальные поля (как student_articulation/prosody_assessments) и два независимых text[] (как syllable_assessments): reading_method — описательная шкала без оси нормы (Р4); reading_pace/reading_comprehension/writing_quality — норма/нарушение с единым кодом normal; reading_errors/writing_errors — разные множества кодов (Р6). Родителю не видна (ADR-005). Запись — только record_/update_/archive_reading_writing_assessment.';

comment on column public.reading_writing_assessments.reading_method is
  'Описательная шкала прогрессии навыка чтения — НЕ ось «норма/нарушение» (Р4). В вычисление «раздел в норме?» не входит; оси нормы — reading_pace, reading_comprehension, writing_quality явным списком.';

-- Два обследования в один день — валидный сценарий (0066 Р17), сортировка
-- детерминированная (0067 Р7).
create index if not exists reading_writing_assessments_student_idx
  on public.reading_writing_assessments (student_id, date desc, created_at desc) where deleted_at is null;
create index if not exists reading_writing_assessments_center_idx
  on public.reading_writing_assessments (center_id) where deleted_at is null;
-- Р12: составной FK на teachers без покрывающего индекса — Advisors бьёт
-- unindexed_foreign_keys (тот же пробел уже есть у 0066/0067, здесь не
-- унаследован дальше).
create index if not exists reading_writing_assessments_teacher_idx
  on public.reading_writing_assessments (teacher_id) where deleted_at is null;

drop trigger if exists reading_writing_assessments_set_updated_at on public.reading_writing_assessments;
create trigger reading_writing_assessments_set_updated_at
  before update on public.reading_writing_assessments
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('reading_writing_assessments');
call public.apply_audit('reading_writing_assessments');
call public.apply_readonly_guard('reading_writing_assessments');

-- clinical_student_visible/student_primary_teacher/student_alive (0063/0065)
-- — только вызовы, тела чужие, не переиздаются.
drop policy if exists reading_writing_assessments_teacher_read on public.reading_writing_assessments;
create policy reading_writing_assessments_teacher_read on public.reading_writing_assessments
  for select to authenticated
  using (
    center_id = public.current_center()
    and deleted_at is null
    and (
      public.clinical_student_visible(student_id)
      or public.student_primary_teacher(student_id)
      or created_by = auth.uid()
    )
  );

-- Точный образец 0066/0067: student_alive держит ВСЕХ, включая
-- owner/admin, без исключений.
drop policy if exists reading_writing_assessments_visible on public.reading_writing_assessments;
create policy reading_writing_assessments_visible on public.reading_writing_assessments
  as restrictive for select to authenticated
  using (
    public.student_alive(student_id)
    and (
      public.clinical_student_visible(student_id)
      or public.student_primary_teacher(student_id)
      or created_by = auth.uid()
    )
  );

revoke all on table public.reading_writing_assessments from public, anon, authenticated;
grant select on public.reading_writing_assessments to authenticated;


-- record_reading_writing_assessment --------------------------------------------------------------

create or replace function public.record_reading_writing_assessment(
  p_student_id            uuid,
  p_date                  date default null,
  p_teacher_id            uuid default null,
  p_reading_method        text default null,
  p_reading_pace          text default null,
  p_reading_comprehension text default null,
  p_reading_errors        text[] default null,
  p_writing_quality       text default null,
  p_writing_errors        text[] default null,
  p_conclusion            text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center                uuid := public.current_center();
  v_role                  text := coalesce(public.my_role(), '');
  v_teacher_id            uuid;
  v_id                    uuid;
  v_reading_method        text := nullif(trim(coalesce(p_reading_method, '')), '');
  v_reading_pace          text := nullif(trim(coalesce(p_reading_pace, '')), '');
  v_reading_comprehension text := nullif(trim(coalesce(p_reading_comprehension, '')), '');
  v_writing_quality       text := nullif(trim(coalesce(p_writing_quality, '')), '');
  v_conclusion            text := nullif(trim(coalesce(p_conclusion, '')), '');
  v_reading_errors        text[];
  v_writing_errors        text[];
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.students s
     where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null
  ) then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  -- Дедуп + алфавитный порядок (0066): <@ проверяет только принадлежность,
  -- не уникальность, cardinality-кап без дедупа не спасает от повторов.
  select coalesce(array_agg(s.x order by s.x), '{}'::text[]) into v_reading_errors
    from (select distinct x from unnest(coalesce(p_reading_errors, '{}'::text[])) x) s;
  select coalesce(array_agg(s.x order by s.x), '{}'::text[]) into v_writing_errors
    from (select distinct x from unnest(coalesce(p_writing_errors, '{}'::text[])) x) s;

  -- Р2: формула ровно как в reading_writing_assessments_not_empty, над
  -- теми же нормализованными значениями — иначе RPC-guard и table-level
  -- CHECK разойдутся на пробеле или дубле.
  if num_nonnulls(v_reading_method, v_reading_pace, v_reading_comprehension, v_writing_quality, v_conclusion) = 0
     and coalesce(cardinality(v_reading_errors), 0) = 0
     and coalesce(cardinality(v_writing_errors), 0) = 0
  then
    raise exception 'Заполните хотя бы одно поле обследования' using errcode = '22023';
  end if;

  -- Симметрично чтению — clinical_teacher_sees или primary_teacher_id (0066/0067 Р3).
  if not (
    v_role in ('owner', 'admin')
    or (v_role = 'teacher' and (
      public.clinical_teacher_sees(p_student_id) or public.student_primary_teacher(p_student_id)
    ))
  ) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_role = 'teacher' then
    v_teacher_id := public.my_teacher_id();
  elsif p_teacher_id is not null then
    v_teacher_id := p_teacher_id;
  end if;

  -- Р8: проверка архивного специалиста — ОДНА, после ветвления, на оба пути.
  if v_teacher_id is not null and not exists (
    select 1 from public.teachers t
     where t.id = v_teacher_id and t.center_id = v_center and t.deleted_at is null
  ) then
    raise exception 'Специалист не найден' using errcode = '42704';
  end if;

  insert into public.reading_writing_assessments (
    center_id, student_id, teacher_id, date,
    reading_method, reading_pace, reading_comprehension, reading_errors,
    writing_quality, writing_errors, conclusion
  ) values (
    v_center, p_student_id, v_teacher_id, coalesce(p_date, public.center_today(v_center)),
    v_reading_method, v_reading_pace, v_reading_comprehension, v_reading_errors,
    v_writing_quality, v_writing_errors, v_conclusion
  )
  returning id into v_id;

  perform public.emit_event('reading_writing_assessment.created',
    jsonb_build_object('center_id', v_center, 'assessment_id', v_id, 'student_id', p_student_id), v_center);

  return v_id;
end;
$$;

comment on function public.record_reading_writing_assessment(uuid, date, uuid, text, text, text, text[], text, text[], text) is
  'Новая запись обследования чтения-письма (0068). Круг записи симметричен чтению (0066/0067 Р3). Специалист — не архивный, проверка одна после ветвления (Р8). Сентинел '''' → NULL на скалярах, дедуп+сортировка на массивах — до guard''а «хотя бы одно поле», который дублирует reading_writing_assessments_not_empty ровно (Р2).';

revoke all on function public.record_reading_writing_assessment(uuid, date, uuid, text, text, text, text[], text, text[], text) from public, anon, authenticated, service_role;
grant execute on function public.record_reading_writing_assessment(uuid, date, uuid, text, text, text, text[], text, text[], text) to authenticated;


-- update_reading_writing_assessment ---------------------------------------------------------------

create or replace function public.update_reading_writing_assessment(
  p_id                    uuid,
  p_date                  date default null,
  p_reading_method        text default null,
  p_reading_pace          text default null,
  p_reading_comprehension text default null,
  p_reading_errors        text[] default null,
  p_writing_quality       text default null,
  p_writing_errors        text[] default null,
  p_conclusion            text default null,
  p_expected_updated_at   timestamptz default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center         uuid := public.current_center();
  v_role           text := coalesce(public.my_role(), '');
  v_row            public.reading_writing_assessments;
  v_reading_errors text[];
  v_writing_errors text[];
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.reading_writing_assessments
   where id = p_id and center_id = v_center and deleted_at is null
   for update;
  if not found then
    raise exception 'Запись не найдена' using errcode = '42704';
  end if;

  -- Р9: student_alive — общее предусловие для ВСЕХ ролей, включая
  -- owner/admin, не только ветки teacher (restrictive держит эту границу
  -- на чтение для всех без исключения — запись не должна быть шире).
  if not public.student_alive(v_row.student_id) then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  -- teacher_id не меняется через update_ — как diagnostics/0066/0067.
  if not (
    v_role in ('owner', 'admin')
    or (
      v_role = 'teacher'
      and (
        public.clinical_teacher_sees(v_row.student_id)
        or public.student_primary_teacher(v_row.student_id)
        or coalesce(v_row.created_by = auth.uid(), false)
      )
    )
  ) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_expected_updated_at is distinct from v_row.updated_at then
    raise exception 'Запись изменена параллельно — обновите страницу и повторите' using errcode = '22023';
  end if;

  -- Р7: одно правило на все семь полей — null не трогает, пустое ('' /
  -- пробел / '{}') снимает, любое другое заменяет целиком. Массивы
  -- нормализуются (дедуп+сортировка) только когда параметр передан.
  if p_reading_errors is not null then
    select coalesce(array_agg(s.x order by s.x), '{}'::text[]) into v_reading_errors
      from (select distinct x from unnest(p_reading_errors) x) s;
  else
    v_reading_errors := v_row.reading_errors;
  end if;

  if p_writing_errors is not null then
    select coalesce(array_agg(s.x order by s.x), '{}'::text[]) into v_writing_errors
      from (select distinct x from unnest(p_writing_errors) x) s;
  else
    v_writing_errors := v_row.writing_errors;
  end if;

  update public.reading_writing_assessments set
    date                  = coalesce(p_date, date),
    reading_method        = case when p_reading_method is null then reading_method
                                  else nullif(trim(p_reading_method), '') end,
    reading_pace          = case when p_reading_pace is null then reading_pace
                                  else nullif(trim(p_reading_pace), '') end,
    reading_comprehension = case when p_reading_comprehension is null then reading_comprehension
                                  else nullif(trim(p_reading_comprehension), '') end,
    reading_errors        = v_reading_errors,
    writing_quality       = case when p_writing_quality is null then writing_quality
                                  else nullif(trim(p_writing_quality), '') end,
    writing_errors        = v_writing_errors,
    conclusion            = case when p_conclusion is null then conclusion
                                  else nullif(trim(p_conclusion), '') end
   where id = p_id;

  perform public.emit_event('reading_writing_assessment.updated',
    jsonb_build_object('center_id', v_center, 'assessment_id', p_id, 'student_id', v_row.student_id), v_center);
end;
$$;

comment on function public.update_reading_writing_assessment(uuid, date, text, text, text, text[], text, text[], text, timestamptz) is
  'Правка записи обследования чтения-письма (0068). Одно правило на все семь полей (Р7): null — не трогать; пустое значение ('''' / пробел / пустой массив) — снять; любое другое — заменить целиком (массивы — с дедупом и сортировкой). teacher_id не меняется. student_alive — общее предусловие для всех ролей (Р9). p_expected_updated_at обязателен при расхождении — 22023 без автоповтора.';

revoke all on function public.update_reading_writing_assessment(uuid, date, text, text, text, text[], text, text[], text, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.update_reading_writing_assessment(uuid, date, text, text, text, text[], text, text[], text, timestamptz) to authenticated;


-- archive_reading_writing_assessment ---------------------------------------------------------------

create or replace function public.archive_reading_writing_assessment(p_id uuid)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_role    text := coalesce(public.my_role(), '');
  v_found   boolean;
  v_student uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  -- Как archive_diagnostic/archive_syllable_assessment/archive_prosody_assessment: только owner/admin.
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.reading_writing_assessments set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null
   returning student_id into v_student;
  v_found := found;

  if v_found then
    perform public.emit_event('reading_writing_assessment.archived',
      jsonb_build_object('center_id', v_center, 'assessment_id', p_id, 'student_id', v_student), v_center);
  end if;

  return v_found;
end;
$$;

comment on function public.archive_reading_writing_assessment(uuid) is
  'Архивация обследования чтения-письма — только owner/admin, как archive_prosody_assessment (0067).';

revoke all on function public.archive_reading_writing_assessment(uuid) from public, anon, authenticated, service_role;
grant execute on function public.archive_reading_writing_assessment(uuid) to authenticated;


-- export_center_tables() — переиздана от 0067, добавлена reading_writing_assessments --

create or replace function public.export_center_tables()
  returns table (table_name text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('attendance'), ('attendance_statuses'), ('booking_requests'), ('diagnostic_clinical_forms'),
    ('diagnostic_referrals'), ('diagnostics'), ('exercise_library'),
    ('expense_categories'), ('expenses'), ('financial_periods'), ('funnel_events'),
    ('goal_progress'), ('goal_stages'), ('goals'), ('group_students'), ('groups'),
    ('homework'), ('homework_exercises'), ('installment_plans'), ('installments'),
    ('lesson_note_goal_scores'), ('lesson_notes'), ('lesson_participants'), ('lessons'),
    ('memberships'), ('message_templates'), ('monthly_reports'), ('payers'),
    ('payment_sources'), ('payments'), ('platform_payments'), ('prosody_assessments'),
    ('reading_writing_assessments'), ('rooms'),
    ('salary_adjustments'), ('salary_runs'), ('services'), ('student_anamnesis'),
    ('student_articulation'), ('student_payers'), ('students'), ('subscription_freezes'),
    ('subscription_types'), ('subscriptions'), ('syllable_assessments'), ('teacher_rates'), ('teachers')
$$;

comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
