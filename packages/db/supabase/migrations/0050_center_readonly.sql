-- =============================================================================
-- 0050_center_readonly.sql — только чтение при истёкшем trial или подписке
-- (этап 8a, шаг 2)
--
-- Механизм и 13 условий — reports/stage-8.md, «Решение по механизму
-- read-only» (после второго ревью архитектора 22.09.2026), ADR-011.
-- Коротко: один BEFORE-триггер на каждой таблице центра вместо гейта в ~70
-- definer-функциях. Триггер срабатывает и внутри security definer, и на
-- прямом PATCH; политики RLS вторым рубежом не переиздаются.
--
--   Р1. Guard срабатывает только при auth.uid() is not null — единственный
--       признак сессии, который переживает и definer, и set role
--       (current_user внутри definer уже postgres; session_user под set
--       local role в pgTAP — тоже). Граница, записанная в ADR-011:
--       миграции, RI-каскады и контур bot_worker триггером не покрыты.
--       Узкие проверки в контуре бота (ai_job_begin и сообщение
--       специалисту) — следующей миграцией вместе с заявками на оплату:
--       им нужен тип события и шаблон.
--
--   Р2. Путь разблокировки не может быть под блокировкой: audit_log и
--       events исключены (иначе extend_subscription откатился бы на своём
--       же аудите), platform_payments и center_billing — когда появятся.
--       is_platform_admin() проходит guard всегда.
--
--   Р3. Режим отказывает на входе в работу, никогда на её закрытии:
--       notification_log, lesson_reminders_sent, center_digest_runs,
--       ai_jobs, ai_usage, lesson_confirmations исключены — иначе воркер
--       уходит в вечный ретрай ровно там, где хотели сэкономить.
--
--   Р4. Белый список — по паре (таблица, операция): memberships и
--       invitations — insert под guard (приём нового не должен идти при
--       просрочке), update/delete свободны (уход сотрудника и отзыв
--       доступа не зависят от оплаты).
--
--   Р5. Fail closed: center_writable — явный case по plan, null в датах —
--       отказ. Инвариант на centers: trial обязан иметь trial_ends_at
--       (check). Для платных тарифов дата не навязывается констрейнтом
--       (платформа сначала ставит план, потом срок), но null означает
--       «не оплачено» — центр без subscription_until читает.
--
--   Р6. Nullable center_id (message_templates, exercise_library): запись
--       строки платформы из сессии центра — отказ, не пропуск. audit_log
--       исключён по Р2.
--
--   Р7. Забор pgTAP двусторонний: каждая таблица public либо под guard на
--       i/u/d (для memberships/invitations — на insert), либо в явном
--       списке исключений с причиной; список nullable center_id
--       зафиксирован. telegram_accounts/telegram_link_codes/platform_admins/
--       plans/centers — без center_id, в списке с причиной.
--
--   Р8. Имя триггера a00_readonly_guard сортируется первым среди BEFORE-
--       триггеров таблицы: просроченный центр с превышенным лимитом видит
--       «подписка истекла», а не «лимит тарифа».
--
--   Р9. SQLSTATE 'PT402' — соглашение PostgREST: PTxxx → HTTP 402 Payment
--       Required. Не 42501 (занят под права, действие у пользователя
--       другое — оплатить) и не произвольный класс (PostgREST отдал бы
--       500). В errors.ts — отдельная ветка.
--
--   Р10. Без кэша вердикта через set_config: соединение пула переживает
--       сессию, вердикт одного центра утёк бы другому. Поиск по PK
--       centers на строку — не измеряется.
--
--   Р11. Момент отсечения — до конца дня истечения в поясе центра: срок
--       «до 30.09» значит «30.09 ещё работаем». Одно выражение в
--       center_writable; center_limits() (0049) считает days_left в том
--       же поясе.
--
--   Р12. Что центр обязан мочь в read-only (ADR-011): подать заявку на
--       оплату (0051), сменить центр, править название и пояс (centers
--       вне цикла — защита тарифа уже в 0049), экспорт (чтение), отвязать
--       Telegram (нет center_id), отозвать доступ сотруднику
--       (memberships delete свободен). Уведомления родителям идут (Р3).
--
--   Р13. DELETE под guard: стоимость нулевая, будущая физическая очистка
--       (ADR-012) не станет дырой.
--
--   Шов. На staging тестовый центр владельца «Логопед Плюс» просрочен с
--   21.09.2026 — после миграции он стал бы read-only мгновенно, и первым
--   выводом было бы «миграция сломала базу». Всем trial-центрам с
--   истёкшим сроком trial продлевается на 30 дней от применения; в prod
--   на момент 8b таких центров быть не должно (проверить запросом).
--   Фикстуры 0017/0049 с платными тарифами получают subscription_until.

-- 1. Инвариант и предикат --------------------------------------------------------------------

alter table public.centers drop constraint if exists centers_trial_has_end;
alter table public.centers
  add constraint centers_trial_has_end check (plan <> 'trial' or trial_ends_at is not null);

-- Шов: просроченные trial на staging получают 30 дней.
update public.centers
   set trial_ends_at = now() + interval '30 days'
 where plan = 'trial' and deleted_at is null
   and (trial_ends_at is null or trial_ends_at < now());

create or replace function public.center_writable(p_center_id uuid)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_c     public.centers;
  v_tz    text;
  v_until timestamptz;
begin
  select * into v_c from public.centers where id = p_center_id and deleted_at is null;
  if not found then
    return false;
  end if;

  v_until := case when v_c.plan = 'trial' then v_c.trial_ends_at else v_c.subscription_until end;
  if v_until is null then
    return false;
  end if;

  -- Р11: до конца дня истечения в поясе центра.
  v_tz := public.center_timezone(p_center_id);
  return (v_until at time zone v_tz)::date >= (now() at time zone v_tz)::date;
end;
$$;

comment on function public.center_writable(uuid) is
  'Центр может писать: живой trial или оплаченная подписка, до конца дня истечения в поясе центра (0050 Р5/Р11). null в дате — нет.';

revoke all on function public.center_writable(uuid) from public, anon;
grant execute on function public.center_writable(uuid) to authenticated;


-- 2. Guard ---------------------------------------------------------------------------------------

create or replace function public.center_readonly_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_row    jsonb;
  v_center uuid;
begin
  -- Р1: без сессии (миграции, каскады, bot_worker) — не наше дело.
  if auth.uid() is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  -- Р2: платформа проходит всегда.
  if public.is_platform_admin() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Р12: отзыв доступа сотруднику не зависит от оплаты. revoke_membership
  -- (0004) вместе с delete memberships гасит карточку teachers
  -- (is_active → false) — эта одна правка проходит и при просрочке.
  if tg_table_name = 'teachers' and tg_op = 'UPDATE'
     and (to_jsonb(old) ->> 'is_active')::boolean and not (to_jsonb(new) ->> 'is_active')::boolean
     and (to_jsonb(new) - 'is_active' - 'updated_at') = (to_jsonb(old) - 'is_active' - 'updated_at')
  then
    return new;
  end if;

  v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_center := (v_row ->> 'center_id')::uuid;

  -- Р6: строка платформы из сессии центра — отказ, не пропуск.
  if v_center is null then
    raise exception 'Запись без центра из сессии центра недоступна'
      using errcode = 'PT402';
  end if;

  if not public.center_writable(v_center) then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.center_readonly_guard() from public, anon, authenticated, service_role;

-- Список исключений — единственное место, где он есть; забор pgTAP 0050
-- сверяет с ним каталог. Причины — в шапке (Р2, Р3, Р4).
create or replace function public.readonly_guard_exempt_tables()
  returns table (table_name text, reason text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('audit_log',            'Р2: аудит действия платформы, снимающего блокировку'),
    ('events',               'Р2/Р3: события платформы и закрытие работы воркера'),
    ('notification_log',     'Р3: закрытие доставки'),
    ('lesson_reminders_sent','Р3: отметка воркера'),
    ('center_digest_runs',   'Р3: отметка воркера'),
    ('ai_jobs',              'Р3: закрытие работы ИИ'),
    ('ai_usage',             'Р3: учёт уже потраченного'),
    ('lesson_confirmations', 'Р3: пишет только bot_worker')
$$;

revoke all on function public.readonly_guard_exempt_tables() from public, anon, authenticated, service_role;

do $$
declare
  r record;
begin
  for r in
    select c.table_name
      from information_schema.columns c
      join information_schema.tables t
        on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
     where c.table_schema = 'public' and c.column_name = 'center_id'
       and c.table_name not in (select x.table_name from public.readonly_guard_exempt_tables() x)
     order by c.table_name
  loop
    execute format('drop trigger if exists a00_readonly_guard on public.%I', r.table_name);
    if r.table_name in ('memberships', 'invitations') then
      -- Р4: приём нового — под guard; уход и отзыв — нет.
      execute format(
        'create trigger a00_readonly_guard before insert on public.%I for each row execute function public.center_readonly_guard()',
        r.table_name);
    else
      execute format(
        'create trigger a00_readonly_guard before insert or update or delete on public.%I for each row execute function public.center_readonly_guard()',
        r.table_name);
    end if;
  end loop;
end;
$$;
