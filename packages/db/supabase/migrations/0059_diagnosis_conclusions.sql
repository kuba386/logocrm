-- =============================================================================
-- 0059_diagnosis_conclusions.sql — логопедическое заключение как справочник
--
-- Решение владельца 24.09.2026 после анализа рынка (РечКарта, Мерсибо
-- Логомер, западные EMR с ICD-10): у всех заключение структурировано и
-- берётся из справочника, у нас — свободный текст diagnostics.conclusion,
-- по которому нельзя ни отфильтровать учеников, ни посчитать структуру
-- центра по нозологии. Это фаза 1 из трёх: только справочники. Фаза 2
-- (подсказка заключения из шкал speech_areas) ждёт решения владельца о
-- порогах; фаза 3 (полная речевая карта) — отдельный этап.
--
-- Ревью плана архитектором (18 находок), решения:
--
--   Р1. Три ГЛОБАЛЬНЫХ справочника (как funnel_stages, 0055; не центровые,
--       как goal_stages, 0036): нозология стандартная (по Левиной), центр
--       её не изобретает; per-center потребовал бы seed-триггер, backfill
--       и политики — и не дал бы платформе сводимых кодов. В отличие от
--       funnel_stages — с is_active: вывести код из оборота (если zrr
--       окажется лишним) иначе нельзя, FK держит строки.
--   Р2. Формы и направления — junction-таблицы по образцу
--       homework_exercises (0036): суррогатный id, deleted_at, частичный
--       unique where deleted_at is null. Не text[] с триггером: у
--       направления есть note, в массив не ложится; снятая форма в массиве
--       исчезает без следа, а junction с deleted_at даёт историю правок
--       заключения — ради неё фаза 1 и затевается. Hard delete не
--       выдаётся никому («ничего не удаляется»).
--   Р3. Видимость junction — своя definer-функция
--       clinical_diagnostic_visible(uuid), повторяющая круг самой
--       diagnostics (owner/admin, teacher через clinical_teacher_sees), с
--       явной проверкой роли внутри. Не через clinical_visible_to_caller:
--       та включает parent (0036), и родитель прочитал бы note
--       «подозрение на РАС, направлена к психиатру» прямым запросом.
--   Р4. Родителю — только conclusion_name (психолого-педагогическая
--       формулировка, которую и так произносят на консультации) плюс
--       свободный conclusion. Клинические формы («сенсорная алалия») и
--       направления к психиатру — того же класса, что sounds/speech_areas
--       (ADR-005, 0036 Р4): не витриной. Маршрут «к сурдологу» родителю
--       нужен, но как сознательный акт логопеда — в conclusion или
--       отдельным событием позже.
--   Р5. student_diagnostics_brief меняет набор колонок → drop function,
--       не create or replace (иначе «cannot change return type»); drop
--       снимает гранты — revoke/grant повторены.
--   Р6. unique (id, center_id) на diagnostics нет (0008/0022/0036 её не
--       заводили; у lesson_notes появилась отдельным alter в 0042) —
--       без неё составной FK junction не создаётся. Первым разделом.
--   Р7. update_diagnostic — select … for update по строке diagnostics
--       (приём transfer_remaining, 0055): delete+insert двух сессий без
--       замка складывают два заключения в одно. Столкновение с частичным
--       unique — 22023 «изменили параллельно», без автоповтора.
--   Р8. Дедуп массива форм и форма jsonb направлений — в SQL
--       (unnest … distinct, jsonb_typeof), unknown код — 22023 с русским
--       текстом до FK; note ≤ 500 — check-констрейнт, как
--       funnel_events.cause (0055).
--   Р9. Переиздание readonly_guard_exempt_tables — от редакции 0055,
--       export_center_tables — от 0057 (последние по grep, не по памяти).
--       Справочники — в export_center_lookups(): junction выгрузит код
--       'alalia_motor', а справочник без center_id забор экспорта не видит
--       — файл без расшифровки нечитаем вне нашей базы (0056, находка 11).
--   Р10. Фильтр «все с ОНР III» в списке учеников — только через RPC
--       student_conclusions(): diagnostics закрыта registrar/finance и
--       ограничена clinical_teacher_sees для teacher, PostgREST-embed
--       отдал бы им пустой массив без ошибки, и фильтр в браузере считал
--       бы по неполным данным. students_brief() не расширяется: её
--       потребители — finance и registrar (0031 Р2).
--   Р11. null в conclusion_code — два смысла («старая запись» и «пока не
--       определено»), «речь в норме» — код norm. Не чиним: comment on
--       column, а будущий отчёт по нозологии обязан показывать «не
--       заполнено» отдельной строкой (урок student_balance.lessons_left).
--   Р12. Фаза 2 кладёт предложение системы В ОТДЕЛЬНУЮ таблицу, а не в
--       diagnostics.conclusion_code — иначе автоподстановка затрёт код,
--       поставленный человеком (прецедент lesson_note_goal_scores, 0042).
--       Записано здесь, чтобы фаза 2 не пришла с «одной колонкой».
--   Р13. Новые параметры RPC — только в конец: позиционные вызовы
--       record_diagnostic('…', 'ОНР II уровня') живут в тестах 0038.
--
-- Ревью написанного SQL (8 находок), решения:
--
--   Р14. Видимость junction — RESTRICTIVE-политика через
--       clinical_diagnostic_visible поверх permissive tenant_admin/
--       teacher_read: permissive складываются по ИЛИ, и для owner/admin
--       tenant_admin (свой deleted_at) полностью перекрывал проверку
--       «жива ли диагностика». Каскад deleted_at в archive_diagnostic
--       остаётся гигиеной, но не единственной опорой — иначе первая же
--       миграция, гасящая diagnostics другим путём, показала бы владельцу
--       направления «подозрение на РАС» к карточке, которой на экране нет.
--   Р15. Замок for update по строке diagnostics ДОСТАТОЧЕН для junction:
--       update_diagnostic берёт его явно, archive_diagnostic делает update
--       той же строки (встаёт в ту же очередь), record_diagnostic пишет в
--       только что вставленный id, никому ещё не видимый. Отдельный замок
--       на junction добавил бы порядок блокировок, которого нет. Гонка на
--       частичном unique гасится `on conflict … do nothing` (no-op, не
--       ошибка) — перехват unique_violation на всю функцию снят: он
--       перевёл бы чужой 23505 будущей правки в «изменили параллельно»,
--       предписывая действие, которое не помогает.
--   Р16. Снять conclusion_code можно: сентинел '' → NULL (как '{}' у форм);
--       null по-прежнему «не трогать». Иначе промах селектом чинился бы
--       только архивом всей диагностики вместе со звуками и шкалами.
--   Р17. student_conclusions() — последнее ПОСТАВЛЕННОЕ заключение
--       (where conclusion_code is not null внутри distinct on): новая
--       диагностика без кода не стирает прошлый диагноз из фильтра.
--       Следствие: «—» в списке значит «заключение не ставилось», а не
--       «диагностики нет» — различать их будет отчёт по нозологии по
--       самой diagnostics (Р11), не этот RPC.
--   Р18. update_diagnostic пускает автора (created_by) без повторной
--       clinical_teacher_sees — асимметрия унаследована от 0038 и здесь
--       осознанно распространена на код/формы/направления: специалист,
--       у которого ребёнка забрали, исправляет СВОЮ запись; переписать
--       чужую он не может.
-- =============================================================================


-- 1. unique (id, center_id) на diagnostics (Р6) ----------------------------------------------------

alter table public.diagnostics
  add constraint diagnostics_id_center_key unique (id, center_id);


-- 2. Справочники (Р1) ----------------------------------------------------------------------------

create table if not exists public.speech_conclusions (
  code      text primary key,
  name      text not null,
  sort      integer not null,
  is_active boolean not null default true
);

comment on table public.speech_conclusions is
  'Психолого-педагогическая классификация (по Левиной): норма, ФНР, ФФНР, ОНР I–IV, ЗРР. Глобальный справочник платформы (0059 Р1), пишет только миграция; is_active — вывести код из оборота, не удаляя строки, на которые он ссылается.';

alter table public.speech_conclusions enable row level security;
drop policy if exists speech_conclusions_select on public.speech_conclusions;
create policy speech_conclusions_select on public.speech_conclusions
  for select to authenticated using (true);
revoke all on table public.speech_conclusions from public, anon, authenticated;
grant select on public.speech_conclusions to authenticated;

insert into public.speech_conclusions (code, name, sort) values
  ('norm',  'Речь в норме',                                        0),
  ('fnr',   'ФНР — фонетическое недоразвитие речи',               10),
  ('ffnr',  'ФФНР — фонетико-фонематическое недоразвитие речи',   20),
  ('onr_1', 'ОНР I уровня',                                       30),
  ('onr_2', 'ОНР II уровня',                                      40),
  ('onr_3', 'ОНР III уровня',                                     50),
  ('onr_4', 'ОНР IV уровня',                                      60),
  ('zrr',   'ЗРР — задержка речевого развития',                   70)
on conflict (code) do nothing;


create table if not exists public.clinical_forms (
  code      text primary key,
  name      text not null,
  sort      integer not null,
  is_active boolean not null default true
);

comment on table public.clinical_forms is
  'Клинико-педагогическая классификация: форма/механизм нарушения. У ребёнка бывает несколько разом («ОНР III + стёртая дизартрия + заикание») — связка diagnostic_clinical_forms. Глобальный справочник (0059 Р1).';

alter table public.clinical_forms enable row level security;
drop policy if exists clinical_forms_select on public.clinical_forms;
create policy clinical_forms_select on public.clinical_forms
  for select to authenticated using (true);
revoke all on table public.clinical_forms from public, anon, authenticated;
grant select on public.clinical_forms to authenticated;

insert into public.clinical_forms (code, name, sort) values
  ('dyslalia',          'Дислалия',            10),
  ('dysarthria_erased', 'Стёртая дизартрия',   20),
  ('dysarthria',        'Дизартрия',           30),
  ('rhinolalia',        'Ринолалия',           40),
  ('stuttering',        'Заикание',            50),
  ('alalia_motor',      'Моторная алалия',     60),
  ('alalia_sensory',    'Сенсорная алалия',    70),
  ('dysgraphia',        'Дисграфия',           80),
  ('dyslexia',          'Дислексия',           90),
  ('tachylalia',        'Тахилалия',          100),
  ('bradylalia',        'Брадилалия',         110),
  ('dysphonia',         'Дисфония',           120)
on conflict (code) do nothing;


create table if not exists public.referral_targets (
  code      text primary key,
  name      text not null,
  sort      integer not null,
  is_active boolean not null default true
);

comment on table public.referral_targets is
  '«Направлен к…»: ответ на кейс «ребёнок не отзывается на имя» — это не диагноз логопеда, а маршрут на дообследование (слух/РАС/сенсорная алалия). Глобальный справочник (0059 Р1).';

alter table public.referral_targets enable row level security;
drop policy if exists referral_targets_select on public.referral_targets;
create policy referral_targets_select on public.referral_targets
  for select to authenticated using (true);
revoke all on table public.referral_targets from public, anon, authenticated;
grant select on public.referral_targets to authenticated;

insert into public.referral_targets (code, name, sort) values
  ('audiologist',  'Сурдолог',  10),
  ('neurologist',  'Невролог',  20),
  ('psychiatrist', 'Психиатр',  30),
  ('ent',          'ЛОР',       40),
  ('psychologist', 'Психолог',  50)
on conflict (code) do nothing;


-- 3. diagnostics.conclusion_code (Р11) -----------------------------------------------------------

alter table public.diagnostics
  add column if not exists conclusion_code text references public.speech_conclusions (code);

comment on column public.diagnostics.conclusion_code is
  'Заключение из справочника speech_conclusions (0059). NULL имеет ДВА смысла — «запись старше 0059» и «пока не определено»; «речь в норме» — код norm, не NULL. Отчёт по нозологии обязан показывать NULL отдельной строкой «не заполнено», а не складывать с остальными (0059 Р11). Фаза 2 (подсказка из speech_areas) пишет в отдельную таблицу, не сюда (Р12).';

create index if not exists diagnostics_conclusion_idx
  on public.diagnostics (center_id, conclusion_code) where deleted_at is null;


-- 4. Видимость: clinical_diagnostic_visible (Р3) -------------------------------------------------

-- Объявлена рядом с diagnostics, которую читает (правило CLAUDE.md о
-- политиках через definer-функцию). Круг — ровно как у самой diagnostics:
-- owner/admin центра, teacher через clinical_teacher_sees. Родителя, стойки и
-- бухгалтера здесь нет намеренно (Р3, Р4).
create or replace function public.clinical_diagnostic_visible(p_diagnostic_id uuid)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_role    text := coalesce(public.my_role(), '');
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

  if v_role in ('owner', 'admin') then
    return true;
  end if;
  if v_role = 'teacher' then
    return public.clinical_teacher_sees(v_student);
  end if;
  return false;
end;
$$;

comment on function public.clinical_diagnostic_visible(uuid) is
  'Кому видны формы и направления диагностики (0059 Р3): owner/admin, teacher — через clinical_teacher_sees. Parent/registrar/finance — false: clinical_visible_to_caller здесь не годится, она включает родителя.';

revoke all on function public.clinical_diagnostic_visible(uuid) from public, anon, service_role;
grant execute on function public.clinical_diagnostic_visible(uuid) to authenticated;


-- 5. Junction-таблицы (Р2) ------------------------------------------------------------------------

create table if not exists public.diagnostic_clinical_forms (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center(),
  diagnostic_id uuid not null,
  form_code     text not null references public.clinical_forms (code),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz,

  constraint diagnostic_clinical_forms_diagnostic_fk
    foreign key (diagnostic_id, center_id) references public.diagnostics (id, center_id) on delete cascade
);

comment on table public.diagnostic_clinical_forms is
  'Клинические формы заключения (0059 Р2). Снятая форма гасится deleted_at, не удаляется — история правок заключения. Запись только через record_diagnostic/update_diagnostic.';

create unique index if not exists diagnostic_clinical_forms_pair_key
  on public.diagnostic_clinical_forms (diagnostic_id, form_code) where deleted_at is null;
create index if not exists diagnostic_clinical_forms_center_idx
  on public.diagnostic_clinical_forms (center_id, form_code) where deleted_at is null;

drop trigger if exists diagnostic_clinical_forms_set_updated_at on public.diagnostic_clinical_forms;
create trigger diagnostic_clinical_forms_set_updated_at
  before update on public.diagnostic_clinical_forms
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('diagnostic_clinical_forms');
call public.apply_audit('diagnostic_clinical_forms');
call public.apply_readonly_guard('diagnostic_clinical_forms');

drop policy if exists diagnostic_clinical_forms_teacher_read on public.diagnostic_clinical_forms;
create policy diagnostic_clinical_forms_teacher_read on public.diagnostic_clinical_forms
  for select to authenticated
  using (center_id = public.current_center() and deleted_at is null and public.clinical_diagnostic_visible(diagnostic_id));

-- Р14: restrictive — «диагностика жива и видна вызывающему» обязательно для
-- ВСЕХ читателей, включая owner/admin через tenant_admin.
drop policy if exists diagnostic_clinical_forms_visible on public.diagnostic_clinical_forms;
create policy diagnostic_clinical_forms_visible on public.diagnostic_clinical_forms
  as restrictive for select to authenticated
  using (public.clinical_diagnostic_visible(diagnostic_id));

-- tenant_admin от apply_tenant_rls — for all, но без гранта на запись это
-- ничего не открывает: подача, правка, гашение — только RPC (0038 сделала
-- то же для шести клинических таблиц).
revoke all on table public.diagnostic_clinical_forms from public, anon, authenticated;
grant select on public.diagnostic_clinical_forms to authenticated;


create table if not exists public.diagnostic_referrals (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center(),
  diagnostic_id uuid not null,
  target_code   text not null references public.referral_targets (code),
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz,

  constraint diagnostic_referrals_diagnostic_fk
    foreign key (diagnostic_id, center_id) references public.diagnostics (id, center_id) on delete cascade,
  constraint diagnostic_referrals_note_len check (note is null or length(note) <= 500)
);

comment on table public.diagnostic_referrals is
  'Направления на дообследование (0059 Р2): к кому и с какой заметкой. Родителю не видна (Р4) — note вроде «подозрение на РАС» логопед сообщает сам. Запись только через RPC.';

create unique index if not exists diagnostic_referrals_pair_key
  on public.diagnostic_referrals (diagnostic_id, target_code) where deleted_at is null;
create index if not exists diagnostic_referrals_center_idx
  on public.diagnostic_referrals (center_id, target_code) where deleted_at is null;

drop trigger if exists diagnostic_referrals_set_updated_at on public.diagnostic_referrals;
create trigger diagnostic_referrals_set_updated_at
  before update on public.diagnostic_referrals
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('diagnostic_referrals');
call public.apply_audit('diagnostic_referrals');
call public.apply_readonly_guard('diagnostic_referrals');

drop policy if exists diagnostic_referrals_teacher_read on public.diagnostic_referrals;
create policy diagnostic_referrals_teacher_read on public.diagnostic_referrals
  for select to authenticated
  using (center_id = public.current_center() and deleted_at is null and public.clinical_diagnostic_visible(diagnostic_id));

drop policy if exists diagnostic_referrals_visible on public.diagnostic_referrals;
create policy diagnostic_referrals_visible on public.diagnostic_referrals
  as restrictive for select to authenticated
  using (public.clinical_diagnostic_visible(diagnostic_id));

revoke all on table public.diagnostic_referrals from public, anon, authenticated;
grant select on public.diagnostic_referrals to authenticated;


-- 6. Запись форм и направлений — одна внутренняя функция (Р7, Р8) --------------------------------

-- Без грантов никому: зовётся только из record_diagnostic/update_diagnostic,
-- которые уже проверили права и (в update) взяли замок строки diagnostics.
-- null = «не передано, не трогать»; '{}'/'[]' = «очистить». Живые строки,
-- которых нет в новом наборе, гасятся; отсутствующие — вставляются; уже
-- живые остаются как есть (идемпотентно, без churn в audit_log).
create or replace function public.diagnostic_set_details(
  p_diagnostic_id uuid,
  p_center_id     uuid,
  p_forms         text[],
  p_referrals     jsonb
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_forms   text[];
  v_bad     text;
  v_item    jsonb;
  v_target  text;
  v_note    text;
  v_targets text[] := '{}';
begin
  if p_forms is not null then
    select coalesce(array_agg(distinct f), '{}') into v_forms
      from unnest(p_forms) f where f is not null and f <> '';

    select f into v_bad from unnest(v_forms) f
     where not exists (select 1 from public.clinical_forms c where c.code = f and c.is_active)
     limit 1;
    if v_bad is not null then
      raise exception 'Неизвестная клиническая форма: %', v_bad using errcode = '22023';
    end if;

    update public.diagnostic_clinical_forms
       set deleted_at = now()
     where diagnostic_id = p_diagnostic_id and center_id = p_center_id
       and deleted_at is null and form_code <> all (v_forms);

    -- Р15: гонка двух сессий на частичном unique — no-op, не ошибка.
    insert into public.diagnostic_clinical_forms (center_id, diagnostic_id, form_code)
    select p_center_id, p_diagnostic_id, f
      from unnest(v_forms) f
     where not exists (
       select 1 from public.diagnostic_clinical_forms x
        where x.diagnostic_id = p_diagnostic_id and x.form_code = f and x.deleted_at is null)
    on conflict (diagnostic_id, form_code) where deleted_at is null do nothing;
  end if;

  if p_referrals is not null then
    if jsonb_typeof(p_referrals) <> 'array' then
      raise exception 'Направления: ожидается список' using errcode = '22023';
    end if;

    for v_item in select value from jsonb_array_elements(p_referrals) loop
      if jsonb_typeof(v_item) <> 'object' or jsonb_typeof(v_item -> 'target') <> 'string' then
        raise exception 'Направление: ожидается объект с полем target' using errcode = '22023';
      end if;
      v_target := v_item ->> 'target';
      v_note   := nullif(trim(coalesce(v_item ->> 'note', '')), '');

      if not exists (select 1 from public.referral_targets r where r.code = v_target and r.is_active) then
        raise exception 'Неизвестный специалист для направления: %', v_target using errcode = '22023';
      end if;
      if v_target = any (v_targets) then
        continue;
      end if;
      v_targets := v_targets || v_target;

      update public.diagnostic_referrals
         set note = v_note
       where diagnostic_id = p_diagnostic_id and center_id = p_center_id
         and target_code = v_target and deleted_at is null
         and note is distinct from v_note;

      insert into public.diagnostic_referrals (center_id, diagnostic_id, target_code, note)
      select p_center_id, p_diagnostic_id, v_target, v_note
       where not exists (
         select 1 from public.diagnostic_referrals x
          where x.diagnostic_id = p_diagnostic_id and x.target_code = v_target and x.deleted_at is null)
      on conflict (diagnostic_id, target_code) where deleted_at is null do nothing;
    end loop;

    update public.diagnostic_referrals
       set deleted_at = now()
     where diagnostic_id = p_diagnostic_id and center_id = p_center_id
       and deleted_at is null and target_code <> all (v_targets);
  end if;
end;
$$;

revoke all on function public.diagnostic_set_details(uuid, uuid, text[], jsonb) from public, anon, authenticated, service_role;


-- 7. record_diagnostic / update_diagnostic — новые сигнатуры (Р13) --------------------------------

-- Старые сигнатуры дропаются явно (как 0055 для create_student_with_payer):
-- две перегрузки с общим префиксом дали бы PostgREST «could not choose the
-- best candidate function» на любом вызове без новых параметров.
drop function if exists public.record_diagnostic(uuid, text, jsonb, jsonb, date, uuid);
drop function if exists public.update_diagnostic(uuid, text, jsonb, jsonb, date);

create or replace function public.record_diagnostic(
  p_student_id      uuid,
  p_conclusion      text default null,
  p_sounds          jsonb default '{}'::jsonb,
  p_speech_areas    jsonb default '{}'::jsonb,
  p_date            date default null,
  p_teacher_id      uuid default null,
  p_conclusion_code text default null,
  p_clinical_forms  text[] default null,
  p_referrals       jsonb default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center     uuid := public.current_center();
  v_role       text := coalesce(public.my_role(), '');
  v_teacher_id uuid;
  v_id         uuid;
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

  -- 0038 Р5: та же граница, что и раньше — clinical_teacher_sees не меняется.
  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(p_student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_role = 'teacher' then
    v_teacher_id := public.my_teacher_id();
  elsif p_teacher_id is not null then
    if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.center_id = v_center) then
      raise exception 'Специалист не найден' using errcode = '42704';
    end if;
    v_teacher_id := p_teacher_id;
  end if;

  if p_conclusion_code is not null and not exists (
    select 1 from public.speech_conclusions c where c.code = p_conclusion_code and c.is_active
  ) then
    raise exception 'Неизвестное заключение: %', p_conclusion_code using errcode = '22023';
  end if;

  insert into public.diagnostics (center_id, student_id, teacher_id, date, conclusion, sounds, speech_areas, conclusion_code)
  values (v_center, p_student_id, v_teacher_id, coalesce(p_date, public.center_today(v_center)),
          p_conclusion, coalesce(p_sounds, '{}'::jsonb), coalesce(p_speech_areas, '{}'::jsonb), p_conclusion_code)
  returning id into v_id;

  perform public.diagnostic_set_details(v_id, v_center, p_clinical_forms, p_referrals);

  perform public.emit_event('diagnostic.created',
    jsonb_build_object('center_id', v_center, 'diagnostic_id', v_id, 'student_id', p_student_id), v_center);

  return v_id;
end;
$$;

revoke all on function public.record_diagnostic(uuid, text, jsonb, jsonb, date, uuid, text, text[], jsonb) from public, anon, authenticated, service_role;
grant execute on function public.record_diagnostic(uuid, text, jsonb, jsonb, date, uuid, text, text[], jsonb) to authenticated;


create or replace function public.update_diagnostic(
  p_id              uuid,
  p_conclusion      text default null,
  p_sounds          jsonb default null,
  p_speech_areas    jsonb default null,
  p_date            date default null,
  p_conclusion_code text default null,
  p_clinical_forms  text[] default null,
  p_referrals       jsonb default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.diagnostics;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  -- Р7: замок строки до любой записи в junction — иначе две сессии гасят и
  -- вставляют формы вперемешку, и в карточке остаётся объединение.
  select * into v_row from public.diagnostics
   where id = p_id and center_id = v_center and deleted_at is null
   for update;
  if not found then
    raise exception 'Запись не найдена' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or v_row.created_by = auth.uid()) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р16: '' — снять код; null — не трогать; иначе — проверить по справочнику.
  if p_conclusion_code is not null and p_conclusion_code <> '' and not exists (
    select 1 from public.speech_conclusions c where c.code = p_conclusion_code and c.is_active
  ) then
    raise exception 'Неизвестное заключение: %', p_conclusion_code using errcode = '22023';
  end if;

  update public.diagnostics
     set conclusion      = coalesce(p_conclusion, conclusion),
         sounds          = coalesce(p_sounds, sounds),
         speech_areas    = coalesce(p_speech_areas, speech_areas),
         date            = coalesce(p_date, date),
         conclusion_code = case
                             when p_conclusion_code = '' then null
                             else coalesce(p_conclusion_code, conclusion_code)
                           end
   where id = p_id;

  perform public.diagnostic_set_details(p_id, v_center, p_clinical_forms, p_referrals);
end;
$$;

revoke all on function public.update_diagnostic(uuid, text, jsonb, jsonb, date, text, text[], jsonb) from public, anon, authenticated, service_role;
grant execute on function public.update_diagnostic(uuid, text, jsonb, jsonb, date, text, text[], jsonb) to authenticated;


-- archive_diagnostic — гасит и связки: tenant_admin на junction фильтрует по
-- СВОЕМУ deleted_at, и без каскада owner видел бы формы архивной
-- диагностики, которую сама diagnostics уже спрятала. Строки остаются.
create or replace function public.archive_diagnostic(p_id uuid)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_found  boolean;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.diagnostics set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;
  v_found := found;

  if v_found then
    update public.diagnostic_clinical_forms set deleted_at = now()
     where diagnostic_id = p_id and center_id = v_center and deleted_at is null;
    update public.diagnostic_referrals set deleted_at = now()
     where diagnostic_id = p_id and center_id = v_center and deleted_at is null;
  end if;

  return v_found;
end;
$$;

revoke all on function public.archive_diagnostic(uuid) from public, anon, authenticated, service_role;
grant execute on function public.archive_diagnostic(uuid) to authenticated;


-- 8. student_diagnostics_brief — плюс conclusion_name (Р4, Р5) ------------------------------------

drop function if exists public.student_diagnostics_brief(uuid);

create or replace function public.student_diagnostics_brief(p_student_id uuid)
  returns table (id uuid, date date, conclusion text, teacher_name text, conclusion_name text)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if not public.clinical_visible_to_caller(p_student_id) then
    return;
  end if;

  return query
    select d.id, d.date, d.conclusion, t.full_name, c.name
      from public.diagnostics d
      left join public.teachers t on t.id = d.teacher_id
      left join public.speech_conclusions c on c.code = d.conclusion_code
     where d.student_id = p_student_id
       and d.center_id = public.current_center()
       and d.deleted_at is null
     order by d.date desc;
end;
$$;

comment on function public.student_diagnostics_brief(uuid) is
  'Диагностика для родителя (0036 Р4): без sounds/speech_areas. 0059: плюс conclusion_name — формулировка из справочника; клинические формы и направления сюда не попадают (Р4).';

revoke all on function public.student_diagnostics_brief(uuid) from public, anon;
grant execute on function public.student_diagnostics_brief(uuid) to authenticated;


-- 9. student_conclusions — последнее заключение по ученикам (Р10) ---------------------------------

create or replace function public.student_conclusions()
  returns table (student_id uuid, conclusion_code text, conclusion_name text, date date)
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
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin', 'teacher') then
    return;
  end if;

  return query
    select l.student_id, l.conclusion_code, c.name, l.date
      from (
        -- Р17: последнее ПОСТАВЛЕННОЕ заключение — фильтр по коду ВНУТРИ
      -- distinct on, иначе новая диагностика без кода стирала бы прошлый
      -- диагноз из списка.
      select distinct on (d.student_id) d.student_id, d.conclusion_code, d.date
          from public.diagnostics d
         where d.center_id = v_center and d.deleted_at is null and d.conclusion_code is not null
         order by d.student_id, d.date desc, d.created_at desc
      ) l
      join public.speech_conclusions c on c.code = l.conclusion_code
     where v_role in ('owner', 'admin') or public.clinical_teacher_sees(l.student_id);
end;
$$;

comment on function public.student_conclusions() is
  'Последнее ПОСТАВЛЕННОЕ заключение каждого ученика (0059 Р10/Р17) — для бейджа и фильтра в списке учеников; ученик без единого кода в выдаче отсутствует — «—» значит «не ставилось», не «диагностики нет». Роль проверяется здесь, не в браузере; registrar/finance/parent — пусто.';

revoke all on function public.student_conclusions() from public, anon, service_role;
grant execute on function public.student_conclusions() to authenticated;


-- 10. Заборы: readonly_guard_exempt_tables (от 0055), export_center_tables (от 0057) (Р9) ----------

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
    ('salary_adjustments'), ('salary_runs'), ('services'), ('student_payers'),
    ('students'), ('subscription_freezes'), ('subscription_types'), ('subscriptions'),
    ('teacher_rates'), ('teachers')
$$;

comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals — клинические данные ребёнка. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;


-- Справочники в выгрузку (Р9): junction выгружает коды, расшифровка — здесь,
-- иначе файл нечитаем вне нашей базы (0056, находка 11).
create or replace function public.export_center_lookups()
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is null or public.current_center() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'speech_conclusions', (select coalesce(jsonb_agg(to_jsonb(s) order by s.sort), '[]'::jsonb) from public.speech_conclusions s),
    'clinical_forms',     (select coalesce(jsonb_agg(to_jsonb(f) order by f.sort), '[]'::jsonb) from public.clinical_forms f),
    'referral_targets',   (select coalesce(jsonb_agg(to_jsonb(r) order by r.sort), '[]'::jsonb) from public.referral_targets r),
    'funnel_stages',      (select coalesce(jsonb_agg(to_jsonb(g) order by g.sort), '[]'::jsonb) from public.funnel_stages g)
  );
end;
$$;

comment on function public.export_center_lookups() is
  'Глобальные справочники для выгрузки центра (0059 Р9): у них нет center_id, забор экспорта их не видит, а без них коды в junction-таблицах нечитаемы. funnel_stages сюда же — тот же класс (0055).';

revoke all on function public.export_center_lookups() from public, anon, service_role;
grant execute on function public.export_center_lookups() to authenticated;
