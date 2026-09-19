-- =============================================================================
-- 0037_message_templates_writable.sql — шаблоны реально можно сохранить
-- (доделка этапа 6, живая приёмка 19.09.2026)
--
-- Найдено на живом прогоне чек-листа этапа 6: владелец открывает
-- /app/settings/notifications, правит текст, жмёт «Сохранить» — и получает
-- «new row violates row-level security policy for table "message_templates"».
-- pgTAP этого не поймал (0034): все вставки в таблицу шли от postgres при
-- пустых claims, ни один тест не писал в неё от authenticated.
--
-- Разбор дошёл до трёх независимых проблем, а не одной:
--
--   Р1. saveTemplate (apps/web/…/notifications/actions.ts) при первом
--       сохранении не передаёт center_id — так же, как соседние формы
--       (services, subscription_types), которые полагаются на
--       `default public.current_center()` у колонки. У message_templates
--       такого default нет — намеренно (0034 Р1: center_id is null значит
--       «текст платформы», и его пишут только миграции). INSERT уходит с
--       center_id = NULL, а with check политики tenant_admin требует
--       center_id = current_center() — отказ. Чиним default: он применяется,
--       только когда колонка ОПУЩЕНА в insert, поэтому платформенные строки
--       (миграции вставляют center_id явным null) не задеты.
--
--   Р2. «Отправлять» выключен, а сообщение всё равно уходит — текстом
--       платформы. Было: `... and mt.is_active and ... order by center_id
--       nulls last limit 1` — фильтр по is_active стоял ДО выбора
--       победившей строки, и выключенная строка центра не перекрывала
--       дефолт, а исчезала из выборки, откуда побеждал активный дефолт.
--       Разрешение шаблона вынесено в отдельную функцию
--       resolve_template(): сначала выбрать строку (своя важнее дефолта),
--       потом уже решать по ЕЁ is_active — не наоборот. notification_targets
--       и notification_admin_targets теперь зовут её, а не держат
--       собственную копию правила (было продублировано трижды, включая
--       apps/web/…/notifications/page.tsx, который правило не путает — там
--       баг не найден).
--
--   Р3. «Вернуть текст платформы» ломается тем же классом ошибки: прямой
--       update({deleted_at}) из PostgREST заворачивается в `returning *`, а
--       обновлённая строка не проходит ни tenant_admin.USING (deleted_at is
--       null), ни message_templates_read_defaults (center_id is null) —
--       RLS отбивает возврат строки, хотя сама мутация могла пройти.
--       Проект уже раз проходил этот урок (0012, soft-delete только через
--       RPC) — здесь тот же приём: upsert_message_template и
--       reset_message_template, авторизация и center_id внутри функции, а
--       не в теле запроса из браузера. Заодно снят гоночный сценарий: два
--       клика «Сохранить» подряд раньше могли упереться в 23505 по
--       message_templates_center_key (insert-then-select в JS — check-then-
--       act), теперь insert ... on conflict do update в одной транзакции.
--
-- Дополнительно — Р4: event_type не был ограничен ничем в базе (только
-- if/elsif в event_messages, дублирующий массив EVENTS в TS). Опечатка в
-- event_type создавала бы валидную с точки зрения RLS строку, которую не
-- читает ни одна функция и не показывает ни один экран — правка молча
-- уходила «в никуда». Лечится тем же приёмом, что и статусы посещения:
-- lookup-таблица и FK, а не enum и не doc-комментарий.
--
-- Правило на будущее (см. docs/Database.md): nullable center_id — сигнал,
-- что таблица не проходит целиком под apply_tenant_rls, и запись в неё из
-- приложения обязана идти через RPC, а не через прямой insert/update формы.
-- =============================================================================


-- 1. center_id получает default, как у всех тенантных таблиц ------------------------------------

-- Применяется только когда колонка ОПУЩЕНА в insert. Явные center_id = null
-- (платформенные дефолты, их пишут только миграции) не задеты.
alter table public.message_templates
  alter column center_id set default public.current_center();


-- 2. Белый список типов событий -----------------------------------------------------------------

create table if not exists public.notification_event_types (
  event_type  text primary key,
  description text not null
);

comment on table public.notification_event_types is
  'Белый список event_type для message_templates (0037 Р4). Не центровая, не RLS: справочник платформы, правит только миграция.';

insert into public.notification_event_types (event_type, description) values
  ('lesson.reminder',          'Напоминание о занятии'),
  ('subscription.low_balance', 'Заканчивается абонемент'),
  ('subscription.exhausted',   'Абонемент закончился'),
  ('student.absent_streak',    'Пропуски подряд'),
  ('installment.due',         'Платёж по рассрочке сегодня'),
  ('installment.overdue',     'Платёж по рассрочке просрочен'),
  ('digest.daily',            'Дневная сводка')
on conflict (event_type) do nothing;

alter table public.message_templates
  drop constraint if exists message_templates_event_type_fk;
alter table public.message_templates
  add constraint message_templates_event_type_fk
  foreign key (event_type) references public.notification_event_types (event_type);

alter table public.notification_event_types enable row level security;
-- Политик нет ни одной: таблица не читается и не пишется через PostgREST,
-- как telegram_link_codes (0033). FK-проверку RLS не касается.
revoke all on table public.notification_event_types from public, anon, authenticated, service_role;


-- 3. resolve_template — единственное место, где решается текст и «слать ли» ----------------------

create or replace function public.resolve_template(
  p_center_id  uuid,
  p_event_type text,
  p_channel    text
)
  returns table (should_send boolean, message_text text)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(mt.is_active, false), mt.text
    from public.message_templates mt
   where mt.event_type = p_event_type
     and mt.channel = p_channel
     and mt.deleted_at is null
     and (mt.center_id = p_center_id or mt.center_id is null)
   order by mt.center_id nulls last
   limit 1
$$;

comment on function public.resolve_template(uuid, text, text) is
  'Побеждает строка центра, а не дефолт (order by center_id nulls last) — и ТОЛЬКО ПОТОМ смотрим is_active у победившей строки. Обратный порядок (было в 0034: is_active в фильтре до order by) давал побег на дефолт вместо «не слать», когда центр выключал напоминание (0037 Р2).';

revoke all on function public.resolve_template(uuid, text, text) from public, anon, authenticated, service_role;


create or replace function public.notification_targets(
  p_center_id  uuid,
  p_payer_id   uuid,
  p_event_type text
)
  returns table (user_id uuid, channel text, chat_id bigint, template_text text)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select m.user_id,
         case when a.chat_id is null then 'whatsapp_link' else 'telegram' end,
         a.chat_id,
         rt.message_text
    from public.memberships m
    left join public.telegram_accounts a
           on a.user_id = m.user_id and a.unlinked_at is null
    join lateral public.resolve_template(
           p_center_id, p_event_type,
           case when a.chat_id is null then 'whatsapp_link' else 'telegram' end
         ) rt on true
   where m.center_id = p_center_id
     and m.role = 'parent'
     and m.payer_id = p_payer_id
     and rt.should_send;
$$;

comment on function public.notification_targets(uuid, uuid, text) is
  'Родители-получатели по плательщику: канал и текст через resolve_template (0037). rt.should_send в where — выключенный шаблон центра не даёт получателя вовсе, а не подменяется дефолтом.';


create or replace function public.notification_admin_targets(p_center_id uuid, p_event_type text)
  returns table (user_id uuid, channel text, chat_id bigint, template_text text)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select m.user_id,
         case when a.chat_id is null then 'whatsapp_link' else 'telegram' end,
         a.chat_id,
         rt.message_text
    from public.memberships m
    left join public.telegram_accounts a
           on a.user_id = m.user_id and a.unlinked_at is null
    join lateral public.resolve_template(
           p_center_id, p_event_type,
           case when a.chat_id is null then 'whatsapp_link' else 'telegram' end
         ) rt on true
   where m.center_id = p_center_id
     and m.role in ('owner', 'admin')
     and rt.should_send;
$$;

comment on function public.notification_admin_targets(uuid, text) is 'Получатели сводок: владелец и администраторы центра. should_send — см. resolve_template (0037).';


-- 4. Запись шаблона — через RPC, не через прямой insert/update из браузера -----------------------

create or replace function public.upsert_message_template(
  p_event_type text,
  p_channel    text,
  p_text       text,
  p_is_active  boolean
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_id     uuid;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if v_center is null then
    raise exception 'Нет активного центра — перезайдите' using errcode = '42501';
  end if;

  if p_channel not in ('telegram', 'whatsapp_link') then
    raise exception 'Неизвестный канал' using errcode = '22023';
  end if;

  if trim(coalesce(p_text, '')) = '' then
    raise exception 'Текст не может быть пустым' using errcode = '22023';
  end if;

  -- on conflict — атомарно: два клика «Сохранить» подряд раньше могли
  -- упереться в 23505 (insert-then-select в JS был check-then-act, не
  -- одной транзакцией). event_type вне справочника отбивает FK (23503) —
  -- строка не создаётся молча под опечаткой (0037 Р4).
  insert into public.message_templates (center_id, event_type, channel, text, is_active)
  values (v_center, p_event_type, p_channel, p_text, p_is_active)
  on conflict (center_id, event_type, channel) where center_id is not null and deleted_at is null
  do update set text = excluded.text, is_active = excluded.is_active
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.upsert_message_template(text, text, text, boolean) is
  'Правка шаблона центра. center_id и права — здесь, не в браузере (0037 Р1, Р3). on conflict делает гонку из двух сохранений невозможной, а не редко воспроизводимой.';


create or replace function public.reset_message_template(p_event_type text, p_channel text)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.message_templates
     set deleted_at = now()
   where center_id = v_center
     and event_type = p_event_type
     and channel = p_channel
     and deleted_at is null;

  return found;
end;
$$;

comment on function public.reset_message_template(text, text) is
  'Возврат к тексту платформы: soft-delete своей строки через RPC (0037 Р3) — прямой update из PostgREST не проходил returning * мимо RLS. false — своей строки не было, честный no-op, а не фальшивое «Готово».';

revoke all on function public.upsert_message_template(text, text, text, boolean) from public, anon, authenticated, service_role;
grant execute on function public.upsert_message_template(text, text, text, boolean) to authenticated;

revoke all on function public.reset_message_template(text, text) from public, anon, authenticated, service_role;
grant execute on function public.reset_message_template(text, text) to authenticated;

-- Запись в таблицу теперь только через RPC выше; select остаётся — экран
-- настроек читает и дефолты, и свою строку напрямую (message_templates_read_defaults + tenant_admin).
revoke insert, update on public.message_templates from authenticated;
