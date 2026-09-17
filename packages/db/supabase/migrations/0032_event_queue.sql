-- =============================================================================
-- 0032_event_queue.sql — очередь outbox и планировщики (этап 6, шаг 1 из 2)
--
-- Первый этап, на котором события из `events` кто-то читает. Читает их n8n:
-- ходит в PostgREST по расписанию и забирает пачку (claim → обработка →
-- ack/fail). Шаг 2 (0033) — Telegram, шаблоны, журнал отправок.
--
-- Решения:
--   Р1. Вытягивание, а не отправка. Промт этапа описывал dispatch_events() на
--       pg_cron с POST на вебхук n8n. Отказались (подтверждено владельцем
--       17.09.2026): URL с токеном негде хранить — centers.settings читают
--       все роли центра, включая родителя; pg_cron и pg_net в проекте не
--       установлены и требуют тумблеров в дашборде; pg_net вдобавок
--       асинхронный, и результат отправки пришлось бы разбирать вторым
--       cron-джобом. Вход для внешнего планировщика спроектирован ещё на
--       этапе 5: installments_notify (0020, Р10) оставлена доступной
--       снаружи, emit_event_unchecked закрыт даже от service_role.
--       Подробности — reports/stage-6.md, ADR-008.
--   Р2. Роль bot_worker, а не service_role. Промт предлагал отдать воркеру
--       service_role. 0024 снимает табличные гранты у public, anon и
--       authenticated — у service_role остаются ВСЕ таблицы: кто получил
--       доступ к инстансу n8n, делает GET /rest/v1/students?select=* и
--       выгружает карточки детей всех центров. Узкие функции 0031 такой
--       обход не закрывают. bot_worker не имеет ни одного табличного
--       гранта: единственная дверь — definer-функции этого файла.
--   Р3. Обратная проверка auth.uid() в каждой функции очереди — тот же
--       приём, что у installments_notify (0020) и emit_event_unchecked
--       (0018): функция исполняется только вне пользовательской сессии.
--       Грант bot_worker — первый рубеж, проверка — второй: случайный
--       grant ... to authenticated в будущем не откроет очередь.
--   Р4. Порядок выдачи — order by id, причём на результате, а не только в
--       выборке: порядок RETURNING у update ... from задаёт план, а не
--       order by внутри CTE. Иначе два параллельных прогона доставят
--       subscription.exhausted раньше subscription.low_balance (0010 шлёт
--       оба), и родитель прочитает «осталось 2» после «абонемент
--       закончился». Оговорка: id выдаётся bigserial в момент insert, а не
--       коммита, поэтому порядок id — это порядок записи, а не фиксации.
--       Для событий одной транзакции (а low_balance и exhausted приходят
--       именно так) этого достаточно; межтранзакционного порядка очередь
--       не обещает.
--   Р5. Терминальное состояние — одно, в fail_events. release_stale_claims
--       не повторяет его, а вызывает fail_events: иначе событие, на котором
--       обработчик стабильно падает по таймауту, возвращалось бы в очередь
--       каждые десять минут вечно.
--   Р6. event.failed не порождает сам себя: для события этого типа
--       fail_events нового события не эмитит. Иначе очередь растёт из себя
--       — падает обработка event.failed, рождается следующий event.failed.
--   Р7. История помечается обработанной прямо здесь. На staging в events
--       лежат события этапов 0–5; без этого первый же запуск n8n разослал
--       бы двухнедельную историю. Тот же приём, что окно 30 дней у
--       installments_notify (0020, Р9).
--   Р8. Отметка «напоминание отправлено» — отдельная таблица, а не колонка
--       lessons.reminder_sent_at. На lessons есть update и у authenticated
--       (0024), и у registrar (0028): колонку можно было бы обнулить
--       PATCH-ом (второе напоминание родителю) или проставить заранее
--       (напоминания не будет, и в журнале это неотличимо от «время не
--       наступило»). У installments этой дыры нет — таблица закрыта на
--       запись, поэтому due_notified_at подделать нельзя. Идемпотентность
--       держит первичный ключ, а не проверка внутри функции.
--   Р9. Дайджест помечается в своей таблице, а не колонкой в centers:
--       centers под apply_audit и с грантом update у владельца — ежедневная
--       отметка засоряла бы audit_log, а дату можно было бы откатить и
--       получить дайджест повторно. Условие — местный час >= 8, а не = 8:
--       пропущенный прогон (рестарт n8n) иначе съедал бы дайджест за день.
-- =============================================================================


-- 1. Роль воркера ----------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'bot_worker') then
    create role bot_worker nologin noinherit;
  end if;
end;
$$;

-- PostgREST переключается в роль из claim `role` JWT — членство обязательно.
grant bot_worker to authenticator;
grant usage on schema public to bot_worker;

comment on role bot_worker is
  'Внешний обработчик очереди (n8n) и Telegram-бот. Ни одного табличного гранта: только execute на функции очереди, планировщиков и бота. Не service_role — у того остаются все таблицы (0024 снимает гранты только у public/anon/authenticated).';


-- 2. events: состояние обработки ---------------------------------------------------------------

alter table public.events
  add column if not exists claimed_at timestamptz,
  add column if not exists attempts   smallint not null default 0,
  add column if not exists last_error text;

comment on column public.events.claimed_at is 'Пачка отдана обработчику. Снимается ack/fail, возвращается release_stale_claims.';
comment on column public.events.attempts  is 'Сколько раз обработка падала. На третьем провале событие уходит в терминал (Р5).';

-- Р7: всё, что накопилось до появления читателя, обработанным не является,
-- но и рассылке не подлежит.
update public.events set processed_at = now() where processed_at is null;

-- Ведущая колонка — id: выдача упорядочена по нему (Р4).
drop index if exists public.events_unprocessed_idx;
create index if not exists events_pending_idx
  on public.events (id) where processed_at is null and claimed_at is null;
create index if not exists events_claimed_idx
  on public.events (claimed_at) where processed_at is null and claimed_at is not null;


-- 3. Очередь -----------------------------------------------------------------------------------

create or replace function public.claim_events(p_limit integer default 100)
  returns table (
    id         bigint,
    center_id  uuid,
    type       text,
    payload    jsonb,
    created_at timestamptz,
    attempts   smallint
  )
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  -- Р3: только вне пользовательской сессии.
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception 'claim_events: размер пачки — от 1 до 500' using errcode = '22023';
  end if;

  -- order by в picked решает, КАКИЕ строки взять; порядок выдачи наружу он не
  -- задаёт — его определяет план (hash join переставит). Поэтому сортировка
  -- ещё раз, на результате: n8n шлёт пачку в порядке массива (Р4).
  return query
    with picked as (
      select e.id
        from public.events e
       where e.processed_at is null
         and e.claimed_at is null
       order by e.id
       limit p_limit
       for update skip locked
    ),
    claimed as (
      update public.events e
         set claimed_at = now()
        from picked p
       where e.id = p.id
      returning e.id, e.center_id, e.type, e.payload, e.created_at, e.attempts
    )
    select c.id, c.center_id, c.type, c.payload, c.created_at, c.attempts
      from claimed c
     order by c.id;
end;
$$;

comment on function public.claim_events(integer) is
  'Забрать пачку необработанных событий: for update skip locked против двух параллельных прогонов, order by id — против доставки «абонемент закончился» раньше «осталось 2» (Р4).';


create or replace function public.ack_events(p_ids bigint[])
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- claimed_at is not null: закрыть можно только то, что сам же и взял.
  -- Иначе ack_events(array(1..1000000)) молча гасит весь outbox всех
  -- центров, и следа не остаётся — у events нет аудита.
  update public.events e
     set processed_at = now(),
         claimed_at   = null,
         last_error   = null
   where e.id = any(coalesce(p_ids, '{}'::bigint[]))
     and e.processed_at is null
     and e.claimed_at is not null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.ack_events(bigint[]) is
  'Пачка обработана. Закрываются только события, помеченные claimed_at. Повторный ack уже закрытого — ноль строк, не ошибка: доставка at-least-once (ADR-003). Обработчик обязан сверять «просили N — закрыли M»: расхождение значит, что пачку кто-то отобрал по таймауту.';


-- Порог провалов. Больше трёх — не терпение, а очередь, которая крутит одну
-- строку вместо того, чтобы позвать человека.
create or replace function public.fail_events(p_ids bigint[], p_error text default null)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer := 0;
  r       record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    update public.events e
       set attempts     = e.attempts + 1,
           claimed_at   = null,
           -- coalesce, а не присваивание: вызов без текста (release_stale_
           -- claims до появления причины) не должен стирать уже записанную.
           last_error   = coalesce(left(nullif(p_error, ''), 1000), e.last_error),
           processed_at = case when e.attempts + 1 >= 3 then now() else null end
     where e.id = any(coalesce(p_ids, '{}'::bigint[]))
       and e.processed_at is null
       and e.claimed_at is not null
    returning e.id, e.center_id, e.type, e.attempts, e.processed_at
  loop
    v_count := v_count + 1;

    -- Р6: терминальный event.failed не порождает следующий event.failed.
    if r.processed_at is not null and r.type <> 'event.failed' then
      perform public.emit_event_unchecked(
        'event.failed',
        jsonb_build_object(
          'center_id', r.center_id,
          'event_id', r.id,
          'event_type', r.type,
          'attempts', r.attempts
        ),
        r.center_id
      );
    end if;
  end loop;

  return v_count;
end;
$$;

comment on function public.fail_events(bigint[], text) is
  'Обработка пачки не удалась: attempts + 1, событие возвращается в очередь. На третьем провале уходит в терминал и порождает event.failed — кроме событий самого типа event.failed (Р6).';


create or replace function public.release_stale_claims(p_older_than interval default '10 minutes')
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_ids bigint[];
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- skip locked: два одновременных прогона иначе поднимут attempts дважды,
  -- и событие уйдёт в терминал после полутора таймаутов вместо трёх.
  -- Блокировка — в подзапросе: FOR UPDATE нельзя совмещать с агрегатом.
  select array_agg(stale.id) into v_ids
    from (
      select e.id
        from public.events e
       where e.processed_at is null
         and e.claimed_at is not null
         and e.claimed_at < now() - p_older_than
       for update skip locked
    ) stale;

  if v_ids is null then
    return 0;
  end if;

  -- Р5: одна копия терминального правила — в fail_events.
  return public.fail_events(v_ids, 'таймаут обработчика');
end;
$$;

comment on function public.release_stale_claims(interval) is
  'Обработчик забрал пачку и умер: события возвращаются в очередь через fail_events, то есть с ростом attempts — иначе строка, на которой он стабильно падает по таймауту, возвращалась бы вечно (Р5).';


-- 4. Напоминания о занятии -----------------------------------------------------------------------

-- Р8: отметка живёт здесь, а не колонкой в lessons, где её можно переписать
-- прямым PATCH. Таблица закрыта на запись всем — заполняет только функция ниже.
create table if not exists public.lesson_reminders_sent (
  lesson_id uuid primary key,
  center_id uuid not null references public.centers (id) on delete cascade,
  sent_at   timestamptz not null default now(),

  -- Составной FK, как во всех таблицах после 0022: пара «занятие одного
  -- центра, center_id другого» иначе проходит, и политика чтения отдаёт
  -- владельцу чужой идентификатор занятия.
  constraint lesson_reminders_sent_lesson_fk
    foreign key (lesson_id, center_id) references public.lessons (id, center_id) on delete cascade
);

comment on table public.lesson_reminders_sent is
  'Напоминание по занятию отправлено. Первичный ключ и есть инвариант «не чаще одного раза» (Р8); строки кладёт только lesson_reminders().';

create index if not exists lesson_reminders_sent_center_idx on public.lesson_reminders_sent (center_id);

alter table public.lesson_reminders_sent enable row level security;

drop policy if exists lesson_reminders_sent_read on public.lesson_reminders_sent;
create policy lesson_reminders_sent_read on public.lesson_reminders_sent
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() in ('owner', 'admin')
  );

-- service_role тоже: default privileges Supabase выдают ему ALL на новую
-- таблицу, а 0024 у него ничего не снимал. Без этого обладатель
-- service-ключа удаляет отметку — и напоминание уходит второй раз (Р2).
revoke all on table public.lesson_reminders_sent from public, anon, authenticated, service_role;
grant select on public.lesson_reminders_sent to authenticated;


create or replace function public.lesson_reminders()
  returns table (sent_count integer)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer := 0;
  r       record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    select l.id, l.center_id, l.starts_at, l.student_id, l.group_id, l.effective_teacher_id
      from public.lessons l
      -- Центр закрыт, а занятия на неделю вперёд остались planned: без этого
      -- фильтра родители продолжали бы получать напоминания от закрытого
      -- центра. daily_digest его ставит, здесь он был забыт.
      join public.centers c on c.id = l.center_id and c.deleted_at is null
     where l.status = 'planned'
       and l.deleted_at is null
       and l.starts_at > now()
       and l.starts_at <= now() + interval '18 hours'
       and not exists (
         select 1 from public.lesson_reminders_sent s where s.lesson_id = l.id
       )
     order by l.starts_at
  loop
    -- on conflict, а не проверка выше: два прогона одновременно — вставит один.
    insert into public.lesson_reminders_sent (lesson_id, center_id)
    values (r.id, r.center_id)
    on conflict (lesson_id) do nothing;

    if found then
      perform public.emit_event_unchecked(
        'lesson.reminder',
        jsonb_build_object(
          'center_id', r.center_id,
          'lesson_id', r.id,
          'starts_at', r.starts_at,
          'student_id', r.student_id,
          'group_id', r.group_id,
          'teacher_id', r.effective_teacher_id
        ),
        r.center_id
      );
      v_count := v_count + 1;
    end if;
  end loop;

  return query select v_count;
end;
$$;

comment on function public.lesson_reminders() is
  'Занятия, до которых осталось не больше 18 часов, — по одному событию lesson.reminder на занятие. Запуск раз в час, поэтому «18 часов» — это «в ближайший час после пересечения границы», а не ровно 18:00:00.';


-- 5. Ежедневный дайджест -------------------------------------------------------------------------

create table if not exists public.center_digest_runs (
  center_id uuid not null references public.centers (id) on delete cascade,
  digest_on date not null,
  sent_at   timestamptz not null default now(),
  primary key (center_id, digest_on)
);

comment on table public.center_digest_runs is
  'Дайджест за день отправлен. Первичный ключ — инвариант «один раз в день на центр» (Р9); в centers такой отметке не место: таблица под аудитом и с грантом update у владельца.';

alter table public.center_digest_runs enable row level security;

drop policy if exists center_digest_runs_read on public.center_digest_runs;
create policy center_digest_runs_read on public.center_digest_runs
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() in ('owner', 'admin')
  );

-- Как и у lesson_reminders_sent: строка, вставленная обладателем
-- service-ключа сегодняшним числом, отменяет дайджест центра, и в журнале
-- это неотличимо от «ещё не восемь утра».
revoke all on table public.center_digest_runs from public, anon, authenticated, service_role;
grant select on public.center_digest_runs to authenticated;


create or replace function public.daily_digest()
  returns table (center_count integer)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count   integer := 0;
  r         record;
  v_tz      text;
  v_today   date;
  v_lessons integer;
  v_low     integer;
  v_debt    bigint;
  v_overdue integer;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    select c.id as center_id from public.centers c where c.deleted_at is null
  loop
    v_tz := public.center_timezone(r.center_id);

    -- Р9: >= 8, а не = 8 — пропущенный прогон не съедает дайджест за день.
    continue when extract(hour from (now() at time zone v_tz))::int < 8;

    v_today := public.center_today(r.center_id);

    insert into public.center_digest_runs (center_id, digest_on)
    values (r.center_id, v_today)
    on conflict (center_id, digest_on) do nothing;

    continue when not found;

    select count(*)::integer into v_lessons
      from public.lessons l
     where l.center_id = r.center_id
       and l.deleted_at is null
       and l.status <> 'cancelled'
       and (l.starts_at at time zone v_tz)::date = v_today;

    -- _unchecked, а не subscription_state: гейтованная версия зовёт
    -- subscription_visible_to_caller, а та возвращает false, когда
    -- auth.uid() пуст (0015:208) — в планировщике пользователя нет, и
    -- счётчик молча всегда был бы нулём. 0015 держит версию без гейта
    -- ровно для таких вызовов.
    -- coalesce(..., 999): NULL у остатка — это безлимит, а не «ноль занятий»
    -- (0010). Безлимитный абонемент в «заканчивается» не попадает.
    select count(*)::integer into v_low
      from public.subscriptions s
     where s.center_id = r.center_id
       and s.deleted_at is null
       and public.subscription_state_unchecked(s.id) = 'active'
       and coalesce(public.subscription_lessons_left(s.id), 999) <= 2;

    select coalesce(sum(a.price_tiyin), 0)::bigint into v_debt
      from public.attendance a
      join public.students st on st.id = a.student_id and st.center_id = a.center_id
     where a.center_id = r.center_id
       and a.subscription_id is null
       and a.deducted
       and st.deleted_at is null;

    -- 'overdue' и 'cancelled' взаимоисключающи по построению витрины (0020).
    select count(*)::integer into v_overdue
      from public.installments_view v
     where v.center_id = r.center_id
       and v.state = 'overdue';

    perform public.emit_event_unchecked(
      'digest.daily',
      jsonb_build_object(
        'center_id', r.center_id,
        'date', v_today,
        'lessons_today', v_lessons,
        'low_balance', v_low,
        'debt_tiyin', v_debt,
        'installments_overdue', v_overdue
      ),
      r.center_id
    );
    v_count := v_count + 1;
  end loop;

  return query select v_count;
end;
$$;

comment on function public.daily_digest() is
  'Сводка за день владельцу и администраторам: занятия сегодня, заканчивающиеся абонементы, долг, просроченные рассрочки. Один раз в день на центр (center_digest_runs), с местных 08:00 (Р9).';


-- 6. Гранты ---------------------------------------------------------------------------------------

-- Postgres выдаёт EXECUTE роли PUBLIC, Supabase — anon и authenticated;
-- снимаем оба, плюс service_role: очередь — не его дверь (Р2).
revoke all on function public.claim_events(integer)            from public, anon, authenticated, service_role;
revoke all on function public.ack_events(bigint[])             from public, anon, authenticated, service_role;
revoke all on function public.fail_events(bigint[], text)      from public, anon, authenticated, service_role;
revoke all on function public.release_stale_claims(interval)   from public, anon, authenticated, service_role;
revoke all on function public.lesson_reminders()               from public, anon, authenticated, service_role;
revoke all on function public.daily_digest()                   from public, anon, authenticated, service_role;

grant execute on function public.claim_events(integer)          to bot_worker;
grant execute on function public.ack_events(bigint[])           to bot_worker;
grant execute on function public.fail_events(bigint[], text)    to bot_worker;
grant execute on function public.release_stale_claims(interval) to bot_worker;
grant execute on function public.lesson_reminders()             to bot_worker;
grant execute on function public.daily_digest()                 to bot_worker;

-- Вход планировщика переезжает с service_role на bot_worker (Р2). Сегодня
-- installments_notify не зовёт никто: pg_cron не установлен.
revoke all on function public.installments_notify() from service_role;
grant execute on function public.installments_notify() to bot_worker;
