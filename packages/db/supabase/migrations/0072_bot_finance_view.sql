-- =============================================================================
-- 0072_bot_finance_view.sql — команды бота /debts и /cash (только просмотр)
--
-- Решение владельца 27.09.2026: финансы в Telegram — просмотр и (позже, 0073)
-- утренняя сводка; ввод и изменение денег из бота НЕ делается: в контуре
-- bot_worker нет auth.uid(), и «кто провёл платёж» нигде не фиксируется
-- (created_by и audit_log пусты) — для денег недопустимо, тот же довод, что
-- отказ бота переписывать отметку посещения (0071 Р6).
--
-- Ревью architect (план) нашёл двенадцать мест; ниже решения. Отдельная
-- находка проверки до кода — на Supabase нельзя повесить `SET
-- "request.jwt.claims"` в объявление функции (permission denied to set
-- parameter, roле postgres не суперпользователь): совет «встроенный
-- finally через SET-клаузу» недоступен, откат подмены сделан вручную (Р2).
--
--   Р1. Вся логика долгов сессионная: student_debts(), students_brief(),
--       student_subscriptions_overdue() (0031/0070) и student_balance_pick
--       (0015) начинаются с `auth.uid() is null → пусто` и берут центр и
--       роль из claims. Из контура bot_worker они вернули бы ноль строк, и
--       бот написал бы «долгов нет» центру с долгами. Варианты: (B)
--       переиздать шесть денежных функций поверх параметра центра — большой
--       риск ради команды «только чтение»; (C) вторая копия правил долга —
--       CLAUDE.md против, живой пример расхождения — bot_balance (0033), не
--       пережившая 0070. Выбран (A): внутренний помощник bot_debts_center
--       ПОСЛЕ проверки роли по memberships локально подменяет
--       request.jwt.claims на {sub, role: authenticated,
--       app_metadata.center_id} и читает student_balance теми же функциями,
--       что экран. Одно правило, экран и бот не разойдутся; сессионные
--       функции внутри ещё раз проверяют роль (can_payments) — второй
--       рубеж.
--   Р2. Подмена не должна пережить вызов. Заборы: (а) помощник без грантов
--       ни у кого, включая bot_worker и service_role — иначе «стать любым
--       пользователем» по ключу бота (включая is_platform_admin());
--       p_user берётся только из telegram_user(chat), p_center — только из
--       memberships этого пользователя, прошедших белый список; (б) только
--       set_config(..., true) — transaction-local (false пережил бы
--       транзакцию на соединении пула PostgREST); pgTAP держит источник;
--       (в) прежнее значение запоминается и возвращается в конце, ПОСЛЕ
--       подмены нет ни одного раннего return (единственный выход внизу);
--       при исключении откат подтранзакции вызывающего возвращает claims
--       сам, а у самого верхнего вызова транзакция PostgREST кончается
--       (проверено на dev-базе: после успеха, после перехваченного
--       исключения и в READ ONLY транзакции auth.uid() снова null); (г)
--       claims ровно из трёх полей, без email; (д) внешние bot_debts/
--       bot_cash не трогают claims сами — их первая строка
--       `auth.uid() is not null → 42501` сохраняет смысл.
--   Р3. Самопроверка после подмены: auth.uid() = p_user, current_center() =
--       p_center, can_payments(). Иначе подмена «не сработала» (например,
--       старая переменная request.jwt.claim.sub перекрыла бы claims) и
--       сессионные функции молча вернули бы пусто — «Долгов нет». Здесь —
--       громкая ошибка 42501, а «проблем нет» — явная строка с нулями.
--   Р4. Внешние функции STABLE: PostgREST исполняет stable-RPC в транзакции
--       только для чтения, и любая случайная запись внутри окна подмены
--       (будущая правка сессионной функции, триггер) упадёт с 25006, а не
--       пройдёт от чужого имени. STABLE-обёртка над volatile-помощником с
--       set_config допустима (проверено, в т.ч. в READ ONLY транзакции).
--   Р5. «Проблемный» ребёнок — как на экране debts/page.tsx: долг за занятия,
--       перерасход, просрочка по абонементу или исчерпанный остаток. Один
--       SQL-источник — student_debt_problems() (порядок и корзины тоже);
--       страница остаётся зеркалом (CLAUDE.md, «SQL источник истины, TS —
--       зеркало»): переход страницы на функцию — отдельный долг. Дашборд и
--       ассистент считают «должника» по-своему (только debt_tiyin) — старое
--       расхождение, тоже долг, не решается здесь.
--   Р6. Два итога, как на странице: «долг за занятия» (debt + перерасход —
--       одни деньги) и «просрочка по абонементам» (другие) — Database.md
--       запрещает их складывать. «Остаток исчерпан» — не долг и в число
--       должников не входит. Порядок топ-10 — по ключу экрана: максимум из
--       двух корзин (не сумма — долг 500 сом не выше просрочки 50 000).
--   Р7. Роли — как на экране/в данных: /debts — can_payments() (owner,
--       admin, registrar, finance); /cash — can_finance() (owner, admin,
--       finance), как cash_by_source и строка матрицы «Витрины выручки и
--       кассы». parent/teacher — 42501 с текстом, не пусто: пустой ответ
--       читался бы как «долгов нет» (тот же класс, что 0033 Р5). Смешанные
--       членства — центры с неподходящей ролью молча пропускаются.
--       Редирект страницы /app/debts всех кроме owner/admin — расхождение
--       с матрицей, не этой миграции.
--   Р8. Слово «касса» в тексте бота не используется: docs/Database.md
--       («Два слова, два определения») — касса = payments И expenses
--       (cash_by_source), а здесь только payments. Величина называется
--       «Поступления»: сумма payments за день центра по paid_at, знак — часть
--       суммы (payment/refund/correction), расходы не входят.
--   Р9. center_payments_day(center, day) — одна внутренняя функция без
--       сессии и грантов (её же возьмёт сводка 0073). Граница дня —
--       полуинтервал [day 00:00, day+1 00:00) в поясе центра (center_
--       timezone — откат на Бишкек для некорректного пояса, 0052), не
--       приведение типов по колонке. left join к payment_sources БЕЗ
--       фильтра архива: source_id допускает NULL, источники архивируются —
--       иначе платёж пропал бы из разбивки и она разошлась бы с итогом;
--       платёж без источника — строка «Без источника». Группировка по id
--       источника, не по имени.
--   Р10. Готовые тексты приходят из SQL (деньги — format_som): в TS нет
--       второй копии форматирования (commands.ts som() — копия format_som).
--       Сообщение — на центр; ФИО обрезаны до 60 знаков, ответ заведомо
--       короче лимита Telegram 4096; телефоны плательщиков не отдаются.
--   Р11. Read-only центр — чтение разрешено (guard 0050 блокирует запись,
--       экран в read-only читает), bot_assert_writable не вызывается.
--       Центр с deleted_at исключается, как в bot_today (0071); если это
--       единственный центр пользователя — 42501, не «нет данных».
--
--   Р12. Только личный чат: у групп и супергрупп chat_id отрицательный, а
--       личность в боте определяется чатом, не автором сообщения — сотрудник,
--       привязавшийся в рабочей группе, открыл бы список должников центра
--       всем её участникам. bot_debts/bot_cash отвергают p_chat_id <= 0 (бот
--       дублирует проверку по chat.type). Для /today и /balance дыра старая
--       (0033), эта миграция не расширяет её с «моё» до «весь центр».
--   Р13. Внутренние помощники (center_payments_day, bot_debts_center) —
--       SECURITY INVOKER: гранта нет ни у кого, но случайный будущий
--       `grant execute` не превратится в чтение чужих поступлений или
--       подмену личности — без гранта на таблицы вызов упадёт. Работают
--       как обычно: их зовут definer-функции от имени владельца. ВАЖНО для
--       0073: bot_debts_center подменяет claims, поэтому вызывать её можно
--       только из STABLE-обёртки (read-only транзакция ловит случайную
--       запись в окне подмены) или явно под set transaction read only —
--       из cron/воркера в пишущей транзакции запись прошла бы от чужого имени.
--   Р14. «Остаток исчерпан» — как на экране (debts/page.tsx): только когда
--       денежных проблем нет вовсе. Ребёнок с просрочкой и исчерпанным
--       абонементом считается один раз — по просрочке.
--   Р15. Суммы складываются в bigint до сложения (два integer-слагаемых не
--       должны ронять /debts переполнением); имена источников обрезаны до 60
--       знаков, в /cash показаны восемь крупнейших источников и строка
--       «Прочие» — ответ заведомо короче лимита Telegram.
--
-- Что НЕ входит: сводка (0073, отдельный PR — переиздание event_messages на
-- 500 строк), ввод платежей, перевод страницы /app/debts на
-- student_debt_problems(), выравнивание bot_balance (0033) с 0070.
-- Таблиц нет — deny-list экспорта не затрагивается.
-- =============================================================================


-- 1. Поступления за день центра (Р8, Р9) ---------------------------------------

create or replace function public.center_payments_day(p_center uuid, p_day date)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  with tz as (
    select public.center_timezone(p_center) as name
  ),
  bounds as (
    select (p_day::timestamp at time zone tz.name)         as t0,
           ((p_day + 1)::timestamp at time zone tz.name)   as t1
      from tz
  ),
  by_src as (
    select ps.id as source_id,
           left(coalesce(ps.name, 'Без источника'), 60) as name,
           sum(p.amount_tiyin)::bigint        as total_tiyin,
           count(*)::integer                  as ops
      from public.payments p
      cross join bounds b
      left join public.payment_sources ps on ps.id = p.source_id and ps.center_id = p.center_id
     where p.center_id = p_center
       and p.paid_at >= b.t0 and p.paid_at < b.t1
     group by ps.id, left(coalesce(ps.name, 'Без источника'), 60)
  )
  select jsonb_build_object(
    'total_tiyin', coalesce((select sum(total_tiyin) from by_src), 0),
    'ops',         coalesce((select sum(ops) from by_src), 0),
    'by_source',   coalesce((select jsonb_agg(jsonb_build_object(
                                     'name', name, 'total_tiyin', total_tiyin, 'ops', ops)
                                   order by abs(total_tiyin) desc, name)
                               from by_src), '[]'::jsonb)
  );
$$;

comment on function public.center_payments_day(uuid, date) is
  'Поступления центра за день: сумма payments по paid_at в поясе центра, полуинтервал [день, день+1), знак — часть суммы, расходы не входят (0072 Р8/Р9). Внутренняя (SECURITY INVOKER, Р13): без сессии и без грантов, зовут bot_cash и (0073) daily_digest; центр — только из вызывающей definer-функции, никогда от пользователя.';

revoke all on function public.center_payments_day(uuid, date)
  from public, anon, authenticated, service_role, bot_worker;


-- 2. «Проблемные» дети — один SQL-источник (Р5, Р6) -----------------------------

create or replace function public.student_debt_problems()
  returns table (
    student_id     uuid,
    full_name      text,
    debt_tiyin     integer,
    overdrawn_tiyin integer,
    overdue_tiyin  integer,
    zero_left      boolean,
    sort_tiyin     bigint
  )
  language sql
  stable
  set search_path = ''
as $$
  select b.student_id,
         left(s.full_name, 60),
         coalesce(b.debt_tiyin, 0),
         coalesce(b.overdrawn_tiyin, 0),
         coalesce(b.subscription_overdue_tiyin, 0),
         -- lessons_left = null значит и «безлимит», и «нет абонемента»
         -- (0010): исчерпан только при живом абонементе и остатке ровно 0.
         -- Как на экране (Р14): метка только когда денежных проблем нет вовсе.
         (b.active_subscription_id is not null and b.lessons_left = 0
          and coalesce(b.debt_tiyin, 0) = 0
          and coalesce(b.overdrawn_tiyin, 0) = 0
          and coalesce(b.subscription_overdue_tiyin, 0) = 0),
         -- Ключ экрана: максимум из двух корзин, не сумма (Р6); bigint до
         -- сложения (Р15).
         greatest(coalesce(b.debt_tiyin, 0)::bigint + coalesce(b.overdrawn_tiyin, 0)::bigint,
                  coalesce(b.subscription_overdue_tiyin, 0)::bigint)
    from public.student_balance b
    join public.students_brief() s on s.id = b.student_id
   where coalesce(b.debt_tiyin, 0) > 0
      or coalesce(b.overdrawn_tiyin, 0) > 0
      or coalesce(b.subscription_overdue_tiyin, 0) > 0
      or (b.active_subscription_id is not null and b.lessons_left = 0);
$$;

comment on function public.student_debt_problems() is
  'Дети с долгом за занятия, перерасходом, просрочкой по абонементу или исчерпанным остатком — то же правило, что debts/page.tsx (0072 Р5): SQL источник истины, страница — зеркало. Сессионная (student_balance и students_brief проверяют права вызывающего); наружу не выдаётся — читают её definer-функции бота под подменённой сессией.';

revoke all on function public.student_debt_problems()
  from public, anon, authenticated, service_role, bot_worker;


-- 3. Помощник чтения долгов одного центра под подменённой сессией (Р1–Р3) --------

create or replace function public.bot_debts_center(p_user uuid, p_center uuid)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_prev text;
  v_ok   boolean;
  v_out  jsonb;
begin
  -- Проверка роли ДО подмены, по memberships (единственный ранний return —
  -- до set_config): вне белого списка помощник не подменяет ничего.
  if not exists (
    select 1 from public.memberships m
     where m.user_id = p_user and m.center_id = p_center
       and m.role in ('owner', 'admin', 'registrar', 'finance')
  ) then
    return null;
  end if;

  v_prev := coalesce(current_setting('request.jwt.claims', true), '');

  -- Р2: только transaction-local, ровно три поля, без email.
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);

  -- Р3: подмена сработала? Иначе сессионные функции молча вернут пусто.
  -- coalesce обязателен: `null and …` — NULL, `not NULL` — NULL, и провал
  -- подмены прошёл бы мимо raise (тот же класс, что 0065).
  v_ok := coalesce(auth.uid() = p_user
                   and public.current_center() = p_center
                   and public.can_payments(), false);

  if v_ok then
    select jsonb_build_object(
             'usage_n',       count(*) filter (where p.debt_tiyin::bigint + p.overdrawn_tiyin::bigint > 0),
             'usage_tiyin',   coalesce(sum(p.debt_tiyin::bigint + p.overdrawn_tiyin::bigint), 0),
             'overdue_n',     count(*) filter (where p.overdue_tiyin > 0),
             'overdue_tiyin', coalesce(sum(p.overdue_tiyin), 0),
             'zero_n',        count(*) filter (where p.zero_left),
             'top', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'name', t.full_name,
                        'usage_tiyin', t.debt_tiyin::bigint + t.overdrawn_tiyin::bigint,
                        'overdue_tiyin', t.overdue_tiyin,
                        'zero_left', t.zero_left)
                      order by t.sort_tiyin desc, t.full_name)
                 from (select * from public.student_debt_problems()
                        order by sort_tiyin desc, full_name
                        limit 10) t
             ), '[]'::jsonb))
      into v_out
      from public.student_debt_problems() p;
  end if;

  -- Единственный выход: claims возвращаются в любом случае (Р2в).
  perform set_config('request.jwt.claims', v_prev, true);

  if not v_ok then
    raise exception 'Не удалось определить права в центре — обратитесь к администратору'
      using errcode = '42501';
  end if;

  return v_out;
end;
$$;

comment on function public.bot_debts_center(uuid, uuid) is
  'Долги одного центра для пользователя чата под ЛОКАЛЬНО подменённой сессией (0072 Р1–Р3). SECURITY INVOKER (Р13) и без грантов ни у кого, включая bot_worker: помощник «стать пользователем» не должен быть доступен по ключу бота. p_user — только из telegram_user(chat), p_center — только из его memberships. claims возвращаются в конце; ранних return после подмены нет.';

revoke all on function public.bot_debts_center(uuid, uuid)
  from public, anon, authenticated, service_role, bot_worker;


-- 4. /debts (Р7, Р10, Р11) ----------------------------------------------------------

create or replace function public.bot_debts(p_chat_id bigint)
  returns table (center_name text, message text)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_user  uuid;
  v_c     record;
  v_d     jsonb;
  v_lines text;
  v_head  text;
  v_found boolean := false;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р12: группы и супергруппы — отрицательный chat_id.
  if p_chat_id <= 0 then
    raise exception 'Команда доступна только в личной переписке с ботом' using errcode = '42501';
  end if;

  v_user := public.telegram_user(p_chat_id);
  if v_user is null then
    raise exception 'Чат не привязан' using errcode = '42501';
  end if;

  -- Р11: центр на удалении исключается, read-only — читается.
  for v_c in
    select c.id, c.name
      from public.memberships m
      join public.centers c on c.id = m.center_id and c.deleted_at is null
     where m.user_id = v_user
       and m.role in ('owner', 'admin', 'registrar', 'finance')
     order by c.name, c.id
  loop
    v_d := public.bot_debts_center(v_user, v_c.id);
    continue when v_d is null;
    v_found := true;

    select string_agg(
             e.n::text || '. ' || (e.t ->> 'name') || ' — '
               || concat_ws('; ',
                    case when (e.t ->> 'usage_tiyin')::bigint > 0
                         then 'долг ' || public.format_som((e.t ->> 'usage_tiyin')::bigint) end,
                    case when (e.t ->> 'overdue_tiyin')::bigint > 0
                         then 'просрочка ' || public.format_som((e.t ->> 'overdue_tiyin')::bigint) end,
                    case when (e.t ->> 'zero_left')::boolean then 'остаток исчерпан' end),
             E'\n' order by e.n)
      into v_lines
      from jsonb_array_elements(v_d -> 'top') with ordinality as e(t, n);

    if (v_d ->> 'usage_n')::int = 0 and (v_d ->> 'overdue_n')::int = 0 and (v_d ->> 'zero_n')::int = 0 then
      -- Р3: «нет проблем» — явный ответ с нулями, а не пустая строка.
      v_head := 'Долгов, просрочек и исчерпанных остатков нет.';
      v_lines := null;
    else
      -- Р6: два итога, не складываются.
      v_head := concat_ws(E'\n',
        case when (v_d ->> 'usage_n')::int > 0
             then 'Долг за занятия: ' || public.format_som((v_d ->> 'usage_tiyin')::bigint)
                  || ' (детей: ' || (v_d ->> 'usage_n') || ')' end,
        case when (v_d ->> 'overdue_n')::int > 0
             then 'Просрочка по абонементам: ' || public.format_som((v_d ->> 'overdue_tiyin')::bigint)
                  || ' (детей: ' || (v_d ->> 'overdue_n') || ')' end,
        case when (v_d ->> 'zero_n')::int > 0
             then 'Остаток исчерпан у детей: ' || (v_d ->> 'zero_n') end);
    end if;

    center_name := v_c.name;
    message := v_c.name || E'\n' || v_head
               || case when v_lines is not null
                       then E'\n\nПервые ' || jsonb_array_length(v_d -> 'top')::text
                            || E' (по размеру):\n' || v_lines
                       else '' end;
    return next;
  end loop;

  if not v_found then
    raise exception 'Команда доступна владельцу, администратору, регистратору и бухгалтеру'
      using errcode = '42501';
  end if;
end;
$$;

comment on function public.bot_debts(bigint) is
  'Команда /debts (0072): по каждому центру пользователя чата (owner/admin/registrar/finance, центры на удалении исключены) готовый текст — два итога (долг за занятия / просрочка по абонементам, не складываются) и первые 10 детей по ключу экрана. Только чтение, STABLE: PostgREST исполняет в транзакции read-only. Роль вне списка — 42501, не пустой ответ.';


-- 5. /cash — поступления за сегодня (Р7–Р11) ------------------------------------------

create or replace function public.bot_cash(p_chat_id bigint)
  returns table (center_name text, message text)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_user  uuid;
  v_c     record;
  v_day   date;
  v_p     jsonb;
  v_src   text;
  v_n     integer;
  v_shown bigint;
  v_shown_ops integer;
  v_found boolean := false;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р12: группы и супергруппы — отрицательный chat_id.
  if p_chat_id <= 0 then
    raise exception 'Команда доступна только в личной переписке с ботом' using errcode = '42501';
  end if;

  v_user := public.telegram_user(p_chat_id);
  if v_user is null then
    raise exception 'Чат не привязан' using errcode = '42501';
  end if;

  for v_c in
    select c.id, c.name
      from public.memberships m
      join public.centers c on c.id = m.center_id and c.deleted_at is null
     where m.user_id = v_user
       and m.role in ('owner', 'admin', 'finance')
     order by c.name, c.id
  loop
    v_found := true;
    v_day := public.center_today(v_c.id);
    v_p := public.center_payments_day(v_c.id, v_day);

    if (v_p ->> 'ops')::int = 0 then
      message := v_c.name || E'\nПоступлений сегодня (' || to_char(v_day, 'DD.MM') || ') нет.';
    else
      -- Р15: восемь крупнейших источников, остальные — одной строкой.
      select string_agg('  ' || (e.s ->> 'name') || ': ' || public.format_som((e.s ->> 'total_tiyin')::bigint)
                        || ' (' || (e.s ->> 'ops') || ')', E'\n' order by e.n),
             sum((e.s ->> 'total_tiyin')::bigint), sum((e.s ->> 'ops')::integer)
        into v_src, v_shown, v_shown_ops
        from jsonb_array_elements(v_p -> 'by_source') with ordinality as e(s, n)
       where e.n <= 8;
      v_n := jsonb_array_length(v_p -> 'by_source');
      if v_n > 8 then
        v_src := v_src || E'\n  Прочие источники (' || (v_n - 8) || '): '
                 || public.format_som((v_p ->> 'total_tiyin')::bigint - v_shown)
                 || ' (' || ((v_p ->> 'ops')::integer - v_shown_ops) || ')';
      end if;

      message := v_c.name || E'\nПоступления сегодня (' || to_char(v_day, 'DD.MM') || '): '
                 || public.format_som((v_p ->> 'total_tiyin')::bigint)
                 || ', операций: ' || (v_p ->> 'ops')
                 || E'\nПо источникам:\n' || v_src;
    end if;

    center_name := v_c.name;
    return next;
  end loop;

  if not v_found then
    raise exception 'Команда доступна владельцу, администратору и бухгалтеру'
      using errcode = '42501';
  end if;
end;
$$;

comment on function public.bot_cash(bigint) is
  'Команда /cash (0072): поступления за сегодня по центрам пользователя чата (owner/admin/finance) — payments по paid_at в поясе центра, знак — часть суммы, расходы не входят (слово «касса» не используется: у неё другое определение, docs/Database.md). Разбивка по источникам, включая платежи без источника и из архивных. Только чтение.';


-- 6. Гранты ------------------------------------------------------------------------------

revoke all on function public.bot_debts(bigint) from public, anon, authenticated, service_role;
grant execute on function public.bot_debts(bigint) to bot_worker;

revoke all on function public.bot_cash(bigint) from public, anon, authenticated, service_role;
grant execute on function public.bot_cash(bigint) to bot_worker;
