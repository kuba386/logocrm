-- pgTAP: абонемент покрывает неоплаченные занятия (0088).
--
-- Модель: покрытие снимает долг и тратит место абонемента, отметки не
-- переписываются (subscription_id остаётся null). Предпросмотр и RPC — один
-- план: самые старые подходящие, пока есть место и остаток долга. Покрытие
-- оплаченной отметки при живом перерасходе гасит перерасход (Р5). Задним
-- числом: «пришёл → болел» закрывает покрытие и возвращает занятие;
-- обратно «пришёл» — снова долг, покрытие не оживает, CHECK не стреляет;
-- отмена занятия и удаление абонемента закрывают покрытия. Границы: другая
-- услуга, безлимит, абонемент брата/сестры (FK), повтор (23505), устаревший
-- expected (23514), больше плана (22023). События: lesson_debt.covered,
-- subscription.exhausted один раз. Права: front desk — да, finance/teacher/
-- parent — 42501, чужой центр — 42704, только чтение — PT402. Заборы.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(50);


-- 1. Каталог --------------------------------------------------------------------------------------

select is_empty(
  $$ select policyname from pg_policies
      where schemaname = 'public' and tablename = 'lesson_debt_covers' and cmd <> 'SELECT' $$,
  'lesson_debt_covers: ни одной политики на запись — только RPC и триггеры');

select is_empty(
  $$ select a.grantee::regrole::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where c.oid = 'public.lesson_debt_covers'::regclass
        and a.grantee <> c.relowner
        and not (a.grantee = 'authenticated'::regrole and a.privilege_type = 'SELECT') $$,
  'lesson_debt_covers: authenticated — только SELECT, у anon и service_role нет ничего');

select is_empty(
  $$ select p.oid::regprocedure::text || ' ' || r
       from pg_proc p, unnest(array['public', 'anon', 'authenticated', 'service_role']) r
      where p.oid in ('public.lesson_debt_cover_plan(uuid)'::regprocedure,
                      'public.lesson_debt_covers_guard()'::regprocedure,
                      'public.lesson_debt_covers_close_only()'::regprocedure,
                      'public.lesson_debt_covers_recalc()'::regprocedure,
                      'public.attendance_close_covers()'::regprocedure,
                      'public.lessons_close_covers()'::regprocedure,
                      'public.recalc_subscription_usage(uuid)'::regprocedure)
        and has_function_privilege(r, p.oid, 'EXECUTE') $$,
  'Внутренние функции и триггеры 0088 не исполняет ни одна роль приложения');

select is_empty(
  $$ select p.oid::regprocedure::text from pg_proc p
      where p.oid in ('public.cover_lesson_debt(uuid,integer,integer)'::regprocedure,
                      'public.uncover_lesson_debt(uuid)'::regprocedure,
                      'public.lesson_debt_covers_guard()'::regprocedure)
        and p.prosrc not like '%lesson_debt_lock%' $$,
  'cover, uncover и триггер вставки берут блокировку по ребёнку');

select ok(
  exists (select 1 from pg_index i where i.indrelid = 'public.lesson_debt_covers'::regclass and i.indpred is null
             and i.indkey::text = (select string_agg(a.attnum::text, ' ' order by k.ord)
                                     from unnest(array['attendance_id', 'student_id', 'center_id']) with ordinality k(col, ord)
                                     join pg_attribute a on a.attrelid = i.indrelid and a.attname = k.col))
  and exists (select 1 from pg_index i where i.indrelid = 'public.lesson_debt_covers'::regclass and i.indpred is null
             and i.indkey::text = (select string_agg(a.attnum::text, ' ' order by k.ord)
                                     from unnest(array['subscription_id', 'student_id', 'center_id']) with ordinality k(col, ord)
                                     join pg_attribute a on a.attrelid = i.indrelid and a.attname = k.col)),
  'FK покрытий на отметку и абонемент покрыты непартиальными индексами (урок 0069)');

select ok(
  exists (select 1 from pg_trigger where tgrelid = 'public.lesson_debt_covers'::regclass and tgname = 'a00_readonly_guard')
  and exists (select 1 from public.export_center_tables() x where x.table_name = 'lesson_debt_covers'),
  'lesson_debt_covers: readonly guard (0050) и экспорт центра (0056)');


-- 2. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('88000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0088@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 8) n;

insert into public.centers (id, name, slug, settings) values
  ('88000000-0000-0000-0000-0000000000c1', 'Центр 0088',   'centr-0088',   '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('88000000-0000-0000-0000-0000000000c2', 'Центр Б 0088', 'centr-0088-b', '{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('88000000-0000-0000-0000-0000000000c3', 'Центр В 0088', 'centr-0088-v', 'solo', now() - interval '2 days', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('88000000-0000-0000-0000-00000000aa01', '88000000-0000-0000-0000-0000000000c1', 'Специалист 0088'),
  ('88000000-0000-0000-0000-00000000aa03', '88000000-0000-0000-0000-0000000000c3', 'Специалист В 0088');

insert into public.payers (id, center_id, full_name, phone) values
  ('88000000-0000-0000-0000-00000000dd01', '88000000-0000-0000-0000-0000000000c1', 'Плательщик 0088',   '+996700008801'),
  ('88000000-0000-0000-0000-00000000dd03', '88000000-0000-0000-0000-0000000000c3', 'Плательщик В 0088', '+996700008803');

-- 1 owner · 2 admin · 3 registrar · 4 finance · 5 teacher · 6 parent · 7 owner Б · 8 owner В (только чтение).
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('88000000-0000-0000-0000-000000000001', '88000000-0000-0000-0000-0000000000c1', 'owner',     null, null),
  ('88000000-0000-0000-0000-000000000002', '88000000-0000-0000-0000-0000000000c1', 'admin',     null, null),
  ('88000000-0000-0000-0000-000000000003', '88000000-0000-0000-0000-0000000000c1', 'registrar', null, null),
  ('88000000-0000-0000-0000-000000000004', '88000000-0000-0000-0000-0000000000c1', 'finance',   null, null),
  ('88000000-0000-0000-0000-000000000005', '88000000-0000-0000-0000-0000000000c1', 'teacher',   '88000000-0000-0000-0000-00000000aa01', null),
  ('88000000-0000-0000-0000-000000000006', '88000000-0000-0000-0000-0000000000c1', 'parent',    null, '88000000-0000-0000-0000-00000000dd01'),
  ('88000000-0000-0000-0000-000000000007', '88000000-0000-0000-0000-0000000000c2', 'owner',     null, null),
  ('88000000-0000-0000-0000-000000000008', '88000000-0000-0000-0000-0000000000c3', 'owner',     null, null);

insert into public.payment_sources (id, center_id, code, name, sort) values
  ('88000000-0000-0000-0000-0000000005f1', '88000000-0000-0000-0000-0000000000c1', 'test0088', 'Касса 0088', 999);

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('88000000-0000-0000-0000-00000000bb01', '88000000-0000-0000-0000-0000000000c1', 'Логопед 0088', 50000),
  ('88000000-0000-0000-0000-00000000bb02', '88000000-0000-0000-0000-0000000000c1', 'ЛФК 0088',     50000),
  ('88000000-0000-0000-0000-00000000bb03', '88000000-0000-0000-0000-0000000000c3', 'Логопед В 0088', 50000),
  ('88000000-0000-0000-0000-00000000bb04', '88000000-0000-0000-0000-0000000000c1', 'Бесплатно 0088', 0);

insert into public.subscription_types (id, center_id, name, service_id, kind, lessons_count, price_tiyin) values
  ('88000000-0000-0000-0000-0000000007a1', '88000000-0000-0000-0000-0000000000c1', 'Логопед 4 · 0088', '88000000-0000-0000-0000-00000000bb01', 'lessons', 4, 200000),
  ('88000000-0000-0000-0000-0000000007a2', '88000000-0000-0000-0000-0000000000c1', 'ЛФК 4 · 0088',     '88000000-0000-0000-0000-00000000bb02', 'lessons', 4, 200000),
  ('88000000-0000-0000-0000-0000000007a3', '88000000-0000-0000-0000-0000000000c3', 'Логопед В · 0088', '88000000-0000-0000-0000-00000000bb03', 'lessons', 4, 200000);

-- e1 основной · e2 брат/сестра (тот же плательщик) · e3 долг оплачен, есть перерасход · e4 архив абонемента
-- · e5 бесплатная отметка раньше платной.
insert into public.students (id, center_id, full_name, payer_id) values
  ('88000000-0000-0000-0000-00000000ee01', '88000000-0000-0000-0000-0000000000c1', 'Основной 0088',   '88000000-0000-0000-0000-00000000dd01'),
  ('88000000-0000-0000-0000-00000000ee02', '88000000-0000-0000-0000-0000000000c1', 'Брат 0088',       '88000000-0000-0000-0000-00000000dd01'),
  ('88000000-0000-0000-0000-00000000ee03', '88000000-0000-0000-0000-0000000000c1', 'Перерасход 0088', '88000000-0000-0000-0000-00000000dd01'),
  ('88000000-0000-0000-0000-00000000ee04', '88000000-0000-0000-0000-0000000000c1', 'Удаление 0088',   '88000000-0000-0000-0000-00000000dd01'),
  ('88000000-0000-0000-0000-00000000ee05', '88000000-0000-0000-0000-0000000000c1', 'Бесплатно 0088',  '88000000-0000-0000-0000-00000000dd01'),
  ('88000000-0000-0000-0000-00000000ee07', '88000000-0000-0000-0000-0000000000c3', 'Только чтение 0088', '88000000-0000-0000-0000-00000000dd03');

-- Занятия в прошлом, абонементы продаются сегодня: отметки уходят в долг (starts_at > дня занятия).
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at)
select ('88000000-0000-0000-0000-0000000000' || x.code)::uuid, x.center::uuid, x.teacher::uuid, x.service::uuid,
       ('88000000-0000-0000-0000-00000000' || x.student)::uuid, 'planned',
       date_trunc('hour', now()) - interval '5 days' + x.shift * interval '1 hour',
       date_trunc('hour', now()) - interval '5 days' + x.shift * interval '1 hour' + interval '45 minutes'
  from (values
    ('11', 'ee01', 1, '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000aa01', '88000000-0000-0000-0000-00000000bb01'),
    ('12', 'ee01', 2, '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000aa01', '88000000-0000-0000-0000-00000000bb01'),
    ('13', 'ee01', 3, '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000aa01', '88000000-0000-0000-0000-00000000bb01'),
    ('31', 'ee03', 4, '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000aa01', '88000000-0000-0000-0000-00000000bb01'),
    ('41', 'ee04', 5, '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000aa01', '88000000-0000-0000-0000-00000000bb01'),
    ('51', 'ee05', 6, '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000aa01', '88000000-0000-0000-0000-00000000bb04'),
    ('52', 'ee05', 7, '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000aa01', '88000000-0000-0000-0000-00000000bb01'),
    ('71', 'ee07', 1, '88000000-0000-0000-0000-0000000000c3', '88000000-0000-0000-0000-00000000aa03', '88000000-0000-0000-0000-00000000bb03')
  ) as x(code, student, shift, center, teacher, service);

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l
 where l.id::text like '88000000-0000-0000-0000-0000000000__'
 order by l.starts_at;

-- Абонементы (прямой insert из-под postgres; lesson_price = price / lessons_total).
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, allow_negative, lessons_used) values
  -- B1: e1, логопед, 4 занятия.
  ('88000000-0000-0000-0000-0000000055b1', '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000ee01',
   '88000000-0000-0000-0000-00000000dd01', '88000000-0000-0000-0000-0000000007a1', 4, 200000, 50000, current_date, null, false, 0),
  -- B2: e1, другая услуга (ЛФК).
  ('88000000-0000-0000-0000-0000000055b2', '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000ee01',
   '88000000-0000-0000-0000-00000000dd01', '88000000-0000-0000-0000-0000000007a2', 4, 200000, 50000, current_date, null, false, 0),
  -- B3: брат/сестра.
  ('88000000-0000-0000-0000-0000000055b3', '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000ee02',
   '88000000-0000-0000-0000-00000000dd01', '88000000-0000-0000-0000-0000000007a1', 4, 200000, 50000, current_date, null, false, 0),
  -- OD: e3, истёкший пакет 1 занятие, использовано 3 (перерасход 2 × 400).
  ('88000000-0000-0000-0000-0000000055d0', '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000ee03',
   '88000000-0000-0000-0000-00000000dd01', null, 1, 40000, 40000, current_date - 40, current_date - 10, true, 3),
  -- B6: e3, новый пакет логопеда.
  ('88000000-0000-0000-0000-0000000055b6', '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000ee03',
   '88000000-0000-0000-0000-00000000dd01', '88000000-0000-0000-0000-0000000007a1', 4, 200000, 50000, current_date, null, false, 0),
  -- B5: e4, пакет на одно занятие.
  ('88000000-0000-0000-0000-0000000055b5', '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000ee04',
   '88000000-0000-0000-0000-00000000dd01', null, 1, 50000, 50000, current_date, null, false, 0),
  -- B8: e5, пакет без типа (любая услуга).
  ('88000000-0000-0000-0000-0000000055b8', '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000ee05',
   '88000000-0000-0000-0000-00000000dd01', null, 4, 200000, 50000, current_date, null, false, 0),
  -- B7: центр только для чтения.
  ('88000000-0000-0000-0000-0000000055b7', '88000000-0000-0000-0000-0000000000c3', '88000000-0000-0000-0000-00000000ee07',
   '88000000-0000-0000-0000-00000000dd03', '88000000-0000-0000-0000-0000000007a3', 4, 200000, 50000, current_date, null, false, 0);
-- B4: e1, безлимит (lessons_total null).
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, starts_at, ends_at) values
  ('88000000-0000-0000-0000-0000000055b4', '88000000-0000-0000-0000-0000000000c1', '88000000-0000-0000-0000-00000000ee01',
   '88000000-0000-0000-0000-00000000dd01', null, 300000, current_date, current_date + 30);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

-- (долг, перерасход, аванс, остаток) ребёнка и остаток абонемента — коротко для проверок.
create or replace function public.tests_acc(p_student uuid)
  returns text language sql as $$
  select row(coalesce(max(x.debt_tiyin), 0), coalesce(max(x.overdrawn_tiyin), 0),
             coalesce(max(x.credit_tiyin), 0), coalesce(max(x.remaining_tiyin), 0))::text
    from public.lesson_debt_accounts_unchecked('88000000-0000-0000-0000-0000000000c1', p_student) x;
$$;
create or replace function public.tests_left(p_sub uuid)
  returns integer language sql as $$ select public.subscription_lessons_left(p_sub); $$;
create or replace function public.tests_status(p_code text)
  returns uuid language sql as $$
  select s.id from public.attendance_statuses s
   where s.center_id = '88000000-0000-0000-0000-0000000000c1' and s.code = p_code;
$$;


-- 3. Модель (owner) -------------------------------------------------------------------------------

select is(public.tests_acc('88000000-0000-0000-0000-00000000ee01'), '(150000,0,0,150000)', 'Три отметки в долг по 500 — долг 1 500');

select public.tests_claims('88000000-0000-0000-0000-000000000001', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is(
  (select row(p.*)::text from public.cover_lesson_debt_preview('88000000-0000-0000-0000-0000000055b1') p),
  '(3,3,150000,150000,0)', 'Предпросмотр B1: 3 подходящих, покрыть можно 3 на 1 500, аванса после не будет');

select is((select p.can_cover from public.cover_lesson_debt_preview('88000000-0000-0000-0000-0000000055b2') p), 0,
  'Абонемент на другую услугу покрыть не может');
select is((select p.can_cover from public.cover_lesson_debt_preview('88000000-0000-0000-0000-0000000055b4') p), 0,
  'Безлимит покрыть не может');

select lives_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b1', 2, 150000) $$,
  'owner покрывает 2 занятия абонементом B1');

reset role;

select is(public.tests_acc('88000000-0000-0000-0000-00000000ee01'), '(50000,0,0,50000)', 'Долг уменьшился до 500');
select is(public.tests_left('88000000-0000-0000-0000-0000000055b1'), 2, 'B1: осталось 2 занятия из 4');
select is(
  (select count(*)::int from public.attendance a
    where a.student_id = '88000000-0000-0000-0000-00000000ee01' and a.subscription_id is null and a.deducted),
  3, 'История отметок не переписана: все три по-прежнему без абонемента');
select is(
  (select array_agg(l.id::text order by l.starts_at) from public.lesson_debt_covers c
     join public.attendance a on a.id = c.attendance_id join public.lessons l on l.id = a.lesson_id
    where c.subscription_id = '88000000-0000-0000-0000-0000000055b1' and c.deleted_at is null),
  array['88000000-0000-0000-0000-000000000011', '88000000-0000-0000-0000-000000000012'],
  'Покрыты две самые старые отметки');
select ok(
  exists (select 1 from public.events e
           where e.type = 'lesson_debt.covered'
             and e.payload ?& array['center_id', 'subscription_id', 'student_id', 'lessons', 'amount_tiyin']
             and (e.payload ->> 'amount_tiyin')::int = 100000),
  'Событие lesson_debt.covered: два занятия на 1 000');


-- 4. Границы --------------------------------------------------------------------------------------

select public.tests_claims('88000000-0000-0000-0000-000000000001', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select throws_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b1', 1, 150000) $$,
  '23514', null, 'Устаревший expected — 23514 со свежей суммой');
select throws_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b1', 5, 50000) $$,
  '22023', null, 'Больше, чем можно покрыть, — 22023');
select throws_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b2', 1, 50000) $$,
  '22023', null, 'Другая услуга — 22023');
select throws_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b4', 1, 50000) $$,
  '22023', null, 'Безлимит — 22023');

reset role;

select throws_ok(
  $$ insert into public.lesson_debt_covers (center_id, attendance_id, subscription_id, student_id, price_tiyin)
     select '88000000-0000-0000-0000-0000000000c1', a.id, '88000000-0000-0000-0000-0000000055b3',
            '88000000-0000-0000-0000-00000000ee01', 0
       from public.attendance a where a.lesson_id = '88000000-0000-0000-0000-000000000013' $$,
  '23503', null, 'Абонементом брата/сестры не покрыть — FK');
select throws_ok(
  $$ insert into public.lesson_debt_covers (center_id, attendance_id, subscription_id, student_id, price_tiyin)
     select '88000000-0000-0000-0000-0000000000c1', a.id, '88000000-0000-0000-0000-0000000055b1',
            '88000000-0000-0000-0000-00000000ee01', 0
       from public.attendance a where a.lesson_id = '88000000-0000-0000-0000-000000000011' $$,
  '23505', null, 'Повторное покрытие той же отметки — 23505');


-- 5. Задним числом (Р3) ---------------------------------------------------------------------------

select public.tests_claims('88000000-0000-0000-0000-000000000001', '88000000-0000-0000-0000-0000000000c1');
update public.attendance set status_id = public.tests_status('sick')
 where lesson_id = '88000000-0000-0000-0000-000000000011';

select is(
  (select c.closed_reason from public.lesson_debt_covers c join public.attendance a on a.id = c.attendance_id
    where a.lesson_id = '88000000-0000-0000-0000-000000000011'),
  'attendance_changed', '«Пришёл → болел»: покрытие закрыто');
select is(public.tests_left('88000000-0000-0000-0000-0000000055b1'), 3, 'B1 вернул занятие: осталось 3');

select lives_ok(
  $$ update public.attendance set status_id = public.tests_status('present')
      where lesson_id = '88000000-0000-0000-0000-000000000011' $$,
  'Обратно «пришёл» — правка проходит, CHECK не стреляет');
select is(public.tests_acc('88000000-0000-0000-0000-00000000ee01'), '(100000,0,0,100000)', 'Снова долг: 500 за L11 и 500 за L13');
select is(public.tests_left('88000000-0000-0000-0000-0000000055b1'), 3, 'Покрытие не ожило: B1 по-прежнему 3');

update public.lessons set status = 'cancelled' where id = '88000000-0000-0000-0000-000000000012';
select is(
  (select c.closed_reason from public.lesson_debt_covers c join public.attendance a on a.id = c.attendance_id
    where a.lesson_id = '88000000-0000-0000-0000-000000000012'),
  'lesson_cancelled', 'Отмена занятия закрывает покрытие');
select is(public.tests_left('88000000-0000-0000-0000-0000000055b1'), 4, 'B1 вернул и это занятие: снова 4');
select is(public.tests_acc('88000000-0000-0000-0000-00000000ee01'), '(100000,0,0,100000)', 'Отменённое занятие в долг не начисляется');


-- 6. Снятие покрытия вручную ----------------------------------------------------------------------

select public.tests_claims('88000000-0000-0000-0000-000000000003', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b1', 1, 100000) $$,
  'registrar покрывает одно занятие');
reset role;
select is(public.tests_acc('88000000-0000-0000-0000-00000000ee01'), '(50000,0,0,50000)', 'Долг 500');

select public.tests_claims('88000000-0000-0000-0000-000000000002', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.uncover_lesson_debt(
       (select c.id from public.lesson_debt_covers c where c.subscription_id = '88000000-0000-0000-0000-0000000055b1'
          and c.deleted_at is null)) $$,
  'admin снимает ошибочное покрытие');
reset role;
select is(public.tests_acc('88000000-0000-0000-0000-00000000ee01'), '(100000,0,0,100000)', 'После снятия долг вернулся');
select is(public.tests_left('88000000-0000-0000-0000-0000000055b1'), 4, 'и занятие вернулось абонементу');


-- 7. Перерасход как долг (Р5) ---------------------------------------------------------------------

select public.tests_claims('88000000-0000-0000-0000-000000000001', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.accept_lesson_debt_payment('88000000-0000-0000-0000-00000000ee03', 50000,
       '88000000-0000-0000-0000-0000000005f1', null, 130000) $$,
  'e3: оплата 500 при долге 500 и перерасходе 800');
reset role;
select is(public.tests_acc('88000000-0000-0000-0000-00000000ee03'), '(0,80000,0,80000)', 'Долг за занятия оплачен, остался перерасход 800');

select public.tests_claims('88000000-0000-0000-0000-000000000001', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b6', 1, 80000) $$,
  'Покрытие оплаченной отметки новым пакетом');
reset role;
select is(public.tests_acc('88000000-0000-0000-0000-00000000ee03'), '(0,30000,0,30000)', 'Освободившиеся 500 погасили перерасход: осталось 300');


-- 8. Последнее занятие и архив абонемента ------------------------------------------------------

select public.tests_claims('88000000-0000-0000-0000-000000000001', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b5', 1, 50000) $$,
  'e4: пакет на одно занятие покрывает долг');
reset role;
select is(
  (select count(*)::int from public.events e
    where e.type = 'subscription.exhausted' and e.payload ->> 'subscription_id' = '88000000-0000-0000-0000-0000000055b5'),
  1, 'subscription.exhausted — один раз, когда покрытие съело последнее занятие');

-- Исчерпанный абонемент уходит в архив — оплаченное им занятие остаётся оплаченным.
update public.subscriptions set deleted_at = now() where id = '88000000-0000-0000-0000-0000000055b5';
select is(
  (select count(*)::int from public.lesson_debt_covers c
    where c.subscription_id = '88000000-0000-0000-0000-0000000055b5' and c.deleted_at is null),
  1, 'Архив абонемента покрытие не закрывает');
select is(public.tests_acc('88000000-0000-0000-0000-00000000ee04'), '(0,0,0,0)', 'и долг не возвращается');

-- Бесплатная отметка (цена 0) места абонемента не занимает.
select public.tests_claims('88000000-0000-0000-0000-000000000001', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select row(p.can_cover, p.amount_tiyin)::text from public.cover_lesson_debt_preview('88000000-0000-0000-0000-0000000055b8') p),
  '(1,50000)', 'Бесплатное занятие пропущено: покрывается только платное');
reset role;

-- Покрытие можно только закрыть, не переписать.
select throws_ok(
  $$ update public.lesson_debt_covers set subscription_id = '88000000-0000-0000-0000-0000000055b1'
      where subscription_id = '88000000-0000-0000-0000-0000000055b5' $$,
  '22023', null, 'Покрытие нельзя переписать на другой абонемент');


-- 9. Права ----------------------------------------------------------------------------------------

select public.tests_claims('88000000-0000-0000-0000-000000000004', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b1', 1, 100000) $$,
  '42501', null, 'finance занятиями абонемента не распоряжается');
reset role;

select public.tests_claims('88000000-0000-0000-0000-000000000005', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select * from public.cover_lesson_debt_preview('88000000-0000-0000-0000-0000000055b1') $$,
  '42501', null, 'teacher: предпросмотр закрыт');
reset role;

select public.tests_claims('88000000-0000-0000-0000-000000000006', '88000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b1', 1, 100000) $$,
  '42501', null, 'parent покрывать не может');
reset role;

select public.tests_claims('88000000-0000-0000-0000-000000000007', '88000000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_ok(
  $$ select * from public.cover_lesson_debt_preview('88000000-0000-0000-0000-0000000055b1') $$,
  '42704', null, 'Чужой центр — «абонемент не найден»');
reset role;

select public.tests_claims('88000000-0000-0000-0000-000000000008', '88000000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $$ select public.cover_lesson_debt('88000000-0000-0000-0000-0000000055b7', 1, 50000) $$,
  'PT402', null, 'Центр только для чтения: долг абонементом не покрыть');
reset role;

select * from finish();
rollback;
