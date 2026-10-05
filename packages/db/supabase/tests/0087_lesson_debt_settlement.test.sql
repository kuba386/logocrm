-- pgTAP: долг за занятия гасится оплатой и списанием (0087).
--
-- Модель: начислено (отметки без абонемента у живых занятий) + валовой
-- перерасход по всем пакетам − оплачено (только covers_lesson_debt) −
-- списано. Платёж без флага (случай с prod: 6 400 «за 8 занятий») долг не
-- трогает. Переплата — аванс, следующая отметка его съедает; аванс до
-- первой отметки виден. Перерасход на истёкшем абонементе не пропадает и
-- гасится оплатой. Списание никогда не даёт аванс (отмена занятия после
-- списания). Границы — триггеры: возврат не больше аванса, списание не
-- больше остатка. Устаревший p_expected_* — 23514. Права: оплата —
-- can_payments, списание — только owner; parent видит детей своего
-- плательщика, teacher и чужой центр — пусто. Заборы: политики, ACL,
-- гранты внутренних функций, одна перегрузка record_payment, порядок
-- колонок student_balance, readonly guard, export allow-list.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(45);


-- 1. Каталог --------------------------------------------------------------------------------------

select ok(
  exists (select 1 from pg_constraint where conname = 'payments_lesson_debt_shape' and conrelid = 'public.payments'::regclass),
  'CHECK payments_lesson_debt_shape на месте');

select is_empty(
  $$ select policyname from pg_policies
      where schemaname = 'public' and tablename = 'lesson_debt_writeoffs' and cmd <> 'SELECT' $$,
  'lesson_debt_writeoffs: ни одной политики на запись — только через RPC');

select is_empty(
  $$ select a.grantee::regrole::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where c.oid = 'public.lesson_debt_writeoffs'::regclass
        and a.grantee <> c.relowner
        and not (a.grantee = 'authenticated'::regrole and a.privilege_type = 'SELECT') $$,
  'lesson_debt_writeoffs: authenticated — только SELECT, у anon и service_role нет ничего');

select is_empty(
  $$ select p.oid::regprocedure::text || ' ' || r
       from pg_proc p, unnest(array['public', 'anon', 'authenticated', 'service_role']) r
      where p.oid in ('public.lesson_debt_lock(uuid)'::regprocedure,
                      'public.lesson_debt_accounts_unchecked(uuid,uuid)'::regprocedure,
                      'public.record_payment_core(uuid,integer,text,uuid,uuid,uuid,timestamptz,text,date,boolean)'::regprocedure,
                      'public.payments_lesson_debt_guard()'::regprocedure,
                      'public.lesson_debt_writeoffs_guard()'::regprocedure)
        and has_function_privilege(r, p.oid, 'EXECUTE') $$,
  'Внутренние функции 0087 не исполняет ни одна роль приложения');

select is(
  (select count(*)::int from pg_proc where pronamespace = 'public'::regnamespace and proname = 'record_payment'),
  1, 'record_payment — одна перегрузка (без PGRST203)');

select is(
  (select array_agg(a.attname::text order by a.attnum) from pg_attribute a
    where a.attrelid = 'public.student_balance'::regclass and a.attnum > 0 and not a.attisdropped),
  array['student_id', 'center_id', 'active_subscription_id', 'lessons_left', 'ends_at', 'debt_tiyin',
        'overdrawn_tiyin', 'state', 'subscription_overdue_tiyin', 'subscription_overdue_payer_id', 'lesson_credit_tiyin'],
  'student_balance: первые десять колонок как в 0070, аванс — одиннадцатой');

select ok(
  exists (select 1 from pg_trigger where tgrelid = 'public.lesson_debt_writeoffs'::regclass and tgname = 'a00_readonly_guard')
  and exists (select 1 from public.export_center_tables() x where x.table_name = 'lesson_debt_writeoffs'),
  'lesson_debt_writeoffs: readonly guard (0050) и экспорт центра (0056)');


-- 2. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('87000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0087@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 7) n;

insert into public.centers (id, name, slug, settings) values
  ('87000000-0000-0000-0000-0000000000c1', 'Центр 0087',   'centr-0087',   '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('87000000-0000-0000-0000-0000000000c2', 'Центр Б 0087', 'centr-0087-b', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('87000000-0000-0000-0000-00000000aa01', '87000000-0000-0000-0000-0000000000c1', 'Специалист 0087');

insert into public.payers (id, center_id, full_name, phone) values
  ('87000000-0000-0000-0000-00000000dd01', '87000000-0000-0000-0000-0000000000c1', 'Плательщик 1 0087', '+996700008701'),
  ('87000000-0000-0000-0000-00000000dd02', '87000000-0000-0000-0000-0000000000c1', 'Плательщик 2 0087', '+996700008702');

-- 1 owner · 2 admin · 3 registrar · 4 finance · 5 teacher · 6 parent (payer 1) · 7 owner центра Б.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('87000000-0000-0000-0000-000000000001', '87000000-0000-0000-0000-0000000000c1', 'owner',     null, null),
  ('87000000-0000-0000-0000-000000000002', '87000000-0000-0000-0000-0000000000c1', 'admin',     null, null),
  ('87000000-0000-0000-0000-000000000003', '87000000-0000-0000-0000-0000000000c1', 'registrar', null, null),
  ('87000000-0000-0000-0000-000000000004', '87000000-0000-0000-0000-0000000000c1', 'finance',   null, null),
  ('87000000-0000-0000-0000-000000000005', '87000000-0000-0000-0000-0000000000c1', 'teacher',   '87000000-0000-0000-0000-00000000aa01', null),
  ('87000000-0000-0000-0000-000000000006', '87000000-0000-0000-0000-0000000000c1', 'parent',    null, '87000000-0000-0000-0000-00000000dd01'),
  ('87000000-0000-0000-0000-000000000007', '87000000-0000-0000-0000-0000000000c2', 'owner',     null, null);

insert into public.payment_sources (id, center_id, code, name, sort) values
  ('87000000-0000-0000-0000-0000000005f1', '87000000-0000-0000-0000-0000000000c1', 'test0087', 'Касса 0087', 999);

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('87000000-0000-0000-0000-00000000bb01', '87000000-0000-0000-0000-0000000000c1', 'Логопед 0087', 50000);

-- e1 долг · e2 перерасход на истёкшем пакете · e3 аванс до отметок · e4 списание ·
-- e5 случай с prod (платёж без флага) · e6 — ребёнок другого плательщика.
insert into public.students (id, center_id, full_name, payer_id) values
  ('87000000-0000-0000-0000-00000000ee01', '87000000-0000-0000-0000-0000000000c1', 'Долг 0087',       '87000000-0000-0000-0000-00000000dd01'),
  ('87000000-0000-0000-0000-00000000ee02', '87000000-0000-0000-0000-0000000000c1', 'Перерасход 0087', '87000000-0000-0000-0000-00000000dd01'),
  ('87000000-0000-0000-0000-00000000ee03', '87000000-0000-0000-0000-0000000000c1', 'Аванс 0087',      '87000000-0000-0000-0000-00000000dd01'),
  ('87000000-0000-0000-0000-00000000ee04', '87000000-0000-0000-0000-0000000000c1', 'Списание 0087',   '87000000-0000-0000-0000-00000000dd01'),
  ('87000000-0000-0000-0000-00000000ee05', '87000000-0000-0000-0000-0000000000c1', 'Prod 0087',       '87000000-0000-0000-0000-00000000dd01'),
  ('87000000-0000-0000-0000-00000000ee06', '87000000-0000-0000-0000-0000000000c1', 'Чужая семья 0087','87000000-0000-0000-0000-00000000dd02');

-- Истёкший пакет на 1 занятие, использовано 3 (allow_negative) — перерасход 2 × 400.
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, lessons_used, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, allow_negative) values
  ('87000000-0000-0000-0000-000000005502', '87000000-0000-0000-0000-0000000000c1', '87000000-0000-0000-0000-00000000ee02',
   '87000000-0000-0000-0000-00000000dd01', 1, 3, 40000, 40000, current_date - 40, current_date - 10, true);

-- Занятия одного специалиста, окна не пересекаются (EXCLUDE 0006). e1: три в долг + одно позже.
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at)
select ('87000000-0000-0000-0000-0000000000' || x.code)::uuid, '87000000-0000-0000-0000-0000000000c1',
       '87000000-0000-0000-0000-00000000aa01', '87000000-0000-0000-0000-00000000bb01',
       ('87000000-0000-0000-0000-00000000' || x.student)::uuid, 'planned',
       date_trunc('hour', now()) - interval '3 days' - x.shift * interval '1 hour',
       date_trunc('hour', now()) - interval '3 days' - x.shift * interval '1 hour' + interval '45 minutes'
  from (values ('11', 'ee01', 1), ('12', 'ee01', 2), ('13', 'ee01', 3), ('14', 'ee01', 4),
               ('41', 'ee04', 5), ('42', 'ee04', 6), ('51', 'ee05', 7), ('61', 'ee06', 8)) as x(code, student, shift);

-- Отметки «пришёл» без абонемента — в долг по цене услуги (500). L14 отмечается позже.
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l
 where l.id::text like '87000000-0000-0000-0000-0000000000__' and l.id <> '87000000-0000-0000-0000-000000000014'
 order by l.starts_at;

-- Случай с prod: платёж без абонемента и без флага.
insert into public.payments (center_id, payer_id, student_id, amount_tiyin, source_id, kind, comment)
values ('87000000-0000-0000-0000-0000000000c1', '87000000-0000-0000-0000-00000000dd01', '87000000-0000-0000-0000-00000000ee05',
        640000, '87000000-0000-0000-0000-0000000005f1', 'payment', 'за 8 занятий');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

-- Счёт одного ребёнка от лица владельца — коротко для проверок ниже.
create or replace function public.tests_acc(p_student uuid)
  returns table (debt integer, overdrawn integer, credit integer, remaining integer)
  language sql as $$
  select coalesce(max(a.debt_tiyin), 0), coalesce(max(a.overdrawn_tiyin), 0),
         coalesce(max(a.credit_tiyin), 0), coalesce(max(a.remaining_tiyin), 0)
    from public.lesson_debt_account() a where a.student_id = p_student;
$$;
grant execute on function public.tests_acc(uuid) to authenticated;


-- 3. Модель (owner) -------------------------------------------------------------------------------

select public.tests_claims('87000000-0000-0000-0000-000000000001', '87000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee01') t), '(150000,0,0,150000)',
  'Три отметки в долг по 500 — долг 1 500');

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee05') t), '(50000,0,0,50000)',
  'Случай с prod: платёж 6 400 без флага долг 500 не гасит и аванса не даёт');

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee02') t), '(0,80000,0,80000)',
  'Перерасход на истёкшем пакете не пропадает: 2 × 400');

select is((select b.debt_tiyin from public.student_balance b where b.student_id = '87000000-0000-0000-0000-00000000ee01'), 150000,
  'student_balance.debt_tiyin — из того же счёта');

select lives_ok(
  $$ select public.accept_lesson_debt_payment('87000000-0000-0000-0000-00000000ee01', 100000,
       '87000000-0000-0000-0000-0000000005f1', null, 150000) $$,
  'Оплата 1 000 при долге 1 500 проходит');

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee01') t), '(50000,0,0,50000)',
  'Оплата гасит долг: осталось 500');

select throws_ok(
  $$ select public.accept_lesson_debt_payment('87000000-0000-0000-0000-00000000ee01', 50000,
       '87000000-0000-0000-0000-0000000005f1', null, 150000) $$,
  '23514', null, 'Устаревший p_expected_remaining_tiyin — 23514, без автоповтора');

select lives_ok(
  $$ select public.accept_lesson_debt_payment('87000000-0000-0000-0000-00000000ee01', 80000,
       '87000000-0000-0000-0000-0000000005f1', null, 50000) $$,
  'Переплата 800 при долге 500 проходит');

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee01') t), '(0,0,30000,0)',
  'Переплата — аванс 300');

reset role;

select ok(
  exists (select 1 from public.events e
           where e.type = 'payment.received'
             and e.payload ->> 'student_id' = '87000000-0000-0000-0000-00000000ee01'
             and (e.payload ->> 'covers_lesson_debt')::boolean),
  'payment.received несёт covers_lesson_debt = true');

-- Новая отметка в долг съедает аванс: начислено 2 000, оплачено 1 800.
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l where l.id = '87000000-0000-0000-0000-000000000014';

select public.tests_claims('87000000-0000-0000-0000-000000000001', '87000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee01') t), '(20000,0,0,20000)',
  'Следующая отметка съела аванс: долг 200');

select throws_ok(
  $$ select public.refund_lesson_debt_credit('87000000-0000-0000-0000-00000000ee01', 100,
       '87000000-0000-0000-0000-0000000005f1', null, 0) $$,
  '22023', null, 'Возврат больше аванса (аванс 0) — отказ триггера: возврат не создаёт долг');

select throws_ok(
  $$ select public.accept_lesson_debt_payment('87000000-0000-0000-0000-00000000ee03', 10000,
       '87000000-0000-0000-0000-0000000005f1', null, 0) $$,
  '22023', null, 'Долга нет — принимать нечего');

select lives_ok(
  $$ select public.accept_lesson_debt_payment('87000000-0000-0000-0000-00000000ee02', 50000,
       '87000000-0000-0000-0000-0000000005f1', null, 80000) $$,
  'Оплата перерасхода как долга проходит');

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee02') t), '(0,30000,0,30000)',
  'Перерасход 800 − 500 = 300, ложного аванса нет');

reset role;

-- Аванс до первой отметки — только прямой записью (RPC без долга отказывает).
insert into public.payments (center_id, payer_id, student_id, amount_tiyin, source_id, kind, comment, covers_lesson_debt)
values ('87000000-0000-0000-0000-0000000000c1', '87000000-0000-0000-0000-00000000dd01', '87000000-0000-0000-0000-00000000ee03',
        300000, '87000000-0000-0000-0000-0000000005f1', 'payment', 'аванс', true);

select public.tests_claims('87000000-0000-0000-0000-000000000001', '87000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee03') t), '(0,0,300000,0)',
  'Аванс до первой отметки виден: 3 000');

select lives_ok(
  $$ select public.refund_lesson_debt_credit('87000000-0000-0000-0000-00000000ee03', 100000,
       '87000000-0000-0000-0000-0000000005f1', null, 300000) $$,
  'Возврат 1 000 в пределах аванса проходит');

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee03') t), '(0,0,200000,0)',
  'Аванс уменьшился до 2 000, долг не появился');


-- 4. Списание -------------------------------------------------------------------------------------

select throws_ok(
  $$ select public.write_off_lesson_debt('87000000-0000-0000-0000-00000000ee04', 10000, '   ', 100000) $$,
  '22023', null, 'Списание без причины — отказ');

select throws_ok(
  $$ select public.write_off_lesson_debt('87000000-0000-0000-0000-00000000ee04', 120000, 'больше долга', 100000) $$,
  '22023', null, 'Списать больше остатка нельзя — граница в триггере');

select lives_ok(
  $$ select public.write_off_lesson_debt('87000000-0000-0000-0000-00000000ee04', 60000, 'семья в трудной ситуации', 100000) $$,
  'owner списывает 600 из 1 000');

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee04') t), '(40000,0,0,40000)',
  'После списания осталось 400');

reset role;

select ok(
  exists (select 1 from public.events e
           where e.type = 'lesson_debt.written_off'
             and e.payload ?& array['center_id', 'writeoff_id', 'student_id', 'amount_tiyin']
             and not (e.payload ? 'reason')),
  'Событие lesson_debt.written_off — с ключами, без причины в payload');

select ok(
  exists (select 1 from public.audit_log a where a.table_name = 'lesson_debt_writeoffs' and a.action = 'INSERT'),
  'Списание попало в audit_log');

-- Отмена занятия после списания: начислено 500, списано 600 — долга нет, аванса тоже.
update public.lessons set status = 'cancelled' where id = '87000000-0000-0000-0000-000000000042';

select public.tests_claims('87000000-0000-0000-0000-000000000001', '87000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is((select row(t.*)::text from public.tests_acc('87000000-0000-0000-0000-00000000ee04') t), '(0,0,0,0)',
  'Отменённое занятие не начисляется, а списание никогда не становится авансом');

reset role;


-- 5. Границы прямой записью и форма флага ---------------------------------------------------------

select throws_ok(
  $$ insert into public.lesson_debt_writeoffs (center_id, student_id, amount_tiyin, reason)
     values ('87000000-0000-0000-0000-0000000000c1', '87000000-0000-0000-0000-00000000ee05', 999999, 'мимо RPC') $$,
  '22023', null, 'Прямой insert списания больше остатка — отказ и из-под postgres');

select throws_ok(
  $$ insert into public.payments (center_id, payer_id, student_id, subscription_id, amount_tiyin, kind, covers_lesson_debt)
     values ('87000000-0000-0000-0000-0000000000c1', '87000000-0000-0000-0000-00000000dd01', '87000000-0000-0000-0000-00000000ee02',
             '87000000-0000-0000-0000-000000005502', 1000, 'payment', true) $$,
  '23514', null, 'Флаг долга на платеже за абонемент — 23514');

select throws_ok(
  $$ insert into public.payments (center_id, payer_id, student_id, amount_tiyin, kind, covers_lesson_debt)
     values ('87000000-0000-0000-0000-0000000000c1', '87000000-0000-0000-0000-00000000dd01', '87000000-0000-0000-0000-00000000ee05',
             1000, 'correction', true) $$,
  '23514', null, 'Флаг долга на корректировке — 23514');


-- 6. Права ----------------------------------------------------------------------------------------

select public.tests_claims('87000000-0000-0000-0000-000000000003', '87000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.accept_lesson_debt_payment('87000000-0000-0000-0000-00000000ee05', 10000,
       '87000000-0000-0000-0000-0000000005f1', null, 50000) $$,
  'registrar принимает оплату долга');
reset role;

select public.tests_claims('87000000-0000-0000-0000-000000000004', '87000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.accept_lesson_debt_payment('87000000-0000-0000-0000-00000000ee05', 10000,
       '87000000-0000-0000-0000-0000000005f1', null, 40000) $$,
  'finance принимает оплату долга');
reset role;

select public.tests_claims('87000000-0000-0000-0000-000000000002', '87000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.write_off_lesson_debt('87000000-0000-0000-0000-00000000ee05', 1000, 'админ', 30000) $$,
  '42501', null, 'admin списывать не может — только owner');
reset role;

select public.tests_claims('87000000-0000-0000-0000-000000000005', '87000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.accept_lesson_debt_payment('87000000-0000-0000-0000-00000000ee05', 1000,
       '87000000-0000-0000-0000-0000000005f1', null, 30000) $$,
  '42501', null, 'teacher принимать оплату не может');
select is_empty($$ select * from public.lesson_debt_account() $$, 'teacher: счёт занятий пуст');
reset role;

select public.tests_claims('87000000-0000-0000-0000-000000000006', '87000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.accept_lesson_debt_payment('87000000-0000-0000-0000-00000000ee05', 1000,
       '87000000-0000-0000-0000-0000000005f1', null, 30000) $$,
  '42501', null, 'parent принимать оплату не может');
select is((select a.debt_tiyin from public.lesson_debt_account() a where a.student_id = '87000000-0000-0000-0000-00000000ee05'), 30000,
  'parent видит долг своего ребёнка — ту же сумму, что стойка');
select is_empty(
  $$ select * from public.lesson_debt_account() a where a.student_id = '87000000-0000-0000-0000-00000000ee06' $$,
  'parent не видит ребёнка другого плательщика');
reset role;

select public.tests_claims('87000000-0000-0000-0000-000000000007', '87000000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is_empty($$ select * from public.lesson_debt_account() $$, 'Владелец другого центра чужих долгов не видит');
select throws_ok(
  $$ select public.accept_lesson_debt_payment('87000000-0000-0000-0000-00000000ee05', 1000,
       '87000000-0000-0000-0000-0000000005f1', null, 30000) $$,
  '42704', null, 'Чужой ребёнок — «не найден»');
reset role;

select * from finish();
rollback;
