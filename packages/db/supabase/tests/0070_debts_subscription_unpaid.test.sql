-- pgTAP: student_subscriptions_overdue() + student_balance.subscription_overdue_tiyin
-- / subscription_overdue_payer_id (0070).
--
-- Два ревью — плана и написанного SQL — нашли настоящие ошибки, каждая
-- закрыта отдельным случаем ниже, а не только исправлением кода:
--   - «просрочка», не «любая недоплата»: план рассрочки на будущее не
--     должен считаться просроченным (sub2);
--   - просрочка по плану ограничена фактическим остатком, а не суммой
--     просроченных строк «как есть» — платёж мимо pay_installment (обычной
--     формой) не гасит конкретную строку, cumulative-сумма installments_view
--     это не видит (sub10 — только одна строка из двух, sub11 — остаток
--     меньше суммы просроченных строк);
--   - атрибуция долга по subscriptions.payer_id, не по текущему
--     students.payer_id ребёнка — их могли развести (sub7);
--   - у одного ребёнка бывает больше одного абонемента одновременно —
--     суммы складываются, строка одна (sub12);
--   - фикстура вставляется как postgres до первого set local role — иначе
--     multi-row insert с двумя центрами падает на RLS tenant_admin, а
--     платежи/планы для каждого центра — под claims именно того центра.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(47);

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a-0070@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','finance-a-0070@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher-a-0070@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','registrar-a-0070@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent1-0070@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','parent2-0070@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-no-payer-0070@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','99999999-9999-9999-9999-999999999999','authenticated','authenticated','owner-b-0070@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0070-0000-0000-00000000000a','Центр А 0070','centr-a-0070','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0070-0000-0000-00000000000b','Центр Б 0070','centr-b-0070','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0070-0000-0000-000000000001','cccccccc-0070-0000-0000-00000000000a','Специалист 0070');

-- Плательщик Б — свой, в своём центре: платёж/абонемент центра Б не может
-- ссылаться на плательщика центра А (составные FK payer_fk, ревью SQL №3).
insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0070-0000-0000-000000000001','cccccccc-0070-0000-0000-00000000000a','Плательщик 1','+996700000011'),
  ('dddddddd-0070-0000-0000-000000000002','cccccccc-0070-0000-0000-00000000000a','Плательщик 2','+996700000012'),
  ('dddddddd-0070-0000-0000-0000000000b1','cccccccc-0070-0000-0000-00000000000b','Плательщик Б','+996700000013');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0070-0000-0000-00000000000a','owner', null, null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0070-0000-0000-00000000000a','finance', null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0070-0000-0000-00000000000a','teacher','aaaaaaaa-0070-0000-0000-000000000001', null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0070-0000-0000-00000000000a','registrar', null, null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0070-0000-0000-00000000000a','parent', null, 'dddddddd-0070-0000-0000-000000000001'),
  ('66666666-6666-6666-6666-666666666666','cccccccc-0070-0000-0000-00000000000a','parent', null, 'dddddddd-0070-0000-0000-000000000002'),
  -- Родитель без payer_id в membership (0031: зеркало «parent без payer_id»).
  ('77777777-7777-7777-7777-777777777777','cccccccc-0070-0000-0000-00000000000a','parent', null, null),
  ('99999999-9999-9999-9999-999999999999','cccccccc-0070-0000-0000-00000000000b','owner', null, null);

-- Ребёнок 7 заводится с payer_id = плательщик 1 (как реально было при
-- продаже) — на плательщика 2 его переведут ПОЗЖЕ, сырым update, вместе с
-- триггером students_track_payer (0014), а не декларативно (ревью SQL №4).
insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0070-0000-0000-000000000001','cccccccc-0070-0000-0000-00000000000a','Без рассрочки','dddddddd-0070-0000-0000-000000000001'),
  ('eeeeeeee-0070-0000-0000-000000000002','cccccccc-0070-0000-0000-00000000000a','Рассрочка не наступила','dddddddd-0070-0000-0000-000000000001'),
  ('eeeeeeee-0070-0000-0000-000000000003','cccccccc-0070-0000-0000-00000000000a','Рассрочка просрочена целиком','dddddddd-0070-0000-0000-000000000001'),
  ('eeeeeeee-0070-0000-0000-000000000004','cccccccc-0070-0000-0000-00000000000a','Оплачен полностью','dddddddd-0070-0000-0000-000000000001'),
  ('eeeeeeee-0070-0000-0000-000000000005','cccccccc-0070-0000-0000-00000000000a','Абонемент отменён','dddddddd-0070-0000-0000-000000000001'),
  ('eeeeeeee-0070-0000-0000-000000000006','cccccccc-0070-0000-0000-00000000000a','Рассрочку отменили','dddddddd-0070-0000-0000-000000000001'),
  ('eeeeeeee-0070-0000-0000-000000000007','cccccccc-0070-0000-0000-00000000000a','Передан плательщику 2 позже','dddddddd-0070-0000-0000-000000000001'),
  ('eeeeeeee-0070-0000-0000-000000000008','cccccccc-0070-0000-0000-00000000000b','Ребёнок центра Б','dddddddd-0070-0000-0000-0000000000b1'),
  ('eeeeeeee-0070-0000-0000-000000000009','cccccccc-0070-0000-0000-00000000000a','Удалённый ребёнок','dddddddd-0070-0000-0000-000000000001'),
  ('eeeeeeee-0070-0000-0000-000000000010','cccccccc-0070-0000-0000-00000000000a','Просрочена одна строка из двух','dddddddd-0070-0000-0000-000000000001'),
  ('eeeeeeee-0070-0000-0000-000000000011','cccccccc-0070-0000-0000-00000000000a','Частичный платёж мимо рассрочки','dddddddd-0070-0000-0000-000000000001'),
  ('eeeeeeee-0070-0000-0000-000000000012','cccccccc-0070-0000-0000-00000000000a','Два абонемента сразу','dddddddd-0070-0000-0000-000000000001');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

-- Вся фикстура-сырец — как postgres, ДО первого set local role (ревью SQL
-- №3): multi-row insert с центром Б в одном операторе с центром А упал бы
-- на with check tenant_admin, если бы роль уже была authenticated с claims
-- владельца А (паттерн 0018-теста).
--
-- sub1  — без плана, недоплата 60000: просрочено немедленно.
-- sub2  — план на будущее: просрочки нет.
-- sub3  — план целиком в прошлом: обе строки просрочены, недоплата = сумме.
-- sub4  — оплачен полностью: не попадает никуда.
-- sub5  — status='cancelled' после платежа: не в наборе.
-- sub6  — план создан и отменён cancel_installment_plan: снова «без плана».
-- sub7  — без плана, продан плательщику 1; ребёнка передадут плательщику 2.
-- sub8  — центр Б, свой плательщик.
-- sub9  — без плана; студента удалят (deleted_at) после недоплаты.
-- sub10 — план из двух строк, просрочена будет только одна (seq=1).
-- sub11 — план из двух строк, просрочены обе, но обычным платежом (мимо
--         pay_installment) внесут ещё 15000 — остаток меньше суммы строк.
-- sub12a — без плана (60000), sub12b — план просрочен (30000): ОДИН ребёнок,
--          два абонемента сразу — суммы складываются в одну строку.
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                   lesson_price_tiyin, starts_at) values
  ('88880070-0000-0000-0000-000000000001','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000001','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000002','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000002','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000003','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000003','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000004','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000004','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000005','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000005','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000006','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000006','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000007','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000007','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000008','cccccccc-0070-0000-0000-00000000000b',
   'eeeeeeee-0070-0000-0000-000000000008','dddddddd-0070-0000-0000-0000000000b1', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000009','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000009','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000010','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000010','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000011','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000011','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000012','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000012','dddddddd-0070-0000-0000-000000000001', null, 4, 100000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date),
  ('88880070-0000-0000-0000-000000000013','cccccccc-0070-0000-0000-00000000000a',
   'eeeeeeee-0070-0000-0000-000000000012','dddddddd-0070-0000-0000-000000000001', null, 2, 50000, 25000,
   (date_trunc('month', now() - interval '1 month'))::date);


-- Платежи и планы для центра А — под claims владельца А ---------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0070-0000-0000-00000000000a');
set local role authenticated;

select public.record_payment('dddddddd-0070-0000-0000-000000000001', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000001', '88880070-0000-0000-0000-000000000001', null, now(), 'аванс 1');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000002', '88880070-0000-0000-0000-000000000002', null, now(), 'аванс 2');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000003', '88880070-0000-0000-0000-000000000003', null, now(), 'аванс 3');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 100000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000004', '88880070-0000-0000-0000-000000000004', null, now(), 'оплата целиком');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000005', '88880070-0000-0000-0000-000000000005', null, now(), 'аванс 5');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000006', '88880070-0000-0000-0000-000000000006', null, now(), 'аванс 6');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000007', '88880070-0000-0000-0000-000000000007', null, now(), 'аванс 7 (плательщик 1)');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000009', '88880070-0000-0000-0000-000000000009', null, now(), 'аванс 9, ребёнок будет удалён');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000010', '88880070-0000-0000-0000-000000000010', null, now(), 'аванс 10');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000011', '88880070-0000-0000-0000-000000000011', null, now(), 'аванс 11');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000012', '88880070-0000-0000-0000-000000000012', null, now(), 'аванс 12a, без плана');
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 20000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000012', '88880070-0000-0000-0000-000000000013', null, now(), 'аванс 12b, с планом');

-- sub2 — план на будущее: оба платежа впереди, просрочки нет.
select public.create_installment_plan('88880070-0000-0000-0000-000000000002', 2::integer,
  (public.center_today('cccccccc-0070-0000-0000-00000000000a') + 20), 1::smallint);

-- sub3 — план создаётся ОБЯЗАТЕЛЬНО не в прошлом (create_installment_plan
-- сам это проверяет, 0026:1570 «Первый платёж рассрочки не может быть в
-- прошлом»); в overdue его переводит отдельный сырой update ниже.
select public.create_installment_plan('88880070-0000-0000-0000-000000000003', 2::integer,
  public.center_today('cccccccc-0070-0000-0000-00000000000a'), 1::smallint);

-- sub6 — план создаётся и сразу отменяется: должен вернуться в «без плана».
select public.create_installment_plan('88880070-0000-0000-0000-000000000006', 2::integer, null, 1::smallint);
select public.cancel_installment_plan('88880070-0000-0000-0000-000000000006');

-- sub10 — план из двух строк; просрочена будет только seq=1 (сырым update).
select public.create_installment_plan('88880070-0000-0000-0000-000000000010', 2::integer,
  public.center_today('cccccccc-0070-0000-0000-00000000000a'), 1::smallint);

-- sub11 — план из двух строк, обе будут просрочены, но после плана внесут
-- ещё 15000 обычным платежом (мимо pay_installment) — остаток станет
-- меньше суммы просроченных строк installments_view.
select public.create_installment_plan('88880070-0000-0000-0000-000000000011', 2::integer,
  public.center_today('cccccccc-0070-0000-0000-00000000000a'), 1::smallint);
select public.record_payment('dddddddd-0070-0000-0000-000000000001', 15000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000011', '88880070-0000-0000-0000-000000000011', null, now(), 'доплата мимо рассрочки');

-- sub12b — план из одной строки на 30000 (остаток 50000-20000=30000 в 1
-- платёж), будет просрочен целиком.
select public.create_installment_plan('88880070-0000-0000-0000-000000000013', 1::integer,
  public.center_today('cccccccc-0070-0000-0000-00000000000a'), 1::smallint);

reset role;


-- Платёж центра Б — под claims владельца Б, не владельца А (ревью SQL №3) --------

select public.tests_claims('99999999-9999-9999-9999-999999999999','cccccccc-0070-0000-0000-00000000000b');
set local role authenticated;

select public.record_payment('dddddddd-0070-0000-0000-0000000000b1', 40000, 'payment',
  'eeeeeeee-0070-0000-0000-000000000008', '88880070-0000-0000-0000-000000000008', null, now(), 'аванс 8, центр Б');

reset role;

-- reset role не сбрасывает request.jwt.claims (только саму роль) — без этого
-- следующая строка резолвила бы auth.uid()/role_in() по claims владельца Б
-- (последний tests_claims выше), а центр А ему не принадлежит:
-- subscriptions_cancel_installments → installment_plans_cancel_live упал бы
-- «Недостаточно прав» на update status ниже (CI это отловил в первом прогоне).
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0070-0000-0000-00000000000a');

-- Сырые правки состояния как postgres, вне RLS и вне RPC (0018-тест: любая
-- правка задним числом нормальному клиенту недоступна — только через
-- RPC/definer-функции; здесь имитация случившегося факта, не путь клиента).

-- sub5 отменяется ПОСЛЕ платежа — недоплата остаётся, но статус cancelled
-- должен полностью убрать абонемент из просрочки.
update public.subscriptions set status = 'cancelled' where id = '88880070-0000-0000-0000-000000000005';

-- Ребёнка 7 передают плательщику 2 ПОСЛЕ продажи абонемента и платежа
-- плательщиком 1 — students_track_payer (0014) заведёт вторую пару в
-- student_payers, а students.payer_id и subscriptions.payer_id разойдутся
-- по-настоящему, а не декларативно (ревью SQL №4).
update public.students set payer_id = 'dddddddd-0070-0000-0000-000000000002'
 where id = 'eeeeeeee-0070-0000-0000-000000000007';

-- Ребёнок 9 удалён ПОСЛЕ недоплаты (deleted_at, не архив-статус) — его
-- абонемент сам по себе не отменён и не оплачен, но самого ребёнка уже нет:
-- сумма не должна висеть там, где спросить про неё уже нельзя (зеркально
-- student_debts, 0031: «finance: его долг ушёл из student_debts — иначе
-- сумма висела бы там, где ребёнка уже нет»).
update public.students set deleted_at = now() where id = 'eeeeeeee-0070-0000-0000-000000000009';

-- Имитация хода времени (0018: «create_installment_plan не принимает
-- прошлое» — раздвигаем due_date сырым update):
--   sub3  — обе строки в прошлое (просрочены обе);
--   sub10 — только seq=1 (seq=2 остаётся в будущем — не просрочена);
--   sub11 — обе строки в прошлое (просрочены обе, но остаток меньше суммы);
--   sub12b (id ...013) — единственная строка в прошлое.
update public.installments
   set due_date = public.center_today('cccccccc-0070-0000-0000-00000000000a') - 45
 where subscription_id = '88880070-0000-0000-0000-000000000003' and seq = 1;
update public.installments
   set due_date = public.center_today('cccccccc-0070-0000-0000-00000000000a') - 15
 where subscription_id = '88880070-0000-0000-0000-000000000003' and seq = 2;

update public.installments
   set due_date = public.center_today('cccccccc-0070-0000-0000-00000000000a') - 10
 where subscription_id = '88880070-0000-0000-0000-000000000010' and seq = 1;
-- seq=2 у sub10 намеренно остаётся в будущем (создан с first_due=today,
-- step=1 месяц → seq=2 due=today+1 месяц) — не трогаем.

update public.installments
   set due_date = public.center_today('cccccccc-0070-0000-0000-00000000000a') - 45
 where subscription_id = '88880070-0000-0000-0000-000000000011' and seq = 1;
update public.installments
   set due_date = public.center_today('cccccccc-0070-0000-0000-00000000000a') - 15
 where subscription_id = '88880070-0000-0000-0000-000000000011' and seq = 2;

update public.installments
   set due_date = public.center_today('cccccccc-0070-0000-0000-00000000000a') - 20
 where subscription_id = '88880070-0000-0000-0000-000000000013' and seq = 1;


-- 1-11. owner: весь центр А, «просрочка», не «недоплата» -------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0070-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000001'),
  60000,
  'Без плана рассрочки: вся недоплата просрочена немедленно'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000002'),
  0,
  'План на будущее: просрочки нет (в наборе строки нет вовсе), хотя paid_tiyin < price_tiyin'
);

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000003'),
  60000,
  'План целиком в прошлом: сумма просроченных строк равна остатку (обе строки перекрывают весь остаток)'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000004'),
  0,
  'Оплачен полностью: не в наборе'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000005'),
  0,
  'Абонемент отменён (status=cancelled): не в наборе, несмотря на недоплату'
);

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000006'),
  60000,
  'Рассрочку отменили (cancel_installment_plan): абонемент вернулся в «без плана» — просрочен немедленно'
);

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000007'),
  60000,
  'Атрибуция по subscriptions.payer_id — сумма видна владельцу независимо от текущего payer_id ребёнка'
);

select is(
  (select payer_id from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000007'),
  'dddddddd-0070-0000-0000-000000000001'::uuid,
  'payer_id — плательщик 1 (кто покупал абонемент), а не плательщик 2 (текущий payer_id ребёнка)'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000008'),
  0,
  'Ребёнок центра Б не виден владельцу центра А — изоляция тенантов'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000009'),
  0,
  'Удалённый ребёнок (deleted_at): недоплата не висит там, где ребёнка уже нет'
);

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000010'),
  30000,
  'Просрочена только одна строка из двух (seq=1) — сумма равна её amount_tiyin, не всему остатку'
);


-- 12-14. Ограничение сверху фактическим остатком (капинг) ------------------------

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000011'),
  45000,
  'Обе строки просрочены (сумма 60000), но доплата 15000 мимо pay_installment снизила остаток до 45000 — просрочка не больше остатка'
);

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000012'),
  90000,
  'Два абонемента у одного ребёнка сразу: 60000 (без плана) + 30000 (план просрочен) = 90000 в одной строке'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000012'),
  1,
  'Два абонемента одного ребёнка — ровно одна строка результата, не две'
);


-- 15-17. Инвариант и общий счёт по центру -----------------------------------------

select is(
  (select count(*)::int from public.student_subscriptions_overdue() o
    where o.overdue_tiyin > (
      select coalesce(sum(greatest(s.price_tiyin - s.paid_tiyin, 0)), 0)::integer
        from public.subscriptions s
       where s.student_id = o.student_id
         and s.center_id = 'cccccccc-0070-0000-0000-00000000000a'
         and s.deleted_at is null
         and s.status <> 'cancelled'
    )),
  0,
  'Инвариант: просрочка ни у одного ребёнка не больше суммарной недоплаты по его живым абонементам'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue()), 7,
  'owner: ровно 7 строк — без плана, план-в-прошлом, план-отменён, чужой-плательщик, одна-строка-из-двух, капинг, два-абонемента'
);

select is(
  pg_typeof((select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000001'))::text,
  'integer',
  'overdue_tiyin — integer, не bigint (sum() приведён явно, иначе 42804 роняет student_balance)'
);


-- 18-21. student_balance -----------------------------------------------------------

select is(
  (select subscription_overdue_tiyin from public.student_balance where student_id = 'eeeeeeee-0070-0000-0000-000000000001'),
  60000,
  'student_balance.subscription_overdue_tiyin отражает ту же сумму, что и функция'
);

select is(
  (select subscription_overdue_payer_id from public.student_balance where student_id = 'eeeeeeee-0070-0000-0000-000000000001'),
  'dddddddd-0070-0000-0000-000000000001'::uuid,
  'student_balance.subscription_overdue_payer_id — плательщик абонемента'
);

select is(
  (select subscription_overdue_tiyin from public.student_balance where student_id = 'eeeeeeee-0070-0000-0000-000000000004'),
  0,
  'student_balance.subscription_overdue_tiyin — 0 (не NULL) у полностью оплаченного: coalesce в вью'
);

select is(
  (select count(*)::int from public.student_balance where center_id = 'cccccccc-0070-0000-0000-00000000000a'),
  10,
  'student_balance по-прежнему строка на каждого живого ребёнка центра (11 заведено, 1 удалён), а не только на должников'
);

reset role;


-- 22-23. finance: тот же расклад, что у owner (can_payments) ---------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0070-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000001'),
  60000,
  'finance: та же просрочка, что у owner (can_payments)'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue()), 7,
  'finance: те же 7 строк, что у owner'
);

reset role;


-- 24-25. registrar: тот же расклад (can_payments включает registrar, 0026) -------

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0070-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000001'),
  60000,
  'registrar: та же просрочка, что у owner — can_payments() включает registrar (0026)'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue()), 7,
  'registrar: те же 7 строк, что у owner'
);

reset role;


-- 26-27. teacher: пусто, не ошибка -----------------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0070-0000-0000-00000000000a');
set local role authenticated;

select is((select count(*)::int from public.student_subscriptions_overdue()), 0,
  'teacher: student_subscriptions_overdue пуст — оплата абонемента не его дело');
select is((select count(*)::int from public.student_balance where subscription_overdue_tiyin > 0), 0,
  'teacher: student_balance тоже не показывает просрочку (доступ к строкам всё равно закрыт students_brief)');

reset role;


-- 28-32. parent1 (плательщик 1): свои дети, атрибуция по subscriptions.payer_id --

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0070-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000001'),
  60000,
  'parent1: видит просрочку своего ребёнка без плана'
);

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000003'),
  60000,
  'parent1: видит просрочку по плану в прошлом'
);

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000007'),
  60000,
  'parent1: видит просрочку по subscriptions.payer_id, хотя ребёнка уже передали плательщику 2'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000002'),
  0,
  'parent1: план на будущее не показан и родителю'
);

select is(
  (select count(*)::int from public.student_subscriptions_overdue()), 7,
  'parent1: те же 7 строк, что у owner — все просроченные абонементы в фикстуре проданы плательщику 1'
);

reset role;


-- 33-34. parent2 (плательщик 2): не видит долг, купленный плательщиком 1 --------

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0070-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000007'),
  0,
  'parent2: НЕ видит просрочку ребёнка 7 — абонемент продан плательщику 1, не ему, хотя ребёнок теперь его'
);

select is((select count(*)::int from public.student_subscriptions_overdue()), 0,
  'parent2: своих просрочек нет вовсе');

reset role;


-- 35. Родитель без payer_id в membership: пусто, не ошибка (0031: тот же урок) ---

select public.tests_claims('77777777-7777-7777-7777-777777777777','cccccccc-0070-0000-0000-00000000000a');
set local role authenticated;

select is((select count(*)::int from public.student_subscriptions_overdue()), 0,
  'parent без payer_id в membership: student_subscriptions_overdue пуст — NULL в сравнении не открывает чужие долги');

reset role;


-- 36-37. Без auth.uid(): пусто, не ошибка ----------------------------------------

select public.tests_claims(null, null);
set local role authenticated;

select is((select count(*)::int from public.student_subscriptions_overdue()), 0,
  'student_subscriptions_overdue без auth.uid() — пусто');
select is((select count(*)::int from public.student_balance), 0,
  'student_balance без auth.uid() — ноль строк, вью не падает');

reset role;


-- 38-39. Владелец центра Б: не видит долги центра А ------------------------------

select public.tests_claims('99999999-9999-9999-9999-999999999999','cccccccc-0070-0000-0000-00000000000b');
set local role authenticated;

select is(
  (select overdue_tiyin from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000008'),
  60000,
  'owner центра Б: видит просрочку своего ребёнка'
);
select is(
  (select count(*)::int from public.student_subscriptions_overdue() where student_id = 'eeeeeeee-0070-0000-0000-000000000001'),
  0,
  'owner центра Б: не видит ребёнка центра А — изоляция тенантов в обе стороны'
);

reset role;


-- 40-41. Контракт функции: набор строк, не скаляр -------------------------------

select is(
  pg_get_function_result('public.student_subscriptions_overdue()'::regprocedure),
  'TABLE(student_id uuid, overdue_tiyin integer, payer_id uuid)',
  'student_subscriptions_overdue: набор строк на ребёнка текущего центра, не скаляр по uuid'
);

select isnt_empty(
  $q$ select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'student_subscriptions_overdue' and p.prosecdef $q$,
  'student_subscriptions_overdue — security definer'
);


-- 42-47. Гранты и колонки student_balance -----------------------------------------

select ok(
  not has_function_privilege('anon', 'public.student_subscriptions_overdue()', 'EXECUTE'),
  'anon не исполняет student_subscriptions_overdue'
);
select ok(
  not has_function_privilege('public', 'public.student_subscriptions_overdue()', 'EXECUTE'),
  'PUBLIC не исполняет student_subscriptions_overdue'
);
select ok(
  not has_function_privilege('service_role', 'public.student_subscriptions_overdue()', 'EXECUTE'),
  'service_role не исполняет student_subscriptions_overdue (не входная точка планировщика)'
);
select ok(
  has_function_privilege('authenticated', 'public.student_subscriptions_overdue()', 'EXECUTE'),
  'authenticated исполняет student_subscriptions_overdue'
);

select ok(
  (select coalesce(array_to_string(c.reloptions, ','), '') like '%security_invoker=true%'
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'student_balance'),
  'student_balance остаётся security_invoker после create or replace (0070) — иначе вью читалась бы от владельца, не от вызывающего'
);

select results_eq(
  $q$ select column_name::text from information_schema.columns
       where table_schema = 'public' and table_name = 'student_balance'
       order by ordinal_position $q$,
  $q$ values ('student_id'), ('center_id'), ('active_subscription_id'), ('lessons_left'), ('ends_at'),
             ('debt_tiyin'), ('overdrawn_tiyin'), ('state'), ('subscription_overdue_tiyin'),
             ('subscription_overdue_payer_id') $q$,
  'student_balance: порядок колонок — восемь старых (0031), потом две новые в хвосте (0070); следующая миграция, дописывающая колонку не в конец, упадёт здесь, а не на 42P16 в проде'
);


select * from finish();

rollback;
