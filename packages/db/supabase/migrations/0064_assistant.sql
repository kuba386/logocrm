-- 0064: AI-ассистент администратора — вопрос обычным языком вместо блуждания
-- по экранам (Backlog.md, владелец 11.09.2026).
--
-- Решения владельца (24.09.2026):
--   В1. Наружу (OpenAI, единственный провайдер — ADR-009) уходит только
--       текст вопроса и сегодняшняя дата в поясе центра. Модель разбирает
--       вопрос в намерение с параметрами (function calling) — и всё; ответ
--       собирает база под правами спросившего, рисует интерфейс. Имена
--       детей и деньги провайдеру не отправляются. Остаточный риск —
--       оператор сам напишет имя в вопросе (как с транскриптом, ADR-009).
--   В2. Квота — лимит в тарифе: plans.limits.ai_questions_month
--       (trial 300, Solo 100, Studio 500, Center 2000), учёт в ai_usage,
--       отказ с текстом тарифа — как у голосовых (0053).
--   В3. Ассистент — всем сотрудникам (owner/admin/registrar/finance/teacher),
--       родителю — нет.
--
-- Решения по ревью плана (architect, 24.09.2026):
--   Р1. Попытка и расход — разные сущности. assistant_requests — попытка
--       (running/done/failed, актор, намерение); ai_usage — расход, пишется
--       ПОСЛЕ ответа провайдера, как ai_usage_record. Резерв в реестре денег
--       с tokens = 0 дал бы колонке два смысла (ошибка lessons_left).
--   Р2. Цену считает SQL по справочнику ставок ai_model_rates() (тыйыны за
--       1M токенов, VALUES как readonly_guard_exempt_tables) — параметр
--       «стоимость» от сессии пользователя в реестр денег не принимается;
--       токены сверх потолка и неизвестная модель — отказ, не ставка 0.
--   Р3. Карта «намерение × роль» — в SQL (assistant_intents_for(role)):
--       из неё собирается список инструментов для модели И повторно
--       проверяется намерение при закрытии попытки. Пустой ответ RLS нельзя
--       выдавать за «данных нет» (0058: исключение вместо пустого файла) —
--       бухгалтеру намерение «занятия» не предлагается вовсе.
--   Р4. Замороженный/удалённый центр — явный PT402 в горловине
--       (center_writable), как ai_job_begin; ai_usage в списке исключений
--       readonly-guard («учёт уже потраченного»), поэтому на него надежды нет.
--       assistant_requests — под guard на insert (как memberships):
--       закрытие уже начатой попытки идёт всегда.
--   Р5. Единица учёта: один вопрос = ровно один вызов провайдера; модель
--       результат RPC не видит. Второй вызов «сформулировать ответ по
--       данным» — отдельное решение владельца и правка ADR-009; проверяется
--       Vitest (ядро запроса — packages/core/assistant.ts).
--   Р6. Исполнение не существует без попытки: server action исполняет
--       намерение только с id попытки в состоянии running, созданной этим
--       же auth.uid(); assistant_finish повторяет ролевой гейт по карте Р3.
--   Р7. Актор — на попытке, не в реестре расхода: у ai_usage из нового
--       только kind = 'question'. Журнала «кто что спрашивал» никто не
--       заказывал — у assistant_requests нет select-гранта, только функции.
--   Р8. Обрыв после ответа провайдера (таймаут 15 с): попытка помечается
--       failed, строки расхода нет — расхождение со счётом провайдера
--       признаётся и измеряется числом failed-попыток. Попытка не удаляется:
--       удаление резерва = бесплатный обход квоты («сорви вызов — лимит цел»).
--   Р9. Квота = оплаченные question-строки за месяц (center_month_start)
--       + running-попытки не старше 5 минут, под pg_advisory_xact_lock
--       ('center_limit:<center>') — тот же приём, что ai_notes_reserved.
--   Р10. Сотруднику — used/limit без имени тарифа (center_limits закрыт от
--        всех, кроме owner/admin); имя тарифа — только в тексте отказа, как
--        0053, и в assistant_quota() для owner/admin.
--   Р11. plans: ключ добавляется ВСЕМ строкам (дефолт 100 неизвестным кодам),
--        не четырём поимённо — иначе пятый тариф получал бы «не задан тариф».
--   Р12. Дата для промпта — из базы (center_today/center_timezone), не из
--        Node: new Date() на Vercel в 02:00 по Бишкеку — вчерашнее число.
--   Р13. Аудита на ai_usage нет (проверено) — забор pgTAP на отсутствие
--        insert/update у authenticated остаётся страховкой. Частичный unique
--        ai_usage_event_kind_key (event_id, kind) where event_id is not null
--        строки вопроса (event_id null) не судит — закреплено тестом.
--   Р14. Единственный гейт по роли — SQL; пункт меню и страница — косметика.

-- 1. Тарифы: лимит вопросов в месяц (В2, Р11) ------------------------------------------------

update public.plans
   set limits = limits || jsonb_build_object('ai_questions_month',
     case code when 'trial' then 300 when 'solo' then 100 when 'studio' then 500 when 'center' then 2000
               else 100 end)
 where not (limits ? 'ai_questions_month');


-- 2. ai_usage: третий вид расхода -------------------------------------------------------------

alter table public.ai_usage drop constraint if exists ai_usage_kind_check;
alter table public.ai_usage add constraint ai_usage_kind_check
  check (kind in ('transcribe', 'summary', 'question'));

comment on column public.ai_usage.kind is
  'transcribe/summary — голосовое резюме (n8n, ai_usage_record); question — вопрос ассистенту (0064, assistant_finish). ai_usage_summary отдаёт все три вида одной таблицей.';


-- 3. Ставки: цену считает SQL (Р2) ---------------------------------------------------------------

create or replace function public.ai_model_rates()
  returns table (model text, in_tiyin_per_m integer, out_tiyin_per_m integer)
  language sql
  immutable
  set search_path = ''
as $$
  -- Тыйыны за 1M токенов при ~87 сом за доллар. Смена курса/модели —
  -- следующей миграцией; история пересчитывается по токенам (0041 Р12).
  values ('gpt-4o-mini', 1300, 5200)
$$;

revoke all on function public.ai_model_rates() from public, anon, authenticated, service_role;


-- 4. Попытки (Р1, Р7) ------------------------------------------------------------------------------

create table if not exists public.assistant_requests (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null references public.centers (id) on delete cascade,
  created_by  uuid not null references auth.users (id) on delete cascade,
  status      text not null default 'running'
                check (status in ('running', 'done', 'failed')),
  intent      text,
  usage_id    uuid references public.ai_usage (id) on delete set null,
  error       text,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,

  constraint assistant_requests_finished_matches_status
    check ((status = 'running') = (finished_at is null)),
  constraint assistant_requests_usage_only_done
    check (usage_id is null or status = 'done')
);

comment on table public.assistant_requests is
  'Попытка вопроса ассистенту (0064): резерв квоты до вызова провайдера, актор и намерение. Текст вопроса не хранится. Расход — в ai_usage (usage_id) только после ответа провайдера. Select-гранта нет ни у кого: журнал «кто что спрашивал» не заказан (Р7).';

create index if not exists assistant_requests_center_started_idx
  on public.assistant_requests (center_id, started_at desc);

alter table public.assistant_requests enable row level security;
revoke all on table public.assistant_requests from public, anon, authenticated, service_role;
-- Новая попытка в замороженном центре — под guard (Р4); закрытие — всегда.
call public.apply_readonly_guard('assistant_requests', true);


-- 5. Карта «намерение × роль» (Р3) ----------------------------------------------------------------

create or replace function public.assistant_intents_for(p_role text)
  returns text[]
  language sql
  immutable
  set search_path = ''
as $$
  -- Ровно те намерения, чей источник данных роли читаем (RLS/RPC):
  --   lessons_on              — lessons/lesson_participants: owner, admin, registrar, teacher
  --   debtors                 — student_debts(): can_payments (owner, admin, registrar, finance)
  --   expiring_subscriptions  — subscriptions + student_balance: owner, admin, registrar, finance
  --   student_info            — global_search (0062): owner, admin, registrar, teacher
  --   payments_summary        — cash_by_source: owner, admin
  select case p_role
    when 'owner'     then array['lessons_on','debtors','expiring_subscriptions','student_info','payments_summary']
    when 'admin'     then array['lessons_on','debtors','expiring_subscriptions','student_info','payments_summary']
    when 'registrar' then array['lessons_on','debtors','expiring_subscriptions','student_info']
    when 'finance'   then array['debtors','expiring_subscriptions']
    when 'teacher'   then array['lessons_on','student_info']
    else array[]::text[]
  end
$$;

revoke all on function public.assistant_intents_for(text) from public, anon, authenticated, service_role;


-- 6. Счётчик и квота (В2, Р9) ------------------------------------------------------------------------

create or replace function public.center_ai_questions_used(p_center_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select count(*)::integer
    from public.ai_usage u
   where u.center_id = p_center_id
     and u.kind = 'question'
     and u.created_at >= public.center_month_start(p_center_id)
$$;

revoke all on function public.center_ai_questions_used(uuid) from public, anon, authenticated, service_role;

create or replace function public.assistant_questions_reserved(p_center_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select count(*)::integer
    from public.assistant_requests r
   where r.center_id = p_center_id
     and r.status = 'running'
     and r.started_at >= now() - interval '5 minutes'
$$;

revoke all on function public.assistant_questions_reserved(uuid) from public, anon, authenticated, service_role;


-- 7. Горловина: assistant_begin() ----------------------------------------------------------------------

create or replace function public.assistant_begin()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_limit  integer;
  v_used   integer;
  v_id     uuid;
  v_tz     text;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin', 'registrar', 'finance', 'teacher') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р4: платный вызов не для замороженного/удалённого центра.
  if not public.center_writable(v_center) then
    raise exception 'Ассистент недоступен: подписка центра не оплачена или центр удалён' using errcode = 'PT402';
  end if;

  v_limit := public.plan_limit(v_center, 'ai_questions_month');
  if v_limit is null then
    raise exception 'У центра не задан тариф — обратитесь к администратору платформы' using errcode = '23514';
  end if;

  if v_limit >= 0 then
    perform pg_advisory_xact_lock(hashtext('center_limit:' || v_center::text));
    v_used := public.center_ai_questions_used(v_center) + public.assistant_questions_reserved(v_center);
    if v_used >= v_limit then
      if v_role in ('owner', 'admin') then
        raise exception 'Лимит вопросов ассистенту на этот месяц исчерпан: % из % по тарифу %. Подайте заявку на другой тариф на экране «Тариф и оплата» или подождите до следующего месяца',
          v_used, v_limit, public.center_plan_name(v_center)
          using errcode = '23514';
      end if;
      raise exception 'Лимит вопросов ассистенту на этот месяц исчерпан: % из %. Сообщите владельцу центра — лимит снимает смена тарифа',
        v_used, v_limit
        using errcode = '23514';
    end if;
  end if;

  insert into public.assistant_requests (center_id, created_by)
  values (v_center, auth.uid())
  returning id into v_id;

  v_tz := public.center_timezone(v_center);

  -- Р12: дата — из базы. Р3: инструменты — по карте роли.
  return jsonb_build_object(
    'request_id', v_id,
    'today',      public.center_today(v_center),
    'timezone',   v_tz,
    'intents',    to_jsonb(public.assistant_intents_for(v_role))
  );
end;
$$;

comment on function public.assistant_begin() is
  'Горловина ассистента (0064): гейт роли (В3), PT402 для неоплаченного центра (Р4), квота = оплаченные вопросы месяца + running-попытки ≤ 5 мин под advisory lock (Р9), попытка running. Возвращает request_id, дату в поясе центра и список намерений роли.';

revoke execute on function public.assistant_begin() from public, anon;
grant  execute on function public.assistant_begin() to authenticated;


-- 8. Закрытие: assistant_finish() ---------------------------------------------------------------------

create or replace function public.assistant_finish(
  p_request_id uuid,
  p_status     text,
  p_intent     text default null,
  p_model      text default null,
  p_tokens_in  integer default 0,
  p_tokens_out integer default 0,
  p_error      text default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_req    public.assistant_requests;
  v_rate   record;
  v_cost   integer;
  v_usage  uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  -- Р6: только своя попытка своего центра; чужая/несуществующая — один код.
  select * into v_req
    from public.assistant_requests r
   where r.id = p_request_id and r.center_id = v_center and r.created_by = auth.uid()
   for update;
  if not found then
    raise exception 'Попытка не найдена' using errcode = '42704';
  end if;
  if v_req.status <> 'running' then
    raise exception 'Попытка уже закрыта' using errcode = '22023';
  end if;

  if p_status not in ('done', 'failed') then
    raise exception 'Неизвестный статус попытки' using errcode = '22023';
  end if;

  if p_status = 'done' then
    if p_intent is not null and not (p_intent = any (public.assistant_intents_for(v_role))) then
      -- Р3/Р6: намерение вне карты роли — отказ, не «пустой ответ».
      raise exception 'Этот вопрос вашей роли недоступен' using errcode = '42501';
    end if;

    -- Р2: цена — из справочника, токены — с потолком.
    if coalesce(p_tokens_in, 0) < 0 or coalesce(p_tokens_out, 0) < 0
       or coalesce(p_tokens_in, 0) > 20000 or coalesce(p_tokens_out, 0) > 2000 then
      raise exception 'Неправдоподобное число токенов' using errcode = '22023';
    end if;
    select * into v_rate from public.ai_model_rates() m where m.model = p_model;
    if not found then
      raise exception 'Неизвестная модель ассистента: %', coalesce(p_model, '—') using errcode = '22023';
    end if;
    v_cost := ceil((coalesce(p_tokens_in, 0)::numeric * v_rate.in_tiyin_per_m
                    + coalesce(p_tokens_out, 0)::numeric * v_rate.out_tiyin_per_m) / 1000000)::integer;

    insert into public.ai_usage (center_id, event_id, kind, model, tokens_in, tokens_out, cost_tiyin, rate_note)
    values (v_center, null, 'question', p_model, coalesce(p_tokens_in, 0), coalesce(p_tokens_out, 0), v_cost,
            format('%s: in %s out %s тыйын/1M', v_rate.model, v_rate.in_tiyin_per_m, v_rate.out_tiyin_per_m))
    returning id into v_usage;
  end if;

  update public.assistant_requests
     set status      = p_status,
         intent      = p_intent,
         usage_id    = v_usage,
         error       = case when p_status = 'failed' then left(p_error, 200) else null end,
         finished_at = now()
   where id = v_req.id;
end;
$$;

comment on function public.assistant_finish(uuid, text, text, text, integer, integer, text) is
  'Закрытие попытки (0064): done — строка ai_usage kind=question с ценой по ai_model_rates() (Р2), намерение сверяется с картой роли (Р3); failed — без расхода, текст ошибки. Только своя попытка (Р6).';

revoke execute on function public.assistant_finish(uuid, text, text, text, integer, integer, text) from public, anon;
grant  execute on function public.assistant_finish(uuid, text, text, text, integer, integer, text) to authenticated;


-- 9. Витрина квоты для экрана (Р10) ------------------------------------------------------------------

create or replace function public.assistant_quota()
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_limit  integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_role not in ('owner', 'admin', 'registrar', 'finance', 'teacher') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  v_limit := public.plan_limit(v_center, 'ai_questions_month');
  return jsonb_build_object(
    'used',      public.center_ai_questions_used(v_center),
    'limit',     v_limit,
    'intents',   to_jsonb(public.assistant_intents_for(v_role)),
    'plan_name', case when v_role in ('owner', 'admin') then public.center_plan_name(v_center) else null end
  );
end;
$$;

revoke execute on function public.assistant_quota() from public, anon;
grant  execute on function public.assistant_quota() to authenticated;


-- 10. center_limits: счётчик вопросов на экране тарифа (тело из 0053) ------------------------------

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
      'ai_notes_month', public.center_ai_notes_used(v_center),
      -- 0064: тот же счётчик, что у гейта ассистента; резерв не показывается.
      'ai_questions_month', public.center_ai_questions_used(v_center)
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

revoke execute on function public.center_limits() from public, anon;
grant  execute on function public.center_limits() to authenticated;
