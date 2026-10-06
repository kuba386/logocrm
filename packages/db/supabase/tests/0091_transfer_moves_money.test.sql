-- pgTAP: перенос остатка вместе с деньгами (0091).
--
-- Р1/Р2: полностью оплаченный пакет 8 × 500, отходил 2 — переносится 6
-- занятий и 3 000 сом парой корректировок (касса ноль), получатель не в
-- недоплате; частично оплаченный — переходит внесённое сверх отработанного.
-- Недоплата за отработанное — отказ триггера 0090. Р3 другой плательщик —
-- отказ. Р4 отменённый — отказ, без сессии — 42501 первой строкой. Р6 живая
-- рассрочка — отказ. Р7 остаток от деления (5 000 / 12) переходит в цену
-- нового. Флаг переноса не протекает наружу. Р5 событие с amount_tiyin. Гранты.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(19);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('91000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0091@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 2) n;

insert into public.centers (id, name, slug, settings) values
  ('91000000-0000-0000-0000-0000000000c1', 'Центр 0091', 'centr-0091', '{"timezone":"Asia/Bishkek"}'::jsonb);

-- 1 owner · 2 registrar.
insert into public.memberships (user_id, center_id, role) values
  ('91000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-0000000000c1', 'owner'),
  ('91000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-0000000000c1', 'registrar');

insert into public.payers (id, center_id, full_name, phone) values
  ('91000000-0000-0000-0000-00000000dd01', '91000000-0000-0000-0000-0000000000c1', 'Семья А 0091', '+996700009101'),
  ('91000000-0000-0000-0000-00000000dd02', '91000000-0000-0000-0000-0000000000c1', 'Семья Б 0091', '+996700009102');

-- e1, e2 — дети семьи А; e3 — семьи Б.
insert into public.students (id, center_id, full_name, payer_id) values
  ('91000000-0000-0000-0000-00000000ee01', '91000000-0000-0000-0000-0000000000c1', 'Старший 0091', '91000000-0000-0000-0000-00000000dd01'),
  ('91000000-0000-0000-0000-00000000ee02', '91000000-0000-0000-0000-0000000000c1', 'Младший 0091', '91000000-0000-0000-0000-00000000dd01'),
  ('91000000-0000-0000-0000-00000000ee03', '91000000-0000-0000-0000-0000000000c1', 'Чужой 0091',   '91000000-0000-0000-0000-00000000dd02');

-- Прямой insert из-под postgres с литералом lessons_used (отметок нет). Все — 8 × 500, отходил 2.
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, lessons_used) values
  -- F: оплачен целиком.
  ('91000000-0000-0000-0000-0000000055f1', '91000000-0000-0000-0000-0000000000c1', '91000000-0000-0000-0000-00000000ee01',
   '91000000-0000-0000-0000-00000000dd01', 8, 400000, 50000, current_date - 10, null, 2),
  -- P: внесено 2 000 — сверх отработанного 1 000.
  ('91000000-0000-0000-0000-0000000055f2', '91000000-0000-0000-0000-0000000000c1', '91000000-0000-0000-0000-00000000ee01',
   '91000000-0000-0000-0000-00000000dd01', 8, 400000, 50000, current_date - 10, null, 2),
  -- U: внесено 500 — недоплата за отработанное.
  ('91000000-0000-0000-0000-0000000055f3', '91000000-0000-0000-0000-0000000000c1', '91000000-0000-0000-0000-00000000ee01',
   '91000000-0000-0000-0000-00000000dd01', 8, 400000, 50000, current_date - 10, null, 2),
  -- I: внесено 1 000, остаток — в рассрочку (план создаётся ниже).
  ('91000000-0000-0000-0000-0000000055f4', '91000000-0000-0000-0000-0000000000c1', '91000000-0000-0000-0000-00000000ee01',
   '91000000-0000-0000-0000-00000000dd01', 8, 400000, 50000, current_date - 10, null, 2),
  -- R: 5 000 на 12 (цена занятия 416,66, остаток от деления 8 тыйын), оплачен целиком, отходил 2.
  ('91000000-0000-0000-0000-0000000055f5', '91000000-0000-0000-0000-0000000000c1', '91000000-0000-0000-0000-00000000ee01',
   '91000000-0000-0000-0000-00000000dd01', 12, 500000, 41666, current_date - 10, null, 2);

insert into public.payments (center_id, payer_id, student_id, subscription_id, amount_tiyin, kind) values
  ('91000000-0000-0000-0000-0000000000c1', '91000000-0000-0000-0000-00000000dd01', '91000000-0000-0000-0000-00000000ee01', '91000000-0000-0000-0000-0000000055f1', 400000, 'payment'),
  ('91000000-0000-0000-0000-0000000000c1', '91000000-0000-0000-0000-00000000dd01', '91000000-0000-0000-0000-00000000ee01', '91000000-0000-0000-0000-0000000055f2', 200000, 'payment'),
  ('91000000-0000-0000-0000-0000000000c1', '91000000-0000-0000-0000-00000000dd01', '91000000-0000-0000-0000-00000000ee01', '91000000-0000-0000-0000-0000000055f3', 50000,  'payment'),
  ('91000000-0000-0000-0000-0000000000c1', '91000000-0000-0000-0000-00000000dd01', '91000000-0000-0000-0000-00000000ee01', '91000000-0000-0000-0000-0000000055f4', 100000, 'payment'),
  ('91000000-0000-0000-0000-0000000000c1', '91000000-0000-0000-0000-00000000dd01', '91000000-0000-0000-0000-00000000ee01', '91000000-0000-0000-0000-0000000055f5', 500000, 'payment');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_new (name text primary key, id uuid);
grant select, insert on t_new to authenticated;


-- 2. Оплаченный пакет: занятия и деньги переходят (Р1, Р2) ----------------------------------------

select public.tests_claims('91000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_new select 'f', public.transfer_remaining('91000000-0000-0000-0000-0000000055f1', '91000000-0000-0000-0000-00000000ee02');
select is(current_setting('logocrm.subscription_transfer', true), '', 'Флаг переноса снят сразу после пары корректировок');
select throws_ok(
  $$ select public.record_payment('91000000-0000-0000-0000-00000000dd01', 1000, 'correction',
       '91000000-0000-0000-0000-00000000ee02', (select id from t_new where name = 'f'), null, null, 'проверка') $$,
  '42501', 'Корректировку по абонементу проводит только владелец центра',
  'После переноса registrar по-прежнему не проводит корректировку — флаг не протёк');
reset role;

select is(
  (select row(s.lessons_total, s.price_tiyin, s.paid_tiyin, s.payer_id)::text from public.subscriptions s
    where s.id = (select id from t_new where name = 'f')),
  '(6,300000,300000,91000000-0000-0000-0000-00000000dd01)',
  'Новый пакет: 6 занятий на 3 000, оплачено 3 000 — получатель не в недоплате');
select is(
  (select row(s.status, s.paid_tiyin, s.settled_worked_tiyin)::text from public.subscriptions s
    where s.id = '91000000-0000-0000-0000-0000000055f1'),
  '(cancelled,100000,100000)', 'Старый закрыт: осталось 1 000 за два отработанных занятия');
select is(
  (select row(count(*), sum(p.amount_tiyin), count(p.source_id))::text from public.payments p
    where p.kind = 'correction'
      and p.subscription_id in ('91000000-0000-0000-0000-0000000055f1', (select id from t_new where name = 'f'))),
  '(2,0,0)', 'Пара корректировок без источника: в сумме ноль — касса не меняется');
select is(
  (select (e.payload ->> 'amount_tiyin')::int from public.events e
    where e.type = 'subscription.transferred' and e.payload ->> 'from_subscription_id' = '91000000-0000-0000-0000-0000000055f1'),
  300000, 'subscription.transferred несёт сумму перенесённых денег');
select is(
  (select x.payment_state from public.subscription_payment_summary((select id from t_new where name = 'f')) x),
  'paid', 'Получатель: абонемент оплачен');


-- 3. Частично оплаченный — переходит внесённое сверх отработанного (Р1) ---------------------------

select public.tests_claims('91000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_new select 'p', public.transfer_remaining('91000000-0000-0000-0000-0000000055f2', '91000000-0000-0000-0000-00000000ee02');
reset role;
select is(
  (select row(s.price_tiyin, s.paid_tiyin)::text from public.subscriptions s where s.id = (select id from t_new where name = 'p')),
  '(300000,100000)', 'Внесено 2 000, отработано 1 000 — на новый пакет переходит 1 000 из 3 000');
select is(
  (select s.paid_tiyin from public.subscriptions s where s.id = '91000000-0000-0000-0000-0000000055f2'),
  100000, 'У старого осталось ровно отработанное');


-- 3б. Остаток от деления переходит в цену нового (Р7) ---------------------------------------------

select public.tests_claims('91000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-0000000000c1');
set local role authenticated;
insert into t_new select 'r', public.transfer_remaining('91000000-0000-0000-0000-0000000055f5', '91000000-0000-0000-0000-00000000ee02');
reset role;
select is(
  (select row(s.lessons_total, s.price_tiyin, s.paid_tiyin)::text from public.subscriptions s where s.id = (select id from t_new where name = 'r')),
  '(10,416668,416668)', '5 000 / 12, отходил 2: 10 занятий за 4 166,68 — с остатком 8 тыйын, оплачено целиком, ничего не застряло');


-- 4. Отказы (Р3, Р4, Р6, 0090) --------------------------------------------------------------------

select public.tests_claims('91000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_like(
  $$ select public.transfer_remaining('91000000-0000-0000-0000-0000000055f3', '91000000-0000-0000-0000-00000000ee02') $$,
  'За отработанные занятия не заплачено%', 'Недоплата за отработанное — перенос невозможен (0090)');
select throws_ok(
  $$ select public.transfer_remaining('91000000-0000-0000-0000-0000000055f3', '91000000-0000-0000-0000-00000000ee03') $$,
  '22023', 'Перенос остатка — только между детьми одного плательщика', 'Другой плательщик — отказ');
select throws_ok(
  $$ select public.transfer_remaining('91000000-0000-0000-0000-0000000055f1', '91000000-0000-0000-0000-00000000ee02') $$,
  '22023', 'Абонемент уже отменён', 'Отменённый абонемент не переносится');
select public.create_installment_plan('91000000-0000-0000-0000-0000000055f4', 2);
select throws_ok(
  $$ select public.transfer_remaining('91000000-0000-0000-0000-0000000055f4', '91000000-0000-0000-0000-00000000ee02') $$,
  '22023', 'Сначала отмените рассрочку — график платежей не переносится',
  'Живая рассрочка — отказ: иначе весь остаток у получателя сразу стал бы просрочкой');
reset role;

select is(
  (select s.status from public.subscriptions s where s.id = '91000000-0000-0000-0000-0000000055f3'),
  'active', 'После отказа абонемент остался открытым');

select set_config('request.jwt.claims', '{}', true);
set local role authenticated;
select throws_ok(
  $$ select public.transfer_remaining('91000000-0000-0000-0000-0000000055f3', '91000000-0000-0000-0000-00000000ee02') $$,
  '42501', 'Требуется авторизация', 'Без сессии — 42501 первой строкой');
reset role;
select public.tests_claims('91000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-0000000000c1');


-- 5. Гранты ---------------------------------------------------------------------------------------

select ok(
  has_function_privilege('authenticated', 'public.transfer_remaining(uuid,uuid)', 'EXECUTE'),
  'transfer_remaining — authenticated');
select ok(
  not has_function_privilege('anon', 'public.transfer_remaining(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('public', 'public.transfer_remaining(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.transfer_remaining(uuid,uuid)', 'EXECUTE'),
  'anon, public и service_role — нет');
select ok(
  not exists (select 1 from pg_proc where proname = 'transfer_remaining' and pronargs <> 2),
  'transfer_remaining — одна перегрузка');

select * from finish();
rollback;
