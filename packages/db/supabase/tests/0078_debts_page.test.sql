-- pgTAP: страница /app/debts одним запросом — student_debt_page() (0078).
--
-- Главное, что ловит файл:
--   - строки и порядок = student_debt_problems() (второй копии правила нет);
--   - последнее/ближайшее занятие без отменённых и удалённых;
--   - контакты из payers_brief(): удалённый плательщик — NULL, payer_id сырой;
--   - выдача по ролям: owner/admin/registrar — всё, finance — без дат,
--     parent — свои дети без контактов, teacher и без сессии — пусто;
--   - второй центр не просачивается;
--   - гранты: только authenticated.
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(21);


-- 1. Каталог --------------------------------------------------------------------------------------

select is_empty(
  $$ select a.grantee::regrole::text
       from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = 'public.student_debt_page()'::regprocedure
        and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner
        and a.grantee <> 'authenticated'::regrole $$,
  'EXECUTE — только у владельца и authenticated: ни PUBLIC, ни anon, ни service_role, ни bot_worker');

select ok(
  has_function_privilege('authenticated', 'public.student_debt_page()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.student_debt_page()', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.student_debt_page()', 'EXECUTE')
  and not has_function_privilege('bot_worker', 'public.student_debt_page()', 'EXECUTE'),
  'authenticated вызывает, anon/service_role/bot_worker — нет');

select ok(
  (select not p.prosecdef and p.provolatile = 's' and p.proconfig::text like '%search_path%'
     from pg_proc p where p.oid = 'public.student_debt_page()'::regprocedure),
  'SECURITY INVOKER, STABLE, search_path зафиксирован');


-- 2. Фикстура (как в 0076, префикс 78…) + занятия для последнего/ближайшего -------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000',
       ('78000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0078@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 9) n;

insert into public.centers (id, name, slug, settings) values
  ('78000000-0000-0000-0000-0000000000c1','Центр 0078',  'centr-0078',   '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('78000000-0000-0000-0000-0000000000c2','Центр 0078 Б','centr-0078-b', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-0000000000c1','Специалист 0078'),
  ('78000000-0000-0000-0000-00000000aa02','78000000-0000-0000-0000-0000000000c2','Специалист Б 0078');

insert into public.payers (id, center_id, full_name, phone) values
  ('78000000-0000-0000-0000-00000000dd01','78000000-0000-0000-0000-0000000000c1','Плательщик 1 0078','+996700007801'),
  ('78000000-0000-0000-0000-00000000dd02','78000000-0000-0000-0000-0000000000c1','Плательщик 2 0078','+996700007802'),
  ('78000000-0000-0000-0000-00000000dd03','78000000-0000-0000-0000-0000000000c2','Плательщик Б 0078','+996700007803');

-- 1 owner c1 · 2 admin · 3 registrar · 4 finance · 5 teacher · 6 parent (payer 1) ·
-- 7 parent (payer 2) · 8 parent без payer_id · 9 owner c2.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('78000000-0000-0000-0000-000000000001','78000000-0000-0000-0000-0000000000c1','owner',    null, null),
  ('78000000-0000-0000-0000-000000000002','78000000-0000-0000-0000-0000000000c1','admin',    null, null),
  ('78000000-0000-0000-0000-000000000003','78000000-0000-0000-0000-0000000000c1','registrar',null, null),
  ('78000000-0000-0000-0000-000000000004','78000000-0000-0000-0000-0000000000c1','finance',  null, null),
  ('78000000-0000-0000-0000-000000000005','78000000-0000-0000-0000-0000000000c1','teacher',  '78000000-0000-0000-0000-00000000aa01', null),
  ('78000000-0000-0000-0000-000000000006','78000000-0000-0000-0000-0000000000c1','parent',   null, '78000000-0000-0000-0000-00000000dd01'),
  ('78000000-0000-0000-0000-000000000007','78000000-0000-0000-0000-0000000000c1','parent',   null, '78000000-0000-0000-0000-00000000dd02'),
  ('78000000-0000-0000-0000-000000000008','78000000-0000-0000-0000-0000000000c1','parent',   null, null),
  ('78000000-0000-0000-0000-000000000009','78000000-0000-0000-0000-0000000000c2','owner',    null, null);

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('78000000-0000-0000-0000-00000000bb01','78000000-0000-0000-0000-0000000000c1','Услуга 50 0078', 50000),
  ('78000000-0000-0000-0000-00000000bb02','78000000-0000-0000-0000-0000000000c1','Услуга 90 0078', 90000),
  ('78000000-0000-0000-0000-00000000bb03','78000000-0000-0000-0000-0000000000c1','Услуга 70 0078', 70000),
  ('78000000-0000-0000-0000-00000000bb04','78000000-0000-0000-0000-0000000000c2','Услуга Б 0078', 33300);

-- sA (payer 1): долг за занятие 500 · sB (payer 2): просрочка по абонементу ·
-- sC (payer 1): чистый исчерпанный остаток · sD (payer 1): просрочка И
-- исчерпанный остаток · sE (payer 1): долг 900, имя длиннее 60 знаков · sF: чистый.
insert into public.students (id, center_id, full_name, payer_id) values
  ('78000000-0000-0000-0000-00000000ee01','78000000-0000-0000-0000-0000000000c1','Аня Долг 0078','78000000-0000-0000-0000-00000000dd01'),
  ('78000000-0000-0000-0000-00000000ee02','78000000-0000-0000-0000-0000000000c1','Боря Просрочка 0078','78000000-0000-0000-0000-00000000dd02'),
  ('78000000-0000-0000-0000-00000000ee03','78000000-0000-0000-0000-0000000000c1','Вера Исчерпан 0078','78000000-0000-0000-0000-00000000dd01'),
  ('78000000-0000-0000-0000-00000000ee04','78000000-0000-0000-0000-0000000000c1','Глеб Просрочен и исчерпан 0078','78000000-0000-0000-0000-00000000dd01'),
  ('78000000-0000-0000-0000-00000000ee05','78000000-0000-0000-0000-0000000000c1',
   'Очень длинное имя ребёнка для проверки обрезки до шестидесяти знаков в Телеграме 0078','78000000-0000-0000-0000-00000000dd01'),
  ('78000000-0000-0000-0000-00000000ee06','78000000-0000-0000-0000-0000000000c1','Чистый 0078','78000000-0000-0000-0000-00000000dd01'),
  -- ee08: второй «чистый» исчерпанный остаток: sort_tiyin = 0, как у Веры, но имя раньше по алфавиту
  -- при большем uuid — порядок «full_name, student_id» не совпадает с порядком вставки и uuid.
  ('78000000-0000-0000-0000-00000000ee08','78000000-0000-0000-0000-0000000000c1','Аня Ранняя 0078','78000000-0000-0000-0000-00000000dd01'),
  ('78000000-0000-0000-0000-00000000ee07','78000000-0000-0000-0000-0000000000c2','Чужой должник 0078','78000000-0000-0000-0000-00000000dd03');

insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at) values
  ('78000000-0000-0000-0000-000000005502','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000ee02','78000000-0000-0000-0000-00000000dd02', 4, 100000, 25000, current_date - 30),
  ('78000000-0000-0000-0000-000000005503','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000ee03','78000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30),
  ('78000000-0000-0000-0000-000000005504','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000ee04','78000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30),
  ('78000000-0000-0000-0000-000000005508','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000ee08','78000000-0000-0000-0000-00000000dd01', 1, 70000, 70000, current_date - 30);

-- Занятия: один специалист, окна не пересекаются (EXCLUDE 0006).
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at) values
  ('78000000-0000-0000-0000-00000000ff01','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb01','78000000-0000-0000-0000-00000000ee01','planned', date_trunc('hour', now()) - interval '2 days', date_trunc('hour', now()) - interval '2 days' + interval '45 minutes'),
  ('78000000-0000-0000-0000-00000000ff03','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb03','78000000-0000-0000-0000-00000000ee03','planned', date_trunc('hour', now()) - interval '2 days' - interval '2 hours', date_trunc('hour', now()) - interval '2 days' - interval '2 hours' + interval '45 minutes'),
  ('78000000-0000-0000-0000-00000000ff04','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb03','78000000-0000-0000-0000-00000000ee04','planned', date_trunc('hour', now()) - interval '2 days' - interval '4 hours', date_trunc('hour', now()) - interval '2 days' - interval '4 hours' + interval '45 minutes'),
  ('78000000-0000-0000-0000-00000000ff05','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb02','78000000-0000-0000-0000-00000000ee05','planned', date_trunc('hour', now()) - interval '2 days' - interval '6 hours', date_trunc('hour', now()) - interval '2 days' - interval '6 hours' + interval '45 minutes'),
  ('78000000-0000-0000-0000-00000000ff08','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb03','78000000-0000-0000-0000-00000000ee08','planned', date_trunc('hour', now()) - interval '2 days' - interval '8 hours', date_trunc('hour', now()) - interval '2 days' - interval '8 hours' + interval '45 minutes'),
  -- ff06: второе занятие sD ПОСЛЕ исчерпания абонемента — уйдёт в долг по цене услуги (отдельным insert ниже).
  ('78000000-0000-0000-0000-00000000ff06','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb03','78000000-0000-0000-0000-00000000ee04','planned', date_trunc('hour', now()) - interval '2 days' - interval '10 hours', date_trunc('hour', now()) - interval '2 days' - interval '10 hours' + interval '45 minutes'),
  ('78000000-0000-0000-0000-00000000ff07','78000000-0000-0000-0000-0000000000c2','78000000-0000-0000-0000-00000000aa02','78000000-0000-0000-0000-00000000bb04','78000000-0000-0000-0000-00000000ee07','planned', date_trunc('hour', now()) - interval '2 days', date_trunc('hour', now()) - interval '2 days' + interval '45 minutes');

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l
 where l.id::text like '78000000-0000-0000-0000-00000000ff%' and l.id <> '78000000-0000-0000-0000-00000000ff06'
 order by l.starts_at;
-- Второе занятие sD — отдельной командой, после того как первое исчерпало абонемент: тогда
-- триггер посещения не списывает с абонемента (subscriptions_not_overdrawn), а ставит долг.
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l where l.id = '78000000-0000-0000-0000-00000000ff06';

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
  select (select id from public.payment_sources where center_id = '78000000-0000-0000-0000-0000000000c1' order by sort, code limit 1) as cash_id;
grant select on t_src to public;

-- Платежи по абонементам — от имени владельца (как кнопка на экране): sB внесено
-- 45 000 из 100 000 (просрочка 55 000), sC оплачен полностью, sD внесено 25 000.
select public.tests_claims('78000000-0000-0000-0000-000000000001','78000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.record_payment('78000000-0000-0000-0000-00000000dd02', 45000, 'payment', '78000000-0000-0000-0000-00000000ee02', '78000000-0000-0000-0000-000000005502', (select cash_id from t_src), now() - interval '5 days', 'аванс');
select public.record_payment('78000000-0000-0000-0000-00000000dd01', 70000, 'payment', '78000000-0000-0000-0000-00000000ee03', '78000000-0000-0000-0000-000000005503', (select cash_id from t_src), now() - interval '5 days', 'полностью');
select public.record_payment('78000000-0000-0000-0000-00000000dd01', 25000, 'payment', '78000000-0000-0000-0000-00000000ee04', '78000000-0000-0000-0000-000000005504', (select cash_id from t_src), now() - interval '5 days', 'аванс');
select public.record_payment('78000000-0000-0000-0000-00000000dd01', 70000, 'payment', '78000000-0000-0000-0000-00000000ee08', '78000000-0000-0000-0000-000000005508', (select cash_id from t_src), now() - interval '5 days', 'полностью');
reset role;
select public.tests_claims(null, null);


-- ee01: прошлое посещённое ff01 (-2 дня) — «последнее». Отменённое (-1 день) и удалённое
-- (-12 часов) позже него и будущие отменённое/удалённое раньше planned ff13 (+1 день) не должны победить.
-- ee03: ff16 идёт прямо сейчас — это «последнее», а не «ближайшее» (0078 Р4).
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at, deleted_at) values
  ('78000000-0000-0000-0000-00000000ff11','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb01','78000000-0000-0000-0000-00000000ee01','cancelled', date_trunc('hour', now()) - interval '1 day',  date_trunc('hour', now()) - interval '1 day'  + interval '45 minutes', null),
  ('78000000-0000-0000-0000-00000000ff12','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb01','78000000-0000-0000-0000-00000000ee01','planned',   date_trunc('hour', now()) - interval '12 hours', date_trunc('hour', now()) - interval '12 hours' + interval '45 minutes', now()),
  ('78000000-0000-0000-0000-00000000ff13','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb01','78000000-0000-0000-0000-00000000ee01','planned',   date_trunc('hour', now()) + interval '1 day',  date_trunc('hour', now()) + interval '1 day'  + interval '45 minutes', null),
  ('78000000-0000-0000-0000-00000000ff14','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb01','78000000-0000-0000-0000-00000000ee01','cancelled', date_trunc('hour', now()) + interval '12 hours', date_trunc('hour', now()) + interval '12 hours' + interval '45 minutes', null),
  ('78000000-0000-0000-0000-00000000ff15','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb01','78000000-0000-0000-0000-00000000ee01','planned',   date_trunc('hour', now()) + interval '6 hours',  date_trunc('hour', now()) + interval '6 hours'  + interval '45 minutes', now()),
  ('78000000-0000-0000-0000-00000000ff16','78000000-0000-0000-0000-0000000000c1','78000000-0000-0000-0000-00000000aa01','78000000-0000-0000-0000-00000000bb03','78000000-0000-0000-0000-00000000ee03','planned',   now() - interval '10 minutes', now() + interval '35 minutes', null);

-- Снимки под сессией каждой роли; утверждения — потом, от postgres.
create temporary table t_page (
  who text, ord bigint, student_id uuid, payer_id uuid, payer_name text, payer_phone text,
  debt_tiyin integer, overdrawn_tiyin integer, overdue_tiyin integer,
  overdue_payer_id uuid, overdue_payer_name text, zero_left boolean, sort_tiyin bigint,
  last_lesson_at timestamptz, next_lesson_at timestamptz);
create temporary table t_prob (ord bigint, student_id uuid, debt_tiyin integer, overdrawn_tiyin integer,
  overdue_tiyin integer, zero_left boolean, sort_tiyin bigint);
grant all on t_page, t_prob to public;

create or replace function public.t_snap(p_who text, p_user uuid, p_center uuid) returns void
  language plpgsql as $$
begin
  perform public.tests_claims(p_user, p_center);
  execute 'set local role authenticated';
  insert into t_page
    select p_who, x.ordinality, x.student_id, x.payer_id, x.payer_name, x.payer_phone,
           x.debt_tiyin, x.overdrawn_tiyin, x.overdue_tiyin, x.overdue_payer_id, x.overdue_payer_name,
           x.zero_left, x.sort_tiyin, x.last_lesson_at, x.next_lesson_at
      from public.student_debt_page() with ordinality as x;
  if p_who = 'owner' then
    insert into t_prob
      select y.ordinality, y.student_id, y.debt_tiyin, y.overdrawn_tiyin, y.overdue_tiyin, y.zero_left, y.sort_tiyin
        from public.student_debt_problems() with ordinality as y;
  end if;
  execute 'reset role';
  perform public.tests_claims(null, null);
end;
$$;

select public.t_snap('owner',     '78000000-0000-0000-0000-000000000001', '78000000-0000-0000-0000-0000000000c1');
select public.t_snap('admin',     '78000000-0000-0000-0000-000000000002', '78000000-0000-0000-0000-0000000000c1');
select public.t_snap('registrar', '78000000-0000-0000-0000-000000000003', '78000000-0000-0000-0000-0000000000c1');
select public.t_snap('finance',   '78000000-0000-0000-0000-000000000004', '78000000-0000-0000-0000-0000000000c1');
select public.t_snap('teacher',   '78000000-0000-0000-0000-000000000005', '78000000-0000-0000-0000-0000000000c1');
select public.t_snap('parent',    '78000000-0000-0000-0000-000000000006', '78000000-0000-0000-0000-0000000000c1');
select public.t_snap('ownerB',    '78000000-0000-0000-0000-000000000009', '78000000-0000-0000-0000-0000000000c2');
select public.t_snap('nobody',    null, null);

-- Мягко удалённый плательщик: payer_id остаётся сырым, контакта нет.
update public.payers set deleted_at = now() where id = '78000000-0000-0000-0000-00000000dd02';
select public.t_snap('owner_del', '78000000-0000-0000-0000-000000000001', '78000000-0000-0000-0000-0000000000c1');


-- 3. Строки и порядок = student_debt_problems() -----------------------------------------------------

select set_eq(
  $$ select student_id, debt_tiyin, overdrawn_tiyin, overdue_tiyin, zero_left, sort_tiyin from t_page where who = 'owner' $$,
  $$ select student_id, debt_tiyin, overdrawn_tiyin, overdue_tiyin, zero_left, sort_tiyin from t_prob $$,
  'Строки и суммы — те же, что у student_debt_problems(): второй копии правила нет');

select is(
  (select array_agg(student_id order by ord) from t_page where who = 'owner'),
  (select array_agg(student_id order by ord) from t_prob),
  'Порядок тот же: sort_tiyin desc, full_name, student_id');

select is((select count(*)::int from t_page where who = 'owner'
            and student_id = '78000000-0000-0000-0000-00000000ee07'), 0,
  'Ребёнок второго центра владельцу первого не виден');


-- 4. Последнее и ближайшее занятие ------------------------------------------------------------------

select is(
  (select last_lesson_at from t_page where who = 'owner' and student_id = '78000000-0000-0000-0000-00000000ee01'),
  date_trunc('hour', now()) - interval '2 days',
  'Последнее — посещённое 2 дня назад: отменённое сутки назад и удалённое 12 часов назад не считаются');

select is(
  (select (last_lesson_at = now() - interval '10 minutes') and next_lesson_at is null
     from t_page where who = 'owner' and student_id = '78000000-0000-0000-0000-00000000ee03'),
  true, 'Идущее сейчас занятие — «последнее», а не «ближайшее»');

select is(
  (select next_lesson_at from t_page where who = 'owner' and student_id = '78000000-0000-0000-0000-00000000ee01'),
  date_trunc('hour', now()) + interval '1 day',
  'Ближайшее — planned завтра: отменённое и удалённое раньше него не считаются');

select is(
  (select count(*)::int from t_page where who = 'owner' and next_lesson_at is not null), 1,
  'У остальных детей будущих занятий нет — ближайшее NULL, а не чужая дата');


-- 5. Контакты -------------------------------------------------------------------------------------

select is(
  (select (payer_name, payer_phone)::text from t_page where who = 'owner' and student_id = '78000000-0000-0000-0000-00000000ee01'),
  '("Плательщик 1 0078",+996700007801)', 'Имя и телефон плательщика ребёнка');

select is(
  (select (overdue_payer_id, overdue_payer_name)::text from t_page where who = 'owner' and student_id = '78000000-0000-0000-0000-00000000ee02'),
  '(78000000-0000-0000-0000-00000000dd02,"Плательщик 2 0078")', 'Плательщик просроченного абонемента — отдельными колонками');

select is(
  (select (payer_id, payer_name, overdue_payer_id, overdue_payer_name)::text from t_page
    where who = 'owner_del' and student_id = '78000000-0000-0000-0000-00000000ee02'),
  '(78000000-0000-0000-0000-00000000dd02,,78000000-0000-0000-0000-00000000dd02,)',
  'Удалённый плательщик: id сырые (страница сравнивает их между собой), контактов нет');


-- 6. Роли -----------------------------------------------------------------------------------------

select set_eq(
  $$ select student_id, payer_name, last_lesson_at, next_lesson_at from t_page where who = 'admin' $$,
  $$ select student_id, payer_name, last_lesson_at, next_lesson_at from t_page where who = 'owner' $$,
  'Администратор видит то же, что владелец');

select set_eq(
  $$ select student_id, payer_name, last_lesson_at, next_lesson_at from t_page where who = 'registrar' $$,
  $$ select student_id, payer_name, last_lesson_at, next_lesson_at from t_page where who = 'owner' $$,
  'Регистратор — то же: lesson_participants ему открыт (0028), контакты — через payers_brief');

select ok(
  (select count(*) = (select count(*) from t_page where who = 'owner')
          and bool_and(payer_name is not null or payer_id is null)
          and bool_and(last_lesson_at is null and next_lesson_at is null)
     from t_page where who = 'finance'),
  'Бухгалтер: все строки и контакты, но без дат занятий — lesson_participants ему закрыт');

select set_eq(
  $$ select student_id from t_page where who = 'parent' $$,
  $$ select student_id from t_page where who = 'owner' and payer_id = '78000000-0000-0000-0000-00000000dd01' $$,
  'Родитель — только свои дети');

select ok(
  (select count(*) > 0
          and bool_and(payer_name is null and payer_phone is null and overdue_payer_name is null)
          and bool_or(last_lesson_at is not null)
     from t_page where who = 'parent'),
  'Родителю контакты не отдаются (payers_brief ему пуст), даты своих детей — да');

select is((select count(*)::int from t_page where who = 'teacher'), 0, 'Специалисту — пусто');

select is((select count(*)::int from t_page where who = 'nobody'), 0, 'Без сессии — пусто');

select is(
  (select array_agg(student_id::text) from t_page where who = 'ownerB'),
  array['78000000-0000-0000-0000-00000000ee07'],
  'Владелец второго центра видит только своего должника');

select * from finish();
rollback;
