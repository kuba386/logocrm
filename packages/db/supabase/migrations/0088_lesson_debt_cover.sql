-- =============================================================================
-- 0088_lesson_debt_cover.sql — абонемент покрывает неоплаченные занятия
--
-- Часть B этапа 10 (docs/Roadmap/stages.md). 0087 дала гасить долг за занятия
-- деньгами и списанием; здесь — абонементом. Решения владельца 5.10.2026:
-- покрыть можно только абонементом этого же ребёнка, пакетом занятий (не
-- безлимит, не «на срок»), той же услуги; перерасход — как долг.
--
-- Решения:
--   Р1. История отметок не переписывается. Покрытие — строка
--       lesson_debt_covers(attendance_id → subscription_id): закрытые месяцы,
--       утверждённая зарплата (calc_salary читает отметку) и выручка
--       (revenue_facts — цена услуги в месяце занятия) не меняются. Занятия
--       абонемента, ушедшие на покрытие, второй строки выручки не дают.
--   Р2. Покрытое занятие входит в lessons_used абонемента через
--       recalc_subscription_usage, а не через subscription_lessons_left: тот
--       же счётчик читают CHECK subscriptions_not_overdrawn, subscription_state,
--       выбор абонемента при отметке, refund_calc и transfer_remaining. В
--       счёте занятий (0087) покрытая отметка не начисляется.
--   Р3. Покрытие ЗАКРЫВАЕТСЯ само (deleted_at, closed_reason), а не «гаснет по
--       условию»: как только отметка перестала быть долговой («пришёл →
--       болел», ей нашёлся абонемент, занятие отменено/удалено). Архив
--       абонемента покрытие НЕ закрывает: в архив уходит отменённый (возврат,
--       перенос уже посчитаны с покрытием) или исчерпанный абонемент, и
--       занятия, которые он оплатил, остаются оплаченными. Ошибочное покрытие
--       снимают uncover_lesson_debt до возврата и архива. Обратного хода нет — вернули «пришёл», это снова долг, его
--       покрывают заново. Иначе покрытие «оживало» поверх уже потраченного
--       места: CHECK отбивал бы правку посещения, а при allow_negative —
--       тихий перерасход; отметка считалась бы в абонементе дважды.
--   Р4. Блокировки в одном порядке до первой вставки: ребёнок
--       (lesson_debt_lock) → занятия for share → отметки for update →
--       абонемент for update. Тот же порядок у триггера вставки (повторный
--       захват в своей транзакции бесплатен). Иначе покрытие и параллельная
--       правка статуса/отмена занятия сходились бы в deadlock, а проверка
--       места без блокировки абонемента пропускала бы гонку с отметкой.
--   Р5. Граница «есть что гасить» — remaining_tiyin (долг + перерасход), не
--       debt_tiyin: деньги в 0087 распределяются суммой, и покрытие уже
--       оплаченной отметки при живом перерасходе честно гасит перерасход — это
--       и есть «перерасход как долг» без переноса отметок между абонементами.
--       При remaining = 0 — отказ (иначе аванс из ничего). Отметки с нулевой
--       ценой не покрываются: заняли бы место абонемента, не сняв ни тыйына.
--       Покрываются самые
--       старые подходящие отметки по одной, пока перед очередной remaining > 0;
--       последняя может перекрыть долг — разница уходит в аванс, предпросмотр
--       показывает это заранее (credit_after_tiyin).
--   Р6. Свободное место — lessons_total − lessons_used − written_off ≥ 1
--       НЕЗАВИСИМО от allow_negative; абонемент только в состоянии active
--       (не frozen, не expired, не cancelled — решение по аналогии с продажей).
--       «Тот же ребёнок» — констрейнтами: FK (attendance_id, student_id,
--       center_id) и (subscription_id, student_id, center_id).
--   Р7. Права — can_front_desk (owner/admin/registrar), как у продажи,
--       переноса и возврата: покрытие тратит занятия абонемента. Снять
--       покрытие нельзя у отменённого или удалённого абонемента: возврат и
--       перенос уже посчитаны с ним.
--   Р8. Отбор подходящих отметок — одна внутренняя функция
--       lesson_debt_cover_plan: её читают и RPC, и предпросмотр — браузер
--       ничего не считает, а два места не разойдутся. RPC строит план дважды:
--       до блокировок (чтобы знать, что блокировать) и после — разошлись,
--       значит отметку поменяли параллельно: 23514 «данные изменились», а не
--       окончательный по виду отказ триггера.
--
-- Известное ограничение: cancel_series_from отменяет занятия одним UPDATE в
-- порядке скана, а RPC берёт их for share в порядке id — одновременные отмена
-- серии и покрытие у одного ребёнка могут сойтись в deadlock (40P01). Одна из
-- транзакций откатывается целиком, errors.ts переводит это в «повторите».
-- Смена услуги у занятия покрытие не закрывает: правило услуги — граница
-- вставки, как у выбора абонемента при отметке.
--
-- Не здесь (отдельной миграцией): прямой перенос отметок перерасходованного
-- абонемента на новый (меняет recalc старого, его state и refund_calc).
-- Чистый перерасход без долговых отметок до этого гасится оплатой/списанием.
-- =============================================================================


-- 1. Ключ «отметка того же ребёнка» (Р6) -----------------------------------------------------------

alter table public.attendance drop constraint if exists attendance_id_student_center_key;
alter table public.attendance add constraint attendance_id_student_center_key unique (id, student_id, center_id);


-- 2. Покрытия --------------------------------------------------------------------------------------

create table if not exists public.lesson_debt_covers (
  id              uuid primary key default gen_random_uuid(),
  center_id       uuid not null default public.current_center()
                    references public.centers (id) on delete cascade,
  attendance_id   uuid not null,
  subscription_id uuid not null,
  student_id      uuid not null,
  -- Снимок цены отметки на момент покрытия — для события и аудита. В расчёт не
  -- идёт: счёт занятий берёт цену из самой отметки.
  price_tiyin     integer not null check (price_tiyin >= 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),
  deleted_at      timestamptz,
  closed_reason   text check (closed_reason in ('manual', 'attendance_changed', 'lesson_cancelled')),
  closed_by       uuid,

  constraint lesson_debt_covers_closed_shape check ((deleted_at is null) = (closed_reason is null)),
  constraint lesson_debt_covers_attendance_fk
    foreign key (attendance_id, student_id, center_id)
    references public.attendance (id, student_id, center_id),
  constraint lesson_debt_covers_subscription_fk
    foreign key (subscription_id, student_id, center_id)
    references public.subscriptions (id, student_id, center_id)
);
comment on table public.lesson_debt_covers is
  'Неоплаченная отметка, покрытая абонементом (0088): занятие списано с абонемента, долг снят, история отметок не тронута. Пишут только RPC cover/uncover и триггеры закрытия; deleted_at + closed_reason — закрыто.';

-- Одна отметка — одно живое покрытие (инвариант). FK покрыты непартиальными
-- индексами: частичный покрытием не засчитывается (урок 0069).
create unique index if not exists lesson_debt_covers_attendance_live_key
  on public.lesson_debt_covers (attendance_id) where deleted_at is null;
create index if not exists lesson_debt_covers_attendance_idx
  on public.lesson_debt_covers (attendance_id, student_id, center_id);
create index if not exists lesson_debt_covers_subscription_idx
  on public.lesson_debt_covers (subscription_id, student_id, center_id);
create index if not exists lesson_debt_covers_student_idx
  on public.lesson_debt_covers (center_id, student_id);

drop trigger if exists lesson_debt_covers_set_updated_at on public.lesson_debt_covers;
create trigger lesson_debt_covers_set_updated_at
  before update on public.lesson_debt_covers
  for each row execute function extensions.moddatetime(updated_at);

alter table public.lesson_debt_covers enable row level security;

drop policy if exists lesson_debt_covers_select on public.lesson_debt_covers;
create policy lesson_debt_covers_select on public.lesson_debt_covers
  for select to authenticated
  using (center_id = public.current_center() and public.can_payments());

revoke all on table public.lesson_debt_covers from public, anon, authenticated, service_role;
grant select on public.lesson_debt_covers to authenticated;

call public.apply_audit('lesson_debt_covers');
call public.apply_readonly_guard('lesson_debt_covers');


-- 3. Счёт абонемента: отметки + живые покрытия (Р2) — тело 0009 плюс покрытия ----------------------

create or replace function public.recalc_subscription_usage(p_subscription_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_used integer;
begin
  if p_subscription_id is null then
    return;
  end if;

  perform 1 from public.subscriptions where id = p_subscription_id for update;
  if not found then
    return;
  end if;

  select
    (select count(*)
       from public.attendance a
       join public.lessons l on l.id = a.lesson_id
      where a.subscription_id = p_subscription_id
        and a.deducted
        and l.deleted_at is null
        and l.status <> 'cancelled')
    +
    -- Р3: закрытие держит инвариант, условия по отметке — вторая линия защиты.
    (select count(*)
       from public.lesson_debt_covers c
       join public.attendance a on a.id = c.attendance_id
       join public.lessons l on l.id = a.lesson_id
      where c.subscription_id = p_subscription_id
        and c.deleted_at is null
        and a.deducted
        and a.subscription_id is null
        and l.deleted_at is null
        and l.status <> 'cancelled')
    into v_used;

  update public.subscriptions set lessons_used = v_used where id = p_subscription_id;
end;
$$;
comment on function public.recalc_subscription_usage(uuid) is
  'lessons_used = отметки абонемента у живых занятий + живые покрытия долга этим абонементом (0088 Р2).';

revoke all on function public.recalc_subscription_usage(uuid) from public, anon, authenticated, service_role;


-- 4. Счёт занятий (0087) — покрытая отметка не начисляется -----------------------------------------

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
       and s.deleted_at is null
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
  'Счёт занятий детей центра (0087 Р2): начислено (отметки без абонемента у живых занятий, кроме покрытых абонементом — 0088), валовой перерасход по всем пакетам, оплачено (только covers_lesson_debt), списано → долг, перерасход, аванс, остаток. Без проверки сессии — для триггеров и обёрток; грантов нет.';

revoke all on function public.lesson_debt_accounts_unchecked(uuid, uuid) from public, anon, authenticated, service_role;



-- 5. План покрытия — одна функция для RPC и предпросмотра (Р5, Р8) ---------------------------------

create or replace function public.lesson_debt_cover_plan(p_subscription_id uuid)
  returns table (attendance_id uuid, lesson_id uuid, price_tiyin integer)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_sub       public.subscriptions;
  v_free      integer;
  v_remaining bigint;
  r           record;
begin
  select * into v_sub from public.subscriptions s where s.id = p_subscription_id;
  if not found
     or v_sub.deleted_at is not null
     or v_sub.lessons_total is null
     or public.subscription_state_unchecked(v_sub.id) <> 'active' then
    return;
  end if;

  v_free := v_sub.lessons_total - v_sub.lessons_used - v_sub.lessons_written_off;
  select coalesce(max(x.remaining_tiyin), 0) into v_remaining
    from public.lesson_debt_accounts_unchecked(v_sub.center_id, v_sub.student_id) x;

  for r in
    select a.id as attendance_id, a.lesson_id, a.price_tiyin
      from public.attendance a
      join public.lessons l on l.id = a.lesson_id
     where a.student_id = v_sub.student_id
       and a.center_id = v_sub.center_id
       and a.subscription_id is null
       and a.deducted
       and a.price_tiyin > 0
       and l.deleted_at is null
       and l.status <> 'cancelled'
       -- Правило услуги — дословно из attendance_fill_and_check (0055).
       and (v_sub.type_id is null
            or exists (select 1 from public.subscription_types t
                        where t.id = v_sub.type_id
                          and (t.service_id is null or t.service_id = l.service_id)))
       and not exists (select 1 from public.lesson_debt_covers c
                        where c.attendance_id = a.id and c.deleted_at is null)
     order by l.starts_at, a.id
  loop
    exit when v_free <= 0 or v_remaining <= 0;
    attendance_id := r.attendance_id;
    lesson_id := r.lesson_id;
    price_tiyin := r.price_tiyin;
    return next;
    v_free := v_free - 1;
    v_remaining := v_remaining - r.price_tiyin;
  end loop;
end;
$$;
comment on function public.lesson_debt_cover_plan(uuid) is
  'Отметки, которые этот абонемент может покрыть сейчас, по порядку (0088 Р5/Р8): долговые, непокрытые, у живых занятий, той же услуги; пока есть место и перед очередной есть остаток долга. Без проверки сессии; грантов нет.';

revoke all on function public.lesson_debt_cover_plan(uuid) from public, anon, authenticated, service_role;


-- 6. Триггеры покрытия (Р3, Р4, Р6) ----------------------------------------------------------------

create or replace function public.lesson_debt_covers_guard()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_att       public.attendance;
  v_lesson    public.lessons;
  v_sub       public.subscriptions;
  v_remaining integer;
begin
  -- Р4: тот же порядок, что в cover_lesson_debt.
  perform public.lesson_debt_lock(new.student_id);
  select * into v_lesson from public.lessons l
   where l.id = (select a.lesson_id from public.attendance a where a.id = new.attendance_id)
   for share;
  select * into v_att from public.attendance a where a.id = new.attendance_id for update;
  select * into v_sub from public.subscriptions s where s.id = new.subscription_id for update;

  if v_att.id is null or v_att.student_id <> new.student_id or v_att.center_id <> new.center_id then
    raise exception 'Отметка не найдена' using errcode = '42704';
  end if;
  if not v_att.deducted or v_att.subscription_id is not null or v_att.price_tiyin <= 0
     or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
    raise exception 'Покрыть можно только неоплаченное занятие без абонемента' using errcode = '22023';
  end if;
  if v_sub.id is null or v_sub.deleted_at is not null or v_sub.lessons_total is null
     or public.subscription_state_unchecked(v_sub.id) <> 'active' then
    raise exception 'Покрыть долг можно только действующим пакетом занятий' using errcode = '22023';
  end if;
  if v_sub.type_id is not null and not exists (
       select 1 from public.subscription_types t
        where t.id = v_sub.type_id and (t.service_id is null or t.service_id = v_lesson.service_id)) then
    raise exception 'Абонемент на другую услугу — им это занятие не покрыть' using errcode = '22023';
  end if;
  if v_sub.lessons_total - v_sub.lessons_used - v_sub.lessons_written_off < 1 then
    raise exception 'В абонементе не осталось свободных занятий' using errcode = '22023';
  end if;

  select coalesce(max(x.remaining_tiyin), 0) into v_remaining
    from public.lesson_debt_accounts_unchecked(new.center_id, new.student_id) x;
  if v_remaining <= 0 then
    raise exception 'Долга нет — покрывать нечего' using errcode = '22023';
  end if;

  new.price_tiyin := v_att.price_tiyin;
  return new;
end;
$$;
comment on function public.lesson_debt_covers_guard() is
  'Граница 0088 при вставке покрытия: долговая отметка у живого занятия, действующий пакет того же ребёнка и услуги, свободное место ≥ 1 при любом allow_negative, остаток долга > 0. Под блокировками в порядке Р4.';
revoke all on function public.lesson_debt_covers_guard() from public, anon, authenticated, service_role;

drop trigger if exists lesson_debt_covers_guard on public.lesson_debt_covers;
create trigger lesson_debt_covers_guard
  before insert on public.lesson_debt_covers
  for each row execute function public.lesson_debt_covers_guard();


-- Изменение покрытия — только закрытие; повторно открыть нельзя (Р3).
create or replace function public.lesson_debt_covers_close_only()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.id <> old.id or new.center_id <> old.center_id or new.attendance_id <> old.attendance_id
     or new.subscription_id <> old.subscription_id or new.student_id <> old.student_id
     or new.price_tiyin <> old.price_tiyin or new.created_at <> old.created_at
     or new.created_by is distinct from old.created_by then
    raise exception 'Покрытие нельзя изменить — только закрыть' using errcode = '22023';
  end if;
  if old.deleted_at is not null then
    raise exception 'Покрытие уже закрыто' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function public.lesson_debt_covers_close_only() from public, anon, authenticated, service_role;

drop trigger if exists lesson_debt_covers_close_only on public.lesson_debt_covers;
create trigger lesson_debt_covers_close_only
  before update on public.lesson_debt_covers
  for each row execute function public.lesson_debt_covers_close_only();


create or replace function public.lesson_debt_covers_recalc()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform public.recalc_subscription_usage(new.subscription_id);
  return null;
end;
$$;
revoke all on function public.lesson_debt_covers_recalc() from public, anon, authenticated, service_role;

drop trigger if exists lesson_debt_covers_recalc on public.lesson_debt_covers;
create trigger lesson_debt_covers_recalc
  after insert or update of deleted_at on public.lesson_debt_covers
  for each row execute function public.lesson_debt_covers_recalc();


-- 7. Закрытие покрытия, когда отметка перестала быть долговой (Р3) ----------------------------------

-- Отдельный триггер, а не правка attendance_recalc_trigger (0071): там
-- дедупликация событий, и правка v_material размножила бы их.
create or replace function public.attendance_close_covers()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if not new.deducted
     or new.subscription_id is not null
     or new.lesson_id is distinct from old.lesson_id
     or new.student_id is distinct from old.student_id then
    update public.lesson_debt_covers c
       set deleted_at = now(), closed_reason = 'attendance_changed', closed_by = auth.uid()
     where c.attendance_id = new.id and c.deleted_at is null;
  end if;
  return null;
end;
$$;
revoke all on function public.attendance_close_covers() from public, anon, authenticated, service_role;

drop trigger if exists attendance_close_covers on public.attendance;
create trigger attendance_close_covers
  after update on public.attendance
  for each row execute function public.attendance_close_covers();


-- Отмена/удаление занятия — statement-level, один проход на стейтмент, порядок
-- по id покрытия (урок 0010: cancel_series_from на двадцать занятий).
create or replace function public.lessons_close_covers()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_cover uuid;
begin
  for v_cover in
    select c.id
      from next_rows n
      join prev_rows p on p.id = n.id
      join public.attendance a on a.lesson_id = n.id
      join public.lesson_debt_covers c on c.attendance_id = a.id and c.deleted_at is null
     where (n.status = 'cancelled' and p.status is distinct from 'cancelled')
        or (n.deleted_at is not null and p.deleted_at is null)
     order by c.id
  loop
    update public.lesson_debt_covers
       set deleted_at = now(), closed_reason = 'lesson_cancelled', closed_by = auth.uid()
     where id = v_cover and deleted_at is null;
  end loop;
  return null;
end;
$$;
revoke all on function public.lessons_close_covers() from public, anon, authenticated, service_role;

drop trigger if exists lessons_close_covers on public.lessons;
create trigger lessons_close_covers
  after update on public.lessons
  referencing old table as prev_rows new table as next_rows
  for each statement execute function public.lessons_close_covers();


-- Архив абонемента покрытия не закрывает (Р3); триггера на subscriptions нет.


-- 8. RPC ------------------------------------------------------------------------------------------

create or replace function public.cover_lesson_debt_preview(p_subscription_id uuid)
  returns table (
    debt_lessons_count integer,
    can_cover          integer,
    amount_tiyin       integer,
    remaining_tiyin    integer,
    credit_after_tiyin integer
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_sub    public.subscriptions;
  v_acc    record;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  select * into v_sub from public.subscriptions s where s.id = p_subscription_id and s.center_id = v_center;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  select * into v_acc from public.lesson_debt_accounts_unchecked(v_center, v_sub.student_id) x;

  return query
    with plan as (select * from public.lesson_debt_cover_plan(p_subscription_id))
    select
      (select count(*)::integer
         from public.attendance a
         join public.lessons l on l.id = a.lesson_id
        where a.student_id = v_sub.student_id and a.center_id = v_center
          and a.subscription_id is null and a.deducted and a.price_tiyin > 0
          and l.deleted_at is null and l.status <> 'cancelled'
          and not exists (select 1 from public.lesson_debt_covers c
                           where c.attendance_id = a.id and c.deleted_at is null)),
      (select count(*)::integer from plan),
      (select coalesce(sum(p.price_tiyin), 0)::integer from plan p),
      coalesce(v_acc.remaining_tiyin, 0),
      greatest(coalesce(v_acc.paid_tiyin, 0)
               - (coalesce(v_acc.accrued_tiyin, 0) - (select coalesce(sum(p.price_tiyin), 0) from plan p)
                  + coalesce(v_acc.overdrawn_gross_tiyin, 0)), 0)::integer;
end;
$$;
comment on function public.cover_lesson_debt_preview(uuid) is
  'Сколько неоплаченных занятий этот абонемент может покрыть сейчас и на какую сумму, остаток долга и аванс после покрытия (0088). can_front_desk; числа браузер не считает.';

revoke all on function public.cover_lesson_debt_preview(uuid) from public, anon;
grant execute on function public.cover_lesson_debt_preview(uuid) to authenticated;


create or replace function public.cover_lesson_debt(
  p_subscription_id          uuid,
  p_count                    integer,
  p_expected_remaining_tiyin integer
)
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center    uuid := public.current_center();
  v_sub       public.subscriptions;
  v_remaining integer;
  v_plan      uuid[];
  v_check     uuid[];
  v_lessons   uuid[];
  v_amount    integer;
  v_left      integer;
  v_left_was  integer;
  v_id        uuid;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if p_count is null or p_count < 1 then
    raise exception 'Укажите, сколько занятий покрыть' using errcode = '22023';
  end if;

  select * into v_sub from public.subscriptions s where s.id = p_subscription_id and s.center_id = v_center;
  if not found then
    raise exception 'Абонемент не найден' using errcode = '42704';
  end if;

  -- Р4: ребёнок → занятия → отметки → абонемент, до первой вставки.
  perform public.lesson_debt_lock(v_sub.student_id);

  select coalesce(max(x.remaining_tiyin), 0) into v_remaining
    from public.lesson_debt_accounts_unchecked(v_center, v_sub.student_id) x;
  if p_expected_remaining_tiyin is distinct from v_remaining then
    raise exception 'Долг изменился, пока открывали форму: сейчас %. Проверьте и повторите.', public.format_som(v_remaining)
      using errcode = '23514';
  end if;

  select array_agg(p.attendance_id order by o), array_agg(p.lesson_id order by o)
    into v_plan, v_lessons
    from public.lesson_debt_cover_plan(p_subscription_id) with ordinality as p(attendance_id, lesson_id, price_tiyin, o);
  if coalesce(array_length(v_plan, 1), 0) < p_count then
    raise exception 'Покрыть можно не больше % занятий', coalesce(array_length(v_plan, 1), 0) using errcode = '22023';
  end if;
  v_plan := v_plan[1:p_count];
  v_lessons := v_lessons[1:p_count];

  perform 1 from public.lessons l where l.id = any (v_lessons) order by l.id for share;
  perform 1 from public.attendance a where a.id = any (v_plan) order by a.id for update;
  select * into v_sub from public.subscriptions s where s.id = p_subscription_id for update;

  -- Р8: под блокировками план тот же? Иначе отметку/место поменяли параллельно.
  select array_agg(p.attendance_id order by o) into v_check
    from public.lesson_debt_cover_plan(p_subscription_id) with ordinality as p(attendance_id, lesson_id, price_tiyin, o);
  if coalesce(v_check[1:p_count], '{}') is distinct from v_plan then
    raise exception 'Данные изменились, пока готовили покрытие. Откройте форму заново.' using errcode = '23514';
  end if;
  v_left_was := public.subscription_lessons_left(p_subscription_id);

  foreach v_id in array v_plan loop
    insert into public.lesson_debt_covers (center_id, attendance_id, subscription_id, student_id, price_tiyin)
    values (v_center, v_id, p_subscription_id, v_sub.student_id, 0);
  end loop;

  select coalesce(sum(c.price_tiyin), 0)::integer into v_amount
    from public.lesson_debt_covers c
   where c.attendance_id = any (v_plan) and c.deleted_at is null;
  v_left := public.subscription_lessons_left(p_subscription_id);

  perform public.emit_event('lesson_debt.covered', jsonb_build_object('center_id', v_center, 'subscription_id', p_subscription_id, 'student_id', v_sub.student_id, 'lessons', p_count, 'amount_tiyin', v_amount), v_center);

  -- Пороги остатка — как при отметке (0071): один раз на абонемент.
  if v_left_was > 2 and v_left <= 2 and v_left > 0 and not exists (
       select 1 from public.events e
        where e.type = 'subscription.low_balance'
          and e.payload ->> 'subscription_id' = p_subscription_id::text) then
    perform public.emit_event('subscription.low_balance', jsonb_build_object('center_id', v_center, 'subscription_id', p_subscription_id, 'student_id', v_sub.student_id, 'lessons_left', v_left), v_center);
  elsif v_left = 0 and not exists (
       select 1 from public.events e
        where e.type = 'subscription.exhausted'
          and e.payload ->> 'subscription_id' = p_subscription_id::text) then
    perform public.emit_event('subscription.exhausted', jsonb_build_object('center_id', v_center, 'subscription_id', p_subscription_id, 'student_id', v_sub.student_id), v_center);
  end if;

  return p_count;
end;
$$;
comment on function public.cover_lesson_debt(uuid, integer, integer) is
  'Покрыть p_count самых старых неоплаченных занятий абонементом (0088): can_front_desk, блокировки в порядке Р4, сверка p_expected_remaining_tiyin (23514), не больше плана (22023); событие lesson_debt.covered и пороги остатка.';

revoke all on function public.cover_lesson_debt(uuid, integer, integer) from public, anon;
grant execute on function public.cover_lesson_debt(uuid, integer, integer) to authenticated;


create or replace function public.uncover_lesson_debt(p_cover_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_cover  public.lesson_debt_covers;
  v_sub    public.subscriptions;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if not public.can_front_desk() then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_cover from public.lesson_debt_covers c where c.id = p_cover_id and c.center_id = v_center;
  if not found then
    raise exception 'Покрытие не найдено' using errcode = '42704';
  end if;

  perform public.lesson_debt_lock(v_cover.student_id);
  select * into v_sub from public.subscriptions s where s.id = v_cover.subscription_id for update;

  if v_cover.deleted_at is not null then
    raise exception 'Покрытие уже снято' using errcode = '22023';
  end if;
  if v_sub.deleted_at is not null or v_sub.status = 'cancelled' then
    raise exception 'Абонемент отменён или удалён — возврат и перенос уже посчитаны с этим покрытием' using errcode = '22023';
  end if;

  -- Событие не шлём: снятие — исправление ошибки стойки, след — в audit_log.
  update public.lesson_debt_covers
     set deleted_at = now(), closed_reason = 'manual', closed_by = auth.uid()
   where id = p_cover_id;
end;
$$;
comment on function public.uncover_lesson_debt(uuid) is
  'Снять ошибочное покрытие (0088 Р7): can_front_desk; нельзя у отменённого/удалённого абонемента. Долг возвращается, занятие — абонементу.';

revoke all on function public.uncover_lesson_debt(uuid) from public, anon;
grant execute on function public.uncover_lesson_debt(uuid) to authenticated;


-- 9. Экспорт центра — allow-list 0087 плюс покрытия ------------------------------------------------

create or replace function public.export_center_tables()
  returns table (table_name text)
  language sql
  immutable
  set search_path = ''
as $$
  values
    ('attendance'), ('attendance_statuses'), ('booking_requests'), ('diagnostic_clinical_forms'),
    ('diagnostic_referrals'), ('diagnostics'), ('exercise_library'),
    ('expense_categories'), ('expenses'), ('financial_periods'), ('funnel_events'),
    ('goal_progress'), ('goal_stages'), ('goals'), ('group_students'), ('groups'),
    ('homework'), ('homework_exercises'), ('installment_plans'), ('installments'),
    ('lesson_debt_covers'), ('lesson_debt_writeoffs'),
    ('lesson_note_goal_scores'), ('lesson_notes'), ('lesson_participants'), ('lessons'),
    ('memberships'), ('message_templates'), ('monthly_reports'), ('payers'),
    ('payment_sources'), ('payments'), ('platform_payments'), ('prosody_assessments'),
    ('reading_writing_assessments'), ('rooms'),
    ('salary_adjustments'), ('salary_runs'), ('services'), ('student_anamnesis'),
    ('student_articulation'), ('student_payers'), ('students'), ('subscription_freezes'),
    ('subscription_types'), ('subscriptions'), ('syllable_assessments'), ('teacher_rates'), ('teachers')
$$;
comment on function public.export_center_tables() is
  'Явный allow-list export_center_table() (0056 Р1) — НЕ «каталог минус deny». 0057: booking_requests. 0059: diagnostic_clinical_forms/diagnostic_referrals. 0063: student_anamnesis. 0065: student_articulation. 0066: syllable_assessments. 0067: prosody_assessments. 0068: reading_writing_assessments. 0087: lesson_debt_writeoffs. 0088: lesson_debt_covers. Забор pgTAP: (allow ∪ export_center_excluded_tables()) = все базовые таблицы public с center_id.';

revoke all on function public.export_center_tables() from public, anon, service_role;
grant execute on function public.export_center_tables() to authenticated;
