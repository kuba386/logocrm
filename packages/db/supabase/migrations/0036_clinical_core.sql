-- =============================================================================
-- 0036_clinical_core.sql — клиническое ядро: диагностика, цели, ДЗ, заметки
-- (этап 7a, шаг 1 из 2 — таблицы и чтение; запись и complete_lesson — 0037)
--
-- Самый чувствительный класс данных в проекте. Деньги пересчитываются,
-- сказанное про ребёнка — нет, поэтому видимость здесь строже, чем у всего
-- остального: две роли из шести не получают ни одной строки.
--
-- Решения:
--   Р1. Запись клиники — не политиками, а RPC (0037). У teacher и parent
--       здесь только select. Политика на insert/update стала бы обходом
--       функции: «утвердить заметку» превратилось бы в прямой update
--       status, а родитель переписал бы teacher_feedback и срок ДЗ через
--       PostgREST. Тот же приём, что у attendance (0009) и lessons (0006).
--   Р2. registrar и finance не получают ничего — включая справочники этапов
--       и упражнений: иначе обещание «ничего» неверно, а забор, фиксирующий
--       неверное решение, хуже отсутствующего. Сноска ⁵ в FEATURE_MATRIX;
--       держит забор tests/0028: таблица с политикой tenant_admin и без
--       записанного решения по новым ролям роняет тест. Поэтому все восемь
--       таблиц получают политику через apply_tenant_rls, а не руками — имя
--       tenant_admin и есть то, что забор ищет.
--   Р3. Специалист видит клинику ребёнка, с которым у него есть живое
--       занятие, — не только закреплённого за ним в карточке.
--       Ребёнка ведёт тот, кто его ведёт, а не тот, кто записан в карточке.
--       Срок доступа не ограничен сознательно: специалист, к которому
--       ребёнок вернулся через год, должен видеть историю. Цена — заменявший
--       один раз сохраняет доступ; сужение окна ломает основной сценарий
--       ради редкого.
--   Р4. Родителю — узкие definer-функции, а не политики. diagnostics и
--       lesson_notes в одной строке содержат и то, что родителю можно
--       (заключение, резюме), и то, что нельзя (карта звуков, расшифровка,
--       черновик). Колоночной приватности в Postgres нет — ADR-005, и это
--       третье её применение после students_teacher_view и students_brief.
--       goal_progress.note тоже закрыт: это внутренняя пометка специалиста,
--       тот же класс, что payers.notes у бухгалтера в 0031.
--   Р5. Этапы работы над звуком — центровой справочник с порядком, статусы
--       цели — check. Асимметрия намеренная: этап это ярлык, который центр
--       переименовывает под себя, и у него есть порядок для прогресс-бара;
--       статус — семантика, по которой ветвится код, и её центр не меняет.
--   Р6. Порядок этапов — подсказка, не инвариант. Ни констрейнта «этапы
--       идут по порядку», ни запрета на шаг назад: логопед начинает
--       дифференциацию, не закончив автоматизацию, и возвращается назад —
--       констрейнт сломал бы обычную практику ради красивой модели.
--       Состав этапов задан владельцем (практикующим логопедом) 19.09.2026
--       и отличается от промта: добавлены постановка и дифференциация,
--       убран «автоматизирован» — достижение цели это статус, а не этап.
--   Р7. Упражнение в ДЗ проверяет триггер, а не составной FK. У библиотеки
--       платформы center_id пуст, и FK (exercise_id, center_id) либо
--       отверг бы её целиком, либо — с nullable-колонкой — не проверял бы
--       ничего: FK с NULL не проверяется. Прецедент — 0022, где такие
--       проверки уже сделаны триггерами.
--   Р8. Статус и его метка времени — один инвариант, а не две колонки.
--       lesson_notes.approved_at и goals.achieved_at выставляет триггер, а
--       check держит их согласованность. Иначе прямой PATCH status='approved'
--       мимо RPC 0037 отдаёт родителю непроверенное резюме, а «кто и когда
--       утвердил» не восстановить. Ровно тот случай, про который CLAUDE.md
--       говорит «инвариант — это констрейнт или триггер, а не проверка в
--       функции»: 0037 придёт позже, а политика tenant_admin уже открыта.
--       Обратный переход approved → draft запрещён: резюме уже ушло
--       родителю, и спрятать его задним числом хуже, чем выпустить новое.
--       Цель, наоборот, разрешено открыть заново — звук откатывается, и это
--       обычная практика; триггер просто снимает achieved_at.
--       Прямой PATCH от администратора триггер не запрещает — он его
--       нормализует, и это сознательно: у owner/admin политика tenant_admin
--       открыта на запись, а отнимать её у них ради одной колонки значит
--       заводить колоночные гранты, которых в проекте нет нигде. Цена
--       записана здесь, чтобы 0037 её не проглядел: событие
--       lesson.note_approved эмитит ЭТОТ триггер, а не RPC. Иначе
--       утверждение получит два пути — через функцию с уведомлением
--       родителю и через PATCH без него, — и они разъедутся.
--   Р9. Заметка, прогресс и ДЗ проверяют состав занятия триггером. FK на
--       lesson_participants невозможен: rebuild_lesson_participants (0006)
--       удаляет и перекладывает строки, restrict заблокировал бы смену
--       состава группы, cascade тихо снёс бы клиническую запись. Без
--       проверки complete_lesson (0037) с чужим student_id записал бы SOAP
--       ребёнка А на занятие ребёнка Б — на групповом занятии это один
--       промах копипасты.
--  Р10. Отменённое занятие доступа не даёт. Р3 отказался от окна по времени
--       для состоявшейся работы, но ошибочная запись, отменённая через
--       минуту, не должна навсегда открывать специалисту диагнозы ребёнка.
--       Проверка живёт в clinical_teacher_sees, а не в общей
--       teacher_teaches_student: на той висят другие сценарии.
--  Р11. source — два значения, 'text' и 'voice', вместо трёх из промта.
--       'manual' и 'text' означали бы одно и то же, а два способа сказать
--       одно и то же расходятся: часть кода пишет одно, часть — другое.
--       Отступление записано в reports/stage-7.md.
--
-- Цена: clinical_teacher_sees — definer stable, планировщик её не
-- встраивает и зовёт построчно, а под ней подзапрос к lesson_participants.
-- У goal_progress уровней два: политика зовёт clinical_goal_visible, та —
-- clinical_teacher_sees. Для карточки ребёнка (десятки строк) это нормально;
-- если лента прогресса вырастет до тысяч точек, решение по ребёнку придётся
-- кешировать. Тот же разбор, что у definer-функций в 0031 (docs/Database.md).
-- =============================================================================


-- 1. Справочник этапов ---------------------------------------------------------------------------

create table if not exists public.goal_stages (
  id         uuid primary key default gen_random_uuid(),
  center_id  uuid not null default public.current_center()
               references public.centers (id) on delete cascade,
  code       text not null,
  title      text not null,
  sort       integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  deleted_at timestamptz,

  constraint goal_stages_center_code_key unique (center_id, code),
  constraint goal_stages_id_center_key unique (id, center_id)
);

comment on table public.goal_stages is
  'Этапы работы над звуком: постановка → изолированно → слоги → слова → фразы → связная речь → дифференциация. Центровой справочник: названия и порядок центр меняет под себя. sort — для прогресс-бара и подсказки «следующий этап», а НЕ инвариант перехода (Р6): работа не линейна.';

create index if not exists goal_stages_center_idx on public.goal_stages (center_id) where deleted_at is null;

drop trigger if exists goal_stages_set_updated_at on public.goal_stages;
create trigger goal_stages_set_updated_at
  before update on public.goal_stages
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('goal_stages');
call public.apply_audit('goal_stages');

-- Читают те, кому клиника вообще положена: специалисту нужен список этапов,
-- родителю — подпись к прогрессу ребёнка. Регистратор и бухгалтер сюда не
-- входят (Р2): «ничего» должно значить ничего, иначе через справочник видно,
-- над чем центр работает. Проверка my_role() обязательна отдельно — без неё
-- пользователь с отозванным членством и ещё живым JWT продолжает читать.
drop policy if exists goal_stages_read_all on public.goal_stages;
create policy goal_stages_read_all on public.goal_stages
  for select to authenticated
  using (
    center_id = public.current_center()
    and deleted_at is null
    and public.clinical_role_allowed(public.my_role())
  );

revoke all on table public.goal_stages from public, anon, authenticated, service_role;
grant select, insert, update on public.goal_stages to authenticated;


create or replace function public.seed_goal_stages(p_center_id uuid)
  returns void
  language sql
  security definer
  set search_path = ''
as $$
  insert into public.goal_stages (center_id, code, title, sort)
  values
    (p_center_id, 'setting',        'Постановка',      10),
    (p_center_id, 'isolated',       'Изолированно',    20),
    (p_center_id, 'syllables',      'В слогах',        30),
    (p_center_id, 'words',          'В словах',        40),
    (p_center_id, 'phrases',        'Во фразах',       50),
    (p_center_id, 'speech',         'В связной речи',  60),
    (p_center_id, 'differentiation','Дифференциация',  70)
  on conflict do nothing;
$$;

comment on function public.seed_goal_stages(uuid) is
  'Семь этапов по умолчанию. Постановка и дифференциация — от владельца-логопеда: первой в промте не было вовсе, а с неё начинается половина случаев; вторая не часть автоматизации, а отдельный этап, без которого цель закрывать рано.';

revoke all on function public.seed_goal_stages(uuid) from public, anon, authenticated, service_role;

create or replace function public.centers_seed_goal_stages()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform public.seed_goal_stages(new.id);
  return null;
end;
$$;

revoke all on function public.centers_seed_goal_stages() from public, anon, authenticated, service_role;

drop trigger if exists centers_seed_goal_stages on public.centers;
create trigger centers_seed_goal_stages
  after insert on public.centers
  for each row execute function public.centers_seed_goal_stages();

-- Существующим центрам этапы нужны тоже, иначе goals.stage_id не на что
-- указать и создание первой же цели падает.
do $$
declare v_id uuid;
begin
  for v_id in select id from public.centers where deleted_at is null loop
    perform public.seed_goal_stages(v_id);
  end loop;
end $$;


-- 2. Кто видит клинику ---------------------------------------------------------------------------

-- Список ролей, которым клиника положена, в одном месте. Он нужен в четырёх
-- предикатах, и расписанный руками разъехался бы: роль, добавленная в 7b или
-- 7c, не увидела бы клинику нигде, а забор tests/0028 этого не поймал бы — он
-- ищет политики tenant_registrar_*/tenant_finance_*, а не отсутствие роли.
create or replace function public.clinical_role_allowed(p_role text)
  returns boolean
  language sql
  immutable
as $$
  select coalesce(p_role, '') in ('owner', 'admin', 'teacher', 'parent');
$$;

comment on function public.clinical_role_allowed(text) is
  'Положена ли роли клиника вообще. Единственное место, где перечислены роли: правится один раз и падает в одном тесте.';

revoke all on function public.clinical_role_allowed(text) from public, anon;
grant execute on function public.clinical_role_allowed(text) to authenticated;


-- Объявлено здесь, а не в разделе про политики: функции ниже читают goals и
-- homework и должны стоять рядом со своими таблицами, а обе опираются на эту.
--
-- Р3: ребёнка ведёт тот, у кого с ним есть живое занятие, а не только тот,
-- кто записан в карточке. Два условия добавлены сверх teacher_teaches_student
-- (0006), потому что та писалась под расписание, а не под диагнозы:
--   • отменённое занятие не считается (Р10) — иначе ошибочная запись,
--     отменённая через минуту, навсегда открывает специалисту клинику;
--   • ребёнок не архивирован — teacher_teaches_student этого не проверяет.
-- my_teacher_id() is not null проверяется явно: без этого сравнение с NULL
-- даёт NULL, и предикат молча ведёт себя не так, как читается.
create or replace function public.clinical_teacher_sees(p_student_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(public.my_role(), '') = 'teacher'
     and public.my_teacher_id() is not null
     and exists (
       select 1
         from public.lesson_participants lp
         join public.lessons l on l.id = lp.lesson_id
        where lp.student_id = p_student_id
          and lp.deleted_at is null
          and l.deleted_at is null
          and l.status <> 'cancelled'
          and (l.teacher_id = public.my_teacher_id() or l.substitute_teacher_id = public.my_teacher_id())
     )
     and exists (
       select 1 from public.students s
        where s.id = p_student_id
          and s.center_id = public.current_center()
          and s.deleted_at is null
     );
$$;

comment on function public.clinical_teacher_sees(uuid) is
  'Видит ли специалист клинику этого ребёнка: есть неотменённое занятие с ним и ребёнок не архивирован. Срок доступа не ограничен сознательно (Р3), отменённое занятие доступа не даёт (Р10).';

revoke all on function public.clinical_teacher_sees(uuid) from public, anon;
grant execute on function public.clinical_teacher_sees(uuid) to authenticated;


-- 3. Диагностика ---------------------------------------------------------------------------------

create table if not exists public.diagnostics (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  student_id    uuid not null,
  teacher_id    uuid,
  date          date not null default public.center_today(public.current_center()),
  conclusion    text,
  -- {"р": "искажение", "л": "отсутствие"}
  sounds        jsonb not null default '{}'::jsonb,
  -- {"звукопроизношение": 3, "фонематика": 4, ...} — уровень 1–5
  speech_areas  jsonb not null default '{}'::jsonb,
  attachments   jsonb not null default '[]'::jsonb,
  custom_fields jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz,

  constraint diagnostics_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade,
  constraint diagnostics_teacher_fk
    foreign key (teacher_id, center_id) references public.teachers (id, center_id) on delete set null
);

comment on table public.diagnostics is
  'Диагностика ребёнка. Родителю доступно только conclusion — карта звуков и уровни по областям это рабочий материал специалиста (Р4), и отдаёт их student_diagnostics_brief, а не политика.';

create index if not exists diagnostics_student_idx on public.diagnostics (student_id) where deleted_at is null;
create index if not exists diagnostics_center_idx on public.diagnostics (center_id) where deleted_at is null;

drop trigger if exists diagnostics_set_updated_at on public.diagnostics;
create trigger diagnostics_set_updated_at
  before update on public.diagnostics
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('diagnostics');
call public.apply_audit('diagnostics');


-- 4. Цели и прогресс -----------------------------------------------------------------------------

create table if not exists public.goals (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  student_id    uuid not null,
  stage_id      uuid not null,
  area          text,
  sound         text,
  title         text not null,
  target_date   date,
  -- Статус — семантика, по которой ветвится код, и центр её не меняет (Р5).
  status        text not null default 'active'
                  check (status in ('active', 'achieved', 'paused')),
  achieved_at   timestamptz,
  custom_fields jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz,

  -- Р8: статус и метка времени — один инвариант. Без этого достижение цели
  -- можно объявить, не оставив следа когда.
  constraint goals_achieved_at_matches_status
    check ((status = 'achieved') = (achieved_at is not null)),
  constraint goals_id_center_key unique (id, center_id),
  constraint goals_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade,
  constraint goals_stage_fk
    foreign key (stage_id, center_id) references public.goal_stages (id, center_id) on delete restrict
);

comment on table public.goals is
  'Цель по звуку или области речи. Привязана к паре «ребёнок + звук», поэтому автоматизация и дифференциация одного звука — две цели рядом, каждая со своим этапом (Р6).';

create index if not exists goals_student_idx on public.goals (student_id) where deleted_at is null;
create index if not exists goals_center_idx on public.goals (center_id) where deleted_at is null;

drop trigger if exists goals_set_updated_at on public.goals;
create trigger goals_set_updated_at
  before update on public.goals
  for each row execute function extensions.moddatetime(updated_at);

-- Метку достижения ставит база, а не тот, кто пишет. Констрейнт выше ловит
-- рассогласование, триггер делает его недостижимым: клиент присылает только
-- status, achieved_at выводится. Цель разрешено открыть заново — звук
-- откатывается, это обычная практика, — и тогда метка снимается (Р8).
create or replace function public.goals_sync_achieved_at()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.status = 'achieved' then
    if tg_op = 'INSERT' or old.status is distinct from 'achieved' then
      new.achieved_at := now();
    else
      -- Уже была достигнута: присланную дату не принимаем.
      new.achieved_at := old.achieved_at;
    end if;
  else
    new.achieved_at := null;
  end if;

  return new;
end;
$$;

revoke all on function public.goals_sync_achieved_at() from public, anon, authenticated, service_role;

-- Ребёнка у цели не переставляют. Иначе весь хвост goal_progress, записанный
-- на занятиях одного ребёнка, одним PATCH переезжает к другому: триггер
-- состава занятия висит на goal_progress и при правке goals не срабатывает,
-- FK пропускает — центр тот же. Цель, заведённую не на того ребёнка,
-- закрывают deleted_at и заводят новую.
create or replace function public.goals_student_immutable()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.student_id is distinct from old.student_id then
    raise exception 'Цель нельзя переставить на другого ребёнка: закройте её и заведите новую'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function public.goals_student_immutable() from public, anon, authenticated, service_role;

drop trigger if exists goals_student_immutable on public.goals;
create trigger goals_student_immutable
  before update on public.goals
  for each row execute function public.goals_student_immutable();

drop trigger if exists goals_sync_achieved_at on public.goals;
create trigger goals_sync_achieved_at
  before insert or update on public.goals
  for each row execute function public.goals_sync_achieved_at();

call public.apply_tenant_rls('goals');
call public.apply_audit('goals');


-- Объявлена рядом с таблицей, которую читает: политика goal_progress ссылается
-- на goals, а RLS-политика, читающая другую таблицу напрямую, однажды даёт
-- infinite recursion detected in policy — и роняет не новую таблицу, а всё,
-- что её читает (на этапе 3 так упали students).
create or replace function public.clinical_goal_visible(p_goal_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1 from public.goals g
     where g.id = p_goal_id
       and g.center_id = public.current_center()
       and g.deleted_at is null
       and public.clinical_teacher_sees(g.student_id)
  );
$$;

comment on function public.clinical_goal_visible(uuid) is
  'Видит ли специалист цель — для политики на goal_progress. Отдельная функция, чтобы политика не читала goals напрямую (CLAUDE.md, рекурсия политик).';

revoke all on function public.clinical_goal_visible(uuid) from public, anon;
grant execute on function public.clinical_goal_visible(uuid) to authenticated;


create table if not exists public.goal_progress (
  id           uuid primary key default gen_random_uuid(),
  center_id    uuid not null default public.current_center()
                 references public.centers (id) on delete cascade,
  goal_id      uuid not null,
  lesson_id    uuid,
  date         date not null default public.center_today(public.current_center()),
  score        integer not null check (score between 0 and 100),
  -- Внутренняя пометка специалиста: родителю не показывается (Р4).
  note         text,
  -- Ключ вызова complete_lesson (0037): повтор не должен дать вторую точку
  -- на графике прогресса.
  conduct_key  uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  deleted_at   timestamptz,

  constraint goal_progress_goal_fk
    foreign key (goal_id, center_id) references public.goals (id, center_id) on delete cascade,
  constraint goal_progress_lesson_fk
    foreign key (lesson_id, center_id) references public.lessons (id, center_id) on delete set null
);

comment on table public.goal_progress is
  'Оценка продвижения по цели за занятие, 0–100. note — рабочая пометка специалиста, родителю не видна.';

create index if not exists goal_progress_goal_idx on public.goal_progress (goal_id) where deleted_at is null;
create index if not exists goal_progress_center_idx on public.goal_progress (center_id) where deleted_at is null;
create unique index if not exists goal_progress_conduct_key
  on public.goal_progress (goal_id, conduct_key) where conduct_key is not null and deleted_at is null;

drop trigger if exists goal_progress_set_updated_at on public.goal_progress;
create trigger goal_progress_set_updated_at
  before update on public.goal_progress
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('goal_progress');
call public.apply_audit('goal_progress');


-- 5. Библиотека упражнений -----------------------------------------------------------------------

create table if not exists public.exercise_library (
  id            uuid primary key default gen_random_uuid(),
  -- null — библиотека платформы, доступная всем центрам (как дефолтные
  -- шаблоны сообщений в 0034). Дефолт всё равно нужен: без него админ,
  -- добавляющий упражнение через PostgREST без явного center_id, получает
  -- отказ with check, а не строку. Платформенная строка заводится явным
  -- center_id => null из миграции.
  center_id     uuid default public.current_center()
                  references public.centers (id) on delete cascade,
  area          text,
  sound         text,
  stage_code    text,
  title         text not null,
  instructions  text,
  media_url     text,
  age_from      integer,
  age_to        integer,
  tags          text[] not null default '{}',
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz
  -- unique (id, center_id) здесь был бы мёртвым: id и так первичный ключ, а
  -- составной FK на эту таблицу невозможен из-за платформенных строк (Р7).
);

comment on table public.exercise_library is
  'Упражнения. Строка с center_id is null — библиотека платформы, видна всем центрам; строка центра — только своему. Целостность ДЗ держит триггер, а не FK: у платформенной строки центра нет (Р7).';

create index if not exists exercise_library_center_idx on public.exercise_library (center_id) where deleted_at is null;
create index if not exists exercise_library_sound_idx on public.exercise_library (sound, stage_code) where deleted_at is null;

drop trigger if exists exercise_library_set_updated_at on public.exercise_library;
create trigger exercise_library_set_updated_at
  before update on public.exercise_library
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('exercise_library');
call public.apply_audit('exercise_library');

-- Читают те же роли, что и справочник этапов, — и свои упражнения, и
-- платформенные. В 0034 копия этой политики была ограничена owner/admin, и
-- повтор оставил бы специалиста с пустой библиотекой, а родителя — с ДЗ без
-- названий. Регистратор и бухгалтер исключены (Р2): методические
-- instructions и media_url — тоже рабочий материал центра.
drop policy if exists exercise_library_read_all on public.exercise_library;
create policy exercise_library_read_all on public.exercise_library
  for select to authenticated
  using (
    deleted_at is null
    and public.clinical_role_allowed(public.my_role())
    and (center_id is null or center_id = public.current_center())
  );

revoke all on table public.exercise_library from public, anon, authenticated, service_role;
grant select, insert, update on public.exercise_library to authenticated;


-- 6. Домашние задания ----------------------------------------------------------------------------

create table if not exists public.homework (
  id               uuid primary key default gen_random_uuid(),
  center_id        uuid not null default public.current_center()
                     references public.centers (id) on delete cascade,
  student_id       uuid not null,
  lesson_id        uuid,
  assigned_at      timestamptz not null default now(),
  due_on           date,
  free_text        text,
  status           text not null default 'assigned'
                     check (status in ('assigned', 'submitted', 'reviewed')),
  parent_note      text,
  teacher_feedback text,
  conduct_key      uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),
  deleted_at       timestamptz,

  constraint homework_id_center_key unique (id, center_id),
  constraint homework_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade,
  constraint homework_lesson_fk
    foreign key (lesson_id, center_id) references public.lessons (id, center_id) on delete set null
);

comment on table public.homework is
  'Домашнее задание ребёнку. Родитель видит его целиком — teacher_feedback пишется для него, parent_note он пишет сам; правит и то и другое только RPC (Р1). Медиа от родителя — часть 7c.';

create index if not exists homework_student_idx on public.homework (student_id) where deleted_at is null;
create index if not exists homework_center_idx on public.homework (center_id) where deleted_at is null;
create unique index if not exists homework_conduct_key
  on public.homework (student_id, conduct_key) where conduct_key is not null and deleted_at is null;

drop trigger if exists homework_set_updated_at on public.homework;
create trigger homework_set_updated_at
  before update on public.homework
  for each row execute function extensions.moddatetime(updated_at);

-- Задание идёт вперёд: выдано → сдано → проверено. Назад не откатывается —
-- «проверено» родитель уже увидел вместе с отзывом специалиста (Р8).
create or replace function public.homework_status_transition()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_rank constant jsonb := '{"assigned": 1, "submitted": 2, "reviewed": 3}'::jsonb;
begin
  if new.status is distinct from old.status
     and (v_rank ->> new.status)::int < (v_rank ->> old.status)::int then
    raise exception 'Нельзя вернуть задание из «%» в «%»', old.status, new.status
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function public.homework_status_transition() from public, anon, authenticated, service_role;

drop trigger if exists homework_status_transition on public.homework;
create trigger homework_status_transition
  before update on public.homework
  for each row execute function public.homework_status_transition();

call public.apply_tenant_rls('homework');
call public.apply_audit('homework');


-- Рядом с таблицей, которую читает: политика на homework_exercises иначе
-- ходила бы в homework напрямую (та же причина, что у clinical_goal_visible).
create or replace function public.clinical_homework_visible(p_homework_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1 from public.homework h
     where h.id = p_homework_id
       and h.center_id = public.current_center()
       and h.deleted_at is null
       and public.clinical_role_allowed(public.my_role())
       and (
         coalesce(public.my_role(), '') in ('owner', 'admin')
         or public.clinical_teacher_sees(h.student_id)
         or (coalesce(public.my_role(), '') = 'parent' and public.parent_of_student(h.student_id))
       )
  );
$$;

comment on function public.clinical_homework_visible(uuid) is
  'Видно ли вызывающему само задание — для политики на homework_exercises. Роль проверяется здесь явно, а не делегируется RLS соседней таблицы: иначе ослабление политик homework молча утащит за собой состав ДЗ.';

revoke all on function public.clinical_homework_visible(uuid) from public, anon;
grant execute on function public.clinical_homework_visible(uuid) to authenticated;


-- Связка с аудитом и soft delete, как у group_students (0006): убрать
-- упражнение из выданного задания нужно уметь, а delete в этом проекте не
-- выдаётся никому. Отсюда суррогатный ключ и частичный unique — иначе
-- убранное упражнение навсегда заблокировало бы повторную выдачу.
create table if not exists public.homework_exercises (
  id          uuid primary key default gen_random_uuid(),
  homework_id uuid not null,
  exercise_id uuid not null references public.exercise_library (id) on delete restrict,
  center_id   uuid not null default public.current_center(),
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  deleted_at  timestamptz,

  constraint homework_exercises_homework_fk
    foreign key (homework_id, center_id) references public.homework (id, center_id) on delete cascade
);

comment on table public.homework_exercises is
  'Упражнения в задании. Отдельной таблицей, а не jsonb: «упражнение чужого центра» должно отбиваться базой, а не проверкой в функции. Составной FK на библиотеку невозможен — у платформенной строки center_id пуст, поэтому центр проверяет триггер (Р7).';

create unique index if not exists homework_exercises_pair_key
  on public.homework_exercises (homework_id, exercise_id) where deleted_at is null;
create index if not exists homework_exercises_exercise_idx on public.homework_exercises (exercise_id);
create index if not exists homework_exercises_center_idx on public.homework_exercises (center_id) where deleted_at is null;

drop trigger if exists homework_exercises_set_updated_at on public.homework_exercises;
create trigger homework_exercises_set_updated_at
  before update on public.homework_exercises
  for each row execute function extensions.moddatetime(updated_at);

-- Прецедент — group_students_check_center_refs (0022).
create or replace function public.homework_exercises_check_center_refs()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.exercise_library e
     where e.id = new.exercise_id
       and e.deleted_at is null
       and (e.center_id is null or e.center_id = new.center_id)
  ) then
    raise exception 'Упражнение не найдено в этом центре' using errcode = '42704';
  end if;

  return new;
end;
$$;

drop trigger if exists homework_exercises_check_center_refs on public.homework_exercises;
create trigger homework_exercises_check_center_refs
  before insert or update on public.homework_exercises
  for each row execute function public.homework_exercises_check_center_refs();

revoke all on function public.homework_exercises_check_center_refs() from public, anon, authenticated, service_role;

-- Через apply_tenant_rls, а не руками: забор tests/0028 ищет политику с
-- именем tenant_admin, и своё имя вывело бы восьмую клиническую таблицу
-- из-под проверки «решение по registrar/finance записано» (Р2).
call public.apply_tenant_rls('homework_exercises');
call public.apply_audit('homework_exercises');


-- 7. Заметки занятий -----------------------------------------------------------------------------

create table if not exists public.lesson_notes (
  id             uuid primary key default gen_random_uuid(),
  center_id      uuid not null default public.current_center()
                   references public.centers (id) on delete cascade,
  lesson_id      uuid not null,
  -- Заметка пишется на ребёнка, а не на занятие: иначе на групповом занятии
  -- SOAP одного ребёнка увидят родители всех остальных.
  student_id     uuid not null,
  teacher_id     uuid,
  raw_transcript text,
  soap           jsonb not null default '{}'::jsonb,
  parent_summary text,
  -- goals_touched jsonb из промта здесь нет: какие цели затронуло занятие,
  -- уже записано в goal_progress парой (goal_id, lesson_id) — с FK и
  -- проверкой центра. Массив id в jsonb ничем не проверяется и однажды
  -- показал бы цель другого ребёнка; ровно за это упражнения в ДЗ вынесены
  -- в отдельную таблицу (Р7).
  source         text not null default 'text' check (source in ('text', 'voice')),
  status         text not null default 'draft' check (status in ('draft', 'approved')),
  approved_at    timestamptz,
  approved_by    uuid,
  -- Заполняет 7b: заводим сразу, чтобы не переиздавать таблицу и политики
  -- ради четырёх nullable-колонок.
  model          text,
  tokens_in      integer,
  tokens_out     integer,
  cost_tiyin     integer,
  conduct_key    uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  deleted_at     timestamptz,

  -- Р8: утверждено — значит известно когда и кем. Без этого прямой PATCH
  -- status='approved' мимо RPC отдаёт родителю непроверенное резюме, а следа
  -- не остаётся.
  constraint lesson_notes_approved_at_matches_status
    check ((status = 'approved') = (approved_at is not null)),
  -- Симметрично, а не «approved_by пуст или статус approved»: утверждение без
  -- автора должно падать громко. Иначе воркер 7b или бэкфилл без auth.uid()
  -- запишет «утверждено неизвестно кем», и это пройдёт незамеченным.
  constraint lesson_notes_approved_by_matches_status
    check ((status = 'approved') = (approved_by is not null)),
  constraint lesson_notes_lesson_fk
    foreign key (lesson_id, center_id) references public.lessons (id, center_id) on delete cascade,
  constraint lesson_notes_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade
);

comment on table public.lesson_notes is
  'Заметка занятия по ребёнку. raw_transcript и soap — рабочий материал специалиста; родителю видно только parent_summary и только после утверждения (Р4). Уникальность частичная: архивная заметка не должна блокировать новую.';

-- Частичная: обычная навсегда заблокировала бы новую заметку после
-- архивации старой. Она же держит идемпотентность повторного «Завершить» —
-- на занятие и ребёнка заметка ровно одна, отдельный ключ по conduct_key ей
-- ничего не добавил бы (у goal_progress и homework строк на занятие много,
-- поэтому там conduct_key уникален, а здесь нет).
create unique index if not exists lesson_notes_lesson_student_key
  on public.lesson_notes (lesson_id, student_id) where deleted_at is null;
create index if not exists lesson_notes_student_idx on public.lesson_notes (student_id) where deleted_at is null;
create index if not exists lesson_notes_center_idx on public.lesson_notes (center_id) where deleted_at is null;

drop trigger if exists lesson_notes_set_updated_at on public.lesson_notes;
create trigger lesson_notes_set_updated_at
  before update on public.lesson_notes
  for each row execute function extensions.moddatetime(updated_at);

-- Утверждение — событие, а не значение колонки: метку и автора ставит база.
-- Обратный переход запрещён (Р8) — резюме уже ушло родителю.
create or replace function public.lesson_notes_approval_transition()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.status = 'approved' and new.status <> 'approved' then
    raise exception 'Утверждённое резюме нельзя вернуть в черновик: родитель его уже видел'
      using errcode = '23514';
  end if;

  if new.status = 'approved' then
    if tg_op = 'INSERT' or old.status <> 'approved' then
      new.approved_at := now();
      new.approved_by := auth.uid();
    else
      -- Уже было утверждено: метку и автора не переписывают. Без этой ветки
      -- прямой PATCH approved_by с чужим uuid проходит — проверка перехода
      -- не срабатывает, потому что статус не менялся, и подделка выглядит
      -- как гарантия.
      new.approved_at := old.approved_at;
      new.approved_by := old.approved_by;
    end if;
  else
    new.approved_at := null;
    new.approved_by := null;
  end if;

  return new;
end;
$$;

revoke all on function public.lesson_notes_approval_transition() from public, anon, authenticated, service_role;

drop trigger if exists lesson_notes_approval_transition on public.lesson_notes;
create trigger lesson_notes_approval_transition
  before insert or update on public.lesson_notes
  for each row execute function public.lesson_notes_approval_transition();

call public.apply_tenant_rls('lesson_notes');
call public.apply_audit('lesson_notes');


-- Р9. Состав занятия ------------------------------------------------------------------------------

-- Клиническая запись, привязанная к занятию, обязана относиться к ребёнку,
-- который на этом занятии был. Составные FK проверяют только совпадение
-- центра; FK на lesson_participants невозможен (см. шапку). Триггер стоит
-- после всех трёх таблиц, чтобы ссылка на goals была уже определена.
create or replace function public.clinical_check_lesson_participant()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_student uuid;
begin
  if new.lesson_id is null then
    return new;
  end if;

  -- Откуда брать ребёнка, задаётся аргументом триггера, а не именем таблицы:
  -- по tg_table_name это ломается при переименовании и молча ловит любую
  -- будущую таблицу с колонкой student_id.
  if tg_argv[0] = 'goal' then
    select g.student_id into v_student from public.goals g where g.id = new.goal_id;
  else
    v_student := new.student_id;
  end if;

  if v_student is null then
    raise exception 'Не найден ребёнок для проверки состава занятия' using errcode = '42704';
  end if;

  -- Отменённое и архивное занятие отбиваются здесь же. Иначе правило про
  -- отменённое занятие работало бы только на чтение (Р10), и получилась бы
  -- заметка, которую её автор прочитать не может, а родитель может.
  if not exists (
    select 1
      from public.lesson_participants lp
      join public.lessons l on l.id = lp.lesson_id
     where lp.lesson_id = new.lesson_id
       and lp.student_id = v_student
       and lp.deleted_at is null
       and l.deleted_at is null
       and l.status <> 'cancelled'
  ) then
    raise exception 'Ребёнок не участвует в этом занятии или занятие отменено' using errcode = '42704';
  end if;

  return new;
end;
$$;

revoke all on function public.clinical_check_lesson_participant() from public, anon, authenticated, service_role;

drop trigger if exists goal_progress_check_participant on public.goal_progress;
create trigger goal_progress_check_participant
  before insert or update of lesson_id, goal_id on public.goal_progress
  for each row execute function public.clinical_check_lesson_participant('goal');

drop trigger if exists homework_check_participant on public.homework;
create trigger homework_check_participant
  before insert or update of lesson_id, student_id on public.homework
  for each row execute function public.clinical_check_lesson_participant('student');

drop trigger if exists lesson_notes_check_participant on public.lesson_notes;
create trigger lesson_notes_check_participant
  before insert or update of lesson_id, student_id on public.lesson_notes
  for each row execute function public.clinical_check_lesson_participant('student');


-- 8. Видимость специалиста -----------------------------------------------------------------------

drop policy if exists diagnostics_teacher_read on public.diagnostics;
create policy diagnostics_teacher_read on public.diagnostics
  for select to authenticated
  using (center_id = public.current_center() and deleted_at is null and public.clinical_teacher_sees(student_id));

drop policy if exists goals_teacher_read on public.goals;
create policy goals_teacher_read on public.goals
  for select to authenticated
  using (center_id = public.current_center() and deleted_at is null and public.clinical_teacher_sees(student_id));

drop policy if exists goal_progress_teacher_read on public.goal_progress;
create policy goal_progress_teacher_read on public.goal_progress
  for select to authenticated
  using (
    center_id = public.current_center() and deleted_at is null
    and public.clinical_goal_visible(goal_id)
  );

drop policy if exists homework_teacher_read on public.homework;
create policy homework_teacher_read on public.homework
  for select to authenticated
  using (center_id = public.current_center() and deleted_at is null and public.clinical_teacher_sees(student_id));

drop policy if exists lesson_notes_teacher_read on public.lesson_notes;
create policy lesson_notes_teacher_read on public.lesson_notes
  for select to authenticated
  using (center_id = public.current_center() and deleted_at is null and public.clinical_teacher_sees(student_id));


-- 9. Видимость родителя --------------------------------------------------------------------------

-- ДЗ родитель видит целиком: teacher_feedback пишется для него, parent_note
-- он пишет сам. Остальное — узкими функциями ниже (Р4).
drop policy if exists homework_parent_read on public.homework;
create policy homework_parent_read on public.homework
  for select to authenticated
  using (
    center_id = public.current_center() and deleted_at is null
    and coalesce(public.my_role(), '') = 'parent'
    and public.parent_of_student(student_id)
  );

-- Состав задания виден тому же, кому видно само задание: специалисту и
-- родителю. Роль проверяется внутри clinical_homework_visible явно — делегировать
-- её RLS соседней таблицы значит потерять её молча при первом же послаблении.
drop policy if exists homework_exercises_read on public.homework_exercises;
create policy homework_exercises_read on public.homework_exercises
  for select to authenticated
  using (
    center_id = public.current_center()
    and deleted_at is null
    and public.clinical_homework_visible(homework_id)
  );


create or replace function public.clinical_visible_to_caller(p_student_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select auth.uid() is not null
     and exists (
       select 1 from public.students s
        where s.id = p_student_id
          and s.center_id = public.current_center()
          and s.deleted_at is null
     )
     and public.clinical_role_allowed(public.my_role())
     and (
       coalesce(public.my_role(), '') in ('owner', 'admin')
       or public.clinical_teacher_sees(p_student_id)
       or (coalesce(public.my_role(), '') = 'parent' and public.parent_of_student(p_student_id))
     );
$$;

comment on function public.clinical_visible_to_caller(uuid) is
  'Кому вообще видна клиника ребёнка: администрации, ведущему специалисту и родителю. registrar и finance сюда не входят — клинические данные им не положены (0031, FEATURE_MATRIX сноска ⁵).';

revoke all on function public.clinical_visible_to_caller(uuid) from public, anon;
grant execute on function public.clinical_visible_to_caller(uuid) to authenticated;


create or replace function public.student_diagnostics_brief(p_student_id uuid)
  returns table (id uuid, date date, conclusion text, teacher_name text)
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
    select d.id, d.date, d.conclusion, t.full_name
      from public.diagnostics d
      left join public.teachers t on t.id = d.teacher_id
     where d.student_id = p_student_id
       and d.center_id = public.current_center()
       and d.deleted_at is null
     order by d.date desc;
end;
$$;

comment on function public.student_diagnostics_brief(uuid) is
  'Диагностика для родителя: дата, заключение, специалист. Колонок sounds и speech_areas здесь нет физически — это рабочий материал (ADR-005, третье применение приёма).';

revoke all on function public.student_diagnostics_brief(uuid) from public, anon;
grant execute on function public.student_diagnostics_brief(uuid) to authenticated;


create or replace function public.student_goals_brief(p_student_id uuid)
  returns table (
    id          uuid,
    title       text,
    area        text,
    sound       text,
    stage_title text,
    stage_sort  integer,
    status      text,
    target_date date,
    last_score  integer
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

  return query
    select g.id, g.title, g.area, g.sound, st.title, st.sort, g.status, g.target_date,
           (select p.score from public.goal_progress p
             where p.goal_id = g.id and p.deleted_at is null
             order by p.date desc, p.created_at desc limit 1)
      from public.goals g
      join public.goal_stages st on st.id = g.stage_id
     where g.student_id = p_student_id
       and g.center_id = public.current_center()
       and g.deleted_at is null
     order by st.sort, g.created_at;
end;
$$;

comment on function public.student_goals_brief(uuid) is
  'Цели ребёнка с последней оценкой. Колонки note из goal_progress здесь нет: это внутренняя пометка специалиста, тот же класс, что payers.notes у бухгалтера в 0031.';

revoke all on function public.student_goals_brief(uuid) from public, anon;
grant execute on function public.student_goals_brief(uuid) to authenticated;


create or replace function public.student_notes_brief(p_student_id uuid)
  returns table (id uuid, lesson_id uuid, lesson_at timestamptz, parent_summary text)
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
    select n.id, n.lesson_id, l.starts_at, n.parent_summary
      from public.lesson_notes n
      join public.lessons l on l.id = n.lesson_id
     where n.student_id = p_student_id
       and n.center_id = public.current_center()
       and n.deleted_at is null
       -- Тот же фильтр, что в clinical_teacher_sees: отменённое и удалённое
       -- занятие выпадает у обоих. Иначе родитель и специалист видят разные
       -- истории одного ребёнка.
       and l.deleted_at is null
       and l.status <> 'cancelled'
       -- Черновик родителю не показывается ни при каких условиях: он ещё
       -- не проверен специалистом.
       and n.status = 'approved'
     order by l.starts_at desc;
end;
$$;

comment on function public.student_notes_brief(uuid) is
  'Резюме занятий для родителя: только утверждённые и только parent_summary. raw_transcript и soap сюда не попадают физически.';

revoke all on function public.student_notes_brief(uuid) from public, anon;
grant execute on function public.student_notes_brief(uuid) to authenticated;


-- 10. Гранты -------------------------------------------------------------------------------------

-- DELETE не выдаётся никому (0024). Запись — owner/admin по tenant_admin;
-- у teacher и parent только select-политики, и их insert отобьёт RLS (Р1).
revoke all on table public.diagnostics    from public, anon, authenticated, service_role;
revoke all on table public.goals          from public, anon, authenticated, service_role;
revoke all on table public.goal_progress  from public, anon, authenticated, service_role;
revoke all on table public.homework       from public, anon, authenticated, service_role;
revoke all on table public.homework_exercises from public, anon, authenticated, service_role;
revoke all on table public.lesson_notes   from public, anon, authenticated, service_role;

grant select, insert, update on public.diagnostics        to authenticated;
grant select, insert, update on public.goals              to authenticated;
grant select, insert, update on public.goal_progress      to authenticated;
grant select, insert, update on public.homework           to authenticated;
grant select, insert, update on public.homework_exercises to authenticated;
grant select, insert, update on public.lesson_notes       to authenticated;
