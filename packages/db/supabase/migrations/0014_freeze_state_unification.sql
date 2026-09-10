-- =============================================================================
-- 0014_freeze_state_unification.sql — заморозка: один источник правды
--
-- Симптом (чек-лист этапа 4, п.3): "отметить посещение во время заморозки —
-- исключение" тихо не работало, отметка уходила в долг. Причина оказалась
-- глубже точечного бага: subscriptions.status='frozen' (колонка, пишется
-- один раз) и диапазон в subscription_freezes (таблица с EXCLUDE) расходятся,
-- как только заморозка с заранее известной датой конца истекает по
-- календарю — unfreeze_subscription умеет закрыть только БЕССРОЧНУЮ
-- заморозку, датированная просто перестаёт покрывать "сегодня", а status
-- остаётся 'frozen' навсегда. attendance_fill_and_check при этом всегда
-- проверял диапазон дат напрямую (не status) — значит баланс/бейдж/долги
-- показывали "нет абонемента" дольше, чем длилась реальная заморозка, а
-- списание тем временем продолжало идти как обычно.
--
-- Четыре раунда ревью architect-субагента (история сессии) + 5 продуктовых
-- решений владельца (11.09.2026):
--   1. Пакеты "N занятий" (kind='lessons') не получают ends_at вообще —
--      заморозке для них нечего сдвигать. Чек-лист правится под
--      period-only семантику (см. docs/Roadmap/stages.md).
--   2. Закрытую (датированную) заморозку нельзя снять раньше срока —
--      осознанно; "разморозить" означает закончить сегодня или раньше,
--      планирование конца вперёд — дело freeze_subscription(p_to). Ещё не
--      начавшуюся заморозку можно ОТМЕНИТЬ целиком (см. раздел 7) — это не
--      противоречит решению, "снять раньше срока" здесь неприменимо: срок
--      ещё не наступил.
--   3. Новое исключение блокирует только НОВЫЙ подбор абонемента.
--      Смена статуса у уже привязанной отметки заморозку не проверяет —
--      тест 25 в 0010_stage4_hardening.test.sql остаётся в силе как есть.
--   4. Массовая отметка группы — откат целиком (как сейчас), но текст
--      исключения называет конкретного ребёнка.
--   5. Исключение распространяется только на списывающие статусы — оно и
--      так только внутри "if new.deducted", смена статуса на непосещение
--      никогда не подбирает абонемент заново.
--
-- Осознанно ВНЕ рамок этой миграции (найдено architect, не устранено):
--   - Перенос уже отмеченного занятия (reschedule_lesson) в окно
--     существующей заморозки — другой механизм, не абонемент. lessons.status
--     остаётся 'planned' и после отметки (тест 29, 0010), reschedule не
--     видит разницы. Инвариант "нельзя списать в дни заморозки" держится
--     на 2 рёбрах из 3 (отметка, создание заморозки) — закреплено тестом
--     ниже как ИЗВЕСТНЫЙ, а не полный, пробел.
--   - subscription_types.kind/period_days у уже НЕ проданных абонементов
--     остаются редактируемыми свободно (защищены только у типов с
--     проданными абонементами, раздел 4). Правильное решение "на всю
--     глубину" — замораживать period_days на самой строке subscriptions
--     при продаже (как lesson_price_tiyin, 0008:193-195) — отдельная,
--     более крупная задача.
--   - Панель отметки (schedule/actions.ts) показывает баланс на "сегодня",
--     а attendance_fill_and_check решает по ДАТЕ ЗАНЯТИЯ — для занятий
--     около границы заморозки, отличных от сегодняшней даты, лейбл
--     "заморожен" может не совпасть с тем, что ответит отметка. Полный
--     фикс — RPC на дату занятия, отдельная задача.
--   - Бейдж специалиста при allow_negative + одновременно исчерпан и
--     заморожен: subscription_state называет такой абонемент 'exhausted'
--     (раздел 5, порядок CASE), бейдж поэтому покажет «нет» — а отметка
--     всё равно подберёт его (allow_negative проходит фильтр остатка) и
--     откажет «заморожен». Узкая, не денежная и не про доступ комбинация —
--     зафиксирована тестом как известное поведение, а не устранена.
--   - subscription_freezes: запись закрыта только грантом (0008:687-696),
--     явной RLS-политики на insert/update нет. Не блокер (грант закрыт
--     всем ролям), но теперь, когда диапазон — единственный источник
--     правды, цена будущего неосторожного grant insert выше — закреплено
--     тестом ниже, а не кодом.
-- =============================================================================


-- 1. Нормализация legacy-формы открытого конца -------------------------------------

-- 0008 писала открытый конец датой 'infinity'::date (0010 это уже не
-- делает — комментарий у freeze_subscription ниже объясняет, почему это
-- была ошибка). До этой строки в проекте были обе формы одновременно
-- (upper_inf() и upper() = 'infinity'::date) — тексту нового исключения
-- ниже пришлось бы различать три случая вместо двух. Порядок в файле
-- важен: нормализация идёт ДО guard-триггера в разделе 6 — иначе триггер
-- сработает на этом самом UPDATE и, если внутри диапазона есть списанная
-- отметка, уронит миграцию.
update public.subscription_freezes
   set period = daterange(lower(period), null, '[)')
 where upper(period) = 'infinity'::date;

-- Отдельный, самостоятельный бэкфилл (не про 'infinity' выше): на момент
-- написания миграции строк со status='frozen' — 0 (проверено через
-- Supabase MCP), но нормализация должна быть безопасна и для среды, где
-- что-то успело записать это значение в обход RPC. Не читать как "значит
-- 'infinity'-строк тоже 0" — это два независимых факта о разных данных.
update public.subscriptions set status = 'active' where status = 'frozen';


-- 2. status перестаёт уметь быть 'frozen' -------------------------------------------

-- Второй, более узкий constraint поверх старого (0008:205-206,
-- 'active','frozen','cancelled') — не дропаем старый: его точное имя в
-- базе не гарантировано (миграция неизменяема после мержа, гадать с
-- DROP CONSTRAINT рискованно), а более узкий constraint поверх более
-- широкого просто делает старый избыточным, не мешая ему. Симметрично
-- тому, как exhausted/expired никогда не были в этом constraint —
-- frozen теперь тоже только вычисляется, не хранится (см. subscription_state
-- ниже и "Статусы exhausted и expired не хранятся", reports/stage-4.md).
alter table public.subscriptions
  add constraint subscriptions_status_no_frozen_check
  check (status in ('active', 'cancelled'));


-- 3. Пакеты занятий не получают срок ------------------------------------------------

-- Product-решение 1: у kind='lessons' ends_at не появляется никогда,
-- потому что period_days у них не задаётся. Без constraint это была
-- только конвенция тернарника в React (settings/subscription-types/
-- actions.ts) — прямой insert в обход формы мог завести пакет со сроком,
-- и заморозка начала бы сдвигать ends_at там, где чек-лист обещает, что
-- сдвигать нечего. Валидируем сразу без NOT VALID: проверено через
-- Supabase MCP — строк kind='lessons' с period_days is not null сейчас 0.
alter table public.subscription_types
  add constraint subscription_types_lessons_no_period_check
  check (kind <> 'lessons' or period_days is null);

-- kind/period_days определяют, получает ли уже ПРОДАННЫЙ абонемент
-- ends_at (через join в subscriptions_apply_freeze_shift, 0008:534-556,
-- по ТЕКУЩЕМУ period_days типа, не по снимку на момент продажи) —
-- редактируемые после продажи, они меняют срок задним числом, то же
-- нарушение принципа "цена абонемента замораживается при продаже"
-- (0008:193-195), только для срока. Инвариант — триггер, а не отзыв
-- гранта: колоночный revoke (первая версия этого файла) ломал форму
-- настроек целиком, потому что она шлёт kind/period_days в каждом PATCH
-- независимо от того, что реально правит администратор (apps/web/app/app/
-- settings/subscription-types/actions.ts). Триггер бьёт только по факту —
-- смене значения у типа, на который уже что-то продано; тип без единого
-- проданного абонемента остаётся редактируемым полностью.
create or replace function public.subscription_types_guard_sold_fields()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if (new.kind is distinct from old.kind or new.period_days is distinct from old.period_days)
     and exists (select 1 from public.subscriptions s where s.type_id = old.id)
  then
    raise exception 'У этого типа уже есть проданные абонементы — kind и period_days менять нельзя, заведите новый тип'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists subscription_types_guard_sold_fields on public.subscription_types;
create trigger subscription_types_guard_sold_fields
  before update of kind, period_days on public.subscription_types
  for each row execute function public.subscription_types_guard_sold_fields();


-- 4. Видимость заморозки для родителя и специалиста ---------------------------------

-- subscription_state (раздел 5) должна отвечать одинаково для admin и для
-- родителя/специалиста, которым видна только ИХ часть данных. Но
-- subscription_freezes закрыта RLS-политикой tenant_admin (0008:290 →
-- только owner/admin) — если бы читающая функция оставалась invoker,
-- чтение этой таблицы для родителя вернуло бы 0 строк не потому, что
-- заморозки нет, а потому что RLS её спрятала: родитель увидел бы
-- "активен" в дни, когда центр считает абонемент замороженным. Тот же
-- класс ошибки, что и "политика, ссылающаяся на другую таблицу с RLS" в
-- CLAUDE.md — только не policy-to-policy рекурсия, а invoker-функция,
-- тихо получающая урезанный RLS-снимок вместо отказа.
--
-- Без ветки teacher: у роли authenticated нет отдельного грамма для
-- owner/admin/parent/teacher — это одна и та же Postgres-роль, разница
-- только в my_role() внутри тела. Значит "специалисту нельзя, остальным
-- можно" нечем выразить в GRANT — это решается тем, что ЭТА функция
-- возвращает для teacher false, а вызывающие её (subscription_current_
-- freeze, subscription_freeze_days, раздел 5) на false отвечают NULL,
-- сами оставаясь выданными authenticated (раздел "Права"). Раньше (первая
-- версия этого файла) ветка teacher здесь была нужна, чтобы subscription_
-- state впускала бейдж, — но это давало специалисту, вызвавшему
-- subscription_state напрямую с известным subscription_id (виден в
-- attendance.subscription_id по его же занятиям), больше категорий
-- состояния (exhausted/expired/cancelled), чем бейдж вообще показывает
-- (сворачивает их все в "нет") — обратное тому, что обещает 0008:245-248.
-- Теперь бейдж читает состояние через subscription_state_unchecked
-- напрямую (сам уже проверил teacher_teaches_student на входе, строка
-- ниже) — та функция вообще без грантов, у неё нет своей проверки видимости.
create or replace function public.subscription_visible_to_caller(p_subscription_id uuid)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_sub  public.subscriptions;
  v_role text;
begin
  if auth.uid() is null then
    return false;
  end if;

  select * into v_sub from public.subscriptions where id = p_subscription_id;
  if not found then
    return false;
  end if;

  v_role := coalesce(public.my_role(), '');
  return coalesce(
    (v_role in ('owner', 'admin') and v_sub.center_id = public.current_center())
    or (v_role = 'parent' and public.parent_of_student(v_sub.student_id)),
    false
  );
end;
$$;

-- Читает subscription_freezes сама, под собственными правами definer —
-- если бы проверку видимости оставили рядом, а чтение снаружи (в invoker-
-- функции), результат не изменился бы: RLS всё равно отфильтрует строку
-- ДО того, как булев предикат вообще будет с чем сравнивать. Возвращает
-- daterange, а не всю строку subscription_freezes: та тащит reason/
-- created_by/center_id и раздала бы их специалисту через PostgREST.
create or replace function public.subscription_current_freeze(p_subscription_id uuid, p_on_date date)
  returns daterange
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select f.period from public.subscription_freezes f
   where f.subscription_id = p_subscription_id
     and f.period @> p_on_date
     and public.subscription_visible_to_caller(p_subscription_id)
   order by lower(f.period) desc limit 1;
$$;


-- 5. subscription_state: definer со своей проверкой, frozen — вычисляемое ------------

-- Была security invoker: сама таблица subscriptions ограничивала видимость
-- через свою RLS (owner/admin — центр, parent — свои дети, teacher — ничего,
-- 0008:249-257), и этого хватало. Определив subscription_current_freeze
-- выше как definer, нельзя было оставить subscription_state invoker: её
-- собственный вызов current_freeze выполнялся бы с правами РЕАЛЬНОГО
-- вызывающего, а значит current_freeze пришлось бы выдать authenticated
-- напрямую — и тогда специалист получил бы прямой путь к точным датам
-- заморозки в обход бейджа (раздел 4). Definer здесь с ЯВНОЙ проверкой
-- видимости — тот же приём, что уже применяют student_subscription_badge
-- и subscription_summary, просто до сих пор не был нужен этой функции.
-- Сама логика без проверки видимости — вызывается ТОЛЬКО оттуда, где
-- доступ уже подтверждён другим способом: badge (teacher_teaches_student/
-- parent_of_student на входе, ниже), freeze_subscription/unfreeze_
-- subscription (owner/admin по роли и центру на входе). НЕ выдана
-- authenticated (раздел "Права") — прямой вызов посторонним не должен
-- давать больше, чем публичная обёртка ниже.
create or replace function public.subscription_state_unchecked(p_subscription_id uuid)
  returns text
  language sql
  stable
  security definer
  set search_path = ''
as $$
  -- Порядок важен: cancelled → expired → exhausted → frozen → active, НЕ
  -- frozen перед exhausted. Заморозка отсекается предикатом на остаток
  -- ещё до всякой заморозки в attendance_fill_and_check (замороженный и
  -- одновременно исчерпанный без allow_negative ведёт себя как обычный
  -- исчерпанный — списывать всё равно нечего), и ЯРЛЫК обязан совпадать
  -- с этим поведением. Иначе /app/debts, отфильтровывая frozen, спрятал
  -- бы реально растущий долг — деньги, которые никто не увидит, пока
  -- родитель не спросит.
  -- Заморозка — прямым select из subscription_freezes, НЕ через
  -- subscription_current_freeze: та сама вызывает subscription_visible_
  -- to_caller (без ветки teacher) и вернула бы NULL специалисту даже
  -- здесь — свело бы на нет весь смысл unchecked-версии, ради которой её
  -- и завели (бейдж переставал бы видеть "заморожен" для teacher).
  -- unchecked уже вызывается только из мест, где доступ подтверждён
  -- иначе, второй гейт тут не нужен и вреден.
  select case
    when s.status = 'cancelled' then 'cancelled'
    when s.ends_at is not null
         and s.ends_at < public.center_today(s.center_id) then 'expired'
    when s.lessons_total is not null
         and s.lessons_total - s.lessons_used - s.lessons_written_off <= 0 then 'exhausted'
    when exists (
      select 1 from public.subscription_freezes f
       where f.subscription_id = s.id and f.period @> public.center_today(s.center_id)
    ) then 'frozen'
    else 'active'
  end
  from public.subscriptions s
  where s.id = p_subscription_id;
$$;

-- Публичная обёртка: гейт видимости (без ветки teacher, см. subscription_
-- visible_to_caller выше), дальше — та же логика, что и раньше, только
-- вынесенная в unchecked-версию. Была security invoker: сама таблица
-- subscriptions ограничивала видимость через свою RLS (owner/admin —
-- центр, parent — свои дети, teacher — ничего, 0008:249-257), и этого
-- хватало. Определив subscription_current_freeze выше как definer, нельзя
-- было оставить subscription_state invoker: её собственный вызов current_
-- freeze выполнялся бы с правами РЕАЛЬНОГО вызывающего, а значит current_
-- freeze пришлось бы выдать authenticated напрямую.
create or replace function public.subscription_state(p_subscription_id uuid)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if not public.subscription_visible_to_caller(p_subscription_id) then
    return null;
  end if;
  return public.subscription_state_unchecked(p_subscription_id);
end;
$$;

-- Тот же перенос definer, что и subscription_state (была ровно та же
-- болезнь: coalesce(sum(...), 0) не отличал "нет заморозок" от "не
-- видно" — родителю возвращала 0 вместо реального числа дней). Грант
-- authenticated остаётся (раздел "Права") — родителю и владельцу эта
-- функция нужна напрямую, а от специалиста её защищает не грант (роль в
-- Postgres одна на всех), а сама visible_to_caller внутри: teacher получит
-- NULL, а не число. 'infinity'-форма нормализована в разделе 1,
-- поэтому sum() по upper-lower корректен без явного case для открытых
-- заморозок: upper() на неограниченной верхней границе даёт NULL, sum()
-- его пропускает — тот же результат, что раньше давал явный `when
-- upper_inf then 0`, без отдельной ветки.
create or replace function public.subscription_freeze_days(p_subscription_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select case when not public.subscription_visible_to_caller(p_subscription_id) then null
    else coalesce((
      select sum(upper(f.period) - lower(f.period))
        from public.subscription_freezes f
       where f.subscription_id = p_subscription_id
    ), 0)::int
  end;
$$;


-- 6. freeze_subscription / unfreeze_subscription: status больше не пишется ----------

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
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Блокировка здесь — больше не "для отображения": раньше она попутно
  -- сериализовалась с выбором абонемента в attendance_fill_and_check через
  -- живой status='frozen'. Теперь status не пишется вовсе, и эта строка —
  -- ЕДИНСТВЕННОЕ, что не даёт двум одновременным freeze_subscription на
  -- одном абонементе пройти проверку "нет незакрытой заморозки" ниже на
  -- одном и том же снимке. Не убирать при следующей уборке кода.
  select * into v_sub from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  -- coalesce: subscription_state теперь умеет возвращать NULL (гейт
  -- видимости не пропустил бы чужого) — здесь это недостижимо (роль и
  -- центр уже проверены выше), но `NULL <> 'active'` тоже NULL, и `if`
  -- молча не сработал бы. Тот же шаблон, что и coalesce(my_role(), '')
  -- в шести RPC 0010 — для функции, которая NULL возвращает штатно.
  v_state := coalesce(public.subscription_state(p_id), '');
  if v_state <> 'active' then
    raise exception 'Заморозить можно только действующий абонемент, а он «%»', v_state
      using errcode = '22023';
  end if;

  if p_from is null then
    raise exception 'Не указана дата начала заморозки' using errcode = '22023';
  end if;

  -- Явная защёлка вместо побочного эффекта колонки: раньше вторая
  -- заморозка была невозможна случайно, потому что status='frozen' сразу
  -- после первой держал subscription_state='frozen' независимо от дат.
  -- Теперь frozen вычисляется из диапазона и НЕ мешает будущей, ещё не
  -- начавшейся заморозке — без этой проверки два вызова с непересекающимися
  -- периодами создали бы две строки; subscription_freeze_days сложил бы
  -- оба интервала, а subscriptions_apply_freeze_shift сдвинул бы ends_at
  -- на их сумму, хотя реально прошёл только один. isempty() исключает
  -- отменённую-до-начала заморозку (раздел 7 ниже, unfreeze схлопывает её
  -- в пустой диапазон вместо удаления строки) — иначе отменённая, но ещё
  -- формально будущая заморозка навсегда блокировала бы новую.
  if exists (
    select 1 from public.subscription_freezes f
     where f.subscription_id = p_id
       and not isempty(f.period)
       and (upper_inf(f.period) or upper(f.period) > public.center_today(v_center))
  ) then
    raise exception 'У абонемента уже есть незакрытая заморозка' using errcode = '22023';
  end if;

  if p_to is not null and p_to < p_from then
    raise exception 'Дата окончания заморозки раньше начала' using errcode = '22023';
  end if;

  -- Открытый конец — неограниченная граница (NULL), не дата 'infinity':
  -- upper_inf() для 'infinity'::date ложен, unfreeze_subscription не находит
  -- такую заморозку открытой, а upper(period)-lower(period) падает на
  -- "cannot subtract infinite dates" (баг 0008, исправлено в 0010).
  insert into public.subscription_freezes (center_id, subscription_id, period)
  values (v_center, p_id, daterange(p_from, p_to, '[)'));

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
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Близнец freeze_subscription: без блокировки абонемента тот же
  -- интерливинг с отметкой, что и у заморозки.
  perform 1 from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  -- Ищем и бессрочную, и ещё НЕ НАЧАВШУЮСЯ датированную заморозку: обе
  -- "открыты" в смысле, который здесь важен — обе можно отменить целиком.
  -- Датированная, уже начавшаяся, сюда не попадает — её закрыть раньше
  -- срока нельзя (продуктовое решение 2), и это ветка ниже (lower &lt;=
  -- сегодня) корректно не находит замену и падает в обычную логику.
  select * into v_open from public.subscription_freezes f
   where f.subscription_id = p_id and f.center_id = v_center
     and (upper_inf(f.period) or lower(f.period) > public.center_today(v_center))
   order by lower(f.period) desc limit 1;
  if not found then
    raise exception 'У абонемента нет открытой заморозки' using errcode = '42704';
  end if;

  -- Ещё не начавшуюся заморозку ("с понедельника", сегодня — среда) нечем
  -- закрыть датой в прошлом: p_to = сегодня < lower(period), обычная
  -- проверка ниже отказала бы "дата окончания раньше начала", а
  -- единственная содержательная дата вперёд (p_to = lower) запрещена
  -- следующей проверкой ("разморозить можно только сегодня или раньше").
  -- Без этой ветки защёлка выше (раздел, "уже есть незакрытая заморозка")
  -- заперла бы абонемент навсегда: заморозить нельзя (уже есть незакрытая),
  -- разморозить нечем (обе проверки отказывают). "Разморозить" для ещё не
  -- начавшейся заморозки значит "отменить целиком" — схлопываем в пустой
  -- диапазон, не удаляем строку (ничего не удаляется, только состояние).
  if lower(v_open.period) > public.center_today(v_center) then
    update public.subscription_freezes
       set period = daterange(lower(v_open.period), lower(v_open.period))
     where id = v_open.id;

    perform public.emit_event('subscription.unfrozen',
      jsonb_build_object('center_id', v_center, 'subscription_id', p_id,
                         'to', lower(v_open.period), 'cancelled_before_start', true), v_center);
    return;
  end if;

  v_to := coalesce(p_to, public.center_today(v_center));
  if v_to < lower(v_open.period) then
    raise exception 'Дата окончания заморозки раньше её начала' using errcode = '22023';
  end if;
  -- "Разморозить" значит закончить сегодня или раньше — планирование
  -- конца вперёд делает freeze_subscription(p_to). Без этой проверки
  -- случайная будущая дата (опечатка в годе) превращает уже НАЧАВШУЮСЯ
  -- заморозку в ЗАКРЫТУЮ, а закрытую эта же функция найти больше не может
  -- (ищет только upper_inf выше) — абонемент запирается до следующей
  -- миграции. Не начавшуюся заморозку эта проверка не трогает — та ветка
  -- уже обработана и вышла из функции выше.
  if v_to > public.center_today(v_center) then
    raise exception 'Разморозить можно только сегодняшним или прошлым числом — для будущей даты укажите срок при заморозке'
      using errcode = '22023';
  end if;

  update public.subscription_freezes
     set period = daterange(lower(v_open.period), v_to, '[)')
   where id = v_open.id;

  perform public.emit_event('subscription.unfrozen',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id, 'to', v_to), v_center);
end;
$$;


-- 7. Guard: заморозка задним числом поверх уже списанного ---------------------------

-- Инвариант — констрейнт/триггер, не проверка в функции (CLAUDE.md):
-- freeze_subscription сама по себе ничего не проверяла про уже
-- существующие отметки в замораживаемом периоде. Специалист отмечает
-- "пришёл" 8 сентября (списывается с X) → администратор 10 сентября
-- морозит X с 1 по 15 сентября → recalc_subscription_usage всё равно
-- считает отметку внутри окна → subscription_freeze_days добавляет дни к
-- ends_at (у period-типа) — родитель получает и списание, и продление за
-- одни и те же дни. Отказываем, а не откатываем списание сами: откат чужих
-- денежных операций без явного решения администратора — хуже отсутствия
-- проверки.
--
-- Проверяются только ВНОВЬ покрываемые дни, а не весь период целиком:
-- на UPDATE (разморозка сужает период) новых дней не появляется — триггер
-- обязан пропускать это без единого обращения к lessons/attendance, иначе
-- unfreeze_subscription сам себе не даёт разморозиться, если когда-то в
-- истории уже бывшего диапазона было списание. Сравнение — через
-- предикаты на дату (d <@ new.period and not d <@ old.period), не через
-- вычитание диапазонов: разность daterange падает с "result of range
-- difference would not be contiguous" на несмежном остатке.
--
-- Граница "сегодня" — заморозка С СЕГОДНЯШНЕГО ДНЯ всегда проходит, даже
-- если сегодняшнее занятие уже отмечено и списано: это самый частый
-- сценарий (специалист закрыл утреннее занятие, в обед позвонили
-- "уезжаем"), а не заморозка задним числом. Сегодняшний день в этом
-- случае считается использованным, а не спорным — сознательный выбор
-- границы, не побочный эффект.
create or replace function public.subscription_freezes_guard_backdate()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center       uuid;
  v_today        date;
  v_old_period   daterange;
  v_blocked_date date;
begin
  if tg_op = 'UPDATE' then
    v_old_period := old.period;
    if new.period <@ v_old_period then
      return new;
    end if;
  end if;

  select center_id into v_center from public.subscriptions
   where id = new.subscription_id for update;
  v_today := public.center_today(v_center);

  select min(d.lesson_date) into v_blocked_date
    from (
      select distinct (l.starts_at at time zone public.center_timezone(v_center))::date as lesson_date
        from public.attendance a
        join public.lessons l on l.id = a.lesson_id
       where a.subscription_id = new.subscription_id
         and a.deducted
         and l.deleted_at is null and l.status <> 'cancelled'
    ) d
   where d.lesson_date <@ new.period
     and d.lesson_date < v_today
     and (v_old_period is null or not (d.lesson_date <@ v_old_period));

  if v_blocked_date is not null then
    raise exception 'На % уже есть списанное занятие — заморозка задним числом запрещена, сначала отмените отметку',
      to_char(v_blocked_date, 'DD.MM.YYYY')
      using errcode = '22023';
  end if;

  return new;
end;
$$;

drop trigger if exists subscription_freezes_guard_backdate on public.subscription_freezes;
create trigger subscription_freezes_guard_backdate
  before insert or update of period, subscription_id on public.subscription_freezes
  for each row execute function public.subscription_freezes_guard_backdate();


-- 8. subscription_summary: границы текущей заморозки --------------------------------

-- CREATE OR REPLACE не умеет менять returns table(...) существующей
-- функции (ERROR: cannot change return type) — DROP теряет ACL и comment,
-- оба возвращаем ниже вместе с новыми колонками. Новые поля — в хвост
-- сигнатуры: subscription_summary вызывается позиционно в паре мест
-- фронтенда (students/[id]), порядок первых пяти колонок — часть контракта.
-- Уже security definer с проверкой "owner/admin своего центра" (0010) —
-- та же болезнь, что у subscription_state (родитель тихо получает RLS-
-- урезанный ответ вместо отказа), здесь не применима: эта функция и так
-- не отвечает родителю/специалисту ни на что, только owner/admin — читает
-- subscription_freezes напрямую, не через subscription_current_freeze.
--
-- freeze_from/freeze_to заполняются независимо от state: если абонемент
-- одновременно исчерпан и заморожен, state='exhausted' (раздел 5), но
-- диапазон текущей заморозки в ответе всё равно есть. Карточка ученика
-- рендерит блок заморозки только при state==='frozen' — для исчерпанного
-- эти два поля останутся в ответе, но не на экране. Сознательно: если
-- абонемент решено показывать пустым, вторая история про паузу поверх
-- этого — не то, что должно отвлекать администратора в первую очередь.
drop function if exists public.subscription_summary(uuid);

create or replace function public.subscription_summary(p_subscription_id uuid)
  returns table (
    lessons_left   integer,
    state          text,
    freeze_days    integer,
    refund_tiyin   integer,
    allow_negative boolean,
    freeze_from    date,
    freeze_to      date
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.subscriptions s
     where s.id = p_subscription_id and s.center_id = v_center
  ) then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  return query
    select public.subscription_lessons_left(s.id),
           public.subscription_state(s.id),
           public.subscription_freeze_days(s.id),
           public.refund_calc(s.id),
           s.allow_negative,
           lower(f.period),
           -- Верхняя граница диапазона исключающая: последний замороженный
           -- день на сутки раньше upper(). NULL — заморозка открытая,
           -- "пока не разморозят" (тот же расчёт раньше жил в клиентском
           -- regex-разборе daterange, apps/web/students/[id]/page.tsx —
           -- убран туда, где посчитан один раз, а не в каждом потребителе).
           case when upper_inf(f.period) then null else upper(f.period) - 1 end
      from public.subscriptions s
      left join lateral (
        select * from public.subscription_freezes sf
         where sf.subscription_id = s.id and sf.period @> public.center_today(s.center_id)
         order by lower(sf.period) desc limit 1
      ) f on true
     where s.id = p_subscription_id;
end;
$$;

comment on function public.subscription_summary(uuid) is
  'Числа абонемента для admin/owner: остаток, состояние, дни заморозки, сумма возврата, границы текущей заморозки.';

revoke all on function public.subscription_summary(uuid) from public, anon;
grant execute on function public.subscription_summary(uuid) to authenticated;


-- 9. student_subscription_badge: различает "нет" и "заморожен" ----------------------

-- Состояние каждого кандидата считается ОДИН РАЗ во внутреннем подзапросе
-- (колонка c.state), а не заново в WHERE/ORDER BY/после выбора — subscription_
-- state теперь definer (раздел 5), три отдельных вызова означали бы три
-- прохода через проверку видимости и чтение subscription_freezes вместо
-- одного. Фильтр расширен с status='active' на status<>'cancelled' и
-- state in ('active','frozen') — раньше замороженный исключался этим же
-- условием, и бейдж врал "нет" вместо "заморожен". Сортировка
-- "незамороженные первыми": если у ребёнка есть и замороженный, и обычный
-- активный абонемент, бейдж обязан показать активный — иначе разойдётся с
-- тем, что реально спишет attendance_fill_and_check.
create or replace function public.student_subscription_badge(p_student_id uuid)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_role  text := public.my_role();
  v_sub   uuid;
  v_state text;
  v_left  integer;
begin
  if v_role is null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.students st
     where st.id = p_student_id and st.center_id = public.current_center()
  ) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if v_role = 'teacher' and not public.teacher_teaches_student(p_student_id) then
    raise exception 'Этот ребёнок не на ваших занятиях' using errcode = '42501';
  end if;
  if v_role = 'parent' and not public.parent_of_student(p_student_id) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- subscription_state_unchecked, не subscription_state: роль/принадлежность
  -- ребёнка этому специалисту/родителю уже проверены выше (teacher_teaches_
  -- student/parent_of_student), второй гейт внутри subscription_state дал
  -- бы тот же ответ ценой лишнего прохода через subscription_visible_to_
  -- caller — а её собственный гейт всё равно не пускает teacher (раздел 4),
  -- так что публичная версия здесь попросту вернула бы NULL специалисту.
  select c.id, c.state into v_sub, v_state
    from (
      select s.id, s.ends_at, s.created_at, s.allow_negative,
             public.subscription_state_unchecked(s.id) as state
        from public.subscriptions s
       where s.student_id = p_student_id
         and s.center_id = public.current_center()
         and s.deleted_at is null
         and s.status <> 'cancelled'
    ) c
   where c.allow_negative or c.state in ('active', 'frozen')
   order by (c.state = 'frozen') asc, c.ends_at asc nulls last, c.created_at, c.id
   limit 1;

  if v_sub is null then return 'нет'; end if;
  if v_state = 'frozen' then return 'заморожен'; end if;

  v_left := public.subscription_lessons_left(v_sub);
  if v_left is null then return 'есть'; end if;
  -- Ноль и минус — «нет»: оплаченных занятий не осталось, даже если
  -- списание продолжается в долг. Специалисту важно именно это.
  if v_left <= 0 then return 'нет'; end if;
  if v_left <= 2 then return 'заканчивается'; end if;
  return 'есть';
end;
$$;


-- 10. student_balance: состояние в витрине, не только число --------------------------

-- Кандидат считается той же функцией, что раньше жила инлайн в lateral
-- (0010:1213-1221) — вынесена в security INVOKER function, а не definer:
-- все колонки, которые она возвращает, приходят из subscriptions, чья RLS
-- (0008:249-257 — owner/admin своего центра, parent своих детей, teacher
-- вообще ничего) уже сужает ровно так, как нужно витрине. Внутри
-- определяет предикатов не завести — как только сюда попадёт колонка НЕ
-- из subscriptions (например когда-нибудь имя ребёнка или сумма платежей),
-- эта гарантия молча перестанет действовать: RLS чужой таблицы её не
-- продолжит. state — исключение: он приходит не из subscriptions
-- напрямую, а через subscription_state (definer, раздел 5), и его
-- корректность держится на subscription_visible_to_caller, а не на RLS
-- этой функции.
--
-- Фильтр state in ('active','exhausted','frozen') — как и раньше
-- (0010:1218, только 'active','exhausted') плюс frozen, иначе замороженный
-- абонемент не мог бы стать active_subscription_id вовсе. Исключённый
-- 'expired' — старый, истёкший абонемент не должен обгонять действующий
-- в сортировке по ends_at (истёкший почти всегда имеет более раннюю дату
-- и без этого фильтра оказался бы первым).
create or replace function public.student_balance_pick(p_student_id uuid)
  returns table (subscription_id uuid, ends_at date, lesson_price_tiyin integer, state text)
  language sql
  stable
  security invoker
  set search_path = ''
as $$
  select c.id, c.ends_at, c.lesson_price_tiyin, c.state
    from (
      select s2.id, s2.ends_at, s2.created_at, s2.lesson_price_tiyin,
             public.subscription_state(s2.id) as state
        from public.subscriptions s2
       where s2.student_id = p_student_id
         and s2.deleted_at is null
         and s2.status <> 'cancelled'
    ) c
   where c.state in ('active', 'exhausted', 'frozen')
   order by (c.state = 'frozen') asc, c.ends_at asc nulls last, c.created_at, c.id
   limit 1;
$$;

-- Фильтр роли в самом конце — тот, что был в 0010:1222-1228 (комментарий
-- там же: "debt_tiyin считается по attendance, а её специалист видит по
-- своим занятиям — без этого условия сумма долга утекала бы к нему").
-- Он был на ВЬЮХЕ, а не в подобранной функции: student_balance_pick
-- отвечает только про subscriptions (специалисту и так недоступные через
-- их RLS), а долг в debt_tiyin считается отдельным подзапросом по
-- attendance, у которой teacher-политика ЕСТЬ (свои занятия) — вынос
-- выбора кандидата в функцию не отменяет эту утечку, фильтр должен
-- остаться именно здесь.
create or replace view public.student_balance
  with (security_invoker = true)
as
  select
    s.id                                        as student_id,
    s.center_id,
    b.subscription_id                           as active_subscription_id,
    public.subscription_lessons_left(b.subscription_id) as lessons_left,
    b.ends_at,
    coalesce((
      select sum(a.price_tiyin) from public.attendance a
       where a.student_id = s.id and a.subscription_id is null and a.deducted
    ), 0)::integer                              as debt_tiyin,
    (greatest(-coalesce(public.subscription_lessons_left(b.subscription_id), 0), 0)
      * coalesce(b.lesson_price_tiyin, 0))::integer as overdrawn_tiyin,
    b.state
  from public.students s
  left join lateral public.student_balance_pick(s.id) b on true
 where s.deleted_at is null
   and (
     public.my_role() in ('owner', 'admin')
     or (public.my_role() = 'parent' and public.parent_of_student(s.id))
   );


-- 11. attendance_fill_and_check: одно исключение вместо тихого долга -----------------

-- Кандидат и признак "заморожен на дату занятия" — из ОДНОГО запроса
-- (порядок, не отдельный exists в WHERE): раньше кандидат выбирался с
-- `and not exists (freeze...)` в фильтре, а перепроверка под блокировкой
-- дублировала тот же exists — пустой результат первого запроса значил
-- "абонемента нет вовсе", а "все подходящие заморожены" от него отличить
-- было нечем без второго независимого снимка данных (гонка: между двумя
-- snapshot'ами администратор мог разморозить). Один запрос, сортировка
-- "незамороженные первыми" — оба вывода из одного снимка.
create or replace function public.attendance_fill_and_check()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_lesson                public.lessons;
  v_status                public.attendance_statuses;
  v_sub                    public.subscriptions;
  v_cand                   uuid;
  v_cand_frozen_at_select  boolean;
  v_cand_frozen_now        boolean;
  v_lesson_date            date;
  v_price                  integer;
  v_keys_changed           boolean := false;
  v_status_changed         boolean := false;
  v_student_name           text;
  v_freeze_period          daterange;
begin
  if tg_op = 'UPDATE' then
    v_keys_changed   := new.lesson_id is distinct from old.lesson_id
                     or new.student_id is distinct from old.student_id;
    v_status_changed := new.status_id is distinct from old.status_id;
  end if;

  select * into v_lesson from public.lessons where id = new.lesson_id;
  if not found or v_lesson.deleted_at is not null then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;
  v_lesson_date := (v_lesson.starts_at at time zone public.center_timezone(new.center_id))::date;

  -- Состояние занятия проверяется при создании отметки и при смене ключей.
  -- Смена статуса у старой отметки его не трогает: занятие могли отменить
  -- позже, и правка истории не должна об это спотыкаться — пересчёт остатка
  -- отменённые занятия и так не считает.
  if tg_op = 'INSERT' or v_keys_changed then
    if v_lesson.status = 'cancelled' then
      raise exception 'Занятие отменено — отметить посещение нельзя' using errcode = '22023';
    end if;
    if v_lesson.starts_at > now() then
      raise exception 'Занятие ещё не началось' using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.lesson_participants p
       where p.lesson_id = new.lesson_id and p.student_id = new.student_id
    ) then
      raise exception 'Этот ребёнок не участник занятия' using errcode = '22023';
    end if;
  end if;

  if tg_op = 'UPDATE' then
    -- Замороженные факты: всё, что пришло от клиента, перетирается старым.
    -- Заморозка НЕ проверяется здесь ни при смене статуса, ни при смене
    -- комментария — только ниже, при подборе НОВОГО абонемента. Продуктовое
    -- решение 11.09.2026: круг "пришёл → болел → пришёл" остаётся на том
    -- же абонементе, даже если его заморозили между первым и последним
    -- шагом — тест 25 в 0010_stage4_hardening.test.sql фиксирует это как
    -- ожидаемое поведение, не как пропуск проверки.
    new.marked_by       := old.marked_by;
    new.subscription_id := old.subscription_id;
    new.price_tiyin     := old.price_tiyin;
    new.deducted        := old.deducted;
    new.counts_absence  := old.counts_absence;
    if not v_status_changed and not v_keys_changed then
      new.marked_at := old.marked_at;
      return new;
    end if;
  else
    new.marked_by       := coalesce(auth.uid(), new.marked_by);
    new.subscription_id := null;
    new.price_tiyin     := 0;
  end if;
  new.marked_at := now();

  select * into v_status from public.attendance_statuses
   where id = new.status_id and center_id = new.center_id and deleted_at is null;
  if not found then
    raise exception 'Статус посещения не найден' using errcode = '42704';
  end if;
  new.deducted       := v_status.deducts_lesson;
  new.counts_absence := v_status.counts_absence;

  -- Заморозка проверяется ТОЛЬКО здесь, при подборе НОВОГО абонемента —
  -- то есть только для списывающих статусов (new.deducted), и только
  -- когда у отметки ещё нет привязки. Непосещающие статусы вообще не
  -- заходят в этот блок и привязки не получают — продуктовое решение
  -- 11.09.2026 "исключение только для списывающих статусов" тем самым уже
  -- выполнено структурой кода, без дополнительной проверки статуса.
  if new.deducted and new.subscription_id is null then
    select c.id, c.is_frozen into v_cand, v_cand_frozen_at_select
      from (
        select s.id,
               exists (
                 select 1 from public.subscription_freezes f
                  where f.subscription_id = s.id and f.period @> v_lesson_date
               ) as is_frozen,
               s.ends_at, s.created_at
          from public.subscriptions s
         where s.student_id = new.student_id
           and s.center_id  = new.center_id
           and s.deleted_at is null
           and s.status <> 'cancelled'
           and s.starts_at <= v_lesson_date
           and (s.ends_at is null or s.ends_at >= v_lesson_date)
           and (s.allow_negative
                or s.lessons_total is null
                or s.lessons_total - s.lessons_used - s.lessons_written_off > 0)
           and (s.type_id is null
                or exists (select 1 from public.subscription_types t
                            where t.id = s.type_id
                              and (t.service_id is null or t.service_id = v_lesson.service_id)))
      ) c
     order by c.is_frozen asc, c.ends_at asc nulls last, c.created_at, c.id
     limit 1;

    if v_cand is not null then
      -- Блокировка отдельно от выбора: `for update ... limit 1` в read
      -- committed после ожидания перепроверяет where на новой версии
      -- строки и при несовпадении возвращает ноль строк — отметка молча
      -- ушла бы в долг вместо "повторите". Поэтому: выбрать, заблокировать,
      -- перепроверить.
      select * into v_sub from public.subscriptions s where s.id = v_cand for update;
      if not found then
        raise exception 'Абонемент изменился во время отметки — повторите'
          using errcode = '40001';
      end if;

      if v_sub.deleted_at is not null
         or v_sub.status = 'cancelled'
         or not (v_sub.allow_negative
                 or v_sub.lessons_total is null
                 or v_sub.lessons_total - v_sub.lessons_used - v_sub.lessons_written_off > 0)
      then
        raise exception 'Абонемент изменился во время отметки — повторите'
          using errcode = '40001';
      end if;

      v_cand_frozen_now := exists (
        select 1 from public.subscription_freezes f
         where f.subscription_id = v_sub.id and f.period @> v_lesson_date);

      if v_cand_frozen_now then
        if v_cand_frozen_at_select then
          -- Окончательный отказ — только если альтернативы нет ИМЕННО
          -- СЕЙЧАС: пока мы ждали блокировку именно этого абонемента, кто-
          -- то мог разморозить ДРУГОЙ абонемент того же ребёнка. Тогда
          -- правильный ответ "повторите", а не окончательный отказ на
          -- абонементе, который мы даже не проверяли на актуальном снимке.
          if exists (
            select 1 from public.subscriptions s2
             where s2.student_id = new.student_id and s2.center_id = new.center_id
               and s2.id <> v_sub.id
               and s2.deleted_at is null and s2.status <> 'cancelled'
               and s2.starts_at <= v_lesson_date
               and (s2.ends_at is null or s2.ends_at >= v_lesson_date)
               and (s2.allow_negative or s2.lessons_total is null
                    or s2.lessons_total - s2.lessons_used - s2.lessons_written_off > 0)
               and not exists (select 1 from public.subscription_freezes f2
                                where f2.subscription_id = s2.id and f2.period @> v_lesson_date)
               and (s2.type_id is null or exists (select 1 from public.subscription_types t2
                      where t2.id = s2.type_id
                        and (t2.service_id is null or t2.service_id = v_lesson.service_id)))
          ) then
            raise exception 'Абонемент изменился во время отметки — повторите'
              using errcode = '40001';
          end if;

          select full_name into v_student_name from public.students where id = new.student_id;
          select f.period into v_freeze_period from public.subscription_freezes f
           where f.subscription_id = v_sub.id and f.period @> v_lesson_date
           order by lower(f.period) desc limit 1;

          if upper_inf(v_freeze_period) then
            raise exception '%: абонемент заморожен с % — отметить посещение нельзя, пока не разморозят',
              v_student_name, to_char(lower(v_freeze_period), 'DD.MM.YYYY')
              using errcode = '22023';
          else
            raise exception '%: абонемент заморожен по % — отметить посещение можно после этой даты',
              v_student_name, to_char(upper(v_freeze_period) - 1, 'DD.MM.YYYY')
              using errcode = '22023';
          end if;
        else
          -- Не был заморожен на снимке выбора, стал под блокировкой —
          -- TOCTOU, а не бизнес-факт: мог существовать другой, не
          -- замороженный кандидат, которого мы не выбрали именно потому,
          -- что этот на тот момент выглядел лучше.
          raise exception 'Абонемент изменился во время отметки — повторите'
            using errcode = '40001';
        end if;
      end if;

      new.subscription_id := v_sub.id;
      new.price_tiyin     := coalesce(v_sub.lesson_price_tiyin, 0);
    else
      -- Списывать не с чего: долг по цене услуги на момент занятия. Тот же
      -- путь и для "абонемента нет вовсе", и для "единственный подходящий
      -- исчерпан без allow_negative" — заморозка тут ни при чём, потому
      -- что до неё дело не дошло: кандидатов не нашлось совсем.
      select sv.default_price_tiyin into v_price from public.services sv
       where sv.id = v_lesson.service_id;
      new.price_tiyin := coalesce(v_price, 0);
    end if;
  elsif tg_op = 'INSERT' then
    select sv.default_price_tiyin into v_price from public.services sv
     where sv.id = v_lesson.service_id;
    new.price_tiyin := coalesce(v_price, 0);
  end if;

  return new;
end;
$$;


-- Права -------------------------------------------------------------------------

-- Триггерные функции закрыты совсем — вызываются только Postgres'ом.
-- revoke ... from public, anon, authenticated (не только public/anon, как
-- у прикладных RPC ниже): Postgres выдаёт EXECUTE роли PUBLIC, а Supabase
-- дополнительно — ролям anon и authenticated. Без явного отзыва у
-- authenticated любая функция в public становится вызываемым
-- /rest/v1/rpc/-эндпоинтом для залогиненного пользователя, даже если сама
-- функция откажет содержательно ("trigger functions can only be called as
-- triggers") — факт существования эндпоинта у постороннего это ровно то,
-- от чего защищают 0003 и 0007.
revoke execute on function
  public.subscription_types_guard_sold_fields(),
  public.subscription_freezes_guard_backdate()
  from public, anon, authenticated;

-- Postgres/Supabase не различают owner/admin/teacher/parent на уровне
-- GRANT — это одна и та же роль authenticated, разница только в my_role()
-- внутри тела функции. Поэтому отзывать EXECUTE у authenticated целиком,
-- чтобы закрыть доступ ИМЕННО специалисту, — не работает: это заодно
-- отзывает его и у владельца, и у родителя, которым эти же данные нужны
-- напрямую (родителю — дни заморозки, раздел 5; владельцу — оба
-- калькулятора в проверках ниже и в подсчётах вроде теста на сумму дней).
-- Разница по ролям уже сделана ВНУТРИ тела: subscription_current_freeze и
-- subscription_freeze_days сами вызывают subscription_visible_to_caller
-- (без ветки teacher, раздел 4) и возвращают NULL, если вызывающему не
-- положено, — специалист, вызвав их напрямую, получит NULL, а не точные
-- даты/дни, и грант на EXECUTE тут ни при чём. Значит грант остаётся, как
-- у subscription_state и subscription_summary.
revoke all on function
  public.subscription_current_freeze(uuid, date),
  public.subscription_freeze_days(uuid)
  from public, anon;
grant execute on function
  public.subscription_current_freeze(uuid, date),
  public.subscription_freeze_days(uuid)
  to authenticated;

-- Эти две — другое дело: у subscription_visible_to_caller нет причины
-- быть вызываемой отдельно от функций выше (она не отвечает на вопрос про
-- заморозку сама по себе, только "видно ли"), а subscription_state_
-- unchecked вообще не имеет собственной проверки — рассчитана только на
-- вызов из уже проверившего доступ кода (badge). Дать ей грант — значит
-- дать любому authenticated точную категорию состояния (exhausted/expired/
-- cancelled) без какого-либо гейта: ровно то, что нашла находка 3 (round5)
-- и что закрывает публичная subscription_state.
revoke execute on function
  public.subscription_visible_to_caller(uuid),
  public.subscription_state_unchecked(uuid)
  from public, anon, authenticated;

-- Вызывается из student_balance (security_invoker = true) под правами
-- реального пользователя — без гранта запрос к вьюхе падал бы на
-- внутреннем вызове этой функции для всех, кроме владельца объектов.
revoke all on function public.student_balance_pick(uuid) from public, anon;
grant execute on function public.student_balance_pick(uuid) to authenticated;
