-- =============================================================================
-- 0066_syllable_assessments.sql — слоговая структура: третий раздел речевой карты
--
-- Фаза 3.3. В отличие от анамнеза (0063) и артикуляционного аппарата
-- (0065) — профилей, одна строка на ребёнка, — слоговая структура это
-- ТЕСТ на словах нарастающей сложности (по Марковой — 14 классов), и его
-- пересдают, чтобы отследить прогресс. Владелец подтвердил явно: ИСТОРИЯ,
-- как diagnostics (новая запись на каждое обследование, архивация, не
-- правка на месте) — не профиль. Таблица НЕ названа с префиксом
-- student_: история в проекте всегда носит голое имя (diagnostics, goals,
-- homework, lessons, attendance) — syllable_assessments держит эту
-- конвенцию (обратное — «student_* всегда 1:1 профиль» — не универсально:
-- student_payers, например, связка M:N, не профиль; правило одностороннее).
--
-- Ревью плана архитектором, решения:
--
--   Р1. Смоделировано на diagnostics (record_/update_/archive_diagnostic,
--       0059), не на student_anamnesis/student_articulation — та же связка
--       RPC, тот же класс таблицы. НО без слепого копирования: у самой
--       diagnostics/update_diagnostic нашлась непроверенная дыра (Р2/Р3
--       ниже) — её не наследуем, закрываем здесь.
--   Р2. created_by = auth.uid() в проверке прав ОБЯЗАНО быть тотальным
--       булевым — coalesce(..., false), привязанным к роли teacher. Голое
--       сравнение (как в живом update_diagnostic) при created_by is null
--       (сид, восстановление из экспорта, ручная правка) даёт SQL NULL,
--       «if not (... or NULL)» в plpgsql пропускает raise молча — тот же
--       блокер, что 0065 Р8, теперь пойман до написания, а не после.
--       Правку самого update_diagnostic это не трогает — отдельная тема.
--   Р3. Круг доступа СИММЕТРИЧЕН всем трём разделам речевой карты на одной
--       карточке: clinical_teacher_sees ИЛИ student_primary_teacher(0065)
--       ИЛИ авторство — и на чтение, и на запись (не только «первое
--       заполнение», урок 0065 Р9). Без этого один экран вёл бы себя
--       по-разному в трёх соседних карточках: специалист без занятия
--       заполняет анамнез и артикуляцию, но получает 42501 на слоговой
--       структуре — необъяснимая для пользователя разница.
--   Р4. Восстановленная дыра diagnostics: update_diagnostic пускает автора
--       без проверки, жив ли ещё ребёнок (занятие отменили, ученик
--       архивирован — правка проходит, потому что ветка created_by ничего
--       не проверяет, кроме себя). Здесь ветка teacher в update_* держит
--       student_alive(v_row.student_id) явно.
--   Р5. Restrictive-политика — точная копия образца 0063/0065:
--       student_alive для ВСЕХ, включая owner/admin, без исключений.
--       Первая версия этой находки пыталась исключить owner/admin,
--       рассуждая, что архивация ребёнка иначе стёрла бы историю с экрана
--       владельца — рассуждение отклонено на ревью написанного SQL:
--       students.deleted_at нигде в приложении не выставляется
--       (archive_student пишет status, не deleted_at), сценарий не
--       наступает уже сегодня, а исключение снимало реальный слой защиты
--       без всякой компенсации.
--   Р6. affected_classes/error_types — NOT NULL DEFAULT '{}', не nullable:
--       иначе null («раздел не заполняли») и '{}' («обследован, нарушений
--       нет») неразличимы на экране — тот же урок, что
--       student_balance.lessons_left. Пустой массив в апдейте — валидная
--       замена (улучшение, все классы освоены), не «не трогать»: null в
--       параметре — «не трогать» (coalesce), непустой/пустой массив —
--       значение целиком, замена, не слияние (повторный тест — новый
--       список целиком, не патч к старому).
--   Р7. date — та же граница (2000-01-01 .. завтра), что в 0063/0065:
--       забор от опечатки в годе. Здесь дороже, чем в профиле — порядок
--       строк в истории и есть смысл таблицы (`order by date desc`).
--   Р8. cardinality(affected_classes) <= 14, cardinality(error_types) <= 8
--       — <@ проверяет только принадлежность элементов множеству, не
--       мощность: без верхней границы массив можно раздуть сколь угодно.
--       Дедуп/сортировку не констрейнтить (подзапрос в CHECK запрещён) —
--       нормализация в RPC, если понадобится, не инвариант доступа.
--   Р9. affected_classes и error_types — ДВА НЕЗАВИСИМЫХ массива, не
--       связка (assessment_id, class, error_type). Решение владельца
--       24.09.2026: проще и быстрее для первой версии, соответствует
--       тому, как это обычно пишут в бумажной речевой карте («нарушены
--       классы 5, 7, 9; преобладающие ошибки: пропуск слога, упрощение
--       стечений») — без привязки, какая ошибка на каком классе. Если
--       понадобится точная связка — отдельная миграция с переносом
--       данных (здесь уже НЕ пустая база, в отличие от решения о переносе
--       из старого MVP 9.09.2026).
--   Р10. p_expected_updated_at + select for update — как 0063/0065, не
--        как diagnostics (там его нет). Тот же экран держит три раздела с
--        одинаковым поведением на конфликт параллельной правки.
--   Р11. Гранты — только select (запись через RPC), НЕ select+insert+update,
--        как у diagnostics (0036) — сознательное отличие, не недосмотр:
--        у diagnostics нет собственных инвариантов на insert мимо функции
--        только потому, что исторически так сложилось, а не потому что
--        это правильно; здесь сразу закрыто, как во всех разделах карты.
--   Р12. Родителю не видно ничего в этом раунде — тот же класс данных, что
--        ADR-005 (sounds/speech_areas, анамнез, артикуляция). Если решат
--        показывать заключение — ТОЛЬКО через отдельную definer-функцию
--        (как student_diagnostics_brief), никогда не политикой: RLS не
--        различает колонки, а affected_classes/error_types — рабочий
--        материал специалиста, не для родителя, даже если conclusion
--        когда-нибудь станет виден.
--
-- Ревью написанного SQL (после Р1–Р12), решения:
--
--   Р13. Р5 пересмотрен — см. текст решения на месте политики ниже:
--        исключение owner/admin из student_alive снято, восстановлен
--        точный образец 0063/0065. Заодно вооружён тестом: без него
--        забор можно удалить целиком, и CI останется зелёным — находка
--        того же ревью, что и сам пересмотр.
--   Р14. record_ требует хотя бы одно содержательное поле (22023) — пустой
--        вызов иначе создавал бы запись, неотличимую на экране от
--        «обследован, нарушений нет».
--   Р15. affected_classes/error_types — дедуп и сортировка (числовая для
--        классов, не лексикографическая — иначе '10' встаёт раньше '2')
--        перед каждой записью, и в record_, и в update_ (только когда
--        параметр передан — иначе нормализовать нечего, оставляем
--        уже нормализованное значение строки). <@ проверяет только
--        принадлежность, cardinality — только верхнюю границу; ни то, ни
--        другое не ловит дубли, и без дедупа cardinality-кап работает как
--        лимит на число повторов одного кода, а не на число находок.
--   Р16. conclusion получил тот же сентинел, что conclusion_code в 0059
--        Р16: '' снимает, null не трогает. Без этого стереть ошибочно
--        введённый текст было бы нечем — то же по духу, что Р6 для
--        массивов, только текстовое поле его не унаследовало в первой
--        версии.
--   Р17. Дубль обследования за один день (двойной клик на «Сохранить» без
--        оптимистичного UI) НЕ ограничен UNIQUE(student_id, date) —
--        сознательно отложено: клинически возможны два обследования в
--        один день (утро/вечер, до и после занятия), а форма и так не
--        даёт повторно нажать раньше ответа сервера. Если станет реальной
--        проблемой — отдельное решение с собственной миграцией и текстом
--        в CHECK_MESSAGES/UNIQUE_MESSAGES.
-- =============================================================================

create table if not exists public.syllable_assessments (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  student_id    uuid not null,
  teacher_id    uuid,
  date          date not null default public.center_today(public.current_center())
    constraint syllable_assessments_date_check
    check (date between date '2000-01-01' and current_date + 1),

  -- 14 классов слоговой структуры по А.К. Марковой (от простого к сложному):
  -- 1 — двусложные из открытых слогов («дети»); 2 — трёхсложные из
  -- открытых слогов («машина»); 3 — односложные закрытого типа («дом»);
  -- 4 — двусложные с одним закрытым слогом («диван»); 5 — двусложные со
  -- стечением согласных в середине слова («банка»); 6 — двусложные с
  -- закрытым слогом и стечением согласных («компот»); 7 — трёхсложные с
  -- закрытым слогом («бегемот»); 8 — трёхсложные со стечением согласных
  -- («комната»); 9 — трёхсложные со стечением и закрытым слогом
  -- («аквариум»); 10 — трёхсложные с двумя стечениями («таблетка»);
  -- 11 — односложные со стечением в начале/конце («стол», «тигр»);
  -- 12 — двусложные с двумя стечениями («кнопка»); 13 — четырёхсложные из
  -- открытых слогов («черепаха»); 14 — многосложные слова из сложных
  -- элементов («велосипедист»). Р9: без привязки к error_types — какой
  -- класс дал какую ошибку, записью не восстановить, решение владельца.
  affected_classes text[] not null default '{}'
    constraint syllable_assessments_affected_classes_check
    check (
      affected_classes <@ array['1','2','3','4','5','6','7','8','9','10','11','12','13','14']
      and cardinality(affected_classes) <= 14
    ),
  -- Латинские коды (0065 Р1) — русские подписи только в приложении.
  error_types   text[] not null default '{}'
    constraint syllable_assessments_error_types_check
    check (
      error_types <@ array['omission','permutation','addition','substitution',
                            'cluster_simplification','perseveration','anticipation','contamination']
      and cardinality(error_types) <= 8
    ),
  conclusion    text
    constraint syllable_assessments_conclusion_check
    check (conclusion is null or length(conclusion) <= 2000),

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz,

  constraint syllable_assessments_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade,
  constraint syllable_assessments_teacher_fk
    foreign key (teacher_id, center_id) references public.teachers (id, center_id) on delete set null
);

comment on table public.syllable_assessments is
  'Слоговая структура — третий раздел речевой карты (0066, Фаза 3.3). ИСТОРИЯ (решение владельца), не профиль: новая запись на каждое обследование, архивация вместо правки на месте — как diagnostics. affected_classes — коды классов Марковой (текст «1».."14", не число: список закрыт, порядковый смысл не нужен для сравнения). Родителю не видна (ADR-005). Запись — только record_/update_/archive_syllable_assessment.';

create index if not exists syllable_assessments_student_idx
  on public.syllable_assessments (student_id, date desc) where deleted_at is null;
create index if not exists syllable_assessments_center_idx
  on public.syllable_assessments (center_id) where deleted_at is null;

drop trigger if exists syllable_assessments_set_updated_at on public.syllable_assessments;
create trigger syllable_assessments_set_updated_at
  before update on public.syllable_assessments
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('syllable_assessments');
call public.apply_audit('syllable_assessments');
call public.apply_readonly_guard('syllable_assessments');

-- Р3/Р5: student_alive/clinical_teacher_sees/student_primary_teacher (0063/0065)
-- — только вызовы, тела чужие, не переиздаются.
drop policy if exists syllable_assessments_teacher_read on public.syllable_assessments;
create policy syllable_assessments_teacher_read on public.syllable_assessments
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

-- Р5 (пересмотрено ревью написанного SQL): изначальный план исключал
-- owner/admin из student_alive, рассуждая, что иначе архивация ребёнка
-- стёрла бы с экрана историю. Рассуждение оказалось построено на неверной
-- посылке: students.deleted_at НИГДЕ в приложении не выставляется —
-- archive_student пишет status='archived', не deleted_at (grep по всем
-- миграциям это подтверждает), так что защищаемый сценарий физически не
-- наступает уже сегодня. А цена исключения реальна: restrictive без
-- student_alive для owner/admin — не замок, а комментарий, и первая же
-- будущая RPC, ставящая students.deleted_at по-настоящему (запрос
-- родителя на удаление данных ребёнка, 0056 умеет удалять центр — вопрос
-- времени для ребёнка), покажет владельцу запись к карточке, которой на
-- экране нет — ровно механизм 0059 Р14. Возвращён точный образец 0063/0065:
-- student_alive для ВСЕХ, включая owner/admin (clinical_student_visible
-- уже несёт эту проверку внутри себя для owner/admin branch).
drop policy if exists syllable_assessments_visible on public.syllable_assessments;
create policy syllable_assessments_visible on public.syllable_assessments
  as restrictive for select to authenticated
  using (
    public.student_alive(student_id)
    and (
      public.clinical_student_visible(student_id)
      or public.student_primary_teacher(student_id)
      or created_by = auth.uid()
    )
  );

revoke all on table public.syllable_assessments from public, anon, authenticated;
grant select on public.syllable_assessments to authenticated;


-- record_syllable_assessment ------------------------------------------------------------------

create or replace function public.record_syllable_assessment(
  p_student_id       uuid,
  p_date             date default null,
  p_teacher_id       uuid default null,
  p_affected_classes text[] default null,
  p_error_types      text[] default null,
  p_conclusion       text default null
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
  v_affected   text[];
  v_error      text[];
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

  -- Р3: симметрично чтению — clinical_teacher_sees или primary_teacher_id.
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
    if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.center_id = v_center) then
      raise exception 'Специалист не найден' using errcode = '42704';
    end if;
    v_teacher_id := p_teacher_id;
  end if;

  -- Находка 3 ревью написанного SQL: запись без единого содержательного
  -- поля читалась бы на экране как «обследован, нарушений нет» — тот же
  -- ребёнок, которого фактически не обследовали. Хотя бы одно поле.
  if coalesce(cardinality(p_affected_classes), 0) = 0
     and coalesce(cardinality(p_error_types), 0) = 0
     and coalesce(trim(p_conclusion), '') = ''
  then
    raise exception 'Заполните хотя бы одно поле обследования' using errcode = '22023';
  end if;

  -- Находка 4/5: дедуп + числовой порядок для классов (лексикографический
  -- порядок текстовых кодов дал бы '10' раньше '2'), дедуп + алфавитный для
  -- типов ошибок — <@ проверяет только принадлежность, не мощность и не
  -- уникальность, а cardinality-кап без дедупа не спасает от '5','5','5'.
  select coalesce(array_agg(s.x order by s.x::int), '{}'::text[]) into v_affected
    from (select distinct x from unnest(coalesce(p_affected_classes, '{}'::text[])) x) s;
  select coalesce(array_agg(s.x order by s.x), '{}'::text[]) into v_error
    from (select distinct x from unnest(coalesce(p_error_types, '{}'::text[])) x) s;

  insert into public.syllable_assessments (
    center_id, student_id, teacher_id, date, affected_classes, error_types, conclusion
  ) values (
    v_center, p_student_id, v_teacher_id, coalesce(p_date, public.center_today(v_center)),
    v_affected, v_error, nullif(trim(coalesce(p_conclusion, '')), '')
  )
  returning id into v_id;

  perform public.emit_event('syllable_assessment.created',
    jsonb_build_object('center_id', v_center, 'assessment_id', v_id, 'student_id', p_student_id), v_center);

  return v_id;
end;
$$;

comment on function public.record_syllable_assessment(uuid, date, uuid, text[], text[], text) is
  'Новая запись обследования слоговой структуры (0066). Круг записи симметричен чтению (Р3): clinical_teacher_sees или student_primary_teacher, не «первое заполнение любым teacher центра» (урок 0063/0065). Требует хотя бы одно содержательное поле — пустая запись иначе читалась бы как «обследован, нарушений нет» (находка 3 ревью). Классы/типы ошибок — дедуп + отсортированы (числовой порядок для классов, не лексикографический) до записи.';

revoke all on function public.record_syllable_assessment(uuid, date, uuid, text[], text[], text) from public, anon, authenticated, service_role;
grant execute on function public.record_syllable_assessment(uuid, date, uuid, text[], text[], text) to authenticated;


-- update_syllable_assessment -------------------------------------------------------------------

create or replace function public.update_syllable_assessment(
  p_id                   uuid,
  p_date                 date default null,
  p_affected_classes     text[] default null,
  p_error_types          text[] default null,
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
  v_row      public.syllable_assessments;
  v_affected text[];
  v_error    text[];
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  -- Р10: замок строки до проверки прав и записи.
  select * into v_row from public.syllable_assessments
   where id = p_id and center_id = v_center and deleted_at is null
   for update;
  if not found then
    raise exception 'Запись не найдена' using errcode = '42704';
  end if;

  -- Р2/Р4: тотальное булево сравнение (coalesce), и ветка teacher держит
  -- student_alive — живой diagnostics.update_diagnostic не проверяет ни
  -- то, ни другое, и это не копируется сюда сознательно.
  if not (
    v_role in ('owner', 'admin')
    or (
      v_role = 'teacher'
      and public.student_alive(v_row.student_id)
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

  -- Находка 4/5: та же нормализация, что в record_ — только когда
  -- параметр реально передан; иначе оставляем уже нормализованное
  -- значение строки как есть (нормализовать нечего).
  if p_affected_classes is not null then
    select coalesce(array_agg(s.x order by s.x::int), '{}'::text[]) into v_affected
      from (select distinct x from unnest(p_affected_classes) x) s;
  else
    v_affected := v_row.affected_classes;
  end if;

  if p_error_types is not null then
    select coalesce(array_agg(s.x order by s.x), '{}'::text[]) into v_error
      from (select distinct x from unnest(p_error_types) x) s;
  else
    v_error := v_row.error_types;
  end if;

  update public.syllable_assessments set
    date             = coalesce(p_date, date),
    affected_classes = v_affected,
    error_types      = v_error,
    -- Находка 6: '' снимает заключение (тот же сентинел, что 0059 Р16 для
    -- conclusion_code) — иначе стереть ошибочно введённый текст было нечем.
    conclusion       = case when p_conclusion = '' then null else coalesce(p_conclusion, conclusion) end
   where id = p_id;

  perform public.emit_event('syllable_assessment.updated',
    jsonb_build_object('center_id', v_center, 'assessment_id', p_id, 'student_id', v_row.student_id), v_center);
end;
$$;

comment on function public.update_syllable_assessment(uuid, date, text[], text[], text, timestamptz) is
  'Правка записи обследования (0066). null-параметр — не трогать; непустой/пустой массив — заменить целиком, не слить (Р6), с дедупом и сортировкой при передаче. conclusion: '''' снимает, null не трогает (сентинел 0059 Р16). p_expected_updated_at обязателен при расхождении — 22023 без автоповтора (Р10). Ветка teacher держит student_alive — дыра update_diagnostic (Р4) сюда не перенесена.';

revoke all on function public.update_syllable_assessment(uuid, date, text[], text[], text, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.update_syllable_assessment(uuid, date, text[], text[], text, timestamptz) to authenticated;


-- archive_syllable_assessment -------------------------------------------------------------------

create or replace function public.archive_syllable_assessment(p_id uuid)
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
  -- Как archive_diagnostic (0059): архивирует только owner/admin, не автор-teacher.
  if v_role not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.syllable_assessments set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null
   returning student_id into v_student;
  v_found := found;

  if v_found then
    perform public.emit_event('syllable_assessment.archived',
      jsonb_build_object('center_id', v_center, 'assessment_id', p_id, 'student_id', v_student), v_center);
  end if;

  return v_found;
end;
$$;

comment on function public.archive_syllable_assessment(uuid) is
  'Архивация обследования — только owner/admin, как archive_diagnostic (0059).';

revoke all on function public.archive_syllable_assessment(uuid) from public, anon, authenticated, service_role;
grant execute on function public.archive_syllable_assessment(uuid) to authenticated;


-- export_center_tables() — переиздана от 0065, добавлена syllable_assessments (0056 allow-list) --

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
    ('subscription_types'), ('subscriptions'), ('syllable_assessments'), ('teacher_rates'), ('teachers')
$$;

comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
