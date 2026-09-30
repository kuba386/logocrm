-- pgTAP: service_role без прав на таблицы, которые пишут только функции и
-- триггеры (0079, закрывает долг 0075 Р4).
--
-- Забор по фактическому ACL: revoke от postgres молча не снимает грант другого
-- grantor, а default privileges Supabase выдают service_role всё на новые
-- таблицы. Новую таблицу «только функциями» добавляет в список автор миграции.
-- Известное ограничение проверки «все пишущие функции — definer»: регулярка не
-- видит update only / merge / динамический execute и имена без public. —
-- поэтому в конце живая проверка: ученик под authenticated доходит до
-- audit_log и funnel_events (nextval последовательностей — от владельца).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(8);

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
        and a.grantee = 'service_role'::regrole $$,
  'Служебные таблицы планировщиков (0032, 0052) — у service_role ни одной привилегии');

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
        and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+public\.(events|audit_log|lesson_participants|funnel_events)\M' $$,
  'Все функции, пишущие в эти таблицы (включая триггерные — у них EXECUTE не проверяется), — SECURITY DEFINER');


-- Живой путь: ученик под authenticated → аудит и воронка пишутся без прав на таблицы и счётчики.
insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','79000000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0079@test.kg','','','','','','','','');
insert into public.centers (id, name, slug, settings) values
  ('79000000-0000-0000-0000-0000000000c1','Центр 0079','centr-0079','{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('79000000-0000-0000-0000-000000000001','79000000-0000-0000-0000-0000000000c1','owner', null, null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

select public.tests_claims('79000000-0000-0000-0000-000000000001','79000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.create_student_with_payer('Ученик 0079', null, 'Родитель 0079', '+996700007901', 'мама') $q$,
  'Ученик создаётся под authenticated после снятия прав на счётчики');
reset role;
select public.tests_claims(null, null);

select ok(
  exists (select 1 from public.audit_log al join public.students s on s.id = al.row_id
           where al.table_name = 'students' and al.action = 'INSERT' and s.full_name = 'Ученик 0079'),
  'Аудит записан: триггер definer, nextval audit_log_id_seq — от владельца');

select is(
  (select count(*)::int from public.funnel_events fe join public.students s on s.id = fe.student_id
    where s.full_name = 'Ученик 0079'),
  1, 'Событие воронки записано: триггер definer, nextval funnel_events_id_seq — от владельца');

select * from finish();
rollback;
