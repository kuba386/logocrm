-- =============================================================================
-- 0079_service_role_closed_tables.sql — service_role без прав на таблицы,
-- которые пишут только функции и триггеры
--
-- Долг из 0075 Р4: у service_role оставались все табличные права на
-- public.events (0024 сняла их только с public/anon/authenticated). Outbox
-- пишут только emit_event* (definer), очередь забирает bot_worker через
-- claim/ack/fail (definer). service_role в приложении не используется нигде
-- (бот — bot_worker, публичная запись — public_booking, n8n — «не service_role»,
-- ADR-008); его утечка — полная компрометация, но писать «outbox закрыт от
-- service_role» до этой миграции было нельзя.
--
-- Ревью плана — architect:
--   Р1. revoke all, а не перечень: в PG17 есть MAINTAIN, перечень бы её пропустил.
--       SELECT тоже снят — читателей под service_role нет, RLS он обходит.
--   Р2. Кроме events — ещё три таблицы, которые заполняют только триггеры и
--       definer-функции: audit_log, lesson_participants (денормализация, на
--       которой держится EXCLUDE по ребёнку), funnel_events (0055 закрыла только
--       public/anon/authenticated). Последовательности — вместе с таблицами, и не
--       только у service_role: anon/authenticated держали на них USAGE/UPDATE.
--   Р3. revoke от postgres молча не снимет грант другого grantor — поэтому
--       забор в pgTAP по фактическому ACL (tests/0079), а не доверие миграции.
--   Р4. Остальные таблицы у service_role не тронуты — отдельное решение
--       (tests/0024 держит DELETE на students как признак «service_role — всё»).
--       alter default privileges не нужен: новые закрытые таблицы автор
--       миграции добавляет в список tests/0079.
--
-- pg_cron/pg_net не установлены, edge functions нет, events нет в publication —
-- ломаться нечему.
-- =============================================================================

revoke all on table public.events, public.audit_log, public.lesson_participants, public.funnel_events
  from service_role;

-- Последовательности — ни у кого, кроме владельца: default privileges выдали anon и
-- authenticated USAGE/UPDATE (setval), а вставки идут только из definer-функций
-- (nextval исполняется от владельца), так что читателям они не нужны.
revoke all on sequence public.events_id_seq, public.audit_log_id_seq, public.funnel_events_id_seq
  from public, anon, authenticated, service_role;
