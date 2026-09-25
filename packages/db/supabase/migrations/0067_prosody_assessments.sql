-- =============================================================================
-- 0067_prosody_assessments.sql — просодика: четвёртый раздел речевой карты
--
-- Фаза 3.4. ИСТОРИЯ, как слоговая структура (0066) и diagnostics (0059), не
-- профиль: новая строка на каждое обследование, архивация вместо правки на
-- месте — владелец подтвердил явно. Форма колонок — как student_articulation
-- (0065): несколько отдельных категориальных text-полей с CHECK на закрытый
-- список кодов, а не массивы (в отличие от 0066: тут поля не комбинируются
-- друг с другом внутри одного обследования — темп либо один, либо не оценён).
--
-- Ревью плана архитектором, решения:
--
--   Р1. Смоделировано на 0066 (record_/update_/archive_), форма колонок — на
--       0065. НЕ слепое копирование ни одного из двух — см. Р2-Р9 ниже.
--   Р2. Код нормы — ОДИН И ТОТ ЖЕ 'normal' во всех шести полях (не
--       'expressive' у интонации, не 'correct' у ударения): вопрос «раздел в
--       норме?» из TS не должен собирать карту из шести разных литералов —
--       второй источник истины расходится сам собой. NULL — «не оценивалось»,
--       'normal' — «оценили, нарушений нет»: NULL как норма отвергнут —
--       строка, где дыхание не оценили, не должна ЛОЖНО утверждать «дыхание
--       в норме» (та же цена ошибки, что student_balance.lessons_left,
--       только здесь неоднозначность была бы у всех шести полей сразу).
--       'monotone' встречается и в intonation, и в voice — подписи в UI
--       обязаны быть per-field картой (как articulation-panel.tsx), не
--       плоским Record<code,label>, иначе «монотонный» отрендерится одним
--       текстом с разным смыслом в двух графах.
--   Р3. Сентинел '' → null — на ОБЕИХ функциях, для ВСЕХ семи текстовых полей
--       (шесть категориальных + conclusion), не только там, где HTML-форма
--       это первой обнаружит: голый select «не выбрано» шлёт '' и при
--       создании тоже, не только при правке (находка 0066 Р16, здесь —
--       заранее, не постфактум).
--   Р4. Инвариант «хотя бы одно содержательное поле» — ИМЕНОВАННЫЙ CHECK на
--       таблице (num_nonnulls), не проверка в record_: в 0066 массивы
--       (not null default '{}') сделали табличный CHECK неудобным, и guard
--       остался только в RPC — но полный-снимок форма правки (тот же приём,
--       что updateSyllableAssessment) даёт прямой путь стереть все поля через
--       update_ и оставить в истории запись, неотличимую от «обследован,
--       нарушений нет», в обход record_ целиком. Здесь все поля скалярные —
--       констрейнт пишется в одну строку и держит эту дыру закрытой на
--       уровне схемы, а не только в одном из трёх входов.
--   Р5. Составной FK на teachers — `on delete set null (teacher_id)`, СО
--       СПИСКОМ колонок (0022), не как 0036/0066 (голый `on delete set null`
--       зануляет ОБЕ колонки составного FK, включая center_id not null, и
--       любое физическое удаление teachers — сегодня только каскад от
--       centers, но 0056 умеет удалять центр по заявке — падает загадочным
--       not-null violation вместо тихого каскада). Долг 0036/0066 — отдельная
--       миграция, не эта.
--   Р6. Специалист — не архивный (`teachers.deleted_at is null`): проверка
--       ОДНА, после ветвления teacher/owner-admin, а не внутри одной ветки
--       (0066 этого не делает вовсе). Найдено ревью написанного SQL: первая
--       редакция проверяла только путь owner/admin (`p_teacher_id`) — путь
--       teacher (`my_teacher_id()`) архивного специалиста пропускал молча,
--       если владелец архивировал специалиста (`archive_teacher`, 0017), но
--       забыл отдельно отозвать доступ (`revoke_membership`, 0050 — это два
--       разных действия).
--   Р7. Индекс — `(student_id, date desc, created_at desc)`: два обследования
--       в один день (0066 Р17 разрешил это сознательно) не должны
--       сортироваться недетерминированно. Индекс САМ ПО СЕБЕ порядок не
--       гарантирует (Postgres не обязан читать по нему) — гарантия придёт из
--       запроса/RPC, который будет читать историю в UI; на момент этой
--       миграции такого запроса ещё нет (UI — отдельная задача). Открытый
--       долг: тот же пробел уже есть в смерженном UI 0066
--       (syllable-assessment-panel.tsx, `.order('date', {ascending:false})`
--       без тай-брейка) — чинить отдельной задачей, не здесь.
--   Р8. update_ не даёт сменить teacher_id — как у diagnostics/0066: ошибка в
--       поле «специалист» правится архивацией и новой записью, не тихой
--       подменой автора старой. Решение явное, не недосмотр.
--   Р9. created_by = auth.uid() в permissive-круге чтения — тот же приём,
--       что 0066 (автор видит свою запись даже потеряв clinical_teacher_sees/
--       primary_teacher_id). Для истории это шире, чем для профиля: автор
--       сохраняет доступ к каждой своей старой строке и после того, как
--       связь с ребёнком оборвалась. Решение принято сознательно, тем же
--       образом, что и в 0066, — не переоткрывать без причины.
--   Р10. student_alive(v_row.student_id) — общее предусловие в update_ для
--        ВСЕХ ролей, включая owner/admin, не только ветки teacher. Найдено
--        ревью написанного SQL: restrictive-политика (Р13/0066) уже держит
--        student_alive на чтение для всех без исключения — update_ без этой
--        же проверки для owner/admin был бы ýже на чтение, чем на запись:
--        первая будущая RPC, реально ставящая students.deleted_at, скрыла бы
--        запись с экрана, но не от правки через прямой id в адресной строке.
--        archive_ этой проверки НЕ получает сознательно — архивировать
--        старую запись удалённого ребёнка (уборка истории) не запрещаем.
--
-- current_date + 1 в CHECK даты — серверный UTC против center_today(center),
-- известное узкое окно у полуночи (0065 Р7) — не новая дыра, а унаследованная,
-- чинить отдельно, не здесь.
-- =============================================================================

create table if not exists public.prosody_assessments (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  student_id    uuid not null,
  teacher_id    uuid,
  date          date not null default public.center_today(public.current_center())
    constraint prosody_assessments_date_check
    check (date between date '2000-01-01' and current_date + 1),

  -- Р2: 'normal' — единый код нормы во всех шести полях. NULL — «не
  -- оценивалось» (не «в норме») — иначе строка ложно утверждает от имени
  -- схемы то, что специалист не проверял.
  tempo          text
    constraint prosody_assessments_tempo_check
    check (tempo is null or tempo in ('normal', 'accelerated', 'slowed')),
  rhythm         text
    constraint prosody_assessments_rhythm_check
    check (rhythm is null or rhythm in ('normal', 'disrupted')),
  intonation     text
    constraint prosody_assessments_intonation_check
    check (intonation is null or intonation in ('normal', 'insufficient', 'monotone')),
  breathing      text
    constraint prosody_assessments_breathing_check
    check (breathing is null or breathing in ('normal', 'shallow', 'weak_exhale', 'uneven')),
  voice          text
    constraint prosody_assessments_voice_check
    check (voice is null or voice in ('normal', 'weak', 'hoarse', 'nasal', 'monotone')),
  logical_stress text
    constraint prosody_assessments_logical_stress_check
    check (logical_stress is null or logical_stress in ('normal', 'incorrect', 'absent')),

  conclusion    text
    constraint prosody_assessments_conclusion_check
    check (conclusion is null or length(conclusion) <= 2000),

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz,

  -- Р4: хотя бы одно содержательное поле — инвариант схемы, не только
  -- проверка в record_ (её update_ через сентинел '' обходил бы целиком).
  constraint prosody_assessments_not_empty
    check (num_nonnulls(tempo, rhythm, intonation, breathing, voice, logical_stress, conclusion) >= 1),

  constraint prosody_assessments_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade,
  -- Р5: список колонок у SET NULL — без него Postgres зануляет весь
  -- составной FK, включая center_id not null (урок 0022, не унаследован
  -- 0036/0066).
  constraint prosody_assessments_teacher_fk
    foreign key (teacher_id, center_id) references public.teachers (id, center_id) on delete set null (teacher_id)
);

comment on table public.prosody_assessments is
  'Просодика — четвёртый раздел речевой карты (0067, Фаза 3.4). ИСТОРИЯ (решение владельца), не профиль: новая строка на каждое обследование, архивация вместо правки на месте — как syllable_assessments (0066). Шесть категориальных text-полей (форма — как student_articulation, 0065), не массивы: находки не комбинируются внутри одного обследования. Родителю не видна (ADR-005). Запись — только record_/update_/archive_prosody_assessment.';

-- Р7: два обследования в один день — валидный сценарий (0066 Р17), сортировка
-- детерминированная.
create index if not exists prosody_assessments_student_idx
  on public.prosody_assessments (student_id, date desc, created_at desc) where deleted_at is null;
create index if not exists prosody_assessments_center_idx
  on public.prosody_assessments (center_id) where deleted_at is null;

drop trigger if exists prosody_assessments_set_updated_at on public.prosody_assessments;
create trigger prosody_assessments_set_updated_at
  before update on public.prosody_assessments
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('prosody_assessments');
call public.apply_audit('prosody_assessments');
call public.apply_readonly_guard('prosody_assessments');

-- clinical_student_visible/student_primary_teacher/student_alive (0063/0065)
-- — только вызовы, тела чужие, не переиздаются.
drop policy if exists prosody_assessments_teacher_read on public.prosody_assessments;
create policy prosody_assessments_teacher_read on public.prosody_assessments
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

-- Р13/0066 (точный образец): student_alive держит ВСЕХ, включая owner/admin,
-- без исключений — restrictive без этого была бы комментарием, не замком, на
-- первую же будущую запись students.deleted_at мимо status (0059 Р14).
drop policy if exists prosody_assessments_visible on public.prosody_assessments;
create policy prosody_assessments_visible on public.prosody_assessments
  as restrictive for select to authenticated
  using (
    public.student_alive(student_id)
    and (
      public.clinical_student_visible(student_id)
      or public.student_primary_teacher(student_id)
      or created_by = auth.uid()
    )
  );

revoke all on table public.prosody_assessments from public, anon, authenticated;
grant select on public.prosody_assessments to authenticated;


-- record_prosody_assessment ------------------------------------------------------------------

create or replace function public.record_prosody_assessment(
  p_student_id     uuid,
  p_date           date default null,
  p_teacher_id     uuid default null,
  p_tempo          text default null,
  p_rhythm         text default null,
  p_intonation     text default null,
  p_breathing      text default null,
  p_voice          text default null,
  p_logical_stress text default null,
  p_conclusion     text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center         uuid := public.current_center();
  v_role           text := coalesce(public.my_role(), '');
  v_teacher_id     uuid;
  v_id             uuid;
  v_tempo          text := nullif(trim(coalesce(p_tempo, '')), '');
  v_rhythm         text := nullif(trim(coalesce(p_rhythm, '')), '');
  v_intonation     text := nullif(trim(coalesce(p_intonation, '')), '');
  v_breathing      text := nullif(trim(coalesce(p_breathing, '')), '');
  v_voice          text := nullif(trim(coalesce(p_voice, '')), '');
  v_logical_stress text := nullif(trim(coalesce(p_logical_stress, '')), '');
  v_conclusion     text := nullif(trim(coalesce(p_conclusion, '')), '');
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

  -- Гарантия — именованный CHECK prosody_assessments_not_empty (Р4); эта
  -- проверка — только читаемый 22023 вместо голого 23514 на самом частом
  -- пути (пустая форма), над теми же нормализованными '' → null значениями.
  if num_nonnulls(v_tempo, v_rhythm, v_intonation, v_breathing, v_voice, v_logical_stress, v_conclusion) = 0 then
    raise exception 'Заполните хотя бы одно поле обследования' using errcode = '22023';
  end if;

  -- Симметрично чтению — clinical_teacher_sees или primary_teacher_id (0066 Р3).
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

  -- Р6 (пересмотрено ревью написанного SQL): проверка — ПОСЛЕ ветвления,
  -- одна на оба пути, а не только внутри ветки owner/admin. Иначе archive_
  -- teacher ставит только teachers.deleted_at (0017), не трогая membership
  -- (отзыв доступа — отдельное действие, revoke_membership, 0050) — и
  -- my_teacher_id() уволенного специалиста проходил бы молча, если владелец
  -- забыл отозвать доступ отдельно.
  if v_teacher_id is not null and not exists (
    select 1 from public.teachers t
     where t.id = v_teacher_id and t.center_id = v_center and t.deleted_at is null
  ) then
    raise exception 'Специалист не найден' using errcode = '42704';
  end if;

  insert into public.prosody_assessments (
    center_id, student_id, teacher_id, date,
    tempo, rhythm, intonation, breathing, voice, logical_stress, conclusion
  ) values (
    v_center, p_student_id, v_teacher_id, coalesce(p_date, public.center_today(v_center)),
    v_tempo, v_rhythm, v_intonation, v_breathing, v_voice, v_logical_stress, v_conclusion
  )
  returning id into v_id;

  perform public.emit_event('prosody_assessment.created',
    jsonb_build_object('center_id', v_center, 'assessment_id', v_id, 'student_id', p_student_id), v_center);

  return v_id;
end;
$$;

comment on function public.record_prosody_assessment(uuid, date, uuid, text, text, text, text, text, text, text) is
  'Новая запись обследования просодики (0067). Круг записи симметричен чтению (0066 Р3). Специалист — не архивный, проверка одна после ветвления teacher/owner-admin, не только в одной из веток (Р6). '''' в любом из семи текстовых полей нормализуется в NULL до insert (Р3) — guard «хотя бы одно поле» держит именованный CHECK prosody_assessments_not_empty (Р4), не только эта функция.';

revoke all on function public.record_prosody_assessment(uuid, date, uuid, text, text, text, text, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.record_prosody_assessment(uuid, date, uuid, text, text, text, text, text, text, text) to authenticated;


-- update_prosody_assessment -------------------------------------------------------------------

create or replace function public.update_prosody_assessment(
  p_id                   uuid,
  p_date                 date default null,
  p_tempo                text default null,
  p_rhythm               text default null,
  p_intonation           text default null,
  p_breathing            text default null,
  p_voice                text default null,
  p_logical_stress       text default null,
  p_conclusion           text default null,
  p_expected_updated_at  timestamptz default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid := public.current_center();
  v_role     text := coalesce(public.my_role(), '');
  v_row      public.prosody_assessments;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.prosody_assessments
   where id = p_id and center_id = v_center and deleted_at is null
   for update;
  if not found then
    raise exception 'Запись не найдена' using errcode = '42704';
  end if;

  -- Р10 (ревью написанного SQL): student_alive — общее предусловие для
  -- ВСЕХ ролей, включая owner/admin, не только ветки teacher. Restrictive-
  -- политика (prosody_assessments_visible) уже держит эту границу на
  -- чтение для всех без исключения (образец 0066 Р13) — запись обязана
  -- быть не шире чтения: иначе первая же будущая RPC, реально ставящая
  -- students.deleted_at (запрос родителя на удаление данных ребёнка),
  -- откроет правку записи, которую владелец уже не видит на экране.
  -- archive_ этой проверки сознательно НЕ получает — архивировать старую
  -- запись удалённого ребёнка (уборка) не запрещаем.
  if not public.student_alive(v_row.student_id) then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  -- Р8: teacher_id не меняется через update_ — ошибка в поле «специалист»
  -- правится архивацией и новой записью, не тихой подменой автора.
  -- coalesce(...,false) — 0066 Р2.
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

  -- Р3 (пересмотрено ревью написанного SQL): '' → null, но ТОЛЬКО когда
  -- параметр реально передан (не null) — null-параметр остаётся «не
  -- трогать». nullif(trim(...),'') схлопывает и '', и голый пробел: форма
  -- правки — полный снимок, и пробел в textarea не должен обходить
  -- prosody_assessments_not_empty так же, как пустая строка (находка 2).
  update public.prosody_assessments set
    date           = coalesce(p_date, date),
    tempo          = case when p_tempo is null then tempo else nullif(trim(p_tempo), '') end,
    rhythm         = case when p_rhythm is null then rhythm else nullif(trim(p_rhythm), '') end,
    intonation     = case when p_intonation is null then intonation else nullif(trim(p_intonation), '') end,
    breathing      = case when p_breathing is null then breathing else nullif(trim(p_breathing), '') end,
    voice          = case when p_voice is null then voice else nullif(trim(p_voice), '') end,
    logical_stress = case when p_logical_stress is null then logical_stress else nullif(trim(p_logical_stress), '') end,
    conclusion     = case when p_conclusion is null then conclusion else nullif(trim(p_conclusion), '') end
   where id = p_id;

  perform public.emit_event('prosody_assessment.updated',
    jsonb_build_object('center_id', v_center, 'assessment_id', p_id, 'student_id', v_row.student_id), v_center);
end;
$$;

comment on function public.update_prosody_assessment(uuid, date, text, text, text, text, text, text, text, timestamptz) is
  'Правка записи обследования просодики (0067). null-параметр — не трогать; '''' и пробел — снять поле (nullif(trim(...),''''), Р3), на всех семи текстовых полях одинаково. teacher_id не меняется (Р8). p_expected_updated_at обязателен при расхождении — 22023 без автоповтора. student_alive — общее предусловие для всех ролей, включая owner/admin (Р10), не только ветки teacher.';

revoke all on function public.update_prosody_assessment(uuid, date, text, text, text, text, text, text, text, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.update_prosody_assessment(uuid, date, text, text, text, text, text, text, text, timestamptz) to authenticated;


-- archive_prosody_assessment -------------------------------------------------------------------

create or replace function public.archive_prosody_assessment(p_id uuid)
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
  -- Как archive_diagnostic/archive_syllable_assessment: только owner/admin.
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.prosody_assessments set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null
   returning student_id into v_student;
  v_found := found;

  if v_found then
    perform public.emit_event('prosody_assessment.archived',
      jsonb_build_object('center_id', v_center, 'assessment_id', p_id, 'student_id', v_student), v_center);
  end if;

  return v_found;
end;
$$;

comment on function public.archive_prosody_assessment(uuid) is
  'Архивация обследования просодики — только owner/admin, как archive_syllable_assessment (0066).';

revoke all on function public.archive_prosody_assessment(uuid) from public, anon, authenticated, service_role;
grant execute on function public.archive_prosody_assessment(uuid) to authenticated;


-- export_center_tables() — переиздана от 0066, добавлена prosody_assessments --

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
    ('payment_sources'), ('payments'), ('platform_payments'), ('prosody_assessments'), ('rooms'),
    ('salary_adjustments'), ('salary_runs'), ('services'), ('student_anamnesis'),
    ('student_articulation'), ('student_payers'), ('students'), ('subscription_freezes'),
    ('subscription_types'), ('subscriptions'), ('syllable_assessments'), ('teacher_rates'), ('teachers')
$$;

comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
