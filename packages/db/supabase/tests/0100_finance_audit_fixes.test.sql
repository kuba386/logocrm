-- pgTAP: аудит финансов 16.10.2026 (0100).
--
-- Р1 installments_view.due_through/row_remaining (в т.ч. base_paid > 0 и
-- отменённый план), pay_installment со сверкой суммы (исходный баг: №2 при
-- неоплаченной №1), installments_notify — остаток строки в событии.
-- Р2 просрочка по абонементу: частично оплаченная строка, немонотонные даты,
-- недобор до графика, без плана, отменённый, ветка родителя, потребитель
-- student_balance. Р3 export_debts с перерасходом. Р4 дата record_expense.
-- Р5 payer_money_summary: суммы семьи и границы доступа. Р6 payments_day_summary.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно, перед
-- «без сессии» — tests_claims(null, null).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(68);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('01000000-0000-0000-0000-0000000000a' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0100@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 8) n;

insert into public.centers (id, name, slug, settings) values
  ('01000000-0000-0000-0000-0000000000c1', 'Центр 0100 А', 'centr-0100-a', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('01000000-0000-0000-0000-0000000000c2', 'Центр 0100 Б', 'centr-0100-b', '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('01000000-0000-0000-0000-0000000000b1', '01000000-0000-0000-0000-0000000000c1', 'Специалист 0100');

insert into public.payers (id, center_id, full_name, phone, deleted_at) values
  ('01000000-0000-0000-0000-0000000000d1', '01000000-0000-0000-0000-0000000000c1', 'П1', '+996700010001', null),
  ('01000000-0000-0000-0000-0000000000d3', '01000000-0000-0000-0000-0000000000c1', 'П3', '+996700010003', null),
  ('01000000-0000-0000-0000-0000000000d4', '01000000-0000-0000-0000-0000000000c1', 'П4', '+996700010004', null),
  ('01000000-0000-0000-0000-0000000000d5', '01000000-0000-0000-0000-0000000000c1', 'П5', '+996700010005', null),
  ('01000000-0000-0000-0000-0000000000d6', '01000000-0000-0000-0000-0000000000c1', 'П6 без долгов', '+996700010006', null),
  ('01000000-0000-0000-0000-0000000000d7', '01000000-0000-0000-0000-0000000000c1', 'П7', '+996700010007', null),
  ('01000000-0000-0000-0000-0000000000dd', '01000000-0000-0000-0000-0000000000c1', 'Удалённый', '+996700010008', now()),
  ('01000000-0000-0000-0000-0000000000db', '01000000-0000-0000-0000-0000000000c2', 'ПБ', '+996700010009', null);

-- 1 owner А · 2 registrar · 3 finance · 4 teacher · 5 parent П3 · 6 parent без плательщика ·
-- 7 owner Б · 8 parent П5.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('01000000-0000-0000-0000-0000000000a1', '01000000-0000-0000-0000-0000000000c1', 'owner', null, null),
  ('01000000-0000-0000-0000-0000000000a2', '01000000-0000-0000-0000-0000000000c1', 'registrar', null, null),
  ('01000000-0000-0000-0000-0000000000a3', '01000000-0000-0000-0000-0000000000c1', 'finance', null, null),
  ('01000000-0000-0000-0000-0000000000a4', '01000000-0000-0000-0000-0000000000c1', 'teacher', '01000000-0000-0000-0000-0000000000b1', null),
  ('01000000-0000-0000-0000-0000000000a5', '01000000-0000-0000-0000-0000000000c1', 'parent', null, '01000000-0000-0000-0000-0000000000d3'),
  ('01000000-0000-0000-0000-0000000000a6', '01000000-0000-0000-0000-0000000000c1', 'parent', null, null),
  ('01000000-0000-0000-0000-0000000000a7', '01000000-0000-0000-0000-0000000000c2', 'owner', null, null),
  ('01000000-0000-0000-0000-0000000000a8', '01000000-0000-0000-0000-0000000000c1', 'parent', null, '01000000-0000-0000-0000-0000000000d5');

-- Дети: K1 (П1) — pay_installment; K2 (П1) — base_paid > 0 и отменённый план;
-- K7, K9 (П3) и K8 (сейчас П4, абонемент покупал П3) — сводка семьи;
-- K10 (П7) — частично оплаченный перерасход; K11–K17 (П5) — просрочка и
-- уведомления; K18 (П6) — семья без долгов.
insert into public.students (id, center_id, full_name, payer_id) values
  ('01000000-0000-0000-0000-000000000e01', '01000000-0000-0000-0000-0000000000c1', 'K1',  '01000000-0000-0000-0000-0000000000d1'),
  ('01000000-0000-0000-0000-000000000e02', '01000000-0000-0000-0000-0000000000c1', 'K2',  '01000000-0000-0000-0000-0000000000d1'),
  ('01000000-0000-0000-0000-000000000e07', '01000000-0000-0000-0000-0000000000c1', 'K7',  '01000000-0000-0000-0000-0000000000d3'),
  ('01000000-0000-0000-0000-000000000e08', '01000000-0000-0000-0000-0000000000c1', 'K8',  '01000000-0000-0000-0000-0000000000d3'),
  ('01000000-0000-0000-0000-000000000e09', '01000000-0000-0000-0000-0000000000c1', 'K9',  '01000000-0000-0000-0000-0000000000d3'),
  ('01000000-0000-0000-0000-000000000e10', '01000000-0000-0000-0000-0000000000c1', 'K10', '01000000-0000-0000-0000-0000000000d7'),
  ('01000000-0000-0000-0000-000000000e11', '01000000-0000-0000-0000-0000000000c1', 'K11', '01000000-0000-0000-0000-0000000000d5'),
  ('01000000-0000-0000-0000-000000000e12', '01000000-0000-0000-0000-0000000000c1', 'K12', '01000000-0000-0000-0000-0000000000d5'),
  ('01000000-0000-0000-0000-000000000e13', '01000000-0000-0000-0000-0000000000c1', 'K13', '01000000-0000-0000-0000-0000000000d5'),
  ('01000000-0000-0000-0000-000000000e14', '01000000-0000-0000-0000-0000000000c1', 'K14', '01000000-0000-0000-0000-0000000000d5'),
  ('01000000-0000-0000-0000-000000000e15', '01000000-0000-0000-0000-0000000000c1', 'K15', '01000000-0000-0000-0000-0000000000d5'),
  ('01000000-0000-0000-0000-000000000e16', '01000000-0000-0000-0000-0000000000c1', 'K16', '01000000-0000-0000-0000-0000000000d5'),
  ('01000000-0000-0000-0000-000000000e17', '01000000-0000-0000-0000-0000000000c1', 'K17', '01000000-0000-0000-0000-0000000000d5'),
  ('01000000-0000-0000-0000-000000000e18', '01000000-0000-0000-0000-0000000000c1', 'K18', '01000000-0000-0000-0000-0000000000d6');

-- Абонементы. Цена занятия — целая часть цены на число занятий (CHECK 0010).
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, lessons_used, allow_negative) values
  -- SA (K1): 600 000 в рассрочку 3×200 000 с нуля.
  ('01000000-0000-0000-0000-000000005a01', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e01',
   '01000000-0000-0000-0000-0000000000d1', 12, 600000, 50000, current_date - 30, 0, false),
  -- SB (K2): 600 000, до плана внесено 100 000, план 2×250 000.
  ('01000000-0000-0000-0000-000000005a02', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e02',
   '01000000-0000-0000-0000-0000000000d1', 12, 600000, 50000, current_date - 30, 0, false),
  -- SC (K2): 200 000, план 2×100 000 и отмена.
  ('01000000-0000-0000-0000-000000005a03', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e02',
   '01000000-0000-0000-0000-0000000000d1', 4, 200000, 50000, current_date - 30, 0, false),
  -- K7a: перерасход 1 занятие × 50 000, оплачен целиком.
  ('01000000-0000-0000-0000-000000005a71', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e07',
   '01000000-0000-0000-0000-0000000000d3', 4, 200000, 50000, current_date - 30, 5, true),
  -- K7b: без плана, внесено 40 000 из 100 000 — просрочка 60 000.
  ('01000000-0000-0000-0000-000000005a72', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e07',
   '01000000-0000-0000-0000-0000000000d3', 2, 100000, 50000, current_date - 30, 0, false),
  -- K8 (покупал П3): 300 000, внесено 100 000, план 2×100 000 — №1 просрочена.
  ('01000000-0000-0000-0000-000000005a81', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e08',
   '01000000-0000-0000-0000-0000000000d3', 6, 300000, 50000, current_date - 30, 0, false),
  -- K9: перерасход 50 000, оплачен 100 000 — дальше переплата долга в аванс.
  ('01000000-0000-0000-0000-000000005a91', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e09',
   '01000000-0000-0000-0000-0000000000d3', 2, 100000, 50000, current_date - 30, 3, true),
  -- K10: перерасход 2 × 50 000, оплачен — частично погасят 30 000.
  ('01000000-0000-0000-0000-000000005a10', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e10',
   '01000000-0000-0000-0000-0000000000d7', 2, 100000, 50000, current_date - 30, 4, true),
  -- SD (K11): 3×100 000 с немонотонными датами.
  ('01000000-0000-0000-0000-000000005a11', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e11',
   '01000000-0000-0000-0000-0000000000d5', 6, 300000, 50000, current_date - 30, 0, false),
  -- SE (K12): 3×200 000, внесено 150 000, просрочена только №1.
  ('01000000-0000-0000-0000-000000005a12', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e12',
   '01000000-0000-0000-0000-0000000000d5', 12, 600000, 50000, current_date - 30, 0, false),
  -- SE2 (K13): 3×200 000, внесено 150 000, просрочены №1 и №2.
  ('01000000-0000-0000-0000-000000005a13', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e13',
   '01000000-0000-0000-0000-0000000000d5', 12, 600000, 50000, current_date - 30, 0, false),
  -- SF (K14): 400 000, до плана 200 000, план 2×100 000 впереди, потом корректировка −50 000.
  ('01000000-0000-0000-0000-000000005a14', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e14',
   '01000000-0000-0000-0000-0000000000d5', 8, 400000, 50000, current_date - 30, 0, false),
  -- SG (K15): без плана, 30 000 из 100 000. SH (K15): отменённый неоплаченный.
  ('01000000-0000-0000-0000-000000005a15', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e15',
   '01000000-0000-0000-0000-0000000000d5', 2, 100000, 50000, current_date - 30, 0, false),
  ('01000000-0000-0000-0000-000000005a16', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e15',
   '01000000-0000-0000-0000-0000000000d5', 2, 100000, 50000, current_date - 30, 0, false),
  -- SI (K16): 2×200 000, внесено 150 000, №1 сегодня — уведомление «к оплате» на остаток.
  ('01000000-0000-0000-0000-000000005a17', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e16',
   '01000000-0000-0000-0000-0000000000d5', 8, 400000, 50000, current_date - 30, 0, false),
  -- SJ (K17): 2×200 000 с нуля, обе просрочены — уведомление №2 на 200 000, не на 400 000.
  ('01000000-0000-0000-0000-000000005a18', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e17',
   '01000000-0000-0000-0000-0000000000d5', 8, 400000, 50000, current_date - 30, 0, false);

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
  select (select id from public.payment_sources where center_id = '01000000-0000-0000-0000-0000000000c1' order by sort, code limit 1) as id,
         (select id from public.payment_sources where center_id = '01000000-0000-0000-0000-0000000000c2' order by sort, code limit 1) as b_id,
         (select id from public.expense_categories where center_id = '01000000-0000-0000-0000-0000000000c1' order by sort, code limit 1) as cat_id,
         public.center_today('01000000-0000-0000-0000-0000000000c1') as today;
grant select on t_src to authenticated;

create temporary table t_ids (name text primary key, id uuid);
grant select, insert on t_ids to authenticated;

-- Платежи до планов и сами планы — от владельца А (emit_event требует сессию).
select public.tests_claims('01000000-0000-0000-0000-0000000000a1', '01000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select public.record_payment('01000000-0000-0000-0000-0000000000d1', 100000, 'payment', '01000000-0000-0000-0000-000000000e02',
                             '01000000-0000-0000-0000-000000005a02', (select id from t_src), null, 'до плана SB');
select public.record_payment('01000000-0000-0000-0000-0000000000d3', 200000, 'payment', '01000000-0000-0000-0000-000000000e07',
                             '01000000-0000-0000-0000-000000005a71', (select id from t_src), null, 'K7a целиком');
select public.record_payment('01000000-0000-0000-0000-0000000000d3', 40000, 'payment', '01000000-0000-0000-0000-000000000e07',
                             '01000000-0000-0000-0000-000000005a72', (select id from t_src), null, 'K7b частично');
select public.record_payment('01000000-0000-0000-0000-0000000000d3', 100000, 'payment', '01000000-0000-0000-0000-000000000e08',
                             '01000000-0000-0000-0000-000000005a81', (select id from t_src), null, 'K8 до плана');
select public.record_payment('01000000-0000-0000-0000-0000000000d3', 100000, 'payment', '01000000-0000-0000-0000-000000000e09',
                             '01000000-0000-0000-0000-000000005a91', (select id from t_src), null, 'K9 целиком');
select public.record_payment('01000000-0000-0000-0000-0000000000d7', 100000, 'payment', '01000000-0000-0000-0000-000000000e10',
                             '01000000-0000-0000-0000-000000005a10', (select id from t_src), null, 'K10 целиком');
select public.record_payment('01000000-0000-0000-0000-0000000000d5', 200000, 'payment', '01000000-0000-0000-0000-000000000e14',
                             '01000000-0000-0000-0000-000000005a14', (select id from t_src), null, 'SF до плана');
select public.record_payment('01000000-0000-0000-0000-0000000000d5', 30000, 'payment', '01000000-0000-0000-0000-000000000e15',
                             '01000000-0000-0000-0000-000000005a15', (select id from t_src), null, 'SG частично');

select count(*) from public.create_installment_plan('01000000-0000-0000-0000-000000005a01', 3, (select today from t_src));
select count(*) from public.create_installment_plan('01000000-0000-0000-0000-000000005a02', 2, (select today from t_src) + 10);
select count(*) from public.create_installment_plan('01000000-0000-0000-0000-000000005a03', 2, (select today from t_src) + 10);
select public.cancel_installment_plan('01000000-0000-0000-0000-000000005a03');
select count(*) from public.create_installment_plan('01000000-0000-0000-0000-000000005a81', 2, (select today from t_src));
select count(*) from public.create_installment_plan('01000000-0000-0000-0000-000000005a11', 3, (select today from t_src));
select count(*) from public.create_installment_plan('01000000-0000-0000-0000-000000005a12', 3, (select today from t_src));
select count(*) from public.create_installment_plan('01000000-0000-0000-0000-000000005a13', 3, (select today from t_src));
select count(*) from public.create_installment_plan('01000000-0000-0000-0000-000000005a14', 2, (select today from t_src) + 10);
select count(*) from public.create_installment_plan('01000000-0000-0000-0000-000000005a17', 2, (select today from t_src));
select count(*) from public.create_installment_plan('01000000-0000-0000-0000-000000005a18', 2, (select today from t_src));

-- Доплаты мимо графика — «Принять оплату» с карточки (accept_subscription_payment).
select public.accept_subscription_payment('01000000-0000-0000-0000-000000005a02', 100000, (select id from t_src),
                                          (select today from t_src), 500000);
select public.accept_subscription_payment('01000000-0000-0000-0000-000000005a12', 150000, (select id from t_src),
                                          (select today from t_src), 600000);
select public.accept_subscription_payment('01000000-0000-0000-0000-000000005a13', 150000, (select id from t_src),
                                          (select today from t_src), 600000);
select public.accept_subscription_payment('01000000-0000-0000-0000-000000005a17', 150000, (select id from t_src),
                                          (select today from t_src), 400000);
-- SF: корректировка −50 000 владельцем — внесено (150 000) стало меньше базы плана (200 000).
select public.record_payment('01000000-0000-0000-0000-0000000000d5', -50000, 'correction', '01000000-0000-0000-0000-000000000e14',
                             '01000000-0000-0000-0000-000000005a14', null, null, 'SF корректировка');
-- K9: переплата долга 50 000 платежом 80 000 — аванс 30 000; K10: частичная оплата перерасхода.
select public.accept_lesson_debt_payment('01000000-0000-0000-0000-000000000e09', 80000, (select id from t_src),
                                         (select today from t_src), 50000);
select public.accept_lesson_debt_payment('01000000-0000-0000-0000-000000000e10', 30000, (select id from t_src),
                                         (select today from t_src), 100000);

reset role;

-- Ход времени — сырыми update как postgres (план не принимает прошлое).
update public.installments i set due_date = v.d
  from (values
    ('01000000-0000-0000-0000-000000005a01'::uuid, 1::smallint, -10), ('01000000-0000-0000-0000-000000005a01', 2, -5),  ('01000000-0000-0000-0000-000000005a01', 3, 20),
    ('01000000-0000-0000-0000-000000005a81', 1, -3),  ('01000000-0000-0000-0000-000000005a81', 2, 10),
    ('01000000-0000-0000-0000-000000005a11', 1, 5),   ('01000000-0000-0000-0000-000000005a11', 2, -1),  ('01000000-0000-0000-0000-000000005a11', 3, -30),
    ('01000000-0000-0000-0000-000000005a12', 1, -3),  ('01000000-0000-0000-0000-000000005a12', 2, 20),  ('01000000-0000-0000-0000-000000005a12', 3, 40),
    ('01000000-0000-0000-0000-000000005a13', 1, -6),  ('01000000-0000-0000-0000-000000005a13', 2, -3),  ('01000000-0000-0000-0000-000000005a13', 3, 40),
    ('01000000-0000-0000-0000-000000005a17', 1, 0),   ('01000000-0000-0000-0000-000000005a17', 2, 30),
    ('01000000-0000-0000-0000-000000005a18', 1, -3),  ('01000000-0000-0000-0000-000000005a18', 2, -2)
  ) as x(sub, seq, shift),
  lateral (select (select today from t_src) + x.shift as d) v
 where i.subscription_id = x.sub and i.seq = x.seq;

-- K8 передают П4 после продажи абонемента П3; у П4 свои: перерасход (оплачен) и неоплаченный без плана.
update public.students set payer_id = '01000000-0000-0000-0000-0000000000d4'
 where id = '01000000-0000-0000-0000-000000000e08';
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, lessons_used, allow_negative) values
  ('01000000-0000-0000-0000-000000005a82', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e08',
   '01000000-0000-0000-0000-0000000000d4', 2, 100000, 50000, current_date - 30, 3, true),
  ('01000000-0000-0000-0000-000000005a83', '01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-000000000e08',
   '01000000-0000-0000-0000-0000000000d4', 1, 50000, 50000, current_date - 30, 0, false);
insert into public.payments (center_id, payer_id, student_id, subscription_id, amount_tiyin, kind) values
  ('01000000-0000-0000-0000-0000000000c1', '01000000-0000-0000-0000-0000000000d4', '01000000-0000-0000-0000-000000000e08',
   '01000000-0000-0000-0000-000000005a82', 100000, 'payment');

-- SH отменён без денег (снимок отработанного — 0, отметок нет).
update public.subscriptions set status = 'cancelled' where id = '01000000-0000-0000-0000-000000005a16';


-- 2. Р1: installments_view ----------------------------------------------------------------------

select is(
  (select array[due_through_tiyin, row_remaining_tiyin] from public.installments_view
    where subscription_id = '01000000-0000-0000-0000-000000005a01' and seq = 2),
  array[400000, 200000],
  'SA №2 при неоплаченной №1: закрыть по №2 — 400 000, остаток самой №2 — 200 000');

select is(
  (select array_agg(array[seq::integer, due_through_tiyin, row_remaining_tiyin] order by seq) from public.installments_view
    where subscription_id = '01000000-0000-0000-0000-000000005a02'),
  array[array[1, 150000, 150000], array[2, 400000, 250000]],
  'base_paid 100 000 + доплата 100 000: №1 — остаток 150 000; №2 — закрыть 400 000, своя 250 000 (base не забыт)');

select is(
  (select array_agg(distinct array[due_through_tiyin, row_remaining_tiyin]) from public.installments_view
    where subscription_id = '01000000-0000-0000-0000-000000005a03'),
  array[array[0, 0]],
  'Отменённый план: к оплате 0 по всем строкам — pay_installment его не примет');

-- Забор на порядок колонок (как 0070 для student_balance): следующий create or
-- replace с колонкой не в конце упадёт здесь, а не на деплое с 42P16.
select is(
  (select array_agg(c.column_name::text order by c.ordinal_position) from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = 'installments_view'),
  array['id', 'center_id', 'subscription_id', 'student_id', 'payer_id', 'plan_id', 'base_paid_tiyin', 'cancelled_at',
        'seq', 'due_date', 'amount_tiyin', 'due_notified_at', 'overdue_notified_at', 'created_at', 'updated_at',
        'price_tiyin', 'paid_tiyin', 'cumulative_tiyin', 'state', 'due_through_tiyin', 'row_remaining_tiyin'],
  'installments_view: прежние 19 колонок на своих местах, две новые — в конце');


-- 3. Р1: pay_installment — сверка суммы ---------------------------------------------------------

select ok(
  to_regprocedure('public.pay_installment(uuid,uuid,timestamptz,text)') is null,
  'Старой сигнатуры pay_installment нет — перегрузки и PGRST203 не будет');

select public.tests_claims('01000000-0000-0000-0000-0000000000a1', '01000000-0000-0000-0000-0000000000c1');
set local role authenticated;

insert into t_ids
  select 'sa' || seq, id from public.installments where subscription_id = '01000000-0000-0000-0000-000000005a01';

select throws_ok(
  $q$ select public.pay_installment((select id from t_ids where name = 'sa2'), 200000, (select id from t_src)) $q$,
  '23514', null,
  'Исходный баг: №2 при неоплаченной №1, на кнопке 2 000 — 23514, а не молчаливые 4 000');
select is(
  (select count(*)::int from public.payments where subscription_id = '01000000-0000-0000-0000-000000005a01'),
  0, '…и ни одного платежа не записано');

insert into t_ids
  select 'pay_sa2', public.pay_installment((select id from t_ids where name = 'sa2'), 400000, (select id from t_src));
select is(
  (select amount_tiyin from public.payments where id = (select id from t_ids where name = 'pay_sa2')),
  400000, 'Сумма, которую показала вью (due_through), — ровно записанная сумма');
select is(
  (select array_agg(state order by seq) from public.installments_view where subscription_id = '01000000-0000-0000-0000-000000005a01'),
  array['paid', 'paid', 'upcoming'], '№1 и №2 закрыты одним платежом, №3 впереди');

select throws_ok(
  $q$ select public.pay_installment((select id from t_ids where name = 'sa1'), 200000, (select id from t_src)) $q$,
  '22023', 'Этот платёж рассрочки уже оплачен',
  'Оплаченная строка — 22023 «уже оплачен» раньше сверки (не «сумма изменилась: сейчас 0»)');
select throws_ok(
  $q$ select public.pay_installment((select id from t_ids where name = 'sa3'), null, (select id from t_src)) $q$,
  '22023', null, 'Без суммы к оплате — отказ, а не прежнее молчаливое поведение');
select throws_ok(
  $q$ select public.pay_installment((select id from t_ids where name = 'sa3'), 200000, null) $q$,
  '22023', 'Укажите источник оплаты', 'Без источника — отказ');
select throws_ok(
  $q$ select public.pay_installment((select id from t_ids where name = 'sa3'), 200000, (select id from t_src), (select today from t_src) + 1) $q$,
  '22023', 'Дата оплаты не может быть в будущем', 'Дата в будущем — 22023 (record_payment_core)');
select throws_ok(
  $q$ select public.pay_installment((select id from t_ids where name = 'sa3'), 200000, (select id from t_src), (select today from t_src) - 400) $q$,
  '22023', 'Дата оплаты старше года — проверьте год', 'Дата старше года — 22023');

select public.tests_claims('01000000-0000-0000-0000-0000000000a4', '01000000-0000-0000-0000-0000000000c1');
select throws_ok(
  $q$ select public.pay_installment((select id from t_ids where name = 'sa3'), 200000, (select id from t_src)) $q$,
  '42501', null, 'Специалист — 42501');
select public.tests_claims(null, null);
select throws_ok(
  $q$ select public.pay_installment((select id from t_ids where name = 'sa3'), 200000, (select id from t_src)) $q$,
  '42501', 'Требуется авторизация', 'Без сессии — 42501 первой строкой');
reset role;


-- 4. Р2: просрочка по абонементу ----------------------------------------------------------------

select public.tests_claims('01000000-0000-0000-0000-0000000000a1', '01000000-0000-0000-0000-0000000000c1');
set local role authenticated;

create temporary table t_over as select * from public.student_subscriptions_overdue();

select is(
  (select overdue_tiyin from t_over where student_id = '01000000-0000-0000-0000-000000000e12'),
  50000, 'Частично оплаченная просроченная №1 (внесено 150 000 из её 200 000) — просрочка 50 000, не 200 000');
select is(
  (select overdue_tiyin from t_over where student_id = '01000000-0000-0000-0000-000000000e13'),
  250000, 'Просрочены №1 и №2 при внесённых 150 000 — 50 000 + 200 000');
select is(
  (select overdue_tiyin from t_over where student_id = '01000000-0000-0000-0000-000000000e11'),
  200000, 'Немонотонные даты (№1 впереди, №2 и №3 прошли) — только №2 и №3, срок №1 не наступил');
select is(
  (select overdue_tiyin from t_over where student_id = '01000000-0000-0000-0000-000000000e14'),
  50000, 'Внесено меньше базы плана (корректировка −50 000) — недобор до графика срочен, хоть строки впереди');
select is(
  (select overdue_tiyin from t_over where student_id = '01000000-0000-0000-0000-000000000e15'),
  70000, 'Без плана — вся недоплата (100 000 − 30 000); отменённый SH не добавил свои 100 000');
select is(
  (select subscription_overdue_tiyin from public.student_balance where student_id = '01000000-0000-0000-0000-000000000e12'),
  50000, 'Потребитель — student_balance (дашборд, долги, бот, debt.reminder) — та же цифра');

select public.tests_claims('01000000-0000-0000-0000-0000000000a8', '01000000-0000-0000-0000-0000000000c1');
select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = '01000000-0000-0000-0000-000000000e12'),
  50000, 'Родитель П5 — просрочка своего ребёнка та же');
select is(
  (select count(*)::int from public.student_subscriptions_overdue() where student_id = '01000000-0000-0000-0000-000000000e07'),
  0, '…и не видит просрочку чужой семьи');
reset role;

select is_empty(
  $$ select r from unnest(array['public', 'anon', 'authenticated', 'service_role', 'bot_worker']) r
      where has_function_privilege(r, 'public.subscription_overdue_unchecked(uuid)', 'EXECUTE') $$,
  'subscription_overdue_unchecked не исполняет ни одна роль — только definer-обёртки');
select is(
  (select prosecdef from pg_proc where oid = 'public.subscription_overdue_unchecked(uuid)'::regprocedure),
  false, 'subscription_overdue_unchecked — SECURITY INVOKER: случайный grant упрётся в RLS, а не отдаст чужой центр');


-- 5. Р1: installments_notify — остаток строки в событии -----------------------------------------

select public.tests_claims(null, null);
select * from public.installments_notify();

select is(
  (select (payload ->> 'amount_tiyin')::int from public.events
    where type = 'installment.due'
      and payload ->> 'installment_id' = (select id::text from public.installments
                                            where subscription_id = '01000000-0000-0000-0000-000000005a17' and seq = 1)),
  50000, '«К оплате сегодня» по частично оплаченной строке — остаток 50 000, не плановые 200 000');
select is(
  (select (payload ->> 'amount_tiyin')::int from public.events
    where type = 'installment.overdue'
      and payload ->> 'installment_id' = (select id::text from public.installments
                                            where subscription_id = '01000000-0000-0000-0000-000000005a18' and seq = 2)),
  200000, 'Просроченная №2 при неоплаченной №1 — в событии 200 000 (своя строка), не 400 000');
select ok(
  has_function_privilege('bot_worker', 'public.installments_notify()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.installments_notify()', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.installments_notify()', 'EXECUTE'),
  'installments_notify — только bot_worker, как в 0032');


-- 6. Р3: export_debts — перерасход в долге за занятия -------------------------------------------

select public.tests_claims('01000000-0000-0000-0000-0000000000a1', '01000000-0000-0000-0000-0000000000c1');
set local role authenticated;

create temporary table t_debts as select * from public.export_debts();

select is(
  (select lessons_debt_tiyin from t_debts where student_name = 'K7'), 50000,
  'K7: перерасход 50 000 в CSV — до 0100 ребёнка с одним перерасходом в выгрузке не было');
select is(
  (select lessons_debt_tiyin from t_debts where student_name = 'K10'), 70000,
  'K10: перерасход 100 000, оплачено 30 000 — в CSV 70 000');
select is(
  (select count(*)::int from t_debts where student_name = 'K9'), 0,
  'K9: только аванс 30 000 — не должник, в CSV нет');
select is(
  (select lessons_debt_tiyin from t_debts where student_name = 'K7'),
  (select (debt_tiyin + overdrawn_tiyin)::int from public.student_debt_problems() where student_id = '01000000-0000-0000-0000-000000000e07'),
  'CSV = долг + перерасход из student_debt_problems() — та же цифра, что на /app/debts');
select is(
  (select subscriptions_unpaid_tiyin from t_debts where student_name = 'K8'), 250000,
  'K8: недоплата 200 000 (абонемент П3) + 50 000 (П4) — колонкой недоплаты, отдельно');


-- 7. Р4: record_expense — дата ------------------------------------------------------------------

create temporary table t_exp_before as
  select count(*)::int as n from public.expenses where center_id = '01000000-0000-0000-0000-0000000000c1';

select lives_ok(
  $q$ select public.record_expense((select cat_id from t_src), 10000, 'expense', (select id from t_src), (select today from t_src), 'сегодня') $q$,
  'Расход сегодняшним днём центра — проходит');
select lives_ok(
  $q$ select public.record_expense((select cat_id from t_src), 10000, 'expense', (select id from t_src),
        ((select today from t_src) - interval '1 year')::date, 'ровно год назад') $q$,
  'Ровно год назад — граница включительно');
select throws_ok(
  $q$ select public.record_expense((select cat_id from t_src), 10000, 'expense', (select id from t_src),
        ((select today from t_src) - interval '1 year')::date - 1, 'год и день') $q$,
  '22023', 'Дата расхода старше года — проверьте год', 'Год и один день назад — 22023');
select throws_ok(
  $q$ select public.record_expense((select cat_id from t_src), 10000, 'expense', (select id from t_src), (select today from t_src) + 1, 'завтра') $q$,
  '22023', 'Дата расхода не может быть в будущем', 'Завтра — 22023');
insert into t_ids
  select 'exp_null', public.record_expense((select cat_id from t_src), 10000, 'expense', (select id from t_src), null, 'без даты');
reset role;
select is(
  (select (paid_at at time zone 'Asia/Bishkek')::date from public.expenses where id = (select id from t_ids where name = 'exp_null')),
  (select today from t_src), 'Без даты — сегодня по центру');
select is(
  (select count(*)::int from public.expenses where center_id = '01000000-0000-0000-0000-0000000000c1') - (select n from t_exp_before),
  3, 'Отказы ничего не записали: прибавились только три принятых расхода');


-- 8. Р5: payer_money_summary --------------------------------------------------------------------

select public.tests_claims('01000000-0000-0000-0000-0000000000a1', '01000000-0000-0000-0000-0000000000c1');
set local role authenticated;

create temporary table t_p3 as select * from public.payer_money_summary('01000000-0000-0000-0000-0000000000d3');

select is(
  (select array[lesson_debt_tiyin, credit_tiyin, overdue_tiyin, unpaid_tiyin] from t_p3 where student_id is null),
  array[50000, 30000, 160000, 260000]::bigint[],
  'П3, итог: долг за занятия 50 000 (K7), аванс 30 000 (K9), просрочка 60 000 + 100 000, недоплата 60 000 + 200 000');
select is(
  (select array[next_due_date::text, next_due_tiyin::text] from t_p3 where student_id is null),
  array[((select today from t_src) - 3)::text, '100000'],
  'Ближайший платёж семьи — просроченная №1 K8 (как subscription_payment_summary), сумма — её остаток');
select is(
  (select array[lesson_debt_tiyin, overdue_tiyin, unpaid_tiyin] from t_p3 where student_id = '01000000-0000-0000-0000-000000000e08'),
  array[0, 100000, 200000]::bigint[],
  'K8 у П3: только его абонемент (просрочка и недоплата); долг за занятия K8 — у текущего плательщика П4');
select is(
  (select array[lesson_debt_tiyin, overdue_tiyin, unpaid_tiyin]
     from public.payer_money_summary('01000000-0000-0000-0000-0000000000d4')
    where student_id = '01000000-0000-0000-0000-000000000e08'),
  array[50000, 50000, 50000]::bigint[],
  'K8 у П4: долг за занятия 50 000 и своя просрочка 50 000 — чужой просрочки П3 тут нет');
select is(
  (select count(*)::int from t_p3 where student_id = '01000000-0000-0000-0000-000000000e09' and credit_tiyin = 30000),
  1, 'K9 — строкой с авансом');
select is(
  (select array_agg(array[lesson_debt_tiyin, credit_tiyin, overdue_tiyin, unpaid_tiyin]) from public.payer_money_summary('01000000-0000-0000-0000-0000000000d6')),
  array[array[0, 0, 0, 0]]::bigint[],
  'Своя семья без долгов — ровно одна строка итога из нулей (не «нельзя»)');
select is(
  (select count(*)::int from public.payer_money_summary(null)), 0, 'NULL — ноль строк, а не сводка всего центра');
select is(
  (select count(*)::int from public.payer_money_summary('01000000-0000-0000-0000-0000000000db')), 0, 'Плательщик центра Б — ноль строк');
select is(
  (select count(*)::int from public.payer_money_summary('01000000-0000-0000-0000-0000000000dd')), 0, 'Удалённый плательщик — ноль строк');

select public.tests_claims('01000000-0000-0000-0000-0000000000a2', '01000000-0000-0000-0000-0000000000c1');
select ok((select count(*) from public.payer_money_summary('01000000-0000-0000-0000-0000000000d3')) > 0, 'Стойка видит сводку семьи');
select public.tests_claims('01000000-0000-0000-0000-0000000000a3', '01000000-0000-0000-0000-0000000000c1');
select ok((select count(*) from public.payer_money_summary('01000000-0000-0000-0000-0000000000d3')) > 0, 'Бухгалтер видит сводку семьи');
select public.tests_claims('01000000-0000-0000-0000-0000000000a4', '01000000-0000-0000-0000-0000000000c1');
select is((select count(*)::int from public.payer_money_summary('01000000-0000-0000-0000-0000000000d3')), 0, 'Специалист — ноль строк');
select public.tests_claims('01000000-0000-0000-0000-0000000000a5', '01000000-0000-0000-0000-0000000000c1');
select is(
  (select overdue_tiyin from public.payer_money_summary('01000000-0000-0000-0000-0000000000d3') where student_id is null),
  160000::bigint, 'Родитель П3 — своя сводка');
select is((select count(*)::int from public.payer_money_summary('01000000-0000-0000-0000-0000000000d4')), 0, '…и не чужая (П4)');
select public.tests_claims('01000000-0000-0000-0000-0000000000a6', '01000000-0000-0000-0000-0000000000c1');
select is((select count(*)::int from public.payer_money_summary(null)), 0, 'Родитель без плательщика с NULL — ноль строк (пара NULL/NULL не проходит)');
select is((select count(*)::int from public.payer_money_summary('01000000-0000-0000-0000-0000000000d3')), 0, 'Родитель без плательщика с чужим id — ноль строк');
select public.tests_claims(null, null);
select is((select count(*)::int from public.payer_money_summary('01000000-0000-0000-0000-0000000000d3')), 0, 'Без сессии — ноль строк');
reset role;


-- 9. Р6: payments_day_summary -------------------------------------------------------------------

-- Платёж центра Б тем же днём — в поступления А не входит.
select public.tests_claims('01000000-0000-0000-0000-0000000000a7', '01000000-0000-0000-0000-0000000000c2');
insert into public.payments (center_id, payer_id, amount_tiyin, kind, source_id)
values ('01000000-0000-0000-0000-0000000000c2', '01000000-0000-0000-0000-0000000000db', 777700, 'payment', (select b_id from t_src));

select public.tests_claims('01000000-0000-0000-0000-0000000000a1', '01000000-0000-0000-0000-0000000000c1');
select is(
  public.payments_day_summary((select today from t_src)),
  public.center_payments_day('01000000-0000-0000-0000-0000000000c1', (select today from t_src)),
  'Владелец: то же, что /cash в боте (center_payments_day, 0072)');
select is(
  (public.payments_day_summary((select today from t_src)) ->> 'total_tiyin')::bigint,
  (select sum(p.amount_tiyin)::bigint from public.payments p
    where p.center_id = '01000000-0000-0000-0000-0000000000c1'
      and (p.paid_at at time zone 'Asia/Bishkek')::date = (select today from t_src)),
  'Итог дня — только платежи центра А (777 700 центра Б не вошли)');
select throws_ok(
  $q$ select public.payments_day_summary(null) $q$, '22023', 'Укажите день', 'NULL — 22023, не «платежей не было»');
select throws_ok(
  $q$ select public.payments_day_summary((select today from t_src) + 1) $q$, '22023', 'День ещё не наступил',
  'Завтра по центру — 22023');
select public.tests_claims('01000000-0000-0000-0000-0000000000a3', '01000000-0000-0000-0000-0000000000c1');
select lives_ok($q$ select public.payments_day_summary((select today from t_src)) $q$, 'Бухгалтер — можно');
select public.tests_claims('01000000-0000-0000-0000-0000000000a2', '01000000-0000-0000-0000-0000000000c1');
select lives_ok(
  $q$ select public.payments_day_summary((select today from t_src)) $q$,
  'Стойка — можно (Р8, решение владельца: сдать кассу вечером); бот /cash остаётся can_finance');
select public.tests_claims('01000000-0000-0000-0000-0000000000a8', '01000000-0000-0000-0000-0000000000c1');
select throws_ok(
  $q$ select public.payments_day_summary((select today from t_src)) $q$, '42501', null, 'Родитель — 42501');
select public.tests_claims(null, null);
select throws_ok(
  $q$ select public.payments_day_summary((select today from t_src)) $q$, '42501', 'Требуется авторизация', 'Без сессии — 42501');


-- 10. Гранты ------------------------------------------------------------------------------------

select ok(
  has_function_privilege('authenticated', 'public.pay_installment(uuid,integer,uuid,date,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.pay_installment(uuid,integer,uuid,date,text)', 'EXECUTE'),
  'pay_installment: authenticated — да, anon — нет');
select ok(
  has_function_privilege('authenticated', 'public.payer_money_summary(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.payer_money_summary(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.payments_day_summary(date)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.payments_day_summary(date)', 'EXECUTE'),
  'Сводка семьи и поступления за день: authenticated — да, anon — нет');
select ok(
  not has_function_privilege('service_role', 'public.student_subscriptions_overdue()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.student_subscriptions_overdue()', 'EXECUTE'),
  'student_subscriptions_overdue: гранты как в 0070 (service_role — нет)');

select * from finish();
rollback;
