-- =============================================================================
-- 0008_subscriptions.sql — абонементы
--
--   1. Составные ключи (id, center_id) — фундамент для FK, не пускающих
--      ссылку в чужой центр
--   2. attendance_statuses  — справочник статусов посещения + сид и backfill
--   3. subscription_types   — что продаём
--   4. subscriptions        — что продали
--   5. subscription_freezes — заморозки диапазонами, EXCLUDE от пересечений
--   6. Продажа, заморозка, перенос, возврат
--
-- Посещения и списание — в 0009. Разделение не ради деплоя (CI катит оба
-- файла одним прогоном), а ради того, что ошибку в абонементах чинит
-- следующая миграция, не трогая механику отметок.
-- =============================================================================


-- 1. Составные ключи для FK по центру ------------------------------------------

-- Обычный FK по id пропускает ссылку в чужой центр: администратор центра А
-- вставляет строку со своим center_id и student_id ребёнка центра Б —
-- with check доволен, RLS на students не спрашивают (она режет чтение, а не
-- ссылку). Составной FK (id, center_id) делает это невозможным на уровне
-- констрейнта, то есть переживает и прямой insert, и гонку.
alter table public.students          add constraint students_id_center_key          unique (id, center_id);
alter table public.payers            add constraint payers_id_center_key            unique (id, center_id);
alter table public.lessons           add constraint lessons_id_center_key           unique (id, center_id);
alter table public.services          add constraint services_id_center_key          unique (id, center_id);


-- 2. Справочник статусов посещения ----------------------------------------------

create table if not exists public.attendance_statuses (
  id             uuid primary key default gen_random_uuid(),
  center_id      uuid not null default public.current_center()
                   references public.centers (id) on delete cascade,
  code           text not null,
  name           text not null,
  color          text not null default 'slate',
  -- Списывает занятие с абонемента.
  deducts_lesson boolean not null default true,
  -- Оплачивается специалисту (нужно этапу 5).
  pays_teacher   boolean not null default true,
  -- Считается пропуском для серии absent_streak.
  counts_absence boolean not null default false,
  notify_parent  boolean not null default false,
  is_default     boolean not null default false,
  sort           integer not null default 100,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  deleted_at     timestamptz,

  constraint attendance_statuses_id_center_key unique (id, center_id)
);

-- Код обязан быть уникальным в центре: mark_attendance ищет статус по коду,
-- и при дубле `limit 1` выбрал бы произвольную строку.
create unique index if not exists attendance_statuses_center_code_idx
  on public.attendance_statuses (center_id, code) where deleted_at is null;

-- Статус по умолчанию тоже один: иначе массовая отметка ставит случайный.
create unique index if not exists attendance_statuses_center_default_idx
  on public.attendance_statuses (center_id) where is_default and deleted_at is null;

drop trigger if exists attendance_statuses_set_updated_at on public.attendance_statuses;
create trigger attendance_statuses_set_updated_at before update on public.attendance_statuses
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('attendance_statuses');
call public.apply_audit('attendance_statuses');

-- Справочник нужен и специалисту, и родителю: без него панель отметки
-- показывает ноль кнопок, а история посещений — «—» вместо «болел».
-- Денег здесь нет, поэтому читать можно всем ролям центра.
drop policy if exists attendance_statuses_read_all on public.attendance_statuses;
create policy attendance_statuses_read_all on public.attendance_statuses
  for select to authenticated
  using (center_id = public.current_center() and deleted_at is null);

-- Сид четырёх статусов. center_id передаётся аргументом, а не берётся из
-- current_center(): create_center вызывает switch_center, но JWT в текущей
-- сессии остаётся старым, и дефолт колонки уехал бы в прежний центр.
create or replace function public.seed_attendance_statuses(p_center_id uuid)
  returns void
  language sql
  security definer
  set search_path = ''
as $$
  insert into public.attendance_statuses
    (center_id, code, name, color, deducts_lesson, pays_teacher, counts_absence, notify_parent, is_default, sort)
  values
    (p_center_id, 'present', 'Пришёл',  'green',  true,  true,  false, false, true,  10),
    (p_center_id, 'late',    'Опоздал', 'amber',  true,  true,  false, false, false, 20),
    (p_center_id, 'sick',    'Болел',   'sky',    false, false, true,  true,  false, 30),
    (p_center_id, 'absent',  'Прогул',  'rose',   true,  true,  true,  true,  false, 40)
  on conflict do nothing;
$$;

-- Новому центру статусы ставит триггер, а не правка create_center: замена
-- функции через create or replace требует переписать её тело целиком, и
-- потерять switch_center или emit_event там слишком легко.
create or replace function public.centers_seed_statuses()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform public.seed_attendance_statuses(new.id);
  return null;
end;
$$;

drop trigger if exists centers_seed_attendance_statuses on public.centers;
create trigger centers_seed_attendance_statuses
  after insert on public.centers
  for each row execute function public.centers_seed_statuses();

-- Существующим центрам статусы нужны тоже: staging не пустой.
do $$
declare v_id uuid;
begin
  for v_id in select id from public.centers where deleted_at is null loop
    perform public.seed_attendance_statuses(v_id);
  end loop;
end $$;


-- 3. Типы абонементов ------------------------------------------------------------

create table if not exists public.subscription_types (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  name          text not null,
  -- null = абонемент подходит к любой услуге.
  service_id    uuid,
  kind          text not null default 'lessons'
                  check (kind in ('lessons', 'period', 'unlimited')),
  lessons_count integer,
  period_days   integer,
  price_tiyin   integer not null check (price_tiyin >= 0),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz,

  constraint subscription_types_id_center_key unique (id, center_id),
  constraint subscription_types_service_fk
    foreign key (service_id, center_id) references public.services (id, center_id),

  -- Пакет занятий обязан знать их количество, периодный — срок.
  check (kind <> 'lessons' or (lessons_count is not null and lessons_count > 0)),
  check (kind <> 'period'  or (period_days   is not null and period_days   > 0)),
  check (lessons_count is null or lessons_count > 0),
  check (period_days   is null or period_days   > 0)
);

create index if not exists subscription_types_center_idx
  on public.subscription_types (center_id) where deleted_at is null;

drop trigger if exists subscription_types_set_updated_at on public.subscription_types;
create trigger subscription_types_set_updated_at before update on public.subscription_types
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('subscription_types');
call public.apply_audit('subscription_types');


-- 4. Проданные абонементы --------------------------------------------------------

create table if not exists public.subscriptions (
  id                  uuid primary key default gen_random_uuid(),
  center_id           uuid not null default public.current_center()
                        references public.centers (id) on delete cascade,
  student_id          uuid not null,
  payer_id            uuid not null,
  type_id             uuid,

  -- Продано занятий. null = безлимит. Не уменьшается никогда: факт продажи.
  lessons_total       integer check (lessons_total is null or lessons_total > 0),
  -- Списано посещениями. Пересчитывается триггером в 0009 из фактических
  -- строк attendance, а не инкрементом: инкремент обходят прямой insert,
  -- правка статуса «болел» → «пришёл» и отмена занятия задним числом.
  lessons_used        integer not null default 0 check (lessons_used >= 0),
  -- Списано без посещения: перенос остатка, возврат. Отдельно от used, чтобы
  -- пересчёт по attendance их не затирал.
  lessons_written_off integer not null default 0 check (lessons_written_off >= 0),

  price_tiyin         integer not null check (price_tiyin >= 0),
  -- Цена занятия замораживается при продаже и дальше не редактируется:
  -- иначе правка цены абонемента задним числом меняет сумму возврата.
  lesson_price_tiyin  integer check (lesson_price_tiyin is null or lesson_price_tiyin >= 0),

  starts_at           date not null,
  ends_at             date,
  -- Разрешено уйти в минус по этому абонементу. Не путать с
  -- centers.settings->>'allow_debt': тот про отметку без абонемента вообще.
  allow_negative      boolean not null default false,
  -- Только решения человека. exhausted и expired не хранятся: они
  -- вычисляются из (used, total, ends_at, now) и в колонке протухают —
  -- истёкший абонемент остался бы active до ближайшего запуска чего-нибудь.
  status              text not null default 'active'
                        check (status in ('active', 'frozen', 'cancelled')),
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid default auth.uid(),
  deleted_at          timestamptz,

  constraint subscriptions_id_center_key unique (id, center_id),
  constraint subscriptions_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id),
  constraint subscriptions_payer_fk
    foreign key (payer_id, center_id) references public.payers (id, center_id),
  constraint subscriptions_type_fk
    foreign key (type_id, center_id) references public.subscription_types (id, center_id),

  -- Пакет занятий обязан иметь цену занятия: на ней держится возврат.
  check (lessons_total is null or lesson_price_tiyin is not null),
  -- Не уйти за оплаченное. CHECK на строке, а не проверка в функции: он
  -- срабатывает на финальном состоянии под блокировкой и переживает гонку.
  constraint subscriptions_not_overdrawn check (
    allow_negative
    or lessons_total is null
    or lessons_used + lessons_written_off <= lessons_total
  ),
  check (ends_at is null or ends_at >= starts_at)
);

create index if not exists subscriptions_student_idx
  on public.subscriptions (student_id, status) where deleted_at is null;
create index if not exists subscriptions_center_idx
  on public.subscriptions (center_id) where deleted_at is null;

drop trigger if exists subscriptions_set_updated_at on public.subscriptions;
create trigger subscriptions_set_updated_at before update on public.subscriptions
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('subscriptions');
call public.apply_audit('subscriptions');

-- Родитель видит абонементы своих детей. Специалист — не видит вовсе:
-- база клиентов и денег центра это ровно то, с чем уходят открывать кабинет
-- через дорогу (ADR-005). Ему в 0009 достаётся бейдж «есть / заканчивается
-- / нет» без единой суммы.
drop policy if exists subscriptions_parent_read on public.subscriptions;
create policy subscriptions_parent_read on public.subscriptions
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'parent'
    and deleted_at is null
    and public.parent_of_student(student_id)
  );


-- 5. Заморозки -------------------------------------------------------------------

-- Отдельной таблицей, а не парой колонок на subscriptions. Пара колонок
-- допускает вторую заморозку поверх первой: ends_at сдвинут дважды, видна
-- одна, и возврат считается от вранья. EXCLUDE по диапазону этого не даёт.
--
-- Открытая заморозка — это daterange(from, 'infinity'), а не NULL:
-- NULL-ы в exclusion между собой не конфликтуют и защита бы не сработала.
create table if not exists public.subscription_freezes (
  id              uuid primary key default gen_random_uuid(),
  center_id       uuid not null default public.current_center()
                    references public.centers (id) on delete cascade,
  subscription_id uuid not null,
  period          daterange not null,
  reason          text,
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),

  constraint subscription_freezes_sub_fk
    foreign key (subscription_id, center_id) references public.subscriptions (id, center_id) on delete cascade,

  constraint subscription_freezes_no_overlap exclude using gist (
    subscription_id with =,
    period with &&
  )
);

create index if not exists subscription_freezes_sub_idx
  on public.subscription_freezes (subscription_id);

call public.apply_tenant_rls('subscription_freezes', false);
call public.apply_audit('subscription_freezes');


-- 6. Функции ---------------------------------------------------------------------

-- Зеркало lessonPrice из packages/core/src/money.ts. Округление вниз: центр
-- не может получить больше, чем заплатил родитель. SQL — источник истины,
-- TypeScript — подсказка в браузере; общий набор случаев гоняется в обоих.
create or replace function public.calc_lesson_price(p_price_tiyin integer, p_lessons integer)
  returns integer
  language sql
  immutable
  set search_path = ''
as $$
  select case
    when p_lessons is null or p_lessons <= 0 then null
    else p_price_tiyin / p_lessons
  end;
$$;

-- Сегодняшняя дата в поясе центра. Сервер в UTC, Бишкек +6: абонемент,
-- проданный в 03:00 по Бишкеку, без пересчёта получил бы вчерашнее число.
create or replace function public.center_today(p_center_id uuid default null)
  returns date
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select (now() at time zone public.center_timezone(coalesce(p_center_id, public.current_center())))::date;
$$;

-- Сколько дней абонемент простоял в заморозке: сумма закрытых периодов.
create or replace function public.subscription_freeze_days(p_subscription_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(sum(
    case when upper_inf(f.period) then 0
         else (upper(f.period) - lower(f.period))
    end
  ), 0)::int
  from public.subscription_freezes f
  where f.subscription_id = p_subscription_id;
$$;

-- Остаток занятий. null = безлимит.
create or replace function public.subscription_lessons_left(p_subscription_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select case
    when s.lessons_total is null then null
    else s.lessons_total - s.lessons_used - s.lessons_written_off
  end
  from public.subscriptions s
  where s.id = p_subscription_id;
$$;

-- Вычисляемый статус. exhausted и expired не хранятся: колонка протухает,
-- а функция считает от текущего состояния.
create or replace function public.subscription_state(p_subscription_id uuid)
  returns text
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select case
    when s.status in ('cancelled', 'frozen') then s.status
    when s.ends_at is not null
         and s.ends_at < public.center_today(s.center_id) then 'expired'
    when s.lessons_total is not null
         and s.lessons_total - s.lessons_used - s.lessons_written_off <= 0 then 'exhausted'
    else 'active'
  end
  from public.subscriptions s
  where s.id = p_subscription_id;
$$;

-- Продажа. Деньги не считает браузер: цена, количество и срок берутся из
-- типа, цена занятия — функцией. Переопределить цену может только явный
-- аргумент, и только owner/admin.
create or replace function public.sell_subscription(
  p_type_id    uuid,
  p_student_id uuid,
  p_price_tiyin integer default null,
  p_starts_at  date default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_type    public.subscription_types;
  v_student public.students;
  v_price   integer;
  v_starts  date;
  v_ends    date;
  v_total   integer;
  v_id      uuid;
begin
  if public.my_role() not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_type from public.subscription_types
   where id = p_type_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Тип абонемента не найден' using errcode = '42704';
  end if;

  select * into v_student from public.students
   where id = p_student_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  v_price  := coalesce(p_price_tiyin, v_type.price_tiyin);
  v_starts := coalesce(p_starts_at, public.center_today(v_center));
  v_total  := case when v_type.kind = 'unlimited' then null else v_type.lessons_count end;
  v_ends   := case when v_type.period_days is null then null
                   else v_starts + v_type.period_days end;

  insert into public.subscriptions (
    center_id, student_id, payer_id, type_id,
    lessons_total, price_tiyin, lesson_price_tiyin,
    starts_at, ends_at
  )
  values (
    v_center, p_student_id, v_student.payer_id, p_type_id,
    v_total, v_price, public.calc_lesson_price(v_price, v_total),
    v_starts, v_ends
  )
  returning id into v_id;

  perform public.emit_event('subscription.created',
    jsonb_build_object('center_id', v_center, 'subscription_id', v_id,
                       'student_id', p_student_id, 'price_tiyin', v_price,
                       'lessons_total', v_total), v_center);
  return v_id;
end;
$$;

-- Заморозка. Сдвиг ends_at считается триггером из суммы периодов, а не
-- прибавляется здесь: две заморозки подряд иначе сдвинули бы дважды, а
-- отмена одной из них не откатила бы сдвиг.
create or replace function public.freeze_subscription(
  p_id   uuid,
  p_from date,
  p_to   date default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_sub    public.subscriptions;
  v_state  text;
begin
  if public.my_role() not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_sub from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  v_state := public.subscription_state(p_id);
  if v_state <> 'active' then
    raise exception 'Заморозить можно только действующий абонемент, а он «%»', v_state
      using errcode = '22023';
  end if;

  if p_to is not null and p_to < p_from then
    raise exception 'Дата окончания заморозки раньше начала' using errcode = '22023';
  end if;

  -- Открытый конец — 'infinity', не NULL: иначе EXCLUDE не поймает
  -- пересечение двух открытых заморозок.
  insert into public.subscription_freezes (center_id, subscription_id, period)
  values (v_center, p_id, daterange(p_from, coalesce(p_to, 'infinity'::date), '[)'));

  update public.subscriptions set status = 'frozen' where id = p_id;

  perform public.emit_event('subscription.frozen',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id,
                       'from', p_from, 'to', p_to), v_center);
end;
$$;

create or replace function public.unfreeze_subscription(p_id uuid, p_to date default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_open   public.subscription_freezes;
  v_to     date;
begin
  if public.my_role() not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_open from public.subscription_freezes f
   where f.subscription_id = p_id and f.center_id = v_center and upper_inf(f.period)
   order by lower(f.period) desc limit 1;
  if not found then
    raise exception 'У абонемента нет открытой заморозки' using errcode = '42704';
  end if;

  v_to := coalesce(p_to, public.center_today(v_center));
  if v_to < lower(v_open.period) then
    raise exception 'Дата окончания заморозки раньше её начала' using errcode = '22023';
  end if;

  update public.subscription_freezes
     set period = daterange(lower(v_open.period), v_to, '[)')
   where id = v_open.id;

  update public.subscriptions set status = 'active' where id = p_id;

  perform public.emit_event('subscription.unfrozen',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id, 'to', v_to), v_center);
end;
$$;

-- Сдвиг ends_at держится триггером на заморозках: он единственный источник
-- правды о том, сколько дней абонемент простоял.
create or replace function public.subscriptions_apply_freeze_shift()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_sub uuid := coalesce(new.subscription_id, old.subscription_id);
begin
  update public.subscriptions s
     set ends_at = t.base_ends + public.subscription_freeze_days(v_sub)
    from (
      select s2.id,
             s2.starts_at + (t2.period_days) as base_ends
        from public.subscriptions s2
        join public.subscription_types t2 on t2.id = s2.type_id
       where s2.id = v_sub and t2.period_days is not null
    ) t
   where s.id = t.id;

  return null;
end;
$$;

drop trigger if exists subscription_freezes_shift on public.subscription_freezes;
create trigger subscription_freezes_shift
  after insert or update or delete on public.subscription_freezes
  for each row execute function public.subscriptions_apply_freeze_shift();

-- Возврат: остаток × цена занятия. Предпросмотр и списание считают одинаково.
create or replace function public.refund_calc(p_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(public.subscription_lessons_left(p_id), 0) * coalesce(s.lesson_price_tiyin, 0)
  from public.subscriptions s where s.id = p_id;
$$;

-- Возврат принимает ожидаемую сумму из предпросмотра: между открытием
-- диалога и нажатием кнопки специалист мог отметить занятие, и вернуть
-- деньги за уже проведённое нельзя. Автоповтора нет — админ должен увидеть
-- новую сумму сам.
create or replace function public.refund_subscription(p_id uuid, p_expected_tiyin integer)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_actual integer;
  v_left   integer;
begin
  if public.my_role() not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  perform 1 from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  v_actual := public.refund_calc(p_id);
  if v_actual is distinct from p_expected_tiyin then
    raise exception 'Остаток изменился, пока считали возврат: сейчас % тыйын. Проверьте расчёт.', v_actual
      using errcode = '23514';
  end if;

  v_left := coalesce(public.subscription_lessons_left(p_id), 0);
  update public.subscriptions
     set lessons_written_off = lessons_written_off + v_left,
         status = 'cancelled'
   where id = p_id;

  perform public.emit_event('subscription.refunded',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id,
                       'lessons', v_left, 'amount_tiyin', v_actual), v_center);
  return v_actual;
end;
$$;

-- Перенос остатка другому ребёнку: старый абонемент списывается целиком в
-- written_off, новый заводится с тем же lesson_price_tiyin. Цену не
-- пересчитываем: родитель заплатил именно столько.
create or replace function public.transfer_remaining(p_from uuid, p_to_student uuid)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_from    public.subscriptions;
  v_student public.students;
  v_left    integer;
  v_new     uuid;
begin
  if public.my_role() not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_from from public.subscriptions
   where id = p_from and center_id = v_center and deleted_at is null for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  select * into v_student from public.students
   where id = p_to_student and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  v_left := coalesce(public.subscription_lessons_left(p_from), 0);
  if v_left <= 0 then
    raise exception 'Переносить нечего: остаток пуст' using errcode = '22023';
  end if;

  update public.subscriptions
     set lessons_written_off = lessons_written_off + v_left,
         status = 'cancelled'
   where id = p_from;

  insert into public.subscriptions (
    center_id, student_id, payer_id, type_id,
    lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at, notes
  )
  values (
    v_center, p_to_student, v_student.payer_id, v_from.type_id,
    v_left, v_left * coalesce(v_from.lesson_price_tiyin, 0), v_from.lesson_price_tiyin,
    public.center_today(v_center), v_from.ends_at,
    'Перенос остатка с абонемента ' || p_from::text
  )
  returning id into v_new;

  perform public.emit_event('subscription.transferred',
    jsonb_build_object('center_id', v_center, 'from_subscription_id', p_from,
                       'to_subscription_id', v_new, 'lessons', v_left), v_center);
  return v_new;
end;
$$;


-- Права -------------------------------------------------------------------------

-- Supabase выдаёт роли authenticated полные права на каждую новую таблицу в
-- public: это `alter default privileges` при инициализации проекта. Пока
-- они на месте, колоночный грант ниже ничего не сужает — он добавляет
-- права к уже выданным, а не заменяет их, и PATCH с lessons_used проходит.
-- Тот же механизм разбирался в 0003 для EXECUTE: снимать нужно оба.
revoke all on
  public.attendance_statuses,
  public.subscription_types,
  public.subscriptions,
  public.subscription_freezes
  from anon, authenticated;

grant select, insert, update on public.attendance_statuses, public.subscription_types to authenticated;
grant select on public.subscriptions, public.subscription_freezes to authenticated;

-- Счётчики, цена и статус закрыты от прямой записи: их держат триггеры и
-- RPC. Без этого PATCH /rest/v1/subscriptions с lessons_used=0 обнуляет
-- абонемент без следа в attendance.
grant insert on public.subscriptions to authenticated;
grant update (notes, allow_negative, deleted_at) on public.subscriptions to authenticated;

revoke execute on function
  public.seed_attendance_statuses(uuid),
  public.centers_seed_statuses(),
  public.subscriptions_apply_freeze_shift()
  from public, anon, authenticated;

revoke execute on function
  public.calc_lesson_price(integer, integer),
  public.center_today(uuid),
  public.subscription_freeze_days(uuid),
  public.subscription_lessons_left(uuid),
  public.subscription_state(uuid),
  public.sell_subscription(uuid, uuid, integer, date),
  public.freeze_subscription(uuid, date, date),
  public.unfreeze_subscription(uuid, date),
  public.refund_calc(uuid),
  public.refund_subscription(uuid, integer),
  public.transfer_remaining(uuid, uuid)
  from public, anon;

grant execute on function
  public.calc_lesson_price(integer, integer),
  public.center_today(uuid),
  public.subscription_freeze_days(uuid),
  public.subscription_lessons_left(uuid),
  public.subscription_state(uuid),
  public.sell_subscription(uuid, uuid, integer, date),
  public.freeze_subscription(uuid, date, date),
  public.unfreeze_subscription(uuid, date),
  public.refund_calc(uuid),
  public.refund_subscription(uuid, integer),
  public.transfer_remaining(uuid, uuid)
  to authenticated;
