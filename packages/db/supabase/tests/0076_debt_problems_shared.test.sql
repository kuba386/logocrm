-- pgTAP: единый источник «проблемных» детей — student_debt_problems() и
-- student_debt_summary() открыты клиенту (0076).
--
-- Главное, что ловит файл:
--   - права по ролям (функция invoker над сессионными student_balance и
--     students_brief): owner/admin/registrar/finance видят один и тот же набор
--     всего центра, parent — только детей своего плательщика (без payer_id —
--     никого), teacher — пусто, чужой центр не виден, без сессии — пусто;
--   - семантика: ребёнок с просрочкой И исчерпанным абонементом — одна строка
--     с zero_left = false; «чистый» исчерпанный остаток — zero_left = true,
--     sort_tiyin = 0; overdue_payer_id — плательщик абонемента; имя >60 знаков
--     возвращается полностью;
--   - итоги считает SQL (debtors_n — уникальные дети, usage_n/overdue_n — по
--     корзинам, ребёнок с долгом и просрочкой учтён в обеих), топ ограничен
--     p_top (0 — пусто, >50 — 50);
--   - регрессия 0072: bot_debts_center отдаёт те же итоги и имена ≤60 знаков,
--     claims после вызова восстановлены;
--   - гранты: authenticated исполняет обе функции, остальные роли — нет.
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(27);


-- 1. Каталог --------------------------------------------------------------------------------------

select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.pronamespace = 'public'::regnamespace
        and p.proname in ('student_debt_problems', 'student_debt_summary')
        and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner
        and a.grantee <> 'authenticated'::regrole $$,
  'EXECUTE на обе функции — только у владельца и authenticated: ни PUBLIC, ни anon, ни service_role, ни bot_worker');

select ok(
  has_function_privilege('authenticated', 'public.student_debt_problems()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.student_debt_summary(integer)', 'EXECUTE'),
  'authenticated исполняет обе функции');

select ok(
  (select bool_and(not p.prosecdef and p.provolatile = 's' and p.proconfig::text like '%search_path%')
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname in ('student_debt_problems', 'student_debt_summary')),
  'Обе — SECURITY INVOKER, STABLE, search_path зафиксирован: права решают сессионные student_balance и students_brief');


-- 2. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000',
       ('76000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0076@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 9) n;

insert into public.centers (id, name, slug, settings) values
  ('76000000-0000-0000-0000-0000000000c1','Центр 0076',  'centr-0076',   '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('76000000-0000-0000-0000-0000000000c2','Центр 0076 Б','centr-0076-b', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('76000000-0000-0000-0000-00000000aa01','76000000-0000-0000-0000-0000000000c1','Специалист 0076'),
  ('76000000-0000-0000-0000-00000000aa02','76000000-0000-0000-0000-0000000000c2','Специалист Б 0076');

insert into public.payers (id, center_id, full_name, phone) values
  ('76000000-0000-0000-0000-00000000dd01','76000000-0000-0000-0000-0000000000c1','Плательщик 1 0076','+996700007601'),
  ('76000000-0000-0000-0000-00000000dd02','76000000-0000-0000-0000-0000000000c1','Плательщик 2 0076','+996700007602'),
  ('76000000-0000-0000-0000-00000000dd03','76000000-0000-0000-0000-0000000000c2','Плательщик Б 0076','+996700007603');

-- 1 owner c1 · 2 admin · 3 registrar · 4 finance · 5 teacher · 6 parent (payer 1) ·
-- 7 parent (payer 2) · 8 parent без payer_id · 9 owner c2.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('76000000-0000-0000-0000-000000000001','76000000-0000-0000-0000-0000000000c1','owner',    null, null),
  ('76000000-0000-0000-0000-000000000002','76000000-0000-0000-0000-0000000000c1','admin',    null, null),
  ('76000000-0000-0000-0000-000000000003','76000000-0000-0000-0000-0000000000c1','registrar',null, null),
  ('76000000-0000-0000-0000-000000000004','76000000-0000-0000-0000-0000000000c1','finance',  null, null),
  ('76000000-0000-0000-0000-000000000005','76000000-0000-0000-0000-0000000000c1','teacher',  '76000000-0000-0000-0000-00000000aa01', null),
  ('76000000-0000-0000-0000-000000000006','76000000-0000-0000-0000-0000000000c1','parent',   null, '76000000-0000-0000-0000-00000000dd01'),
  ('76000000-0000-0000-0000-000000000007','76000000-0000-0000-0000-0000000000c1','parent',   null, '76000000-0000-0000-0000-00000000dd02'),
  ('76000000-0000-0000-0000-000000000008','76000000-0000-0000-0000-0000000000c1','parent',   null, null),
  ('76000000-0000-0000-0000-000000000009','76000000-0000-0000-0000-0000000000c2','owner',    null, null);

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('76000000-0000-0000-0000-00000000bb01','76000000-0000-0000-0000-0000000000c1','Услуга 50 0076', 50000),
  ('76000000-0000-0000-0000-00000000bb02','76000000-0000-0000-0000-0000000000c1','Услуга 90 0076', 90000),
  ('76000000-0000-0000-0000-00000000bb03','76000000-0000-0000-0000-0000000000c1','Услуга 70 0076', 70000),
  ('76000000-0000-0000-0000-00000000bb04','76000000-0000-0000-0000-0000000000c2','Услуга Б 0076', 33300);

-- sA (payer 1): долг за занятие 500 · sB (payer 2): просрочка по абонементу ·
-- sC (payer 1): чистый исчерпанный остаток · sD (payer 1): просрочка И
-- исчерпанный остаток · sE (payer 1): долг 900, имя длиннее 60 знаков · sF: чистый.
insert into public.students (id, center_id, full_name, payer_id) values
  ('76000000-0000-0000-0000-00000000ee01','76000000-0000-0000-0000-0000000000c1','Аня Долг 0076','76000000-0000-0000-0000-00000000dd01'),
  ('76000000-0000-0000-0000-00000000ee02','76000000-0000-0000-0000-0000000000c1','Боря Просрочка 0076','76000000-0000-0000-0000-00000000dd02'),
  ('76000000-0000-0000-0000-00000000ee03','76000000-0000-0000-0000-0000000000c1','Вера Исчерпан 0076','76000000-0000-0000-0000-00000000dd01'),
  ('76000000-0000-0000-0000-00000000ee04','76000000-0000-0000-0000-0000000000c1','Глеб Просрочен и исчерпан 0076','76000000-0000-0000-0000-00000000dd01'),
  ('76000000-0000-0000-0000-00000000ee05','76000000-0000-0000-0000-0000000000c1',
   'Очень длинное имя ребёнка для проверки обрезки до шестидесяти знаков в Телеграме 0076','76000000-0000-0000-0000-00000000dd01'),
  ('76000000-0000-0000-0000-00000000ee06','76000000-0000-0000-0000-0000000000c1','Чистый 0076','76000000-0000-0000-0000-00000000dd01'),
  -- ee08: второй «чистый» исчерпанный остаток: sort_tiyin = 0, как у Веры, но имя раньше по алфавиту
  -- при большем uuid — порядок «full_name, student_id» не совпадает с порядком вставки и uuid.
  ('76000000-0000-0000-0000-00000000ee08','76000000-0000-0000-0000-0000000000c1','Аня Ранняя 0076','76000000-0000-0000-0000-00000000dd01'),
  ('76000000-0000-0000-0000-00000000ee07','76000000-0000-0000-0000-0000000000c2','Чужой должник 0076','76000000-0000-0000-0000-00000000dd03');

insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at) values
  ('76000000-0000-0000-0000-000000005502','76000000-0000-0000-0000-0000000000c1','76000000-0000-0000-0000-00000000ee02','76000000-0000-0000-0000-00000000dd02', 4, 100000, 25000, current_date - 30),
  ('76000000-0000-0000-0000-000000005503','76000000-0000-0000-0000-0000000000c1','76000000-0000-0000-0000-00000000ee03','76000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30),
  ('76000000-0000-0000-0000-000000005504','76000000-0000-0000-0000-0000000000c1','76000000-0000-0000-0000-00000000ee04','76000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30),
  ('76000000-0000-0000-0000-000000005508','76000000-0000-0000-0000-0000000000c1','76000000-0000-0000-0000-00000000ee08','76000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30);

-- Занятия: один специалист, окна не пересекаются (EXCLUDE 0006).
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at) values
  ('76000000-0000-0000-0000-00000000ff01','76000000-0000-0000-0000-0000000000c1','76000000-0000-0000-0000-00000000aa01','76000000-0000-0000-0000-00000000bb01','76000000-0000-0000-0000-00000000ee01','planned', date_trunc('hour', now()) - interval '2 days', date_trunc('hour', now()) - interval '2 days' + interval '45 minutes'),
  ('76000000-0000-0000-0000-00000000ff03','76000000-0000-0000-0000-0000000000c1','76000000-0000-0000-0000-00000000aa01','76000000-0000-0000-0000-00000000bb03','76000000-0000-0000-0000-00000000ee03','planned', date_trunc('hour', now()) - interval '2 days' - interval '2 hours', date_trunc('hour', now()) - interval '2 days' - interval '2 hours' + interval '45 minutes'),
  ('76000000-0000-0000-0000-00000000ff04','76000000-0000-0000-0000-0000000000c1','76000000-0000-0000-0000-00000000aa01','76000000-0000-0000-0000-00000000bb03','76000000-0000-0000-0000-00000000ee04','planned', date_trunc('hour', now()) - interval '2 days' - interval '4 hours', date_trunc('hour', now()) - interval '2 days' - interval '4 hours' + interval '45 minutes'),
  ('76000000-0000-0000-0000-00000000ff05','76000000-0000-0000-0000-0000000000c1','76000000-0000-0000-0000-00000000aa01','76000000-0000-0000-0000-00000000bb02','76000000-0000-0000-0000-00000000ee05','planned', date_trunc('hour', now()) - interval '2 days' - interval '6 hours', date_trunc('hour', now()) - interval '2 days' - interval '6 hours' + interval '45 minutes'),
  ('76000000-0000-0000-0000-00000000ff08','76000000-0000-0000-0000-0000000000c1','76000000-0000-0000-0000-00000000aa01','76000000-0000-0000-0000-00000000bb03','76000000-0000-0000-0000-00000000ee08','planned', date_trunc('hour', now()) - interval '2 days' - interval '8 hours', date_trunc('hour', now()) - interval '2 days' - interval '8 hours' + interval '45 minutes'),
  -- ff06: второе занятие sD ПОСЛЕ исчерпания абонемента — уйдёт в долг по цене услуги (отдельным insert ниже).
  ('76000000-0000-0000-0000-00000000ff06','76000000-0000-0000-0000-0000000000c1','76000000-0000-0000-0000-00000000aa01','76000000-0000-0000-0000-00000000bb03','76000000-0000-0000-0000-00000000ee04','planned', date_trunc('hour', now()) - interval '2 days' - interval '10 hours', date_trunc('hour', now()) - interval '2 days' - interval '10 hours' + interval '45 minutes'),
  ('76000000-0000-0000-0000-00000000ff07','76000000-0000-0000-0000-0000000000c2','76000000-0000-0000-0000-00000000aa02','76000000-0000-0000-0000-00000000bb04','76000000-0000-0000-0000-00000000ee07','planned', date_trunc('hour', now()) - interval '2 days', date_trunc('hour', now()) - interval '2 days' + interval '45 minutes');

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l
 where l.id::text like '76000000-0000-0000-0000-00000000ff%' and l.id <> '76000000-0000-0000-0000-00000000ff06'
 order by l.starts_at;
-- Второе занятие sD — отдельной командой, после того как первое исчерпало абонемент: тогда
-- триггер посещения не списывает с абонемента (subscriptions_not_overdrawn), а ставит долг.
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l where l.id = '76000000-0000-0000-0000-00000000ff06';

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
  select (select id from public.payment_sources where center_id = '76000000-0000-0000-0000-0000000000c1' order by sort, code limit 1) as cash_id;
grant select on t_src to public;

-- Платежи по абонементам — от имени владельца (как кнопка на экране): sB внесено
-- 45 000 из 100 000 (просрочка 55 000), sC оплачен полностью, sD внесено 25 000.
select public.tests_claims('76000000-0000-0000-0000-000000000001','76000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.record_payment('76000000-0000-0000-0000-00000000dd02', 45000, 'payment', '76000000-0000-0000-0000-00000000ee02', '76000000-0000-0000-0000-000000005502', (select cash_id from t_src), now() - interval '5 days', 'аванс');
select public.record_payment('76000000-0000-0000-0000-00000000dd01', 70000, 'payment', '76000000-0000-0000-0000-00000000ee03', '76000000-0000-0000-0000-000000005503', (select cash_id from t_src), now() - interval '5 days', 'полностью');
select public.record_payment('76000000-0000-0000-0000-00000000dd01', 25000, 'payment', '76000000-0000-0000-0000-00000000ee04', '76000000-0000-0000-0000-000000005504', (select cash_id from t_src), now() - interval '5 days', 'аванс');
select public.record_payment('76000000-0000-0000-0000-00000000dd01', 70000, 'payment', '76000000-0000-0000-0000-00000000ee08', '76000000-0000-0000-0000-000000005508', (select cash_id from t_src), now() - interval '5 days', 'полностью');
reset role;
select public.tests_claims(null, null);

create temporary table t_out (who text, ids text[]);
grant all on t_out to public;

create or replace function public.t_snapshot(p_who text, p_user uuid, p_center uuid) returns void
  language plpgsql as $$
begin
  perform public.tests_claims(p_user, p_center);
  execute 'set local role authenticated';
  insert into t_out select p_who, coalesce(array_agg(student_id::text order by student_id), '{}') from public.student_debt_problems();
  execute 'reset role';
  perform public.tests_claims(null, null);
end;
$$;

select public.t_snapshot('owner',     '76000000-0000-0000-0000-000000000001', '76000000-0000-0000-0000-0000000000c1');
select public.t_snapshot('admin',     '76000000-0000-0000-0000-000000000002', '76000000-0000-0000-0000-0000000000c1');
select public.t_snapshot('registrar', '76000000-0000-0000-0000-000000000003', '76000000-0000-0000-0000-0000000000c1');
select public.t_snapshot('finance',   '76000000-0000-0000-0000-000000000004', '76000000-0000-0000-0000-0000000000c1');
select public.t_snapshot('teacher',   '76000000-0000-0000-0000-000000000005', '76000000-0000-0000-0000-0000000000c1');
select public.t_snapshot('parent1',   '76000000-0000-0000-0000-000000000006', '76000000-0000-0000-0000-0000000000c1');
select public.t_snapshot('parent2',   '76000000-0000-0000-0000-000000000007', '76000000-0000-0000-0000-0000000000c1');
select public.t_snapshot('parent0',   '76000000-0000-0000-0000-000000000008', '76000000-0000-0000-0000-0000000000c1');
select public.t_snapshot('ownerB',    '76000000-0000-0000-0000-000000000009', '76000000-0000-0000-0000-0000000000c2');
insert into t_out select 'nosession', coalesce(array_agg(student_id::text), '{}') from public.student_debt_problems();


-- 3. Права по ролям -------------------------------------------------------------------------------

select is(
  (select ids from t_out where who = 'owner'),
  array['76000000-0000-0000-0000-00000000ee01', '76000000-0000-0000-0000-00000000ee02', '76000000-0000-0000-0000-00000000ee03',
        '76000000-0000-0000-0000-00000000ee04', '76000000-0000-0000-0000-00000000ee05', '76000000-0000-0000-0000-00000000ee08'],
  'Владелец видит шестерых проблемных детей центра; чистый ребёнок и чужой центр не входят');
select is((select ids from t_out where who = 'admin'), (select ids from t_out where who = 'owner'), 'Администратор — тот же набор');
select is((select ids from t_out where who = 'registrar'), (select ids from t_out where who = 'owner'), 'Регистратор — тот же набор');
select is((select ids from t_out where who = 'finance'), (select ids from t_out where who = 'owner'), 'Бухгалтер — тот же набор, включая имена (students_brief)');
select is((select ids from t_out where who = 'teacher'), '{}'::text[], 'Специалист долгов не видит');
select is(
  (select ids from t_out where who = 'parent1'),
  array['76000000-0000-0000-0000-00000000ee01', '76000000-0000-0000-0000-00000000ee03', '76000000-0000-0000-0000-00000000ee04',
        '76000000-0000-0000-0000-00000000ee05', '76000000-0000-0000-0000-00000000ee08'],
  'Родитель плательщика 1 — только его дети, без ребёнка плательщика 2');
select is((select ids from t_out where who = 'parent2'), array['76000000-0000-0000-0000-00000000ee02'], 'Родитель плательщика 2 — только своего ребёнка');
select is((select ids from t_out where who = 'parent0'), '{}'::text[], 'Родитель без payer_id — никого');
select is((select ids from t_out where who = 'ownerB'), array['76000000-0000-0000-0000-00000000ee07'], 'Владелец другого центра видит только своего должника');
select is((select ids from t_out where who = 'nosession'), '{}'::text[], 'Без сессии — пусто, без исключения');


-- 4. Семантика и итоги ----------------------------------------------------------------------------

select public.tests_claims('76000000-0000-0000-0000-000000000001','76000000-0000-0000-0000-0000000000c1');
set local role authenticated;
create temporary table t_rows as select * from public.student_debt_problems();
create temporary table t_sum as select public.student_debt_summary(10) as j;
create temporary table t_sum0 as select public.student_debt_summary(0) as j;
create temporary table t_sum99 as select public.student_debt_summary(99) as j;
create temporary table t_summ1 as select public.student_debt_summary(-1) as j;
create temporary table t_sumnull as select public.student_debt_summary(null) as j;
reset role;

select public.tests_claims('76000000-0000-0000-0000-000000000006','76000000-0000-0000-0000-0000000000c1');
set local role authenticated;
create temporary table t_sump as select public.student_debt_summary(10) as j;
reset role;
select public.tests_claims(null, null);
select public.tests_claims(null, null);

select ok(
  (select not zero_left and overdue_tiyin > 0 and lessons_left = 0 and debt_tiyin = 70000 and sort_tiyin = 70000
     from t_rows where student_id = '76000000-0000-0000-0000-00000000ee04'),
  'Просрочка И долг И исчерпанный абонемент — одна строка, zero_left = false, sort_tiyin — максимум корзин (70 000), не их сумма');
select ok(
  (select zero_left and sort_tiyin = 0 and debt_tiyin = 0 and overdue_tiyin = 0 from t_rows where student_id = '76000000-0000-0000-0000-00000000ee03'),
  'Чистый исчерпанный остаток — zero_left = true, sort_tiyin = 0');
select is(
  (select overdue_payer_id from t_rows where student_id = '76000000-0000-0000-0000-00000000ee02'),
  '76000000-0000-0000-0000-00000000dd02'::uuid, 'overdue_payer_id — плательщик абонемента');
select ok(
  (select length(full_name) > 60 from t_rows where student_id = '76000000-0000-0000-0000-00000000ee05'),
  'Имя длиннее 60 знаков возвращается полностью (обрезка — забота бота)');
select is(
  (select array_agg(student_id::text) from t_rows),
  array['76000000-0000-0000-0000-00000000ee05', '76000000-0000-0000-0000-00000000ee04', '76000000-0000-0000-0000-00000000ee02',
        '76000000-0000-0000-0000-00000000ee01', '76000000-0000-0000-0000-00000000ee08', '76000000-0000-0000-0000-00000000ee03'],
  'Порядок: 900, 700 (по максимуму корзин), 550, 500, затем два нуля по имени — «Аня Ранняя» (uuid ee08) раньше «Веры» (ee03), вопреки uuid и порядку вставки');

select is(
  (select (j ->> 'debtors_n')::int from t_sum), 4,
  'debtors_n — уникальные дети (sA, sB, sD, sE): sD с долгом и просрочкой учтён один раз, поэтому 4 < usage_n + overdue_n = 5; исчерпанные остатки не входят');
select ok(
  (select (j ->> 'usage_n')::int = 3 and (j ->> 'usage_tiyin')::bigint = 210000
      and (j ->> 'overdue_n')::int = 2 and (j ->> 'overdue_tiyin')::bigint = 100000
      and (j ->> 'zero_n')::int = 2 from t_sum),
  'Итоги по корзинам: долг за занятия 500 + 700 + 900 (3 детей), просрочка 550 + 450 (2 детей), два «чистых» исчерпанных; корзины не складываются');
select ok(
  (select jsonb_array_length(j -> 'top') = 6 from t_sum)
  and (select jsonb_array_length(j -> 'top') = 0 from t_sum0)
  and (select jsonb_array_length(j -> 'top') = 6 from t_sum99),
  'Топ ограничен p_top: 0 — пусто; больше числа строк — все шесть');
select ok(
  (select jsonb_array_length(j -> 'top') = 0 from t_summ1)
  and (select jsonb_array_length(j -> 'top') = 6 from t_sumnull),
  'p_top = -1 — не исключение (LIMIT must not be negative), пустой топ; p_top = NULL — топ по умолчанию');
select ok(
  pg_get_functiondef('public.student_debt_summary(integer)'::regprocedure) ~ 'least\(greatest\(coalesce\(p_top, 10\), 0\), 50\)',
  'Верхняя граница p_top = 50 держится в коде функции (пять-шесть строк фикстуры её не различают)');
select ok(
  (select (j ->> 'debtors_n')::int = 3 and (j ->> 'usage_n')::int = 3 and (j ->> 'overdue_n')::int = 1
      and (j ->> 'overdue_tiyin')::bigint = 45000 and (j ->> 'zero_n')::int = 2 from t_sump),
  'Итоги под родителем плательщика 1 — только по его детям (без просрочки Бори у плательщика 2)');

-- Регрессия 0072: бот получает те же итоги и имена ≤ 60 знаков.
select is(
  (select (public.bot_debts_center('76000000-0000-0000-0000-000000000001','76000000-0000-0000-0000-0000000000c1') ->> 'usage_tiyin')::bigint), 210000::bigint,
  'bot_debts_center: usage_tiyin как в общем агрегате');
select ok(
  (select (b ->> 'overdue_tiyin')::bigint = 100000 and (b ->> 'zero_n')::int = 2 and (b ->> 'overdue_n')::int = 2 and (b ->> 'usage_n')::int = 3
      and not (b ? 'debtors_n')
      and (select max(length(e ->> 'name')) from jsonb_array_elements(b -> 'top') e) <= 60
     from (select public.bot_debts_center('76000000-0000-0000-0000-000000000001','76000000-0000-0000-0000-0000000000c1') as b) q),
  'bot_debts_center: остальные итоги те же, debtors_n в ответ бота не течёт, имена в топе ≤ 60 знаков');

select set_config('request.jwt.claims', '{"sentinel":"0076"}', true);
select public.bot_debts_center('76000000-0000-0000-0000-000000000001','76000000-0000-0000-0000-0000000000c1');
select is(current_setting('request.jwt.claims', true), '{"sentinel":"0076"}', 'claims после вызова помощника восстановлены (0072 Р2в)');

select * from finish();
rollback;
