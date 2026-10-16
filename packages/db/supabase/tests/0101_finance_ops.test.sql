-- pgTAP: деньги центра (0101) — аванс без долга, выплата зарплаты из кассы,
-- отмена расхода, переводы между кассами, скидки с причиной и отчётом.
--
-- Р1–Р3 аванс: проводка ровно на A, второе нажатие, долг, списание (и тот же
-- ребёнок после уменьшения начислений), недоплаченный абонемент, архив, без
-- плательщика, права. Р4–Р8 выплаты: первая выплата сверх начисленного и с
-- неверной суммой (NULL в «выплачено», А3), снимок, «нечего выплачивать»,
-- специалист видит своё, отмена и её границы, код статьи. Р9–Р10 переводы:
-- ключ, кассы, замок месяца, readonly, неизменяемость, cash_by_source.
-- Р11–Р12 скидки: причина в базе, справочник, отчёт и итоги.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно после
-- каждого блока «чужой роли».

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(86);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('01010000-0000-0000-0000-0000000000a' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0101@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 8) n;

insert into public.centers (id, name, slug, settings) values
  ('01010000-0000-0000-0000-0000000000c1', 'Центр 0101 А', 'centr-0101-a', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('01010000-0000-0000-0000-0000000000c2', 'Центр 0101 Б', 'centr-0101-b', '{"timezone":"Asia/Bishkek"}'::jsonb);
-- В: подписка истекла — только чтение (0050).
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('01010000-0000-0000-0000-0000000000c3', 'Центр 0101 В', 'centr-0101-c', 'solo', now() - interval '2 days',
   '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('01010000-0000-0000-0000-0000000000b1', '01010000-0000-0000-0000-0000000000c1', 'Специалист 0101'),
  ('01010000-0000-0000-0000-0000000000b2', '01010000-0000-0000-0000-0000000000c1', 'Без начислений 0101'),
  ('01010000-0000-0000-0000-0000000000bb', '01010000-0000-0000-0000-0000000000c2', 'Специалист Б');

insert into public.payers (id, center_id, full_name, phone) values
  ('01010000-0000-0000-0000-0000000000d1', '01010000-0000-0000-0000-0000000000c1', 'П1', '+996700020001'),
  ('01010000-0000-0000-0000-0000000000d2', '01010000-0000-0000-0000-0000000000c1', 'П2', '+996700020002'),
  ('01010000-0000-0000-0000-0000000000db', '01010000-0000-0000-0000-0000000000c2', 'ПБ', '+996700020003'),
  ('01010000-0000-0000-0000-0000000000dc', '01010000-0000-0000-0000-0000000000c3', 'ПВ', '+996700020004');

-- 1 owner А · 2 registrar А · 3 finance А · 4 teacher А (b1) · 5 parent П1 · 6 admin А · 7 owner Б · 8 owner В.
insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('01010000-0000-0000-0000-0000000000a1', '01010000-0000-0000-0000-0000000000c1', 'owner', null, null),
  ('01010000-0000-0000-0000-0000000000a2', '01010000-0000-0000-0000-0000000000c1', 'registrar', null, null),
  ('01010000-0000-0000-0000-0000000000a3', '01010000-0000-0000-0000-0000000000c1', 'finance', null, null),
  ('01010000-0000-0000-0000-0000000000a4', '01010000-0000-0000-0000-0000000000c1', 'teacher', '01010000-0000-0000-0000-0000000000b1', null),
  ('01010000-0000-0000-0000-0000000000a5', '01010000-0000-0000-0000-0000000000c1', 'parent', null, '01010000-0000-0000-0000-0000000000d1'),
  ('01010000-0000-0000-0000-0000000000a6', '01010000-0000-0000-0000-0000000000c1', 'admin', null, null),
  ('01010000-0000-0000-0000-0000000000a7', '01010000-0000-0000-0000-0000000000c2', 'owner', null, null),
  ('01010000-0000-0000-0000-0000000000a8', '01010000-0000-0000-0000-0000000000c3', 'owner', null, null);

-- e1 — аванс; e2 — долг (перерасход); e3 — долг закрыт списанием; e4 — недоплаченный
-- абонемент; e5 — архив; e6 — без плательщика; e7 — скидки; eb — чужой центр; ec — центр В.
insert into public.students (id, center_id, full_name, payer_id, status) values
  ('01010000-0000-0000-0000-000000000e01', '01010000-0000-0000-0000-0000000000c1', 'K1', '01010000-0000-0000-0000-0000000000d1', 'active'),
  ('01010000-0000-0000-0000-000000000e02', '01010000-0000-0000-0000-0000000000c1', 'K2', '01010000-0000-0000-0000-0000000000d1', 'active'),
  ('01010000-0000-0000-0000-000000000e03', '01010000-0000-0000-0000-0000000000c1', 'K3', '01010000-0000-0000-0000-0000000000d2', 'active'),
  ('01010000-0000-0000-0000-000000000e04', '01010000-0000-0000-0000-0000000000c1', 'K4', '01010000-0000-0000-0000-0000000000d2', 'active'),
  ('01010000-0000-0000-0000-000000000e05', '01010000-0000-0000-0000-0000000000c1', 'K5', '01010000-0000-0000-0000-0000000000d1', 'archived'),
  ('01010000-0000-0000-0000-000000000e06', '01010000-0000-0000-0000-0000000000c1', 'K6', null, 'active'),
  ('01010000-0000-0000-0000-000000000e07', '01010000-0000-0000-0000-0000000000c1', 'K7', '01010000-0000-0000-0000-0000000000d2', 'active'),
  ('01010000-0000-0000-0000-000000000e0b', '01010000-0000-0000-0000-0000000000c2', 'KБ', '01010000-0000-0000-0000-0000000000db', 'active'),
  ('01010000-0000-0000-0000-000000000e0c', '01010000-0000-0000-0000-0000000000c3', 'KВ', '01010000-0000-0000-0000-0000000000dc', 'active');

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('01010000-0000-0000-0000-0000000000f1', '01010000-0000-0000-0000-0000000000c1', 'Восемь занятий 0101', 'lessons', 8, 400000);

-- Цена занятия — целая часть цены на число занятий (CHECK 0010).
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, lessons_used, allow_negative) values
  -- s2 (K2): перерасход 1 × 50 000 — долг 50 000.
  ('01010000-0000-0000-0000-000000005a02', '01010000-0000-0000-0000-0000000000c1', '01010000-0000-0000-0000-000000000e02',
   '01010000-0000-0000-0000-0000000000d1', null, 2, 100000, 50000, current_date - 30, 3, true),
  -- s3 (K3): перерасход 2 × 50 000 — оплатят 30 000, спишут 70 000.
  ('01010000-0000-0000-0000-000000005a03', '01010000-0000-0000-0000-0000000000c1', '01010000-0000-0000-0000-000000000e03',
   '01010000-0000-0000-0000-0000000000d2', null, 2, 100000, 50000, current_date - 30, 4, true),
  -- s4 (K4): 400 000, не оплачен.
  ('01010000-0000-0000-0000-000000005a04', '01010000-0000-0000-0000-0000000000c1', '01010000-0000-0000-0000-000000000e04',
   '01010000-0000-0000-0000-0000000000d2', '01010000-0000-0000-0000-0000000000f1', 8, 400000, 50000, current_date - 30, 0, false);

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
  select (select id from public.payment_sources where center_id = '01010000-0000-0000-0000-0000000000c1' order by sort, code limit 1) as id,
         (select id from public.payment_sources where center_id = '01010000-0000-0000-0000-0000000000c1' order by sort, code offset 1 limit 1) as id2,
         (select id from public.payment_sources where center_id = '01010000-0000-0000-0000-0000000000c2' order by sort, code limit 1) as b_id,
         (select id from public.payment_sources where center_id = '01010000-0000-0000-0000-0000000000c3' order by sort, code limit 1) as c_id,
         (select id from public.payment_sources where center_id = '01010000-0000-0000-0000-0000000000c3' order by sort, code offset 1 limit 1) as c_id2,
         (select id from public.expense_categories where center_id = '01010000-0000-0000-0000-0000000000c1' and code = 'rent') as rent_id,
         public.center_today('01010000-0000-0000-0000-0000000000c1') as today,
         date_trunc('month', public.center_today('01010000-0000-0000-0000-0000000000c1'))::date as month,
         (date_trunc('month', public.center_today('01010000-0000-0000-0000-0000000000c1')) - interval '1 month')::date as prev_month;
grant select on t_src to authenticated;

create temporary table t_ids (name text primary key, id uuid);
grant select, insert on t_ids to authenticated;

-- Деньги К3 — от владельца А: абонемент целиком, долг 30 000 из 100 000, списание 70 000.
select public.tests_claims('01010000-0000-0000-0000-0000000000a1', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.record_payment('01010000-0000-0000-0000-0000000000d2', 100000, 'payment', '01010000-0000-0000-0000-000000000e03',
                             '01010000-0000-0000-0000-000000005a03', (select id from t_src), null, 's3 целиком');
select public.accept_lesson_debt_payment('01010000-0000-0000-0000-000000000e03', 30000, (select id from t_src),
                                         (select today from t_src), 100000);
select public.write_off_lesson_debt('01010000-0000-0000-0000-000000000e03', 70000, 'семья в трудной ситуации', 70000);
reset role;

-- Зарплата: бонус 300 000 специалисту А за текущий месяц, 200 000 — специалисту Б;
-- утверждённый снимок А за прошлый месяц — 500 000.
insert into public.salary_adjustments (center_id, teacher_id, month, amount_tiyin, reason) values
  ('01010000-0000-0000-0000-0000000000c1', '01010000-0000-0000-0000-0000000000b1', (select month from t_src), 300000, 'бонус 0101'),
  ('01010000-0000-0000-0000-0000000000c2', '01010000-0000-0000-0000-0000000000bb', (select month from t_src), 200000, 'бонус Б');
insert into public.salary_runs (center_id, teacher_id, month, total_tiyin, lines) values
  ('01010000-0000-0000-0000-0000000000c1', '01010000-0000-0000-0000-0000000000b1', (select prev_month from t_src), 500000, '[]'::jsonb);


-- 2. Р1–Р3: аванс --------------------------------------------------------------------------------

select public.tests_claims('01010000-0000-0000-0000-0000000000a2', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 1
select is(
  (select array[coalesce(block_reason, 'ok'), credit_tiyin::text] from public.lesson_advance_preview('01010000-0000-0000-0000-000000000e01')),
  array['ok', '0'],
  'Стойка: предпросмотр — у ребёнка без долга аванс принять можно, аванса пока нет');

-- 2
select lives_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e01', 300000, (select id from t_src),
                                          (select today from t_src), 0) $q$,
  'Стойка принимает аванс 3 000 сом');

-- 3
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e01', 300000, (select id from t_src),
                                          (select today from t_src), 0) $q$,
  '23514', null,
  'Второе нажатие с тем же «аванс 0» — 23514, второго аванса нет');

-- 4
select lives_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e01', 100000, (select id from t_src),
                                          (select today from t_src), 300000, '  ') $q$,
  'Пополнение аванса со свежей сверкой');

-- 5
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e02', 100000, (select id from t_src),
                                          (select today from t_src), 0) $q$,
  '22023', 'У ученика долг за занятия — примите оплату долга, переплата станет авансом',
  'При долге — отказ с подсказкой про оплату долга');

-- 6
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e03', 100000, (select id from t_src),
                                          (select today from t_src), 0) $q$,
  '22023', 'Аванс не отразится на счёте: у ученика списан долг за занятия. Предложите абонемент',
  'Долг закрыт списанием — аванс съелся бы, отказ');

-- 7
select is(
  (select block_reason from public.lesson_advance_preview('01010000-0000-0000-0000-000000000e03')),
  'writeoff',
  'Предпросмотр называет ту же причину — кнопку прячет база');

-- 8
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e04', 100000, (select id from t_src),
                                          (select today from t_src), 0) $q$,
  '22023', 'Не доплачен абонемент «Восемь занятий 0101»: 4000,00 сом — примите оплату абонемента',
  'Недоплаченный абонемент — отказ: аванс легко принять за его оплату');

-- 9
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e05', 100000, (select id from t_src),
                                          (select today from t_src), 0) $q$,
  '22023', 'Ученик в архиве — восстановите его, чтобы принять аванс',
  'Архивному ученику аванс не принимается');

-- 10
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e06', 100000, (select id from t_src),
                                          (select today from t_src), 0) $q$,
  '22023', 'У ученика нет плательщика — привяжите его в карточке ученика',
  'Без плательщика — отказ');

-- 11
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e0b', 100000, (select id from t_src),
                                          (select today from t_src), 0) $q$,
  '42704', 'Ученик не найден',
  'Ребёнок чужого центра — 42704');

-- 12
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e01', 100000, (select b_id from t_src),
                                          (select today from t_src), 400000) $q$,
  '42704', 'Источник оплаты не найден',
  'Касса чужого центра — 42704, а не 23503 от FK');

-- 13
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e01', 100000, (select id from t_src),
                                          (select today from t_src), null) $q$,
  '22023', 'Обновите страницу: текущий аванс не передан',
  'Без сверки аванса не проводим');

reset role;

-- 14
select is(
  (select credit_tiyin from public.lesson_debt_accounts_unchecked('01010000-0000-0000-0000-0000000000c1', '01010000-0000-0000-0000-000000000e01')),
  400000,
  'Аванс K1 — ровно 3 000 + 1 000 сом');

-- 15
select is(
  (select comment from public.payments
    where student_id = '01010000-0000-0000-0000-000000000e01' and covers_lesson_debt order by created_at limit 1),
  'Аванс за занятия',
  'Пустой комментарий — «Аванс за занятия» (nullif(btrim))');

-- K3: начисления уменьшились (перерасход 2 → 0 занятий) — теперь деньги покрывают
-- всё, аванс отражается целиком.
update public.subscriptions set lessons_used = 2 where id = '01010000-0000-0000-0000-000000005a03';

select public.tests_claims('01010000-0000-0000-0000-0000000000a2', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 16
select lives_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e03', 10000, (select id from t_src),
                                          (select today from t_src), 30000) $q$,
  'Тот же ребёнок после уменьшения начислений: аванс проходит, сверка с прежним авансом 300 сом');

reset role;

-- 17
select is(
  (select credit_tiyin from public.lesson_debt_accounts_unchecked('01010000-0000-0000-0000-0000000000c1', '01010000-0000-0000-0000-000000000e03')),
  40000,
  'Аванс K3 вырос ровно на внесённое: 300 + 100 сом');

select public.tests_claims('01010000-0000-0000-0000-0000000000a4', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 18
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e01', 100000, (select id from t_src),
                                          (select today from t_src), 400000) $q$,
  '42501', null,
  'Специалист аванс не принимает');

reset role;
select public.tests_claims('01010000-0000-0000-0000-0000000000a5', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 19
select throws_ok(
  $q$ select * from public.lesson_advance_preview('01010000-0000-0000-0000-000000000e01') $q$,
  '42501', null,
  'Родитель предпросмотр аванса не получает');

reset role;

-- 20
select ok(
  not has_function_privilege('anon', 'public.accept_lesson_advance(uuid,integer,uuid,date,integer,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.lesson_advance_block_unchecked(uuid,uuid)', 'EXECUTE'),
  'Аноним аванс не исполняет; помощник причин закрыт для authenticated');

-- Центр В (только чтение): аванс упирается в readonly-guard платежей.
select public.tests_claims('01010000-0000-0000-0000-0000000000a8', '01010000-0000-0000-0000-0000000000c3');
set local role authenticated;

-- 21
select throws_ok(
  $q$ select public.accept_lesson_advance('01010000-0000-0000-0000-000000000e0c', 100000, (select c_id from t_src),
                                          public.center_today('01010000-0000-0000-0000-0000000000c3'), 0) $q$,
  'PT402', null,
  'Центр только для чтения — аванс не проводится');

reset role;


-- 3. Р4–Р8: выплата зарплаты ---------------------------------------------------------------------

select public.tests_claims('01010000-0000-0000-0000-0000000000a3', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 22
select is(
  (select array[total_tiyin, paid_tiyin, due_tiyin] from public.salary_summary((select month from t_src))
    where teacher_id = '01010000-0000-0000-0000-0000000000b1'),
  array[300000, 0, 300000],
  'Без выплат «выплачено» 0, «к выплате» = итог — не NULL (А3)');

-- 23
select throws_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000b1', (select month from t_src), 400000,
                               (select id from t_src), (select today from t_src), 300000) $q$,
  '22023', 'Больше, чем к выплате: 3000,00 сом',
  'Первая выплата сверх начисленного — отказ (раньше NULL пропускал любую)');

-- 24
select throws_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000b1', (select month from t_src), 100000,
                               (select id from t_src), (select today from t_src), 1) $q$,
  '23514', null,
  'Первая выплата с неверным «к выплате» — 23514 со свежей суммой');

-- 25
select throws_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000b2', (select month from t_src), 100000,
                               (select id from t_src), (select today from t_src), 0) $q$,
  '22023', null,
  'Ничего не начислено — «нечего выплачивать», не «уже выплачена»');

-- 26
select throws_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000b1', ((select month from t_src) + interval '1 month')::date, 100000,
                               (select id from t_src), (select today from t_src), 0) $q$,
  '22023', 'За будущий месяц зарплату не выплачивают',
  'Будущий месяц — отказ');

-- 27
select throws_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000b1', (select month from t_src), 100000,
                               (select id from t_src), (select month from t_src) - 1, 300000) $q$,
  '22023', 'Дата выплаты раньше месяца зарплаты — проверьте месяц и дату',
  'Выплата датой раньше месяца — отказ');

-- 28
select lives_ok(
  $q$ insert into t_ids values ('payout1', public.pay_salary('01010000-0000-0000-0000-0000000000b1', (select month from t_src), 100000,
                               (select id from t_src), (select today from t_src), 300000, 'аванс')) $q$,
  'Бухгалтер выплачивает 1 000 сом из 3 000');

-- 29
select is(
  (select array[paid_tiyin, due_tiyin] from public.salary_summary((select month from t_src))
    where teacher_id = '01010000-0000-0000-0000-0000000000b1'),
  array[100000, 200000],
  'Выплачено 1 000, к выплате 2 000');

-- 30
select is(
  (select array[c.code, e.kind, e.salary_month::text, e.amount_tiyin::text]
     from public.expenses e join public.expense_categories c on c.id = e.category_id
    where e.id = (select id from t_ids where name = 'payout1')),
  array['salary', 'expense', (select month from t_src)::text, '100000'],
  'Выплата — расход по статье «Зарплата» со специалистом и месяцем');

reset role;
select public.tests_claims('01010000-0000-0000-0000-0000000000a2', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 31
select throws_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000b1', (select month from t_src), 100000,
                               (select id from t_src), (select today from t_src), 200000) $q$,
  '42501', null,
  'Стойка зарплату не выплачивает');

reset role;
select public.tests_claims('01010000-0000-0000-0000-0000000000a4', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 32
select is(
  (select array_agg(array[teacher_id::text, paid_tiyin::text, due_tiyin::text]) from public.salary_summary((select month from t_src))),
  array[array['01010000-0000-0000-0000-0000000000b1', '100000', '200000']],
  'Специалист видит свою строку с выплаченным — и только её');

-- 33
select is(
  (select count(*)::integer from public.expenses),
  0,
  'Таблицу расходов специалист не читает — сумма только через salary_summary');

-- 34
select throws_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000b1', (select month from t_src), 100000,
                               (select id from t_src), (select today from t_src), 200000) $q$,
  '42501', null,
  'Специалист сам себе не выплачивает');

reset role;
select public.tests_claims('01010000-0000-0000-0000-0000000000a3', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 35
select lives_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000b1', (select month from t_src), 200000,
                               (select id from t_src), (select today from t_src), 200000) $q$,
  'Остаток 2 000 выплачен');

-- 36
select throws_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000b1', (select month from t_src), 100000,
                               (select id from t_src), (select today from t_src), 0) $q$,
  '22023', null,
  'Месяц выплачен — повтор отбит');

-- 37
select is(
  (select array[total_tiyin, due_tiyin] from public.salary_summary((select prev_month from t_src))
    where teacher_id = '01010000-0000-0000-0000-0000000000b1'),
  array[500000, 500000],
  'Утверждённый снимок прошлого месяца — итог из снимка, к выплате весь');

-- 38
select lives_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000b1', (select prev_month from t_src), 500000,
                               (select id from t_src), (select today from t_src), 500000) $q$,
  'Выплата по снимку прошлого месяца сегодняшним днём');

-- 39
select throws_ok(
  $q$ select public.void_expense((select id from t_ids where name = 'payout1'), 'ошибка') $q$,
  '42501', 'Отменить расход может только владелец центра',
  'Бухгалтер расход не отменяет — только владелец');

reset role;
select public.tests_claims('01010000-0000-0000-0000-0000000000a6', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 40
select throws_ok(
  $q$ select public.void_expense((select id from t_ids where name = 'payout1'), 'ошибка') $q$,
  '42501', null,
  'Администратор тоже не отменяет');

reset role;
select public.tests_claims('01010000-0000-0000-0000-0000000000a1', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 41
select throws_ok(
  $q$ select public.void_expense((select id from t_ids where name = 'payout1'), '   ') $q$,
  '22023', 'Укажите причину отмены',
  'Без причины — отказ');

-- 42
select lives_ok(
  $q$ insert into t_ids values ('void1', public.void_expense((select id from t_ids where name = 'payout1'), 'не тому специалисту')) $q$,
  'Владелец отменяет выплату 1 000');

-- 43
select is(
  (select array[v.amount_tiyin::text, v.kind, v.comment, (v.teacher_id = o.teacher_id)::text,
                (v.salary_month = o.salary_month)::text, (v.paid_at = o.paid_at)::text,
                (v.source_id = o.source_id)::text, (v.category_id = o.category_id)::text]
     from public.expenses v join public.expenses o on o.id = v.voids_expense_id
    where v.id = (select id from t_ids where name = 'void1')),
  array['-100000', 'correction', 'Отмена: не тому специалисту', 'true', 'true', 'true', 'true', 'true'],
  'Отмена зеркалит выплату: минус, та же дата, касса, статья, специалист, месяц');

-- 44
select is(
  (select due_tiyin from public.salary_summary((select month from t_src))
    where teacher_id = '01010000-0000-0000-0000-0000000000b1'),
  100000,
  'После отмены «к выплате» снова 1 000');

-- 45
select throws_ok(
  $q$ select public.void_expense((select id from t_ids where name = 'payout1'), 'ещё раз') $q$,
  '22023', 'Расход уже отменён',
  'Повторная отмена — отказ');

-- 46
select throws_ok(
  $q$ select public.void_expense((select id from t_ids where name = 'void1'), 'отмена отмены') $q$,
  '22023', 'Отмену расхода отменить нельзя',
  'Отмену не отменить');

-- 47
select throws_ok(
  $q$ update public.expenses set comment = 'переписал причину' where id = (select id from t_ids where name = 'void1') $q$,
  '22023', 'Отмену расхода менять нельзя',
  'Причину в отмене владелец не перепишет — строка отмены неизменяема');

-- 48
select throws_ok(
  $q$ update public.expense_categories set code = 'salary' where id = (select rent_id from t_src) $q$,
  '22023', null,
  'Код статьи не меняется: «Аренда» не станет «Зарплатой» для выплат');

-- 49: расход без кассы — для проверки зеркала с NULL ниже.
select lives_ok(
  $q$ insert into t_ids values ('nosource', public.record_expense((select rent_id from t_src), 50000, 'expense', null,
                                (select today from t_src), 'аренда без кассы')) $q$,
  'Расход без кассы записан');

reset role;

-- 50
select throws_ok(
  $q$ insert into public.expenses (center_id, category_id, source_id, amount_tiyin, paid_at, kind, voids_expense_id)
      select e.center_id, e.category_id, (select id from t_src), -e.amount_tiyin, e.paid_at, 'correction', e.id
        from public.expenses e where e.id = (select id from t_ids where name = 'nosource') $q$,
  '22023', 'Отмена должна зеркалить исходный расход',
  'Отмена с кассой при исходной без кассы — отказ (is distinct from, А8)');

-- 51
select throws_ok(
  $q$ insert into public.expenses (center_id, category_id, amount_tiyin, paid_at, kind, teacher_id, salary_month)
      values ('01010000-0000-0000-0000-0000000000c1',
              (select id from public.expense_categories where center_id = '01010000-0000-0000-0000-0000000000c1' and code = 'salary'),
              -1000, now(), 'correction', '01010000-0000-0000-0000-0000000000b1', (select month from t_src)) $q$,
  '23514', null,
  'Корректировка со специалистом без ссылки на отмену — CHECK (А8)');

-- 52
select throws_ok(
  $q$ insert into public.expenses (center_id, category_id, amount_tiyin, paid_at, kind, teacher_id, salary_month)
      values ('01010000-0000-0000-0000-0000000000c1', (select rent_id from t_src),
              1000, now(), 'expense', '01010000-0000-0000-0000-0000000000b1', (select month from t_src)) $q$,
  '23514', 'Выплата зарплаты проводится только по статье «Зарплата»',
  'Выплата в чужой статье — отказ триггера и от postgres');

select public.tests_claims('01010000-0000-0000-0000-0000000000a1', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 53
select throws_ok(
  $q$ select public.void_expense((select e.id from public.expenses e
                                    join public.expense_categories c on c.id = e.category_id
                                   where c.center_id = '01010000-0000-0000-0000-0000000000c2' limit 1), 'чужой') $q$,
  '42704', null,
  'Чужой или несуществующий расход — 42704');

reset role;

-- Центр Б без статьи «Зарплата»: выплата создаёт её одну.
delete from public.expense_categories
 where center_id = '01010000-0000-0000-0000-0000000000c2' and code = 'salary';

select public.tests_claims('01010000-0000-0000-0000-0000000000a7', '01010000-0000-0000-0000-0000000000c2');
set local role authenticated;

-- 54
select lives_ok(
  $q$ select public.pay_salary('01010000-0000-0000-0000-0000000000bb', (select month from t_src), 50000,
                               (select b_id from t_src), (select today from t_src), 200000) $q$,
  'Центр без статьи «Зарплата»: выплата проходит');

reset role;

-- 55
select is(
  (select count(*)::integer from public.expense_categories
    where center_id = '01010000-0000-0000-0000-0000000000c2' and code = 'salary' and deleted_at is null),
  1,
  'Статья создана ровно одна');


-- 4. Р9–Р10: переводы между кассами --------------------------------------------------------------

create temporary table t_cash_before as
  select (select sum(total_tiyin) from public.cash_by_source where false) as dummy;
grant select, insert, update on t_cash_before to authenticated;

select public.tests_claims('01010000-0000-0000-0000-0000000000a3', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

update t_cash_before set dummy = (select coalesce(sum(total_tiyin), 0) from public.cash_by_source where month = (select month from t_src));

-- 56
select lives_ok(
  $q$ select public.record_cash_transfer((select id from t_src), (select id2 from t_src), 150000,
                                         '01010000-0000-0000-0000-00000000aaa1', (select today from t_src), 'инкассация') $q$,
  'Бухгалтер переводит 1 500 сом между кассами');

-- 57
select throws_ok(
  $q$ select public.record_cash_transfer((select id from t_src), (select id2 from t_src), 150000,
                                         '01010000-0000-0000-0000-00000000aaa1', (select today from t_src)) $q$,
  '22023', 'Этот перевод уже проведён — обновите страницу',
  'Повтор с тем же ключом — отказ, второго перевода нет (А11)');

-- 58
select throws_ok(
  $q$ select public.record_cash_transfer((select id from t_src), (select id from t_src), 100,
                                         '01010000-0000-0000-0000-00000000aaa2') $q$,
  '22023', 'Откуда и куда — разные кассы',
  'Перевод в ту же кассу — отказ');

-- 59
select throws_ok(
  $q$ select public.record_cash_transfer((select id from t_src), (select id2 from t_src), 0,
                                         '01010000-0000-0000-0000-00000000aaa3') $q$,
  '22023', 'Сумма должна быть больше нуля',
  'Нулевая сумма — отказ');

-- 60
select throws_ok(
  $q$ select public.record_cash_transfer((select id from t_src), (select b_id from t_src), 100,
                                         '01010000-0000-0000-0000-00000000aaa4') $q$,
  '42704', 'Касса не найдена',
  'Касса чужого центра — 42704');

-- 61
select throws_ok(
  $q$ select public.record_cash_transfer((select id from t_src), (select id2 from t_src), 100,
                                         '01010000-0000-0000-0000-00000000aaa5', (select today from t_src) + 1) $q$,
  '22023', 'Дата перевода не может быть в будущем',
  'Перевод завтрашним днём — отказ');

-- 62
select is(
  (select array[transfers_out_tiyin, transfers_in_tiyin] from public.cash_by_source
    where month = (select month from t_src) and source_id = (select id from t_src)),
  array[-150000::bigint, 0::bigint],
  'Касса «откуда»: переводы из кассы −1 500');

-- 63
select is(
  (select transfers_in_tiyin from public.cash_by_source
    where month = (select month from t_src) and source_id = (select id2 from t_src)),
  150000::bigint,
  'Касса «куда»: переводы в кассу +1 500');

-- 64
select is(
  (select coalesce(sum(total_tiyin), 0) from public.cash_by_source where month = (select month from t_src)),
  (select dummy from t_cash_before),
  'Итог центра за месяц перевод не меняет');

-- 65
select ok(
  (select bool_and(total_tiyin = received_tiyin + refunded_tiyin + corrections_tiyin + spent_tiyin + other_tiyin
                                 + transfers_in_tiyin + transfers_out_tiyin)
     from public.cash_by_source),
  'Тождество кассы с переводами: total = все колонки');

reset role;

-- 66: забор на порядок колонок — следующий create or replace с колонкой не в конце упадёт здесь.
select is(
  (select array_agg(column_name::text order by ordinal_position) from information_schema.columns
    where table_schema = 'public' and table_name = 'cash_by_source' and ordinal_position > 9),
  array['transfers_in_tiyin', 'transfers_out_tiyin'],
  'cash_by_source: переводы — последние колонки');

-- 67
select throws_ok(
  $q$ update public.cash_transfers set amount_tiyin = 1 $q$,
  '22023', null,
  'Перевод не меняется — даже от postgres (А7)');

-- 68
select throws_ok(
  $q$ delete from public.cash_transfers $q$,
  '22023', null,
  'Перевод не удаляется');

-- 69
select ok(
  not has_table_privilege('service_role', 'public.cash_transfers', 'SELECT')
  and not has_table_privilege('service_role', 'public.cash_transfers', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.cash_transfers', 'INSERT'),
  'cash_transfers: у service_role прав нет, authenticated не пишет напрямую');

select public.tests_claims('01010000-0000-0000-0000-0000000000a2', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 70
select throws_ok(
  $q$ select public.record_cash_transfer((select id from t_src), (select id2 from t_src), 100,
                                         '01010000-0000-0000-0000-00000000aaa6') $q$,
  '42501', null,
  'Стойка переводы не проводит');

-- 71
select is(
  (select count(*)::integer from public.cash_transfers),
  0,
  'Стойка переводы не видит');

reset role;
select public.tests_claims('01010000-0000-0000-0000-0000000000a8', '01010000-0000-0000-0000-0000000000c3');
set local role authenticated;

-- 72
select throws_ok(
  $q$ select public.record_cash_transfer((select c_id from t_src), (select c_id2 from t_src), 100,
                                         '01010000-0000-0000-0000-00000000aaa7') $q$,
  'PT402', null,
  'Центр только для чтения — перевод не проводится (А1)');

reset role;


-- 5. Р11–Р12: скидки ------------------------------------------------------------------------------

select public.tests_claims('01010000-0000-0000-0000-0000000000a2', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 73
select is(
  (select count(*)::integer from public.discount_reasons where deleted_at is null),
  5,
  'Стойка видит пять типовых причин центра (сид при создании центра)');

-- 74
select throws_ok(
  $q$ select public.sell_subscription('01010000-0000-0000-0000-0000000000f1', '01010000-0000-0000-0000-000000000e07', 300000) $q$,
  '22023', 'Укажите причину скидки: цена 3000,00 сом ниже цены типа 4000,00 сом',
  'Скидка без причины — отказ прямо в sell_subscription (А4)');

-- 75
select lives_ok(
  $q$ insert into t_ids values ('disc', public.sell_subscription('01010000-0000-0000-0000-0000000000f1', '01010000-0000-0000-0000-000000000e07', 300000, null,
        (select id from public.discount_reasons where code = 'second_child'))) $q$,
  'Скидка с причиной из справочника проходит');

-- 76
select lives_ok(
  $q$ insert into t_ids values ('full', public.sell_subscription('01010000-0000-0000-0000-0000000000f1', '01010000-0000-0000-0000-000000000e07', null, null,
        (select id from public.discount_reasons where code = 'promo'))) $q$,
  'Полная цена с причиной — продаётся');

reset role;

-- 77
select is(
  (select array_agg(array[coalesce(list_price_tiyin, -1)::text, price_tiyin::text, coalesce(discount_reason_id::text, '-')] order by price_tiyin)
     from public.subscriptions where id in (select id from t_ids where name in ('disc', 'full'))),
  array[array['400000', '300000', (select id::text from public.discount_reasons where center_id = '01010000-0000-0000-0000-0000000000c1' and code = 'second_child')],
        array['400000', '400000', '-']],
  'Цена типа пишется всегда, причина — только при скидке');

-- 78
select throws_ok(
  $q$ insert into public.subscriptions (center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin,
                                        starts_at, list_price_tiyin)
      values ('01010000-0000-0000-0000-0000000000c1', '01010000-0000-0000-0000-000000000e07', '01010000-0000-0000-0000-0000000000d2',
              '01010000-0000-0000-0000-0000000000f1', 8, 200000, 25000, current_date, 400000) $q$,
  '23514', null,
  'Скидка без причины невозможна и от postgres — CHECK');

select public.tests_claims('01010000-0000-0000-0000-0000000000a2', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 79
select throws_ok(
  $q$ select * from public.sell_subscription_paid('01010000-0000-0000-0000-0000000000f1', '01010000-0000-0000-0000-000000000e07',
        '01010000-0000-0000-0000-00000000bbb1', 350000, null, 0) $q$,
  '22023', null,
  'Продажа с оплатой: скидка без причины — отказ');

-- 80
select lives_ok(
  $q$ select * from public.sell_subscription_paid('01010000-0000-0000-0000-0000000000f1', '01010000-0000-0000-0000-000000000e07',
        '01010000-0000-0000-0000-00000000bbb2', 350000, null, 350000, (select id from t_src), (select today from t_src),
        null, null, 1::smallint, 0, (select id from public.discount_reasons where code = 'regular')) $q$,
  'Продажа с оплатой и причиной скидки проходит');

-- 81
select throws_ok(
  $q$ select * from public.subscription_discounts((select month from t_src), (select today from t_src)) $q$,
  '42501', null,
  'Отчёт по скидкам стойке закрыт');

reset role;
select public.tests_claims('01010000-0000-0000-0000-0000000000a5', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 82
select is(
  (select count(*)::integer from public.discount_reasons),
  0,
  'Родитель справочник причин не видит — на абонементе у него только id (А5)');

reset role;
select public.tests_claims('01010000-0000-0000-0000-0000000000a3', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 83
select is(
  (select array_agg(array[discount_tiyin::text, reason_name, coalesce(sold_by_role, '-')] order by discount_tiyin)
     from public.subscription_discounts((select month from t_src), (select today from t_src))),
  array[array['50000', 'Постоянный клиент', 'registrar'], array['100000', 'Второй ребёнок', 'registrar']],
  'Бухгалтер видит продажи со скидкой: сумма, причина, роль продавца (А6)');

-- 84
select is(
  (select array_agg(array[is_total::text, coalesce(reason_name, 'итог'), sales::text, discount_tiyin::text] order by is_total, discount_tiyin desc)
     from public.subscription_discount_totals((select month from t_src), (select today from t_src))),
  array[array['false', 'Второй ребёнок', '1', '100000'],
        array['false', 'Постоянный клиент', '1', '50000'],
        array['true', 'итог', '2', '150000']],
  'Итоги по причинам и строка итога — из базы, итог различается по is_total');

-- 85
select lives_ok(
  $q$ select public.archive_discount_reason((select id from public.discount_reasons where code = 'promo' and deleted_at is null)) $q$,
  'Бухгалтер убирает причину в архив');

reset role;
select public.tests_claims('01010000-0000-0000-0000-0000000000a2', '01010000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 86
select throws_ok(
  $q$ select public.sell_subscription('01010000-0000-0000-0000-0000000000f1', '01010000-0000-0000-0000-000000000e07', 390000, null,
        (select id from public.discount_reasons where code = 'promo')) $q$,
  '22023', 'Причина скидки не найдена или в архиве',
  'Архивная причина в продаже не принимается');

reset role;

select * from finish();
rollback;
