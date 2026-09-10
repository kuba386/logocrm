-- pgTAP: ядро денежного учёта (миграция 0013).
-- Два центра — межтенантная граница; составные FK — платёж не может
-- сослаться на чужого ребёнка/абонемент; знак суммы — payments_sign_
-- matches_kind; замок месяца — payments/attendance/lessons.status, old
-- и new дата разом; close_month/reopen_month — роли и пересчёт сам, не по
-- предпросмотру.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(38);

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
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','revoked@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Препод А');

-- Два плательщика в центре А: свой (d1) и чужой для ребёнка e1 (d2) —
-- проверка «платёж не от того плательщика».
insert into public.payers (id, center_id, full_name, phone) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Иванова А.','+996700111222'),
  ('bbbbbbbb-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Чужая Б.','+996700333444'),
  ('bbbbbbbb-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Плательщик Б.','+996700999888');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Данияр','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Чужой','bbbbbbbb-0000-0000-0000-00000000000b',null);

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('99999999-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Индивидуальное',45,50000);

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',null,null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner',null,null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001',null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','parent',null,'bbbbbbbb-0000-0000-0000-000000000001');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

insert into public.subscription_types (id, center_id, name, service_id, kind, lessons_count, price_tiyin)
values ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
        'Восемь занятий','99999999-0000-0000-0000-000000000001','lessons',8,400000);

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at)
values ('88888888-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
        'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
        '77777777-0000-0000-0000-000000000001', 8, 400000, 50000, current_date - 10);

-- Абонемент центра Б — только для теста 11 (составной FK по чужому центру).
-- Вставляется здесь, как postgres, до первого set local role: RLS
-- attendance/services/subscriptions пускает insert только своему центру,
-- а роль в этом месте файла ещё не переключена ни на одного пользователя
-- (первое tests_claims — в блоке «1-3» ниже). Вставка под ролью owner-A
-- (как было раньше, ближе к тесту 11) падает на RLS «чужого» insert.
insert into public.services (id, center_id, name, duration_min, default_price_tiyin)
values ('99999999-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Индивидуальное',45,70000);
insert into public.subscription_types (id, center_id, name, service_id, kind, lessons_count, price_tiyin)
values ('77777777-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b',
        'Чужой тип','99999999-0000-0000-0000-00000000000b','lessons',4,100000);
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at)
values ('88888888-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b',
        'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-00000000000b',
        '77777777-0000-0000-0000-00000000000b', 4, 100000, 25000, current_date - 5);

-- Три занятия: ...001 «вчера» (текущий, открытый месяц) — общего вида.
-- ...002 в M1 (2 месяца назад), уже status='done' — единственная причина,
-- по которой close_month(M1) вообще сможет пройти в тесте 19. ...003 в M2
-- (3 месяца назад), status='planned' — специально НЕ отмечено, для теста
-- «close_month отклоняет месяц с неотмеченным занятием» независимо от M1.
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('44444444-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
   '99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-000000000001', now() - interval '1 day', now() - interval '1 day' + interval '45 min', 'planned'),
  ('44444444-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a',
   '99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-000000000001',
   date_trunc('month', now() - interval '2 months') + interval '10 days',
   date_trunc('month', now() - interval '2 months') + interval '10 days' + interval '45 min', 'done'),
  ('44444444-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a',
   '99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-000000000001',
   date_trunc('month', now() - interval '3 months') + interval '10 days',
   date_trunc('month', now() - interval '3 months') + interval '10 days' + interval '45 min', 'planned');

-- ...002 отмечена (как postgres, тем же приёмом, что 0009_attendance.
-- test.sql:88) — после 0014 close_month смотрит не на status='done', а на
-- отметку участника; без этой строки close_month(M1) в тесте 19 находит
-- ...002 неотмеченной и падает раньше, чем должен.
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', '44444444-0000-0000-0000-000000000002',
       'eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';

-- Платежи центра А для тестов 1-3 и 27 — без них «не видит платежей»
-- проходило бы и с полностью открытыми политиками: до первого
-- record_payment (тест 15) платежей нигде не существует вовсе, проверка
-- изоляции ничего не изолирует. Второй — от «чужого» плательщика d2,
-- специально для теста 27 (родитель не видит платежи не своего плательщика).
insert into public.payments (center_id, payer_id, student_id, amount_tiyin, kind, paid_at) values
  ('cccccccc-0000-0000-0000-00000000000a','bbbbbbbb-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-000000000001', 30000, 'payment', now()),
  ('cccccccc-0000-0000-0000-00000000000a','bbbbbbbb-0000-0000-0000-000000000002',
   null, 30000, 'payment', now());


-- 1-3. Изоляция и роли ---------------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;

select is(
  (select count(*)::int from public.payment_sources), 5,
  'Владелец центра Б видит только пять своих источников (сид create_center), не центра А'
);
select is(
  (select count(*)::int from public.payments), 0,
  'Владелец центра Б не видит платежей центра А'
);
select is(
  -- Не голый count(*) = 0: у центра Б есть своя строка student_payers
  -- (триггер завёл её на "Чужой" студентке при фикстурной вставке, payer_id
  -- ...b). Фильтр по center_id — именно то, что проверяет межтенантную
  -- границу, не зависит от того, сколько у Б своих строк.
  (select count(*)::int from public.student_payers where center_id = 'cccccccc-0000-0000-0000-00000000000a'), 0,
  'Владелец центра Б не видит student_payers центра А'
);

reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.payments), 0,
  'Специалист не видит ни одного платежа своего же центра'
);
select is(
  (select count(*)::int from public.student_payers), 0,
  'Специалист не видит student_payers своего же центра'
);

reset role;


-- 4-5. Отозванное членство ------------------------------------------------------

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', 100000) $q$,
  '42501', 'Недостаточно прав', 'record_payment: отозванный получает 42501'
);
select throws_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  '42501', 'Недостаточно прав', 'close_month: отозванный получает 42501'
);

reset role;


-- 6-9. Прямая запись закрыта -----------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select ok(
  not has_table_privilege('authenticated', 'public.payments', 'DELETE'),
  'authenticated не может удалить строку из payments вообще'
);
select ok(
  not has_table_privilege('authenticated', 'public.payments', 'INSERT'),
  'authenticated не может вставить платёж напрямую — только через record_payment'
);
select ok(
  not has_table_privilege('authenticated', 'public.student_payers', 'INSERT'),
  'authenticated не может вставить строку в student_payers напрямую — только триггером'
);
select ok(
  not has_table_privilege('authenticated', 'public.student_payers', 'UPDATE'),
  'authenticated не может изменить строку student_payers'
);
select ok(
  not has_table_privilege('authenticated', 'public.student_payers', 'DELETE'),
  'authenticated не может удалить строку student_payers — append-only'
);
select throws_ok(
  $q$ update public.financial_periods set closed_at = now() where center_id = 'cccccccc-0000-0000-0000-00000000000a' $q$,
  '42501', null, 'Прямой PATCH financial_periods отклонён — только close_month/reopen_month'
);
select throws_ok(
  $q$ update public.subscriptions set paid_tiyin = 999999 where id = '88888888-0000-0000-0000-000000000001' $q$,
  '42501', null, 'Прямая правка paid_tiyin отклонена — колонка вне гранта'
);


-- 10. Платёж от чужого плательщика — составной FK ---------------------------------

select throws_ok(
  $q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000002', 100000, 'payment',
                                   'eeeeeeee-0000-0000-0000-000000000001') $q$,
  '23503', null,
  'Платёж от плательщика, не привязанного к ребёнку, отклонён составным FK'
);


-- 11. Платёж на абонемент чужого центра — составной FK -----------------------------

-- Абонемент центра Б (fin_b, фикстура вверху файла) — настоящий, существующий,
-- но FK (subscription_id, student_id, center_id) ищет строку с center_id
-- ЦЕНТРА А (он подставится из current_center() внутри record_payment,
-- вызов идёт под owner-A) — такой не существует, даже если сам
-- subscription_id реален.
select throws_ok(
  $q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', 100000, 'payment',
                                   'eeeeeeee-0000-0000-0000-000000000001', '88888888-0000-0000-0000-00000000000b') $q$,
  '23503', null,
  'Платёж на реальный, но чужой (центра Б) абонемент отклонён составным FK'
);


-- 12-14. Знак суммы и сумма без ученика -------------------------------------------

select throws_ok(
  $q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', -100000, 'payment') $q$,
  '23514', null, 'payment с отрицательной суммой — CHECK payments_sign_matches_kind'
);
select throws_ok(
  $q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', 100000, 'refund') $q$,
  '23514', null, 'refund с положительной суммой — CHECK payments_sign_matches_kind'
);
select lives_ok(
  $q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', -50000, 'correction') $q$,
  'correction с отрицательной суммой проходит — знак у него не ограничен'
);


-- 15-17. Успешный платёж, пересчёт paid_tiyin, коллизия абонемент/ученик -----------

create temporary table t_pay (name text primary key, id uuid);
grant select, insert on t_pay to authenticated;

insert into t_pay (name, id)
select 'p1', public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', 200000, 'payment',
                                   'eeeeeeee-0000-0000-0000-000000000001', '88888888-0000-0000-0000-000000000001',
                                   null, now(), 'первый взнос');

select is(
  (select paid_tiyin from public.subscriptions where id = '88888888-0000-0000-0000-000000000001'),
  200000,
  -- correction из теста 14 — без subscription_id, на пересчёт этого
  -- абонемента не влияет; только что записанный платёж — единственный.
  'paid_tiyin пересчитан из payments (200000)'
);

select throws_ok(
  $q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', 100000, 'payment',
                                   null, '88888888-0000-0000-0000-000000000001') $q$,
  '23514', null,
  'Абонемент без ученика в том же платеже — payments_subscription_needs_student'
);


-- 18. Возврат больше оплаченного — paid_tiyin не уходит в минус --------------------

select throws_ok(
  $q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', -900000, 'refund',
                                   'eeeeeeee-0000-0000-0000-000000000001', '88888888-0000-0000-0000-000000000001') $q$,
  '23514', null,
  'Возврат больше оплаченного — CHECK subscriptions_paid_not_negative'
);


-- 19-21. Замок месяца: payments и attendance, старая и новая дата -----------------

select lives_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  'close_month(M1) проходит: planned-занятий в месяце нет (...002 уже done)'
);

select throws_ok(
  format($q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', 50000, 'payment',
                                          null, null, null, %L) $q$,
    (date_trunc('month', now() - interval '2 months') + interval '5 days')),
  '22023', null,
  'Платёж датой закрытого месяца отклонён'
);

insert into t_pay (name, id)
select 'p2', public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', 30000, 'payment');

select throws_ok(
  format($q$ update public.payments set paid_at = %L where id = (select id from t_pay where name = 'p2') $q$,
    (date_trunc('month', now() - interval '2 months') + interval '5 days')),
  '42501', null,
  'paid_at не в гранте на update вовсе — перенос в закрытый месяц отбивается на гранте раньше, чем на замке'
);

select throws_ok(
  $q$ select public.mark_attendance('44444444-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000001','present') $q$,
  '22023', null,
  'Отметка занятия из закрытого месяца отклонена замком (дата занятия, не marked_at)'
);


-- 22. lessons.status в закрытом месяце ---------------------------------------------

select throws_ok(
  $q$ update public.lessons set status = 'cancelled' where id = '44444444-0000-0000-0000-000000000002' $q$,
  '22023', null,
  'Смена статуса занятия в закрытом месяце отклонена замком'
);


-- 23-24. close_month: текущий месяц и занятия без отметки --------------------------

select throws_ok(
  $q$ select public.close_month(date_trunc('month', now())::date) $q$,
  '22023', null, 'close_month текущего месяца отклонён'
);

select throws_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '3 months')::date) $q$,
  '22023', null,
  'close_month месяца с неотмеченным planned-занятием отклонён (занятие ...003, M2, независимо от M1)'
);


-- 25-26. Повторное закрытие и reopen_month только owner ----------------------------

select throws_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  '22023', null, 'Повторный close_month того же месяца — читаемый 22023, не голый conflict'
);

reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.reopen_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  '42501', 'Недостаточно прав', 'reopen_month: не owner (здесь teacher) отклонён'
);

reset role;


-- 27. Родитель видит свои платежи, не видит чужого плательщика --------------------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select ok(
  (select count(*)::int from public.payments) > 0,
  'Родитель видит хотя бы один свой платёж (по payer_id)'
);
select is(
  (select count(*)::int from public.payments p where p.payer_id = 'bbbbbbbb-0000-0000-0000-000000000002'),
  0,
  'Родитель не видит платежи чужого плательщика того же центра'
);
select is(
  (select count(*)::int from public.student_payers), 0,
  'Родитель не видит student_payers (apply_tenant_rls — только owner/admin, как и у специалиста)'
);

reset role;


-- 28. reopen_month владельцем — платёж в открытый снова месяц проходит -------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select lives_ok(
  $q$ select public.reopen_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  'reopen_month(M1) владельцем проходит'
);

select lives_ok(
  format($q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', 10000, 'payment',
                                          null, null, null, %L) $q$,
    (date_trunc('month', now() - interval '2 months') + interval '5 days')),
  'После reopen_month платёж той же датой снова проходит'
);


-- 29-30. Гранты: белый список 0007 дополнен --------------------------------------

select ok(
  not has_function_privilege('authenticated', 'public.financial_period_guard()', 'EXECUTE'),
  'Триггерная financial_period_guard закрыта для authenticated'
);
select ok(
  has_function_privilege('authenticated', 'public.record_payment(uuid,integer,text,uuid,uuid,uuid,timestamptz,text)', 'EXECUTE'),
  'record_payment исполняется authenticated (белый список 0007 актуален)'
);

reset role;

select * from finish();

rollback;
