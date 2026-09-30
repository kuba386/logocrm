-- pgTAP: service_role без прав на таблицы, которые пишут только функции и
-- триггеры (0079, закрывает долг 0075 Р4).
--
-- Забор по фактическому ACL: revoke от postgres молча не снимает грант другого
-- grantor, а default privileges Supabase выдают service_role всё на новые
-- таблицы. Новую таблицу «только функциями» добавляет в список автор миграции.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(5);

select is_empty(
  $$ select c.oid::regclass::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault((case when c.relkind = 'S' then 's' else 'r' end)::"char", c.relowner))) a
      where c.oid in ('public.events'::regclass, 'public.audit_log'::regclass,
                      'public.lesson_participants'::regclass, 'public.funnel_events'::regclass,
                      'public.events_id_seq'::regclass, 'public.audit_log_id_seq'::regclass,
                      'public.funnel_events_id_seq'::regclass)
        and a.grantee = 'service_role'::regrole $$,
  'service_role — ни одной привилегии на events, audit_log, lesson_participants, funnel_events и их последовательности');

select is_empty(
  $$ select c.oid::regclass::text || ' ' || a.grantee::regrole::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault('s', c.relowner))) a
      where c.oid in ('public.events_id_seq'::regclass, 'public.audit_log_id_seq'::regclass,
                      'public.funnel_events_id_seq'::regclass)
        and a.grantee <> c.relowner $$,
  'Последовательности этих таблиц — ни у кого, кроме владельца: ни nextval, ни setval снаружи');

select is_empty(
  $$ select c.oid::regclass::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where c.oid in ('public.lesson_reminders_sent'::regclass, 'public.center_digest_runs'::regclass,
                      'public.subscription_reminders_sent'::regclass)
        and a.grantee = 'service_role'::regrole
        and a.privilege_type not in ('SELECT') $$,
  'Служебные таблицы планировщиков (0032, 0052) — тоже без записи у service_role');

select is_empty(
  $$ select c.oid::regclass::text || ' ' || a.grantee::regrole::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where c.oid in ('public.events'::regclass, 'public.audit_log'::regclass,
                      'public.lesson_participants'::regclass, 'public.funnel_events'::regclass)
        and a.grantee <> c.relowner
        and a.privilege_type <> 'SELECT' $$,
  'Никто, кроме владельца, в эти таблицы не пишет: у authenticated/anon/PUBLIC — не больше SELECT (регрессия 0024)');

select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and not p.prosecdef
        and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+public\.(events|audit_log|lesson_participants|funnel_events)\M'
        and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                     where a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner) $$,
  'Все функции, пишущие в эти таблицы и доступные кому-то кроме владельца, — SECURITY DEFINER: иначе запись шла бы от роли вызывающего и падала');

select * from finish();
rollback;
