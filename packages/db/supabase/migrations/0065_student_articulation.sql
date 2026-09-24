-- =============================================================================
-- 0065_student_articulation.sql — артикуляционный аппарат: второй раздел речевой карты
--
-- Фаза 3.2 (по одному разделу за раз, как 0063). Осмотр строения и
-- подвижности губ, зубов, прикуса, нёба, языка, уздечки — фиксированные
-- клинические находки, не свободный анамнез. Собирается обычно рядом с
-- анамнезом, но ОТДЕЛЬНОЙ таблицей, не колонками student_anamnesis:
-- иначе исключение автора анамнеза бесплатно открыло бы и осмотр,
-- updated_at на двух разделах гасил бы правки друг друга ложным «изменили
-- параллельно», а audit_log перестал бы различать, какой раздел правили.
--
-- Ревью плана архитектором, решения:
--
--   Р1. Значения — латинские коды (normal/limited/paretic/…), не русский
--       текст в колонке: как students.status, payments.kind, а не
--       свободные слова. Правка формулировки перестаёт быть миграцией
--       данных; русский текст — в apps/web/lib/errors.ts (CHECK_MESSAGES),
--       единственном месте разбора ошибок, как и остальные CHECK во всём
--       проекте.
--   Р2. Инлайн CHECK на колонке, не lookup-таблица: терминология осмотра —
--       не настраиваемый центром справочник (в отличие от
--       speech_conclusions/clinical_forms, 0059) и не список, который
--       расширяют без миграции. Одна попытка держать значения и в CHECK, и
--       списком внутри RPC — отклонена: два места легко разойтись, а
--       разошедшись, RPC начинает врать (отбивать код, который таблица бы
--       приняла) — хуже отсутствия проверки. RPC проверяет только ФОРМУ
--       значения (jsonb_typeof), CHECK — единственный источник истины по
--       допустимым кодам.
--   Р3. Четыре поля, где находки реально сочетаются (толстые губы +
--       асимметрия, редкие + кривые зубы, укороченное + малоподвижное
--       мягкое нёбо), — text[] с constraint `<@` (образец
--       notification_event_types.channels, 0051), не одно значение: иначе
--       структурированное поле теряет половину находок в notes без
--       возврата. Остальные (подвижность губ/языка, прикус, уздечка) —
--       одно значение, там альтернативы взаимоисключающие.
--   Р4. Исключение автора (0063 Р10) СУЖЕНО, а не скопировано как есть:
--       вместо «любой teacher центра создаёт первую запись» — только
--       teacher, у которого уже есть clinical_teacher_sees ИЛИ он назначен
--       primary_teacher_id ребёнка. Копировать формулировку «любой
--       teacher» в каждый следующий раздел карты линейно растит площадь
--       «зашёл первым — получил доступ навсегда» по всему центру.
--       primary_teacher_id дан СИММЕТРИЧНО чтению и записи, не только
--       первому заполнению (Р9) — см. student_primary_teacher() ниже.
--   Р5. student_alive/clinical_student_visible/clinical_diagnostic_visible
--       (0063) НЕ переиздаются — только вызываются. Копия тела в новую
--       миграцию рискует откатить будущий фикс этих функций, если он
--       приедет из параллельного PR раньше мержа этого; заодно исключает
--       класс инлайн-exists-в-политике, который 0063 поймал только по CI
--       (RLS students фильтрует по primary_teacher_id и скрывает живого
--       ученика от специалиста без прямой связи).
--   Р6. export_center_tables() переиздана от актуальной редакции — 0063
--       (проверено grep по всем миграциям: 0064 её не трогала). Хвост
--       грантов (revoke ...; grant execute ... to authenticated)
--       выписан отдельно и осознанно — 0063 сама на этом падала: соседняя
--       readonly_guard_exempt_tables() заканчивается ДРУГИМ хвостом (без
--       грантов вовсе), и слепое копирование всего блока стирает execute
--       у authenticated. readonly_guard_exempt_tables() и
--       export_center_excluded_tables() НЕ переизданы — в их списки
--       ничего не добавляется (export_center_excluded_tables содержит
--       assistant_requests из 0064 — переиздание от чужой редакции
--       потеряло бы её).
--   Р7. collected_at — та же граница (current_date + 1), что в 0063:
--       забор от опечатки в годе, не бизнес-правило; часовой пояс сервера
--       (UTC) против центра даёт узкое окно у полуночи — принято сознательно,
--       не расширяется. Дефолт при первой записи — center_today(v_center),
--       как в 0063 (упущено в первом проходе, найдено ревью написанного SQL).
--
-- Ревью написанного SQL (после Р1–Р7), решения:
--
--   Р8. Сравнение created_by = auth.uid() в проверке прав ОБЯЗАНО быть
--       тотальным булевым — coalesce(..., false), не голое «=». При
--       v_created_by is null (строки ещё нет) голое сравнение даёт SQL
--       NULL, а «if not (... or NULL or ...)» в plpgsql трактует NULL как
--       «не сработало» и пропускает raise: посторонний специалист снова
--       проходил бы первое заполнение — ровно то, что Р4 должна была
--       закрыть. Блокер, пойман только вторым проходом.
--   Р9. primary_teacher_id — отдельная security-definer функция
--       student_primary_teacher(uuid), а не проверка «только для первого
--       заполнения» внутри RPC: асимметрия «пишет, но не видит» (первый
--       вариант Р4) открывала тот же тупик, что 0063 Р10 чинила по CI —
--       назначенный специалист без занятия сохранял бы пустую страницу
--       (RLS его не пускает) и тут же получал 42501 при попытке
--       заполнить форму, которую только что открыл. security definer —
--       по тому же приёму, что clinical_student_visible/clinical_teacher_sees:
--       inline exists() от вызывающей роли не гарантированно совпадает с
--       RLS students для условий, отличных от primary_teacher_id дословно.
--   Р10. tongue_mobility получил 'paretic' — тот же набор, что
--        lips_mobility; в первом проходе список случайно оказался у́же
--        для языка, хотя клинически подвижность языка описывают не
--        беднее, чем губ.
-- =============================================================================

create table if not exists public.student_articulation (
  id                uuid primary key default gen_random_uuid(),
  center_id         uuid not null default public.current_center()
                      references public.centers (id) on delete cascade,
  student_id        uuid not null,

  collected_at      date
    constraint student_articulation_collected_at_check
    check (collected_at is null or collected_at between date '2000-01-01' and current_date + 1),

  -- Р3: сочетаются — text[]. Имена CHECK — явные (находка 3 ревью
  -- написанного SQL): безымянный инлайн-CHECK на колонке получает имя от
  -- Postgres автоматически, но следующая же правка набора значений
  -- (alter table ... drop constraint ... add constraint) без явного имени
  -- получит другое автоимя — 23514 перестанет матчиться в CHECK_MESSAGES
  -- молча, ни один тест этого не поймает.
  lips_structure    text[]
    constraint student_articulation_lips_structure_check
    check (lips_structure is null or lips_structure <@ array['normal','thick','thin','cleft','asymmetric']),
  teeth             text[]
    constraint student_articulation_teeth_check
    check (teeth is null or teeth <@ array['normal','sparse','crooked','partially_missing']),
  soft_palate       text[]
    constraint student_articulation_soft_palate_check
    check (soft_palate is null or soft_palate <@ array['normal','shortened','cleft','low_mobility']),
  tongue_structure  text[]
    constraint student_articulation_tongue_structure_check
    check (tongue_structure is null or tongue_structure <@ array['normal','massive','small','short_frenulum']),

  -- Взаимоисключающие — одно значение.
  lips_mobility     text
    constraint student_articulation_lips_mobility_check
    check (lips_mobility is null or lips_mobility in ('normal','limited','paretic')),
  bite              text
    constraint student_articulation_bite_check
    check (bite is null or bite in ('normal','prognathia','prognathism','open_anterior','open_lateral','crossbite')),
  hard_palate       text
    constraint student_articulation_hard_palate_check
    check (hard_palate is null or hard_palate in ('normal','gothic','flattened','cleft')),
  -- Подвижность языка описывают богаче, чем губ (паретичность, девиация) —
  -- 'paretic' добавлен для симметрии с lips_mobility, а не сужен произвольно.
  tongue_mobility   text
    constraint student_articulation_tongue_mobility_check
    check (tongue_mobility is null or tongue_mobility in ('normal','limited','paretic')),
  frenulum          text
    constraint student_articulation_frenulum_check
    check (frenulum is null or frenulum in ('normal','shortened','clipped')),

  notes             text
    constraint student_articulation_notes_check
    check (notes is null or length(notes) <= 2000),

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid default auth.uid(),
  updated_by        uuid,

  constraint student_articulation_student_key unique (student_id),
  constraint student_articulation_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade
);

comment on table public.student_articulation is
  'Артикуляционный аппарат — второй раздел речевой карты (0065, Фаза 3.2). Профиль, не история: одна строка на ребёнка, как student_anamnesis (0063), отдельной таблицей (иначе исключение автора и updated_at разделов гасят друг друга). Коды — латиницей (Р1), русский текст в apps/web/lib/errors.ts CHECK_MESSAGES. Родителю не видна (тот же класс, что sounds/speech_areas, ADR-005). Запись — только set_student_articulation(uuid,jsonb,timestamptz).';

create index if not exists student_articulation_center_idx on public.student_articulation (center_id);

drop trigger if exists student_articulation_set_updated_at on public.student_articulation;
create trigger student_articulation_set_updated_at
  before update on public.student_articulation
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('student_articulation', false);
call public.apply_audit('student_articulation');
call public.apply_readonly_guard('student_articulation');

-- Назначенный primary_teacher_id — отношение к ребёнку такого же качества,
-- что clinical_teacher_sees (не «первое заполнение», а полноценный доступ
-- на чтение и запись — находка 2 ревью написанного SQL: асимметрия
-- «пишет, но не видит» открывала тот же тупик, что 0063 Р10 чинила по CI).
-- security definer обязателен (Р5-стиль 0063): inline exists() от
-- вызывающей роли упёрся бы в RLS students для случаев, где условие не
-- совпадает с students_teacher_read_own дословно.
create or replace function public.student_primary_teacher(p_student_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1 from public.students s
     where s.id = p_student_id and s.center_id = public.current_center()
       and s.primary_teacher_id = public.my_teacher_id() and s.deleted_at is null
  );
$$;

comment on function public.student_primary_teacher(uuid) is
  'Вызывающий — назначенный primary_teacher_id ребёнка (0065). Используется наравне с clinical_teacher_sees в разделах речевой карты, где занятия может ещё не быть.';

revoke all on function public.student_primary_teacher(uuid) from public, anon, service_role;
grant execute on function public.student_primary_teacher(uuid) to authenticated;

-- Р5: student_alive/clinical_student_visible — только вызовы, тела чужие, не переиздаются.
drop policy if exists student_articulation_teacher_read on public.student_articulation;
create policy student_articulation_teacher_read on public.student_articulation
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.student_alive(student_id)
    and (
      public.clinical_student_visible(student_id)
      or public.student_primary_teacher(student_id)
      or created_by = auth.uid()
    )
  );

drop policy if exists student_articulation_visible on public.student_articulation;
create policy student_articulation_visible on public.student_articulation
  as restrictive for select to authenticated
  using (
    public.student_alive(student_id)
    and (
      public.clinical_student_visible(student_id)
      or public.student_primary_teacher(student_id)
      or created_by = auth.uid()
    )
  );

revoke all on table public.student_articulation from public, anon, authenticated;
grant select on public.student_articulation to authenticated;


-- set_student_articulation — единственный путь записи (Р2/Р3/Р4) ---------------------------------

create or replace function public.set_student_articulation(
  p_student_id          uuid,
  p_fields              jsonb,
  p_expected_updated_at timestamptz default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center       uuid := public.current_center();
  v_role         text := coalesce(public.my_role(), '');
  v_id           uuid;
  v_current      timestamptz;
  v_created_by   uuid;
  v_exists       boolean;
  v_bad_key      text;
  v_key          text;
  v_val          jsonb;
  v_array_keys   text[] := array['lips_structure', 'teeth', 'soft_palate', 'tongue_structure'];
  v_allowed_keys text[] := array[
    'collected_at', 'lips_structure', 'lips_mobility', 'teeth', 'bite', 'hard_palate',
    'soft_palate', 'tongue_structure', 'tongue_mobility', 'frenulum', 'notes'
  ];
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

  select a.id, a.updated_at, a.created_by into v_id, v_current, v_created_by
    from public.student_articulation a where a.student_id = p_student_id
    for update;
  v_exists := found;

  -- Р4/находка 1: primary_teacher_id теперь симметричен с
  -- clinical_teacher_sees (не только «первое заполнение» — находка 2, та
  -- же сила и на чтение, см. student_primary_teacher() выше). Сравнение с
  -- auth.uid() обязано быть тотальным булевым — coalesce(...,false), не
  -- голое «=»: при v_created_by is null (строки ещё нет) голое сравнение
  -- даёт SQL NULL, а «if not (... or NULL or ...)» в plpgsql пропускает
  -- raise молча — посторонний специалист снова проходит (находка 1,
  -- поймано только ревью написанного SQL, не первым проходом).
  if not (
    v_role in ('owner', 'admin')
    or (v_role = 'teacher' and (
      public.clinical_teacher_sees(p_student_id)
      or public.student_primary_teacher(p_student_id)
      or coalesce(v_created_by = auth.uid(), false)
    ))
  ) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_exists and p_expected_updated_at is distinct from v_current then
    raise exception 'Карта изменена параллельно — обновите страницу и повторите' using errcode = '22023';
  end if;

  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then
    raise exception 'Поля осмотра: ожидается объект' using errcode = '22023';
  end if;

  select k into v_bad_key from jsonb_object_keys(p_fields) k
   where k <> all (v_allowed_keys) limit 1;
  if v_bad_key is not null then
    raise exception 'Неизвестное поле осмотра: %', v_bad_key using errcode = '22023';
  end if;

  if p_fields = '{}'::jsonb then
    raise exception 'Не передано ни одного поля для записи' using errcode = '22023';
  end if;

  -- Р2: RPC проверяет только форму значения; допустимые коды — только
  -- CHECK на колонке (дублировать список здесь запрещено решением Р2).
  for v_key, v_val in select * from jsonb_each(p_fields) loop
    if v_key = any (v_array_keys) then
      if jsonb_typeof(v_val) not in ('array', 'null') then
        raise exception 'Поле "%": ожидается список значений', v_key using errcode = '22023';
      end if;
    elsif v_key = 'collected_at' then
      if jsonb_typeof(v_val) not in ('string', 'null') then
        raise exception 'Поле "collected_at": ожидается дата строкой' using errcode = '22023';
      end if;
      if jsonb_typeof(v_val) = 'string' and (v_val #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then
        raise exception 'Поле "collected_at": ожидается дата в формате ГГГГ-ММ-ДД' using errcode = '22023';
      end if;
    else
      if jsonb_typeof(v_val) not in ('string', 'null') then
        raise exception 'Поле "%": ожидается текст', v_key using errcode = '22023';
      end if;
    end if;
  end loop;

  if v_exists then
    update public.student_articulation set
      collected_at     = case when p_fields ? 'collected_at'
                           then nullif(p_fields ->> 'collected_at', '')::date else collected_at end,
      lips_structure    = case when p_fields ? 'lips_structure'
                           then (select array_agg(e) from jsonb_array_elements_text(
                                  coalesce(nullif(p_fields -> 'lips_structure', 'null'::jsonb), '[]'::jsonb)) e)
                           else lips_structure end,
      lips_mobility    = case when p_fields ? 'lips_mobility'
                           then nullif(p_fields ->> 'lips_mobility', '') else lips_mobility end,
      teeth             = case when p_fields ? 'teeth'
                           then (select array_agg(e) from jsonb_array_elements_text(
                                  coalesce(nullif(p_fields -> 'teeth', 'null'::jsonb), '[]'::jsonb)) e)
                           else teeth end,
      bite             = case when p_fields ? 'bite'
                           then nullif(p_fields ->> 'bite', '') else bite end,
      hard_palate      = case when p_fields ? 'hard_palate'
                           then nullif(p_fields ->> 'hard_palate', '') else hard_palate end,
      soft_palate       = case when p_fields ? 'soft_palate'
                           then (select array_agg(e) from jsonb_array_elements_text(
                                  coalesce(nullif(p_fields -> 'soft_palate', 'null'::jsonb), '[]'::jsonb)) e)
                           else soft_palate end,
      tongue_structure  = case when p_fields ? 'tongue_structure'
                           then (select array_agg(e) from jsonb_array_elements_text(
                                  coalesce(nullif(p_fields -> 'tongue_structure', 'null'::jsonb), '[]'::jsonb)) e)
                           else tongue_structure end,
      tongue_mobility  = case when p_fields ? 'tongue_mobility'
                           then nullif(p_fields ->> 'tongue_mobility', '') else tongue_mobility end,
      frenulum         = case when p_fields ? 'frenulum'
                           then nullif(p_fields ->> 'frenulum', '') else frenulum end,
      notes            = case when p_fields ? 'notes'
                           then nullif(p_fields ->> 'notes', '') else notes end,
      updated_by = auth.uid()
    where student_id = p_student_id
    returning id into v_id;
  else
    begin
      insert into public.student_articulation (
        center_id, student_id, collected_at, lips_structure, lips_mobility, teeth, bite,
        hard_palate, soft_palate, tongue_structure, tongue_mobility, frenulum, notes, updated_by
      ) values (
        v_center, p_student_id,
        coalesce(nullif(p_fields ->> 'collected_at', '')::date, public.center_today(v_center)),
        (select array_agg(e) from jsonb_array_elements_text(
           coalesce(nullif(p_fields -> 'lips_structure', 'null'::jsonb), '[]'::jsonb)) e),
        nullif(p_fields ->> 'lips_mobility', ''),
        (select array_agg(e) from jsonb_array_elements_text(
           coalesce(nullif(p_fields -> 'teeth', 'null'::jsonb), '[]'::jsonb)) e),
        nullif(p_fields ->> 'bite', ''),
        nullif(p_fields ->> 'hard_palate', ''),
        (select array_agg(e) from jsonb_array_elements_text(
           coalesce(nullif(p_fields -> 'soft_palate', 'null'::jsonb), '[]'::jsonb)) e),
        (select array_agg(e) from jsonb_array_elements_text(
           coalesce(nullif(p_fields -> 'tongue_structure', 'null'::jsonb), '[]'::jsonb)) e),
        nullif(p_fields ->> 'tongue_mobility', ''),
        nullif(p_fields ->> 'frenulum', ''),
        nullif(p_fields ->> 'notes', ''),
        auth.uid()
      )
      returning id into v_id;
    exception
      when unique_violation then
        raise exception 'Осмотр уже создан — обновите страницу' using errcode = '22023';
    end;
  end if;

  perform public.emit_event(
    case when v_exists then 'articulation.updated' else 'articulation.created' end,
    jsonb_build_object('center_id', v_center, 'articulation_id', v_id, 'student_id', p_student_id), v_center);

  return v_id;
end;
$$;

comment on function public.set_student_articulation(uuid, jsonb, timestamptz) is
  'Единственный путь записи осмотра артикуляционного аппарата (0065). Тот же jsonb-патч-контракт, что set_student_anamnesis (0063), но круг записи сужен до clinical_teacher_sees/primary_teacher_id (Р4/Р9) — не любой teacher центра, и симметричен кругу чтения. Допустимые коды — только CHECK на колонке (Р2), RPC проверяет лишь форму значения. Сравнение с auth.uid() — только через coalesce (Р8): голое сравнение с NULL пропускает проверку прав.';

revoke all on function public.set_student_articulation(uuid, jsonb, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.set_student_articulation(uuid, jsonb, timestamptz) to authenticated;


-- export_center_tables() — переиздана от 0063, добавлена student_articulation (Р6) -----------------

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
    ('payment_sources'), ('payments'), ('platform_payments'), ('rooms'),
    ('salary_adjustments'), ('salary_runs'), ('services'), ('student_anamnesis'),
    ('student_articulation'), ('student_payers'), ('students'), ('subscription_freezes'),
    ('subscription_types'), ('subscriptions'), ('teacher_rates'), ('teachers')
$$;

comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation — данные центра о ребёнке, не служебный кеш. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
