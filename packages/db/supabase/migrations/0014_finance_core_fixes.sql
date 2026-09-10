-- =============================================================================
-- 0014_finance_core_fixes.sql — закрытие находок третьего ревью 0013
--
-- 0013 неизменяема после мержа (CLAUDE.md) — все правки здесь, не там.
-- Полный список находок — architect-ревью написанного 0013 в истории
-- сессии. По каждому пункту ниже — что было не так и что стало.
--
--   1. students.payer_id стал бы неизменяем для любого ребёнка с платежом
--      (FK payments_student_payer_fk без on update). Разведено на
--      student_payers — историю связей, а не текущий указатель.
--   2. Бэкфилл paid_tiyin писал в производную колонку напрямую, из-за чего
--      первый же настоящий платёж или возврат по абонементу, проданному
--      до 0013, давал неверную сумму. Самокорректирующийся: заводит
--      payments-строку с kind='correction' для каждого абонемента с
--      paid_tiyin > 0 и без единой строки payments — работает и там, где
--      0013 применена (paid_tiyin уже проставлен бэкфиллом впрямую), и
--      там, где применяется впервые (в CI paid_tiyin=0 у всех, бэкфилл
--      0013 — no-op на пустой базе, эта миграция тоже no-op).
--   3. Замок lessons.status не покрывал перенос занятия (reschedule_lesson
--      меняет starts_at, не status) — расширен на before insert or update
--      без списка колонок.
--   4. payment_sources осталась с дефолтными грантами Supabase (включая
--      DELETE) — добавлен revoke all, как у всех таблиц с 0008.
--   5. financial_period_guard падал 55000 на DELETE (new не назначен в
--      DELETE-триггере, coalesce(new..., old...) всё равно вычисляет
--      первый аргумент). v_center теперь по ветке tg_op, без обращения к
--      неназначенной записи.
--   6. close_month считал status='planned', а сообщение обещало «без
--      отметки» — разные множества: mark_lesson_status может закрыть
--      занятие без единой отметки посещения. Считает теперь занятия без
--      attendance хотя бы на одного участника.
--   7. Гонка close_month/close_month — insert...on conflict...do update
--      с предварительным exists видел разные снимки. Один атомарный
--      upsert с where в do update и проверкой по returning.
--   8. errors.ts не разбирал 23503 — четыре новых FK возвращали нативный
--      английский текст.
--   9. Название месяца в сообщениях шло через to_char(...,'FMMonth') —
--      зависит от lc_time сервера, не от языка текста. Заменено на
--      русский маппинг рядом с текстом.
--  10. Мелочи: именованные CHECK на amount_tiyin/kind (были безымянные),
--      emit_event в archive/restore_payment_source (были без событий, в
--      отличие от аналогов 0012), when-условие на триггере пересчёта
--      paid_tiyin (не пересчитывал зря на правке одного comment),
--      seed_payment_sources — явная защита по паттерну проекта, две новые
--      функции дописаны в белый список 0007.
--
-- Не закрыто здесь сознательно: гонка close_month против одновременной
-- отметки/платежа в том же месяце (администратор закрывает и специалист
-- отмечает в один и тот же миг) — требует блокировки, разделяемой между
-- close_month и financial_period_guard, а не только между двумя close_month.
-- Редкий сценарий для одного администратора на центр; принято как известное
-- ограничение, не тянет на полный редизайн прямо сейчас.
--
-- Второй раунд (архитектор против написанного выше, до коммита): пункты 1,
-- 3, 6 из списка выше по факту закрывали не до конца.
--   Б1. seed_payment_sources проверял права наоборот — отбивал ровно вызов
--       из триггера centers_seed_payment_sources (роли у только что
--       созданного центра ещё нет), пропускал прямой вызов, когда auth.uid()
--       null. Любая регистрация роняла create_center целиком. Заменено на
--       проверку происхождения вызова (pg_trigger_depth), см. раздел 8.
--   Б2. close_month теперь считает и по attendance — уже смерженный
--       0013_finance_core.test.sql фиксировал старое поведение (планово
--       'done'-занятие без отметки не мешало закрытию). Тест поправлен той
--       же миграцией не трогая (тесты не защищены applied-migration-guard),
--       фикстуре добавлена отметка посещения.
--   Б3. Бэкфилл раздела 2 был голым insert в теле миграции — на пустой CI
--       базе (supabase db reset) отрабатывал до того, как тест успевал
--       завести свою фикстуру, и не мог быть проверен. Вынесен в функцию
--       backfill_subscription_payments(), тест зовёт её сам.
--   Б4. Бэкфилл student_payers (раздел 1) брал только текущего плательщика
--       (students.payer_id) — абонемент, проданный прежнему плательщику
--       ребёнка, не находил пары, своп FK падал на живых данных. Добавлены
--       subscriptions.payer_id и payments.payer_id как источники истории.
--   Б5. close_month (раздел 7) считал через inner join lesson_participants —
--       занятие с пустым составом (group, все вышли) пропадало из подсчёта
--       вместо блокировки. left join + явная проверка на пустой состав;
--       заодно count(distinct l.id) вместо count(*) (число в сообщении
--       считало участников, не занятия) и status='planned' оставлен как
--       отдельное условие, не заменён.
-- Принято отдельно (без кода, см. раздел 2 и 8): ru_month_year — именительный
-- падеж вместо родительного (грамматика), явное условие о порядке деплоя
-- 0013+0014 одним db push.
-- =============================================================================


-- 1. student_payers — история связи ребёнок↔плательщик ----------------------------

-- Append-only: строка не удаляется и не правится, только добавляется новая
-- при смене плательщика. payments ссылается сюда составным FK — тогда смена
-- students.payer_id не блокируется уже существующими платежами (FK без
-- on update иначе привязал бы правку карточки ребёнка к истории оплат
-- намертво), а старые платежи остаются атрибутированы тому, кто платил
-- на самом деле.
create table if not exists public.student_payers (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null default public.current_center()
                references public.centers (id) on delete cascade,
  student_id  uuid not null,
  payer_id    uuid not null,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),

  constraint student_payers_id_center_key unique (id, center_id),
  constraint student_payers_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id),
  constraint student_payers_payer_fk
    foreign key (payer_id, center_id) references public.payers (id, center_id),
  -- Цель составного FK у payments — эта тройка.
  constraint student_payers_student_payer_center_key unique (student_id, payer_id, center_id)
);

create index if not exists student_payers_student_idx on public.student_payers (student_id);
create index if not exists student_payers_center_idx on public.student_payers (center_id);

comment on table public.student_payers is
  'История связей ребёнок↔плательщик. Append-only: смена students.payer_id заводит новую строку, старые платежи остаются привязаны к плательщику, который платил на самом деле.';

call public.apply_tenant_rls('student_payers', false);
call public.apply_audit('student_payers');

-- Только чтение прямым запросом — строки заводит триггер ниже.
revoke all on public.student_payers from anon, authenticated;
grant select on public.student_payers to authenticated;

create or replace function public.students_track_payer()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.payer_id is not null
     and (tg_op = 'INSERT' or new.payer_id is distinct from old.payer_id)
  then
    insert into public.student_payers (center_id, student_id, payer_id)
    values (new.center_id, new.id, new.payer_id)
    on conflict (student_id, payer_id, center_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists students_track_payer on public.students;
create trigger students_track_payer
  after insert or update of payer_id on public.students
  for each row execute function public.students_track_payer();

revoke execute on function public.students_track_payer() from public, anon, authenticated;

-- Бэкфилл: история должна знать не только текущего плательщика
-- (students.payer_id), но и любую пару, уже зафиксированную раньше —
-- плательщика на момент продажи абонемента (subscriptions.payer_id) и,
-- для полноты, плательщика уже существующих платежей (payments.payer_id,
-- из 0013). Без subscriptions: на живой базе абонемент, проданный не
-- текущему плательщику ребёнка (payer_id сменился уже после продажи, до
-- 0013 это ничем не ограничивалось), не находит пары в student_payers —
-- своп FK ниже падает на первой же такой строке, и 0014 откатывается
-- целиком, оставляя 0013 с неисправленным paid_tiyin (раздел 2).
--
-- Именованная функция — тем же приёмом и по той же причине, что
-- backfill_subscription_payments (раздел 2): тест должен уметь позвать
-- бэкфилл на своей фикстуре (абонемент с payer_id, отличным от текущего
-- students.payer_id), а не только доверять коду ревью.
create or replace function public.backfill_student_payers_history()
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  insert into public.student_payers (center_id, student_id, payer_id)
  select s.center_id, s.id, s.payer_id
    from public.students s
   where s.payer_id is not null
  union
  select sub.center_id, sub.student_id, sub.payer_id
    from public.subscriptions sub
   where sub.student_id is not null and sub.payer_id is not null
  union
  select p.center_id, p.student_id, p.payer_id
    from public.payments p
   where p.student_id is not null and p.payer_id is not null
  on conflict (student_id, payer_id, center_id) do nothing;
end;
$$;

revoke execute on function public.backfill_student_payers_history() from public, anon, authenticated;

select public.backfill_student_payers_history();

-- payments_student_payer_fk теперь ссылается на историю, а не на текущее
-- состояние students — смена плательщика у ребёнка с платежами больше не
-- заблокирована. Старый constraint снимается тем же способом, что и любая
-- правка ограничения в проекте — alter table, а не правка 0013.
alter table public.payments drop constraint if exists payments_student_payer_fk;
alter table public.payments
  add constraint payments_student_payer_fk
  foreign key (student_id, payer_id, center_id)
  references public.student_payers (student_id, payer_id, center_id);


-- 2. Самокорректирующийся бэкфилл paid_tiyin --------------------------------------

-- Именованная функция, а не голый insert в теле миграции: тест должен
-- проверять именно эту логику на своей фикстуре, а не состояние базы на
-- момент прогона supabase db reset (на пустой базе бэкфиллить нечего — s
-- из теста появляется уже ПОСЛЕ того, как этот insert давно отработал).
--
-- Чинит искажение бэкфилла 0013 (paid_tiyin писался напрямую, без единой
-- строки payments) и одновременно безопасна там, где 0013 ещё не
-- применялась взаправду (paid_tiyin=0 у всех, where отсекает всё, 0 строк)
-- и при повторном вызове (not exists — уже заведённую строку не дублирует).
-- paid_at — created_at абонемента: условная точка, когда деньги считались
-- внесёнными; на момент применения 0013+0014 одним db push financial_periods
-- пуста, замок эту вставку не заденет — см. примечание о порядке деплоя
-- ниже, у вызова.
create or replace function public.backfill_subscription_payments()
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  insert into public.payments (center_id, payer_id, student_id, subscription_id, amount_tiyin, kind, comment, paid_at)
  select s.center_id, s.payer_id, s.student_id, s.id, s.paid_tiyin, 'correction',
         'Перенос остатка при переходе на payments (0013)', s.created_at
    from public.subscriptions s
   where s.paid_tiyin > 0
     and not exists (select 1 from public.payments p where p.subscription_id = s.id);
  -- payments_recalc_paid (0013) сама пересчитает paid_tiyin из этой строки —
  -- отдельный update не нужен, значение то же, что уже было.
end;
$$;

revoke execute on function public.backfill_subscription_payments() from public, anon, authenticated;

-- Деплой полагается на то, что 0013 и 0014 катятся одним db push (staging
-- сейчас так и устроен) — на момент выполнения этой строки close_month ещё
-- не существовал(а) ни секунды сам по себе, financial_periods гарантированно
-- пуста. Если когда-нибудь 0013/0014 разъедутся во времени и кто-то успеет
-- закрыть месяц между ними — платёж с paid_at в этом месяце упадёт на
-- замке; на практике это означало бы, что close_month уже был на проде
-- без 0014, чего по трекеру миграций не происходило.
select public.backfill_subscription_payments();


-- 3. Замок lessons — перенос занятия и не только смена статуса --------------------

drop trigger if exists financial_period_guard_lessons on public.lessons;
create trigger financial_period_guard_lessons
  before insert or update on public.lessons
  for each row execute function public.financial_period_guard();
-- Без списка колонок: reschedule_lesson не трогает status (0011:407-450),
-- financial_period_guard_lessons на "before update of status" его не видел
-- вовсе. Функция уже сравнивала new.starts_at/old.starts_at — правка только
-- в объявлении триггера, тело функции (раздел 5 ниже) не про даты, а про
-- вычисление центра для DELETE-ветки.


-- 4. payment_sources — узкие гранты, как у всех таблиц с 0008 ---------------------

-- 0013 сделала только revoke update — Supabase выдаёт authenticated полный
-- набор на новую таблицу по умолчанию (0008:683-687), включая DELETE:
-- источник оплаты можно было физически удалить в обход archive_payment_source.
revoke all on public.payment_sources from anon, authenticated;
grant select, insert on public.payment_sources to authenticated;
grant update (code, name, is_active, sort) on public.payment_sources to authenticated;


-- 5. financial_period_guard — DELETE больше не падает 55000 -----------------------

-- coalesce(new.center_id, old.center_id) первой строкой вычислял new даже
-- когда new не назначен (DELETE) — обращение к полю неназначенной записи
-- в plpgsql бросает 55000 независимо от короткого замыкания coalesce,
-- потому что ошибка — в самом обращении к полю, а не в результате coalesce.
create or replace function public.financial_period_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid;
  v_old_date date;
  v_new_date date;
  v_blocked  date;
begin
  if tg_op = 'DELETE' then
    v_center := old.center_id;
  else
    v_center := new.center_id;
  end if;

  if tg_table_name = 'payments' then
    if tg_op <> 'DELETE' then
      v_new_date := (new.paid_at at time zone public.center_timezone(v_center))::date;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := (old.paid_at at time zone public.center_timezone(v_center))::date;
    end if;

  elsif tg_table_name = 'attendance' then
    if tg_op <> 'DELETE' then
      select (l.starts_at at time zone public.center_timezone(v_center))::date into v_new_date
        from public.lessons l where l.id = new.lesson_id;
    end if;
    if tg_op <> 'INSERT' then
      select (l.starts_at at time zone public.center_timezone(v_center))::date into v_old_date
        from public.lessons l where l.id = old.lesson_id;
    end if;

  elsif tg_table_name = 'lessons' then
    if tg_op <> 'DELETE' then
      v_new_date := (new.starts_at at time zone public.center_timezone(v_center))::date;
    end if;
    if tg_op <> 'INSERT' then
      v_old_date := (old.starts_at at time zone public.center_timezone(v_center))::date;
    end if;
  end if;

  if v_new_date is not null and exists (
       select 1 from public.financial_periods fp
        where fp.center_id = v_center
          and fp.month = date_trunc('month', v_new_date)::date
          and fp.closed_at is not null
     ) then
    v_blocked := v_new_date;
  elsif v_old_date is not null and exists (
       select 1 from public.financial_periods fp
        where fp.center_id = v_center
          and fp.month = date_trunc('month', v_old_date)::date
          and fp.closed_at is not null
     ) then
    v_blocked := v_old_date;
  end if;

  if v_blocked is not null then
    raise exception 'Месяц % закрыт — операции с этой датой запрещены', public.ru_month_year(v_blocked)
      using errcode = '22023';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;


-- 6. Русское название месяца в сообщениях -----------------------------------------

-- to_char(..., 'FMMonth YYYY') зависит от lc_time сервера (обычно
-- английская локаль на raw Postgres) — сообщение получалось наполовину
-- русским, наполовину английским. Маппинг рядом с текстом, не от локали.
-- Именительный падеж («январь», не «января») — сообщения ниже строятся как
-- «Месяц <название> <год>», куда родительный не встаёт грамматически
-- («Месяц января 2026 закрыт» читается разбито). close_month берёт
-- отдельную формулировку без слова «месяц» — туда родительный тоже не
-- вставить без перестройки фразы.
create or replace function public.ru_month_year(p_date date)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select (array[
    'январь','февраль','март','апрель','май','июнь',
    'июль','август','сентябрь','октябрь','ноябрь','декабрь'
  ])[extract(month from p_date)::int] || ' ' || extract(year from p_date)::text;
$$;

revoke execute on function public.ru_month_year(date) from public, anon, authenticated;
grant execute on function public.ru_month_year(date) to authenticated;


-- 7. close_month — без гонки, с правильным условием, с русским месяцем ------------

create or replace function public.close_month(p_month date)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center      uuid := public.current_center();
  v_month       date := date_trunc('month', p_month)::date;
  v_open_count  integer;
  v_period_id   uuid;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_month >= date_trunc('month', public.center_today(v_center))::date then
    raise exception 'Закрыть можно только полностью прошедший месяц' using errcode = '22023';
  end if;

  -- Не только "занятий в статусе planned" (это разные множества:
  -- mark_lesson_status закрывает занятие 'done' без единой отметки), а ЕЩЁ и
  -- "занятий без отметки хотя бы одного участника" — планово 'planned'
  -- остаётся отдельным условием (не заменяется, а дополняется): пока неясно,
  -- будет ли будущий расчёт зарплаты (этап 6) смотреть на lessons.status
  -- где-то помимо attendance, безопаснее не терять существовавшую защиту.
  -- left join, не join: групповое занятие с пустым составом на дату (все
  -- вышли из группы, rebuild_lesson_participants дал 0 строк) не должно
  -- пропадать из подсчёта — такое физически нельзя отметить, closeable оно
  -- быть не должно. lp.student_id is null — ровно этот случай после left
  -- join. count(distinct l.id), не count(*): группа из пяти с тремя
  -- неотмеченными иначе считалась бы как "3 занятия", а не как одно.
  -- Пересчёт каждый раз, не по предпросмотру: между открытием диалога и
  -- нажатием кнопки специалист мог доотметить.
  select count(distinct l.id) into v_open_count
    from public.lessons l
    left join public.lesson_participants lp on lp.lesson_id = l.id
   where l.center_id = v_center
     and l.deleted_at is null
     and l.status <> 'cancelled'
     and (l.starts_at at time zone public.center_timezone(v_center))::date >= v_month
     and (l.starts_at at time zone public.center_timezone(v_center))::date < (v_month + interval '1 month')::date
     and (
           l.status = 'planned'
           or lp.student_id is null
           or not exists (
                select 1 from public.attendance a
                 where a.lesson_id = l.id and a.student_id = lp.student_id
              )
         );

  if v_open_count > 0 then
    raise exception '%: занятий с неотмеченными участниками — %, сначала отметьте или отмените',
      public.ru_month_year(v_month), v_open_count
      using errcode = '22023';
  end if;

  -- Один атомарный upsert вместо exists-проверки и отдельного insert: два
  -- параллельных close_month видели два разных снимка и оба проходили
  -- предпроверку. where в do update оставляет already-closed строку как
  -- есть — returning тогда пуст, и это единственный признак "уже закрыт",
  -- которому можно верить под конкуренцией.
  insert into public.financial_periods (center_id, month, closed_at, closed_by)
  values (v_center, v_month, now(), auth.uid())
  on conflict (center_id, month) do update
    set closed_at = excluded.closed_at, closed_by = excluded.closed_by
  where public.financial_periods.closed_at is null
  returning id into v_period_id;

  if v_period_id is null then
    raise exception 'Месяц % уже закрыт', public.ru_month_year(v_month) using errcode = '22023';
  end if;

  perform public.emit_event('period.closed',
    jsonb_build_object('center_id', v_center, 'month', v_month), v_center);
end;
$$;

create or replace function public.reopen_month(p_month date)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_month  date := date_trunc('month', p_month)::date;
begin
  if coalesce(public.my_role(), '') <> 'owner' then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.financial_periods
     set closed_at = null, closed_by = null
   where center_id = v_center and month = v_month and closed_at is not null;

  if not found then
    raise exception 'Месяц % не закрыт', public.ru_month_year(v_month) using errcode = '42704';
  end if;

  perform public.emit_event('period.reopened',
    jsonb_build_object('center_id', v_center, 'month', v_month), v_center);
end;
$$;


-- 8. Мелочи из находки 13 ------------------------------------------------------------

-- Именованные CHECK — безымянные давали "Действие нарушает правила центра"
-- вместо понятного текста через CHECK_MESSAGES.
alter table public.payments drop constraint if exists payments_amount_tiyin_check;
alter table public.payments add constraint payments_amount_not_zero check (amount_tiyin <> 0);
alter table public.payments drop constraint if exists payments_kind_check;
alter table public.payments add constraint payments_kind_known check (kind in ('payment', 'refund', 'correction'));

-- Пересчёт paid_tiyin незачем гонять на правке одного comment — тот же
-- приём, что мог бы стоять у attendance_recalc, но там пересчёт зависит
-- от status_id тоже; здесь ровно две колонки решают исход.
drop trigger if exists payments_recalc_paid on public.payments;
create trigger payments_recalc_paid
  after insert or delete or update of amount_tiyin, subscription_id on public.payments
  for each row execute function public.payments_recalc_trigger();

-- archive/restore_payment_source не эмитили события — расхождение с пятью
-- аналогами 0012 (attendance_statuses/subscription_types).
create or replace function public.archive_payment_source(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.payment_sources
     set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Источник оплаты не найден' using errcode = '42704';
  end if;

  perform public.emit_event('payment_source.archived',
    jsonb_build_object('center_id', v_center, 'source_id', p_id), v_center);
end;
$$;

create or replace function public.restore_payment_source(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_code   text;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select code into v_code
    from public.payment_sources
   where id = p_id and center_id = v_center and deleted_at is not null;

  if not found then
    raise exception 'Источник оплаты не найден в архиве' using errcode = '42704';
  end if;

  begin
    update public.payment_sources
       set deleted_at = null
     where id = p_id and center_id = v_center;
  exception
    when unique_violation then
      raise exception 'Код «%» уже занят другим источником — переименуйте перед восстановлением', v_code
        using errcode = '22023';
  end;

  perform public.emit_event('payment_source.restored',
    jsonb_build_object('center_id', v_center, 'source_id', p_id), v_center);
end;
$$;

-- seed_payment_sources — явная защита по паттерну проекта (0007 §5:
-- security definer функция обязана проверять права, даже если execute
-- никому не выдан явно; второй рубеж, а не формальность).
--
-- Проверка — не по роли (её у только что созданного центра ещё нет ни у
-- кого, my_role() законно NULL), а по происхождению вызова: тот же приём,
-- что у rebuild_lesson_participants (0007_lock_down_participant_functions.
-- sql:44). centers_seed_payment_sources зовёт эту функцию из AFTER INSERT
-- на centers — pg_trigger_depth() там уже >= 1. Отбивается только прямой
-- вызов живым пользователем (pg_trigger_depth() = 0 и auth.uid() не null);
-- вызов из триггера и вызов от service_role/миграции (auth.uid() null)
-- пропускаются оба. Прежняя версия проверяла наоборот — coalesce(my_role(),
-- '') not in (...) отбивала ровно вызов из триггера при создании центра
-- (роли ещё нет) и пропускала прямой вызов, когда auth.uid() null: любая
-- регистрация нового пользователя ловила 42501 на первом же create_center
-- и откатывалась целиком, ни один pgTAP этого не проверял (0001_foundation.
-- test.sql:149 вызывает create_center только от anon).
create or replace function public.seed_payment_sources(p_center_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if pg_trigger_depth() = 0 and auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  insert into public.payment_sources (center_id, code, name, sort) values
    (p_center_id, 'cash',     'Наличные', 10),
    (p_center_id, 'mbank',    'Mbank',    20),
    (p_center_id, 'odengi',   'O!Dengi',  30),
    (p_center_id, 'elcart',   'Elcart',   40),
    (p_center_id, 'transfer', 'Перевод',  50)
  on conflict do nothing;
end;
$$;


-- Гранты -------------------------------------------------------------------------

revoke execute on function public.students_track_payer() from public, anon, authenticated;

revoke execute on function
  public.archive_payment_source(uuid),
  public.restore_payment_source(uuid),
  public.close_month(date),
  public.reopen_month(date)
  from public, anon, authenticated;

grant execute on function
  public.archive_payment_source(uuid),
  public.restore_payment_source(uuid),
  public.close_month(date),
  public.reopen_month(date)
  to authenticated;
