-- pgTAP: перерасход не теряется при возврате и архиве абонемента (0089).
--
-- Р3: «к возврату» у перерасходованного пакета — 0, не минус (общий случай с
-- Vitest refundAmount: 8 занятий по 500, отходил 10 — настоящими отметками).
-- Р2: возврат такого пакета проходит, written_off не уходит в минус,
-- перерасход остаётся долгом. Р1: архив пакета перерасход не стирает, счёт
-- идёт по отметкам («пришёл → болел» после архива его уменьшает), а внесённая
-- до архива оплата долга не становится авансом. Ветка written_off > 0 —
-- подделанное состояние (штатно недостижимо), защита от ручной правки.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(21);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
) values
  ('00000000-0000-0000-0000-000000000000', '89000000-0000-0000-0000-000000000001',
   'authenticated', 'authenticated', 'u1-0089@test.kg', '', '', '', '', '', '', '', '');

insert into public.centers (id, name, slug, settings) values
  ('89000000-0000-0000-0000-0000000000c1', 'Центр 0089', 'centr-0089', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.memberships (user_id, center_id, role) values
  ('89000000-0000-0000-0000-000000000001', '89000000-0000-0000-0000-0000000000c1', 'owner');

insert into public.payers (id, center_id, full_name, phone) values
  ('89000000-0000-0000-0000-00000000dd01', '89000000-0000-0000-0000-0000000000c1', 'Плательщик 0089', '+996700008901');

insert into public.teachers (id, center_id, full_name) values
  ('89000000-0000-0000-0000-00000000aa01', '89000000-0000-0000-0000-0000000000c1', 'Специалист 0089');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('89000000-0000-0000-0000-00000000bb01', '89000000-0000-0000-0000-0000000000c1', 'Логопед 0089', 50000);

insert into public.payment_sources (id, center_id, code, name, sort) values
  ('89000000-0000-0000-0000-0000000005f1', '89000000-0000-0000-0000-0000000000c1', 'test0089', 'Касса 0089', 999);

-- e1 возврат перерасходованного · e2 оплата долга, потом архив · e3 перенос, потом перерасход.
insert into public.students (id, center_id, full_name, payer_id) values
  ('89000000-0000-0000-0000-00000000ee01', '89000000-0000-0000-0000-0000000000c1', 'Возврат 0089', '89000000-0000-0000-0000-00000000dd01'),
  ('89000000-0000-0000-0000-00000000ee02', '89000000-0000-0000-0000-0000000000c1', 'Архив 0089',   '89000000-0000-0000-0000-00000000dd01'),
  ('89000000-0000-0000-0000-00000000ee03', '89000000-0000-0000-0000-0000000000c1', 'Перенос 0089', '89000000-0000-0000-0000-00000000dd01');

-- S1: 8 по 500 с allow_negative; 10 отметок «пришёл» набирают used настоящим пересчётом.
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, allow_negative) values
  ('89000000-0000-0000-0000-0000000055a1', '89000000-0000-0000-0000-0000000000c1', '89000000-0000-0000-0000-00000000ee01',
   '89000000-0000-0000-0000-00000000dd01', 8, 400000, 50000, current_date - 40, null, true);

insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at)
select ('89000000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid,
       '89000000-0000-0000-0000-0000000000c1', '89000000-0000-0000-0000-00000000aa01',
       '89000000-0000-0000-0000-00000000bb01', '89000000-0000-0000-0000-00000000ee01', 'planned',
       date_trunc('hour', now()) - n * interval '1 day',
       date_trunc('hour', now()) - n * interval '1 day' + interval '45 minutes'
  from generate_series(1, 10) n;

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select l.center_id, l.id, l.student_id,
       (select s.id from public.attendance_statuses s where s.center_id = l.center_id and s.code = 'present')
  from public.lessons l
 where l.student_id = '89000000-0000-0000-0000-00000000ee01'
 order by l.starts_at;

-- S2, S3 — прямой insert из-под postgres с литералом lessons_used (как OD в 0088): пересчёт их не трогает.
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, allow_negative,
                                  lessons_used, lessons_written_off) values
  -- S2: 1 по 400, отходил 3 — перерасход 2 × 400.
  ('89000000-0000-0000-0000-0000000055a2', '89000000-0000-0000-0000-0000000000c1', '89000000-0000-0000-0000-00000000ee02',
   '89000000-0000-0000-0000-00000000dd01', 1, 40000, 40000, current_date - 40, null, true, 3, 0),
  -- S3: ПОДДЕЛАНО — живой пакет с written_off 3 штатно не бывает (refund и
  -- transfer отменяют пакет); 4 по 500, used 3 — остаток −2.
  ('89000000-0000-0000-0000-0000000055a3', '89000000-0000-0000-0000-0000000000c1', '89000000-0000-0000-0000-00000000ee03',
   '89000000-0000-0000-0000-00000000dd01', 4, 200000, 50000, current_date - 40, null, true, 3, 3);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create or replace function public.tests_status(p_code text)
  returns uuid language sql as $$
  select s.id from public.attendance_statuses s
   where s.center_id = '89000000-0000-0000-0000-0000000000c1' and s.code = p_code;
$$;

-- (долг, перерасход, аванс, остаток) — из-под postgres.
create or replace function public.tests_acc(p_student uuid)
  returns text language sql as $$
  select row(coalesce(max(x.debt_tiyin), 0), coalesce(max(x.overdrawn_tiyin), 0),
             coalesce(max(x.credit_tiyin), 0), coalesce(max(x.remaining_tiyin), 0))::text
    from public.lesson_debt_accounts_unchecked('89000000-0000-0000-0000-0000000000c1', p_student) x;
$$;


-- 2. Возврат перерасходованного пакета (Р2, Р3) ---------------------------------------------------

select is(
  (select row(s.lessons_used, public.subscription_lessons_left(s.id))::text
     from public.subscriptions s where s.id = '89000000-0000-0000-0000-0000000055a1'),
  '(10,-2)', 'Фикстура: 10 отметок по пакету на 8 — остаток −2');
select is(public.tests_acc('89000000-0000-0000-0000-00000000ee01'), '(0,100000,0,100000)', 'Перерасход 2 × 500 — долг 1 000');

select public.tests_claims('89000000-0000-0000-0000-000000000001', '89000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(public.refund_calc('89000000-0000-0000-0000-0000000055a1'), 0,
  'К возврату 0, не минус — как refundAmount в packages/core (8 занятий, отходил 10)');
select is(
  (select x.refund_tiyin from public.subscription_summary('89000000-0000-0000-0000-0000000055a1') x), 0,
  'И в карточке (subscription_summary.refund_tiyin) — 0');
select lives_ok(
  $$ select public.refund_subscription('89000000-0000-0000-0000-0000000055a1', 0, null) $$,
  'Перерасходованный пакет отменяется (раньше — CHECK lessons_written_off >= 0)');
reset role;

select is(
  (select row(s.status, s.lessons_written_off)::text from public.subscriptions s where s.id = '89000000-0000-0000-0000-0000000055a1'),
  '(cancelled,0)', 'Отменён, written_off не ушёл в минус');
select is(public.tests_acc('89000000-0000-0000-0000-00000000ee01'), '(0,100000,0,100000)', 'Перерасход после возврата остался долгом');
select is(
  (select row(e.payload ->> 'lessons', e.payload ->> 'amount_tiyin', e.payload ->> 'refund_tiyin')::text from public.events e
    where e.type = 'subscription.refunded' and e.payload ->> 'subscription_id' = '89000000-0000-0000-0000-0000000055a1'),
  '(0,0,0)', 'subscription.refunded: 0 занятий, 0 к возврату, 0 выплачено — не минусы');
select is(
  (select count(*)::int from public.payments p where p.subscription_id = '89000000-0000-0000-0000-0000000055a1'),
  0, 'Платёжной строки возврата нет — возвращать нечего');

update public.subscriptions set deleted_at = now() where id = '89000000-0000-0000-0000-0000000055a1';
select is(public.tests_acc('89000000-0000-0000-0000-00000000ee01'), '(0,100000,0,100000)', 'Архив пакета перерасход не стирает (Р1)');

-- Счёт по факту отметок, а не по живым пакетам: правка задним числом после архива.
select public.tests_claims('89000000-0000-0000-0000-000000000001', '89000000-0000-0000-0000-0000000000c1');
update public.attendance set status_id = public.tests_status('sick')
 where lesson_id = '89000000-0000-0000-0000-000000000101';
select is(public.tests_acc('89000000-0000-0000-0000-00000000ee01'), '(0,50000,0,50000)',
  '«Пришёл → болел» у архивного пакета уменьшает перерасход до 1 × 500');


-- 3. Оплата долга до архива не становится авансом (Р1) -------------------------------------------

select public.tests_claims('89000000-0000-0000-0000-000000000001', '89000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.accept_lesson_debt_payment('89000000-0000-0000-0000-00000000ee02', 80000,
       '89000000-0000-0000-0000-0000000005f1', null, 80000) $$,
  'Перерасход 800 оплачен');
reset role;

select is(public.tests_acc('89000000-0000-0000-0000-00000000ee02'), '(0,0,0,0)', 'После оплаты долга нет');
update public.subscriptions set deleted_at = now() where id = '89000000-0000-0000-0000-0000000055a2';
select is(public.tests_acc('89000000-0000-0000-0000-00000000ee02'), '(0,0,0,0)',
  'Архив оплаченного перерасходованного пакета не превращает оплату в аванс');

select public.tests_claims('89000000-0000-0000-0000-000000000001', '89000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_like(
  $$ select public.refund_lesson_debt_credit('89000000-0000-0000-0000-00000000ee02', 80000,
       '89000000-0000-0000-0000-0000000005f1', null, 0) $$,
  'Вернуть можно только аванс%', 'Вернуть деньгами нечего: аванса нет');
reset role;


-- 4. Подделанное состояние: written_off > 0 и минус (Р2, защита от ручной правки) -----------------

select public.tests_claims('89000000-0000-0000-0000-000000000001', '89000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.refund_subscription('89000000-0000-0000-0000-0000000055a3', 0, null) $$,
  'Возврат пакета с written_off > 0 и перерасходом проходит (подделанное состояние)');
reset role;

select is(
  (select s.lessons_written_off from public.subscriptions s where s.id = '89000000-0000-0000-0000-0000000055a3'),
  3, 'written_off не уменьшился (раньше 3 + (−2) = 1 молча стирал перерасход)');
select is(public.tests_acc('89000000-0000-0000-0000-00000000ee03'), '(0,100000,0,100000)', 'Перерасход 2 × 500 остался');


-- 5. Гранты переизданных функций ------------------------------------------------------------------

select is_empty(
  $$ select p.oid::regprocedure::text || ' ' || r
       from pg_proc p, unnest(array['public', 'anon', 'authenticated', 'service_role']) r
      where p.oid in ('public.refund_calc_unchecked(uuid)'::regprocedure,
                      'public.lesson_debt_accounts_unchecked(uuid,uuid)'::regprocedure)
        and has_function_privilege(r, p.oid, 'EXECUTE')
     union all
     select 'refund_subscription ' || r
       from unnest(array['public', 'anon']) r
      where has_function_privilege(r, 'public.refund_subscription(uuid,integer,uuid)'::regprocedure, 'EXECUTE')
     union all
     select 'refund_subscription authenticated'
      where not has_function_privilege('authenticated', 'public.refund_subscription(uuid,integer,uuid)'::regprocedure, 'EXECUTE') $$,
  'Гранты: возврат — только authenticated, внутренние счётчики — ни одной роли, включая service_role');

select ok(
  exists (select 1 from pg_index i where i.indrelid = 'public.subscriptions'::regclass and i.indpred is null
             and i.indkey::text = (select string_agg(a.attnum::text, ' ' order by k.ord)
                                     from unnest(array['student_id', 'center_id']) with ordinality k(col, ord)
                                     join pg_attribute a on a.attrelid = i.indrelid and a.attname = k.col)),
  'subscriptions (student_id, center_id) — непартиальный индекс под ov и FK subscriptions_student_fk (Р4)');

-- Без сессии — отказ первой строкой.
select set_config('request.jwt.claims', '{}', true);
set local role authenticated;
select throws_ok(
  $$ select public.refund_subscription('89000000-0000-0000-0000-0000000055a2', 0, null) $$,
  '42501', 'Требуется авторизация', 'refund_subscription без сессии — 42501 до любых проверок');
reset role;
select public.tests_claims('89000000-0000-0000-0000-000000000001', '89000000-0000-0000-0000-0000000000c1');

select * from finish();
rollback;
