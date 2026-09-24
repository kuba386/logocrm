-- =============================================================================
-- 0063_student_anamnesis.sql — анамнез: первый раздел полной речевой карты
--
-- Владелец 24.09.2026: «Фаза 3» (речевая карта) строится по одному разделу
-- за раз, а не одной миграцией на всё. Это первый — анамнез (история до
-- первого приёма): беременность/роды, ранее развитие и речевые вехи,
-- перенесённые заболевания, наследственность, условия воспитания, слух и
-- зрение на момент сбора. В отличие от diagnostics (запись на приём,
-- история копится и архивируется) — это ПРОФИЛЬ: одна строка на ребёнка,
-- собирается один раз при первичке и дозаполняется по мере уточнения, без
-- смысла «архивировать» её целиком.
--
-- Ревью плана архитектором, решения:
--
--   Р1. Запись — не record/update, а один upsert-RPC set_student_anamnesis
--       с ЕДИНЫМ jsonb-параметром p_fields (белый список ключей внутри).
--       Причина двойная: (а) следующие разделы карты (артикуляционный
--       аппарат, слоговая структура…) добавят свои поля — позиционная
--       сигнатура на 17+ параметров росла бы миграция за миграцией, а
--       drop/create с новым списком рушит вызовы прошлых миграций
--       (0059 Р13 — тот же урок, здесь он бьёт сильнее); (б) семантика
--       поля «есть ключ → записать/снять (null или '' → NULL внутри jsonb
--       уже дают снять), нет ключа → не трогать» без этого была
--       нереализуема тремя разными способами трижды — здесь она одна.
--   Р2. Оптимистичная блокировка: p_expected_updated_at должен совпасть с
--       текущим updated_at существующей строки, иначе 22023 без
--       автоповтора (приём transfer_remaining/0059 Р7). Профиль
--       дозаполняют многократно и с перерывами — без замка правка
--       специалиста и правка администратора в одну сессию гасят друг
--       друга молча.
--   Р3. PK — суррогатный id, НЕ student_id: audit_trigger (0001) берёт
--       row_id из колонки id; без неё запись анамнеза стала бы
--       единственной таблицей, где прошлые значения в audit_log
--       физически есть, но не адресуются ничем (панель истории на
--       карточке ищет по table_name+row_id). unique(student_id) держит
--       честный 1:1 так же, как PK.
--   Р4. Кто пишет: owner/admin — всегда; teacher — либо у него уже есть
--       clinical_teacher_sees на этого ученика (занятие/приём состоялись),
--       либо строки анамнеза ЕЩЁ НЕТ (первое заполнение). Анамнез чаще
--       собирают ДО первого занятия (на первичной консультации), а
--       clinical_teacher_sees требует существующего занятия — без этой
--       оговорки основной сценарий давал бы 42501 на самом обычном
--       действии. Правка уже существующей строки чужим специалистом
--       (без своего занятия с ребёнком) по-прежнему закрыта.
--   Р5. Видимость на чтение — новая clinical_student_visible(uuid):
--       owner/admin или clinical_teacher_sees, НЕ clinical_visible_to_caller
--       (та включает parent — родитель прочитал бы «алкоголизм отца»,
--       тот же класс данных, что sounds/speech_areas, ADR-005). Функция
--       объявлена одна на всех — clinical_diagnostic_visible (0059)
--       переиздана здесь ЖЕ ФАЙЛОМ, чтобы делегировать в неё: иначе круг
--       ролей живёт в двух местах и расходится при следующей правке.
--       RESTRICTIVE-политика (образец 0059 Р14) — обязательна и для
--       owner/admin: без неё tenant_admin (permissive) отдал бы строку по
--       одному center_id, не проверяя, жив ли ученик, чей это анамнез.
--   Р6. Шестнадцать текстовых/числовых полей — у каждого текстового CHECK
--       на длину (образец diagnostic_referrals.note, 0059: до 2000 для
--       «течений», 500 для коротких заметок), у pregnancy_number/
--       birth_number — диапазон 1..20. apgar — переименован в apgar_note
--       (не «apgar_score»): значения пишут вперемешку («7/8», «7-8», «не
--       помню»), обещать фильтруемость форматом было бы нечестно.
--   Р7. collected_at — дата сбора анамнеза, не updated_at: половина полей
--       («слух в норме, проверяли») актуальна на дату записи со слов
--       родителя, а не на дату последней правки другого поля. По
--       умолчанию — center_today() центра при первой записи, не now() и
--       не дата браузера.
--   Р8. Явные center_id-FK на centers, индекс на center_id, moddatetime-
--       триггер, apply_audit, apply_readonly_guard — по каталогу
--       (docs/Database.md), без исключений: профильная таблица, не
--       денормализованный кеш.
--   Р9. export_center_tables()/readonly_guard_exempt_tables() переизданы
--       от актуальной редакции — 0059 (проверено grep по всем миграциям,
--       не по памяти): student_anamnesis добавлена в allow-list экспорта
--       (данные центра о ребёнке, не служебный кеш — как diagnostics, не
--       как funnel_events/suggest_speech_conclusion из 0061).
--
-- Ревью написанного SQL (после Р1–Р9), решения:
--
--   Р10. Р4 расширен: teacher, создавший запись без clinical_teacher_sees
--        (первое заполнение), сохраняет доступ к СВОЕЙ же записи и на
--        чтение, и на дальнейшую правку (created_by = auth.uid()) — тот же
--        приём, что 0038/0059 Р18 для diagnostics. Без этого первое
--        заполнение упиралось бы в тупик: форма после сохранения читалась
--        бы как пустая (clinical_student_visible её не открывает), а
--        следующая правка не могла бы получить updated_at для замка.
--   Р11. select … for update перед проверкой замка: без него check-then-act
--        в plpgsql не держит две транзакции с одинаковым (актуальным на
--        момент чтения) p_expected_updated_at — обе проходят проверку до
--        коммита первой. Приём — тот же, что update_diagnostic (0059 Р7).
--   Р12. Гонка на первой вставке (два специалиста открыли первичку
--        одновременно) ловится явным exception when unique_violation —
--        свой текст вместо голого 23505, без автоповтора (затёр бы чужую
--        строку).
--   Р13. Типы значений p_fields проверяются explicit raise ДО insert/update,
--        не сырым кастом: нечисловая строка в pregnancy_number или вложенный
--        объект в текстовом поле получают понятный 22023 с именем поля, а
--        не 22P02 без перевода на русский (errors.ts его не знает) или
--        тихую запись JSON-текста в колонку.
--   Р14. Пустой p_fields = '{}' — явная 22023, не проход до update: иначе
--        «Сохранить» без единой правки двигало бы updated_at, засоряло
--        audit_log копией себя же и било бы 22023 по чужой открытой форме.
--   Р15. collected_at получил CHECK-диапазон (2000-01-01 .. завтра) —
--        единственное поле без границ в первой редакции.
-- =============================================================================


-- 1. clinical_student_visible — единый круг ролей для клинических данных ребёнка ------------------

create or replace function public.clinical_student_visible(p_student_id uuid)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
begin
  if auth.uid() is null or v_center is null then
    return false;
  end if;

  if not exists (
    select 1 from public.students s
     where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null
  ) then
    return false;
  end if;

  if v_role in ('owner', 'admin') then
    return true;
  end if;
  if v_role = 'teacher' then
    return public.clinical_teacher_sees(p_student_id);
  end if;
  return false;
end;
$$;

comment on function public.clinical_student_visible(uuid) is
  'Единый круг ролей для клинических данных ребёнка (0063 Р5): owner/admin, или teacher через clinical_teacher_sees. НЕ clinical_visible_to_caller (та включает parent). clinical_diagnostic_visible (0059) делегирует сюда после разрешения diagnostic_id → student_id.';

revoke all on function public.clinical_student_visible(uuid) from public, anon, service_role;
grant execute on function public.clinical_student_visible(uuid) to authenticated;


-- 2. clinical_diagnostic_visible (0059) — переиздана, делегирует в clinical_student_visible --------

create or replace function public.clinical_diagnostic_visible(p_diagnostic_id uuid)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_student uuid;
begin
  if auth.uid() is null or v_center is null then
    return false;
  end if;

  select d.student_id into v_student
    from public.diagnostics d
   where d.id = p_diagnostic_id and d.center_id = v_center and d.deleted_at is null;
  if not found then
    return false;
  end if;

  return public.clinical_student_visible(v_student);
end;
$$;

comment on function public.clinical_diagnostic_visible(uuid) is
  'Видимость junction-таблиц диагностики (0059): owner/admin, teacher через clinical_teacher_sees. С 0063 — тонкая обёртка над clinical_student_visible(uuid), которая держит круг ролей единолично.';

revoke all on function public.clinical_diagnostic_visible(uuid) from public, anon, service_role;
grant execute on function public.clinical_diagnostic_visible(uuid) to authenticated;


-- 3. student_anamnesis ------------------------------------------------------------------------------

create table if not exists public.student_anamnesis (
  id                     uuid primary key default gen_random_uuid(),
  center_id              uuid not null default public.current_center()
                           references public.centers (id) on delete cascade,
  student_id             uuid not null,

  collected_at           date check (collected_at is null or collected_at between date '2000-01-01' and current_date + 1),

  pregnancy_number       integer check (pregnancy_number is null or pregnancy_number between 1 and 20),
  birth_number           integer check (birth_number is null or birth_number between 1 and 20),
  pregnancy_course       text check (pregnancy_course is null or length(pregnancy_course) <= 2000),
  birth_course           text check (birth_course is null or length(birth_course) <= 2000),
  apgar_note             text check (apgar_note is null or length(apgar_note) <= 200),

  early_development      text check (early_development is null or length(early_development) <= 2000),
  cooing_age             text check (cooing_age is null or length(cooing_age) <= 200),
  babbling_age           text check (babbling_age is null or length(babbling_age) <= 200),
  first_words_age        text check (first_words_age is null or length(first_words_age) <= 200),
  phrase_speech_age      text check (phrase_speech_age is null or length(phrase_speech_age) <= 200),

  illnesses_injuries     text check (illnesses_injuries is null or length(illnesses_injuries) <= 2000),
  heredity               text check (heredity is null or length(heredity) <= 2000),
  upbringing_conditions  text check (upbringing_conditions is null or length(upbringing_conditions) <= 2000),
  hearing_note           text check (hearing_note is null or length(hearing_note) <= 1000),
  vision_note            text check (vision_note is null or length(vision_note) <= 1000),
  notes                  text check (notes is null or length(notes) <= 2000),

  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid default auth.uid(),
  updated_by             uuid,

  constraint student_anamnesis_student_key unique (student_id),
  constraint student_anamnesis_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade
);

comment on table public.student_anamnesis is
  'Анамнез — первый раздел речевой карты (0063, Фаза 3.1). Одна строка на ребёнка, не история: собирается один раз при первичке, дозаполняется. Родителю не видна ни в каком виде (ADR-005: тот же класс, что sounds/speech_areas, только чувствительнее — третьи лица, наследственность). Запись — только set_student_anamnesis(uuid,jsonb,timestamptz).';

create index if not exists student_anamnesis_center_idx on public.student_anamnesis (center_id);

drop trigger if exists student_anamnesis_set_updated_at on public.student_anamnesis;
create trigger student_anamnesis_set_updated_at
  before update on public.student_anamnesis
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('student_anamnesis', false);
call public.apply_audit('student_anamnesis');
call public.apply_readonly_guard('student_anamnesis');

-- Р4-исключение (найдено ревью написанного SQL): teacher без своего занятия
-- может создать первую запись анамнеза (первичка до первого приёма), но
-- clinical_student_visible её не откроет — форма при перезагрузке была бы
-- пустой, а следующая правка не могла бы получить updated_at и упиралась
-- бы в ложное «изменили параллельно». Автор строки сохраняет доступ к
-- своей же записи — тот же приём, что 0038/0059 Р18 для diagnostics
-- (created_by = auth.uid() видит и правит независимо от текущей
-- clinical_teacher_sees).
drop policy if exists student_anamnesis_teacher_read on public.student_anamnesis;
create policy student_anamnesis_teacher_read on public.student_anamnesis
  for select to authenticated
  using (
    center_id = public.current_center()
    and (public.clinical_student_visible(student_id) or created_by = auth.uid())
  );

-- Р5: restrictive — обязательна для ВСЕХ читателей, включая owner/admin
-- через permissive tenant_admin (0059 Р14, тот же класс дыры). Исключение
-- автора — то же самое и здесь, иначе restrictive отменит его.
drop policy if exists student_anamnesis_visible on public.student_anamnesis;
create policy student_anamnesis_visible on public.student_anamnesis
  as restrictive for select to authenticated
  using (public.clinical_student_visible(student_id) or created_by = auth.uid());

revoke all on table public.student_anamnesis from public, anon, authenticated;
grant select on public.student_anamnesis to authenticated;


-- 4. set_student_anamnesis — единственный путь записи (Р1/Р2/Р4) -----------------------------------

create or replace function public.set_student_anamnesis(
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
  v_allowed_keys text[] := array[
    'collected_at', 'pregnancy_number', 'birth_number', 'pregnancy_course', 'birth_course',
    'apgar_note', 'early_development', 'cooing_age', 'babbling_age', 'first_words_age',
    'phrase_speech_age', 'illnesses_injuries', 'heredity', 'upbringing_conditions',
    'hearing_note', 'vision_note', 'notes'
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

  -- for update: без замка на строке check-then-act в plpgsql не держит две
  -- одновременные транзакции с одинаковым (верным) p_expected_updated_at —
  -- обе проходят проверку до того, как первая закоммитит (Р2/находка 3).
  select a.id, a.updated_at, a.created_by into v_id, v_current, v_created_by
    from public.student_anamnesis a where a.student_id = p_student_id
    for update;
  v_exists := found;

  -- Р4: owner/admin всегда; teacher — либо своя видимость уже есть, либо
  -- строки ещё нет вовсе (первое заполнение до первого занятия), либо это
  -- его же запись (создал без clinical_teacher_sees — не запирать в
  -- собственном вводе на следующей правке, симметрично read-политике).
  if not (
    v_role in ('owner', 'admin')
    or (v_role = 'teacher' and (
      not v_exists or public.clinical_teacher_sees(p_student_id) or v_created_by = auth.uid()
    ))
  ) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р2: замок по снимку updated_at. v_current null у новой строки — сюда
  -- не попадает (v_exists=false пропускает проверку).
  if v_exists and p_expected_updated_at is distinct from v_current then
    raise exception 'Анамнез изменили параллельно — обновите страницу и повторите' using errcode = '22023';
  end if;

  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then
    raise exception 'Поля анамнеза: ожидается объект' using errcode = '22023';
  end if;

  select k into v_bad_key from jsonb_object_keys(p_fields) k
   where k <> all (v_allowed_keys) limit 1;
  if v_bad_key is not null then
    raise exception 'Неизвестное поле анамнеза: %', v_bad_key using errcode = '22023';
  end if;

  if p_fields = '{}'::jsonb then
    raise exception 'Не передано ни одного поля для записи' using errcode = '22023';
  end if;

  -- Тип проверяется здесь явным raise, а не отдаётся сырым кастом (Р6
  -- ревью написанного SQL): "не помню" в pregnancy_number иначе дал бы
  -- голый 22P02 без текста на русском, а {"heredity": {...}} молча ушёл бы
  -- в поле текстом объекта — jsonb->>'key' не проверяет форму значения.
  for v_key, v_val in select * from jsonb_each(p_fields) loop
    if v_key = any (array['pregnancy_number', 'birth_number']) then
      if jsonb_typeof(v_val) not in ('number', 'null') then
        raise exception 'Поле "%": ожидается число', v_key using errcode = '22023';
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
    update public.student_anamnesis set
      collected_at          = case when p_fields ? 'collected_at'
                                 then nullif(p_fields ->> 'collected_at', '')::date else collected_at end,
      pregnancy_number       = case when p_fields ? 'pregnancy_number'
                                 then nullif(p_fields ->> 'pregnancy_number', '')::integer else pregnancy_number end,
      birth_number           = case when p_fields ? 'birth_number'
                                 then nullif(p_fields ->> 'birth_number', '')::integer else birth_number end,
      pregnancy_course       = case when p_fields ? 'pregnancy_course'
                                 then nullif(p_fields ->> 'pregnancy_course', '') else pregnancy_course end,
      birth_course           = case when p_fields ? 'birth_course'
                                 then nullif(p_fields ->> 'birth_course', '') else birth_course end,
      apgar_note             = case when p_fields ? 'apgar_note'
                                 then nullif(p_fields ->> 'apgar_note', '') else apgar_note end,
      early_development      = case when p_fields ? 'early_development'
                                 then nullif(p_fields ->> 'early_development', '') else early_development end,
      cooing_age             = case when p_fields ? 'cooing_age'
                                 then nullif(p_fields ->> 'cooing_age', '') else cooing_age end,
      babbling_age           = case when p_fields ? 'babbling_age'
                                 then nullif(p_fields ->> 'babbling_age', '') else babbling_age end,
      first_words_age        = case when p_fields ? 'first_words_age'
                                 then nullif(p_fields ->> 'first_words_age', '') else first_words_age end,
      phrase_speech_age      = case when p_fields ? 'phrase_speech_age'
                                 then nullif(p_fields ->> 'phrase_speech_age', '') else phrase_speech_age end,
      illnesses_injuries     = case when p_fields ? 'illnesses_injuries'
                                 then nullif(p_fields ->> 'illnesses_injuries', '') else illnesses_injuries end,
      heredity               = case when p_fields ? 'heredity'
                                 then nullif(p_fields ->> 'heredity', '') else heredity end,
      upbringing_conditions  = case when p_fields ? 'upbringing_conditions'
                                 then nullif(p_fields ->> 'upbringing_conditions', '') else upbringing_conditions end,
      hearing_note           = case when p_fields ? 'hearing_note'
                                 then nullif(p_fields ->> 'hearing_note', '') else hearing_note end,
      vision_note            = case when p_fields ? 'vision_note'
                                 then nullif(p_fields ->> 'vision_note', '') else vision_note end,
      notes                  = case when p_fields ? 'notes'
                                 then nullif(p_fields ->> 'notes', '') else notes end,
      updated_by = auth.uid()
    where student_id = p_student_id
    returning id into v_id;
  else
    begin
      insert into public.student_anamnesis (
        center_id, student_id, collected_at, pregnancy_number, birth_number, pregnancy_course,
        birth_course, apgar_note, early_development, cooing_age, babbling_age, first_words_age,
        phrase_speech_age, illnesses_injuries, heredity, upbringing_conditions, hearing_note,
        vision_note, notes, updated_by
      ) values (
        v_center, p_student_id,
        coalesce(nullif(p_fields ->> 'collected_at', '')::date, public.center_today(v_center)),
        nullif(p_fields ->> 'pregnancy_number', '')::integer,
        nullif(p_fields ->> 'birth_number', '')::integer,
        nullif(p_fields ->> 'pregnancy_course', ''),
        nullif(p_fields ->> 'birth_course', ''),
        nullif(p_fields ->> 'apgar_note', ''),
        nullif(p_fields ->> 'early_development', ''),
        nullif(p_fields ->> 'cooing_age', ''),
        nullif(p_fields ->> 'babbling_age', ''),
        nullif(p_fields ->> 'first_words_age', ''),
        nullif(p_fields ->> 'phrase_speech_age', ''),
        nullif(p_fields ->> 'illnesses_injuries', ''),
        nullif(p_fields ->> 'heredity', ''),
        nullif(p_fields ->> 'upbringing_conditions', ''),
        nullif(p_fields ->> 'hearing_note', ''),
        nullif(p_fields ->> 'vision_note', ''),
        nullif(p_fields ->> 'notes', ''),
        auth.uid()
      )
      returning id into v_id;
    exception
      when unique_violation then
        -- Р4-гонка (находка 5): два специалиста на первичке открыли форму
        -- одновременно. Автоповтора нет — повтор затёр бы чужую строку.
        raise exception 'Анамнез уже создан — обновите страницу' using errcode = '22023';
    end;
  end if;

  perform public.emit_event(
    case when v_exists then 'anamnesis.updated' else 'anamnesis.created' end,
    jsonb_build_object('center_id', v_center, 'anamnesis_id', v_id, 'student_id', p_student_id), v_center);

  return v_id;
end;
$$;

comment on function public.set_student_anamnesis(uuid, jsonb, timestamptz) is
  'Единственный путь записи анамнеза (0063). p_fields — белый список ключей: ключ есть (даже со значением null/"") → записать/снять поле; ключа нет → не трогать; пустой объект — 22023 (Р14). p_expected_updated_at обязателен к передаче текущим значением при правке существующей строки — расхождение даёт 22023 без автоповтора (Р2/Р11, select for update). Первое заполнение (строки ещё нет) доступно любому teacher центра; правка существующей — через clinical_teacher_sees либо собственное авторство записи (Р10); гонка на первой вставке — 22023, не голый 23505 (Р12).';

revoke all on function public.set_student_anamnesis(uuid, jsonb, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.set_student_anamnesis(uuid, jsonb, timestamptz) to authenticated;


-- 5. export_center_tables() / readonly_guard_exempt_tables() — переизданы от 0059 (Р9) --------------

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
    ('student_payers'), ('students'), ('subscription_freezes'), ('subscription_types'),
    ('subscriptions'), ('teacher_rates'), ('teachers')
$$;

comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis — данные центра о ребёнке, не служебный кеш. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;

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
    ('referral_targets',        'Р1 (0059): глобальный справочник без center_id, пишет только миграция')
$$;

revoke all on function public.readonly_guard_exempt_tables() from public, anon, authenticated, service_role;
