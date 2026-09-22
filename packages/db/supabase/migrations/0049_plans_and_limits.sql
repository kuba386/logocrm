-- =============================================================================
-- 0049_plans_and_limits.sql — тарифы, роль платформы, лимиты (этап 8a, шаг 1)
--
-- План — reports/stage-8.md (после ревью архитектора, 20 находок). Здесь
-- первая часть: справочник тарифов с ценами владельца (22.09.2026), защита
-- тарифа от правки центром, роль администратора платформы, лимиты
-- специалистов и учеников. Trial/read-only, платежи, воронка и квота ИИ —
-- следующими миграциями, каждая со своим Plan-разделом.
--
-- Решения:
--
--   Р1. plans — справочник платформы, не центра: code pk, price_tiyin
--       (тыйыны, не сомы — MRR на /admin не должен смешивать единицы),
--       limits jsonb с ключами teachers/students/ai_notes_month. «Без
--       ограничения» — явное -1, не null: отсутствие ключа — отказ, а не
--       разрешение (иначе пустой seed на prod = безлимит для всех). Ключей
--       telehealth/branches из промта нет: лимит, который никто не
--       проверяет, — ложь. Seed — строками этой миграции, не seed.sql.
--
--   Р2. centers.plan → FK на plans.code, литеральный check из 0001 снят:
--       два списка тарифов разошлись бы на первом новом. Код 'ai' из 0001
--       заменён на 'center' (ни один центр им не пользовался; проверено
--       запросом 22.09.2026: оба центра на trial).
--
--   Р3. Тариф пишет только платформа. grant update on centers to
--       authenticated + centers_update_owner (0001/0024) дают владельцу
--       центра запись во все колонки — PATCH из devtools отменял бы
--       оплату навсегда (0032 Р9 отказался от отметки в centers ровно
--       поэтому). Триггер before update: plan, trial_ends_at,
--       subscription_until и settings->'features' меняет только
--       is_platform_admin(). Колоночных прав по роли в Postgres нет
--       (ADR-005) — поэтому триггер, а не revoke update (plan).
--
--   Р4. platform_admins — по email, не по user_id: у владельца платформы
--       (kadamlogopedbishkek@gmail.com) на 22.09.2026 ещё нет аккаунта, а
--       миграция не может ссылаться на несуществующий auth.users.id.
--       is_platform_admin() сравнивает lower(auth.jwt()->>'email') —
--       email в JWT ставит Supabase после подтверждения, подделать его
--       из клиента нельзя. Роль вне memberships: current_center() и
--       my_role() у администратора платформы пусты, и функции /admin
--       обязаны начинаться с этого предиката, а не с центра (Plan Р15).
--
--   Р5. Лицензия специалиста = живая карточка teachers (deleted_at is
--       null). Одно определение: create_invitation заводит карточку до
--       регистрации, accept_invitation добавляет членство после — счёт по
--       memberships расходовал бы одну лицензию дважды в одном счётчике
--       и ни разу в другом. Ученик занимает место, пока не в архиве
--       (deleted_at is null and status <> 'archived'): у учеников нет
--       мягкого удаления, archive_student ставит только status, и счёт по
--       deleted_at оставил бы центр без способа освободить место — текст
--       отказа врал бы о доступных действиях. Плата за активный список,
--       не за историю; отступление от Plan Р5 записано в BUSINESS_RULES.
--
--   Р6. Лимит проверяется только на переходе В считаемое состояние:
--       insert живой строки, восстановление из deleted_at, у учеников —
--       выход из archived. Центр, превысивший лимит после понижения
--       плана, живёт дальше и теряет только право расти — правка телефона
--       у ребёнка не должна отбиваться лимитом (Plan Р5). Триггеры AFTER:
--       BEFORE не видит строк своего оператора, и пакетная вставка
--       обходила бы лимит целиком (ревью). Смена center_id живой строки
--       счёт не пересчитывает — прямой путь закрыт with check тенанта;
--       если этап 9 заведёт перенос между филиалами, триггер расширить.
--
--   Р7. Гонка: pg_advisory_xact_lock по ключу 'center_limit:' ||
--       center_id ДО count(*), один ключ для всех триггеров лимитов —
--       иначе гонка переезжает между таблицами. Serializable не годится:
--       под PostgREST транзакцией управляет не приложение (Plan Р5).
--       Два одновременных восстановления одной карточки дадут 40P01 —
--       errors.ts помечает его retryable, это приемлемо.
--
--   Р8. Текст отказа — русский, errcode 23514, имя тарифа из plans.name,
--       без склонения числа: «Лимит тарифа Solo — специалистов: 1.
--       Освободите место в архиве или смените тариф в настройках центра».
--       Имени констрейнта нет, поэтому errors.ts отдаёт текст как есть
--       (ветка 23514 без имени) — правка CHECK_MESSAGES не нужна.
--       Фикстуры pgTAP, которым нужно больше 5 специалистов или 200
--       учеников в одном центре, заводят центр с plan = 'center' (0017).
--       Запись settings центром — в будущем только через RPC, которая
--       мержит ключи и не трогает features; целый PATCH settings без
--       ключа features триггер отобьёт как попытку снять фичи.
--
--   Р9. center_limits() — один RPC для экрана тарифа, баннера и
--       онбординга: план, лимиты, использование, дни до конца в поясе
--       центра. Считает тем же предикатом, что триггеры (plan_limit +
--       те же count). Права и занятость в браузере не считаются
--       (CLAUDE.md). Родителю не отдаётся — тариф центра не его дело.
--
--   Р10. Что НЕ здесь: center_billing, trial/read-only гейт по всем
--       definer-функциям записи, платежи и extend_subscription, воронка,
--       квота ИИ, /admin-RPC, экспорт, самоподписка. Каждое — своей
--       миграцией с ревью.

-- 1. Справочник тарифов --------------------------------------------------------------------------

create table if not exists public.plans (
  code        text primary key,
  name        text not null,
  price_tiyin integer not null check (price_tiyin >= 0),
  limits      jsonb not null,
  sort        integer not null default 0,
  is_public   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint plans_limits_keys check (
    limits ?& array['teachers', 'students', 'ai_notes_month']
    and jsonb_typeof(limits -> 'teachers') = 'number'
    and jsonb_typeof(limits -> 'students') = 'number'
    and jsonb_typeof(limits -> 'ai_notes_month') = 'number'
  )
);

comment on table public.plans is
  'Тарифы платформы (0049 Р1). Цены в тыйынах. limits: teachers/students/ai_notes_month, -1 = без ограничения. Пишет только администратор платформы; читает любой авторизованный — экран «Сменить план».';

drop trigger if exists plans_set_updated_at on public.plans;
create trigger plans_set_updated_at
  before update on public.plans
  for each row execute function extensions.moddatetime(updated_at);

-- Цены и лимиты — решение владельца 22.09.2026 по анализу рынка
-- (reports/stage-8.md): 990 / 3 900 / 7 900 сом. trial = полный Studio,
-- не продаётся.
insert into public.plans (code, name, price_tiyin, limits, sort, is_public) values
  ('trial',  'Пробный', 0,      '{"teachers": 5,  "students": 200, "ai_notes_month": 200}'::jsonb,  0, false),
  ('solo',   'Solo',    99000,  '{"teachers": 1,  "students": 40,  "ai_notes_month": 30}'::jsonb,  10, true),
  ('studio', 'Studio',  390000, '{"teachers": 5,  "students": 200, "ai_notes_month": 200}'::jsonb, 20, true),
  ('center', 'Center',  790000, '{"teachers": -1, "students": -1,  "ai_notes_month": 1000}'::jsonb, 30, true)
on conflict (code) do nothing;

alter table public.plans enable row level security;

drop policy if exists plans_select_authenticated on public.plans;
create policy plans_select_authenticated on public.plans
  for select to authenticated
  using (true);

-- service_role чтение оставлено (конвенция 0024: revoke только у
-- public/anon/authenticated): справочник тарифов — не персональные данные,
-- а квота ИИ следующей миграции читает limits из контура воркера.
revoke all on table public.plans from public, anon, authenticated;
grant select on public.plans to authenticated;

-- Аудит: plans и platform_admins без center_id, а audit_log.center_id not
-- null — apply_audit к ним неприменим. След смены тарифа есть в audit_log
-- центра (centers под apply_audit); журнал изменений самих справочников —
-- вместе с /admin-RPC, которые будут единственным путём записи.

-- Р2: centers.plan — ссылка, не литерал. Перед деплоем на другую базу:
-- select plan, count(*) from centers group by 1 — код 'ai' должен быть пуст.
alter table public.centers drop constraint if exists centers_plan_check;
alter table public.centers drop constraint if exists centers_plan_fk;
alter table public.centers
  add constraint centers_plan_fk foreign key (plan) references public.plans (code) on delete restrict;


-- 2. Роль платформы ------------------------------------------------------------------------------

create table if not exists public.platform_admins (
  email      text primary key check (email = lower(email)),
  created_at timestamptz not null default now(),
  note       text
);

comment on table public.platform_admins is
  'Администраторы платформы по email (0049 Р4): роль вне memberships, сравнение с auth.jwt()->>''email''. Первого заводит миграция, следующих — RPC /admin (позже).';

insert into public.platform_admins (email, note) values
  ('kadamlogopedbishkek@gmail.com', 'владелец платформы, решение 22.09.2026')
on conflict (email) do nothing;

-- Не по claim'у email из JWT, а по auth.users текущего uid и только при
-- подтверждённом email: claim — это auth.users.email на момент выдачи
-- токена, а signup с чужим адресом при выключенном подтверждении дал бы
-- токен с этим email любому. Подтверждение email в облачном проекте —
-- условие деплоя (ADR-004). Долг: после регистрации владельца перевести
-- platform_admins на user_id (план Р15), строка по email — одноразовая
-- заявка.
create or replace function public.is_platform_admin()
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select auth.uid() is not null
     and exists (
       select 1
         from auth.users u
         join public.platform_admins a on a.email = lower(u.email)
        where u.id = auth.uid()
          and u.email_confirmed_at is not null
     );
$$;

comment on function public.is_platform_admin() is
  'Администратор платформы текущей сессии (0049 Р4): auth.users по auth.uid(), email подтверждён, адрес в platform_admins. Проверка внутри каждой /admin-RPC — первой строкой, до current_center().';

revoke all on function public.is_platform_admin() from public, anon;
grant execute on function public.is_platform_admin() to authenticated;

alter table public.platform_admins enable row level security;

drop policy if exists platform_admins_select_self on public.platform_admins;
create policy platform_admins_select_self on public.platform_admins
  for select to authenticated
  using (public.is_platform_admin());

revoke all on table public.platform_admins from public, anon, authenticated, service_role;
grant select on public.platform_admins to authenticated;


-- 3. Тариф пишет только платформа (Р3) -----------------------------------------------------------

create or replace function public.centers_protect_plan()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if (new.plan is distinct from old.plan
      or new.trial_ends_at is distinct from old.trial_ends_at
      or new.subscription_until is distinct from old.subscription_until
      or (new.settings -> 'features') is distinct from (old.settings -> 'features'))
     and not public.is_platform_admin()
  then
    raise exception 'Тариф и срок подписки меняет только администратор платформы'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function public.centers_protect_plan() from public, anon, authenticated, service_role;

drop trigger if exists centers_protect_plan on public.centers;
create trigger centers_protect_plan
  before update on public.centers
  for each row execute function public.centers_protect_plan();


-- 4. Лимиты (Р5–Р8) ------------------------------------------------------------------------------

-- Лимит тарифа центра по ключу. Отсутствие плана или ключа — ошибка, не
-- безлимит (Р1). -1 — без ограничения.
create or replace function public.plan_limit(p_center_id uuid, p_key text)
  returns integer
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_limits jsonb;
begin
  select p.limits into v_limits
    from public.centers c
    join public.plans p on p.code = c.plan
   where c.id = p_center_id;

  if v_limits is null or jsonb_typeof(v_limits -> p_key) <> 'number' then
    raise exception 'У центра не задан тариф — обратитесь к администратору платформы'
      using errcode = '23514';
  end if;

  return (v_limits ->> p_key)::integer;
end;
$$;

revoke all on function public.plan_limit(uuid, text) from public, anon, authenticated, service_role;

create or replace function public.center_plan_name(p_center_id uuid)
  returns text
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(p.name, c.plan)
    from public.centers c left join public.plans p on p.code = c.plan
   where c.id = p_center_id;
$$;

revoke all on function public.center_plan_name(uuid) from public, anon, authenticated, service_role;

-- Общая проверка: вызывается из AFTER-триггеров, когда своя строка уже
-- посчитана — поэтому сравнение строгое (>). Ключ advisory lock один на
-- центр для всех лимитов (Р7). Текст не склоняет число: «1 специалистов»
-- на экране, который должен убедить заплатить, недопустимо.
create or replace function public.assert_center_limit(p_center_id uuid, p_key text, p_current integer, p_noun text)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_limit integer := public.plan_limit(p_center_id, p_key);
begin
  if v_limit < 0 then
    return;
  end if;
  if p_current > v_limit then
    raise exception 'Лимит тарифа % — %: %. Освободите место в архиве или смените тариф в настройках центра',
      public.center_plan_name(p_center_id), p_noun, v_limit
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function public.assert_center_limit(uuid, text, integer, text) from public, anon, authenticated, service_role;

-- AFTER, не BEFORE: BEFORE-триггер не видит строк своего же оператора
-- (cmin = curcid), и один insert с массивом из 500 учеников проходил бы
-- лимит целиком. AFTER выполняется после инкремента командного счётчика и
-- считает всё, включая свою строку.
create or replace function public.teachers_check_limit()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer;
begin
  -- Р6: только вход в «живые»: insert живой карточки или восстановление.
  if new.deleted_at is not null then
    return null;
  end if;
  if tg_op = 'UPDATE' and old.deleted_at is null then
    return null;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('center_limit:' || new.center_id::text, 0));

  select count(*)::integer into v_count
    from public.teachers t
   where t.center_id = new.center_id and t.deleted_at is null;

  perform public.assert_center_limit(new.center_id, 'teachers', v_count, 'специалистов');
  return null;
end;
$$;

revoke all on function public.teachers_check_limit() from public, anon, authenticated, service_role;

drop trigger if exists teachers_check_limit on public.teachers;
create trigger teachers_check_limit
  after insert or update of deleted_at on public.teachers
  for each row execute function public.teachers_check_limit();

-- Ученик занимает место, пока он не в архиве: archive_student (0005) ставит
-- status = 'archived', deleted_at у учеников не выставляет ничто — считать
-- по deleted_at значило бы, что место освободить нечем. Решение записано в
-- docs/BUSINESS_RULES.md; center_limits() считает тем же условием.
create or replace function public.students_check_limit()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer;
begin
  if new.deleted_at is not null or new.status = 'archived' then
    return null;
  end if;
  if tg_op = 'UPDATE' and old.deleted_at is null and old.status <> 'archived' then
    return null;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('center_limit:' || new.center_id::text, 0));

  select count(*)::integer into v_count
    from public.students s
   where s.center_id = new.center_id and s.deleted_at is null and s.status <> 'archived';

  perform public.assert_center_limit(new.center_id, 'students', v_count, 'учеников');
  return null;
end;
$$;

revoke all on function public.students_check_limit() from public, anon, authenticated, service_role;

drop trigger if exists students_check_limit on public.students;
create trigger students_check_limit
  after insert or update of deleted_at, status on public.students
  for each row execute function public.students_check_limit();


-- 5. Экран тарифа: один RPC (Р9) ------------------------------------------------------------------

create or replace function public.center_limits()
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_c      public.centers;
  v_p      public.plans;
  v_tz     text;
  v_today  date;
  v_until  timestamptz;
  v_ai     integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role = 'parent' or v_role = '' then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_c from public.centers where id = v_center;
  select * into v_p from public.plans where code = v_c.plan;
  if v_p.code is null then
    raise exception 'У центра не задан тариф — обратитесь к администратору платформы' using errcode = '23514';
  end if;

  v_tz    := public.center_timezone(v_center);
  v_today := (now() at time zone v_tz)::date;
  v_until := case when v_c.plan = 'trial' then v_c.trial_ends_at else v_c.subscription_until end;

  select count(*)::integer into v_ai
    from public.ai_usage u
   where u.center_id = v_center
     and u.kind = 'summary'
     and (u.created_at at time zone v_tz)::date >= date_trunc('month', v_today)::date;

  return jsonb_build_object(
    'plan',        v_p.code,
    'plan_name',   v_p.name,
    'price_tiyin', v_p.price_tiyin,
    'is_trial',    v_c.plan = 'trial',
    'until',       v_until,
    'days_left',   case when v_until is null then null
                        else ((v_until at time zone v_tz)::date - v_today) end,
    'limits',      v_p.limits,
    'usage', jsonb_build_object(
      'teachers', (select count(*) from public.teachers t where t.center_id = v_center and t.deleted_at is null),
      'students', (select count(*) from public.students s where s.center_id = v_center and s.deleted_at is null and s.status <> 'archived'),
      'ai_notes_month', v_ai
    ),
    'onboarding', jsonb_build_object(
      'teacher',    exists (select 1 from public.teachers t where t.center_id = v_center and t.deleted_at is null),
      'service',    exists (select 1 from public.services s where s.center_id = v_center and s.deleted_at is null),
      'student',    exists (select 1 from public.students s where s.center_id = v_center and s.deleted_at is null),
      'lesson',     exists (select 1 from public.lessons l where l.center_id = v_center and l.deleted_at is null),
      'attendance', exists (select 1 from public.attendance a where a.center_id = v_center)
    )
  );
end;
$$;

comment on function public.center_limits() is
  'Тариф, лимиты, использование, дни до конца в поясе центра и галочки онбординга — одним запросом для экрана тарифа и баннера (0049 Р9). Родителю недоступно.';

revoke all on function public.center_limits() from public, anon, service_role;
grant execute on function public.center_limits() to authenticated;
