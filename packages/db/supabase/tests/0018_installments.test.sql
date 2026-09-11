-- pgTAP: рассрочка и статус оплаты абонемента (миграции 0018, 0019, 0020 —
-- проверяется итоговое состояние после всех трёх).
-- Даты планов — от center_today центра А (create_installment_plan не
-- принимает прошлое); «вчера» и «400 дней назад» для overdue делаются сырым
-- update as postgres — имитация хода времени. M1 = позапрошлый месяц,
-- единственный закрываемый. Claims владельца А — до первой сырой вставки
-- (emit_event требует auth.uid()).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(83);

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

-- students_track_payer (0014) заводит student_payers — на них FK плана.
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
-- sub4 — уведомления, отмена плана целиком, возврат; sub5 — архивный ученик;
-- sub6 — гонка предпросмотра, окно просрочки, null-дата; sub7 — календарь
-- с фиксированной датой (те же входные данные, что finance.test.ts).
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
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880000-0000-0000-0000-000000000006','cccccccc-0000-0000-0000-00000000000a',
   'eeeeeeee-0000-0000-0000-000000000002','dddddddd-0000-0000-0000-000000000002', null, 2, 60000, 30000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880000-0000-0000-0000-000000000007','cccccccc-0000-0000-0000-00000000000a',
   'eeeeeeee-0000-0000-0000-000000000002','dddddddd-0000-0000-0000-000000000002', null, 3, 90000, 30000,
   (date_trunc('month', now() - interval '1 month'))::date);


-- 1-6. Чек-лист п.1: продать 4 000, оплата 2 000, рассрочка 2×1 000 ----------

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
  (select count(*)::int from public.create_installment_plan('88880000-0000-0000-0000-000000000001', 2,
    public.center_today('cccccccc-0000-0000-0000-00000000000a') + 30)),
  2,
  'План на остаток 2 000 сом в 2 платежа — в ответе две строки плана (интерфейс рисует по ответу сервера)'
);

select is(
  (select array_agg(amount_tiyin order by seq) from public.installments
    where subscription_id = '88880000-0000-0000-0000-000000000001'),
  array[100000, 100000],
  'Чек-лист: 2 installments по 1 000 сом, сумма = price − paid'
);

select is(
  (select count(*)::int from public.events where type = 'installment_plan.created'), 1,
  'installment_plan.created эмитировано — родитель узнает о рассрочке раньше, чем о просрочке'
);

select throws_ok(
  $q$ select * from public.create_installment_plan('88880000-0000-0000-0000-000000000001', 2) $q$,
  '22023', null,
  'Второй план по абонементу с живой рассрочкой — читаемый 22023, не 23505'
);

select is(
  (select count(*)::int from public.installments where subscription_id = '88880000-0000-0000-0000-000000000001'),
  2,
  'После отказа строк по-прежнему две'
);


-- 7-13. Арифметика, границы, гонка предпросмотра -----------------------------------

select count(*) from public.create_installment_plan('88880000-0000-0000-0000-000000000002', 3,
  public.center_today('cccccccc-0000-0000-0000-00000000000a'));

select is(
  (select array_agg(amount_tiyin order by seq) from public.installments
    where subscription_id = '88880000-0000-0000-0000-000000000002'),
  array[33334, 33333, 33333],
  '100 000 / 3: остаток от деления первым платежам — 33334/33333/33333, сумма 100000 (те же числа, что в finance.test.ts)'
);

select throws_ok(
  $q$ select * from public.create_installment_plan('88880000-0000-0000-0000-000000000003', 3) $q$,
  '22023', 'Платежей больше, чем тыйынов в остатке',
  'Остаток 2 тыйына на 3 платежа — читаемый 22023, а не 23514 на installments_amount_positive'
);

select throws_ok(
  $q$ select * from public.create_installment_plan('88880000-0000-0000-0000-000000000004', 0) $q$,
  '22023', null, 'n = 0 — 22023'
);

select throws_ok(
  $q$ select * from public.create_installment_plan('88880000-0000-0000-0000-000000000004', 25) $q$,
  '22023', null, 'n = 25 — 22023'
);

select throws_ok(
  $q$ select * from public.create_installment_plan('88880000-0000-0000-0000-000000000004', 3,
        public.center_today('cccccccc-0000-0000-0000-00000000000a') - 1) $q$,
  '22023', null,
  'Первый платёж вчерашней датой — 22023: план из прошлого дал бы залп overdue-уведомлений'
);

select throws_ok(
  $q$ select * from public.create_installment_plan('88880000-0000-0000-0000-000000000004', 3, null, 0::smallint) $q$,
  '22023', null, 'Шаг 0 месяцев — 22023'
);

-- Предпросмотр считал остаток 50 000, а на сервере 60 000 — как
-- refund_subscription(p_expected_tiyin).
select throws_ok(
  $q$ select * from public.create_installment_plan('88880000-0000-0000-0000-000000000006', 2,
        public.center_today('cccccccc-0000-0000-0000-00000000000a'), 1::smallint, 50000) $q$,
  '23514', null,
  'Остаток изменился между предпросмотром и созданием плана — 23514 с русским текстом'
);

select count(*) from public.create_installment_plan('88880000-0000-0000-0000-000000000006', 2,
  public.center_today('cccccccc-0000-0000-0000-00000000000a'), 1::smallint, 60000);


-- 14-16. Прямая запись закрыта -----------------------------------------------------

select ok(not has_table_privilege('authenticated', 'public.installments', 'INSERT'),
  'authenticated не вставляет в installments напрямую — только create_installment_plan');
select ok(not has_table_privilege('authenticated', 'public.installments', 'UPDATE'),
  'authenticated не правит installments напрямую');
select ok(not has_table_privilege('authenticated', 'public.installments', 'DELETE'),
  'authenticated не удаляет installments');
select ok(not has_table_privilege('authenticated', 'public.installment_plans', 'INSERT'),
  'authenticated не вставляет в installment_plans напрямую');
-- tenant_admin от apply_tenant_rls — for all: один grant update в будущей
-- миграции позволил бы вернуть cancelled_at в null и воскресить мёртвый план.
select ok(not has_table_privilege('authenticated', 'public.installment_plans', 'UPDATE'),
  'authenticated не правит installment_plans напрямую');
select ok(not has_table_privilege('authenticated', 'public.installment_plans', 'DELETE'),
  'authenticated не удаляет installment_plans');


-- 17-31. pay_installment, свободные платежи, календарь -----------------------------

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

-- Оплаченный абонемент с живым (оплаченным) планом: остаток проверяется
-- раньше живого плана — иначе тупик «отмените рассрочку» ↔ «отменять нечего».
select throws_ok(
  $q$ select * from public.create_installment_plan('88880000-0000-0000-0000-000000000001', 2) $q$,
  '22023', 'Абонемент оплачен — рассрочивать нечего',
  'Оплаченный абонемент: «рассрочивать нечего», а не «сначала отмените рассрочку»'
);

-- sub5 — план из одной строки со сроком сегодня, ученик уходит в архив.
select count(*) from public.create_installment_plan('88880000-0000-0000-0000-000000000005', 1,
  public.center_today('cccccccc-0000-0000-0000-00000000000a'));
select public.archive_student('eeeeeeee-0000-0000-0000-000000000003');

-- sub4 — три строки: сегодня, +1 мес, +2 мес.
select is(
  (select count(*)::int from public.create_installment_plan('88880000-0000-0000-0000-000000000004', 3,
    public.center_today('cccccccc-0000-0000-0000-00000000000a'))),
  3,
  'План sub4 на 3 платежа создан'
);

select is(
  (select array_agg(due_date order by seq) from public.installments
    where subscription_id = '88880000-0000-0000-0000-000000000004'),
  array[
    public.center_today('cccccccc-0000-0000-0000-00000000000a'),
    (public.center_today('cccccccc-0000-0000-0000-00000000000a') + interval '1 month')::date,
    (public.center_today('cccccccc-0000-0000-0000-00000000000a') + interval '2 months')::date
  ],
  'Календарь: каждая дата — «первая + k месяцев», не цепочкой (finance.ts::installmentDueDates — те же правила)'
);

-- Фиксированная дата — те же входные данные, что в finance.test.ts:
-- 31 января → 28 февраля (прижим) → 31 марта (не дрейф цепочкой).
select count(*) from public.create_installment_plan('88880000-0000-0000-0000-000000000007', 3, '2030-01-31');

select is(
  (select array_agg(due_date order by seq) from public.installments
    where subscription_id = '88880000-0000-0000-0000-000000000007'),
  array['2030-01-31'::date, '2030-02-28'::date, '2030-03-31'::date],
  'Календарь на фиксированной дате: 2030-01-31 → 02-28 → 03-31 (общий набор с Vitest)'
);

reset role;


-- 32. Отмена абонемента гасит план триггером ---------------------------------------

-- Любой путь отмены (refund_subscription, transfer_remaining, будущие) —
-- проверяется само событие update status, а не конкретная RPC.
update public.subscriptions set status = 'cancelled' where id = '88880000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.installments_view
    where subscription_id = '88880000-0000-0000-0000-000000000002' and state = 'cancelled'),
  3,
  'status = cancelled → план отменён триггером, все три строки cancelled'
);


-- 33-45. installments_notify — due / overdue, окно, идемпотентность, null-дата ------

-- Имитация хода времени: sub4 seq 2 просрочена на день, seq 3 — ровно на
-- 30 (граница окна, внутри); sub6 seq 1 — на 31 (вне окна), seq 2 — сегодня
-- (второй абонемент в due: CTE today не должна схлопывать выборку).
update public.installments
   set due_date = public.center_today('cccccccc-0000-0000-0000-00000000000a') - 1
 where subscription_id = '88880000-0000-0000-0000-000000000004' and seq = 2;
update public.installments
   set due_date = public.center_today('cccccccc-0000-0000-0000-00000000000a') - 30
 where subscription_id = '88880000-0000-0000-0000-000000000004' and seq = 3;
update public.installments
   set due_date = public.center_today('cccccccc-0000-0000-0000-00000000000a') - 31
 where subscription_id = '88880000-0000-0000-0000-000000000006' and seq = 1;
update public.installments
   set due_date = public.center_today('cccccccc-0000-0000-0000-00000000000a')
 where subscription_id = '88880000-0000-0000-0000-000000000006' and seq = 2;

select is(
  (select array_agg(state order by seq) from public.installments_view
    where subscription_id = '88880000-0000-0000-0000-000000000004'),
  array['due', 'overdue', 'overdue'],
  'installments_view: состояния sub4 — due / overdue / overdue от center_today центра'
);

-- Cron-контекст: без auth.uid().
select public.tests_claims(null, null);

create temporary table t_notify as select * from public.installments_notify();

select is((select due_count from t_notify), 2, 'installments_notify: два due (sub4 seq 1, sub6 seq 2) — два абонемента в одной выборке');
select is((select overdue_count from t_notify), 2, 'installments_notify: два overdue (sub4 seq 2 — вчера, seq 3 — ровно 30 дней, внутри окна)');

select is(
  (select count(*)::int from public.events where type = 'installment.due'), 2,
  'События installment.due — ровно два'
);
select is(
  (select count(*)::int from public.events where type = 'installment.overdue'), 2,
  'События installment.overdue — ровно два'
);
select is(
  (select payload->>'amount_tiyin' from public.events
    where type = 'installment.due' and payload->>'subscription_id' = '88880000-0000-0000-0000-000000000004'),
  '100000',
  'Payload due: amount_tiyin строки (contract installmentPayload)'
);
select is(
  (select count(*)::int from public.events
    where type in ('installment.due', 'installment.overdue')
      and payload->>'subscription_id' = '88880000-0000-0000-0000-000000000005'),
  0,
  'Архивный ученик (sub5, срок сегодня) — уведомлений нет (students.status = archived)'
);
select ok(
  (select overdue_notified_at is null from public.installments
    where subscription_id = '88880000-0000-0000-0000-000000000006' and seq = 1),
  'Просрочка на 31 день — вне окна, не уведомляется: первый запуск планировщика не даёт залп'
);
select ok(
  (select overdue_notified_at is not null from public.installments
    where subscription_id = '88880000-0000-0000-0000-000000000004' and seq = 3),
  'Просрочка ровно на 30 дней — граница окна включительно, уведомлена'
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

-- null вместо даты платежа — сегодня, а не 23502.
select lives_ok(
  format($q$ select public.pay_installment(%L, null, null) $q$,
    (select id from public.installments where subscription_id = '88880000-0000-0000-0000-000000000006' and seq = 2)),
  'pay_installment(p_paid_at => null) — дата подставляется, не 23502'
);
select is(
  (select paid_tiyin from public.subscriptions where id = '88880000-0000-0000-0000-000000000006'),
  60000,
  'Оплата «по строку 2 включительно» закрыла обе строки sub6: 60000'
);

reset role;
revoke execute on function public.installments_notify() from authenticated;
revoke execute on function public.emit_event_unchecked(text, jsonb, uuid) from authenticated;


-- 46-54. Границы доступа ------------------------------------------------------------

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
  'installments_view под родителем — security_invoker пропускает свои строки (installments, installment_plans, subscriptions)'
);
-- Нарастающий итог считается латеральным подзапросом под RLS вызывающего:
-- сужение родительской политики иначе занизило бы его молча.
select is(
  (select cumulative_tiyin from public.installments_view
    where subscription_id = '88880000-0000-0000-0000-000000000001' and seq = 2),
  200000,
  'Под родителем нарастающий итог второй строки — сумма обеих (200000), не заниженный'
);
select is(
  (select payment_state from public.subscription_payment_summary('88880000-0000-0000-0000-000000000001')),
  'overpaid',
  'Родитель видит статус оплаты своего абонемента'
);
select throws_ok(
  $q$ select * from public.create_installment_plan('88880000-0000-0000-0000-000000000004', 2) $q$,
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
select throws_ok(
  $q$ select public.cancel_installment_plan('88880000-0000-0000-0000-000000000001') $q$,
  '42704', null,
  'Владелец центра Б не отменяет план центра А — 42704'
);

reset role;


-- 55-63. Отмена плана целиком, возврат не воскрешает мёртвый план ------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  public.cancel_installment_plan('88880000-0000-0000-0000-000000000004'), 3,
  'cancel_installment_plan: план sub4 из трёх неоплаченных строк отменён'
);
select is(
  (select count(*)::int from public.events where type = 'installment_plan.cancelled'), 1,
  'installment_plan.cancelled эмитировано'
);
select throws_ok(
  $q$ select public.cancel_installment_plan('88880000-0000-0000-0000-000000000004') $q$,
  '22023', null,
  'Повторная отмена — живого плана нет, 22023'
);

-- План B: 2 × 150 000, первая строка оплачена — отмена гасит план ЦЕЛИКОМ,
-- включая оплаченную строку: иначе она смешивалась бы с новым планом и
-- воскресала в overdue после возврата.
select is(
  (select count(*)::int from public.create_installment_plan('88880000-0000-0000-0000-000000000004', 2)),
  2,
  'После отмены новый план возможен (свой plan_id, seq с единицы)'
);

insert into t_ins (name, id)
select 'p_b1', public.pay_installment(
  (select v.id from public.installments_view v
    where v.subscription_id = '88880000-0000-0000-0000-000000000004' and v.state <> 'cancelled' and v.seq = 1));

select is(
  public.cancel_installment_plan('88880000-0000-0000-0000-000000000004'), 1,
  'Отмена плана с оплаченной первой строкой — возвращает число неоплаченных (1), для «Отменено N платежей»'
);
select is(
  (select count(*)::int from public.installments_view
    where subscription_id = '88880000-0000-0000-0000-000000000004' and state = 'cancelled'),
  5,
  'Все пять строк sub4 (план A и план B) — cancelled, оплаченная тоже'
);

-- Возврат 1 500 сом: paid_tiyin → 0. Строки мёртвого плана B не должны
-- стать overdue.
insert into t_ins (name, id)
select 'p_refund', public.record_payment('dddddddd-0000-0000-0000-000000000001', -150000, 'refund',
  'eeeeeeee-0000-0000-0000-000000000001', '88880000-0000-0000-0000-000000000004', null, now(), 'возврат');

select is(
  (select count(*)::int from public.installments_view
    where subscription_id = '88880000-0000-0000-0000-000000000004' and state in ('upcoming', 'due', 'overdue')),
  0,
  'После возврата ни одна строка мёртвого плана не воскресла в overdue'
);
select is(
  (select overdue_count from public.subscription_payment_summary('88880000-0000-0000-0000-000000000004')),
  0,
  'summary sub4: просрочек нет — отменённые планы не считаются'
);
select throws_ok(
  $q$ select public.cancel_installment_plan('88880000-0000-0000-0000-000000000001') $q$,
  '22023', null,
  'Полностью оплаченный план отменять нечего — 22023'
);

reset role;


-- 64-67. Хранимый инвариант и service_role ------------------------------------------

-- Прямой insert второго живого плана as postgres — отказ индексом, не тишина.
select throws_like(
  $q$ insert into public.installment_plans (center_id, subscription_id, student_id, payer_id, base_paid_tiyin)
      values ('cccccccc-0000-0000-0000-00000000000a', '88880000-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001', 0) $q$,
  '%installment_plans_one_live_key%',
  'Второй живой план на абонемент невозможен даже в обход RPC — именно installment_plans_one_live_key'
);

select ok(
  not has_function_privilege('service_role', 'public.emit_event_unchecked(text,jsonb,uuid)', 'EXECUTE'),
  'emit_event_unchecked закрыта и от service_role — у него auth.uid() null, обратная проверка его пропустила бы'
);
select ok(
  not has_function_privilege('service_role', 'public.installment_plans_cancel_live(uuid)', 'EXECUTE'),
  'installment_plans_cancel_live закрыта и от service_role'
);
select ok(
  has_function_privilege('service_role', 'public.installments_notify()', 'EXECUTE'),
  'installments_notify открыта service_role — вход планировщика этапа 6 (сознательно)'
);

-- Строка принадлежит плану того же абонемента: sub3 — тот же ребёнок и
-- плательщик, что у sub1, так что остальные FK проходят, отбивает именно
-- installments_plan_fk по пяти колонкам.
select throws_ok(
  $q$ update public.installments set subscription_id = '88880000-0000-0000-0000-000000000003'
       where subscription_id = '88880000-0000-0000-0000-000000000001' and seq = 1 $q$,
  '23503', null,
  'Строку нельзя перевесить на другой абонемент, оставив plan_id чужого плана — 23503, а не тихий пересчёт порогов'
);

-- Внутренняя проверка installment_plans_cancel_live: даже с выданным
-- грантом живой пользователь чужого центра получает 42501.
grant execute on function public.installment_plans_cancel_live(uuid) to authenticated;
select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select throws_ok(
  $q$ select public.installment_plans_cancel_live('88880000-0000-0000-0000-000000000001') $q$,
  '42501', null,
  'installment_plans_cancel_live от владельца чужого центра — 42501 внутри функции, даже с грантом'
);
reset role;
revoke execute on function public.installment_plans_cancel_live(uuid) from authenticated;


-- 68. Гранты — белый список 0007 актуален -----------------------------------------

select ok(
  has_function_privilege('authenticated', 'public.create_installment_plan(uuid,integer,date,smallint,integer)', 'EXECUTE'),
  'create_installment_plan (новая сигнатура 0020) исполняется authenticated'
);


-- 69-73. Контрольные суммы и осознанное отсутствие замка ----------------------------

select is(
  (select count(*)::int from public.payments), 7,
  'Платежей за файл — семь: аванс, строка 1, свободный, переплата, sub6 (null-дата), план B строка 1, возврат'
);
select is(
  (select count(*)::int from pg_trigger
    where tgrelid = 'public.installments'::regclass and tgname like 'financial_period_guard%'),
  0,
  'На installments нет financial_period_guard — сознательно (0018 Р2, 0020 Р13): денежный факт — платёж'
);
select is(
  (select count(*)::int from public.installments_view
    where subscription_id = '88880000-0000-0000-0000-000000000004' and state <> 'cancelled'),
  0,
  'У sub4 живых строк нет — оба плана отменены'
);
select is(
  (select installments_total from public.subscription_payment_summary('88880000-0000-0000-0000-000000000004')),
  0,
  'summary sub4: отменённые планы в installments_total не считаются'
);
select is(
  (select count(*)::int from public.events where type = 'installment_plan.created'), 7,
  'installment_plan.created — по одному на каждый созданный план (sub1, sub2, sub6, sub5, sub4 A, sub7, sub4 B)'
);

select * from finish();

rollback;
