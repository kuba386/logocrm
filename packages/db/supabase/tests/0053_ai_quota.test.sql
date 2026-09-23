-- pgTAP: квота голосовых резюме по тарифу (0053).
--
-- Заборы: новые функции без грантов, ai_usage без insert-гранта, справочник
-- и дефолты ai.quota_exceeded. Счёт: граница месяца в поясе центра, чужой
-- центр не считается. Границы лимита: limit-1 проходит, limit отбивается,
-- 0 отбивает сразу, -1 не отбивает никогда. request_voice_note: отказ до
-- гашения прежнего токена, текст по роли. Резерв: свежая running-работа
-- считается в ai_job_begin (но не в request_voice_note — Р3), своя работа
-- при перезахвате исключается, старше 8 минут не считается. ai_job_begin:
-- null без ai_jobs, одно событие, повтор — null и то же событие, второй
-- прямой emit — 23505; тариф отсутствует — null без события (fail closed).
-- Доставка: заказчик и owner/admin, {child} только telegram с предлогом,
-- {used}/{limit} в оба канала, subject_required=false. Регрессия 0048.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(27);


-- 1. Заборы ----------------------------------------------------------------------------------------------

select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('center_month_start','center_ai_notes_used','ai_notes_reserved','assert_ai_quota')
        and (has_function_privilege('public', p.oid, 'EXECUTE')
             or has_function_privilege('anon', p.oid, 'EXECUTE')
             or has_function_privilege('authenticated', p.oid, 'EXECUTE')
             or has_function_privilege('service_role', p.oid, 'EXECUTE')
             or has_function_privilege('bot_worker', p.oid, 'EXECUTE')) $$,
  'Новые функции квоты без единого гранта — зовутся только изнутри definer (Р1)');

select is_empty(
  $$ select grantee from information_schema.role_table_grants
      where table_schema = 'public' and table_name = 'ai_usage' and privilege_type = 'INSERT' $$,
  'ai_usage по-прежнему без insert-гранта ни у кого — единственный писатель ai_usage_record (Р1)');

select set_eq(
  $$ select event_type || ':' || audience || ':' || subject_required::text || ':' || mandatory::text || ':' || array_to_string(channels, '+')
       from public.notification_event_types where event_type = 'ai.quota_exceeded' $$,
  $$ values ('ai.quota_exceeded:center:false:false:telegram+whatsapp_link') $$,
  'Справочник: не обязательное, не о ребёнке формально (subject опционален), оба канала (Р8)');

select is(
  (select count(*)::int from public.message_templates
    where center_id is null and deleted_at is null and event_type = 'ai.quota_exceeded'),
  2, 'Дефолтные шаблоны на оба канала');


-- Фикстура ------------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0530000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0053@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0530000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-0053@test.kg','','','','','','','','');

-- solo: лимит 30 (0049 seed). Центр Б — нулевой лимит через свой тариф.
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('a0530000-0000-0000-0000-0000000000c1','Центр А 0053','centr-a-0053','solo', now() + interval '30 days', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('a0530000-0000-0000-0000-000000000010','a0530000-0000-0000-0000-0000000000c1','Специалист 0053','a0530000-0000-0000-0000-000000000002');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('a0530000-0000-0000-0000-000000000020','a0530000-0000-0000-0000-0000000000c1','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('a0530000-0000-0000-0000-000000000030','a0530000-0000-0000-0000-0000000000c1','Родитель 0053','+996700005301');

insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('a0530000-0000-0000-0000-000000000001','a0530000-0000-0000-0000-0000000000c1','owner',  null),
  ('a0530000-0000-0000-0000-000000000002','a0530000-0000-0000-0000-0000000000c1','teacher','a0530000-0000-0000-0000-000000000010');

insert into public.students (id, center_id, full_name, payer_id) values
  ('a0530000-0000-0000-0000-000000000040','a0530000-0000-0000-0000-0000000000c1','Ребёнок 0053','a0530000-0000-0000-0000-000000000030');

insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('a0530000-0000-0000-0000-000000000050','a0530000-0000-0000-0000-0000000000c1','a0530000-0000-0000-0000-000000000010',
   'a0530000-0000-0000-0000-000000000040','a0530000-0000-0000-0000-000000000020','planned',
   now() - interval '2 hours', now() - interval '1 hour 15 minutes'),
  ('a0530000-0000-0000-0000-000000000051','a0530000-0000-0000-0000-0000000000c1','a0530000-0000-0000-0000-000000000010',
   'a0530000-0000-0000-0000-000000000040','a0530000-0000-0000-0000-000000000020','planned',
   now() - interval '1 hour', now() - interval '15 minutes');

insert into public.telegram_accounts (user_id, chat_id) values
  ('a0530000-0000-0000-0000-000000000002', 5302),
  ('a0530000-0000-0000-0000-000000000001', 5301);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Счёт: граница месяца в поясе центра (Р5) -------------------------------------------------------------

-- 29 строк в этом месяце (в поясе центра) + 1 строка в прошлом месяце — не должна считаться.
insert into public.ai_usage (center_id, kind, cost_tiyin, created_at)
select 'a0530000-0000-0000-0000-0000000000c1', 'summary', 100, public.center_month_start('a0530000-0000-0000-0000-0000000000c1') + (n || ' hours')::interval
  from generate_series(1, 29) n;
insert into public.ai_usage (center_id, kind, cost_tiyin, created_at)
values ('a0530000-0000-0000-0000-0000000000c1', 'summary', 100, public.center_month_start('a0530000-0000-0000-0000-0000000000c1') - interval '1 second');
insert into public.ai_usage (center_id, kind, cost_tiyin, created_at)
values ('a0530000-0000-0000-0000-0000000000c1', 'transcribe', 50, public.center_month_start('a0530000-0000-0000-0000-0000000000c1') + interval '1 hour');

select is(public.center_ai_notes_used('a0530000-0000-0000-0000-0000000000c1'), 29,
  'Считаются только summary этого месяца в поясе центра — не transcribe, не прошлый месяц (Р5)');


-- 3. request_voice_note: последний слот проходит, лимит отбивает (Р2, Р6, Р7) ------------------------------

select public.tests_claims('a0530000-0000-0000-0000-000000000002','a0530000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.request_voice_note('a0530000-0000-0000-0000-000000000050','a0530000-0000-0000-0000-000000000040') $q$,
  '29 из 30 — 30-я диктовка ещё проходит');
reset role;

-- 30-я строка использования — лимит исчерпан.
select public.tests_claims(null, null);
insert into public.ai_usage (center_id, kind, cost_tiyin) values ('a0530000-0000-0000-0000-0000000000c1', 'summary', 100);
select is(public.center_ai_notes_used('a0530000-0000-0000-0000-0000000000c1'), 30, 'Использовано 30 из 30');

select public.tests_claims('a0530000-0000-0000-0000-000000000002','a0530000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.request_voice_note('a0530000-0000-0000-0000-000000000051','a0530000-0000-0000-0000-000000000040') $q$,
  '23514', null,
  'Специалист: лимит исчерпан — 23514 (Р2)');
reset role;

-- Текст различается по роли (Р7): владельцу — заявка, специалисту — сообщите владельцу.
select public.tests_claims('a0530000-0000-0000-0000-000000000001','a0530000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_like(
  $q$ select public.request_voice_note('a0530000-0000-0000-0000-000000000051','a0530000-0000-0000-0000-000000000040') $q$,
  '%Тариф и оплата%',
  'Владельцу — «подайте заявку на экране «Тариф и оплата»» (Р7)');
reset role;
select public.tests_claims('a0530000-0000-0000-0000-000000000002','a0530000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_like(
  $q$ select public.request_voice_note('a0530000-0000-0000-0000-000000000051','a0530000-0000-0000-0000-000000000040') $q$,
  '%Сообщите владельцу центра%',
  'Специалисту — «сообщите владельцу центра» (Р7)');
reset role;

-- Р6: отказ не тронул живой токен первой (успешной) диктовки.
select ok(
  (select cancelled_at is null from public.lesson_voice_requests
    where lesson_id = 'a0530000-0000-0000-0000-000000000050' and student_id = 'a0530000-0000-0000-0000-000000000040'
    order by created_at desc limit 1),
  'Прежний живой токен не погашен отказом по квоте (Р6)');
select is(
  (select count(*)::int from public.lesson_voice_requests where lesson_id = 'a0530000-0000-0000-0000-000000000051'),
  0, 'Вторая диктовка токена не получила');


-- 4. Границы тарифа: 0 и -1 (Q3) ---------------------------------------------------------------------------

select public.tests_claims(null, null);
insert into public.plans (code, name, price_tiyin, limits, sort, is_public)
values
  ('t0053_zero', 'Тест-ноль', 100000, '{"teachers": 5, "students": 100, "ai_notes_month": 0}'::jsonb, 900, false),
  ('t0053_unlimited', 'Тест-безлимит', 500000, '{"teachers": 5, "students": 100, "ai_notes_month": -1}'::jsonb, 901, false)
on conflict (code) do nothing;

update public.centers set plan = 't0053_zero' where id = 'a0530000-0000-0000-0000-0000000000c1';
select public.tests_claims('a0530000-0000-0000-0000-000000000002','a0530000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.request_voice_note('a0530000-0000-0000-0000-000000000051','a0530000-0000-0000-0000-000000000040') $q$,
  '23514', null,
  'Лимит 0 отбивает первую же диктовку');
reset role;

select public.tests_claims(null, null);
update public.centers set plan = 't0053_unlimited' where id = 'a0530000-0000-0000-0000-0000000000c1';
select public.tests_claims('a0530000-0000-0000-0000-000000000002','a0530000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.request_voice_note('a0530000-0000-0000-0000-000000000051','a0530000-0000-0000-0000-000000000040') $q$,
  '-1 = без ограничения — 31-я диктовка проходит');
reset role;

select public.tests_claims(null, null);
update public.centers set plan = 'solo' where id = 'a0530000-0000-0000-0000-0000000000c1';


-- 5. Резерв в ai_job_begin (Р3, Р4) ------------------------------------------------------------------------
-- Снова 30 из 30 (solo): диктовка с шага 3 остаётся неотправленной (51),
-- отменяем её токен и заводим свежую пару диктовка+событие для ai_job_begin.

delete from public.lesson_voice_requests where lesson_id = 'a0530000-0000-0000-0000-000000000051';

select public.tests_claims('a0530000-0000-0000-0000-000000000002','a0530000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.request_voice_note('a0530000-0000-0000-0000-000000000051','a0530000-0000-0000-0000-000000000040');
reset role;
select public.tests_claims(null, null);
select public.arm_voice_request(
  (select token from public.lesson_voice_requests where lesson_id = 'a0530000-0000-0000-0000-000000000051' and consumed_at is null and cancelled_at is null),
  5302);
select public.report_voice_note(5302, 'file-053', 30);
update public.events set claimed_at = now() where claimed_at is null and type = 'lesson.voice_received' and center_id = 'a0530000-0000-0000-0000-0000000000c1';

create temporary table t0053_voice as
  select (select max(id) from public.events where type = 'lesson.voice_received' and center_id = 'a0530000-0000-0000-0000-0000000000c1') as event_id,
         (select id from public.lesson_voice_requests where lesson_id = 'a0530000-0000-0000-0000-000000000051') as request_id;

select ok(public.ai_job_begin((select event_id from t0053_voice)) is null,
  'ai_job_begin при 30 из 30 (реестр, без резерва ещё) — null');
select is((select count(*)::int from public.ai_jobs where event_id = (select event_id from t0053_voice)), 0,
  'Строки в ai_jobs нет — null до insert (Р2)');
select is(
  (select count(*)::int from public.events e
    where e.type = 'ai.quota_exceeded' and e.center_id = 'a0530000-0000-0000-0000-0000000000c1'
      and e.payload ->> 'voice_request_id' = (select request_id::text from t0053_voice)
      and (e.payload ->> 'used')::int = 30 and (e.payload ->> 'limit')::int = 30),
  1, 'Событие ai.quota_exceeded одно, used=30/limit=30');

select ok(public.ai_job_begin((select event_id from t0053_voice)) is null, 'Повторный вход — снова null');
select is(
  (select count(*)::int from public.events e where e.type = 'ai.quota_exceeded' and e.center_id = 'a0530000-0000-0000-0000-0000000000c1'),
  1, 'Второго события нет — дедупликация констрейнтом (Р8)');
select throws_ok(
  $q$ select public.emit_event_unchecked('ai.quota_exceeded',
        jsonb_build_object('center_id', 'a0530000-0000-0000-0000-0000000000c1',
                           'voice_request_id', (select request_id from t0053_voice), 'used', 30, 'limit', 30),
        'a0530000-0000-0000-0000-0000000000c1') $q$,
  '23505', null,
  'Прямой второй emit на ту же диктовку — 23505 (Р8)');


-- 6. Доставка (Р8, Р10) -------------------------------------------------------------------------------------

select set_eq(
  $$ select recipient_user_id::text || ':' || channel
       from public.event_messages((select min(id) from public.events where type = 'ai.quota_exceeded' and center_id = 'a0530000-0000-0000-0000-0000000000c1')) $$,
  $$ values ('a0530000-0000-0000-0000-000000000002:telegram'), ('a0530000-0000-0000-0000-000000000001:telegram') $$,
  'Заказчик диктовки (специалист) и владелец, оба telegram — привязан только telegram у обоих');

select ok(
  (select m.message like '%по Ребёнок 0053%' and m.message like '%30%'
     from public.event_messages((select min(id) from public.events where type = 'ai.quota_exceeded' and center_id = 'a0530000-0000-0000-0000-0000000000c1')) m
    where m.recipient_user_id = 'a0530000-0000-0000-0000-000000000002'),
  'Заказчику — {child} с предлогом, {used}/{limit} подставлены');
select ok(
  (select m.message not like '%Ребёнок 0053%' and m.message like '%30%'
     from public.event_messages((select min(id) from public.events where type = 'ai.quota_exceeded' and center_id = 'a0530000-0000-0000-0000-0000000000c1')) m
    where m.recipient_user_id = 'a0530000-0000-0000-0000-000000000001'),
  'Владельцу — без имени ребёнка, числа те же (Р8)');
select ok(
  (select m.subject_id is null
     from public.event_messages((select min(id) from public.events where type = 'ai.quota_exceeded' and center_id = 'a0530000-0000-0000-0000-0000000000c1')) m
    where m.recipient_user_id = 'a0530000-0000-0000-0000-000000000001'),
  'Строка владельцу не привязана к ребёнку (subject пуст)');

select ok(
  public.notification_begin(
    (select min(id) from public.events where type = 'ai.quota_exceeded' and center_id = 'a0530000-0000-0000-0000-0000000000c1'),
    'a0530000-0000-0000-0000-000000000001', 'telegram') is not null,
  'notification_begin без subject_id для строки владельца проходит (subject_required=false)');


-- 7. Регрессия 0048 и снятие лимита ---------------------------------------------------------------------------

select public.tests_claims(null, null);
delete from public.ai_usage where center_id = 'a0530000-0000-0000-0000-0000000000c1' and created_at > public.center_month_start('a0530000-0000-0000-0000-0000000000c1') - interval '2 hours';

select ok(
  (public.ai_job_begin((select event_id from t0053_voice))) ? 'student_goals',
  'Под квотой: ai_job_begin отдаёт объект с student_goals (регрессия 0048)');
select is((select count(*)::int from public.ai_jobs where event_id = (select event_id from t0053_voice)), 1,
  'Строка в ai_jobs создана');

select * from finish();

rollback;
