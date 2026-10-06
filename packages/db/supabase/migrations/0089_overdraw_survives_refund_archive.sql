-- =============================================================================
-- 0089_overdraw_survives_refund_archive.sql — перерасход не теряется при
-- возврате и архиве абонемента
--
-- Найдено ревью 0088 (этап 10, docs/Roadmap/stages.md, «Попутно в долги»).
-- Перерасход (отметки сверх пакета при allow_negative) — долг по факту
-- посещений; 0087 гасит его оплатой и списанием. Три места его теряли:
--
--   Р1. lesson_debt_accounts_unchecked (0088): CTE ov считало только живые
--       пакеты, а subscriptions_guard_soft_delete (0010) пускает в архив и
--       перерасходованный (остаток ≤ 0). Архив обнулял перерасход, и уже
--       внесённая оплата долга становилась авансом, который можно вернуть
--       деньгами. Переиздано дословно, без фильтра s.deleted_at в ov — та же
--       логика, что «архив не снимает покрытие» в 0088 Р3.
--   Р2. refund_subscription (0030): written_off += остаток, а у
--       перерасходованного пакета он отрицательный. При written_off = 0 —
--       CHECK lessons_written_off >= 0 (0008), пакет с перерасходом нельзя
--       было отменить вовсе. Теперь списывается greatest(остаток, 0). Ветка
--       «written_off > 0 и минус» штатно недостижима (written_off растёт только
--       в refund/transfer, обе отменяют пакет) — это защита от ручной правки.
--       Попутно явная проверка auth.uid() и центра первой строкой.
--   Р3. refund_calc_unchecked (0054): ветка пакета — остаток × цена, у
--       перерасхода отрицательная сумма «к возврату» в карточке и в
--       p_expected. Теперь greatest(остаток, 0), как refundAmount в
--       packages/core (TS-зеркало уже так считало — общий случай «8 занятий,
--       отходил 10» в Vitest и pgTAP).
--
--   Р4. Без фильтра deleted_at ov не попадает в частичные индексы subscriptions
--       (0008) — непартиальный (student_id, center_id); он же покрывает FK
--       subscriptions_student_fk (урок 0069).
--
-- НЕ здесь, в долги (ревью 0089): отмена или архив частично оплаченного пакета
-- стирает недоплату за отработанные занятия — «просрочка» (0070) и экспорт
-- (0058) берут только живые неотменённые пакеты, рассрочка гасится при отмене
-- (0020). Так было и для исчерпанного пакета; 0089 делает доступной ещё и
-- отмену перерасходованного. Нужен выбор владельца: запрет отмены при
-- недоплате или недоплата отменённых в счёте долга. И transfer_remaining
-- (0055) не проверяет status = 'cancelled'.
--
-- Данных чинить не нужно: на prod и staging 6.10.2026 нет ни одного
-- перерасходованного пакета, written_off < 0 и событий возврата с минусом.
-- =============================================================================


-- 1. Счёт долга: перерасход по всем пакетам, включая архивные (Р1, Р4) ------

create index if not exists subscriptions_student_center_idx
  on public.subscriptions (student_id, center_id);

create or replace function public.lesson_debt_accounts_unchecked(p_center_id uuid, p_student_id uuid default null)
  returns table (
    student_id          uuid,
    accrued_tiyin       integer,
    overdrawn_gross_tiyin integer,
    paid_tiyin          integer,
    written_off_tiyin   integer,
    debt_tiyin          integer,
    overdrawn_tiyin     integer,
    credit_tiyin        integer,
    remaining_tiyin     integer
  )
  language sql
  stable
  security definer
  set search_path = ''
as $$
  with acc as (
    select a.student_id, sum(a.price_tiyin)::bigint as v
      from public.attendance a
      join public.lessons l on l.id = a.lesson_id
     where a.center_id = p_center_id
       and (p_student_id is null or a.student_id = p_student_id)
       and a.subscription_id is null
       and a.deducted
       and l.deleted_at is null
       and l.status <> 'cancelled'
       -- 0088: отметка, покрытая абонементом, — уже не долг: её занятие списано с абонемента.
       and not exists (select 1 from public.lesson_debt_covers c
                        where c.attendance_id = a.id and c.deleted_at is null)
     group by a.student_id
  ),
  ov as (
    select s.student_id,
           sum(greatest(s.lessons_used + s.lessons_written_off - s.lessons_total, 0)::bigint
               * coalesce(s.lesson_price_tiyin, 0))::bigint as v
      from public.subscriptions s
     where s.center_id = p_center_id
       and (p_student_id is null or s.student_id = p_student_id)
       -- 0089: без s.deleted_at is null — архив перерасходованного пакета
       -- перерасход не отменяет (Р1).
       and s.lessons_total is not null
     group by s.student_id
  ),
  pd as (
    select p.student_id, sum(p.amount_tiyin)::bigint as v
      from public.payments p
     where p.center_id = p_center_id
       and (p_student_id is null or p.student_id = p_student_id)
       and p.covers_lesson_debt
     group by p.student_id
  ),
  wo as (
    select w.student_id, sum(w.amount_tiyin)::bigint as v
      from public.lesson_debt_writeoffs w
     where w.center_id = p_center_id
       and (p_student_id is null or w.student_id = p_student_id)
       and w.deleted_at is null
     group by w.student_id
  ),
  ids as (
    select acc.student_id from acc
    union select ov.student_id from ov
    union select pd.student_id from pd
    union select wo.student_id from wo
  ),
  base as (
    select i.student_id,
           coalesce(acc.v, 0)              as accrued,
           coalesce(ov.v, 0)               as over_gross,
           greatest(coalesce(pd.v, 0), 0)  as paid,
           coalesce(wo.v, 0)               as written_off
      from ids i
      join public.students st on st.id = i.student_id and st.center_id = p_center_id and st.deleted_at is null
      left join acc on acc.student_id = i.student_id
      left join ov  on ov.student_id  = i.student_id
      left join pd  on pd.student_id  = i.student_id
      left join wo  on wo.student_id  = i.student_id
  )
  select b.student_id,
         b.accrued::integer,
         b.over_gross::integer,
         b.paid::integer,
         b.written_off::integer,
         greatest(b.accrued - (b.paid + b.written_off), 0)::integer,
         greatest(b.over_gross - greatest(b.paid + b.written_off - b.accrued, 0), 0)::integer,
         greatest(b.paid - (b.accrued + b.over_gross), 0)::integer,
         greatest(b.accrued + b.over_gross - (b.paid + b.written_off), 0)::integer
    from base b;
$$;


comment on function public.lesson_debt_accounts_unchecked(uuid, uuid) is
  'Счёт занятий детей центра (0087 Р2): начислено (отметки без абонемента у живых занятий, кроме покрытых абонементом — 0088), валовой перерасход по всем пакетам, включая архивные (0089), оплачено (только covers_lesson_debt), списано → долг, перерасход, аванс, остаток. Без проверки сессии — для триггеров и обёрток; грантов нет.';

revoke all on function public.lesson_debt_accounts_unchecked(uuid, uuid) from public, anon, authenticated, service_role;


-- 2. Возврат не списывает минус (Р2) -------------------------------------------

create or replace function public.refund_subscription(
  p_id             uuid,
  p_expected_tiyin integer,
  p_source_id      uuid default null
)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_sub    public.subscriptions;
  v_actual integer;
  v_refund integer;
  v_left   integer;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_sub from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  -- Р4: явно, до расчёта — иначе status='cancelled' перезаписывался бы
  -- молча, а lessons_written_off списывались бы второй раз.
  if v_sub.status = 'cancelled' then
    raise exception 'Абонемент уже отменён' using errcode = '22023';
  end if;

  -- refund_calc — стоимость НЕОТРАБОТАННЫХ занятий (сверка с формой и
  -- событие остаются про это же число, как раньше); деньги, которые
  -- реально возвращаются, — Р1.
  v_actual := public.refund_calc(p_id);
  if v_actual is distinct from p_expected_tiyin then
    raise exception 'Остаток изменился, пока считали возврат: сейчас % тыйын. Проверьте расчёт.', v_actual
      using errcode = '23514';
  end if;

  v_refund := least(v_actual, v_sub.paid_tiyin);
  if v_refund > 0 and p_source_id is null then
    raise exception 'Укажите источник оплаты' using errcode = '22023';
  end if;

  -- 0089 (Р2): у перерасходованного пакета остаток отрицательный — списывать
  -- нечего. Прибавка минуса падала на CHECK lessons_written_off >= 0, а при
  -- written_off > 0 молча стирала перерасход.
  v_left := greatest(coalesce(public.subscription_lessons_left(p_id), 0), 0);
  update public.subscriptions
     set lessons_written_off = lessons_written_off + v_left,
         status = 'cancelled'
   where id = p_id;

  if v_refund > 0 then
    -- record_payment — тот же путь, что у любых других денег: пересчёт
    -- paid_tiyin и событие payment.refunded достаются отсюда, не
    -- дублируются вручную.
    perform public.record_payment(
      v_sub.payer_id, -v_refund, 'refund', v_sub.student_id, p_id,
      p_source_id, now(), 'Возврат при отмене абонемента'
    );
  end if;

  perform public.emit_event('subscription.refunded',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id,
                       'lessons', v_left, 'amount_tiyin', v_actual,
                       'refund_tiyin', v_refund), v_center);
  return v_actual;
end;
$$;


revoke execute on function public.refund_subscription(uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.refund_subscription(uuid, integer, uuid) to authenticated;


-- 3. «К возврату» не бывает отрицательным (Р3) ----------------------------------

create or replace function public.refund_calc_unchecked(p_id uuid)
  returns integer
  language sql
  stable
  security definer
  set search_path = ''
as $$
  with sub as (
    select
      s.id, s.center_id, s.status, s.lessons_total, s.lesson_price_tiyin,
      s.price_tiyin, s.starts_at, s.ends_at,
      coalesce(t.period_days, greatest(s.ends_at - s.starts_at, 1)) as total_days,
      -- Незакрытая заморозка не сдвинула ends_at (Р1) — её дни, ещё не
      -- отражённые там, добавляются к остатку явно. greatest(0,...): если
      -- заморозка ещё не началась (lower(period) в будущем), это 0, не минус.
      coalesce((
        select greatest(0, public.center_today(s.center_id) - lower(f.period))
          from public.subscription_freezes f
         where f.subscription_id = s.id
           and upper_inf(f.period)
         limit 1
      ), 0) as open_freeze_days
    from public.subscriptions s
    left join public.subscription_types t on t.id = s.type_id
    where s.id = p_id
  )
  select case
    -- Р5: после отмены возврат не течёт дальше ни для одного kind.
    when sub.status = 'cancelled' then 0
    -- lessons/unlimited-без-срока (ends_at null) — как раньше: стоимость
    -- неотработанных занятий. lessons_total is not null покрывает lessons;
    -- ends_at is null отсекает unlimited без периода (см. Р4 — unlimited
    -- С периодом ниже, в else, наравне с period).
    when sub.lessons_total is not null or sub.ends_at is null then
      -- 0089 (Р3): перерасход не даёт отрицательного «к возврату» — как
      -- refundAmount в packages/core.
      greatest(coalesce(public.subscription_lessons_left(p_id), 0), 0) * coalesce(sub.lesson_price_tiyin, 0)
    -- period (или unlimited с ends_at, Р4) — пропорционально дням, что
    -- останутся до ends_at от сегодня центра, плюс дни ЕЩЁ не закрытой
    -- заморозки (Р1), от знаменателя period_days типа (Р3), не ends_at-
    -- starts_at. bigint — иначе int4 переполняется на реалистичных цифрах
    -- (Р6): 60 000 сом * 365 дней = 21 900 000 000 > 2^31.
    else
      (
        sub.price_tiyin::bigint
        * greatest(0, least(
            (sub.ends_at - public.center_today(sub.center_id)) + sub.open_freeze_days,
            sub.total_days
          ))
        / sub.total_days
      )::integer
  end
  from sub;
$$;


revoke all on function public.refund_calc_unchecked(uuid) from public, anon, authenticated, service_role;
