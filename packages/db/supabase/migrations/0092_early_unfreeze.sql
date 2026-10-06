-- =============================================================================
-- 0092_early_unfreeze.sql — разморозить раньше срока
--
-- Решение владельца 6.10.2026 (случай на prod: абонемент заморожен «с первого
-- дня по 24.10», кнопки «Разморозить» нет — продуктовое решение 2 из 0015
-- запрещало снимать датированную заморозку раньше срока). Решение 2 отменено.
--
--   Р1. unfreeze_subscription находит и датированную заморозку, которая уже
--       идёт (upper > сегодня), и заканчивает её сегодня или прошлым числом,
--       как бессрочную. Ещё не начавшуюся — по-прежнему отменяет целиком.
--       Сжатие диапазона проходит guard_backdate (new <@ old), срок
--       абонемента на период пересчитывает триггер subscription_freezes_shift
--       (0008) — отдельной правки ends_at не нужно.
--   Р2. Конец прошлым числом: отметки, ушедшие в долг в дни заморозки, не
--       переподбираются (0015 решение 3) — их закрывает «Покрыть неоплаченные
--       занятия» (0088).
--   Р3. Проверка сессии и центра — первой строкой (тело 0026 её не имело).
--
-- Известное: занятие, отмеченное в долг сегодня до разморозки, остаётся долгом
-- (конец заморозки — исключающая граница «сегодня»); его закрывает 0088.
-- =============================================================================


-- 1. unfreeze_subscription — тело 0026 плюс Р1, Р3 ---------------------------------------------

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
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Почему так — 0015, раздел 6: блокировка абонемента; «открытая» —
  -- бессрочная, ещё не начавшаяся (её «разморозить» = отменить целиком,
  -- схлопнуть в пустой диапазон) и с 0092 датированная, ещё идущая;
  -- разморозить можно только сегодняшним или прошлым числом.
  perform 1 from public.subscriptions
   where id = p_id and center_id = v_center and deleted_at is null
     for update;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  select * into v_open from public.subscription_freezes f
   where f.subscription_id = p_id and f.center_id = v_center
     -- 0092 (Р1): и датированная, ещё идущая (конец после сегодня).
     and not isempty(f.period)
     and (upper_inf(f.period) or upper(f.period) > public.center_today(v_center))
   order by lower(f.period) desc limit 1;
  if not found then
    raise exception 'У абонемента нет открытой заморозки' using errcode = '42704';
  end if;

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
  if v_to > public.center_today(v_center) then
    raise exception '%', case when upper_inf(v_open.period)
        then 'Разморозить можно только сегодняшним или прошлым числом — для будущей даты укажите срок при заморозке'
        else 'Разморозить можно только сегодняшним или прошлым числом — срок заморозки уже задан' end
      using errcode = '22023';
  end if;

  update public.subscription_freezes
     set period = daterange(lower(v_open.period), v_to, '[)')
   where id = v_open.id;

  perform public.emit_event('subscription.unfrozen',
    jsonb_build_object('center_id', v_center, 'subscription_id', p_id, 'to', v_to), v_center);
end;
$$;

comment on function public.unfreeze_subscription(uuid, date) is
  'Разморозить (0015; 0092 — и датированную, уже идущую): ещё не начавшуюся заморозку отменяет целиком, идущую заканчивает сегодня или прошлым числом.';

revoke all on function public.unfreeze_subscription(uuid, date) from public, anon;
grant execute on function public.unfreeze_subscription(uuid, date) to authenticated;
