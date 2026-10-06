-- pgTAP: отмена ошибочного платежа (0093).
--
-- Р1: владелец отменяет поступление 6 400 без абонемента — появляется
-- корректировка −6 400 с той же датой, источником и учеником, исходная строка
-- не меняется, итог по плательщику — ноль. Повтор — отказ. Р2: платёж по
-- абонементу и оплата долга не отменяются. Р3: registrar — 42501, причина
-- обязательна, без сессии — 42501, чужой центр — 42704, закрытый месяц —
-- отказ с подсказкой. Р4: прямая вставка «отмены» не того размера или другой
-- датой — отказ триггера; у пары нельзя менять сумму. Р5: причина в
-- payment_voids, родитель её не видит, в comment — нейтральный текст. Р6:
-- событие без причины. Гранты.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(24);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('93000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0093@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 4) n;

insert into public.centers (id, name, slug, settings) values
  ('93000000-0000-0000-0000-0000000000c1', 'Центр 0093', 'centr-0093', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('93000000-0000-0000-0000-0000000000c2', 'Центр Б 0093', 'centr-0093-b', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.payers (id, center_id, full_name, phone) values
  ('93000000-0000-0000-0000-00000000dd01', '93000000-0000-0000-0000-0000000000c1', 'Плательщик 0093', '+996700009301');

-- 1 owner · 2 registrar · 3 parent (плательщик dd01) · 4 owner центра Б.
insert into public.memberships (user_id, center_id, role, payer_id) values
  ('93000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-0000000000c1', 'owner', null),
  ('93000000-0000-0000-0000-000000000002', '93000000-0000-0000-0000-0000000000c1', 'registrar', null),
  ('93000000-0000-0000-0000-000000000003', '93000000-0000-0000-0000-0000000000c1', 'parent', '93000000-0000-0000-0000-00000000dd01'),
  ('93000000-0000-0000-0000-000000000004', '93000000-0000-0000-0000-0000000000c2', 'owner', null);
insert into public.students (id, center_id, full_name, payer_id) values
  ('93000000-0000-0000-0000-00000000ee01', '93000000-0000-0000-0000-0000000000c1', 'Ученик 0093', '93000000-0000-0000-0000-00000000dd01');
insert into public.payment_sources (id, center_id, code, name, sort) values
  ('93000000-0000-0000-0000-0000000005f1', '93000000-0000-0000-0000-0000000000c1', 'test0093', 'Mbank 0093', 999);

insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at) values
  ('93000000-0000-0000-0000-0000000055a1', '93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000ee01',
   '93000000-0000-0000-0000-00000000dd01', 12, 960000, 80000, current_date - 7, null);

-- D: дубль без абонемента · S: оплата абонемента · L: оплата долга за занятия ·
-- C: корректировка · M: поступление прошлого (закрытого) месяца.
insert into public.payments (id, center_id, payer_id, student_id, subscription_id, amount_tiyin, source_id, paid_at, kind, comment, covers_lesson_debt) values
  ('93000000-0000-0000-0000-0000000009d1', '93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000dd01',
   '93000000-0000-0000-0000-00000000ee01', null, 640000, '93000000-0000-0000-0000-0000000005f1', now() - interval '1 minute', 'payment', 'за 8 занятий', false),
  ('93000000-0000-0000-0000-0000000009d2', '93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000dd01',
   '93000000-0000-0000-0000-00000000ee01', '93000000-0000-0000-0000-0000000055a1', 640000, '93000000-0000-0000-0000-0000000005f1', now() - interval '1 minute', 'payment', 'Оплата при продаже абонемента', false),
  ('93000000-0000-0000-0000-0000000009d3', '93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000dd01',
   '93000000-0000-0000-0000-00000000ee01', null, 80000, '93000000-0000-0000-0000-0000000005f1', now() - interval '1 minute', 'payment', 'долг', true),
  ('93000000-0000-0000-0000-0000000009d4', '93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000dd01',
   '93000000-0000-0000-0000-00000000ee01', null, 10000, null, now() - interval '1 minute', 'correction', 'правка', false),
  ('93000000-0000-0000-0000-0000000009d5', '93000000-0000-0000-0000-0000000000c1', '93000000-0000-0000-0000-00000000dd01',
   '93000000-0000-0000-0000-00000000ee01', null, 20000, '93000000-0000-0000-0000-0000000005f1',
   (date_trunc('month', now() at time zone 'Asia/Bishkek') - interval '10 days') at time zone 'Asia/Bishkek', 'payment', 'прошлый месяц', false);

-- Прошлый месяц закрыт (вставка из-под postgres; close_month проверяет то же самое).
insert into public.financial_periods (center_id, month, closed_at)
values ('93000000-0000-0000-0000-0000000000c1',
        (date_trunc('month', now() at time zone 'Asia/Bishkek') - interval '1 month')::date, now());

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
select throws_ok(
  $$ select public.void_payment('93000000-0000-0000-0000-0000000009d4', 'Дубль') $$,
  '22023', 'Отменить можно только поступление', 'Корректировку отменить нельзя (Р2)');
select throws_like(
  $$ select public.void_payment('93000000-0000-0000-0000-0000000009d5', 'Дубль') $$,
  'Месяц платежа (%) закрыт — переоткройте его во вкладке «Периоды», затем отмените платёж',
  'Закрытый месяц исходного платежа — отказ с подсказкой (Р3)');
reset role;

select public.tests_claims('93000000-0000-0000-0000-000000000004', '93000000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_ok(
  $$ select public.void_payment('93000000-0000-0000-0000-0000000009d1', 'Чужой') $$,
  '42704', 'Платёж не найден', 'Владелец другого центра чужой платёж не видит');
reset role;


-- 2б. Граница на таблице до отмены (Р4) -----------------------------------------------------------

select public.tests_claims('93000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-0000000000c1');
select throws_ok(
  $$ insert into public.payments (center_id, payer_id, student_id, amount_tiyin, source_id, paid_at, kind, voids_payment_id)
     select center_id, payer_id, student_id, -100, source_id, paid_at, 'correction', id
       from public.payments where id = '93000000-0000-0000-0000-0000000009d1' $$,
  '22023', 'Отмена должна зеркалить исходный платёж', 'Прямая «отмена» не той суммы — отказ триггера');
select throws_ok(
  $$ insert into public.payments (center_id, payer_id, student_id, amount_tiyin, source_id, paid_at, kind, voids_payment_id)
     select center_id, payer_id, student_id, -amount_tiyin, source_id, now(), 'correction', id
       from public.payments where id = '93000000-0000-0000-0000-0000000009d1' $$,
  '22023', 'Отмена должна зеркалить исходный платёж', 'Прямая «отмена» другой датой — отказ триггера');

select public.tests_claims('93000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-0000000000c1');
set local role authenticated;


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
  (select row(p.comment, v.reason)::text
     from public.payments p join public.payment_voids v on v.payment_id = p.id
    where p.voids_payment_id = '93000000-0000-0000-0000-0000000009d1'),
  '("Отмена ошибочного платежа","Дубль перевода Mbank 2 октября")',
  'В comment — нейтральный текст, причина — в payment_voids (Р5)');
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


-- 4. Граница на таблице (Р4) и видимость причины (Р5) --------------------------------------------

select public.tests_claims('93000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-0000000000c1');
select throws_ok(
  $$ update public.payments set amount_tiyin = 1 where id = '93000000-0000-0000-0000-0000000009d1' $$,
  '22023', 'Отменённый платёж и его отмену менять нельзя', 'Сумму отменённого платежа не поменять');
select throws_ok(
  $$ update public.payment_voids set reason = 'другое' where voided_payment_id = '93000000-0000-0000-0000-0000000009d1' $$,
  '22023', 'Причина отмены платежа не меняется и не удаляется', 'Причину не переписать');

select public.tests_claims('93000000-0000-0000-0000-000000000003', '93000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is((select count(*)::int from public.payment_voids), 0, 'Родитель причину отмены не видит');
reset role;

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
