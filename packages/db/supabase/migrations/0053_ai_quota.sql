-- =============================================================================
-- 0053_ai_quota.sql — квота голосовых резюме по тарифу (этап 8a, шаг 5)
--
-- План — reports/stage-8.md («Квота ИИ (ревью)»); ревью плана архитектором
-- 22.09.2026 (14 находок) — ниже как Р-условия.
--
--   Р1. Квота — гейт в горловине, не инвариант на реестре: единственный
--       путь к платному вызову — ai_job_begin (грант только bot_worker),
--       единственный писатель ai_usage — ai_usage_record (0041). Триггер на
--       ai_usage был бы вреден: отказ во вставке — потраченные и
--       неучтённые деньги. Забор pgTAP: на ai_usage нет гранта на запись.
--
--   Р2. В ai_job_begin квота — булев исход, не исключение: контракт n8n —
--       «null / объект», третий исход (ошибка) подвешивает событие на 24 часа
--       через release_stale_claims. Тарифа нет или ключа лимита нет — fail
--       closed: null без события. raise живёт только в assert_ai_quota для
--       request_voice_note, где есть сессия и место для русского текста.
--
--   Р3. Счёт: оплаченное (ai_usage kind = 'summary' за месяц в поясе
--       центра) плюс резерв — работы ai_jobs status = 'running' не старше
--       8 минут (порог, которым ai_job_begin считает прогон живым; старше —
--       работа перезахватываема и «в полёте» не считается) и без строки
--       summary по своему event_id. Своя работа при перезахвате исключается
--       (p_exclude_event_id). Экран и текст отказа резерв не видят: они
--       показывают только оплаченное — числа, которых нет в реестре, не
--       называются.
--
--   Р4. Гонка двух прогонов одного центра: pg_advisory_xact_lock тем же
--       ключом, что лимиты 0049 (center_limit:<center>), перед счётом и до
--       insert ai_jobs — замок держится до коммита вставки, дальше резерв
--       держит сама строка работы. В request_voice_note замка нет намеренно:
--       это ранняя подсказка, а не точка учёта.
--
--   Р5. Граница месяца — одна функция center_month_start(center) → timestamptz
--       в поясе центра; предикат created_at >= … ложится на индекс
--       ai_usage (center_id, created_at). center_limits (0050) переиздана
--       на тот же счётчик — экран, текст и гейт не разъезжаются.
--
--   Р6. В request_voice_note отказ — до гашения прежнего токена: иначе отказ
--       по квоте убивал бы живую ссылку, а новую получить нельзя.
--
--   Р7. Текст отказа — по адресату: owner/admin — «подайте заявку на другой
--       тариф на экране «Тариф и оплата»», остальным — «сообщите владельцу
--       центра»; имя тарифа — center_plan_name, не код.
--
--   Р8. Про упёртый лимит узнаёт и тот, кто платит: событие ai.quota_exceeded
--       идёт заказчику диктовки (с {child} только в telegram) и owner/admin
--       центра (без {child}), один раз на диктовку (unique
--       events_quota_exceeded_once). subject_required = false: строки
--       владельцу — не о ребёнке.
--
--   Р9. Отказ по квоте терминален, как subscription.voice_blocked: n8n делает
--       ack, после смены тарифа диктовку нужно записать заново — текст
--       шаблона это говорит.
--
--   Р10. {used}/{limit} — не персональные данные, идут в оба канала;
--        {child} — только telegram (0047 Р1), с предлогом внутри переменной
--        (« по Имя»), чтобы текст без ребёнка не рвался.
--
--   Отступление (в отчёт): перезахват после зависания даёт второй вызов
--   модели, но ai_usage_event_kind_key (0042) не пускает вторую строку
--   summary — счётчик занижает на такую работу. Реестр не трогаем здесь.

-- 1. Счёт (Р3, Р5) -----------------------------------------------------------------------------------------

create or replace function public.center_month_start(p_center_id uuid)
  returns timestamptz
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select (date_trunc('month', public.center_today(p_center_id))::date::timestamp)
           at time zone public.center_timezone(p_center_id);
$$;

comment on function public.center_month_start(uuid) is
  'Начало календарного месяца центра в его поясе, timestamptz — одна граница для квоты ИИ, экрана тарифа и гейта (0053 Р5). Без проверки auth.uid()/членства — как plan_limit и center_plan_name (0049): зовётся только изнутри definer-функций, гранта нет ни одной роли.';

revoke all on function public.center_month_start(uuid) from public, anon, authenticated, service_role;

create or replace function public.center_ai_notes_used(p_center_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select count(*)::integer
    from public.ai_usage u
   where u.center_id = p_center_id
     and u.kind = 'summary'
     and u.created_at >= public.center_month_start(p_center_id);
$$;

comment on function public.center_ai_notes_used(uuid) is
  'Оплаченные голосовые резюме центра за текущий месяц в его поясе (0053 Р3). Резерв работ в полёте сюда не входит — экран и текст показывают только реестр. Без проверки auth.uid()/членства — как plan_limit (0049): зовётся только изнутри definer-функций.';

revoke all on function public.center_ai_notes_used(uuid) from public, anon, authenticated, service_role;

create or replace function public.ai_notes_reserved(p_center_id uuid, p_exclude_event_id bigint default null)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select count(*)::integer
    from public.ai_jobs j
   where j.center_id = p_center_id
     and j.status = 'running'
     and j.started_at > now() - interval '8 minutes'
     and (p_exclude_event_id is null or j.event_id <> p_exclude_event_id)
     and not exists (
       select 1 from public.ai_usage u where u.event_id = j.event_id and u.kind = 'summary');
$$;

comment on function public.ai_notes_reserved(uuid, bigint) is
  'Работы в полёте, ещё не оплаченные (0053 Р3): running не старше 8 минут без строки summary; своя работа при перезахвате исключается. Без проверки auth.uid()/членства — зовётся только изнутри ai_job_begin (bot_worker, нет сессии).';

revoke all on function public.ai_notes_reserved(uuid, bigint) from public, anon, authenticated, service_role;

create or replace function public.assert_ai_quota(p_center_id uuid)
  returns void
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_limit integer := public.plan_limit(p_center_id, 'ai_notes_month');
  v_used  integer;
begin
  if v_limit < 0 then
    return;
  end if;
  v_used := public.center_ai_notes_used(p_center_id);
  if v_used < v_limit then
    return;
  end if;

  -- Р7: текст по адресату, имя тарифа — не код.
  if coalesce(public.my_role(), '') in ('owner', 'admin') then
    raise exception 'Лимит голосовых резюме на этот месяц исчерпан: % из % по тарифу %. Подайте заявку на другой тариф на экране «Тариф и оплата» или подождите до следующего месяца',
      v_used, v_limit, public.center_plan_name(p_center_id)
      using errcode = '23514';
  end if;
  raise exception 'Лимит голосовых резюме на этот месяц исчерпан: % из % по тарифу %. Сообщите владельцу центра — лимит снимает смена тарифа',
    v_used, v_limit, public.center_plan_name(p_center_id)
    using errcode = '23514';
end;
$$;

comment on function public.assert_ai_quota(uuid) is
  'Раздутый вариант center_ai_notes_used с текстом отказа (0053 Р2/Р7). Без проверки auth.uid()/центра — зовётся только из request_voice_note с v_center = current_center() своей же сессии.';

revoke all on function public.assert_ai_quota(uuid) from public, anon, authenticated, service_role;


-- 2. request_voice_note — из 0042, добавлена одна строка (Р6) ------------------------------------------------

create or replace function public.request_voice_note(p_lesson_id uuid, p_student_id uuid)
  returns text
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_role    text := coalesce(public.my_role(), '');
  v_uid     uuid := auth.uid();
  v_lesson  public.lessons;
  v_token   text;
begin
  if v_uid is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_lesson from public.lessons
   where id = p_lesson_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;
  if v_lesson.status = 'cancelled' then
    raise exception 'Занятие отменено' using errcode = '22023';
  end if;

  -- Р2: owner/admin тоже, а не только ведущий специалист — администратор
  -- закрывает занятие за заболевшего (0039 Р9).
  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(p_student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Всё, что можно отбить бесплатно, отбивается здесь: иначе отказ придёт
  -- после Whisper и Claude, то есть деньгами.
  if not exists (
    select 1 from public.lesson_participants lp
     where lp.lesson_id = p_lesson_id and lp.student_id = p_student_id and lp.deleted_at is null
  ) then
    raise exception 'Ребёнка нет в составе занятия' using errcode = '42704';
  end if;

  if exists (
    select 1 from public.lesson_notes n
     where n.lesson_id = p_lesson_id and n.student_id = p_student_id
       and n.deleted_at is null and n.status = 'approved'
  ) then
    raise exception 'Заметка уже утверждена — заведите новую на следующем занятии'
      using errcode = '23514';
  end if;

  -- 0053 Р6/Р7: квота — последняя из проверок и до первой записи: отказ
  -- не должен гасить прежний живой токен. Только оплаченное, без замка (Р4).
  perform public.assert_ai_quota(v_center);

  -- Р9: прежний живой токен гасится, иначе старая ссылка остаётся рабочей.
  update public.lesson_voice_requests
     set cancelled_at = now()
   where requested_by = v_uid and consumed_at is null and cancelled_at is null;

  v_token := encode(extensions.gen_random_bytes(12), 'hex');

  insert into public.lesson_voice_requests
    (token, center_id, lesson_id, student_id, teacher_id, requested_by, expires_at)
  values
    (v_token, v_center, p_lesson_id, p_student_id,
     coalesce(v_lesson.substitute_teacher_id, v_lesson.teacher_id), v_uid,
     now() + interval '15 minutes');

  return v_token;
end;
$$;

comment on function public.request_voice_note(uuid, uuid) is
  'Кнопка «Отправьте голосовое» в строке ребёнка. Возвращает токен для deep-link t.me/<bot>?start=voice_<token>. С 0053 — отказ по квоте голосовых резюме до выдачи токена, с русским текстом по роли.';

revoke all on function public.request_voice_note(uuid, uuid) from public, anon, service_role;
grant execute on function public.request_voice_note(uuid, uuid) to authenticated;


-- 3. Событие и шаблоны (Р8–Р10) -------------------------------------------------------------------------------
--
-- mandatory = true (как subscription.ending/expired, 0052 Р1): это
-- единственный сигнал о пропавшей диктовке — ai_job_begin отдаёт null,
-- n8n делает ack, и без события след теряется целиком. Дефолтный текст
-- не называет {used}/{limit}: решение о блокировке смотрит ещё и на
-- резерв работ в полёте (Р3), которого экран не показывает, и число в
-- сообщении могло бы разойтись с числом на экране тарифа в том же
-- центре («исчерпан (29 из 30)»). Переменные остаются доступны центру
-- для собственного текста — с этой оговоркой в подсказке формы.

insert into public.notification_event_types (event_type, description, audience, subject_required, channels, mandatory) values
  ('ai.quota_exceeded', 'Голосовое не расшифровано: лимит голосовых резюме исчерпан', 'center', false, '{telegram,whatsapp_link}', true)
on conflict (event_type) do update
  set audience = excluded.audience, subject_required = excluded.subject_required,
      channels = excluded.channels, mandatory = excluded.mandatory;

insert into public.message_templates (center_id, event_type, channel, text)
select v.center_id, v.event_type, v.channel, v.text
  from (values
    (null::uuid, 'ai.quota_exceeded', 'telegram',
     'Голосовое{child} не расшифровано: лимит голосовых резюме на этот месяц исчерпан. Проверьте использование на экране «Тариф и оплата» — лимит снимает смена тарифа; после смены диктовку нужно записать заново.'),
    (null::uuid, 'ai.quota_exceeded', 'whatsapp_link',
     'Голосовое не расшифровано: лимит голосовых резюме на этот месяц исчерпан. Проверьте использование на экране «Тариф и оплата» в LogoCRM; после смены тарифа диктовку нужно записать заново.')
  ) as v(center_id, event_type, channel, text)
 where not exists (
   select 1 from public.message_templates m
    where m.center_id is null
      and m.event_type = v.event_type
      and m.channel = v.channel
      and m.deleted_at is null
 );

-- Р8: одно событие на диктовку — констрейнт, не проверка перед записью.
create unique index if not exists events_quota_exceeded_once
  on public.events (center_id, (payload ->> 'voice_request_id'))
  where type = 'ai.quota_exceeded';


-- 4. ai_job_begin — из 0051, добавлен один блок (Р2–Р4) ----------------------------------------------------------

create or replace function public.ai_job_begin(p_event_id bigint)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_event   public.events;
  v_request public.lesson_voice_requests;
  v_job     public.ai_jobs;
  v_goals   jsonb;
  v_total   integer;
  v_limit   integer;
  v_used    integer;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р3/Р7 (0042): событие принимается только живое, своё и захваченное.
  select * into v_event from public.events
   where id = p_event_id
     and type = 'lesson.voice_received'
     and processed_at is null
     and claimed_at is not null;
  if not found then
    return null;
  end if;

  select * into v_request from public.lesson_voice_requests
   where id = (v_event.payload ->> 'voice_request_id')::uuid;
  if not found then
    return null;
  end if;

  -- Р8 (0042): свежесть считается от диктовки, не от токена.
  if v_request.consumed_at is null or v_request.consumed_at < now() - interval '24 hours' then
    return null;
  end if;

  -- Б3 (0042): всё, на чём упадёт запись, проверяется ЗДЕСЬ — до Whisper
  -- и модели. Иначе отказ приходит после двух платных вызовов, работа
  -- становится терминальной, и диктовка не восстанавливается никогда.
  if v_request.center_id <> v_event.center_id then
    return null;
  end if;
  if not exists (
    select 1 from public.students s
     where s.id = v_request.student_id and s.deleted_at is null
  ) then
    return null;
  end if;
  if not exists (
    select 1 from public.lessons l
     where l.id = v_request.lesson_id and l.deleted_at is null and l.status <> 'cancelled'
  ) then
    return null;
  end if;
  if exists (
    select 1 from public.lesson_notes n
     where n.lesson_id = v_request.lesson_id and n.student_id = v_request.student_id
       and n.deleted_at is null
       and (n.status = 'approved'
            or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
  ) then
    return null;
  end if;

  -- 0051 Р8/Р9: подписка истекла между диктовкой и обработкой — деньги
  -- платформы не тратятся, специалист узнаёт один раз. После проверок выше
  -- (работа, которую всё равно отбросили бы, сообщения не заслуживает) и до
  -- insert в ai_jobs (следа в очереди работ нет). «Один раз» держит
  -- частичный unique events_voice_blocked_once, а не if — два параллельных
  -- прогона n8n иначе эмитили бы оба.
  if not public.center_writable(v_event.center_id) then
    begin
      perform public.emit_event_unchecked(
        'subscription.voice_blocked',
        jsonb_build_object(
          'center_id',        v_event.center_id,
          'voice_request_id', v_request.id,
          'reason_code',      'subscription_expired'
        ),
        v_event.center_id
      );
    exception when unique_violation then
      null;
    end;
    return null;
  end if;

  -- 0053 Р2–Р4: квота голосовых резюме. Замок тем же ключом, что лимиты 0049,
  -- до счёта и до insert ai_jobs; тарифа или ключа нет — null без события
  -- (fail closed); резерв — работы в полёте кроме своей (перезахват).
  -- Перехват сужен до 23514 (единственный исход plan_limit при отсутствии
  -- тарифа/ключа, 0049) — иначе настоящая поломка тонет молча без следа.
  perform pg_advisory_xact_lock(hashtextextended('center_limit:' || v_event.center_id::text, 0));
  begin
    v_limit := public.plan_limit(v_event.center_id, 'ai_notes_month');
  exception when sqlstate '23514' then
    return null;
  end;
  if v_limit >= 0 then
    v_used := public.center_ai_notes_used(v_event.center_id);
    if v_used + public.ai_notes_reserved(v_event.center_id, p_event_id) >= v_limit then
      begin
        perform public.emit_event_unchecked(
          'ai.quota_exceeded',
          jsonb_build_object(
            'center_id',        v_event.center_id,
            'voice_request_id', v_request.id,
            'used',             v_used,
            'limit',            v_limit
          ),
          v_event.center_id
        );
      exception when unique_violation then
        null;
      end;
      return null;
    end if;
  end if;

  select * into v_job from public.ai_jobs where event_id = p_event_id for update;

  if found then
    -- Р4 (0042): сделанное и терминальное не переигрывается — n8n сразу ack.
    if v_job.status in ('done', 'failed') then
      return null;
    end if;
    -- В2 (0042): пока прогон свеж, работа занята. Без этого
    -- release_stale_claims возвращает событие за спину живому обработчику,
    -- и Whisper с моделью оплачиваются второй раз. Порог меньше того, с
    -- которым очередь возвращает пачки (10 минут), — иначе окна не
    -- остаётся вовсе.
    if v_job.started_at > now() - interval '8 minutes' then
      return null;
    end if;
    update public.ai_jobs
       set attempts = attempts + 1, started_at = now()
     where event_id = p_event_id;
  else
    -- В7 (0042): голый insert на гонке двух прогонов падал бы на первичном
    -- ключе, и воркер разобрал бы это как сбой — терминал по причине,
    -- которой нет.
    insert into public.ai_jobs (event_id, center_id)
    values (p_event_id, v_event.center_id)
    on conflict (event_id) do nothing
    returning * into v_job;

    if v_job.event_id is null then
      return null;
    end if;
  end if;

  -- 0048 Р1–Р6: активные цели ребёнка диктовки, обезличенно, в
  -- детерминированном порядке, не больше 50, с полным числом отдельно.
  -- Один проход: предикат «активная цель» написан один раз, список и
  -- полное число не могут разойтись при следующей правке фильтра.
  select coalesce(jsonb_agg(jsonb_build_object(
           'goal_id',     x.id,
           'title',       x.title,
           'area',        x.area,
           'sound',       x.sound,
           'stage_title', x.stage_title
         ) order by x.stage_sort, x.created_at, x.id) filter (where x.rn <= 50), '[]'::jsonb),
         coalesce(max(x.total), 0)::integer
    into v_goals, v_total
    from (
      select g.id, g.title, g.area, g.sound, st.title as stage_title, st.sort as stage_sort, g.created_at,
             row_number() over (order by st.sort, g.created_at, g.id) as rn,
             count(*) over () as total
        from public.goals g
        join public.goal_stages st on st.id = g.stage_id
       where g.student_id = v_request.student_id
         and g.center_id = v_request.center_id
         and g.deleted_at is null
         and g.status = 'active'
    ) x;

  return jsonb_build_object(
    'file_id',             v_event.payload ->> 'file_id',
    'center_id',           v_request.center_id,
    'lesson_id',           v_request.lesson_id,
    'student_id',          v_request.student_id,
    'student_goals',       v_goals,
    'student_goals_total', v_total
  );
end;
$$;

comment on function public.ai_job_begin(bigint) is
  'Занять событие до похода в платные API. null значит «не работай»: событие чужое, устаревшее, уже сделанное, терминальное, запись всё равно упадёт (0042 Б3), подписка центра истекла (0051 Р8 — событие subscription.voice_blocked один раз на диктовку) или квота голосовых резюме исчерпана (0053 — ai.quota_exceeded один раз на диктовку; тарифа нет — null без события). С 0048 отдаёт student_goals — активные цели ребёнка диктовки без чего-либо, идентифицирующего ребёнка (goal_id, title, area, sound, stage_title; порядок этап→дата→id; не больше 50, полное число в student_goals_total).';

revoke all on function public.ai_job_begin(bigint) from public, anon, authenticated, service_role;
grant execute on function public.ai_job_begin(bigint) to bot_worker;


-- 5. center_limits — из 0050, счётчик ИИ через center_ai_notes_used (Р5) -----------------------------------------

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

  return jsonb_build_object(
    'plan',        v_p.code,
    'plan_name',   v_p.name,
    'price_tiyin', v_p.price_tiyin,
    'is_trial',    v_c.plan = 'trial',
    'until',       v_until,
    'days_left',   case when v_until is null then null
                        else ((v_until at time zone v_tz)::date - v_today) end,
    'writable',    public.center_writable(v_center),
    'limits',      v_p.limits,
    'usage', jsonb_build_object(
      'teachers', (select count(*) from public.teachers t where t.center_id = v_center and t.deleted_at is null),
      'students', (select count(*) from public.students s where s.center_id = v_center and s.deleted_at is null and s.status <> 'archived'),
      -- 0053 Р5: тот же счётчик, что у гейта; резерв работ в полёте не показывается.
      'ai_notes_month', public.center_ai_notes_used(v_center)
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
  'Тариф, лимиты, использование, дни до конца и writable в поясе центра, галочки онбординга — одним запросом для экрана тарифа и баннера (0049 Р9, 0050 Р11, 0053 Р5). Родителю недоступно.';

revoke all on function public.center_limits() from public, anon, service_role;
grant execute on function public.center_limits() to authenticated;


-- 6. Доставка (Р8, Р10) — event_messages из 0052, одна ветка сверху --------------------------------------------------

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
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4), с 0047 — только в telegram. Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. lesson.note_approved (0047) — резюме родителю, {summary} только в telegram и не длиннее 3500 символов; lesson.voice_failed (0047) — заказчику диктовки через notification_user_targets, без причины отказа и только пока повтор диктовки имеет смысл (условие ai_job_begin). 0051: platform.payment_submitted — администраторам платформы (notification_platform_targets, шаблон только дефолтный), subscription.extended — owner/admin центра с {until} в поясе центра, subscription.voice_blocked — заказчику диктовки, {child} только в telegram. 0052: subscription.ending/expired — owner/admin центра, {what}/{until}/{when} на момент доставки в поясе центра. 0053: ai.quota_exceeded — заказчику диктовки ({child} с предлогом, только telegram) и owner/admin центра без {child}, {used}/{limit} в оба канала, пока повтор диктовки имеет смысл. Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;
