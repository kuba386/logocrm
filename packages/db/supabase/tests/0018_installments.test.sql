-- pgTAP: рассрочка и статус оплаты абонемента (миграция 0018).
-- Даты планов — от center_today центра А (create_installment_plan не
-- принимает прошлое); «вчера» для overdue делается сырым update as postgres —
-- имитация хода времени. M1 = позапрошлый месяц, единственный закрываемый.
-- Claims владельца А — до первой сырой вставки (emit_event требует auth.uid()).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(58);

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-b@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent1@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent2@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-inst','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-inst','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист');

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик 1','+996700000001'),
  ('dddddddd-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Плательщик 2','+996700000002');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner', null, null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner', null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001', null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000001'),
  ('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000002');

-- students_track_payer (0014) заводит student_payers — на них FK рассрочки.
insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок 1','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Ребёнок 2','dddddddd-0000-0000-0000-000000000002'),
  ('eeeeeeee-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Ребёнок 3','dddddddd-0000-0000-0000-000000000002');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

create temporary table t_ins (name text primary key, id uuid);
grant select, insert on t_ins to authenticated;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');

-- sub1 — чек-лист (4 000 сом, аванс 2 000, рассрочка 2×1 000);
-- sub2 — остаток 100 000 на 3 и отмена триггером; sub3 — 2 тыйына (n > остатка);
-- sub4 — уведомления и отмена планом; sub5 — архивный ученик.
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                   lesson_price_tiyin, starts_at) values
  ('88880000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
   'eeeeeeee-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001', null, 8, 400000, 50000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880000-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a',
   'eeeeeeee-0000-0000-0000-000000000002','dddddddd-0000-0000-0000-000000000002', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880000-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a',
   'eeeeeeee-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001', null, 1, 2, 2,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880000-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a',
   'eeeeeeee-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001', null, 6, 300000, 50000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880000-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-00000000000a',
   'eeeeeeee-0000-0000-0000-000000000003','dddddddd-0000-0000-0000-000000000002', null, 1, 50000, 50000,
   (date_trunc('month', now() - interval '1 month'))::date);


-- 1-5. Чек-лист п.1: продать 4 000, оплата 2 000, рассрочка 2×1 000 ----------

set local role authenticated;

insert into t_ins (name, id)
select 'p_adv', public.record_payment('dddddddd-0000-0000-0000-000000000001', 200000, 'payment',
  'eeeeeeee-0000-0000-0000-000000000001', '88880000-0000-0000-0000-000000000001', null, now(), 'аванс');

select is(
  (select paid_tiyin from public.subscriptions where id = '88880000-0000-0000-0000-000000000001'),
  200000,
  'Аванс 2 000 сом: paid_tiyin = 200000 (триггер payments_recalc_paid)'
);

select is(
  public.create_installment_plan('88880000-0000-0000-0000-000000000001', 2,
    public.center_today('cccccccc-0000-0000-0000-00000000000a') + 30),
  2,
  'План на остаток 2 000 сом в 2 платежа — вернул 2'
);

select is(
  (select array_agg(amount_tiyin order by seq) from public.installments
    where subscription_id = '88880000-0000-0000-0000-000000000001'),
  array[100000, 100000],
  'Чек-лист: 2 installments по 1 000 сом, сумма = price − paid'
);

select throws_ok(
  $q$ select public.create_installment_plan('88880000-0000-0000-0000-000000000001', 2) $q$,
  '22023', null,
  'Второй план по абонементу с живой рассрочкой — читаемый 22023, не 23505'
);

select is(
  (select count(*)::int from public.installments where subscription_id = '88880000-0000-0000-0000-000000000001'),
  2,
  'После отказа строк по-прежнему две'
);


-- 6-11. Арифметика и границы ------------------------------------------------------

select public.create_installment_plan('88880000-0000-0000-0000-000000000002', 3,
  public.center_today('cccccccc-0000-0000-0000-00000000000a'));

select is(
  (select array_agg(amount_tiyin order by seq) from public.installments
    where subscription_id = '88880000-0000-0000-0000-000000000002'),
  array[33334, 33333, 33333],
  '100 000 / 3: остаток от деления первым платежам — 33334/33333/33333, сумма 100000 (те же числа, что в finance.test.ts)'
);

select throws_ok(
  $q$ select public.create_installment_plan('88880000-0000-0000-0000-000000000003', 3) $q$,
  '22023', 'Платежей больше, чем тыйынов в остатке',
  'Остаток 2 тыйына на 3 платежа — читаемый 22023, а не 23514 на installments_amount_positive'
);

select throws_ok(
  $q$ select public.create_installment_plan('88880000-0000-0000-0000-000000000004', 0) $q$,
  '22023', null, 'n = 0 — 22023'
);

select throws_ok(
  $q$ select public.create_installment_plan('88880000-0000-0000-0000-000000000004', 25) $q$,
  '22023', null, 'n = 25 — 22023'
);

select throws_ok(
  $q$ select public.create_installment_plan('88880000-0000-0000-0000-000000000004', 3,
        public.center_today('cccccccc-0000-0000-0000-00000000000a') - 1) $q$,
  '22023', null,
  'Первый платёж вчерашней датой — 22023: план из прошлого дал бы залп overdue-уведомлений'
);

select throws_ok(
  $q$ select public.create_installment_plan('88880000-0000-0000-0000-000000000004', 3, null, 0::smallint) $q$,
  '22023', null, 'Шаг 0 месяцев — 22023'
);


-- 12-14. Прямая запись закрыта -----------------------------------------------------

select ok(not has_table_privilege('authenticated', 'public.installments', 'INSERT'),
  'authenticated не вставляет в installments напрямую — только create_installment_plan');
select ok(not has_table_privilege('authenticated', 'public.installments', 'UPDATE'),
  'authenticated не правит installments напрямую');
select ok(not has_table_privilege('authenticated', 'public.installments', 'DELETE'),
  'authenticated не удаляет installments');


-- 15-28. pay_installment и свободные платежи ---------------------------------------

insert into t_ins (name, id)
select 'sub1_r1', id from public.installments
 where subscription_id = '88880000-0000-0000-0000-000000000001' and seq = 1;
insert into t_ins (name, id)
select 'sub1_r2', id from public.installments
 where subscription_id = '88880000-0000-0000-0000-000000000001' and seq = 2;

insert into t_ins (name, id)
select 'p_r1', public.pay_installment((select id from t_ins where name = 'sub1_r1'));

select is(
  (select paid_tiyin from public.subscriptions where id = '88880000-0000-0000-0000-000000000001'),
  300000,
  'pay_installment: платёж ровно на 1 000 сом, paid_tiyin = 300000'
);

select is(
  (select state from public.installments_view where id = (select id from t_ins where name = 'sub1_r1')),
  'paid',
  'Первая строка оплачена: 300000 >= base 200000 + 100000 — аванс до плана не считался за неё'
);

select is(
  (select state from public.installments_view where id = (select id from t_ins where name = 'sub1_r2')),
  'upcoming',
  'Вторая строка ещё не оплачена'
);

select throws_ok(
  format($q$ select public.pay_installment(%L) $q$, (select id from t_ins where name = 'sub1_r1')),
  '22023', null,
  'Повторный pay_installment той же строки — 22023, второго платежа нет'
);

select is(
  (select payment_state from public.subscription_payment_summary('88880000-0000-0000-0000-000000000001')),
  'partial',
  'subscription_payment_summary: 300000 из 400000 — partial'
);

select lives_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  'close_month(M1) проходит'
);

select throws_like(
  format($q$ select public.pay_installment(%L, null, %L) $q$,
    (select id from t_ins where name = 'sub1_r2'),
    ((date_trunc('month', now() - interval '2 months'))::date + 5)::timestamptz),
  '%закрыт%',
  'pay_installment датой в закрытом M1 — замок месяца на payments срабатывает штатно'
);

select is(
  (select state from public.installments_view where id = (select id from t_ins where name = 'sub1_r2')),
  'upcoming',
  '...и после отката строка не оплачена'
);

select is(
  (select count(*)::int from public.payments), 2,
  '...и платежей по-прежнему два (аванс + первая строка)'
);

-- Свободный платёж мимо плана («Добавить платёж» на /app/finance).
insert into t_ins (name, id)
select 'p_free', public.record_payment('dddddddd-0000-0000-0000-000000000001', 100000, 'payment',
  'eeeeeeee-0000-0000-0000-000000000001', '88880000-0000-0000-0000-000000000001', null, now(), 'наличными');

select is(
  (select state from public.installments_view where id = (select id from t_ins where name = 'sub1_r2')),
  'paid',
  'Платёж мимо плана закрыл вторую строку сам — оплаченность выводится из paid_tiyin, не хранится'
);

select is(
  (select payment_state from public.subscription_payment_summary('88880000-0000-0000-0000-000000000001')),
  'paid',
  'summary: paid'
);

select is(
  (select installments_unpaid from public.subscription_payment_summary('88880000-0000-0000-0000-000000000001')),
  0,
  'summary: неоплаченных строк нет'
);

insert into t_ins (name, id)
select 'p_over', public.record_payment('dddddddd-0000-0000-0000-000000000001', 50000, 'payment',
  'eeeeeeee-0000-0000-0000-000000000001', '88880000-0000-0000-0000-000000000001', null, now(), 'лишнее');

select is(
  (select payment_state from public.subscription_payment_summary('88880000-0000-0000-0000-000000000001')),
  'overpaid',
  'summary: переплата — overpaid, не paid'
);

-- sub5 — план из одной строки со сроком сегодня, ученик уходит в архив.
select public.create_installment_plan('88880000-0000-0000-0000-000000000005', 1,
  public.center_today('cccccccc-0000-0000-0000-00000000000a'));
select public.archive_student('eeeeeeee-0000-0000-0000-000000000003');

-- sub4 — три строки: сегодня, +1 мес, +2 мес.
select is(
  public.create_installment_plan('88880000-0000-0000-0000-000000000004', 3,
    public.center_today('cccccccc-0000-0000-0000-00000000000a')),
  3,
  'План sub4 на 3 платежа создан'
);

reset role;


-- 29. Отмена абонемента гасит неоплаченные строки триггером ------------------------

-- Любой путь отмены (refund_subscription, transfer_remaining, будущие) —
-- проверяется само событие update status, а не конкретная RPC.
update public.subscriptions set status = 'cancelled' where id = '88880000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.installments
    where subscription_id = '88880000-0000-0000-0000-000000000002' and cancelled_at is not null),
  3,
  'status = cancelled → все три неоплаченные строки плана отменены триггером'
);


-- 30-39. installments_notify — due / overdue, идемпотентность --------------------

-- Имитация хода времени: вторая строка sub4 просрочена на день.
update public.installments
   set due_date = public.center_today('cccccccc-0000-0000-0000-00000000000a') - 1
 where subscription_id = '88880000-0000-0000-0000-000000000004' and seq = 2;

select is(
  (select array_agg(state order by seq) from public.installments_view
    where subscription_id = '88880000-0000-0000-0000-000000000004'),
  array['due', 'overdue', 'upcoming'],
  'installments_view: состояния sub4 — due / overdue / upcoming от center_today центра'
);

-- Cron-контекст: без auth.uid().
select public.tests_claims(null, null);

create temporary table t_notify as select * from public.installments_notify();

select is((select due_count from t_notify), 1, 'installments_notify: одно due (sub4 seq 1)');
select is((select overdue_count from t_notify), 1, 'installments_notify: одно overdue (sub4 seq 2)');

select is(
  (select count(*)::int from public.events where type = 'installment.due'), 1,
  'Событие installment.due — ровно одно'
);
select is(
  (select count(*)::int from public.events where type = 'installment.overdue'), 1,
  'Событие installment.overdue — ровно одно'
);
select is(
  (select payload->>'amount_tiyin' from public.events where type = 'installment.due'),
  '100000',
  'Payload due: amount_tiyin строки (contract installmentPayload)'
);
select is(
  (select count(*)::int from public.events
    where type in ('installment.due', 'installment.overdue')
      and payload->>'subscription_id' = '88880000-0000-0000-0000-000000000005'),
  0,
  'Архивный ученик (sub5, срок сегодня) — уведомлений нет'
);

select is(
  (select due_count + overdue_count from public.installments_notify()), 0,
  'Повторный вызов — 0/0: отметки поставлены тем же update'
);

-- Обратная проверка внутри функций, не только грант: выдаём грант и зовём
-- от живого пользователя.
grant execute on function public.installments_notify() to authenticated;
grant execute on function public.emit_event_unchecked(text, jsonb, uuid) to authenticated;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select * from public.installments_notify() $q$,
  '42501', null,
  'installments_notify от живого пользователя — 42501 внутри функции, даже с грантом'
);
select throws_ok(
  $q$ select public.emit_event_unchecked('installment.due', '{}'::jsonb, 'cccccccc-0000-0000-0000-00000000000a') $q$,
  '42501', null,
  'emit_event_unchecked от живого пользователя — 42501 внутри функции, даже с грантом'
);

reset role;
revoke execute on function public.installments_notify() from authenticated;
revoke execute on function public.emit_event_unchecked(text, jsonb, uuid) from authenticated;


-- 40-48. Границы доступа ------------------------------------------------------------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.installments where subscription_id = '88880000-0000-0000-0000-000000000001'),
  2,
  'Родитель 1 видит строки рассрочки своего ребёнка'
);
select is(
  (select count(*)::int from public.installments where subscription_id = '88880000-0000-0000-0000-000000000002'),
  0,
  'Родитель 1 не видит рассрочку ребёнка родителя 2'
);
select is(
  (select count(*)::int from public.installments_view where subscription_id = '88880000-0000-0000-0000-000000000001'),
  2,
  'installments_view под родителем — security_invoker пропускает свои строки'
);
select is(
  (select payment_state from public.subscription_payment_summary('88880000-0000-0000-0000-000000000001')),
  'overpaid',
  'Родитель видит статус оплаты своего абонемента'
);
select throws_ok(
  $q$ select public.create_installment_plan('88880000-0000-0000-0000-000000000004', 2) $q$,
  '42501', null,
  'Родитель не создаёт план'
);

reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.installments), 0,
  'Специалист не видит рассрочки вовсе — деньги ему не показываются'
);
select throws_ok(
  $q$ select * from public.subscription_payment_summary('88880000-0000-0000-0000-000000000001') $q$,
  '42704', null,
  'Специалист: subscription_payment_summary — 42704, не данные'
);

reset role;

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;

select is(
  (select count(*)::int from public.installments), 0,
  'Владелец центра Б не видит рассрочки центра А'
);
select throws_ok(
  $q$ select * from public.subscription_payment_summary('88880000-0000-0000-0000-000000000001') $q$,
  '42704', null,
  'Владелец центра Б по uuid абонемента центра А — 42704, не суммы чужого ребёнка'
);

reset role;


-- 49-52. cancel_installment_plan --------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  public.cancel_installment_plan('88880000-0000-0000-0000-000000000004'), 3,
  'cancel_installment_plan: три неоплаченные строки sub4 отменены'
);
select throws_ok(
  $q$ select public.cancel_installment_plan('88880000-0000-0000-0000-000000000004') $q$,
  '22023', null,
  'Повторная отмена — нечего отменять, 22023'
);
select is(
  public.create_installment_plan('88880000-0000-0000-0000-000000000004', 1), 1,
  'После отмены новый план возможен (свой plan_id, seq с единицы)'
);
select throws_ok(
  $q$ select public.cancel_installment_plan('88880000-0000-0000-0000-000000000001') $q$,
  '22023', null,
  'Полностью оплаченный план отменять нечего — 22023'
);

reset role;


-- 53-54. Гранты — белый список 0007 актуален -------------------------------------

select ok(
  has_function_privilege('authenticated', 'public.create_installment_plan(uuid,integer,date,smallint)', 'EXECUTE'),
  'create_installment_plan исполняется authenticated'
);
select ok(
  not has_function_privilege('authenticated', 'public.installments_notify()', 'EXECUTE'),
  'installments_notify закрыта для authenticated (после revoke в тесте — как в миграции)'
);


-- 55-58. Контрольные суммы и осознанное отсутствие замка ----------------------------

select is(
  (select count(*)::int from public.payments), 4,
  'Платежей за файл — четыре: аванс, строка 1, свободный, переплата'
);
select is(
  (select count(*)::int from pg_trigger
    where tgrelid = 'public.installments'::regclass and tgname like 'financial_period_guard%'),
  0,
  'На installments нет financial_period_guard — сознательно (Р2): денежный факт — платёж'
);
select is(
  (select count(*)::int from public.installments where cancelled_at is null
      and subscription_id = '88880000-0000-0000-0000-000000000004'),
  1,
  'У sub4 одна живая строка — нового плана'
);
select is(
  (select installments_total from public.subscription_payment_summary('88880000-0000-0000-0000-000000000004')),
  1,
  'summary sub4: отменённые строки в installments_total не считаются'
);

select * from finish();

rollback;
