-- pgTAP: абонемент закрывается, только если отработанное оплачено (0090).
--
-- Р1 отработанное: неиспользованный пакет с остатком от деления (5 000 / 12)
-- — 0; безлимит без срока — 0 без отметок, цена с отметкой; подарочный
-- (цена 0) — 0. Р2 снимок при закрытии и CHECK на строке: недоплата —
-- отказ с текстом (стойке «примите оплату», владельцу ещё «или спишите»),
-- прямой архив — тот же отказ; после закрытия положительный платёж и
-- корректировка ниже снимка — отказ (Р3). Р4 выплата — внесённое сверх
-- отработанного. Р5 списание: только owner, сверка, касса не тронута, после
-- списания пакет закрыт, списание не меняется. Р6 возврат по абонементу —
-- только refund_subscription, корректировка — только owner. Р7 оплата по
-- абонементу с карточки. Р8 сводка и 'closed'. Гранты и заборы.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(45);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('90000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0090@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 3) n;

insert into public.centers (id, name, slug, settings) values
  ('90000000-0000-0000-0000-0000000000c1', 'Центр 0090', 'centr-0090', '{"timezone":"Asia/Bishkek"}'::jsonb);

-- 1 owner · 2 registrar · 3 finance.
insert into public.memberships (user_id, center_id, role) values
  ('90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-0000000000c1', 'owner'),
  ('90000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-0000000000c1', 'registrar'),
  ('90000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-0000000000c1', 'finance');

insert into public.payers (id, center_id, full_name, phone) values
  ('90000000-0000-0000-0000-00000000dd01', '90000000-0000-0000-0000-0000000000c1', 'Плательщик 0090', '+996700009001');

insert into public.payment_sources (id, center_id, code, name, sort) values
  ('90000000-0000-0000-0000-0000000005f1', '90000000-0000-0000-0000-0000000000c1', 'test0090', 'Касса 0090', 999);

insert into public.students (id, center_id, full_name, payer_id) values
  ('90000000-0000-0000-0000-00000000ee01', '90000000-0000-0000-0000-0000000000c1', 'Ученик 0090', '90000000-0000-0000-0000-00000000dd01');

-- Прямой insert из-под postgres с литералом lessons_used: отметок нет, пересчёт их не трогает.
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at, lessons_used) values
  -- R: 5 000 на 12 — цена занятия 416,66, остаток от деления 8 тыйын; не использован, не оплачен.
  ('90000000-0000-0000-0000-0000000055a0', '90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000ee01',
   '90000000-0000-0000-0000-00000000dd01', 12, 500000, 41666, current_date - 10, null, 0),
  -- P1: 8 × 500, отходил 2, внесено 1 000 — ровно отработанное.
  ('90000000-0000-0000-0000-0000000055a1', '90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000ee01',
   '90000000-0000-0000-0000-00000000dd01', 8, 400000, 50000, current_date - 10, null, 2),
  -- P2: 8 × 500, отходил 2, внесено 500 — недоплата 500.
  ('90000000-0000-0000-0000-0000000055a2', '90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000ee01',
   '90000000-0000-0000-0000-00000000dd01', 8, 400000, 50000, current_date - 10, null, 2),
  -- P3: 8 × 500, отходил 2, внесено 2 000 — к выплате 1 000.
  ('90000000-0000-0000-0000-0000000055a3', '90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000ee01',
   '90000000-0000-0000-0000-00000000dd01', 8, 400000, 50000, current_date - 10, null, 2),
  -- P4: 8 × 500, отходил 2, не оплачен — списание владельцем.
  ('90000000-0000-0000-0000-0000000055a4', '90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000ee01',
   '90000000-0000-0000-0000-00000000dd01', 8, 400000, 50000, current_date - 10, null, 2),
  -- E: исчерпанный 1 × 500, не оплачен — прямой архив.
  ('90000000-0000-0000-0000-0000000055a6', '90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000ee01',
   '90000000-0000-0000-0000-00000000dd01', 1, 50000, 50000, current_date - 10, null, 1),
  -- G: подарочный 4 × 0, отходил 3.
  ('90000000-0000-0000-0000-0000000055a5', '90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000ee01',
   '90000000-0000-0000-0000-00000000dd01', 4, 0, 0, current_date - 10, null, 3);
-- U0, U1: безлимит без срока, без отметок и с одной.
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, starts_at, ends_at, lessons_used) values
  ('90000000-0000-0000-0000-0000000055b0', '90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000ee01',
   '90000000-0000-0000-0000-00000000dd01', null, 300000, current_date - 10, null, 0),
  ('90000000-0000-0000-0000-0000000055b1', '90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000ee01',
   '90000000-0000-0000-0000-00000000dd01', null, 300000, current_date - 10, null, 1);

insert into public.payments (center_id, payer_id, student_id, subscription_id, amount_tiyin, kind) values
  ('90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000dd01', '90000000-0000-0000-0000-00000000ee01', '90000000-0000-0000-0000-0000000055a1', 100000, 'payment'),
  ('90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000dd01', '90000000-0000-0000-0000-00000000ee01', '90000000-0000-0000-0000-0000000055a2', 50000,  'payment'),
  ('90000000-0000-0000-0000-0000000000c1', '90000000-0000-0000-0000-00000000dd01', '90000000-0000-0000-0000-00000000ee01', '90000000-0000-0000-0000-0000000055a3', 200000, 'payment');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Каталог и гранты -----------------------------------------------------------------------------

select ok(
  not has_column_privilege('authenticated', 'public.subscriptions', 'settled_worked_tiyin', 'UPDATE')
  and not has_column_privilege('authenticated', 'public.subscriptions', 'shortfall_written_off_tiyin', 'UPDATE'),
  'Снимок и списанная недоплата закрыты на запись — их пишут только триггеры');

select is_empty(
  $$ select p.oid::regprocedure::text || ' ' || r
       from pg_proc p, unnest(array['public', 'anon', 'authenticated', 'service_role']) r
      where p.oid in ('public.subscription_worked_unchecked(uuid)'::regprocedure,
                      'public.subscriptions_settle_close()'::regprocedure,
                      'public.payments_subscription_kind_gate()'::regprocedure,
                      'public.subscription_shortfall_writeoffs_guard()'::regprocedure,
                      'public.subscription_shortfall_writeoffs_recalc()'::regprocedure,
                      'public.recalc_subscription_paid(uuid)'::regprocedure)
        and has_function_privilege(r, p.oid, 'EXECUTE') $$,
  'Внутренние функции 0090 не исполняет ни одна роль приложения');

select ok(
  not exists (select 1 from pg_proc where proname = 'refund_subscription' and pronargs <> 4)
  and has_function_privilege('authenticated', 'public.refund_subscription(uuid,integer,integer,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.refund_subscription(uuid,integer,integer,uuid)', 'EXECUTE'),
  'refund_subscription — одна перегрузка (uuid,integer,integer,uuid), authenticated да, anon нет');

select is_empty(
  $$ select a.grantee::regrole::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where c.oid = 'public.subscription_shortfall_writeoffs'::regclass
        and a.grantee <> c.relowner
        and not (a.grantee = 'authenticated'::regrole and a.privilege_type = 'SELECT') $$,
  'subscription_shortfall_writeoffs: authenticated — только SELECT');

select ok(
  not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'subscription_shortfall_writeoffs' and cmd <> 'SELECT')
  and exists (select 1 from pg_trigger where tgrelid = 'public.subscription_shortfall_writeoffs'::regclass and tgname = 'a00_readonly_guard')
  and exists (select 1 from public.export_center_tables() x where x.table_name = 'subscription_shortfall_writeoffs'),
  'Списания: политик на запись нет, забор «только чтение» и выгрузка центра на месте');


-- 3. Отработанное (Р1) ----------------------------------------------------------------------------

select is(public.subscription_worked_unchecked('90000000-0000-0000-0000-0000000055a0'), 0,
  'Пакет 5 000 / 12 без отметок — отработано 0 (остаток от деления не в счёт)');
select is(public.subscription_worked_unchecked('90000000-0000-0000-0000-0000000055a1'), 100000,
  'Пакет 8 × 500, отходил 2 — отработано 1 000');
select is(public.subscription_worked_unchecked('90000000-0000-0000-0000-0000000055b0'), 0,
  'Безлимит без срока без отметок — 0');
select is(public.subscription_worked_unchecked('90000000-0000-0000-0000-0000000055b1'), 300000,
  'Безлимит без срока с отметкой — вся цена');
select is(public.subscription_worked_unchecked('90000000-0000-0000-0000-0000000055a5'), 0,
  'Подарочный пакет (цена 0) — 0');


-- 4. Сводка для карточки (Р8) ---------------------------------------------------------------------

select public.tests_claims('90000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select row(x.worked_tiyin, x.payout_tiyin, x.shortfall_tiyin, x.due_tiyin)::text from public.subscription_summary('90000000-0000-0000-0000-0000000055a2') x),
  '(100000,0,50000,350000)', 'P2: отработано 1 000, к выплате 0, недоплата 500, осталось оплатить 3 500');
select is(
  (select row(x.worked_tiyin, x.payout_tiyin, x.shortfall_tiyin)::text from public.subscription_summary('90000000-0000-0000-0000-0000000055a3') x),
  '(100000,100000,0)', 'P3: внесено 2 000 — к выплате 1 000');


-- 5. Отказ при недоплате (Р2) ---------------------------------------------------------------------

select throws_ok(
  $$ select public.refund_subscription('90000000-0000-0000-0000-0000000055a2', 300000, 0) $$,
  '22023', 'За отработанные занятия не заплачено: не хватает 500,00 сом. Сначала примите оплату.',
  'Стойка: недоплата 500 — отказ с текстом, без «спишите»');
reset role;

select public.tests_claims('90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.refund_subscription('90000000-0000-0000-0000-0000000055a2', 300000, 0) $$,
  '22023', 'За отработанные занятия не заплачено: не хватает 500,00 сом. Сначала примите оплату или спишите недоплату.',
  'Владелец: тот же отказ с подсказкой «спишите недоплату»');
reset role;

select public.tests_claims('90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-0000000000c1');
select throws_like(
  $$ update public.subscriptions set deleted_at = now() where id = '90000000-0000-0000-0000-0000000055a6' $$,
  'За отработанные занятия не заплачено%', 'Прямой архив исчерпанного неоплаченного пакета — тот же отказ');
select is(
  (select row(s.status, s.settled_worked_tiyin)::text from public.subscriptions s where s.id = '90000000-0000-0000-0000-0000000055a2'),
  '(active,)', 'После отказа абонемент открыт, снимка нет');


-- 6. Без недоплаты отмена проходит ----------------------------------------------------------------

select public.tests_claims('90000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.refund_subscription('90000000-0000-0000-0000-0000000055a0', 499992, 0) $$,
  'Неиспользованный неоплаченный пакет 5 000 / 12 отменяется (раньше «не хватает 8 тыйын» по формуле «цена − к возврату»)');
select lives_ok(
  $$ select public.refund_subscription('90000000-0000-0000-0000-0000000055b0', 0, 0) $$,
  'Безлимит без отметок, проданный по ошибке, отменяется');
select lives_ok(
  $$ select public.refund_subscription('90000000-0000-0000-0000-0000000055a5', 0, 0) $$,
  'Подарочный пакет отменяется');
select lives_ok(
  $$ select public.refund_subscription('90000000-0000-0000-0000-0000000055a1', 300000, 0) $$,
  'P1: внесено ровно отработанное — отмена с выплатой 0');
reset role;
select is(
  (select row(s.status, s.settled_worked_tiyin, s.paid_tiyin)::text from public.subscriptions s where s.id = '90000000-0000-0000-0000-0000000055a1'),
  '(cancelled,100000,100000)', 'P1: снимок 1 000, внесено 1 000');


-- 7. Выплата — внесённое сверх отработанного (Р4) -------------------------------------------------

select public.tests_claims('90000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.refund_subscription('90000000-0000-0000-0000-0000000055a3', 300000, 200000, '90000000-0000-0000-0000-0000000005f1') $$,
  '23514', 'Сумма к выплате изменилась, пока открывали форму: сейчас 1000,00 сом. Проверьте и повторите.',
  'Устаревшая выплата (2 000 по старой формуле) — 23514 со свежей суммой');
select is(
  public.refund_subscription('90000000-0000-0000-0000-0000000055a3', 300000, 100000, '90000000-0000-0000-0000-0000000005f1'),
  300000, 'P3: возврат проходит, функция по-прежнему отдаёт refund_calc');
reset role;
select is(
  (select row(s.paid_tiyin, s.settled_worked_tiyin,
              (select p.amount_tiyin from public.payments p where p.subscription_id = s.id and p.kind = 'refund'))::text
     from public.subscriptions s where s.id = '90000000-0000-0000-0000-0000000055a3'),
  '(100000,100000,-100000)', 'Вернули 1 000 — после возврата внесено = отработанное');


-- 8. Платежи по закрытому (Р3) и замки на виды платежей (Р6) --------------------------------------

select public.tests_claims('90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.record_payment('90000000-0000-0000-0000-00000000dd01', 10000, 'payment',
       '90000000-0000-0000-0000-00000000ee01', '90000000-0000-0000-0000-0000000055a3', '90000000-0000-0000-0000-0000000005f1') $$,
  '22023', 'Абонемент закрыт — оплату по нему принять нельзя', 'Оплата на закрытый абонемент — отказ');
select throws_ok(
  $$ select public.record_payment('90000000-0000-0000-0000-00000000dd01', -10000, 'correction',
       '90000000-0000-0000-0000-00000000ee01', '90000000-0000-0000-0000-0000000055a1', null, null, 'проверка') $$,
  '22023', 'Абонемент закрыт: вернуть можно не больше 0,00 сом, остальное — за отработанные занятия',
  'Корректировка владельца ниже снимка на закрытом — отказ: недоплата не воскресает');
select throws_ok(
  $$ select public.record_payment('90000000-0000-0000-0000-00000000dd01', -10000, 'refund',
       '90000000-0000-0000-0000-00000000ee01', '90000000-0000-0000-0000-0000000055a2', '90000000-0000-0000-0000-0000000005f1') $$,
  '42501', 'Возврат по абонементу — только кнопкой «Вернуть» в карточке ученика',
  'Строка возврата по абонементу в обход refund_subscription — отказ даже владельцу');
reset role;

select public.tests_claims('90000000-0000-0000-0000-000000000003', '90000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.record_payment('90000000-0000-0000-0000-00000000dd01', 50000, 'correction',
       '90000000-0000-0000-0000-00000000ee01', '90000000-0000-0000-0000-0000000055a2', null, null, 'проверка') $$,
  '42501', 'Корректировку по абонементу проводит только владелец центра', 'finance: корректировка по абонементу — отказ');
reset role;


-- 9. Оплата по абонементу с карточки (Р7) ---------------------------------------------------------

select public.tests_claims('90000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.accept_subscription_payment('90000000-0000-0000-0000-0000000055a2', 50000,
       '90000000-0000-0000-0000-0000000005f1', null, 1) $$,
  '23514', null, 'Устаревший остаток к оплате — 23514');
select throws_ok(
  $$ select public.accept_subscription_payment('90000000-0000-0000-0000-0000000055a2', 400000,
       '90000000-0000-0000-0000-0000000005f1', null, 350000) $$,
  '22023', 'Больше остатка к оплате: сейчас 3500,00 сом', 'Больше остатка — отказ');
select lives_ok(
  $$ select public.accept_subscription_payment('90000000-0000-0000-0000-0000000055a2', 50000,
       '90000000-0000-0000-0000-0000000005f1', null, 350000) $$,
  'Стойка принимает 500 по абонементу');
select is(
  (select x.shortfall_tiyin from public.subscription_summary('90000000-0000-0000-0000-0000000055a2') x), 0,
  'После оплаты недоплаты нет');
select lives_ok(
  $$ select public.refund_subscription('90000000-0000-0000-0000-0000000055a2', 300000, 0) $$,
  'И отмена проходит');
select throws_ok(
  $$ select public.accept_subscription_payment('90000000-0000-0000-0000-0000000055a2', 1,
       '90000000-0000-0000-0000-0000000005f1', null, 300000) $$,
  '22023', 'Абонемент закрыт — оплату по нему принять нельзя', 'Оплата по закрытому с карточки — отказ');
select is(
  (select x.payment_state from public.subscription_payment_summary('90000000-0000-0000-0000-0000000055a2') x), 'closed',
  'payment_state закрытого — closed, не «частично»');


-- 10. Списание недоплаты владельцем (Р5) ----------------------------------------------------------

select throws_ok(
  $$ select public.write_off_subscription('90000000-0000-0000-0000-0000000055a4', 100000, 'Семья уехала') $$,
  '42501', 'Списать недоплату может только владелец центра', 'registrar не списывает');
reset role;

select public.tests_claims('90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.write_off_subscription('90000000-0000-0000-0000-0000000055a4', 50000, 'Семья уехала') $$,
  '23514', null, 'Недоплата изменилась — 23514');
select throws_ok(
  $$ select public.write_off_subscription('90000000-0000-0000-0000-0000000055a4', 100000, '  ') $$,
  '22023', 'Укажите причину списания', 'Без причины — отказ');
select lives_ok(
  $$ select public.write_off_subscription('90000000-0000-0000-0000-0000000055a4', 100000, 'Семья уехала') $$,
  'Владелец списывает 1 000 и закрывает пакет');
reset role;

select is(
  (select row(s.status, s.settled_worked_tiyin, s.shortfall_written_off_tiyin, s.paid_tiyin)::text
     from public.subscriptions s where s.id = '90000000-0000-0000-0000-0000000055a4'),
  '(cancelled,100000,100000,0)', 'Закрыт: снимок 1 000 = списано 1 000, денег 0');
select is(
  (select count(*)::int from public.payments p where p.subscription_id = '90000000-0000-0000-0000-0000000055a4'),
  0, 'Касса не тронута: платёжных строк нет');
select is(
  (select e.payload::text like '%Семья%' from public.events e
    where e.type = 'subscription.shortfall_written_off' and e.payload ->> 'subscription_id' = '90000000-0000-0000-0000-0000000055a4'),
  false, 'Событие есть, причина в payload не уходит');

select public.tests_claims('90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-0000000000c1');
select throws_ok(
  $$ update public.subscription_shortfall_writeoffs set amount_tiyin = 1 where subscription_id = '90000000-0000-0000-0000-0000000055a4' $$,
  '22023', 'Списание недоплаты не меняется и не отменяется', 'Списание не правится');
select throws_ok(
  $$ delete from public.subscription_shortfall_writeoffs where subscription_id = '90000000-0000-0000-0000-0000000055a4' $$,
  '22023', 'Списание недоплаты не меняется и не отменяется', 'Списание не удаляется');
select throws_ok(
  $$ update public.subscriptions set settled_worked_tiyin = 0 where id = '90000000-0000-0000-0000-0000000055a4' $$,
  '22023', 'Расчёт закрытого абонемента не меняется', 'Снимок закрытого не меняется');

select * from finish();
rollback;
