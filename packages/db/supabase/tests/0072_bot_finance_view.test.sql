-- pgTAP: бот — команды /debts и /cash, только просмотр (0072).
--
-- Заборы (до любого set role): bot_debts / bot_cash исполняет только
-- bot_worker; bot_debts_center (подмена claims), center_payments_day и
-- (student_debt_problems с 0076 открыта authenticated); внешние функции STABLE, помощник —
-- VOLATILE; в источнике помощника нет set_config(..., false) и нет
-- функционального SET "request.jwt.claims" (на Supabase он отвергается).
-- Главное, что ловит файл:
--   - экран и бот считают долг одним кодом: суммы и счётчики помощника
--     равны student_balance под сессией владельца, включая детей за
--     пределами первой десятки;
--   - подмена claims не переживает вызов — ни после успеха, ни после
--     перехваченного исключения (маркер в request.jwt.claims цел);
--   - роли решает база: /debts — owner/admin/registrar/finance, /cash —
--     owner/admin/finance; teacher/parent — 42501 с текстом, не пустота;
--   - смешанные членства: центры без нужной роли и помеченные на удаление
--     пропускаются; чужой центр не виден;
--   - «Поступления» — сумма payments за день центра по его часовому поясу
--     (границы полуночи включительно/исключительно), расходы не влияют,
--     возврат и корректировка входят со знаком, платёж без источника,
--     в архивный и неактивный источник не теряются, сумма по источникам
--     равна итогу;
--   - бот ничего не пишет: events и audit_log до/после равны.
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(72);


-- 1. Заборы по каталогу ---------------------------------------------------------------------------

select ok(
  (select bool_and(has_function_privilege('bot_worker', f, 'EXECUTE')
                   and not has_function_privilege('authenticated', f, 'EXECUTE')
                   and not has_function_privilege('anon', f, 'EXECUTE')
                   and not has_function_privilege('service_role', f, 'EXECUTE')
                   and not has_function_privilege('public', f, 'EXECUTE'))
     from unnest(array['public.bot_debts(bigint)', 'public.bot_cash(bigint)']) f),
  'bot_debts и bot_cash исполняет только bot_worker');

select ok(
  (select bool_and(not has_function_privilege('bot_worker', f, 'EXECUTE')
                   and not has_function_privilege('authenticated', f, 'EXECUTE')
                   and not has_function_privilege('anon', f, 'EXECUTE')
                   and not has_function_privilege('service_role', f, 'EXECUTE')
                   and not has_function_privilege('public', f, 'EXECUTE'))
     from unnest(array[
       'public.bot_debts_center(uuid,uuid)', 'public.center_payments_day(uuid,date)']) f),
  'Помощник подмены claims и center_payments_day — ни у одной роли (student_debt_problems с 0076 открыта authenticated), включая bot_worker и service_role (Р2а)');

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('bot_debts', 'bot_cash') and p.provolatile = 's'),
  array['bot_cash', 'bot_debts'],
  'Внешние функции STABLE — PostgREST исполнит их в транзакции только для чтения (Р4)');

select is(
  (select provolatile::text from pg_proc where oid = 'public.bot_debts_center(uuid,uuid)'::regprocedure), 'v',
  'Помощник с set_config VOLATILE — stable-объявление скрыло бы запись claims от планировщика');

select ok(
  (select bool_and(pg_get_functiondef(p.oid) !~* 'set_config\s*\([^;]*,\s*false\s*\)'
                   and pg_get_functiondef(p.oid) !~* 'set\s+"?request\.jwt\.claims')
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('bot_debts_center', 'bot_debts', 'bot_cash', 'center_payments_day', 'student_debt_problems')),
  'Ни в одной функции 0072 нет set_config(..., false) и SET "request.jwt.claims" (Р2б)');

select ok(
  pg_get_functiondef('public.bot_debts_center(uuid,uuid)'::regprocedure) ~* 'set_config\(''request\.jwt\.claims'',[^;]*true\)'
  and not exists (
    select 1 from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('bot_debts_center', 'bot_debts', 'bot_cash', 'center_payments_day', 'student_debt_problems')
       and coalesce(p.proconfig::text, '') ~ 'request'),
  'Подмена — transaction-local set_config, а не параметр функции (Р2б)');

select ok(
  (select bool_and(p.prosecdef) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname in ('bot_debts', 'bot_cash'))
  and not (select bool_or(p.prosecdef) from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('bot_debts_center', 'center_payments_day', 'student_debt_problems')),
  'bot_debts/bot_cash — security definer; внутренние помощники — invoker: случайный будущий grant не откроет данные (Р13)');


-- 2. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000',
       ('72000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0072@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 12) n;

-- c1 — основной, Asia/Bishkek; c2 — другой центр; c3 — помечен на удаление;
-- c4 — trial истёк (центр только для чтения).
insert into public.centers (id, name, slug, trial_ends_at, settings) values
  ('72000000-0000-0000-0000-0000000000c1','Центр 0072',   'centr-0072',   now() + interval '7 days', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('72000000-0000-0000-0000-0000000000c2','Центр 0072 Б', 'centr-0072-b', now() + interval '7 days', '{"timezone":"America/New_York"}'::jsonb),
  ('72000000-0000-0000-0000-0000000000c3','Центр 0072 У', 'centr-0072-d', now() + interval '7 days', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('72000000-0000-0000-0000-0000000000c4','Центр 0072 И', 'centr-0072-x', now() - interval '2 days', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('72000000-0000-0000-0000-00000000aa01','72000000-0000-0000-0000-0000000000c1','Специалист 0072'),
  ('72000000-0000-0000-0000-00000000aa02','72000000-0000-0000-0000-0000000000c2','Специалист Б 0072');

insert into public.payers (id, center_id, full_name, phone) values
  ('72000000-0000-0000-0000-00000000dd01','72000000-0000-0000-0000-0000000000c1','Плательщик 0072','+996700007270'),
  ('72000000-0000-0000-0000-00000000dd02','72000000-0000-0000-0000-0000000000c2','Плательщик Б 0072','+996700007271');

-- 1 owner c1 · 2 admin c1 · 3 registrar c1 · 4 finance c1 · 5 teacher c1 ·
-- 6 parent c1 · 7 owner c2 · 8 owner c4 (read-only) · 9 teacher c1 + finance
-- c2 · 10 owner c1 + owner c3 (удалён) · 11 owner только c3.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1','owner',    null, null),
  ('72000000-0000-0000-0000-000000000002','72000000-0000-0000-0000-0000000000c1','admin',    null, null),
  ('72000000-0000-0000-0000-000000000003','72000000-0000-0000-0000-0000000000c1','registrar',null, null),
  ('72000000-0000-0000-0000-000000000004','72000000-0000-0000-0000-0000000000c1','finance',  null, null),
  ('72000000-0000-0000-0000-000000000005','72000000-0000-0000-0000-0000000000c1','teacher',  '72000000-0000-0000-0000-00000000aa01', null),
  ('72000000-0000-0000-0000-000000000006','72000000-0000-0000-0000-0000000000c1','parent',   null, '72000000-0000-0000-0000-00000000dd01'),
  ('72000000-0000-0000-0000-000000000007','72000000-0000-0000-0000-0000000000c2','owner',    null, null),
  ('72000000-0000-0000-0000-000000000008','72000000-0000-0000-0000-0000000000c4','owner',    null, null),
  ('72000000-0000-0000-0000-000000000009','72000000-0000-0000-0000-0000000000c1','teacher',  null, null),
  ('72000000-0000-0000-0000-000000000009','72000000-0000-0000-0000-0000000000c2','finance',  null, null),
  ('72000000-0000-0000-0000-000000000010','72000000-0000-0000-0000-0000000000c1','owner',    null, null),
  ('72000000-0000-0000-0000-000000000010','72000000-0000-0000-0000-0000000000c3','owner',    null, null),
  ('72000000-0000-0000-0000-000000000011','72000000-0000-0000-0000-0000000000c3','owner',    null, null),
  ('72000000-0000-0000-0000-000000000012','72000000-0000-0000-0000-0000000000c1','owner',    null, null),
  ('72000000-0000-0000-0000-000000000012','72000000-0000-0000-0000-0000000000c2','owner',    null, null);

-- Центр c3 помечен на удаление (0056: deleted_at).
update public.centers set deleted_at = now() where id = '72000000-0000-0000-0000-0000000000c3';

-- Услуги c1: bb01..bb12 по 10 000 · i тыйынов (для порядка топа), bb13 — 70 000.
insert into public.services (id, center_id, name, default_price_tiyin)
select ('72000000-0000-0000-0000-00000000bb' || lpad(i::text, 2, '0'))::uuid,
       '72000000-0000-0000-0000-0000000000c1', 'Услуга ' || i || ' 0072', case when i <= 12 then i * 10000 else 70000 end
  from generate_series(1, 13) i;
insert into public.services (id, center_id, name, default_price_tiyin) values
  ('72000000-0000-0000-0000-00000000bb21','72000000-0000-0000-0000-0000000000c2','Услуга Б 0072', 33300);

-- Дети c1: ee01..ee12 — должники за занятия (долг = i · 10 000); ee13 —
-- просрочка по абонементу; ee14 — остаток исчерпан; ee15 — должник, которого
-- потом заархивируют; ee16 — чистый. Перерасхода нет: констрейнт
-- subscriptions_not_overdrawn (0015) не даёт списать больше абонемента, так что
-- overdrawn_tiyin достижим только через заморозку/возврат — здесь не строится.
insert into public.students (id, center_id, full_name, payer_id)
select ('72000000-0000-0000-0000-00000000ee' || lpad(i::text, 2, '0'))::uuid,
       '72000000-0000-0000-0000-0000000000c1', 'Долг ' || lpad(i::text, 2, '0') || ' 0072',
       '72000000-0000-0000-0000-00000000dd01'
  from generate_series(1, 12) i;
insert into public.students (id, center_id, full_name, payer_id) values
  ('72000000-0000-0000-0000-00000000ee13','72000000-0000-0000-0000-0000000000c1','Просрочка 0072',  '72000000-0000-0000-0000-00000000dd01'),
  ('72000000-0000-0000-0000-00000000ee14','72000000-0000-0000-0000-0000000000c1','Исчерпан 0072',   '72000000-0000-0000-0000-00000000dd01'),
  ('72000000-0000-0000-0000-00000000ee15','72000000-0000-0000-0000-0000000000c1','Архивный 0072',   '72000000-0000-0000-0000-00000000dd01'),
  ('72000000-0000-0000-0000-00000000ee16','72000000-0000-0000-0000-0000000000c1','Чистый 0072',     '72000000-0000-0000-0000-00000000dd01'),
  ('72000000-0000-0000-0000-00000000ee18','72000000-0000-0000-0000-0000000000c1','Просрочен и исчерпан 0072', '72000000-0000-0000-0000-00000000dd01'),
  ('72000000-0000-0000-0000-00000000ee21','72000000-0000-0000-0000-0000000000c2','Чужой должник 0072','72000000-0000-0000-0000-00000000dd02');

-- Абонементы: ee13 — 4 занятия за 100 000; ee14 — одно занятие за 70 000
-- (оплатит полностью).
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at) values
  ('72000000-0000-0000-0000-000000005513','72000000-0000-0000-0000-0000000000c1','72000000-0000-0000-0000-00000000ee13',
   '72000000-0000-0000-0000-00000000dd01', 4, 100000, 25000, current_date - 30),
  ('72000000-0000-0000-0000-000000005514','72000000-0000-0000-0000-0000000000c1','72000000-0000-0000-0000-00000000ee14',
   '72000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30),
  -- ee18: одно занятие за 70 000, внесено 25 000 и занятие использовано —
  -- просрочка 45 000 И исчерпанный остаток одновременно (Р14).
  ('72000000-0000-0000-0000-000000005518','72000000-0000-0000-0000-0000000000c1','72000000-0000-0000-0000-00000000ee18',
   '72000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30);

-- Занятия: номер k → старт = час назад на k·2 часа от «позавчера»; один
-- специалист, окна не пересекаются (EXCLUDE 0006). Услуга — та же, что номер
-- ребёнка, чтобы долг был i · 10 000.
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at)
select ('72000000-0000-0000-0000-00000000ff' || lpad(k::text, 2, '0'))::uuid,
       '72000000-0000-0000-0000-0000000000c1', '72000000-0000-0000-0000-00000000aa01',
       ('72000000-0000-0000-0000-00000000bb' || lpad(least(k, 13)::text, 2, '0'))::uuid,
       ('72000000-0000-0000-0000-00000000ee' || lpad(k::text, 2, '0'))::uuid,
       'planned',
       date_trunc('hour', now()) - interval '2 days' - k * interval '2 hours',
       date_trunc('hour', now()) - interval '2 days' - k * interval '2 hours' + interval '45 minutes'
  from generate_series(1, 18) k
 where k in (1,2,3,4,5,6,7,8,9,10,11,12, 14, 15, 18);
-- 14 — ee14, 15 — ee15, 18 — ee18.
update public.lessons set service_id = '72000000-0000-0000-0000-00000000bb01'
 where id = '72000000-0000-0000-0000-00000000ff15';
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at) values
  ('72000000-0000-0000-0000-00000000ff31','72000000-0000-0000-0000-0000000000c2','72000000-0000-0000-0000-00000000aa02',
   '72000000-0000-0000-0000-00000000bb21','72000000-0000-0000-0000-00000000ee21','planned',
   date_trunc('hour', now()) - interval '2 days', date_trunc('hour', now()) - interval '2 days' + interval '45 minutes');

insert into public.telegram_accounts (user_id, chat_id) values
  ('72000000-0000-0000-0000-000000000001', 720001),
  ('72000000-0000-0000-0000-000000000002', 720002),
  ('72000000-0000-0000-0000-000000000003', 720003),
  ('72000000-0000-0000-0000-000000000004', 720004),
  ('72000000-0000-0000-0000-000000000005', 720005),
  ('72000000-0000-0000-0000-000000000006', 720006),
  ('72000000-0000-0000-0000-000000000007', 720007),
  ('72000000-0000-0000-0000-000000000008', 720008),
  ('72000000-0000-0000-0000-000000000009', 720009),
  ('72000000-0000-0000-0000-000000000010', 720010),
  ('72000000-0000-0000-0000-000000000011', 720011),
  ('72000000-0000-0000-0000-000000000012', 720012);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

-- Отметки «был» без сессии (триггеры посещения эмитят через emit_event_internal,
-- 0071): долг без абонемента у ee01..ee12 и ee15; ee14 списывается с абонемента.
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l
 where l.center_id = '72000000-0000-0000-0000-0000000000c1'
   and l.id <> '72000000-0000-0000-0000-00000000ff31'
 order by l.starts_at;
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l where l.id = '72000000-0000-0000-0000-00000000ff31';

create temporary table t_src as
  select (select id from public.payment_sources where center_id = '72000000-0000-0000-0000-0000000000c1' order by sort, code limit 1) as cash_id,
         (select id from public.payment_sources where center_id = '72000000-0000-0000-0000-0000000000c2' order by sort, code limit 1) as cash_b_id;
insert into public.payment_sources (id, center_id, code, name, is_active, sort) values
  ('72000000-0000-0000-0000-000000005a01','72000000-0000-0000-0000-0000000000c1','arch0072','Архивный источник 0072', true, 900),
  ('72000000-0000-0000-0000-000000005a02','72000000-0000-0000-0000-0000000000c1','inact0072','Неактивный источник 0072', false, 901);
-- Центр Б: восемь мелких источников сверх основного — источников девять, в /cash
-- показываются восемь крупнейших и строка «Прочие источники» (Р15).
insert into public.payment_sources (center_id, code, name, is_active, sort)
select '72000000-0000-0000-0000-0000000000c2', 'm0072' || n, 'Мелкий источник ' || n || ' 0072', true, 800 + n
  from generate_series(1, 8) n;
create temporary table t_cat as
  select id from public.expense_categories where center_id = '72000000-0000-0000-0000-0000000000c1' order by 1 limit 1;
grant select on t_src, t_cat to public;

-- Платежи — обычным путём, от имени владельца (как кнопка на экране).
-- Абонементные платежи — пять дней назад: иначе они попали бы в «сегодня» и
-- сломали бы арифметику раздела 6.
select public.tests_claims('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select public.record_payment('72000000-0000-0000-0000-00000000dd01', 45000, 'payment',
  '72000000-0000-0000-0000-00000000ee13', '72000000-0000-0000-0000-000000005513', (select cash_id from t_src), now() - interval '5 days', 'аванс просрочки');
select public.record_payment('72000000-0000-0000-0000-00000000dd01', 70000, 'payment',
  '72000000-0000-0000-0000-00000000ee14', '72000000-0000-0000-0000-000000005514', (select cash_id from t_src), now() - interval '5 days', 'абонемент исчерпанного');
select public.record_payment('72000000-0000-0000-0000-00000000dd01', 25000, 'payment',
  '72000000-0000-0000-0000-00000000ee18', '72000000-0000-0000-0000-000000005518', (select cash_id from t_src), now() - interval '5 days', 'аванс просроченного и исчерпанного');

-- Платежи дня. Полночь центра — граница суток: 00:00:00 сегодня — сегодня,
-- 23:59:59 вчера — вчера.
select public.record_payment('72000000-0000-0000-0000-00000000dd01', 30000, 'payment', null, null, (select cash_id from t_src),
  (public.center_today('72000000-0000-0000-0000-0000000000c1')::timestamp at time zone 'Asia/Bishkek'), 'сегодня 00:00:00');
select public.record_payment('72000000-0000-0000-0000-00000000dd01', 20000, 'payment', null, null, null,
  (public.center_today('72000000-0000-0000-0000-0000000000c1')::timestamp at time zone 'Asia/Bishkek') + interval '1 second', 'без источника');
select public.record_payment('72000000-0000-0000-0000-00000000dd01', 15000, 'payment', null, null, '72000000-0000-0000-0000-000000005a01',
  (public.center_today('72000000-0000-0000-0000-0000000000c1')::timestamp at time zone 'Asia/Bishkek') + interval '2 seconds', 'в архивный');
select public.record_payment('72000000-0000-0000-0000-00000000dd01', 7000, 'payment', null, null, '72000000-0000-0000-0000-000000005a02',
  (public.center_today('72000000-0000-0000-0000-0000000000c1')::timestamp at time zone 'Asia/Bishkek') + interval '3 seconds', 'в неактивный');
select public.record_payment('72000000-0000-0000-0000-00000000dd01', -5000, 'refund', null, null, (select cash_id from t_src),
  (public.center_today('72000000-0000-0000-0000-0000000000c1')::timestamp at time zone 'Asia/Bishkek') + interval '4 seconds', 'возврат');
select public.record_payment('72000000-0000-0000-0000-00000000dd01', -1000, 'correction', null, null, null,
  (public.center_today('72000000-0000-0000-0000-0000000000c1')::timestamp at time zone 'Asia/Bishkek') + interval '5 seconds', 'корректировка');
select public.record_payment('72000000-0000-0000-0000-00000000dd01', 50000, 'payment', null, null, (select cash_id from t_src),
  (public.center_today('72000000-0000-0000-0000-0000000000c1')::timestamp at time zone 'Asia/Bishkek') - interval '1 second', 'вчера 23:59:59');
-- Расход сегодня: в «Поступления» не входит.
select public.record_expense((select id from t_cat), 40000, 'expense', (select cash_id from t_src), null, 'расход');

select public.tests_claims('72000000-0000-0000-0000-000000000007','72000000-0000-0000-0000-0000000000c2');
select public.record_payment('72000000-0000-0000-0000-00000000dd02', 99900, 'payment', null, null, (select cash_b_id from t_src),
  (public.center_today('72000000-0000-0000-0000-0000000000c2')::timestamp at time zone 'America/New_York') + interval '1 second', 'чужой центр');
select public.record_payment('72000000-0000-0000-0000-00000000dd02', 1000, 'payment', null, null, s.id,
  (public.center_today('72000000-0000-0000-0000-0000000000c2')::timestamp at time zone 'America/New_York') + interval '2 seconds', 'мелкий')
  from public.payment_sources s
 where s.center_id = '72000000-0000-0000-0000-0000000000c2' and s.code like 'm0072%';
reset role;

-- Архивный должник: сначала отметка, потом архив — из набора уходит (0031).
update public.students set deleted_at = now() where id = '72000000-0000-0000-0000-00000000ee15';
-- Источник архивируется ПОСЛЕ платежа в него (archive — deleted_at, 0027): его
-- платежи и название остаются в итоге и в разбивке (Р9).
update public.payment_sources set deleted_at = now() where id = '72000000-0000-0000-0000-000000005a01';
select public.tests_claims(null, null);

-- Ожидаемое считаем той самой сессией, что видит экран: под владельцем c1.
create temporary table t_exp (usage_n int, usage_tiyin bigint, overdue_n int, overdue_tiyin bigint, zero_n int, prob_n int);
grant all on t_exp to public;
create temporary table t_top (ord int, full_name text);
grant all on t_top to public;
create temporary table t_topx (ord int, full_name text);
grant all on t_topx to public;
select public.tests_claims('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_exp
  select count(*) filter (where debt_tiyin + overdrawn_tiyin > 0),
         coalesce(sum(debt_tiyin + overdrawn_tiyin), 0),
         count(*) filter (where subscription_overdue_tiyin > 0),
         coalesce(sum(subscription_overdue_tiyin), 0),
         count(*) filter (where active_subscription_id is not null and lessons_left = 0
                             and debt_tiyin = 0 and overdrawn_tiyin = 0 and subscription_overdue_tiyin = 0),
         count(*) filter (where debt_tiyin > 0 or overdrawn_tiyin > 0 or subscription_overdue_tiyin > 0
                             or (active_subscription_id is not null and lessons_left = 0))
    from public.student_balance;
insert into t_topx
  select r.ord::int, r.full_name
    from (select row_number() over (order by greatest(b.debt_tiyin + b.overdrawn_tiyin, b.subscription_overdue_tiyin) desc, s.full_name) as ord,
                 s.full_name
            from public.student_balance b
            join public.students_brief() s on s.id = b.student_id
           where b.debt_tiyin > 0 or b.overdrawn_tiyin > 0 or b.subscription_overdue_tiyin > 0
              or (b.active_subscription_id is not null and b.lessons_left = 0)) r
   where r.ord <= 10;
reset role;
select public.tests_claims(null, null);

select ok(
  (select usage_n >= 12 and overdue_n = 2 and zero_n = 1 and prob_n >= 15 from t_exp),
  'Фикстура: не меньше 12 должников за занятия (в топ-10 не все), две просрочки, ровно один «чистый» исчерпанный остаток — у ребёнка с просрочкой и исчерпанным абонементом метка не двоится (Р14)');


-- 3. Помощник = экран (Р1, Р5, Р6) ----------------------------------------------------------------

create temporary table t_evt as
  select (select count(*) from public.events) as ev, (select count(*) from public.audit_log) as au;

select is(
  (select public.bot_debts_center('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1') ->> 'usage_n')::int,
  (select usage_n from t_exp), 'Число должников за занятия равно student_balance под сессией владельца');
select is(
  (select public.bot_debts_center('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1') ->> 'usage_tiyin')::bigint,
  (select usage_tiyin from t_exp), 'Сумма долга за занятия (долг + перерасход) — та же, что на экране, включая детей вне первой десятки');
select is(
  (select public.bot_debts_center('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1') ->> 'overdue_tiyin')::bigint,
  (select overdue_tiyin from t_exp), 'Сумма просрочки по абонементам — та же');
select is(
  (select public.bot_debts_center('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1') ->> 'overdue_n')::int,
  (select overdue_n from t_exp), 'Число детей с просрочкой — то же');
select is(
  (select public.bot_debts_center('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1') ->> 'zero_n')::int,
  (select zero_n from t_exp), 'Исчерпанный остаток считается отдельно и в должников не входит');
select is(
  (select jsonb_array_length(public.bot_debts_center('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1') -> 'top')),
  10, 'Топ — ровно десять, итоги по всем');

insert into t_top
  select e.n::int, e.t ->> 'name'
    from jsonb_array_elements(public.bot_debts_center('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1') -> 'top')
         with ordinality as e(t, n);

select is(
  (select array_agg(full_name order by ord) from t_top), (select array_agg(full_name order by ord) from t_topx),
  'Топ-10 в том же порядке, что ранжирование student_balance под сессией владельца');
select is((select full_name from t_top where ord = 1), 'Долг 12 0072', 'Первый в топе — самый большой долг');
select ok(
  (select ord from t_top where full_name = 'Просрочка 0072') < (select ord from t_top where full_name = 'Долг 05 0072')
  and (select ord from t_top where full_name = 'Просрочка 0072') > (select ord from t_top where full_name = 'Долг 06 0072'),
  'Порядок по большему из двух корзин: просрочка 55 000 — между долгом 60 000 и долгом 50 000, а не по сумме корзин (Р6)');
select is((select ord from t_top where full_name = 'Просрочен и исчерпан 0072'), 10,
  'Просрочен и исчерпан (45 000) — десятый, после долга 50 000 (Р14: считается по просрочке)');
select ok(not exists (select 1 from t_top where full_name = 'Долг 01 0072'), 'Малые долги остались за пределами топа, но в итоги вошли (сверено выше)');
select ok(
  not exists (select 1 from t_top where full_name in ('Архивный 0072', 'Чистый 0072', 'Исчерпан 0072')),
  'Архивный должник, чистый ребёнок и «остаток исчерпан» без долга в топ долгов не попадают');

select is(
  (select public.bot_debts_center('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c2')),
  null, 'Помощник для центра, где у пользователя нет подходящей роли, возвращает null до подмены');
select is(
  (select public.bot_debts_center('72000000-0000-0000-0000-000000000005','72000000-0000-0000-0000-0000000000c1')),
  null, 'Специалист — null, подмена не начиналась');


-- 4. Подмена не переживает вызов (Р2в) -----------------------------------------------------------

select set_config('request.jwt.claims', '{"sentinel":"0072"}', true);
select public.bot_debts_center('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1');
select is(current_setting('request.jwt.claims', true), '{"sentinel":"0072"}',
  'После успешного вызова request.jwt.claims — прежний, маркер цел');
select is(auth.uid(), null::uuid, 'И auth.uid() снова пуст');

-- Р3: подмена «не сработала». request.jwt.claim.sub (единственное число)
-- auth.uid() читает раньше claims — как чужая подпись при неверной сборке
-- сессии. Без самопроверки сессионные функции молча вернули бы пусто.
select set_config('request.jwt.claim.sub', '72000000-0000-0000-0000-000000000002', true);
select throws_ok(
  $q$ select public.bot_debts_center('72000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-0000000000c1') $q$,
  '42501', 'Не удалось определить права в центре — обратитесь к администратору',
  'Подмена не удалась (auth.uid() не равен пользователю чата) — громкий отказ, а не «долгов нет» (Р3)');
select is(current_setting('request.jwt.claims', true), '{"sentinel":"0072"}',
  'После отказа claims прежние — откат подтранзакции их вернул');
select set_config('request.jwt.claim.sub', '', true);
select public.tests_claims(null, null);


-- 5. Бот: тексты и права -------------------------------------------------------------------------

create temporary table t_out (who int, kind text, n int, center_name text, message text);
grant all on t_out to public;
create temporary table t_ref (kind text, k text, v text);
grant all on t_ref to public;
insert into t_ref
  select 'debts', 'usage', 'Долг за занятия: ' || public.format_som(usage_tiyin) || ' (детей: ' || usage_n || ')' from t_exp
  union all
  select 'debts', 'overdue', 'Просрочка по абонементам: ' || public.format_som(overdue_tiyin) || ' (детей: ' || overdue_n || ')' from t_exp
  union all
  select 'debts', 'zero', 'Остаток исчерпан у детей: ' || zero_n from t_exp
  union all
  select 'debts', 'top1', '1. Долг 12 0072 — долг ' || public.format_som(120000)
  union all
  select 'cash', 'today', 'Поступления сегодня (' || to_char(public.center_today('72000000-0000-0000-0000-0000000000c1'), 'DD.MM') || '): '
                          || public.format_som(66000) || ', операций: 6'
  union all
  select 'cash', 'none', 'Поступлений сегодня (' || to_char(public.center_today('72000000-0000-0000-0000-0000000000c4'), 'DD.MM') || ') нет.';

insert into t_out select 1, 'debts', row_number() over (), center_name, message from public.bot_debts(720001);
insert into t_out select 2, 'debts', row_number() over (), center_name, message from public.bot_debts(720002);
insert into t_out select 3, 'debts', row_number() over (), center_name, message from public.bot_debts(720003);
insert into t_out select 4, 'debts', row_number() over (), center_name, message from public.bot_debts(720004);
insert into t_out select 7, 'debts', row_number() over (), center_name, message from public.bot_debts(720007);
insert into t_out select 8, 'debts', row_number() over (), center_name, message from public.bot_debts(720008);
insert into t_out select 9, 'debts', row_number() over (), center_name, message from public.bot_debts(720009);
insert into t_out select 10, 'debts', row_number() over (), center_name, message from public.bot_debts(720010);
insert into t_out select 12, 'debts', row_number() over (), center_name, message from public.bot_debts(720012);
insert into t_out select 12, 'cash', row_number() over (), center_name, message from public.bot_cash(720012);
insert into t_out select 1, 'cash', row_number() over (), center_name, message from public.bot_cash(720001);
insert into t_out select 2, 'cash', row_number() over (), center_name, message from public.bot_cash(720002);
insert into t_out select 4, 'cash', row_number() over (), center_name, message from public.bot_cash(720004);
insert into t_out select 7, 'cash', row_number() over (), center_name, message from public.bot_cash(720007);
insert into t_out select 8, 'cash', row_number() over (), center_name, message from public.bot_cash(720008);
insert into t_out select 9, 'cash', row_number() over (), center_name, message from public.bot_cash(720009);
insert into t_out select 10, 'cash', row_number() over (), center_name, message from public.bot_cash(720010);

select throws_ok($q$ select * from public.bot_debts(720005) $q$, '42501',
  'Команда доступна владельцу, администратору, регистратору и бухгалтеру', '/debts специалисту — 42501 с текстом, не пустой ответ');
select throws_ok($q$ select * from public.bot_debts(720006) $q$, '42501',
  'Команда доступна владельцу, администратору, регистратору и бухгалтеру', '/debts родителю — 42501');
select throws_ok($q$ select * from public.bot_cash(720005) $q$, '42501',
  'Команда доступна владельцу, администратору и бухгалтеру', '/cash специалисту — 42501');
select throws_ok($q$ select * from public.bot_cash(720006) $q$, '42501',
  'Команда доступна владельцу, администратору и бухгалтеру', '/cash родителю — 42501');
select throws_ok($q$ select * from public.bot_cash(720003) $q$, '42501',
  'Команда доступна владельцу, администратору и бухгалтеру', '/cash регистратору — 42501: касса — только owner/admin/finance, как cash_by_source');
select throws_ok($q$ select * from public.bot_debts(720011) $q$, '42501', null,
  'Владелец только удалённого центра — отказ: помеченный на удаление центр не считается');
select throws_ok($q$ select * from public.bot_cash(720011) $q$, '42501', null, '/cash владельца удалённого центра — отказ');
select throws_ok($q$ select * from public.bot_debts(-100720001) $q$, '42501',
  'Команда доступна только в личной переписке с ботом', 'Групповой чат (отрицательный chat_id) — /debts отказ (Р12)');
select throws_ok($q$ select * from public.bot_cash(-100720001) $q$, '42501',
  'Команда доступна только в личной переписке с ботом', 'Групповой чат — /cash отказ (Р12)');
select throws_ok($q$ select * from public.bot_debts(999072) $q$, '42501', 'Чат не привязан', 'Непривязанный чат — 42501');
select throws_ok($q$ select * from public.bot_cash(999072) $q$, '42501', 'Чат не привязан', '/cash непривязанного чата — 42501');

select public.tests_claims('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-0000000000c1');
select throws_ok($q$ select * from public.bot_debts(720001) $q$, '42501', 'Недостаточно прав',
  'Вызов с живой сессией пользователя отвергается: функции только для контура бота (Р2д)');
select public.tests_claims(null, null);

select is((select count(*)::int from t_out where kind = 'debts' and who = 1), 1, '/debts владельца — одно сообщение на центр');
select ok(
  (select position((select v from t_ref where k = 'usage') in message) > 0
      and position((select v from t_ref where k = 'overdue') in message) > 0
      and position((select v from t_ref where k = 'zero') in message) > 0
      and position((select v from t_ref where k = 'top1') in message) > 0
      and position('Первые 10 (по размеру):' in message) > 0
      and position('Просрочен и исчерпан 0072 — просрочка ' in message) > 0
      and position('остаток исчерпан' in message) = 0
      and position('Чужой должник' in message) = 0
      and position('Архивный 0072' in message) = 0
      and length(message) < 4000
     from t_out where kind = 'debts' and who = 1),
  'Текст: два итога раздельно, «остаток исчерпан», первые 10, лидер с деньгами из базы; чужого ребёнка и архивного нет');
select is(
  (select message from t_out where kind = 'debts' and who = 3),
  (select message from t_out where kind = 'debts' and who = 1),
  'Регистратор видит те же долги, что владелец');
select is(
  (select message from t_out where kind = 'debts' and who = 2),
  (select message from t_out where kind = 'debts' and who = 1), 'Администратор — тот же текст');
select is(
  (select message from t_out where kind = 'debts' and who = 4),
  (select message from t_out where kind = 'debts' and who = 1), 'Бухгалтер — тот же текст');
select ok(
  (select position('Чужой должник 0072' in message) > 0
      and position('Долг ' in message) > 0 and position('Долг 12 0072' in message) = 0
     from t_out where kind = 'debts' and who = 7),
  'Владелец другого центра видит только своего должника');
select is(
  (select center_name from t_out where kind = 'debts' and who = 9), 'Центр 0072 Б',
  'Смешанные членства: специалист c1 + бухгалтер c2 получает только центр Б (роль в c1 не подходит)');
select is((select count(*)::int from t_out where kind = 'debts' and who = 9), 1, 'Ровно один центр');
select is(
  (select array_agg(center_name order by n) from t_out where kind = 'debts' and who = 12),
  array['Центр 0072', 'Центр 0072 Б'],
  'Владелец двух живых центров получает два сообщения в порядке названий (цикл не обрывается на первом)');
select ok(
  (select (select message from t_out where kind = 'debts' and who = 12 and n = 1) = (select message from t_out where kind = 'debts' and who = 1)
      and (select message from t_out where kind = 'debts' and who = 12 and n = 2) = (select message from t_out where kind = 'debts' and who = 7)),
  'Каждое сообщение — по своему центру: подмена делается заново на каждой итерации');
select ok(
  (select (select message from t_out where kind = 'cash' and who = 12 and n = 1) = (select message from t_out where kind = 'cash' and who = 1)
      and (select message from t_out where kind = 'cash' and who = 12 and n = 2) = (select message from t_out where kind = 'cash' and who = 7)),
  '/cash владельца двух центров — тоже по центрам, суммы не смешиваются');
select is(
  (select center_name from t_out where kind = 'debts' and who = 10), 'Центр 0072',
  'Владелец c1 + удалённого c3: удалённый пропущен');
select is((select count(*)::int from t_out where kind = 'debts' and who = 10), 1, 'Удалённый центр не даёт второго сообщения');
select is(
  (select message from t_out where kind = 'debts' and who = 8),
  'Центр 0072 И' || E'\nДолгов, просрочек и исчерпанных остатков нет.',
  'Центр только для чтения (истёк trial) читается; без долгов — явная строка, а не пустота');


-- 6. /cash: «Поступления» за день центра ------------------------------------------------------------

select is(
  (select public.center_payments_day('72000000-0000-0000-0000-0000000000c1', public.center_today('72000000-0000-0000-0000-0000000000c1')) ->> 'total_tiyin')::bigint,
  66000::bigint,
  'Поступления сегодня: 30 000 + 20 000 + 15 000 + 7 000 − 5 000 возврат − 1 000 корректировка; расход 40 000 не вычитается, вчерашние 50 000 не входят');
select is(
  (select public.center_payments_day('72000000-0000-0000-0000-0000000000c1', public.center_today('72000000-0000-0000-0000-0000000000c1')) ->> 'ops')::int,
  6, 'Операций шесть: платежи 4, возврат, корректировка');
select is(
  (select (public.center_payments_day('72000000-0000-0000-0000-0000000000c1', public.center_today('72000000-0000-0000-0000-0000000000c1') - 1) ->> 'total_tiyin')::bigint),
  50000::bigint, 'Вчера: 23:59:59 центра — вчерашний день; 00:00:00 сегодняшнего в него не попадает');
select is(
  (select coalesce(sum((s ->> 'total_tiyin')::bigint), 0)::bigint from jsonb_array_elements(
     public.center_payments_day('72000000-0000-0000-0000-0000000000c1', public.center_today('72000000-0000-0000-0000-0000000000c1')) -> 'by_source') s),
  66000::bigint, 'Сумма по источникам равна итогу — ни один платёж не потерян');
select is(
  (select array_agg((s ->> 'name') order by n) from jsonb_array_elements(
     public.center_payments_day('72000000-0000-0000-0000-0000000000c1', public.center_today('72000000-0000-0000-0000-0000000000c1')) -> 'by_source')
     with ordinality as e(s, n)),
  (select array[(select name from public.payment_sources where id = (select cash_id from t_src)),
                'Без источника', 'Архивный источник 0072', 'Неактивный источник 0072']),
  'Источники: обычный, «Без источника», архивный и неактивный — по убыванию суммы; названия не теряются');
select is(
  (select (public.center_payments_day('72000000-0000-0000-0000-0000000000c2', public.center_today('72000000-0000-0000-0000-0000000000c2')) ->> 'total_tiyin')::bigint),
  107900::bigint, 'Центр с другим поясом (Нью-Йорк): сутки считаются по его полуночи, 99 900 + 8 × 1 000');
select ok(
  (select position('Прочие источники (1): ' || (select public.format_som(1000)) || ' (1)' in message) > 0
      and position((select public.format_som(99900)) in message) > 0
      and position((select public.format_som(107900)) in message) > 0
     from t_out where kind = 'cash' and who = 7),
  '/cash при девяти источниках: восемь строк и «Прочие источники (1)» — разбивка сходится с итогом (Р15)');
select is(
  (select (public.center_payments_day('72000000-0000-0000-0000-0000000000c4', public.center_today('72000000-0000-0000-0000-0000000000c4')) ->> 'ops')::int),
  0, 'День без платежей — ноль операций');
select ok(
  (select position((select v from t_ref where k = 'today') in message) > 0
      and position('По источникам:' in message) > 0
      and position('Без источника: ' in message) > 0
      and position('99900' in message) = 0 and position('999,00' in message) = 0
     from t_out where kind = 'cash' and who = 1),
  '/cash владельца: итог и число операций из базы, разбивка по источникам, суммы чужого центра не примешаны');
select is((select message from t_out where kind = 'cash' and who = 2), (select message from t_out where kind = 'cash' and who = 1),
  '/cash администратора — тот же текст');
select is((select message from t_out where kind = 'cash' and who = 4), (select message from t_out where kind = 'cash' and who = 1),
  '/cash бухгалтера — тот же текст');
select ok(
  (select position('999,00 сом' in message) > 0 or position(public.format_som(99900) in message) > 0
     from t_out where kind = 'cash' and who = 7),
  '/cash владельца центра Б — свои 999 сом');
select is(
  (select message from t_out where kind = 'cash' and who = 8),
  'Центр 0072 И' || E'\n' || (select v from t_ref where k = 'none'),
  '/cash центра только для чтения без платежей: «Поступлений сегодня (ДД.ММ) нет.»');
select is((select center_name from t_out where kind = 'cash' and who = 9), 'Центр 0072 Б',
  '/cash смешанного членства — только центр Б');
select is((select count(*)::int from t_out where kind = 'cash' and who = 10), 1, '/cash: удалённый центр пропущен');


-- 7. Бот ничего не пишет -------------------------------------------------------------------------

select is((select count(*) from public.events), (select ev from t_evt), 'События не появились — бот только читает');
select is((select count(*) from public.audit_log), (select au from t_evt), 'audit_log не вырос');

-- В транзакции только для чтения (так PostgREST исполняет stable-RPC) подмена
-- работает и откатывается: SET LOCAL перехода «запись → чтение» допускает.
set local transaction_read_only = on;
select lives_ok($q$ select * from public.bot_debts(720001) $q$, '/debts работает в транзакции только для чтения (Р4)');
select lives_ok($q$ select * from public.bot_cash(720001) $q$, '/cash тоже');
select is(auth.uid(), null::uuid, 'После вызова в read-only транзакции auth.uid() снова пуст');

select * from finish();
rollback;
