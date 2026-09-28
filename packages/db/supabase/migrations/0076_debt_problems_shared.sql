-- =============================================================================
-- 0076_debt_problems_shared.sql — единый SQL-источник «проблемных» детей для
-- экранов и бота
--
-- Долг из 0072 Р5: «должник» считали в четырёх местах по-разному —
-- /app/debts в TypeScript (долг + перерасход + просрочка + исчерпанный остаток),
-- дашборд админа и ассистент (только debt_tiyin: «Долгов нет» при живых
-- просрочках абонементов), бот /debts (SQL, 0072). CLAUDE.md: деньги в браузере
-- не считаются, SQL — источник истины.
--
-- Ревью плана — architect (блокеров нет, три важных):
--   Р1. student_debt_problems() переиздана как общий источник и открыта
--       authenticated. Функция invoker над student_balance и students_brief() —
--       обе сессионные, права по роли внутри (owner/admin/registrar/finance —
--       весь центр; parent — свои дети; teacher — пусто; без сессии — пусто), так
--       что открытие не даёт больше, чем видно из student_balance напрямую.
--       Колонки расширены под страницу: payer_id, overdue_payer_id, lessons_left,
--       active_subscription_id; full_name БЕЗ обрезки (обрезка ≤60 для Telegram
--       переехала в bot_debts_center). zero_left — coalesce и только когда нет
--       денежных проблем (как на экране); порядок в SQL: sort_tiyin desc,
--       full_name, student_id (детерминизм; страница берёт «по сумме» отсюда, а не
--       из своей копии формулы).
--   Р2. Итоги — тоже в SQL: student_debt_summary(p_top) (invoker, jsonb): число и
--       сумма по корзинам, число уникальных детей с денежной проблемой
--       (debtors_n), исчерпанные остатки и топ. Считать их в TypeScript по строкам
--       RPC нельзя: PostgREST режет ответ по max_rows (1000, config.toml), итоги
--       усекались бы молча и расходились с ботом. bot_debts_center зовёт этот же
--       агрегат после подмены claims (0072 Р1–Р3 — без изменений).
--   Р3. Долг за занятия = долг + перерасход (как в боте и на странице); просрочка
--       по абонементам — отдельная корзина, не складывается (Database.md, «Два
--       слова, два определения»). Ребёнок с долгом и просрочкой учтён в обеих
--       корзинах (usage_n, overdue_n) и один раз в debtors_n.
--   Р4. Что НЕ выравнивается здесь (записано поимённо, «единого определения»
--       для них нет): {debt} утренней сводки (daily_digest, 0032: только
--       debt_tiyin, 0073 Р6), колонка «Долг» ассистента в student_info и
--       bot_balance (0033, до 0070). Определение едино для /app/debts, дашборда,
--       ассистента «Должники» и /debts в боте.
-- =============================================================================

drop function public.student_debt_problems();

create function public.student_debt_problems()
  returns table (
    student_id           uuid,
    full_name            text,
    payer_id             uuid,
    debt_tiyin           integer,
    overdrawn_tiyin      integer,
    overdue_tiyin        integer,
    overdue_payer_id     uuid,
    lessons_left         integer,
    active_subscription_id uuid,
    zero_left            boolean,
    sort_tiyin           bigint
  )
  language sql
  stable
  set search_path = ''
as $$
  select b.student_id,
         s.full_name,
         s.payer_id,
         coalesce(b.debt_tiyin, 0),
         coalesce(b.overdrawn_tiyin, 0),
         coalesce(b.subscription_overdue_tiyin, 0),
         b.subscription_overdue_payer_id,
         b.lessons_left,
         b.active_subscription_id,
         -- lessons_left = null значит и «безлимит», и «нет абонемента» (0010):
         -- исчерпан только при живом абонементе и остатке 0, и только когда
         -- денежных проблем нет вовсе — как на экране (0072 Р14).
         coalesce(b.active_subscription_id is not null and b.lessons_left = 0
                  and coalesce(b.debt_tiyin, 0) = 0
                  and coalesce(b.overdrawn_tiyin, 0) = 0
                  and coalesce(b.subscription_overdue_tiyin, 0) = 0, false),
         greatest(coalesce(b.debt_tiyin, 0)::bigint + coalesce(b.overdrawn_tiyin, 0)::bigint,
                  coalesce(b.subscription_overdue_tiyin, 0)::bigint)
    from public.student_balance b
    join public.students_brief() s on s.id = b.student_id
   where coalesce(b.debt_tiyin, 0) > 0
      or coalesce(b.overdrawn_tiyin, 0) > 0
      or coalesce(b.subscription_overdue_tiyin, 0) > 0
      or (b.active_subscription_id is not null and b.lessons_left = 0)
   order by 11 desc, 2, 1;
$$;

comment on function public.student_debt_problems() is
  'Единый источник «проблемных» детей центра (0076 Р1): долг за занятия, перерасход, просрочка по абонементу, исчерпанный остаток; порядок sort_tiyin desc, full_name, student_id. Invoker над student_balance и students_brief() — права по роли внутри (owner/admin/registrar/finance — весь центр, parent — свои дети, teacher и без сессии — пусто). Читают /app/debts, дашборд, ассистент, student_debt_summary; ответ PostgREST режется max_rows.';

revoke all on function public.student_debt_problems() from public, anon, service_role, bot_worker;
grant execute on function public.student_debt_problems() to authenticated;


create function public.student_debt_summary(p_top integer default 10)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  with p as (select * from public.student_debt_problems())
  select jsonb_build_object(
           'debtors_n',     count(*) filter (where p.debt_tiyin::bigint + p.overdrawn_tiyin::bigint > 0 or p.overdue_tiyin > 0),
           'usage_n',       count(*) filter (where p.debt_tiyin::bigint + p.overdrawn_tiyin::bigint > 0),
           'usage_tiyin',   coalesce(sum(p.debt_tiyin::bigint + p.overdrawn_tiyin::bigint), 0),
           'overdue_n',     count(*) filter (where p.overdue_tiyin > 0),
           'overdue_tiyin', coalesce(sum(p.overdue_tiyin::bigint), 0),
           'zero_n',        count(*) filter (where p.zero_left),
           'top', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'student_id', t.student_id,
                      'name', t.full_name,
                      'usage_tiyin', t.debt_tiyin::bigint + t.overdrawn_tiyin::bigint,
                      'overdue_tiyin', t.overdue_tiyin,
                      'zero_left', t.zero_left)
                    order by t.sort_tiyin desc, t.full_name, t.student_id)
               from (select * from p
                      order by sort_tiyin desc, full_name, student_id
                      limit least(greatest(coalesce(p_top, 10), 0), 50)) t
           ), '[]'::jsonb))
    from p;
$$;

comment on function public.student_debt_summary(integer) is
  'Итоги по student_debt_problems (0076 Р2): usage_n/usage_tiyin (долг + перерасход), overdue_n/overdue_tiyin (просрочка, не складывается с долгом), debtors_n (уникальные дети с денежной проблемой), zero_n (исчерпанный остаток без денежных проблем), top — первые p_top (до 50) по sort_tiyin. Считает SQL целиком: PostgREST режет ответ по max_rows, TypeScript-итоги по строкам усекались бы молча.';

revoke all on function public.student_debt_summary(integer) from public, anon, service_role, bot_worker;
grant execute on function public.student_debt_summary(integer) to authenticated;


-- bot_debts_center: тело 0072 без изменений, кроме источника итогов (Р2).
create or replace function public.bot_debts_center(p_user uuid, p_center uuid)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_prev text;
  v_ok   boolean;
  v_out  jsonb;
  v_sum  jsonb;
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
    -- Итоги и топ — общий агрегат student_debt_summary (0076): дашборд читает
    -- тот же SQL. Здесь только форма ответа бота: без debtors_n и с именами
    -- не длиннее 60 знаков (сообщение Telegram, 0072 Р10).
    v_sum := public.student_debt_summary(10);
    v_out := (v_sum - 'top' - 'debtors_n') || jsonb_build_object('top', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', left(x.e ->> 'name', 60),
               'usage_tiyin', x.e -> 'usage_tiyin',
               'overdue_tiyin', x.e -> 'overdue_tiyin',
               'zero_left', x.e -> 'zero_left') order by x.n)
        from jsonb_array_elements(v_sum -> 'top') with ordinality as x(e, n)
    ), '[]'::jsonb));
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
  'Долги одного центра для пользователя чата под ЛОКАЛЬНО подменённой сессией (0072 Р1–Р3; с 0076 итоги — общий агрегат student_debt_summary). SECURITY INVOKER (0072 Р13) и без грантов ни у кого, включая bot_worker: помощник «стать пользователем» не должен быть доступен по ключу бота. p_user — только из telegram_user(chat), p_center — только из его memberships. claims возвращаются в конце; ранних return после подмены нет.';

revoke all on function public.bot_debts_center(uuid, uuid)
  from public, anon, authenticated, service_role, bot_worker;
