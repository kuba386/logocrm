-- pgTAP: {debt} утренней сводки и bot_balance считают долг по общему
-- определению «должника» (0077, продолжение 0076).
--
-- Главное, что ловит файл:
--   - сверка с экраном: строка ребёнка в bot_balance (долг за занятия с
--     перерасходом, просрочка отдельно) равна его строке в
--     student_debt_problems() под сессией родителя; {debt} сводки равен
--     student_debt_summary() под сессией владельца — одни и те же цифры на
--     всех поверхностях;
--   - границы: второй центр не виден ни боту, ни сводке; чужой плательщик —
--     не виден; teacher / owner / родитель без payer_id / непривязанный или
--     групповой чат — отказ или пусто, не чужие данные;
--   - родитель в двух центрах получает строки обоих, по центрам;
--   - подмена claims: после вызова claims те же, что были; при принудительном
--     провале самопроверки (чужой sub) сводка не падает, а пишет «не удалось
--     посчитать», бот — 42501;
--   - событие с чужим center_id в payload считается по events.center_id, а
--     payload.debt_tiyin не читается;
--   - гранты: помощники закрыты у всех пяти ролей, bot_balance — у bot_worker.
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(39);


-- 1. Каталог --------------------------------------------------------------------------------------

select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.pronamespace = 'public'::regnamespace
        and p.proname in ('bot_balance_center', 'digest_debt_text')
        and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner $$,
  'Помощники bot_balance_center и digest_debt_text — без EXECUTE ни у кого, кроме владельца (в том числе у bot_worker)');

select ok(
  has_function_privilege('bot_worker', 'public.bot_balance(bigint)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.bot_balance(bigint)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.bot_balance(bigint)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.bot_balance(bigint)', 'EXECUTE')
  and not has_function_privilege('public', 'public.bot_balance(bigint)', 'EXECUTE'),
  'bot_balance после drop + create — по-прежнему только у bot_worker');

select ok(
  (select bool_and(not p.prosecdef and p.proconfig::text like '%search_path%')
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname in ('bot_balance_center', 'digest_debt_text'))
  and (select p.prosecdef and p.provolatile = 's' from pg_proc p where p.oid = 'public.bot_balance(bigint)'::regprocedure),
  'Помощники — SECURITY INVOKER; bot_balance — SECURITY DEFINER и STABLE');


-- 2. Фикстура (как в 0076, префикс 77…) ------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000',
       ('77000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0077@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 9) n;

insert into public.centers (id, name, slug, settings) values
  ('77000000-0000-0000-0000-0000000000c1','Центр 0077',  'centr-0077',   '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('77000000-0000-0000-0000-0000000000c2','Центр 0077 Б','centr-0077-b', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('77000000-0000-0000-0000-00000000aa01','77000000-0000-0000-0000-0000000000c1','Специалист 0077'),
  ('77000000-0000-0000-0000-00000000aa02','77000000-0000-0000-0000-0000000000c2','Специалист Б 0077');

insert into public.payers (id, center_id, full_name, phone) values
  ('77000000-0000-0000-0000-00000000dd01','77000000-0000-0000-0000-0000000000c1','Плательщик 1 0077','+996700007701'),
  ('77000000-0000-0000-0000-00000000dd02','77000000-0000-0000-0000-0000000000c1','Плательщик 2 0077','+996700007702'),
  ('77000000-0000-0000-0000-00000000dd03','77000000-0000-0000-0000-0000000000c2','Плательщик Б 0077','+996700007703');

-- 1 owner c1 · 2 admin · 3 registrar · 4 finance · 5 teacher · 6 parent (payer 1) ·
-- 7 parent (payer 2) · 8 parent без payer_id · 9 owner c2.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('77000000-0000-0000-0000-000000000001','77000000-0000-0000-0000-0000000000c1','owner',    null, null),
  ('77000000-0000-0000-0000-000000000002','77000000-0000-0000-0000-0000000000c1','admin',    null, null),
  ('77000000-0000-0000-0000-000000000003','77000000-0000-0000-0000-0000000000c1','registrar',null, null),
  ('77000000-0000-0000-0000-000000000004','77000000-0000-0000-0000-0000000000c1','finance',  null, null),
  ('77000000-0000-0000-0000-000000000005','77000000-0000-0000-0000-0000000000c1','teacher',  '77000000-0000-0000-0000-00000000aa01', null),
  ('77000000-0000-0000-0000-000000000006','77000000-0000-0000-0000-0000000000c1','parent',   null, '77000000-0000-0000-0000-00000000dd01'),
  ('77000000-0000-0000-0000-000000000007','77000000-0000-0000-0000-0000000000c1','parent',   null, '77000000-0000-0000-0000-00000000dd02'),
  ('77000000-0000-0000-0000-000000000008','77000000-0000-0000-0000-0000000000c1','parent',   null, null),
  ('77000000-0000-0000-0000-000000000009','77000000-0000-0000-0000-0000000000c2','owner',    null, null);

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('77000000-0000-0000-0000-00000000bb01','77000000-0000-0000-0000-0000000000c1','Услуга 50 0077', 50000),
  ('77000000-0000-0000-0000-00000000bb02','77000000-0000-0000-0000-0000000000c1','Услуга 90 0077', 90000),
  ('77000000-0000-0000-0000-00000000bb03','77000000-0000-0000-0000-0000000000c1','Услуга 70 0077', 70000),
  ('77000000-0000-0000-0000-00000000bb04','77000000-0000-0000-0000-0000000000c2','Услуга Б 0077', 33300);

-- sA (payer 1): долг за занятие 500 · sB (payer 2): просрочка по абонементу ·
-- sC (payer 1): чистый исчерпанный остаток · sD (payer 1): просрочка И
-- исчерпанный остаток · sE (payer 1): долг 900, имя длиннее 60 знаков · sF: чистый.
insert into public.students (id, center_id, full_name, payer_id) values
  ('77000000-0000-0000-0000-00000000ee01','77000000-0000-0000-0000-0000000000c1','Аня Долг 0077','77000000-0000-0000-0000-00000000dd01'),
  ('77000000-0000-0000-0000-00000000ee02','77000000-0000-0000-0000-0000000000c1','Боря Просрочка 0077','77000000-0000-0000-0000-00000000dd02'),
  ('77000000-0000-0000-0000-00000000ee03','77000000-0000-0000-0000-0000000000c1','Вера Исчерпан 0077','77000000-0000-0000-0000-00000000dd01'),
  ('77000000-0000-0000-0000-00000000ee04','77000000-0000-0000-0000-0000000000c1','Глеб Просрочен и исчерпан 0077','77000000-0000-0000-0000-00000000dd01'),
  ('77000000-0000-0000-0000-00000000ee05','77000000-0000-0000-0000-0000000000c1',
   'Очень длинное имя ребёнка для проверки обрезки до шестидесяти знаков в Телеграме 0077','77000000-0000-0000-0000-00000000dd01'),
  ('77000000-0000-0000-0000-00000000ee06','77000000-0000-0000-0000-0000000000c1','Чистый 0077','77000000-0000-0000-0000-00000000dd01'),
  -- ee08: второй «чистый» исчерпанный остаток: sort_tiyin = 0, как у Веры, но имя раньше по алфавиту
  -- при большем uuid — порядок «full_name, student_id» не совпадает с порядком вставки и uuid.
  ('77000000-0000-0000-0000-00000000ee08','77000000-0000-0000-0000-0000000000c1','Аня Ранняя 0077','77000000-0000-0000-0000-00000000dd01'),
  ('77000000-0000-0000-0000-00000000ee07','77000000-0000-0000-0000-0000000000c2','Чужой должник 0077','77000000-0000-0000-0000-00000000dd03');

insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at) values
  ('77000000-0000-0000-0000-000000005502','77000000-0000-0000-0000-0000000000c1','77000000-0000-0000-0000-00000000ee02','77000000-0000-0000-0000-00000000dd02', 4, 100000, 25000, current_date - 30),
  ('77000000-0000-0000-0000-000000005503','77000000-0000-0000-0000-0000000000c1','77000000-0000-0000-0000-00000000ee03','77000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30),
  ('77000000-0000-0000-0000-000000005504','77000000-0000-0000-0000-0000000000c1','77000000-0000-0000-0000-00000000ee04','77000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30),
  ('77000000-0000-0000-0000-000000005508','77000000-0000-0000-0000-0000000000c1','77000000-0000-0000-0000-00000000ee08','77000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30);

-- Занятия: один специалист, окна не пересекаются (EXCLUDE 0006).
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at) values
  ('77000000-0000-0000-0000-00000000ff01','77000000-0000-0000-0000-0000000000c1','77000000-0000-0000-0000-00000000aa01','77000000-0000-0000-0000-00000000bb01','77000000-0000-0000-0000-00000000ee01','planned', date_trunc('hour', now()) - interval '2 days', date_trunc('hour', now()) - interval '2 days' + interval '45 minutes'),
  ('77000000-0000-0000-0000-00000000ff03','77000000-0000-0000-0000-0000000000c1','77000000-0000-0000-0000-00000000aa01','77000000-0000-0000-0000-00000000bb03','77000000-0000-0000-0000-00000000ee03','planned', date_trunc('hour', now()) - interval '2 days' - interval '2 hours', date_trunc('hour', now()) - interval '2 days' - interval '2 hours' + interval '45 minutes'),
  ('77000000-0000-0000-0000-00000000ff04','77000000-0000-0000-0000-0000000000c1','77000000-0000-0000-0000-00000000aa01','77000000-0000-0000-0000-00000000bb03','77000000-0000-0000-0000-00000000ee04','planned', date_trunc('hour', now()) - interval '2 days' - interval '4 hours', date_trunc('hour', now()) - interval '2 days' - interval '4 hours' + interval '45 minutes'),
  ('77000000-0000-0000-0000-00000000ff05','77000000-0000-0000-0000-0000000000c1','77000000-0000-0000-0000-00000000aa01','77000000-0000-0000-0000-00000000bb02','77000000-0000-0000-0000-00000000ee05','planned', date_trunc('hour', now()) - interval '2 days' - interval '6 hours', date_trunc('hour', now()) - interval '2 days' - interval '6 hours' + interval '45 minutes'),
  ('77000000-0000-0000-0000-00000000ff08','77000000-0000-0000-0000-0000000000c1','77000000-0000-0000-0000-00000000aa01','77000000-0000-0000-0000-00000000bb03','77000000-0000-0000-0000-00000000ee08','planned', date_trunc('hour', now()) - interval '2 days' - interval '8 hours', date_trunc('hour', now()) - interval '2 days' - interval '8 hours' + interval '45 minutes'),
  -- ff06: второе занятие sD ПОСЛЕ исчерпания абонемента — уйдёт в долг по цене услуги (отдельным insert ниже).
  ('77000000-0000-0000-0000-00000000ff06','77000000-0000-0000-0000-0000000000c1','77000000-0000-0000-0000-00000000aa01','77000000-0000-0000-0000-00000000bb03','77000000-0000-0000-0000-00000000ee04','planned', date_trunc('hour', now()) - interval '2 days' - interval '10 hours', date_trunc('hour', now()) - interval '2 days' - interval '10 hours' + interval '45 minutes'),
  ('77000000-0000-0000-0000-00000000ff07','77000000-0000-0000-0000-0000000000c2','77000000-0000-0000-0000-00000000aa02','77000000-0000-0000-0000-00000000bb04','77000000-0000-0000-0000-00000000ee07','planned', date_trunc('hour', now()) - interval '2 days', date_trunc('hour', now()) - interval '2 days' + interval '45 minutes');

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l
 where l.id::text like '77000000-0000-0000-0000-00000000ff%' and l.id <> '77000000-0000-0000-0000-00000000ff06'
 order by l.starts_at;
-- Второе занятие sD — отдельной командой, после того как первое исчерпало абонемент: тогда
-- триггер посещения не списывает с абонемента (subscriptions_not_overdrawn), а ставит долг.
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l where l.id = '77000000-0000-0000-0000-00000000ff06';

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

create temporary table t_src as
  select (select id from public.payment_sources where center_id = '77000000-0000-0000-0000-0000000000c1' order by sort, code limit 1) as cash_id;
grant select on t_src to public;

-- Платежи по абонементам — от имени владельца (как кнопка на экране): sB внесено
-- 45 000 из 100 000 (просрочка 55 000), sC оплачен полностью, sD внесено 25 000.
select public.tests_claims('77000000-0000-0000-0000-000000000001','77000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.record_payment('77000000-0000-0000-0000-00000000dd02', 45000, 'payment', '77000000-0000-0000-0000-00000000ee02', '77000000-0000-0000-0000-000000005502', (select cash_id from t_src), now() - interval '5 days', 'аванс');
select public.record_payment('77000000-0000-0000-0000-00000000dd01', 70000, 'payment', '77000000-0000-0000-0000-00000000ee03', '77000000-0000-0000-0000-000000005503', (select cash_id from t_src), now() - interval '5 days', 'полностью');
select public.record_payment('77000000-0000-0000-0000-00000000dd01', 25000, 'payment', '77000000-0000-0000-0000-00000000ee04', '77000000-0000-0000-0000-000000005504', (select cash_id from t_src), now() - interval '5 days', 'аванс');
select public.record_payment('77000000-0000-0000-0000-00000000dd01', 70000, 'payment', '77000000-0000-0000-0000-00000000ee08', '77000000-0000-0000-0000-000000005508', (select cash_id from t_src), now() - interval '5 days', 'полностью');
reset role;
select public.tests_claims(null, null);


-- Родитель 6 состоит ещё и во втором центре (плательщик Б): «родитель в двух центрах».
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('77000000-0000-0000-0000-000000000006','77000000-0000-0000-0000-0000000000c2','parent', null, '77000000-0000-0000-0000-00000000dd03');

insert into public.telegram_accounts (user_id, chat_id) values
  ('77000000-0000-0000-0000-000000000001', 770001),
  ('77000000-0000-0000-0000-000000000005', 770005),
  ('77000000-0000-0000-0000-000000000006', 770006),
  ('77000000-0000-0000-0000-000000000007', 770007),
  ('77000000-0000-0000-0000-000000000008', 770008),
  ('77000000-0000-0000-0000-000000000009', 770009);

-- Снимки: экран под сессией (student_debt_problems / student_debt_summary) и бот от postgres
-- при пустых claims — так его будет звать bot_worker.
create temporary table t_prob (who text, student_id uuid, usage_tiyin bigint, overdue_tiyin bigint);
create temporary table t_sum (who text, s jsonb);
grant all on t_prob, t_sum to public;

create or replace function public.t_snapshot(p_who text, p_user uuid, p_center uuid) returns void
  language plpgsql as $$
begin
  perform public.tests_claims(p_user, p_center);
  execute 'set local role authenticated';
  insert into t_prob
    select p_who, student_id, debt_tiyin::bigint + overdrawn_tiyin::bigint, overdue_tiyin::bigint
      from public.student_debt_problems();
  insert into t_sum select p_who, public.student_debt_summary(10);
  execute 'reset role';
  perform public.tests_claims(null, null);
end;
$$;

select public.t_snapshot('parent1', '77000000-0000-0000-0000-000000000006', '77000000-0000-0000-0000-0000000000c1');
select public.t_snapshot('owner',   '77000000-0000-0000-0000-000000000001', '77000000-0000-0000-0000-0000000000c1');
select public.t_snapshot('ownerB',  '77000000-0000-0000-0000-000000000009', '77000000-0000-0000-0000-0000000000c2');

create temporary table t_bot as select * from public.bot_balance(770006);


-- 3. bot_balance: строки и значения ----------------------------------------------------------------

select is((select count(*)::int from t_bot), 7,
  'Родитель в двух центрах: шестеро детей первого и один второго');

select is(
  (select array_agg(n order by n) from (select distinct center_name as n from t_bot) x),
  array['Центр 0077', 'Центр 0077 Б'],
  'Строки по обоим центрам родителя, центры по имени');

select is(
  (select (has_subscription, lessons_left, debt_tiyin, overdue_tiyin)::text from t_bot
    where student_id = '77000000-0000-0000-0000-00000000ee01'),
  '(f,,50000,0)', 'Ребёнок без абонемента: has_subscription = false, остаток NULL, долг 500 сом, просрочки нет');

select is(
  (select (has_subscription, debt_tiyin, overdue_tiyin)::text from t_bot
    where student_id = '77000000-0000-0000-0000-00000000ee04'),
  '(t,70000,45000)', 'Долг за занятие и просрочка по абонементу — отдельными числами, не складываются');

select is(
  (select (has_subscription, lessons_left, debt_tiyin, overdue_tiyin)::text from t_bot
    where student_id = '77000000-0000-0000-0000-00000000ee03'),
  '(t,0,0,0)', 'Исчерпанный остаток — не долг: остаток 0, долга нет');

select is(
  (select (has_subscription, lessons_left, debt_tiyin, overdue_tiyin)::text from t_bot
    where student_id = '77000000-0000-0000-0000-00000000ee06'),
  '(f,,0,0)', 'Чистый ребёнок без абонемента: нули');

select is(
  (select (debt_tiyin, center_name)::text from t_bot where student_id = '77000000-0000-0000-0000-00000000ee07'),
  '(33300,"Центр 0077 Б")', 'Ребёнок второго центра — только под своим центром');

select is(
  (select count(*)::int from t_bot where student_id = '77000000-0000-0000-0000-00000000ee02'),
  0, 'Ребёнок другого плательщика того же центра родителю не виден');


-- 4. Сверка с экраном ----------------------------------------------------------------------------

select set_eq(
  $$ select student_id, debt_tiyin, overdue_tiyin from t_bot
      where center_name = 'Центр 0077' and (debt_tiyin > 0 or overdue_tiyin > 0) $$,
  $$ select student_id, usage_tiyin, overdue_tiyin from t_prob
      where who = 'parent1' and (usage_tiyin > 0 or overdue_tiyin > 0) $$,
  'Бот = строки student_debt_problems() под сессией того же родителя: долг за занятия и просрочка совпадают у каждого ребёнка');

select is(
  (select count(*)::int from t_bot b
     join t_prob p on p.who = 'parent1' and p.student_id = b.student_id
    where b.debt_tiyin <> p.usage_tiyin or b.overdue_tiyin <> p.overdue_tiyin),
  0, 'Расхождений между ботом и экраном нет ни у одного ребёнка родителя');


-- 5. Другие чаты ---------------------------------------------------------------------------------

select is(
  (select array_agg(student_id::text) from public.bot_balance(770007)),
  array['77000000-0000-0000-0000-00000000ee02'],
  'Второй родитель видит только своего ребёнка');

select is(
  (select (debt_tiyin, overdue_tiyin)::text from public.bot_balance(770007)),
  '(0,55000)', 'Просрочка по абонементу второго родителя — отдельной цифрой, долга нет');

select is((select count(*)::int from public.bot_balance(770008)), 0,
  'Родитель без payer_id не получает никого — а не всех детей центра');

select is((select count(*)::int from public.bot_balance(770005)), 0,
  'Специалисту баланс числами не отдаётся');

select is((select count(*)::int from public.bot_balance(770001)), 0,
  'Владельцу /balance не отдаёт детей — для него /debts');

select throws_ok($q$ select * from public.bot_balance(779999) $q$, '42501', 'Чат не привязан',
  'Непривязанный чат — отказ, не пустой список');

select throws_ok($q$ select * from public.bot_balance(-1001234567890) $q$, '42501', null,
  'Групповой чат (отрицательный chat_id) — отказ');

select public.tests_claims('77000000-0000-0000-0000-000000000001', '77000000-0000-0000-0000-0000000000c1');
select throws_ok($q$ select * from public.bot_balance(770006) $q$, '42501', 'Недостаточно прав',
  'Под сессией пользователя bot_balance отказывает: это функция бота, не приложения');
select public.tests_claims(null, null);


-- 6. Подмена claims -------------------------------------------------------------------------------

create temporary table t_before as select current_setting('request.jwt.claims', true) as c;
grant select on t_before to public;

select count(*) from public.bot_balance(770006);
select is(current_setting('request.jwt.claims', true), (select c from t_before),
  'После bot_balance claims те же, что были до вызова');

select is_empty(
  $$ select * from public.bot_balance_center('77000000-0000-0000-0000-000000000001', '77000000-0000-0000-0000-0000000000c1') $$,
  'Помощник для не-родителя (владелец) не отдаёт ничего');
select is_empty(
  $$ select * from public.bot_balance_center('77000000-0000-0000-0000-000000000008', '77000000-0000-0000-0000-0000000000c1') $$,
  'Помощник для родителя без payer_id не отдаёт ничего');
select is(current_setting('request.jwt.claims', true), (select c from t_before),
  'Ранний выход помощника не трогает claims');

-- Провал самопроверки: auth.uid() берёт request.jwt.claim.sub приоритетнее claims.
select set_config('request.jwt.claim.sub', '77000000-0000-0000-0000-0000000000ff', true);
select throws_ok(
  $q$ select * from public.bot_balance_center('77000000-0000-0000-0000-000000000006', '77000000-0000-0000-0000-0000000000c1') $q$,
  '42501', null, 'Провал подмены — 42501, а не пустой ответ, выданный за «всё оплачено»');
select set_config('request.jwt.claim.sub', '', true);


-- 7. {debt} утренней сводки -----------------------------------------------------------------------

insert into public.events (center_id, type, payload) values
  ('77000000-0000-0000-0000-0000000000c1', 'digest.daily',
   jsonb_build_object('center_id', '77000000-0000-0000-0000-0000000000c1', 'date', '2026-06-15',
                      'lessons_today', 5, 'low_balance', 1, 'debt_tiyin', 1, 'installments_overdue', 0)),
  ('77000000-0000-0000-0000-0000000000c2', 'digest.daily',
   jsonb_build_object('center_id', '77000000-0000-0000-0000-0000000000c2', 'date', '2026-06-15',
                      'lessons_today', 0, 'low_balance', 0, 'debt_tiyin', 1, 'installments_overdue', 0)),
  ('77000000-0000-0000-0000-0000000000c1', 'digest.daily',
   jsonb_build_object('center_id', '77000000-0000-0000-0000-0000000000c2', 'date', '2026-06-15',
                      'lessons_today', 5, 'low_balance', 1, 'debt_tiyin', 1, 'installments_overdue', 0));

create temporary table t_ev (name text primary key, id bigint);
grant all on t_ev to public;
insert into t_ev select 'c1',     min(id) from public.events where type = 'digest.daily' and center_id = '77000000-0000-0000-0000-0000000000c1';
insert into t_ev select 'c2',     min(id) from public.events where type = 'digest.daily' and center_id = '77000000-0000-0000-0000-0000000000c2';
insert into t_ev select 'forged', max(id) from public.events where type = 'digest.daily' and center_id = '77000000-0000-0000-0000-0000000000c1';

select is(
  (select message from public.event_messages((select id from t_ev where name = 'c1'))
    where recipient_user_id = '77000000-0000-0000-0000-000000000001' limit 1) ~ 'долг — 2100,00 сом; просрочка по абонементам — 1000,00 сом, просроченных',
  true,
  '{debt}: долг за занятия 2100 (3 ребёнка) и просрочка по абонементам 1000 (2 ребёнка) — двумя суммами, не складываются');

select is(
  (select message from public.event_messages((select id from t_ev where name = 'c1'))
    where recipient_user_id = '77000000-0000-0000-0000-000000000001' limit 1) !~ '0,01 сом',
  true, 'payload.debt_tiyin (там 1) не читается');

select is(
  public.digest_debt_text('77000000-0000-0000-0000-0000000000c1'),
  public.format_som((select (s ->> 'usage_tiyin')::bigint from t_sum where who = 'owner'))
    || '; просрочка по абонементам — ' || public.format_som((select (s ->> 'overdue_tiyin')::bigint from t_sum where who = 'owner')),
  '{debt} сводки = student_debt_summary() под сессией владельца — те же цифры, что на /app/debts и в /debts');

select ok(
  (select message like '%долг — 333,00 сом, просроченных%' and message not like '%просрочка по абонементам%'
     from public.event_messages((select id from t_ev where name = 'c2'))
    where recipient_user_id = '77000000-0000-0000-0000-000000000009' limit 1),
  'Второй центр: только его долг 333,00 сом, без просрочки; долги первого центра не просачиваются');

select is(
  (select message from public.event_messages((select id from t_ev where name = 'forged'))
    where recipient_user_id = '77000000-0000-0000-0000-000000000001' limit 1),
  (select message from public.event_messages((select id from t_ev where name = 'c1'))
    where recipient_user_id = '77000000-0000-0000-0000-000000000001' limit 1),
  'Центр берётся из events.center_id, не из payload: чужой center_id в payload не подменяет долг');

select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'c1'))
    where recipient_user_id in ('77000000-0000-0000-0000-000000000006', '77000000-0000-0000-0000-000000000007')),
  0, 'Сводка с долгами центра родителям не уходит');

select is(current_setting('request.jwt.claims', true), (select c from t_before),
  'После event_messages claims те же, что были');

-- Сбой расчёта: сводка не падает и не врёт нулём.
select set_config('request.jwt.claim.sub', '77000000-0000-0000-0000-0000000000ff', true);
select is(public.digest_debt_text('77000000-0000-0000-0000-0000000000c1'), 'не удалось посчитать — см. /debts',
  'Провал самопроверки подмены — честное «не удалось посчитать», а не «0,00 сом»');
select set_config('request.jwt.claim.sub', '', true);
select is(current_setting('request.jwt.claims', true), (select c from t_before),
  'После провала claims восстановлены откатом подтранзакции');
select ok(public.digest_debt_text('77000000-0000-0000-0000-0000000000c1') like '2100,00 сом; просрочка%',
  'Следующий вызов считает нормально: сбой не залипает');

select is(public.digest_debt_text('77000000-0000-0000-0000-000000000abc'), 'не удалось посчитать — см. /debts',
  'Центр без владельца и администратора — «не удалось посчитать», не ноль');

-- Владелец предпочтительнее администратора: без владельца считает админ.
-- Страж последнего владельца (0024) не даёт удалить единственного — на время шага выключаем.
alter table public.memberships disable trigger memberships_last_owner_guard;
delete from public.memberships
 where user_id = '77000000-0000-0000-0000-000000000001' and center_id = '77000000-0000-0000-0000-0000000000c1';
alter table public.memberships enable trigger memberships_last_owner_guard;
select ok(public.digest_debt_text('77000000-0000-0000-0000-0000000000c1') like '2100,00 сом; просрочка%',
  'Без владельца сводку считает администратор — цифра та же');


-- 8. Предпросмотр шаблона --------------------------------------------------------------------------

select public.tests_claims('77000000-0000-0000-0000-000000000002', '77000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(public.preview_message('{debt}'), '700,00 сом; просрочка по абонементам — 1200,00 сом',
  'Образец {debt} в предпросмотре показывает и просрочку');
reset role;
select public.tests_claims(null, null);

select * from finish();
rollback;
