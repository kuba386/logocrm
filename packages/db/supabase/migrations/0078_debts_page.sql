-- =============================================================================
-- 0078_debts_page.sql — страница /app/debts одним запросом
--
-- Долг из 0076: после student_debt_problems() страница добирала данные тремя
-- запросами PostgREST — прошлые уроки всех проблемных детей без лимита
-- (max_rows 1000 резал ответ, и «Последнее занятие» молча уезжало), будущие
-- уроки и плательщиков через .in('…', ids). Сотни uuid в URL упираются в его
-- длину. Теперь всё собирает одна invoker-функция на стороне базы.
--
-- Ревью плана — architect (блокеров нет):
--   Р1. Отдельная функция, а не расширение student_debt_problems(): её выдачу
--       читают student_debt_summary, бот, ассистент и дашборд.
--   Р2. Контакты — через payers_brief() (0031: без notes и удалённых;
--       owner/admin/registrar/finance), а не из таблицы payers: у finance
--       табличных политик на payers нет, контакты пропали бы молча.
--   Р3. payer_id и overdue_payer_id — сырые, как в 0076: страница сравнивает
--       их между собой (кому можно писать о просрочке). Видимость плательщика —
--       payer_name is not null.
--   Р4. Последнее занятие — самое позднее начавшееся (starts_at < now()),
--       не отменённое и не удалённое; ближайшее — planned, не удалённое,
--       starts_at >= now(). Идущее сейчас занятие — «последнее». До 0078
--       отменённые и удалённые в «последнее» попадали.
--   Р5. SECURITY INVOKER: всё под RLS и правами вызывающего, данных сверх
--       прямого чтения нет, поэтому отдельной проверки роли внутри нет. Если
--       функцию когда-нибудь переведут в definer — проверка роли обязательна.
--
-- Что видит роль (фиксирует tests/0078):
--   owner/admin — всё; registrar — всё (lesson_participants ему открыт с 0028);
--   finance — долги и контакты, last/next = NULL (lesson_participants ему закрыт);
--   parent — свои дети и даты, контакты NULL (payers_brief родителю пуст);
--   teacher и без сессии — пусто.
--
-- Таблиц нет — deny-list экспорта не затрагивается.
-- =============================================================================

create function public.student_debt_page()
  returns table (
    student_id             uuid,
    full_name              text,
    payer_id               uuid,
    payer_name             text,
    payer_phone            text,
    debt_tiyin             integer,
    overdrawn_tiyin        integer,
    overdue_tiyin          integer,
    overdue_payer_id       uuid,
    overdue_payer_name     text,
    overdue_payer_phone    text,
    lessons_left           integer,
    active_subscription_id uuid,
    zero_left              boolean,
    sort_tiyin             bigint,
    last_lesson_at         timestamptz,
    next_lesson_at         timestamptz
  )
  language sql
  stable
  set search_path = ''
as $$
  with p as (select * from public.student_debt_problems()),
       pb as (select b.id, b.full_name, b.phone from public.payers_brief() b)
  select p.student_id,
         p.full_name,
         p.payer_id,
         py.full_name,
         py.phone,
         p.debt_tiyin,
         p.overdrawn_tiyin,
         p.overdue_tiyin,
         p.overdue_payer_id,
         op.full_name,
         op.phone,
         p.lessons_left,
         p.active_subscription_id,
         p.zero_left,
         p.sort_tiyin,
         (select max(lp.starts_at)
            from public.lesson_participants lp
           where lp.student_id = p.student_id
             and lp.deleted_at is null
             and lp.status <> 'cancelled'
             and lp.starts_at < now()),
         (select min(lp.starts_at)
            from public.lesson_participants lp
           where lp.student_id = p.student_id
             and lp.deleted_at is null
             and lp.status = 'planned'
             and lp.starts_at >= now())
    from p
    left join pb py on py.id = p.payer_id
    left join pb op on op.id = p.overdue_payer_id
   order by p.sort_tiyin desc, p.full_name, p.student_id;
$$;

comment on function public.student_debt_page() is
  'Страница /app/debts одним запросом (0078): строки student_debt_problems() + контакты из payers_brief() + последнее/ближайшее занятие из lesson_participants. Invoker: всё под RLS вызывающего (finance — без дат, parent — без контактов, teacher и без сессии — пусто). payer_id/overdue_payer_id сырые, видимость — payer_name is not null. Порядок как у 0076: sort_tiyin desc, full_name, student_id.';

revoke all on function public.student_debt_page() from public, anon, service_role, bot_worker;
grant execute on function public.student_debt_page() to authenticated;
