-- pgTAP: скидка за предоплату тарифа платформы (0084).
--
-- Общий набор случаев — тот же, что в packages/core/src/platform-payment.test.ts
-- (TS-зеркало для подсказки на странице тарифа): одинаковые входы, одинаковые
-- суммы, включая округление половины тыйына вверх. submit_platform_payment
-- пишет сумму со скидкой и в заявку, и в событие; на 1 месяц — без скидки.
-- Хелперы закрыты для прикладных ролей.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(18);


-- 1. Общий набор случаев (= Vitest) ------------------------------------------------------------------------

select is(public.platform_prepay_discount_pct(m) || '/' || public.platform_payment_amount(p, m), expected, label)
  from (values
    (99000,  1,  '0/99000',     'Solo × 1 — без скидки'),
    (99000,  5,  '0/495000',    'Solo × 5 — граница, без скидки'),
    (99000,  6,  '10/534600',   'Solo × 6 — 10 %'),
    (390000, 11, '10/3861000',  'Studio × 11 — ещё 10 %'),
    (390000, 12, '20/3744000',  'Studio × 12 — 20 %'),
    (790000, 24, '20/15168000', 'Center × 24 — 20 %'),
    (12345,  6,  '10/66663',    '12345 × 6 — 10 %, ровная сумма'),
    (12345,  7,  '10/77774',    '12345 × 7 — 77773,5 тыйына → 77774 (половина вверх)')
  ) as c(p, m, expected, label);


-- Фикстура ------------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0840000-0000-0000-0000-000000000001','authenticated','authenticated','owner-a-0084@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0840000-0000-0000-0000-000000000002','authenticated','authenticated','owner-b-0084@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0840000-0000-0000-0000-000000000003','authenticated','authenticated','owner-c-0084@test.kg','','','','','','','','');

insert into public.centers (id, name, slug) values
  ('a0840000-0000-0000-0000-0000000000c1','Центр 0084 А','centr-0084-a'),
  ('a0840000-0000-0000-0000-0000000000c2','Центр 0084 Б','centr-0084-b'),
  ('a0840000-0000-0000-0000-0000000000c3','Центр 0084 В','centr-0084-c');

insert into public.memberships (user_id, center_id, role) values
  ('a0840000-0000-0000-0000-000000000001','a0840000-0000-0000-0000-0000000000c1','owner'),
  ('a0840000-0000-0000-0000-000000000002','a0840000-0000-0000-0000-0000000000c2','owner'),
  ('a0840000-0000-0000-0000-000000000003','a0840000-0000-0000-0000-0000000000c3','owner');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Заявка: сумма со скидкой в строке и в событии ---------------------------------------------------------

select public.tests_claims('a0840000-0000-0000-0000-000000000001', 'a0840000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $q$ select public.submit_platform_payment('studio', 0, 'mbank', null) $q$,
  '22023', null,
  'Срок 0 месяцев — отказ до расчёта суммы');
select throws_ok(
  $q$ select public.submit_platform_payment('studio', 25, 'mbank', null) $q$,
  '22023', null,
  'Срок 25 месяцев — отказ до расчёта суммы');
select public.submit_platform_payment('studio', 1, 'mbank', null);
reset role;

select public.tests_claims('a0840000-0000-0000-0000-000000000002', 'a0840000-0000-0000-0000-0000000000c2');
set local role authenticated;
select public.submit_platform_payment('studio', 6, 'elcart', null);
reset role;

select public.tests_claims('a0840000-0000-0000-0000-000000000003', 'a0840000-0000-0000-0000-0000000000c3');
set local role authenticated;
select public.submit_platform_payment('studio', 12, 'cash', null);
reset role;
select public.tests_claims(null, null);

select is(
  (select claimed_amount_tiyin from public.platform_payments where center_id = 'a0840000-0000-0000-0000-0000000000c1'),
  390000, 'Studio × 1 — в заявке полная цена');
select is(
  (select claimed_amount_tiyin from public.platform_payments where center_id = 'a0840000-0000-0000-0000-0000000000c2'),
  2106000, 'Studio × 6 — в заявке минус 10 %');
select is(
  (select claimed_amount_tiyin from public.platform_payments where center_id = 'a0840000-0000-0000-0000-0000000000c3'),
  3744000, 'Studio × 12 — в заявке минус 20 %');

select is(
  (select (e.payload->>'amount_tiyin')::int from public.events e
    where e.type = 'platform.payment_submitted' and e.center_id = 'a0840000-0000-0000-0000-0000000000c1'),
  390000, 'Событие × 1 — та же сумма, что в заявке');
select is(
  (select (e.payload->>'amount_tiyin')::int from public.events e
    where e.type = 'platform.payment_submitted' and e.center_id = 'a0840000-0000-0000-0000-0000000000c2'),
  2106000, 'Событие × 6 — та же сумма, что в заявке');
select is(
  (select (e.payload->>'amount_tiyin')::int from public.events e
    where e.type = 'platform.payment_submitted' and e.center_id = 'a0840000-0000-0000-0000-0000000000c3'),
  3744000, 'Событие × 12 — та же сумма, что в заявке');


-- 3. Права ------------------------------------------------------------------------------------------------

select ok(
  not has_function_privilege('anon', 'public.platform_prepay_discount_pct(integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.platform_prepay_discount_pct(integer)', 'execute')
  and not has_function_privilege('service_role', 'public.platform_prepay_discount_pct(integer)', 'execute'),
  'platform_prepay_discount_pct закрыта для anon, authenticated, service_role');
select ok(
  not has_function_privilege('anon', 'public.platform_payment_amount(integer, integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.platform_payment_amount(integer, integer)', 'execute')
  and not has_function_privilege('service_role', 'public.platform_payment_amount(integer, integer)', 'execute'),
  'platform_payment_amount закрыта для anon, authenticated, service_role');

select * from finish();
rollback;
