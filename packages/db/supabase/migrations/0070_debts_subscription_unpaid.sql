-- =============================================================================
-- 0070_debts_subscription_unpaid.sql — просрочка по абонементу видна на
-- /app/debts (architect-ревью плана — 11 находок, ревью написанного SQL —
-- ещё 8, читай ниже, что учтено и как)
--
-- /app/debts (student_balance.debt_tiyin/overdrawn_tiyin, 0031) видит долг
-- за занятия, но не видит просроченную оплату САМОГО абонемента: семья
-- взяла рассрочку, платёж просрочен на две недели — на живой странице
-- долгов ребёнок не появляется, хотя export_debts() (0058,
-- subscriptions_unpaid_tiyin) уже считает эту сумму для CSV-выгрузки.
--
-- Формула export_debts НЕ переиспользуется дословно (ревью плана, находки
-- №1/№2): та формула — «вся недоплата по цене абонемента, независимо от
-- графика», нужна для бухгалтерского отчёта «сколько всего нам должны». На
-- живой странице долгов с кнопкой «Написать в WhatsApp» это опасно: семья,
-- которая только что оформила рассрочку на три месяца и внесла первый
-- платёж, немедленно попала бы в список должников.
--
-- Здесь — более узкое понятие, «просрочено» (docs/Database.md, «Два слова,
-- два определения»):
--   - абонемент с живым планом рассрочки (installment_plans, 0020) — сумма
--     просроченных строк installments_view.state = 'overdue', НО не больше
--     фактического остатка price_tiyin − paid_tiyin (ревью написанного SQL,
--     находка №5: частичный платёж обычной формой record_payment мимо
--     pay_installment не гасит конкретную строку рассрочки — cumulative-сумма
--     в installments_view это не видит, — поэтому сумма просроченных строк
--     может быть больше, чем реально должны; ограничиваем сверху остатком);
--   - абонемент без живого плана (не продавался в рассрочку, план отменён
--     cancel_installment_plan) — вся недоплата (price_tiyin − paid_tiyin)
--     срочна немедленно: графика ждать нечего, это тот же случай, что
--     export_debts всегда трактует как непосредственный долг. Осознанно НЕ
--     вводим отсрочку/льготный период на этот случай (ревью плана, находка
--     №7, ревью SQL, находка №7): стойка, принимающая частичный платёж без
--     формальной рассрочки, обязана оформить create_installment_plan (RPC
--     в два клика) — тогда сработает первая ветка и просрочки не будет,
--     пока не наступит её собственный срок. Это правило процесса, а не
--     пробел кода; export_debts (0058) уже год живёт с тем же допущением.
--
-- Атрибуция плательщика (ревью плана, находка №7; ревью SQL, находка №6):
-- ребёнка могли передать другому плательщику (link_parent_payer, 0060), а
-- недоплаченный абонемент остаётся долгом того, кто его покупал —
-- subscriptions.payer_id, не текущий students.payer_id. Функция возвращает
-- payer_id отдельной колонкой (NULL, если у ребёнка одновременно просрочены
-- абонементы разных плательщиков — сумма в этом случае не привязывается ни
-- к одному контакту автоматически, TypeScript должен решить, кому писать,
-- а не молча взять текущего плательщика ребёнка).
-- =============================================================================

create or replace function public.student_subscriptions_overdue()
  returns table (student_id uuid, overdue_tiyin integer, payer_id uuid)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_payer  uuid;
begin
  if auth.uid() is null then
    return;
  end if;

  if public.can_payments() then
    return query
      with per_sub as (
        -- Абонементы с живым планом: просрочка по плану, но не больше
        -- фактического остатка (находка №5) — группировка по конкретному
        -- абонементу, не сразу по ребёнку, иначе ограничить сверху нечем.
        select s.student_id, s.payer_id,
               least(sum(iv.amount_tiyin), greatest(s.price_tiyin - s.paid_tiyin, 0))::integer as amt
          from public.installments_view iv
          join public.subscriptions s on s.id = iv.subscription_id
          join public.students st on st.id = s.student_id and st.center_id = s.center_id
         where iv.center_id = v_center
           and iv.cancelled_at is null
           and iv.state = 'overdue'
           and s.deleted_at is null
           and st.deleted_at is null
           and s.status <> 'cancelled'
         group by s.id, s.student_id, s.payer_id

        union all

        -- Абонементы без живого плана: весь остаток просрочен немедленно.
        select s.student_id, s.payer_id, (s.price_tiyin - s.paid_tiyin)::integer as amt
          from public.subscriptions s
          join public.students st on st.id = s.student_id and st.center_id = s.center_id
         where s.center_id = v_center
           and s.deleted_at is null
           and st.deleted_at is null
           and s.status <> 'cancelled'
           and s.paid_tiyin < s.price_tiyin
           and not exists (
             select 1 from public.installment_plans p
              where p.subscription_id = s.id and p.cancelled_at is null
           )
      )
      select x.student_id,
             sum(x.amt)::integer,
             -- min(uuid) не существует как агрегат — сортируем по тексту;
             -- это не более чем «взять единственное значение», а не
             -- содержательный минимум, потому и работает только когда
             -- count(distinct) = 1 (иначе — null, находка №6 ревью SQL).
             case when count(distinct x.payer_id) = 1 then min(x.payer_id::text)::uuid else null end
        from per_sub x
       where x.amt > 0
       group by x.student_id;
    return;
  end if;

  if coalesce(public.my_role(), '') = 'parent' then
    v_payer := public.my_payer_id();
    if v_payer is null then
      return;
    end if;

    return query
      with per_sub as (
        select s.student_id, s.payer_id,
               least(sum(iv.amount_tiyin), greatest(s.price_tiyin - s.paid_tiyin, 0))::integer as amt
          from public.installments_view iv
          join public.subscriptions s on s.id = iv.subscription_id
          join public.students st on st.id = s.student_id and st.center_id = s.center_id
         where iv.center_id = v_center
           and iv.cancelled_at is null
           and iv.state = 'overdue'
           and s.deleted_at is null
           and st.deleted_at is null
           and s.status <> 'cancelled'
           and s.payer_id = v_payer
         group by s.id, s.student_id, s.payer_id

        union all

        select s.student_id, s.payer_id, (s.price_tiyin - s.paid_tiyin)::integer as amt
          from public.subscriptions s
          join public.students st on st.id = s.student_id and st.center_id = s.center_id
         where s.center_id = v_center
           and s.deleted_at is null
           and st.deleted_at is null
           and s.status <> 'cancelled'
           and s.paid_tiyin < s.price_tiyin
           and s.payer_id = v_payer
           and not exists (
             select 1 from public.installment_plans p
              where p.subscription_id = s.id and p.cancelled_at is null
           )
      )
      select x.student_id,
             sum(x.amt)::integer,
             case when count(distinct x.payer_id) = 1 then min(x.payer_id::text)::uuid else null end
        from per_sub x
       where x.amt > 0
       group by x.student_id;
    return;
  end if;
  -- teacher и прочие роли — пусто, ни одна ветка выше не вернула query.
end;
$$;

comment on function public.student_subscriptions_overdue() is
  'Просроченная оплата абонемента, строка на ребёнка текущего центра (0070): с живым планом рассрочки — сумма installments_view.state=overdue, но не больше фактического остатка, без плана — вся недоплата немедленно. НЕ то же самое, что export_debts().subscriptions_unpaid_tiyin (0058): там любая недоплата независимо от графика, для бухгалтерского отчёта, не для живой страницы с уведомлением родителей — см. docs/Database.md, «Два слова, два определения». payer_id — плательщик абонемента (subscriptions.payer_id, не текущий payer_id ребёнка); NULL, если у ребёнка одновременно просрочены абонементы разных плательщиков — писать в этом случае молча текущему плательщику ребёнка нельзя. owner/admin/registrar/finance — весь центр, parent — свои дети по subscriptions.payer_id, остальным пусто.';

revoke all on function public.student_subscriptions_overdue() from public, anon, service_role;
grant execute on function public.student_subscriptions_overdue() to authenticated;


-- student_balance: две новые колонки в конец списка — create or replace view
-- не может ни удалить, ни переставить существующие, только дописать в
-- хвост (ревью написанного SQL, находка №1: `state` был случайно оставлен
-- НЕ последней колонкой при первой попытке — 42P16 на деплое; здесь порядок
-- первых восьми колонок — дословно 0031:373-388, `state` — восьмая, новые
-- две — девятая и десятая). Ни один потребитель в apps/web не делает
-- select('*') на student_balance (dashboard-admin.tsx, dashboard-parent.tsx,
-- debts/page.tsx, students/[id]/page.tsx, schedule/actions.ts,
-- assistant/intents.ts — все перечисляют колонки явно).
create or replace view public.student_balance
  with (security_invoker = true)
as
  select
    s.id                                        as student_id,
    s.center_id,
    b.subscription_id                           as active_subscription_id,
    public.subscription_lessons_left(b.subscription_id) as lessons_left,
    b.ends_at,
    coalesce(d.debt_tiyin, 0)::integer          as debt_tiyin,
    (greatest(-coalesce(public.subscription_lessons_left(b.subscription_id), 0), 0)
      * coalesce(b.lesson_price_tiyin, 0))::integer as overdrawn_tiyin,
    b.state,
    coalesce(o.overdue_tiyin, 0)::integer       as subscription_overdue_tiyin,
    o.payer_id                                  as subscription_overdue_payer_id
  from public.students_brief() s
  left join lateral public.student_balance_pick(s.id) b on true
  left join public.student_debts() d on d.student_id = s.id
  left join public.student_subscriptions_overdue() o on o.student_id = s.id;

-- create or replace сохраняет ACL; повторяем явно (правило 0010).
revoke all on table public.student_balance from public, anon, authenticated;
grant select on table public.student_balance to authenticated;
