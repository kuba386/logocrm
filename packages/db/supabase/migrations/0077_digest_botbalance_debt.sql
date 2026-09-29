-- =============================================================================
-- 0077_digest_botbalance_debt.sql — {debt} утренней сводки и /balance в боте
-- считают долг по общему определению «должника» (0076)
--
-- Хвост 0076 Р4: два места считали долг по-старому. {debt} сводки (daily_digest,
-- 0032) — только неоплаченные списания без абонемента, без перерасхода и
-- просрочки; bot_balance (0033, до 0070) — свой подбор абонемента и свой
-- подзапрос по attendance. Родитель видел в боте одну сумму, администратор в
-- сводке другую, экран /app/debts третью. CLAUDE.md: SQL — источник истины,
-- определение одно.
--
-- Ревью плана — architect (вариант А: подмена claims в обёртках, как 0072/0076;
-- вариант Б — дублировать формулу в двух функциях — дороже). Учтено:
--   Р1. Сбой расчёта не ломает сводку. Расчёт вынесен в digest_debt_text с
--       блоком exception: ошибка подмены внутри event_messages уронила бы
--       доставку всей сводки (получатели, {payments}). При сбое {debt} =
--       «не удалось посчитать — см. /debts»: не пустая строка и не «0,00 сом» —
--       ноль читался бы как «долгов нет».
--   Р2. Пользователь для подмены — детерминированно: из memberships центра
--       events.center_id, owner раньше admin, затем по user_id. Центр — только
--       из events.center_id, не из payload (0073 Р7).
--   Р3. bot_balance_center (как bot_debts_center 0072): SECURITY INVOKER, без
--       грантов ни у кого; роль (parent, payer_id не null, центр не удалён)
--       проверяется по memberships ДО подмены; после подмены самопроверка
--       coalesce(auth.uid() = p_user and current_center() = p_center and
--       my_role() = 'parent' and my_payer_id() = <payer>, false) — не
--       can_payments(): у родителя его нет; единственный выход восстанавливает
--       claims, raise — после отката. Ребёнок видим только через students_brief()
--       (граница центра и плательщика — там; проверяется pgTAP «второй центр»).
--   Р4. daily_digest НЕ переиздан: payload.debt_tiyin по-прежнему пишется, но
--       больше не читается — событие может лежать в очереди со старой цифрой.
--   Р5. event_messages переиздана побайтово от 0073; изменена только ветка
--       digest.daily (переменная v_debt_text и значение 'debt'). preview_message —
--       только образец {debt}. Шаблоны и плейсхолдеры не менялись.
--   Р6. Просрочка по абонементам — внутри {debt}: «700,00 сом; просрочка по
--       абонементам — 1200,00 сом», суммы не складываются (0076 Р3). Новый
--       плейсхолдер не заводился: у владельцев уже сохранены шаблоны.
--   Р7. bot_balance: отказ при chat_id <= 0 (группа — не личная переписка, как
--       0072 Р12).
--   Р8. Набор колонок bot_balance меняется (debt_tiyin теперь bigint и включает
--       перерасход; добавлена overdue_tiyin) — drop + create и явные гранты.
--
-- Записано, не чинится (Р11): смена плательщика ребёнка (0060) — родитель со
-- старым payer_id перестаёт видеть ребёнка сразу, через students_brief().
-- {debt} берётся на момент доставки, а не на дату сводки (Р12).
-- Р12а. В одной строке сводки рядом стоят «просрочка по абонементам» (в {debt}, по
-- 0070 абонемент без плана рассрочки просрочен сразу) и «просроченных рассрочек»
-- ({overdue} из payload, только планы рассрочки): цифры могут выглядеть
-- противоречиво. {overdue} и {low} — на момент создания события. Осознанно не
-- меняется в 0077 (шаблоны владельцев уже сохранены); решение по тексту — за владельцем.
-- Р12б. Сбой расчёта {debt} оставляет только raise warning в логе сервера; повторяющийся
-- сбой будет каждое утро давать «не удалось посчитать — см. /debts» без следа в журнале.
--
-- Таблиц нет — deny-list экспорта не затрагивается.
-- =============================================================================


-- 1. bot_balance_center: баланс детей родителя под подменённой сессией ------------------

create function public.bot_balance_center(p_user uuid, p_center uuid)
  returns table (
    student_id       uuid,
    full_name        text,
    has_subscription boolean,
    lessons_left     integer,
    debt_tiyin       bigint,
    overdue_tiyin    bigint
  )
  language plpgsql
  set search_path = ''
as $$
declare
  v_payer uuid;
  v_prev  text;
  v_ok    boolean;
begin
  -- Проверка ДО подмены, по memberships: вне роли parent помощник не подменяет
  -- ничего (единственный ранний return — до set_config).
  select m.payer_id into v_payer
    from public.memberships m
    join public.centers c on c.id = m.center_id and c.deleted_at is null
   where m.user_id = p_user and m.center_id = p_center
     and m.role = 'parent' and m.payer_id is not null;
  if v_payer is null then
    return;
  end if;

  v_prev := coalesce(current_setting('request.jwt.claims', true), '');

  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);

  -- coalesce обязателен: `null and …` — NULL, и провал подмены прошёл бы мимо raise.
  v_ok := coalesce(auth.uid() = p_user
                   and public.current_center() = p_center
                   and public.my_role() = 'parent'
                   and public.my_payer_id() = v_payer, false);

  if v_ok then
    return query
      select s.id,
             s.full_name,
             b.active_subscription_id is not null,
             b.lessons_left,
             coalesce(b.debt_tiyin, 0)::bigint + coalesce(b.overdrawn_tiyin, 0)::bigint,
             coalesce(b.subscription_overdue_tiyin, 0)::bigint
        from public.student_balance b
        join public.students_brief() s on s.id = b.student_id
       order by s.full_name, s.id;
  end if;

  -- Единственный выход: claims возвращаются в любом случае, и только потом raise.
  perform set_config('request.jwt.claims', v_prev, true);

  if not v_ok then
    raise exception 'Не удалось определить права в центре — обратитесь к администратору'
      using errcode = '42501';
  end if;
end;
$$;

comment on function public.bot_balance_center(uuid, uuid) is
  'Дети родителя в одном центре и их баланс под ЛОКАЛЬНО подменённой сессией (0077, прецедент bot_debts_center 0072/0076): остаток, долг за занятия с перерасходом (та же сумма, что «Долг за занятия» на /app/debts) и просрочка по абонементу — отдельно, не складываются. SECURITY INVOKER и без грантов ни у кого, включая bot_worker. p_user — только из telegram_user(chat), p_center — только из его memberships. Роль проверяется до подмены, самопроверка после; claims возвращаются перед raise.';

revoke all on function public.bot_balance_center(uuid, uuid)
  from public, anon, authenticated, service_role, bot_worker;


-- 2. bot_balance: набор колонок меняется — drop + create (Р7, Р8) ----------------------

drop function public.bot_balance(bigint);

create function public.bot_balance(p_chat_id bigint)
  returns table (
    center_name        text,
    student_id         uuid,
    full_name          text,
    has_subscription   boolean,
    lessons_left       integer,
    debt_tiyin         bigint,
    overdue_tiyin      bigint
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_user uuid;
  v_c    record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р7: группы и супергруппы — отрицательный chat_id.
  if p_chat_id <= 0 then
    raise exception 'Команда доступна только в личной переписке с ботом' using errcode = '42501';
  end if;

  v_user := public.telegram_user(p_chat_id);
  if v_user is null then
    raise exception 'Чат не привязан' using errcode = '42501';
  end if;

  -- Только родитель: остаток числом — это его данные. Специалисту в
  -- приложении показывают слово (student_subscription_badge), и заводить
  -- второй канал к тем же числам в боте незачем.
  for v_c in
    select c.id, c.name
      from public.memberships m
      join public.centers c on c.id = m.center_id and c.deleted_at is null
     where m.user_id = v_user
       and m.role = 'parent'
       and m.payer_id is not null
     order by c.name, c.id
  loop
    return query
      select v_c.name, x.student_id, x.full_name, x.has_subscription,
             x.lessons_left, x.debt_tiyin, x.overdue_tiyin
        from public.bot_balance_center(v_user, v_c.id) x;
  end loop;
end;
$$;

comment on function public.bot_balance(bigint) is
  'Остаток и долг по детям владельца чата — только для роли parent (0033), с 0077 по общему определению «должника» (0076): debt_tiyin — долг за занятия с перерасходом (bigint), overdue_tiyin — просрочка по абонементу отдельно. has_subscription отделяет «безлимит» от «нет абонемента»: в lessons_left и то и другое даёт NULL (0010); lessons_left может быть отрицательным при перерасходе. Групповой chat_id — отказ.';

revoke all on function public.bot_balance(bigint) from public, anon, authenticated, service_role;
grant execute on function public.bot_balance(bigint) to bot_worker;


-- 3. digest_debt_text: {debt} сводки (Р1, Р2, Р6) -------------------------------------

create function public.digest_debt_text(p_center uuid)
  returns text
  language plpgsql
  set search_path = ''
as $$
declare
  v_user    uuid;
  v_d       jsonb;
  v_usage   bigint;
  v_overdue bigint;
  v_fail    constant text := 'не удалось посчитать — см. /debts';
begin
  select m.user_id into v_user
    from public.memberships m
   where m.center_id = p_center and m.role in ('owner', 'admin')
   order by (m.role = 'owner') desc, m.user_id
   limit 1;
  if v_user is null then
    return v_fail;
  end if;

  begin
    v_d := public.bot_debts_center(v_user, p_center);
  exception when others then
    -- Откат подтранзакции возвращает и подменённые claims. Сводка уходит без
    -- расчёта долга, но уходит.
    raise warning 'digest_debt_text: центр %, %', p_center, sqlerrm;
    return v_fail;
  end;

  if v_d is null then
    return v_fail;
  end if;

  v_usage   := coalesce((v_d ->> 'usage_tiyin')::bigint, 0);
  v_overdue := coalesce((v_d ->> 'overdue_tiyin')::bigint, 0);

  return public.format_som(v_usage)
         || case when v_overdue > 0
                 then '; просрочка по абонементам — ' || public.format_som(v_overdue)
                 else '' end;
end;
$$;

comment on function public.digest_debt_text(uuid) is
  'Текст {debt} утренней сводки (0077): долг за занятия центра по общему определению (student_debt_summary через bot_debts_center от имени владельца, иначе администратора) и, если есть, просрочка по абонементам отдельной фразой — суммы не складываются. Сбой расчёта — «не удалось посчитать — см. /debts», не ноль. Внутренняя (SECURITY INVOKER, без грантов ни у кого, включая bot_worker): зовёт только event_messages; центр — из events.center_id, никогда от пользователя.';

revoke all on function public.digest_debt_text(uuid)
  from public, anon, authenticated, service_role, bot_worker;


-- 4. event_messages: ветка digest.daily (Р5) -------------------------------------------

-- Переиздаётся целиком от последней редакции (0073): поиск
-- "create or replace function public.event_messages" по всем миграциям.
-- Отличия от 0073 — только объявление v_debt_text и ветка digest.daily.
create or replace function public.event_messages(p_event_id bigint)
  returns table (
    recipient_user_id uuid,
    channel           text,
    chat_id           bigint,
    message           text,
    subject_id        uuid,
    action            jsonb
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_event    public.events;
  v_tz       text;
  v_vars     jsonb := '{}'::jsonb;
  v_student  uuid;
  v_payer    uuid;
  v_lesson   record;
  v_homework public.homework;
  v_note     public.lesson_notes;
  v_request  public.lesson_voice_requests;
  v_child    text;
  v_summary  text;
  v_days     integer;
  v_debt_text text;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if not found then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  v_tz := public.center_timezone(v_event.center_id);

  -- 0053 Р8/Р10: лимит голосовых резюме — заказчику диктовки ({child} только
  -- в telegram, с предлогом внутри) и owner/admin центра (без {child}, без
  -- subject), пока повтор диктовки имеет смысл (0047 Р4). Заказчик-владелец
  -- не получает двух строк.
  if v_event.type = 'ai.quota_exceeded' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    v_vars := jsonb_build_object(
      'used',  coalesce(v_event.payload ->> 'used', ''),
      'limit', coalesce(v_event.payload ->> 'limit', '')
    );

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               v_vars || jsonb_build_object('child',
                 case when r.channel = 'telegram' then ' по ' || v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r
      union all
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', '')),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r
       where r.user_id <> v_request.requested_by;
    return;
  end if;

  -- 0052: срок заканчивается / истёк — owner/admin центра. {when} и {until}
  -- считаются на момент доставки в поясе центра (Р6).
  if v_event.type in ('subscription.ending', 'subscription.expired') then
    v_days := ((v_event.payload ->> 'until')::timestamptz at time zone v_tz)::date
              - (now() at time zone v_tz)::date;
    v_vars := jsonb_build_object(
      'what',  case when (v_event.payload ->> 'is_trial')::boolean then 'Пробный период' else 'Подписка' end,
      'until', to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY')
    );
    -- {when} есть только у «заканчивается»: у истёкшего срока «сегодня» врало бы.
    if v_event.type = 'subscription.ending' then
      v_vars := v_vars || jsonb_build_object('when', case
                 when v_days <= 0 then 'сегодня'
                 when v_days = 1 then 'завтра'
                 else 'через ' || v_days::text || ' дн.'
               end);
    end if;
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0051: заявка на оплату — администраторам платформы, шаблон только
  -- дефолтный (Р10), суммы и пояс — центра-заявителя (Р12).
  if v_event.type = 'platform.payment_submitted' then
    v_vars := jsonb_build_object(
      'center_name', coalesce((select c.name from public.centers c where c.id = v_event.center_id), '—'),
      'plan_name',   coalesce((select p.name from public.plans p where p.code = v_event.payload ->> 'plan'), coalesce(v_event.payload ->> 'plan', '—')),
      'months',      coalesce(v_event.payload ->> 'months', ''),
      'amount',      public.format_som(coalesce((v_event.payload ->> 'amount_tiyin')::bigint, 0)),
      'source',      case v_event.payload ->> 'source'
                       when 'mbank' then 'Mbank' when 'elcart' then 'Elcart'
                       when 'cash' then 'наличные' else 'другое' end,
      'payment_id',  coalesce(v_event.payload ->> 'payment_id', '')
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_platform_targets(v_event.type) r;
    return;
  end if;

  -- 0051: продление — owner/admin центра; {until} в поясе центра (Р12).
  if v_event.type = 'subscription.extended' then
    v_vars := jsonb_build_object(
      'plan_name', coalesce((select p.name from public.plans p where p.code = v_event.payload ->> 'plan'), coalesce(v_event.payload ->> 'plan', '—')),
      'months',    coalesce(v_event.payload ->> 'months', ''),
      'until',     coalesce(to_char((v_event.payload ->> 'until')::timestamptz at time zone v_tz, 'DD.MM.YYYY'), '—')
    );
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0056: заявка на удаление центра — owner/admin (в т.ч. второй владелец,
  -- который её не подавал), без {until}.
  if v_event.type = 'center.deletion_requested' then
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, '{}'::jsonb),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  end if;

  -- 0057: заявка с публичной витрины записи — стойке (owner/admin/
  -- registrar, notification_front_desk_targets — не notification_admin_
  -- targets, регистратор реально разбирает очередь). {child}/{teacher}/
  -- {when}/{phone} читаются заново на момент доставки, не из payload —
  -- заявку могли обработать до отправки, а специалиста переименовать.
  if v_event.type = 'booking.requested' then
    declare
      v_booking      public.booking_requests;
      v_teacher_name text;
    begin
      -- emit_event открыта authenticated и проверяет только center_id
      -- аргумента — payload не доверенный ключ, откуда читать. Без фильтра
      -- по center_id участник центра X мог бы эмитировать событие с
      -- request_id чужой заявки и получить в свой телеграм имя ребёнка и
      -- телефон родителя центра Y (архитектор, раунд 3, п.3).
      select * into v_booking from public.booking_requests
       where id = (v_event.payload ->> 'request_id')::uuid
         and center_id = v_event.center_id
         and deleted_at is null;
      if not found then
        return;
      end if;

      select t.full_name into v_teacher_name from public.teachers t where t.id = v_booking.teacher_id;

      v_vars := jsonb_build_object(
        'child', v_booking.child_name,
        'teacher', coalesce(v_teacher_name, 'специалист'),
        'when', to_char(v_booking.starts_at at time zone v_tz, 'DD.MM HH24:MI'),
        'phone', v_booking.parent_phone
      );

      return query
        select r.user_id, r.channel, r.chat_id,
               public.render_template(r.template_text, v_vars),
               null::uuid,
               null::jsonb
          from public.notification_front_desk_targets(v_event.center_id, v_event.type) r;
      return;
    end;
  end if;

  -- 0051 Р9: подписка истекла между диктовкой и обработкой — заказчику
  -- диктовки, если он всё ещё сотрудник (0047 Р2) и повтор диктовки ещё
  -- имеет смысл (0047 Р4, дословно как у lesson.voice_failed — текст просит
  -- записать заново, и просить это при утверждённой заметке нельзя).
  -- {child} только в telegram.
  if v_event.type = 'subscription.voice_blocked' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               jsonb_build_object('child',
                 case when r.channel = 'telegram' then v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r;
    return;
  end if;

  if v_event.type = 'lesson.reminder' then
    select l.starts_at, l.status, l.deleted_at, coalesce(t.full_name, '—') as teacher
      into v_lesson
      from public.lessons l
      left join public.teachers t on t.id = l.effective_teacher_id
     where l.id = (v_event.payload ->> 'lesson_id')::uuid;

    if not found or v_lesson.deleted_at is not null or v_lesson.status <> 'planned' then
      return;
    end if;

    v_vars := jsonb_build_object(
      'date',    to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY'),
      'time',    to_char(v_lesson.starts_at at time zone v_tz, 'HH24:MI'),
      'teacher', v_lesson.teacher
    );

    return query
      with participants as (
        select lp.student_id, s.full_name, s.payer_id
          from public.lesson_participants lp
          join public.students s on s.id = lp.student_id and s.deleted_at is null
         where lp.lesson_id = (v_event.payload ->> 'lesson_id')::uuid
           and lp.deleted_at is null
      )
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', p.full_name)),
             p.student_id,
             case when r.chat_id is null then null else jsonb_build_object(
               'label', 'Подтвердить приход',
               'callback_data', 'c:' || v_event.id::text || ':' || p.student_id::text
             ) end
        from participants p
        join lateral public.notification_targets(v_event.center_id, p.payer_id, v_event.type) r on true;
    return;
  end if;

  -- 0043: месячный отчёт. Текст уже заморожен в событии (Р4 из 0043) —
  -- здесь он только подставляется, ничего не пересчитывается.
  if v_event.type = 'report.monthly_ready' then
    v_student := (v_event.payload ->> 'student_id')::uuid;

    select s.payer_id into v_payer
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    -- 0047 Р10: текст отчёта — только в telegram, вне его пусто.
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'summary', case when r.channel = 'telegram'
                               then coalesce(v_event.payload ->> 'summary', '') else '' end,
               'month',   to_char((v_event.payload ->> 'period_month')::date, 'MM.YYYY'),
               'child',   (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0047: утверждённое резюме — родителю. Перечитывается на момент
  -- доставки (Р4); {summary} только в telegram (Р1); длина ограничена (Р5).
  if v_event.type = 'lesson.note_approved' then
    select * into v_note from public.lesson_notes n
     where n.id = (v_event.payload ->> 'lesson_note_id')::uuid
       and n.center_id = v_event.center_id
       and n.deleted_at is null
       and n.status = 'approved';
    if not found or coalesce(trim(v_note.parent_summary), '') = '' then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_note.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_note.student_id;
    select s.payer_id, s.full_name into v_payer, v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    v_summary := case
      when length(v_note.parent_summary) > 3500 then left(v_note.parent_summary, 3499) || '…'
      else v_note.parent_summary
    end;
    v_vars := jsonb_build_object(
      'child', v_child,
      'date',  to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY')
    );

    -- Р1: вне telegram переменная пуста, а не отсутствует — иначе
    -- render_template оставит «{summary}» буквально.
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               v_vars || jsonb_build_object('summary',
                 case when r.channel = 'telegram' then v_summary else '' end)),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0047: отказ обработки диктовки — заказчику диктовки, если он всё ещё
  -- сотрудник центра (Р2) и повтор диктовки ещё имеет смысл (Р4).
  -- Причина отказа в текст не идёт (Р6).
  if v_event.type = 'lesson.voice_failed' then
    select * into v_request from public.lesson_voice_requests r
     where r.id = (v_event.payload ->> 'voice_request_id')::uuid
       and r.center_id = v_event.center_id;
    if not found then
      return;
    end if;

    -- Р4: дословно условие отказа ai_job_begin (0042) — утверждено или
    -- голосовой черновик другой диктовки. Ручной черновик не гасит.
    if exists (
      select 1 from public.lesson_notes n
       where n.lesson_id = v_request.lesson_id
         and n.student_id = v_request.student_id
         and n.deleted_at is null
         and (n.status = 'approved'
              or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
    ) then
      return;
    end if;

    select l.starts_at, l.status, l.deleted_at into v_lesson
      from public.lessons l where l.id = v_request.lesson_id;
    if not found or v_lesson.deleted_at is not null or v_lesson.status = 'cancelled' then
      return;
    end if;

    v_student := v_request.student_id;
    select s.full_name into v_child
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_child is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text,
               jsonb_build_object('child',
                 case when r.channel = 'telegram' then v_child else '' end)),
             v_student,
             null::jsonb
        from public.notification_user_targets(v_event.center_id, v_request.requested_by, v_event.type) r;
    return;
  end if;

  -- 0045: выдано родителю. Шлём независимо от текущего статуса задания —
  -- факт выдачи не перестаёт быть фактом, даже если уже сдано (Р4).
  if v_event.type = 'homework.assigned' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student),
               'due',   coalesce(to_char(v_homework.due_on, 'DD.MM.YYYY'), 'без срока')
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0045: специалисту, что сдано. Шлём, только если статус ВСЁ ЕЩЁ
  -- submitted — напоминание «проверьте» после того, как уже проверено,
  -- вводит в заблуждение (Р4, в отличие от assigned выше).
  if v_event.type = 'homework.submitted' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found or v_homework.status <> 'submitted' then
      return;
    end if;

    v_student := v_homework.student_id;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_homework_targets(v_event.center_id, v_homework.id, v_event.type) r;
    return;
  end if;

  -- 0045: специалист проверил — родителю.
  if v_event.type = 'homework.reviewed' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  if v_event.type in ('subscription.low_balance', 'subscription.exhausted', 'student.absent_streak') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'left',  coalesce(v_event.payload ->> 'lessons_left', ''),
      'count', coalesce(v_event.payload ->> 'length', '')
    );
  elsif v_event.type in ('installment.due', 'installment.overdue') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'amount', public.format_som((v_event.payload ->> 'amount_tiyin')::bigint),
      'date',   to_char((v_event.payload ->> 'due_date')::date, 'DD.MM.YYYY')
    );
  elsif v_event.type = 'digest.daily' then
    -- 0077: {debt} — общее определение «должника» (student_debt_summary через
    -- digest_debt_text), на момент доставки, а не payload.debt_tiyin (0032:
    -- только debt_tiyin, без перерасхода и просрочки). Центр — events.center_id.
    v_debt_text := public.digest_debt_text(v_event.center_id);
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'date',    to_char((v_event.payload ->> 'date')::date, 'DD.MM.YYYY'),
               'lessons', coalesce(v_event.payload ->> 'lessons_today', '0'),
               'low',     coalesce(v_event.payload ->> 'low_balance', '0'),
               'debt',    v_debt_text,
               'overdue', coalesce(v_event.payload ->> 'installments_overdue', '0'),
               -- 0073: поступления за день ДО даты сводки — из базы на момент
               -- доставки, не из payload (emit_event открыта любой роли центра:
               -- цифра из payload подделывалась бы). Дата в самой строке —
               -- доставка бывает позже утра.
               'payments', 'за ' || to_char((v_event.payload ->> 'date')::date - 1, 'DD.MM') || ': '
                           || case when (pay.p ->> 'ops')::integer = 0
                                   then 'платежей не было'
                                   else public.format_som((pay.p ->> 'total_tiyin')::bigint)
                                        || ' (операций: ' || (pay.p ->> 'ops') || ')' end
             )),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r
       cross join lateral (
         select public.center_payments_day(v_event.center_id, (v_event.payload ->> 'date')::date - 1) as p
         offset 0
       ) pay;
    return;
  else
    return;
  end if;

  select s.payer_id into v_payer
    from public.students s
   where s.id = v_student and s.deleted_at is null;

  if v_payer is null then
    return;
  end if;

  return query
    select r.user_id, r.channel, r.chat_id,
           public.render_template(r.template_text, v_vars || jsonb_build_object(
             'child', (select s.full_name from public.students s where s.id = v_student))),
           v_student,
           null::jsonb
      from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
end;
$$;

comment on function public.event_messages(bigint) is
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4), с 0047 — только в telegram. Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. lesson.note_approved (0047) — резюме родителю, {summary} только в telegram и не длиннее 3500 символов; lesson.voice_failed (0047) — заказчику диктовки через notification_user_targets, без причины отказа и только пока повтор диктовки имеет смысл (условие ai_job_begin). 0051: platform.payment_submitted — администраторам платформы (notification_platform_targets, шаблон только дефолтный), subscription.extended — owner/admin центра с {until} в поясе центра, subscription.voice_blocked — заказчику диктовки, {child} только в telegram. 0052: subscription.ending/expired — owner/admin центра, {what}/{until}/{when} на момент доставки в поясе центра. 0053: ai.quota_exceeded — заказчику диктовки ({child} с предлогом, только telegram) и owner/admin центра без {child}, {used}/{limit} в оба канала, пока повтор диктовки имеет смысл. 0056: center.deletion_requested — owner/admin центра, без переменных. 0057: booking.requested — стойке (owner/admin/registrar) через notification_front_desk_targets, {child}/{teacher}/{when}/{phone} читаются заново из booking_requests на момент доставки, не из payload. Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать. 0073: digest.daily — {payments} («за ДД.ММ: сумма (операций: N)» или «платежей не было») считается из платежей на момент доставки (center_payments_day), не из payload. 0077: {debt} в digest.daily — общее определение «должника» из student_debt_summary (долг за занятия с перерасходом; при просрочке по абонементам — «; просрочка по абонементам — сумма», суммы не складываются), считается на момент доставки через digest_debt_text от имени владельца центра (events.center_id), payload.debt_tiyin не читается; при сбое расчёта — «не удалось посчитать — см. /debts», а не ноль. {overdue} — по-прежнему число просроченных рассрочек из payload.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;


-- 5. preview_message: образец {debt} (Р5) -----------------------------------------------

-- От последней редакции (0073); изменён только образец 'debt'.
create or replace function public.preview_message(p_text text, p_vars jsonb default null)
  returns text
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  return public.render_template(
    p_text,
    coalesce(p_vars, jsonb_build_object(
      'child', 'Айдана', 'date', '01.10.2026', 'time', '10:00',
      'teacher', 'Нургуль Абдырахманова', 'left', '2', 'count', '2',
      'amount', public.format_som(200000), 'lessons', '5', 'low', '1',
      'debt', public.format_som(70000) || '; просрочка по абонементам — ' || public.format_som(120000),
      'overdue', '0',
      'payments', 'за 30.09: ' || public.format_som(1250000) || ' (операций: 7)'
    ))
  );
end;
$$;
comment on function public.preview_message(text, jsonb) is 'Предпросмотр шаблона на образцовых данных — тем же рендером, что и отправка.';

revoke all on function public.preview_message(text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.preview_message(text, jsonb) to authenticated;
