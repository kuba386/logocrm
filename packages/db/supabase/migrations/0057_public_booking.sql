-- =============================================================================
-- 0057_public_booking.sql — публичная витрина записи /book/[slug]
--
-- Два раунда ревью архитектору (план, затем переработанный план) нашли 13 +
-- 22 дыры в исходной идее «анонимный RPC пишет lead в students + lesson
-- planned напрямую». Решения:
--
--   Р1. Заявка на подтверждение, не мгновенная запись (решение владельца).
--       booking_requests — отдельная таблица; анонимный путь не касается
--       students/lessons/payers вовсе. Иначе публичный EXCLUDE-конфликт
--       (lessons_teacher_no_overlap) даёт DoS на расписание специалиста, и
--       students_check_limit сливает название тарифа наружу.
--   Р2. Анонимного PostgREST-пути к записи нет вообще. Новая роль
--       `public_booking` — точная калька `bot_worker` (0032): nologin
--       noinherit, ни одного табличного гранта, только execute на три
--       функции витрины. Не service_role (у него остаются все таблицы) и не
--       anon (там ключ лежит в браузерном бандле, параметры RPC — под
--       контролем атакующего). JWT с claim role: public_booking заводит
--       владелец, используется только в Next.js Server Actions — ADR-008.
--       `emit_event` требует auth.uid() is not null (0002) — у этой роли
--       его нет и не будет, поэтому запись заявки идёт через
--       emit_event_unchecked (0018), как у bot_worker.
--   Р3. Публикация центра — через RPC set_booking_enabled (owner/admin), не
--       прямой PATCH centers.settings: слово того же веса, что удаление
--       центра (0056), не разбросанное поле формы. Ключ settings.
--       booking_enabled по конвенции timezone/city/features (0001).
--       booking_published(uuid) — единственное место, где ключ читается.
--   Р4. Один отказ на все внутренние причины по публичному пути —
--       «запись сейчас недоступна» что для неизвестного slug, что для
--       неопубликованного центра, что для read-only/просроченного (через
--       center_writable, 0050), что для неактивной услуги/специалиста.
--       Детали — только в CRM, не на форме перед посторонним.
--   Р5. Матчинг с существующим payer по телефону — НЕ на публичном пути и
--       НЕ неявно при подтверждении. confirm_booking_request принимает
--       явный p_payer_id: null — стойка осознанно создаёт нового
--       плательщика текстом заявки, конкретный id — стойка выбрала
--       существующего (см. booking_request_payer_match, предпросмотр по
--       телефону). create_student_with_payer (0055) зовётся уже с готовым
--       payer_id, её собственный поиск по телефону в этом пути не участвует
--       — иначе кто угодно с публичной формы подсаживает чужого ребёнка в
--       чужой кабинет по угаданному номеру.
--   Р6. Телефон нормализуется на входе (normalize_kg_phone, 0005) и
--       хранится только нормализованным — констрейнт, не соглашение внутри
--       функции, иначе лимит по телефону сравнивает разные форматы одного
--       номера и не срабатывает никогда.
--   Р7. service_id обязателен; ends_at считается в SQL из
--       services.duration_min — второго источника длительности (React)
--       не заводим.
--   Р8. Rate limit — без отдельной attempts-таблицы: считает сами
--       booking_requests за час (отказ не пишет строку — гонка «отказ
--       откатывается вместе со своей же попыткой» этим устранена
--       структурно, не логикой). Лимит на телефон (3/час, в границах
--       центра — общий по всем центрам одним номером превращал бы очередь
--       чужого центра в отказ доступа к своему, находка архитектора) —
--       адресная защита, рабочая благодаря Р6 (нормализация) и
--       pg_advisory_xact_lock(hashtext(телефон||центр)) — без него
--       параллельные заявки читают один и тот же count(*) до чужого
--       коммита и лимит не держит вовсе. Лимит на центр (20/час) — мягкий
--       backstop, намеренно НЕ сериализован тем же приёмом (блокировка на
--       весь центр убила бы параллельную пропускную способность ради
--       этого мягкого ограничения): IP-ограничение и капча — вне SQL,
--       задача владельца на Vercel (Требует пользователя).
--   Р9. Рабочих часов/доступности специалиста в схеме нет и здесь не
--       заводятся (0057 — не про это). Публичная форма принимает любое
--       время в окне [+30 минут; +90 дней] от now(); решение, стоит ли
--       время в рабочие часы центра, — за стойкой при подтверждении.
--       Явное решение, а не недосмотр.
--   Р10. Составные FK (service_id, center_id)/(teacher_id, center_id) на
--       services/teachers по образцу 0022 — принадлежность центру не
--       только в plpgsql-проверке.
--   Р11. Уведомление о заявке — стойке (owner/admin/registrar), не только
--       owner/admin: notification_front_desk_targets — копия
--       notification_admin_targets (последней версии, 0037 — через
--       resolve_template/should_send, не ранней 0034) с расширенным
--       списком ролей, потому что notification_admin_targets используют
--       больше десятка других типов событий и её семантику трогать нельзя.
--       mandatory = false — это не платёжный и не безопасностный сигнал,
--       стойка вправе выключить канал.
--   Р12. booking_requests — обычная таблица центра: deleted_at, apply_
--       tenant_rls/apply_audit/apply_readonly_guard как у всех, плюс
--       собственная select-политика для registrar (apply_role_rls, 0028) —
--       apply_tenant_rls покрывает только owner/admin. Прямых INSERT/
--       UPDATE/DELETE-грантов для authenticated нет вовсе: подача,
--       подтверждение и отклонение — только через RPC (revoke all + grant
--       select, тот же приём, что у audit_log/events/lesson_participants,
--       0024). a00_readonly_guard молча пропускает вставку под
--       public_booking (auth.uid() is null, ADR-011) — submit_booking_
--       request поэтому проверяет booking_published() сама (которая уже
--       включает center_writable, Р3); под authenticated-подтверждением
--       guard работает нормально и блокирует confirm/decline на read-only
--       центре, что и требуется. Автоочистки отклонённых заявок здесь нет
--       — как и у audit_log/events, срок хранения этого класса данных
--       решается отдельно, не в рамках 0057. deleted_at — по конвенции
--       apply_tenant_rls (нужен ей как колонка), пути записи в него сейчас
--       нет ни у кого: мягкое удаление отдельной заявки — не сценарий
--       этого этапа, не изобретаю RPC под гипотетическую надобность.
--   Р13. confirm_booking_request сначала атомарно захватывает заявку
--       (update … where status = 'new'), потом создаёт student/lesson —
--       двойное подтверждение получает отказ «уже обработана» без гонки;
--       если сама конверсия упадёт (конфликт слота, архивный специалист),
--       откат вернёт status в 'new' вместе со всей транзакцией.
--   Р14. export_center_tables() (0056) переиздана с booking_requests —
--       текст ребёнка/родителя в заявке (даже неподтверждённой) для
--       владельца — те же персональные данные, что и в students.
-- =============================================================================


-- 1. Роль public_booking ------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'public_booking') then
    create role public_booking nologin noinherit;
  end if;
end;
$$;

grant public_booking to authenticator;
grant usage on schema public to public_booking;

comment on role public_booking is
  'Публичная витрина записи /book/[slug] (0057). Ни одного табличного гранта: только execute на booking_center_info/booking_teacher_busy/submit_booking_request. Не service_role — у того остаются все таблицы; не anon — ключ живёт в браузере, а параметры RPC были бы под контролем атакующего (0024, ADR-008 — тот же довод для bot_worker). JWT без sub заводит владелец, используется только в Next.js Server Actions.';


-- 2. booking_enabled: тумблер публикации центра -------------------------------------------------

create or replace function public.booking_published(p_center_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  -- center_writable (0050) здесь же — читать занятость/услуги read-only
  -- центра снаружи так же неуместно, как в него записывать; все три
  -- публичные функции витрины смотрят только на эту функцию, а не
  -- дублируют проверку каждая по-своему (архитектор, раунд 3, п.7).
  select exists (
    select 1 from public.centers c
     where c.id = p_center_id
       and c.deleted_at is null
       and coalesce((c.settings ->> 'booking_enabled')::boolean, false)
  ) and public.center_writable(p_center_id);
$$;

comment on function public.booking_published(uuid) is
  'Единственное место, где читается settings.booking_enabled (0057 Р3) — три публичные функции витрины зовут её, а не повторяют ->> сами.';

revoke all on function public.booking_published(uuid) from public, anon, authenticated, service_role;

create or replace function public.set_booking_enabled(p_enabled boolean)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- centers_protect_plan (0049) следит только за settings->'features' —
  -- слияние по одному ключу его не задевает.
  update public.centers
     set settings = settings || jsonb_build_object('booking_enabled', p_enabled)
   where id = v_center;
end;
$$;

comment on function public.set_booking_enabled(boolean) is
  'Публикация/снятие публичной витрины записи (0057 Р3) — действие того же веса, что и другие настройки центра, не прямой PATCH settings.';

revoke all on function public.set_booking_enabled(boolean) from public, anon, service_role;
grant execute on function public.set_booking_enabled(boolean) to authenticated;


-- 3. booking_requests -----------------------------------------------------------------------------

create table if not exists public.booking_requests (
  id                    uuid primary key default gen_random_uuid(),
  center_id             uuid not null references public.centers(id) on delete cascade,
  service_id            uuid not null,
  teacher_id            uuid not null,
  starts_at             timestamptz not null,
  ends_at               timestamptz not null,
  child_name            text not null,
  parent_name           text not null,
  parent_phone          text not null,
  status                text not null default 'new' check (status in ('new', 'confirmed', 'declined')),
  decline_reason        text,
  converted_student_id  uuid references public.students(id) on delete set null,
  converted_lesson_id   uuid references public.lessons(id) on delete set null,
  decided_by            uuid references auth.users(id) on delete set null,
  decided_at            timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,

  check (ends_at > starts_at),
  -- normalize_kg_phone на нераспознаваемой строке отдаёт null, а
  -- null = parent_phone тоже null — CHECK такое пропускает молча (NULL, не
  -- false). is not null форсирует именно отказ, не тихий пропуск.
  check (public.normalize_kg_phone(parent_phone) is not null and parent_phone = public.normalize_kg_phone(parent_phone)),
  check ((status = 'new') = (decided_at is null)),
  check (decline_reason is null or status = 'declined'),
  check (status = 'confirmed' or (converted_student_id is null and converted_lesson_id is null)),

  constraint booking_requests_service_fk foreign key (service_id, center_id)
    references public.services (id, center_id) on delete restrict,
  constraint booking_requests_teacher_fk foreign key (teacher_id, center_id)
    references public.teachers (id, center_id) on delete restrict
);

comment on table public.booking_requests is
  'Заявки с публичной витрины /book/[slug] (0057 Р1) — очередь на подтверждение, не мгновенная запись. Подтверждённая заявка превращается в students+lessons через confirm_booking_request.';
comment on column public.booking_requests.parent_phone is
  'Только нормализованный формат (normalize_kg_phone, 0005) — констрейнт, не соглашение: иначе rate limit по телефону сравнивает разные записи одного номера (0057 Р6).';

create index if not exists booking_requests_queue_idx on public.booking_requests (center_id, status, created_at desc);
create index if not exists booking_requests_phone_idx on public.booking_requests (parent_phone, created_at desc);

create trigger booking_requests_set_updated_at before update on public.booking_requests
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('booking_requests');
call public.apply_role_rls('booking_requests', 'registrar', 'read', true);
call public.apply_audit('booking_requests');
call public.apply_readonly_guard('booking_requests');

-- Р12: apply_tenant_rls даёт owner/admin RLS-политику "for all", но реальный
-- гейт — гранты ниже: без insert/update/delete-гранта write-политика не
-- открывает ничего. Все три перехода состояния — только через RPC.
revoke all on public.booking_requests from public, anon, authenticated;
grant select on public.booking_requests to authenticated;


-- 4. Публичное чтение: услуги/специалисты, занятость ----------------------------------------------

create or replace function public.booking_center_info(p_slug text)
  returns table (
    is_open     boolean,
    center_name text,
    timezone    text,
    services    jsonb,
    teachers    jsonb
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center public.centers;
begin
  -- Защита в глубину (0057 Р2): если authenticated случайно получит грант
  -- в будущей миграции, функция всё равно откажет — как emit_event_unchecked.
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_center from public.centers c where c.slug = p_slug;

  -- Неизвестный slug и неопубликованный/read-only/удалённый центр
  -- неотличимы намеренно (Р4) — как invitation_preview для неизвестного
  -- токена (0004). booking_published() уже включает center_writable (0050).
  if not found or not public.booking_published(v_center.id) then
    return query select false, null::text, null::text, null::jsonb, null::jsonb;
    return;
  end if;

  -- center_id намеренно не в ответе: весь публичный контур адресуется
  -- только по slug (booking_teacher_busy/submit_booking_request), внутренний
  -- идентификатор из app_metadata наружу выносить незачем.
  return query
    select
      true,
      v_center.name,
      public.center_timezone(v_center.id),
      coalesce((
        select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'duration_min', s.duration_min) order by s.name)
          from public.services s
         where s.center_id = v_center.id and s.is_active and s.deleted_at is null and s.kind = 'individual'
      ), '[]'::jsonb),
      coalesce((
        select jsonb_agg(jsonb_build_object('id', t.id, 'full_name', t.full_name) order by t.full_name)
          from public.teachers t
         where t.center_id = v_center.id and t.is_active and t.deleted_at is null
      ), '[]'::jsonb);
end;
$$;

comment on function public.booking_center_info(text) is
  'Публичное чтение витрины по slug (0057) — только активные индивидуальные услуги/специалисты, без телефонов, center_id и прочего лишнего. is_open=false для неизвестного/неопубликованного/read-only/удалённого центра — одинаково (Р4); колонка не названа found, чтобы не путать с plpgsql FOUND.';

revoke all on function public.booking_center_info(text) from public, anon, authenticated, service_role;
grant execute on function public.booking_center_info(text) to public_booking;


create or replace function public.booking_teacher_busy(p_slug text, p_teacher_id uuid, p_date date)
  returns table (starts_at timestamptz, ends_at timestamptz)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid;
  v_tz     text;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select c.id into v_center from public.centers c where c.slug = p_slug;
  if v_center is null or not public.booking_published(v_center) then
    return;
  end if;

  -- Специалист обязан принадлежать именно этому центру — иначе чужой
  -- teacher_id при своём slug превращает функцию в межцентровый оракул.
  if not exists (
    select 1 from public.teachers t
     where t.id = p_teacher_id and t.center_id = v_center and t.is_active and t.deleted_at is null
  ) then
    return;
  end if;

  v_tz := public.center_timezone(v_center);
  if p_date < public.center_today(v_center) or p_date > public.center_today(v_center) + 90 then
    return;
  end if;

  -- Режем по дате НАЧАЛА занятия в поясе центра — занятие, переходящее
  -- через полночь, не попадёт в сетку следующего дня. Осознанно не решаем:
  -- логопедическое занятие короче часа, через полночь в этом продукте не
  -- планируется; при подтверждении реальный конфликт всё равно ловит
  -- lesson_slot_conflicts/EXCLUDE, эта функция только подсказка UI.
  return query
    select l.starts_at, l.ends_at
      from public.lessons l
     where l.center_id = v_center
       and l.effective_teacher_id = p_teacher_id
       and l.deleted_at is null
       and l.status <> 'cancelled'
       and (l.starts_at at time zone v_tz)::date = p_date;
end;
$$;

comment on function public.booking_teacher_busy(text, uuid, date) is
  'Занятые интервалы специалиста на дату (0057) — только starts_at/ends_at, без student_id и имён. Дата — только [сегодня центра; +90 дней], день режется в поясе центра (center_timezone), не UTC.';

revoke all on function public.booking_teacher_busy(text, uuid, date) from public, anon, authenticated, service_role;
grant execute on function public.booking_teacher_busy(text, uuid, date) to public_booking;


-- 5. Подача заявки ---------------------------------------------------------------------------------

create or replace function public.submit_booking_request(
  p_slug         text,
  p_service_id   uuid,
  p_teacher_id   uuid,
  p_starts_at    timestamptz,
  p_child_name   text,
  p_parent_name  text,
  p_parent_phone text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid;
  v_duration integer;
  v_ends_at  timestamptz;
  v_phone    text;
  v_id       uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select c.id into v_center from public.centers c where c.slug = p_slug;

  -- Один и тот же отказ для «нет такого slug», «не опубликован», «read-only/
  -- просрочен» (booking_published уже включает center_writable, 0050) —
  -- публичная форма не обязана объяснять постороннему, что именно не так
  -- с чужим центром (Р4).
  if v_center is null or not public.booking_published(v_center) then
    raise exception 'Запись сейчас недоступна' using errcode = '22023';
  end if;

  select s.duration_min into v_duration
    from public.services s
   where s.id = p_service_id and s.center_id = v_center and s.is_active and s.deleted_at is null;
  if not found then
    raise exception 'Запись сейчас недоступна' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.teachers t
     where t.id = p_teacher_id and t.center_id = v_center and t.is_active and t.deleted_at is null
  ) then
    raise exception 'Запись сейчас недоступна' using errcode = '22023';
  end if;

  if p_starts_at < now() + interval '30 minutes' or p_starts_at > now() + interval '90 days' then
    raise exception 'Выберите время не раньше чем через 30 минут и не дальше 90 дней от сегодня' using errcode = '22023';
  end if;

  v_phone := public.normalize_kg_phone(p_parent_phone);
  if v_phone is null then
    raise exception 'Укажите номер телефона в кыргызском формате' using errcode = '22023';
  end if;
  if coalesce(trim(p_child_name), '') = '' or coalesce(trim(p_parent_name), '') = '' then
    raise exception 'Укажите имя ребёнка и имя родителя' using errcode = '22023';
  end if;

  -- Р8: без отдельной attempts-таблицы — считает сами заявки. Отказ не
  -- пишет строку, значит и не учитывается лимитом; это осознанно (Р8), не
  -- полная защита от перебора, а адресная (телефон, в границах ЭТОГО
  -- центра — общий лимит по всем центрам одним номером превращал бы
  -- очередь одного центра в отказ доступа к другому, находка архитектора)
  -- плюс мягкий backstop (центр). count(*) и insert — два разных
  -- оператора; без advisory-lock параллельные заявки читают один и тот же
  -- счётчик до чужого коммита и лимит по телефону не держит вовсе —
  -- сериализуем по (телефон, центр). Центровой лимит НЕ сериализован
  -- намеренно: блокировка на весь центр на каждую заявку убила бы
  -- параллельную пропускную способность ради мягкого backstop, которым он
  -- и задуман (при параллельной атаке он превращается в 20×N — известное,
  -- принятое ограничение, не полная защита).
  perform pg_advisory_xact_lock(hashtext(v_phone || ':' || v_center::text)::bigint);

  if (
    select count(*) from public.booking_requests
     where center_id = v_center and created_at > now() - interval '1 hour'
  ) >= 20 then
    raise exception 'Слишком много заявок на этот центр, попробуйте позже' using errcode = '22023';
  end if;
  if (
    select count(*) from public.booking_requests
     where center_id = v_center and parent_phone = v_phone and created_at > now() - interval '1 hour'
  ) >= 3 then
    raise exception 'Слишком много заявок с этого номера, попробуйте позже' using errcode = '22023';
  end if;

  v_ends_at := p_starts_at + (v_duration * interval '1 minute');

  insert into public.booking_requests (
    center_id, service_id, teacher_id, starts_at, ends_at, child_name, parent_name, parent_phone
  ) values (
    v_center, p_service_id, p_teacher_id, p_starts_at, v_ends_at, trim(p_child_name), trim(p_parent_name), v_phone
  )
  returning id into v_id;

  -- emit_event (0002) требует auth.uid() is not null — здесь его нет и не
  -- будет; emit_event_unchecked (0018) — обратное условие, для no-session
  -- контекстов вроде bot_worker.
  perform public.emit_event_unchecked(
    'booking.requested',
    jsonb_build_object('request_id', v_id, 'teacher_id', p_teacher_id, 'service_id', p_service_id, 'starts_at', p_starts_at),
    v_center
  );

  return v_id;
end;
$$;

comment on function public.submit_booking_request(text, uuid, uuid, timestamptz, text, text, text) is
  'Подача заявки с публичной витрины (0057) — только booking_requests, ни students, ни lessons не трогает (Р1). Rate limit по телефону и мягкий по центру — без отдельной attempts-таблицы (Р8).';

revoke all on function public.submit_booking_request(text, uuid, uuid, timestamptz, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.submit_booking_request(text, uuid, uuid, timestamptz, text, text, text) to public_booking;


-- 6. Подтверждение и отклонение (стойка) -----------------------------------------------------------

create or replace function public.notification_front_desk_targets(p_center_id uuid, p_event_type text)
  returns table (user_id uuid, channel text, chat_id bigint, template_text text)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select m.user_id,
         case when a.chat_id is null then 'whatsapp_link' else 'telegram' end,
         a.chat_id,
         rt.message_text
    from public.memberships m
    left join public.telegram_accounts a
           on a.user_id = m.user_id and a.unlinked_at is null
    join lateral public.resolve_template(
           p_center_id, p_event_type,
           case when a.chat_id is null then 'whatsapp_link' else 'telegram' end
         ) rt on true
   where m.center_id = p_center_id
     and m.role in ('owner', 'admin', 'registrar')
     and rt.should_send;
$$;

comment on function public.notification_front_desk_targets(uuid, text) is
  'Получатели заявок с витрины записи (0057 Р11) — владелец, администраторы И регистратор: копия notification_admin_targets (0037, ПОСЛЕДНЕЙ версии — через resolve_template/should_send, не ранней 0034 с is_active в фильтре до order by, тот порядок давал побег на дефолт вместо «не слать», 0037 Р2) с расширенным списком ролей.';

revoke all on function public.notification_front_desk_targets(uuid, text) from public, anon, authenticated, service_role;


create or replace function public.booking_request_payer_match(p_request_id uuid)
  returns table (payer_id uuid, payer_name text)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_req    public.booking_requests;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_req from public.booking_requests where id = p_request_id and center_id = v_center;
  if not found then
    raise exception 'Заявка не найдена' using errcode = '42704';
  end if;

  return query
    select p.id, p.full_name
      from public.payers p
     where p.center_id = v_center and p.deleted_at is null
       -- Тем же выражением, что уникальный индекс payers_center_phone_uniq
       -- (0005) — иначе предпросмотр говорит «совпадений нет», а вставка в
       -- confirm_booking_request всё равно падает на индексе (архитектор,
       -- раунд 3, п.4): существующий payers.phone не обязан быть в
       -- нормализованном виде, v_req.parent_phone — обязан (CHECK, Р6).
       and public.normalize_kg_phone(p.phone) = v_req.parent_phone;
end;
$$;

comment on function public.booking_request_payer_match(uuid) is
  'Предпросмотр совпадения по телефону перед подтверждением (0057 Р5) — стойка видит совпадение и решает сама, привязать к нему или завести нового; confirm_booking_request не матчит неявно.';

revoke all on function public.booking_request_payer_match(uuid) from public, anon, service_role;
grant execute on function public.booking_request_payer_match(uuid) to authenticated;


create or replace function public.confirm_booking_request(p_request_id uuid, p_payer_id uuid default null)
  returns table (student_id uuid, lesson_id uuid)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_req       public.booking_requests;
  v_conflicts jsonb;
  v_payer     uuid;
  v_student   uuid;
  v_lesson    uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р13: атомарный захват ДО создания чего-либо — два одновременных
  -- подтверждения не порождают два урока по одной заявке. Если дальше
  -- что-то упадёт, откат транзакции вернёт status в 'new' вместе со всем
  -- остальным.
  update public.booking_requests
     set status = 'confirmed', decided_by = auth.uid(), decided_at = now()
   where id = p_request_id and center_id = v_center and status = 'new'
  returning * into v_req;

  if not found then
    raise exception 'Заявка уже обработана' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.teachers t
     where t.id = v_req.teacher_id and t.center_id = v_center and t.is_active and t.deleted_at is null
  ) then
    raise exception 'Специалист из заявки больше не активен — свяжитесь с родителем и создайте занятие вручную' using errcode = '22023';
  end if;

  -- Р5: матчинг по телефону — не здесь. p_payer_id null означает, что
  -- стойка осознанно создаёт нового плательщика текстом заявки (не
  -- create_student_with_payer, чтобы её собственный поиск по телефону не
  -- сработал в этом пути).
  if p_payer_id is not null then
    if not exists (select 1 from public.payers where id = p_payer_id and center_id = v_center and deleted_at is null) then
      raise exception 'Плательщик не найден в этом центре' using errcode = '22023';
    end if;
    v_payer := p_payer_id;
  else
    begin
      insert into public.payers (center_id, full_name, phone)
      values (v_center, v_req.parent_name, v_req.parent_phone)
      returning id into v_payer;
    exception when unique_violation then
      -- payers_center_phone_uniq (0005) — самый обычный случай: у этого
      -- родителя уже есть карточка (второй ребёнок), а стойка не
      -- воспользовалась booking_request_payer_match. Откат уже вернул
      -- booking_requests в 'new' (вся транзакция) — понятный отказ вместо
      -- голого 23505 (архитектор, раунд 3, п.4).
      raise exception 'По этому номеру уже есть плательщик — выберите его в списке совпадений и подтвердите заново'
        using errcode = '22023';
    end;

    perform public.emit_event('payer.created',
      jsonb_build_object('center_id', v_center, 'payer_id', v_payer, 'full_name', v_req.parent_name), v_center);
  end if;

  select cs.student_id into v_student
    from public.create_student_with_payer(
      p_full_name          := v_req.child_name,
      p_payer_id           := v_payer,
      p_primary_teacher_id := v_req.teacher_id,
      p_source             := 'booking_widget',
      p_funnel_stage       := 'lead'
    ) cs;

  -- Тот же приём, что reschedule_lesson (0011/0006): пересчитать конфликты
  -- заранее понятным текстом, а сам insert обернуть на случай гонки с
  -- параллельным confirm/созданием урока вручную.
  v_conflicts := public.lesson_slot_conflicts(v_center, v_req.teacher_id, null, null, null, v_req.starts_at, v_req.ends_at, null);
  if jsonb_array_length(v_conflicts) > 0 then
    raise exception 'Слот уже занят'
      using errcode = '23P01',
            detail = jsonb_build_array(jsonb_build_object(
              'day', v_req.starts_at::date, 'starts_at', v_req.starts_at, 'conflicts', v_conflicts))::text;
  end if;

  begin
    insert into public.lessons (center_id, service_id, teacher_id, student_id, starts_at, ends_at, status)
    values (v_center, v_req.service_id, v_req.teacher_id, v_student, v_req.starts_at, v_req.ends_at, 'planned')
    returning id into v_lesson;
  exception when exclusion_violation then
    v_conflicts := public.lesson_slot_conflicts(v_center, v_req.teacher_id, null, null, null, v_req.starts_at, v_req.ends_at, null);
    if jsonb_array_length(v_conflicts) = 0 then
      raise exception 'Слот был занят на момент сохранения, попробуйте ещё раз' using errcode = '23P01';
    end if;
    raise exception 'Слот уже занят'
      using errcode = '23P01',
            detail = jsonb_build_array(jsonb_build_object(
              'day', v_req.starts_at::date, 'starts_at', v_req.starts_at, 'conflicts', v_conflicts))::text;
  end;

  -- create_lesson_series эмитит lesson.created на каждый вставленный урок
  -- (0006) — этот путь вставляет урок напрямую и не должен молчать перед
  -- теми же потребителями события (архитектор, раунд 3, п.10).
  perform public.emit_event('lesson.created',
    jsonb_build_object('center_id', v_center, 'lesson_id', v_lesson, 'series_id', null, 'starts_at', v_req.starts_at),
    v_center);

  update public.booking_requests
     set converted_student_id = v_student, converted_lesson_id = v_lesson
   where id = p_request_id;

  return query select v_student, v_lesson;
end;
$$;

comment on function public.confirm_booking_request(uuid, uuid) is
  'Подтверждение заявки (0057 Р13) — атомарный захват (status=new→confirmed) раньше самого создания, иначе двойное подтверждение создаёт два урока. p_payer_id — явный выбор стойки (Р5), не неявный матчинг.';

revoke all on function public.confirm_booking_request(uuid, uuid) from public, anon, service_role;
grant execute on function public.confirm_booking_request(uuid, uuid) to authenticated;


create or replace function public.decline_booking_request(p_request_id uuid, p_reason text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.booking_requests
     set status = 'declined', decline_reason = p_reason, decided_by = auth.uid(), decided_at = now()
   where id = p_request_id and center_id = v_center and status = 'new';

  if not found then
    raise exception 'Заявка уже обработана' using errcode = '22023';
  end if;
end;
$$;

comment on function public.decline_booking_request(uuid, text) is
  'Отклонение заявки (0057) — тот же атомарный захват по status=new, что и confirm_booking_request.';

revoke all on function public.decline_booking_request(uuid, text) from public, anon, service_role;
grant execute on function public.decline_booking_request(uuid, text) to authenticated;


-- 7. Уведомление стойке -----------------------------------------------------------------------------

insert into public.notification_event_types (event_type, description, audience, subject_required, channels, mandatory) values
  ('booking.requested', 'Новая заявка с публичной витрины записи', 'center', false, '{telegram,whatsapp_link}', false)
on conflict (event_type) do update set
  audience = excluded.audience, subject_required = excluded.subject_required,
  channels = excluded.channels, mandatory = excluded.mandatory;

insert into public.message_templates (center_id, event_type, channel, text)
select v.center_id, v.event_type, v.channel, v.text from (values
  (null::uuid, 'booking.requested', 'telegram',
   'Новая заявка на запись: {child} к {teacher} на {when}. Телефон: {phone}. Подтвердите в CRM.'),
  (null::uuid, 'booking.requested', 'whatsapp_link',
   'Новая заявка на запись: {child} к {teacher} на {when}. Телефон: {phone}. Подтвердите в CRM.')
) as v(center_id, event_type, channel, text)
where not exists (
  select 1 from public.message_templates m
   where m.center_id is null and m.event_type = v.event_type and m.channel = v.channel and m.deleted_at is null
);


-- event_messages(bigint) — переиздаётся целиком от последней версии (0056):
-- поиск "create or replace function public.event_messages" по всем
-- миграциям, не по памяти (правило этой сессии — 0055 однажды откатывала
-- чужие ветки именно так).
create or replace function public.event_messages(p_event_id bigint)
  returns table (
    recipient_user_id uuid,
    channel           text,
    chat_id           bigint,
    message           text,
    subject_id        uuid,
    action            jsonb
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_event    public.events;
  v_tz       text;
  v_vars     jsonb := '{}'::jsonb;
  v_student  uuid;
  v_payer    uuid;
  v_lesson   record;
  v_homework public.homework;
  v_note     public.lesson_notes;
  v_request  public.lesson_voice_requests;
  v_child    text;
  v_summary  text;
  v_days     integer;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if not found then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  v_tz := public.center_timezone(v_event.center_id);

  -- 0053 Р8/Р10: лимит голосовых резюме — заказчику диктовки ({child} только
  -- в telegram, с предлогом внутри) и owner/admin центра (без {child}, без
  -- subject), пока повтор диктовки имеет смысл (0047 Р4). Заказчик-владелец
  -- не получает двух строк.
  if v_event.type = 'ai.quota_exceeded' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    v_vars := jsonb_build_object(
      'used',  coalesce(v_event.payload ->> 'used', ''),
      'limit', coalesce(v_event.payload ->> 'limit', '')
    );

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               v_vars || jsonb_build_object('child',
                 case when r.channel = 'telegram' then ' по ' || v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r
      union all
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', '')),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r
       where r.user_id <> v_request.requested_by;
    return;
  end if;

  -- 0052: срок заканчивается / истёк — owner/admin центра. {when} и {until}
  -- считаются на момент доставки в поясе центра (Р6).
  if v_event.type in ('subscription.ending', 'subscription.expired') then
    v_days := ((v_event.payload ->> 'until')::timestamptz at time zone v_tz)::date
              - (now() at time zone v_tz)::date;
    v_vars := jsonb_build_object(
      'what',  case when (v_event.payload ->> 'is_trial')::boolean then 'Пробный период' else 'Подписка' end,
      'until', to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY')
    );
    -- {when} есть только у «заканчивается»: у истёкшего срока «сегодня» врало бы.
    if v_event.type = 'subscription.ending' then
      v_vars := v_vars || jsonb_build_object('when', case
                 when v_days <= 0 then 'сегодня'
                 when v_days = 1 then 'завтра'
                 else 'через ' || v_days::text || ' дн.'
               end);
    end if;
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0051: заявка на оплату — администраторам платформы, шаблон только
  -- дефолтный (Р10), суммы и пояс — центра-заявителя (Р12).
  if v_event.type = 'platform.payment_submitted' then
    v_vars := jsonb_build_object(
      'center_name', coalesce((select c.name from public.centers c where c.id = v_event.center_id), '—'),
      'plan_name',   coalesce((select p.name from public.plans p where p.code = v_event.payload ->> 'plan'), coalesce(v_event.payload ->> 'plan', '—')),
      'months',      coalesce(v_event.payload ->> 'months', ''),
      'amount',      public.format_som(coalesce((v_event.payload ->> 'amount_tiyin')::bigint, 0)),
      'source',      case v_event.payload ->> 'source'
                       when 'mbank' then 'Mbank' when 'elcart' then 'Elcart'
                       when 'cash' then 'наличные' else 'другое' end,
      'payment_id',  coalesce(v_event.payload ->> 'payment_id', '')
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_platform_targets(v_event.type) r;
    return;
  end if;

  -- 0051: продление — owner/admin центра; {until} в поясе центра (Р12).
  if v_event.type = 'subscription.extended' then
    v_vars := jsonb_build_object(
      'plan_name', coalesce((select p.name from public.plans p where p.code = v_event.payload ->> 'plan'), coalesce(v_event.payload ->> 'plan', '—')),
      'months',    coalesce(v_event.payload ->> 'months', ''),
      'until',     coalesce(to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY'), '—')
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0056: заявка на удаление центра — owner/admin (в т.ч. второй владелец,
  -- который её не подавал), без {until}.
  if v_event.type = 'center.deletion_requested' then
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, '{}'::jsonb),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0057: заявка с публичной витрины записи — стойке (owner/admin/
  -- registrar, notification_front_desk_targets — не notification_admin_
  -- targets, регистратор реально разбирает очередь). {child}/{teacher}/
  -- {when}/{phone} читаются заново на момент доставки, не из payload —
  -- заявку могли обработать до отправки, а специалиста переименовать.
  if v_event.type = 'booking.requested' then
    declare
      v_booking      public.booking_requests;
      v_teacher_name text;
    begin
      -- emit_event открыта authenticated и проверяет только center_id
      -- аргумента — payload не доверенный ключ, откуда читать. Без фильтра
      -- по center_id участник центра X мог бы эмитировать событие с
      -- request_id чужой заявки и получить в свой телеграм имя ребёнка и
      -- телефон родителя центра Y (архитектор, раунд 3, п.3).
      select * into v_booking from public.booking_requests
       where id = (v_event.payload ->> 'request_id')::uuid
         and center_id = v_event.center_id
         and deleted_at is null;
      if not found then
        return;
      end if;

      select t.full_name into v_teacher_name from public.teachers t where t.id = v_booking.teacher_id;

      v_vars := jsonb_build_object(
        'child', v_booking.child_name,
        'teacher', coalesce(v_teacher_name, 'специалист'),
        'when', to_char(v_booking.starts_at at time zone v_tz, 'DD.MM HH24:MI'),
        'phone', v_booking.parent_phone
      );

      return query
        select r.user_id, r.channel, r.chat_id,
               public.render_template(r.template_text, v_vars),
               null::uuid,
               null::jsonb
          from public.notification_front_desk_targets(v_event.center_id, v_event.type) r;
      return;
    end;
  end if;

  -- 0051 Р9: подписка истекла между диктовкой и обработкой — заказчику
  -- диктовки, если он всё ещё сотрудник (0047 Р2) и повтор диктовки ещё
  -- имеет смысл (0047 Р4, дословно как у lesson.voice_failed — текст просит
  -- записать заново, и просить это при утверждённой заметке нельзя).
  -- {child} только в telegram.
  if v_event.type = 'subscription.voice_blocked' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               jsonb_build_object('child',
                 case when r.channel = 'telegram' then v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r;
    return;
  end if;

  if v_event.type = 'lesson.reminder' then
    select l.starts_at, l.status, l.deleted_at, coalesce(t.full_name, '—') as teacher
      into v_lesson
      from public.lessons l
      left join public.teachers t on t.id = l.effective_teacher_id
     where l.id = (v_event.payload ->> 'lesson_id')::uuid;

    if not found or v_lesson.deleted_at is not null or v_lesson.status <> 'planned' then
      return;
    end if;

    v_vars := jsonb_build_object(
      'date',    to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY'),
      'time',    to_char(v_lesson.starts_at at time zone v_tz, 'HH24:MI'),
      'teacher', v_lesson.teacher
    );

    return query
      with participants as (
        select lp.student_id, s.full_name, s.payer_id
          from public.lesson_participants lp
          join public.students s on s.id = lp.student_id and s.deleted_at is null
         where lp.lesson_id = (v_event.payload ->> 'lesson_id')::uuid
           and lp.deleted_at is null
      )
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', p.full_name)),
             p.student_id,
             case when r.chat_id is null then null else jsonb_build_object(
               'label', 'Подтвердить приход',
               'callback_data', 'c:' || v_event.id::text || ':' || p.student_id::text
             ) end
        from participants p
        join lateral public.notification_targets(v_event.center_id, p.payer_id, v_event.type) r on true;
    return;
  end if;

  -- 0043: месячный отчёт. Текст уже заморожен в событии (Р4 из 0043) —
  -- здесь он только подставляется, ничего не пересчитывается.
  if v_event.type = 'report.monthly_ready' then
    v_student := (v_event.payload ->> 'student_id')::uuid;

    select s.payer_id into v_payer
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    -- 0047 Р10: текст отчёта — только в telegram, вне его пусто.
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'summary', case when r.channel = 'telegram'
                               then coalesce(v_event.payload ->> 'summary', '') else '' end,
               'month',   to_char((v_event.payload ->> 'period_month')::date, 'MM.YYYY'),
               'child',   (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0047: утверждённое резюме — родителю. Перечитывается на момент
  -- доставки (Р4); {summary} только в telegram (Р1); длина ограничена (Р5).
  if v_event.type = 'lesson.note_approved' then
    select * into v_note from public.lesson_notes n
     where n.id = (v_event.payload ->> 'lesson_note_id')::uuid
       and n.center_id = v_event.center_id
       and n.deleted_at is null
       and n.status = 'approved';
    if not found or coalesce(trim(v_note.parent_summary), '') = '' then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_note.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_note.student_id;
    select s.payer_id, s.full_name into v_payer, v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    v_summary := case
      when length(v_note.parent_summary) > 3500 then left(v_note.parent_summary, 3499) || '…'
      else v_note.parent_summary
    end;
    v_vars := jsonb_build_object(
      'child', v_child,
      'date',  to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY')
    );

    -- Р1: вне telegram переменная пуста, а не отсутствует — иначе
    -- render_template оставит «{summary}» буквально.
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               v_vars || jsonb_build_object('summary',
                 case when r.channel = 'telegram' then v_summary else '' end)),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0047: отказ обработки диктовки — заказчику диктовки, если он всё ещё
  -- сотрудник центра (Р2) и повтор диктовки ещё имеет смысл (Р4).
  -- Причина отказа в текст не идёт (Р6).
  if v_event.type = 'lesson.voice_failed' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    -- Р4: дословно условие отказа ai_job_begin (0042) — утверждено или
    -- голосовой черновик другой диктовки. Ручной черновик не гасит.
    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               jsonb_build_object('child',
                 case when r.channel = 'telegram' then v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r;
    return;
  end if;

  -- 0045: выдано родителю. Шлём независимо от текущего статуса задания —
  -- факт выдачи не перестаёт быть фактом, даже если уже сдано (Р4).
  if v_event.type = 'homework.assigned' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student),
               'due',   coalesce(to_char(v_homework.due_on, 'DD.MM.YYYY'), 'без срока')
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0045: специалисту, что сдано. Шлём, только если статус ВСЁ ЕЩЁ
  -- submitted — напоминание «проверьте» после того, как уже проверено,
  -- вводит в заблуждение (Р4, в отличие от assigned выше).
  if v_event.type = 'homework.submitted' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found or v_homework.status <> 'submitted' then
      return;
    end if;

    v_student := v_homework.student_id;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_homework_targets(v_event.center_id, v_homework.id, v_event.type) r;
    return;
  end if;

  -- 0045: специалист проверил — родителю.
  if v_event.type = 'homework.reviewed' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  if v_event.type in ('subscription.low_balance', 'subscription.exhausted', 'student.absent_streak') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'left',  coalesce(v_event.payload ->> 'lessons_left', ''),
      'count', coalesce(v_event.payload ->> 'length', '')
    );
  elsif v_event.type in ('installment.due', 'installment.overdue') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'amount', public.format_som((v_event.payload ->> 'amount_tiyin')::bigint),
      'date',   to_char((v_event.payload ->> 'due_date')::date, 'DD.MM.YYYY')
    );
  elsif v_event.type = 'digest.daily' then
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'date',    to_char((v_event.payload ->> 'date')::date, 'DD.MM.YYYY'),
               'lessons', coalesce(v_event.payload ->> 'lessons_today', '0'),
               'low',     coalesce(v_event.payload ->> 'low_balance', '0'),
               'debt',    public.format_som(coalesce((v_event.payload ->> 'debt_tiyin')::bigint, 0)),
               'overdue', coalesce(v_event.payload ->> 'installments_overdue', '0')
             )),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  else
    return;
  end if;

  select s.payer_id into v_payer
    from public.students s
   where s.id = v_student and s.deleted_at is null;

  if v_payer is null then
    return;
  end if;

  return query
    select r.user_id, r.channel, r.chat_id,
           public.render_template(r.template_text, v_vars || jsonb_build_object(
             'child', (select s.full_name from public.students s where s.id = v_student))),
           v_student,
           null::jsonb
      from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
end;
$$;

comment on function public.event_messages(bigint) is
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4), с 0047 — только в telegram. Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. lesson.note_approved (0047) — резюме родителю, {summary} только в telegram и не длиннее 3500 символов; lesson.voice_failed (0047) — заказчику диктовки через notification_user_targets, без причины отказа и только пока повтор диктовки имеет смысл (условие ai_job_begin). 0051: platform.payment_submitted — администраторам платформы (notification_platform_targets, шаблон только дефолтный), subscription.extended — owner/admin центра с {until} в поясе центра, subscription.voice_blocked — заказчику диктовки, {child} только в telegram. 0052: subscription.ending/expired — owner/admin центра, {what}/{until}/{when} на момент доставки в поясе центра. 0053: ai.quota_exceeded — заказчику диктовки ({child} с предлогом, только telegram) и owner/admin центра без {child}, {used}/{limit} в оба канала, пока повтор диктовки имеет смысл. 0056: center.deletion_requested — owner/admin центра, без переменных. 0057: booking.requested — стойке (owner/admin/registrar) через notification_front_desk_targets, {child}/{teacher}/{when}/{phone} читаются заново из booking_requests на момент доставки, не из payload. Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;


-- 8. Экспорт центра: заявки — те же персональные данные, что students -------------------------------

create or replace function public.export_center_tables()
  returns table (table_name text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('attendance'), ('attendance_statuses'), ('booking_requests'), ('diagnostics'), ('exercise_library'),
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
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny», иначе новая таблица с center_id молча попадала бы в выгрузку. 0057: booking_requests добавлена — текст заявки (имя ребёнка, телефон родителя) те же персональные данные, что и в students. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
