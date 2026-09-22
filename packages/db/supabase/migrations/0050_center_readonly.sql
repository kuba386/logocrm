-- =============================================================================
-- 0050_center_readonly.sql — только чтение при истёкшем trial или подписке
-- (этап 8a, шаг 2)
--
-- Механизм и 13 условий — reports/stage-8.md, «Решение по механизму
-- read-only» (после второго ревью архитектора 22.09.2026), ADR-011.
-- Коротко: один BEFORE-триггер на каждой таблице public вместо гейта в ~70
-- definer-функциях. Триггер срабатывает и внутри security definer, и на
-- прямом PATCH; политики RLS вторым рубежом не переиздаются.
--
--   Р1. Guard срабатывает только при auth.uid() is not null — единственный
--       признак сессии, который переживает и definer, и set role
--       (current_user внутри definer уже postgres; session_user под set
--       local role в pgTAP — тоже). Граница, записанная в ADR-011:
--       миграции, RI-каскады и контур bot_worker триггером не покрыты.
--       Долг контура бота — один список в ADR-011 («Известные границы»):
--       проверка в ai_job_begin и сообщение специалисту, следующей
--       миграцией вместе с заявками на оплату (нужны тип события и шаблон).
--
--   Р2. Путь разблокировки не может быть под блокировкой: audit_log и
--       events исключены (иначе extend_subscription откатился бы на своём
--       же аудите), platform_payments — когда появится. is_platform_admin()
--       проходит guard всегда; проверяется после center_writable — живой
--       центр не ходит в auth.users на каждую строку. Следствие: сессия
--       просроченного центра по-прежнему пишет в events через emit_event —
--       принято осознанно: событие само по себе платформе ничего не стоит,
--       а строки, о которых оно сообщает (lessons, lesson_notes,
--       monthly_reports), уже не создать; единственная платная работа по
--       событию — ai_job_begin — закрывается в 0051 (ADR-011).
--
--   Р3. Режим отказывает на входе в работу, никогда на её закрытии:
--       notification_log, lesson_reminders_sent, center_digest_runs,
--       ai_jobs, ai_usage, lesson_confirmations исключены — иначе воркер
--       уходит в вечный ретрай ровно там, где хотели сэкономить.
--
--   Р4. Белый список — по паре (таблица, операция): memberships и
--       invitations — insert под guard (приём нового не должен идти при
--       просрочке), update/delete свободны (уход сотрудника и отзыв
--       доступа не зависят от оплаты). revoke_membership гасит карточку
--       teachers (is_active → false, profile_id → null) — эта правка
--       проходит по транзакционному флагу logocrm.revoke_membership,
--       который ставит и снимает сама функция. Форму строки guard не
--       сравнивает: прямой PATCH is_active = false — обычная запись, отказ.
--       set_config через PostgREST недоступен (не функция схемы public).
--
--   Р5. Fail closed: center_writable — явный case по plan, null в датах —
--       отказ. Инвариант на centers: trial обязан иметь trial_ends_at
--       (check). Для платных тарифов дата не навязывается констрейнтом
--       (платформа ставит план и срок одним update — ADR-011), но null
--       означает «не оплачено» — центр без subscription_until читает.
--
--   Р6. Nullable center_id (message_templates, exercise_library): строка
--       платформы не принадлежит центру, подписки у неё нет — guard её
--       не судит. Это fail-open по строкам платформы, и он держится на
--       двух условиях, записанных в ADR-011 и Database.md: (а) у таблицы
--       с nullable center_id есть свой рубеж записи, работающий и внутри
--       definer — триггер по роли (0040 exercise_library) или if в
--       единственной пишущей RPC (0037 message_templates); (б) center_id
--       заполняется только default current_center(), ни один BEFORE-триггер
--       его не присваивает — иначе guard увидит null, а следующий триггер
--       подставит центр. Список таких таблиц зафиксирован забором, чтобы
--       новая получила решение осознанно. Таблицы без center_id — только
--       через список исключений (Р7). audit_log исключён по Р2.
--
--   Р7. Забор pgTAP двусторонний по ВСЕМ базовым таблицам public: каждая
--       либо под guard на i/u/d (memberships/invitations — на insert),
--       либо в явном списке исключений с причиной; список nullable
--       center_id зафиксирован. Таблицы без center_id — centers, plans,
--       platform_admins, notification_event_types, telegram_accounts,
--       telegram_link_codes — в списке с причиной. Новую таблицу вешает
--       apply_readonly_guard(tbl) рядом с apply_tenant_rls/apply_audit.
--
--   Р8. Имя триггера a00_readonly_guard сортируется первым среди BEFORE-
--       триггеров таблицы: просроченный центр с превышенным лимитом видит
--       «подписка истекла», а не «лимит тарифа».
--
--   Р9. SQLSTATE 'PT402' — соглашение PostgREST: PTxxx → HTTP 402 Payment
--       Required. Не 42501 (занят под права, действие у пользователя
--       другое — оплатить) и не произвольный класс (PostgREST отдал бы
--       500). В errors.ts — отдельная ветка. Текст — по роли: owner/admin
--       читают «оплатите», остальные — «обратитесь к администратору».
--
--   Р10. Без кэша вердикта через set_config: соединение пула переживает
--       сессию, вердикт одного центра утёк бы другому. Поиск по PK
--       centers на строку — не измеряется.
--
--   Р11. Момент отсечения — до конца дня истечения в поясе центра: срок
--       «до 30.09» значит «30.09 ещё работаем». Одно выражение в
--       center_writable; center_limits() (0049) отдаёт writable из той же
--       функции и считает days_left в том же поясе — pgTAP гоняет границу
--       через обе.
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
--   выводом было бы «миграция сломала базу». Всем центрам с истёкшим или
--   пустым сроком (trial — trial_ends_at, платные — subscription_until)
--   даётся 30 дней от применения, включая мягко удалённые: констрейнт ниже
--   смотрит на все строки. centers_protect_plan (0049) без сессии тоже
--   отказывает — на время шва выключается явно. В prod на момент 8b таких
--   центров быть не должно (проверить запросом). Фикстуры 0017/0049 с
--   платными тарифами получают subscription_until.

-- 1. Шов, инвариант, предикат ----------------------------------------------------------------------

alter table public.centers disable trigger centers_protect_plan;

-- Пустая дата trial — у всех строк (иначе не пройдёт констрейнт ниже);
-- просроченные — только живые центры: закрытый центр 30 дней не получает.
-- Список затронутых снимается запросом до деплоя (reports/stage-8.md).
update public.centers
   set trial_ends_at = now() + interval '30 days'
 where plan = 'trial'
   and (trial_ends_at is null or (trial_ends_at < now() and deleted_at is null));

update public.centers
   set subscription_until = now() + interval '30 days'
 where plan <> 'trial'
   and deleted_at is null
   and (subscription_until is null or subscription_until < now());

alter table public.centers enable trigger centers_protect_plan;

alter table public.centers drop constraint if exists centers_trial_has_end;
alter table public.centers
  add constraint centers_trial_has_end check (plan <> 'trial' or trial_ends_at is not null);

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

-- Без гранта authenticated: прямой RPC дал бы вердикт по любому UUID центра
-- (существует, жив, платит). Зовут её guard и center_limits() изнутри definer;
-- экрану хватает center_limits().writable.
revoke all on function public.center_writable(uuid) from public, anon, authenticated, service_role;


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

  -- Р4: revoke_membership гасит карточку teachers под своим флагом.
  if tg_table_name = 'teachers' and tg_op = 'UPDATE'
     and current_setting('logocrm.revoke_membership', true) = '1'
  then
    return new;
  end if;

  v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_center := (v_row ->> 'center_id')::uuid;

  -- Р6: строка платформы (center_id is null) не принадлежит центру — у неё
  -- нет подписки, и guard её не судит. Кто вправе её писать, решают
  -- триггер 0040 (exercise_library) и политики 0037 (message_templates);
  -- забор 0050 фиксирует список таких таблиц, чтобы новая получила решение.
  if v_center is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Р2/Р10: живой центр — дешёвая проверка по PK, без похода в auth.users.
  if public.center_writable(v_center) then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Р2: платформа проходит всегда.
  if public.is_platform_admin() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Р9: текст по роли — «оплатите» читает тот, кто может оплатить; родителю
  -- и специалисту это выглядело бы как требование денег с них.
  if coalesce(public.my_role(), '') in ('owner', 'admin') then
    raise exception 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра'
      using errcode = 'PT402';
  end if;
  raise exception 'Центр временно доступен только для чтения — обратитесь к администратору центра'
    using errcode = 'PT402';
end;
$$;

revoke all on function public.center_readonly_guard() from public, anon, authenticated, service_role;

-- Список исключений — единственное место, где он есть; забор pgTAP 0050
-- сверяет с ним каталог. Причины — в шапке (Р2, Р3, Р4, Р7, Р12).
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
    ('telegram_link_codes',     'Р12: нет center_id; код привязки Telegram')
$$;

revoke all on function public.readonly_guard_exempt_tables() from public, anon, authenticated, service_role;

-- Р7: одна точка навешивания — рядом с apply_tenant_rls / apply_audit.
-- Новая таблица центра в следующих миграциях: call public.apply_readonly_guard('tbl').
create or replace procedure public.apply_readonly_guard(tbl text, insert_only boolean default false)
  language plpgsql
  set search_path = ''
as $$
begin
  execute format('drop trigger if exists a00_readonly_guard on public.%I', tbl);
  if insert_only then
    execute format(
      'create trigger a00_readonly_guard before insert on public.%I for each row execute function public.center_readonly_guard()',
      tbl);
  else
    execute format(
      'create trigger a00_readonly_guard before insert or update or delete on public.%I for each row execute function public.center_readonly_guard()',
      tbl);
  end if;
end;
$$;

revoke execute on procedure public.apply_readonly_guard(text, boolean) from public, anon, authenticated, service_role;

do $$
declare
  r record;
begin
  for r in
    select t.table_name
      from information_schema.tables t
     where t.table_schema = 'public' and t.table_type = 'BASE TABLE'
       and t.table_name not in (select x.table_name from public.readonly_guard_exempt_tables() x)
     order by t.table_name
  loop
    -- Р4: приём нового — под guard; уход и отзыв — нет.
    call public.apply_readonly_guard(r.table_name, r.table_name in ('memberships', 'invitations'));
  end loop;
end;
$$;


-- 3. revoke_membership: флаг для карточки teachers (Р4) ------------------------------------------------
-- Из 0028_roles_policies.sql; добавлен только set_config вокруг update teachers.

create or replace function public.revoke_membership(p_user_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_actor  text := coalesce(public.my_role(), '');
  v_target public.memberships;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_actor not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_target
    from public.memberships
   where user_id = p_user_id and center_id = v_center;

  if not found then
    raise exception 'Участник не найден в этом центре' using errcode = '42704';
  end if;

  if v_target.role = 'owner' then
    if v_actor <> 'owner' then
      raise exception 'Только владелец может отключить другого владельца' using errcode = '42501';
    end if;

    if (select count(*) from public.memberships
         where center_id = v_center and role = 'owner') <= 1 then
      raise exception 'Нельзя отключить последнего владельца центра' using errcode = '23514';
    end if;
  end if;

  delete from public.memberships where user_id = p_user_id and center_id = v_center;

  if v_target.teacher_id is not null then
    -- 0050 Р4: карточка гаснет и при просрочке — флаг только на этот update.
    perform set_config('logocrm.revoke_membership', '1', true);
    update public.teachers
       set is_active = false, profile_id = null
     where id = v_target.teacher_id and center_id = v_center;
    perform set_config('logocrm.revoke_membership', '', true);
  end if;

  perform public.emit_event(
    'membership.revoked',
    jsonb_build_object('center_id', v_center, 'user_id', p_user_id, 'role', v_target.role),
    v_center
  );
end;
$$;

revoke execute on function public.revoke_membership(uuid) from public, anon;
grant execute on function public.revoke_membership(uuid) to authenticated;


-- 4. center_limits: writable из той же функции (Р11) --------------------------------------------------
-- Из 0049_plans_and_limits.sql; добавлен только ключ writable.

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
    'writable',    public.center_writable(v_center),
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
  'Тариф, лимиты, использование, дни до конца и writable в поясе центра, галочки онбординга — одним запросом для экрана тарифа и баннера (0049 Р9, 0050 Р11). Родителю недоступно.';

revoke all on function public.center_limits() from public, anon, service_role;
grant execute on function public.center_limits() to authenticated;
