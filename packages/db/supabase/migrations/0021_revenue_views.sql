-- =============================================================================
-- 0021_revenue_views.sql — витрины выручки и кассы (этап 5, промт п.9)
--
-- Architect-ревью плана: 12 находок, учтены. Определения — здесь и в
-- docs/Database.md («Витрины финансов»); две витрины с двумя разными
-- определениями одного слова — то, из-за чего выручка и зарплата в 0017
-- могли бы разъехаться.
--
--   В1. ВЫРУЧКА (revenue_*) — начисление: отметки с deducted = true по
--       занятиям в статусе done. planned (отметили, но не нажали
--       «Проведено») и cancelled (отменили после отметок) в выручку не
--       входят — так же, как не входят в зарплату. Сумма —
--       attendance.price_tiyin, замороженная при отметке.
--       НЕ одна база с зарплатой: выручка идёт по deducted (списано с
--       ребёнка), зарплата (0017) — по pays_teacher (обязательство перед
--       специалистом). Это две галочки статуса посещения, администратор
--       правит их независимо («Прогул»: списывает, не оплачивается).
--       «Маржа = выручка − зарплата» — не разность по одному множеству;
--       тест 0021 фиксирует расхождение как ожидаемое.
--   В2. Ноль в price_tiyin — два разных случая, две колонки: unlimited_visits
--       (безлимит: subscription_id есть, lesson_price_tiyin null → 0) и
--       unpriced_visits (абонемента нет, а у услуги цена не задана или
--       занятие без услуги — деньги потеряны, не «безлимит»). Оба нуля
--       ВИДНЫ, а не растворены в сумме. Безлимиты в выручку не входят ни
--       одной суммой — смотреть кассу; подпись об этом — на экране.
--   В3. visits ≠ lessons: строка attendance — на ребёнка, групповое занятие
--       на шестерых даёт 6 visits и 1 lesson. Обе колонки, оба имени.
--   В4. КАССА (cash_by_source) — платежи И расходы по месяцу paid_at в
--       поясе центра, по источнику. Знак у всех колонок один: вклад в
--       кассу (+ пришло, − ушло); расход инвертируется (0016: там плюс —
--       «деньги ушли»). Каждая агрегатная колонка coalesce(…, 0), неизвестный
--       kind — в other_tiyin, чтобы был громким, а не терялся из именованных
--       колонок при сохранении в total.
--   В5. Пояс — центра (settings->>'timezone'), один раз на запрос (CTE tz),
--       не на строку. Месяц витрины совпадает с месяцем замка
--       financial_period_guard по построению (то же выражение).
--   В6. Ролевой фильтр в теле каждой витрины (owner/admin + свой центр),
--       как у student_balance: у attendance есть teacher-политика, у payments
--       — parent; агрегаты центра — не для них (ADR-005). Сам фильтр —
--       договорённость; механизм — тест 0021, перечисляющий витрины
--       revenue_%/cash_% из каталога: забытый фильтр роняет CI.
--   В7. Join только к lessons (нужны status, service_id, starts_at) — и
--       никаких join к teachers/services/payers: под security_invoker RLS
--       этих таблиц (deleted_at is null) молча уносила бы выручку
--       архивного специалиста. Имена резолвит интерфейс отдельно.
--       lessons.deleted_at is null — явно: занятие с отметками, если его
--       когда-нибудь станут мягко удалять, выпадет из выручки, но останется
--       в student_balance.debt_tiyin — тогда это решение пересмотреть.
--   В8. «План» (выручка месяц/план на дашборде) не строится — таблицы
--       плана нет; отступление в отчёт этапа. Долги — student_balance,
--       просроченные рассрочки — installments_view (0020): отдельных витрин
--       не нужно. Схема — public: отдельная схема требует ручного действия
--       владельца в дашборде (Exposed schemas).
--   В9. Дата платежа приходит из браузера моментом (record_payment
--       p_paid_at timestamptz), а у расхода — днём по поясу центра
--       (record_expense p_paid_on). Витрина считает по поясу центра, как
--       замок; приведение record_payment к дате — отдельная задача перед UI
--       платежей.
-- =============================================================================


-- 0. Индексы под группировку по месяцу и по источнику -------------------------

-- У expenses (center_id, paid_at) и (source_id) есть с 0016; у payments —
-- только (center_id): Advisor давал unindexed_foreign_keys по
-- payments_source_fk.
create index if not exists payments_center_paid_at_idx on public.payments (center_id, paid_at);
create index if not exists payments_source_idx on public.payments (source_id);


-- 1. Выручка ---------------------------------------------------------------------

create or replace view public.revenue_by_month
  with (security_invoker = true)
as
with tz as (
  select public.center_timezone(public.current_center()) as tz
),
base as (
  select a.center_id, a.lesson_id, a.price_tiyin, a.subscription_id,
         date_trunc('month', (l.starts_at at time zone t.tz))::date as month
    from public.attendance a
    join public.lessons l on l.id = a.lesson_id
    cross join tz t
   where a.center_id = public.current_center()
     and coalesce(public.my_role(), '') in ('owner', 'admin')
     and a.deducted
     and l.status = 'done'
     and l.deleted_at is null
)
select b.center_id,
       b.month,
       count(*)::integer                                   as visits,
       count(distinct b.lesson_id)::integer                as lessons,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is not null))::integer as unlimited_visits,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is null))::integer     as unpriced_visits,
       coalesce(sum(b.price_tiyin), 0)::bigint             as revenue_tiyin
  from base b
 group by b.center_id, b.month;

comment on view public.revenue_by_month is
  'Выручка по месяцам (начисление): отметки deducted по занятиям done, месяц — по starts_at в поясе центра. Только owner/admin своего центра.';
comment on column public.revenue_by_month.unlimited_visits is
  'Посещения по безлимитному абонементу (price_tiyin = 0 при subscription_id): в revenue_tiyin дают ноль — здесь он виден; сумму безлимитов смотреть в кассе.';
comment on column public.revenue_by_month.unpriced_visits is
  'Посещения без абонемента с ценой 0 — у услуги не задана цена или занятие без услуги: деньги не начислены, это не безлимит.';

create or replace view public.revenue_by_teacher
  with (security_invoker = true)
as
with tz as (
  select public.center_timezone(public.current_center()) as tz
),
base as (
  select a.center_id, a.lesson_id, a.price_tiyin, a.subscription_id, a.paid_teacher_id,
         date_trunc('month', (l.starts_at at time zone t.tz))::date as month
    from public.attendance a
    join public.lessons l on l.id = a.lesson_id
    cross join tz t
   where a.center_id = public.current_center()
     and coalesce(public.my_role(), '') in ('owner', 'admin')
     and a.deducted
     and l.status = 'done'
     and l.deleted_at is null
)
select b.center_id,
       b.month,
       -- Кто фактически провёл (заморожен при отметке, 0017) — та же
       -- атрибуция, что у зарплаты; не lessons.teacher_id.
       b.paid_teacher_id                                   as teacher_id,
       count(*)::integer                                   as visits,
       count(distinct b.lesson_id)::integer                as lessons,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is not null))::integer as unlimited_visits,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is null))::integer     as unpriced_visits,
       coalesce(sum(b.price_tiyin), 0)::bigint             as revenue_tiyin
  from base b
 group by b.center_id, b.month, b.paid_teacher_id;

comment on view public.revenue_by_teacher is
  'Выручка по специалистам (начисление), атрибуция по attendance.paid_teacher_id — как в зарплате.';

create or replace view public.revenue_by_service
  with (security_invoker = true)
as
with tz as (
  select public.center_timezone(public.current_center()) as tz
),
base as (
  select a.center_id, a.lesson_id, a.price_tiyin, a.subscription_id, l.service_id,
         date_trunc('month', (l.starts_at at time zone t.tz))::date as month
    from public.attendance a
    join public.lessons l on l.id = a.lesson_id
    cross join tz t
   where a.center_id = public.current_center()
     and coalesce(public.my_role(), '') in ('owner', 'admin')
     and a.deducted
     and l.status = 'done'
     and l.deleted_at is null
)
select b.center_id,
       b.month,
       b.service_id,                                        -- null = занятие без услуги
       count(*)::integer                                   as visits,
       count(distinct b.lesson_id)::integer                as lessons,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is not null))::integer as unlimited_visits,
       (count(*) filter (where b.price_tiyin = 0 and b.subscription_id is null))::integer     as unpriced_visits,
       coalesce(sum(b.price_tiyin), 0)::bigint             as revenue_tiyin
  from base b
 group by b.center_id, b.month, b.service_id;

comment on view public.revenue_by_service is
  'Выручка по услугам (начисление); service_id null — занятие без услуги.';


-- 2. Касса по источникам ------------------------------------------------------------

create or replace view public.cash_by_source
  with (security_invoker = true)
as
with tz as (
  select public.center_timezone(public.current_center()) as tz
),
flows as (
  select p.center_id, p.source_id, p.kind,
         p.amount_tiyin::bigint                                   as delta,
         date_trunc('month', (p.paid_at at time zone t.tz))::date as month,
         'payment'                                                as src
    from public.payments p
    cross join tz t
   where p.center_id = public.current_center()
     and coalesce(public.my_role(), '') in ('owner', 'admin')
  union all
  -- Расход: в expenses плюс — «ушло из кассы» (0016), здесь знак инвертирован.
  select e.center_id, e.source_id, e.kind,
         -(e.amount_tiyin::bigint),
         date_trunc('month', (e.paid_at at time zone t.tz))::date,
         'expense'
    from public.expenses e
    cross join tz t
   where e.center_id = public.current_center()
     and coalesce(public.my_role(), '') in ('owner', 'admin')
)
select f.center_id,
       f.month,
       f.source_id,                                                                   -- null = источник не указан
       coalesce(sum(f.delta) filter (where f.src = 'payment' and f.kind = 'payment'),    0)::bigint as received_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'payment' and f.kind = 'refund'),     0)::bigint as refunded_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'payment' and f.kind = 'correction'), 0)::bigint as corrections_tiyin,
       coalesce(sum(f.delta) filter (where f.src = 'expense'
                                       and f.kind in ('expense', 'refund', 'correction')),  0)::bigint as spent_tiyin,
       -- Неизвестный kind — и у платежей, и у расходов: громкий, а не
       -- проглоченный именованной колонкой.
       coalesce(sum(f.delta) filter (where (f.src = 'payment' and f.kind not in ('payment', 'refund', 'correction'))
                                        or (f.src = 'expense' and f.kind not in ('expense', 'refund', 'correction'))),
                0)::bigint as other_tiyin,
       coalesce(sum(f.delta), 0)::bigint                                                            as total_tiyin
  from flows f
 group by f.center_id, f.month, f.source_id;

comment on view public.cash_by_source is
  'Касса по источникам и месяцам (paid_at в поясе центра): платежи и расходы вместе. Все колонки — вклад в кассу с одним знаком: плюс пришло, минус ушло; total_tiyin = сумма остальных.';
comment on column public.cash_by_source.refunded_tiyin is
  'Возвраты платежей — отрицательные (как хранятся в payments).';
comment on column public.cash_by_source.spent_tiyin is
  'Расходы с инвертированным знаком: expense → минус, возврат расхода → плюс.';
comment on column public.cash_by_source.other_tiyin is
  'Платежи и расходы с kind вне известных витрине: ноль, пока такого вида нет; ненулевое — сигнал, что витрину не обновили под новый kind.';


-- Гранты ------------------------------------------------------------------------

-- Supabase раздаёт новым объектам public дефолтные привилегии — revoke
-- обязателен. Только select: вью на одной таблице была бы автоматически
-- обновляемой, grant по недосмотру открыл бы запись мимо record_payment.
revoke all on public.revenue_by_month, public.revenue_by_teacher,
              public.revenue_by_service, public.cash_by_source
  from anon, authenticated;
grant select on public.revenue_by_month, public.revenue_by_teacher,
                public.revenue_by_service, public.cash_by_source
  to authenticated;
