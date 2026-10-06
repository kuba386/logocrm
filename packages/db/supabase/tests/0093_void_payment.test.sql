-- pgTAP: отмена ошибочного платежа (0093).
--
-- Р1: владелец отменяет поступление 6 400 без абонемента — появляется
-- корректировка −6 400 с той же датой, источником и учеником, исходная строка
-- не меняется, итог по плательщику — ноль. Повтор — отказ. Р2: платёж по
-- абонементу и оплата долга не отменяются. Р3: registrar — 42501, причина
-- обязательна, без сессии — 42501. Р4: прямая вставка «отмены» не того
-- размера — отказ триггера. Р5: событие без причины. Гранты.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(15);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('93000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0093@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 2) n;

insert into public.centers (id, name, slug, settings) values
  ('93000000-0000-0000-0000-0000000000c1', 'Центр 0093', 'centr-0093', '{"timezone":"Asia/Bishkek"}'::jsonb);

-- 1 owner · 2 registrar.
insert into public.memberships (user_id, center_id, role) values
  ('93000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-0000000000c1', 'owner'),
  ('93000000-0000-0000-0000-000000000002', '93000000-0000-0000-0000-0000000000c1', 'registrar');

insert into public.payers (id, center_id, full_name, phone) values
  ('93000000-0000-0000-0000-00000000dd01', '93000000-0000-0000-0000-0000000000c1', 'Плательщик 0093', '+996700009301');
insert into public.students (id, center_id, full_name, payer_id) values
  ('93000000-0000-0000-0000-00000000ee01', '93000000-0000-0000-0000-0000000000c1', 'Ученик 0093', '93000000-0000-0000-0000-00000000dd01');
insert into public.payment_sources (id, center_id, code, name, sort) values
  ('93000000-0000-0000-0000-0000000005f1', '93000000-0000-0000-0000-0000000000c1', 'test0093', 'Mbank 0093', 999);

insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at) values
  ('93000000-0000-0000-0000-0000000055a1', '93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000ee01',
   '93000000-0000-0000-0000-00000000dd01', 12, 960000, 80000, current_date - 7, null);

-- D: дубль без абонемента · S: оплата абонемента · L: оплата долга за занятия.
insert into public.payments (id, center_id, payer_id, student_id, subscription_id, amount_tiyin, source_id, paid_at, kind, comment, covers_lesson_debt) values
  ('93000000-0000-0000-0000-0000000009d1', '93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000dd01',
   '93000000-0000-0000-0000-00000000ee01', null, 640000, '93000000-0000-0000-0000-0000000005f1', now() - interval '1 day', 'payment', 'за 8 занятий', false),
  ('93000000-0000-0000-0000-0000000009d2', '93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000dd01',
   '93000000-0000-0000-0000-00000000ee01', '93000000-0000-0000-0000-0000000055a1', 640000, '93000000-0000-0000-0000-0000000005f1', now() - interval '1 day', 'payment', 'Оплата при продаже абонемента', false),
  ('93000000-0000-0000-0000-0000000009d3', '93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000dd01',
   '93000000-0000-0000-0000-00000000ee01', null, 80000, '93000000-0000-0000-0000-0000000005f1', now() - interval '1 day', 'payment', 'долг', true);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Права и проверки (Р3) ------------------------------------------------------------------------

select public.tests_claims('93000000-0000-0000-0000-000000000002', '93000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.void_payment('93000000-0000-0000-0000-0000000009d1', 'Дубль') $$,
  '42501', 'Отменить платёж может только владелец центра', 'registrar не отменяет платежи');
reset role;

select public.tests_claims('93000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.void_payment('93000000-0000-0000-0000-0000000009d1', '  ') $$,
  '22023', 'Укажите причину отмены', 'Без причины — отказ');
select throws_ok(
  $$ select public.void_payment('93000000-0000-0000-0000-0000000009d2', 'Дубль') $$,
  '22023', 'Платёж по абонементу отменяется возвратом в карточке ученика', 'Платёж по абонементу не отменяется (Р2)');
select throws_ok(
  $$ select public.void_payment('93000000-0000-0000-0000-0000000009d3', 'Дубль') $$,
  '22023', 'Оплату долга за занятия отменить нельзя — оформите возврат аванса', 'Оплата долга не отменяется (Р2)');


-- 3. Отмена дубля (Р1, Р5) ------------------------------------------------------------------------

select lives_ok(
  $$ select public.void_payment('93000000-0000-0000-0000-0000000009d1', 'Дубль перевода Mbank 2 октября') $$,
  'Владелец отменяет дубль 6 400');
select throws_ok(
  $$ select public.void_payment('93000000-0000-0000-0000-0000000009d1', 'Ещё раз') $$,
  '22023', 'Платёж уже отменён', 'Повторная отмена — отказ');
reset role;

select is(
  (select row(p.kind, p.amount_tiyin, p.source_id, p.student_id, p.paid_at = o.paid_at, p.subscription_id)::text
     from public.payments p
     join public.payments o on o.id = p.voids_payment_id
    where p.voids_payment_id = '93000000-0000-0000-0000-0000000009d1'),
  '(correction,-640000,93000000-0000-0000-0000-0000000005f1,93000000-0000-0000-0000-00000000ee01,t,)',
  'Отмена — корректировка −6 400 тем же источником, учеником и датой, без абонемента');
select is(
  (select row(p.kind, p.amount_tiyin, p.comment)::text from public.payments p where p.id = '93000000-0000-0000-0000-0000000009d1'),
  '(payment,640000,"за 8 занятий")', 'Исходная строка не изменилась');
select is(
  (select sum(p.amount_tiyin)::int from public.payments p
    where p.id = '93000000-0000-0000-0000-0000000009d1' or p.voids_payment_id = '93000000-0000-0000-0000-0000000009d1'),
  0, 'Пара в сумме ноль — касса без дубля');
select is(
  (select e.payload::text like '%Mbank%' from public.events e
    where e.type = 'payment.voided' and e.payload ->> 'voided_payment_id' = '93000000-0000-0000-0000-0000000009d1'),
  false, 'Событие payment.voided есть, причины в нём нет');

select public.tests_claims('93000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.void_payment((select p.id from public.payments p where p.voids_payment_id = '93000000-0000-0000-0000-0000000009d1'), 'Отмена отмены') $$,
  '22023', 'Отмену платежа отменить нельзя', 'Отмену не отменить');
reset role;


-- 4. Граница на таблице (Р4) ----------------------------------------------------------------------

select public.tests_claims('93000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-0000000000c1');
select throws_ok(
  $$ insert into public.payments (center_id, payer_id, student_id, amount_tiyin, source_id, kind, voids_payment_id)
     values ('93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000dd01', '93000000-0000-0000-0000-00000000ee01',
             -100, '93000000-0000-0000-0000-0000000005f1', 'correction', '93000000-0000-0000-0000-0000000009d2') $$,
  '22023', 'Отменить можно только поступление без абонемента и не оплату долга',
  'Прямая «отмена» платежа по абонементу — отказ триггера');


-- 5. Без сессии и гранты --------------------------------------------------------------------------

select set_config('request.jwt.claims', '{}', true);
set local role authenticated;
select throws_ok(
  $$ select public.void_payment('93000000-0000-0000-0000-0000000009d2', 'x') $$,
  '42501', 'Требуется авторизация', 'Без сессии — 42501 первой строкой');
reset role;
select public.tests_claims('93000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-0000000000c1');

select ok(
  has_function_privilege('authenticated', 'public.void_payment(uuid,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.void_payment(uuid,text)', 'EXECUTE')
  and not has_function_privilege('public', 'public.void_payment(uuid,text)', 'EXECUTE'),
  'void_payment — authenticated, не anon и не public');
select ok(
  not has_function_privilege('authenticated', 'public.payments_void_guard()', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.payments_void_guard()', 'EXECUTE'),
  'Функцию триггера не исполняет ни одна роль приложения');

select * from finish();
rollback;
