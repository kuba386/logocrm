-- pgTAP: возврат платёжной строкой, переплата как инвариант (0030).
-- Чек-лист этапа 5 п.4: частично оплаченный абонемент (продажа 4 000,
-- оплата 2 000) — деньги возврата ограничены внесённым (2 000), а не
-- стоимостью неотработанных занятий (4 000, ничего не списано).
-- Claims — явно перед каждым блоком: reset role их не сбрасывает.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(46);

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-b@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','registrar-a@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-0030','{}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-0030','{}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист А');

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик А','+996700000001');

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок 1','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Ребёнок 2','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Ребёнок 3','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','Ребёнок 4','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-00000000000a','Ребёнок 5','dddddddd-0000-0000-0000-000000000001');

-- Свои плательщик/ребёнок центра Б — чтобы ниже пробовать переплату по
-- чужому (центр А) subscription_id, не спотыкаясь о payments_payer_fk
-- раньше, чем сработает нужный по смыслу payments_subscription_fk.
insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Плательщик Б','+996700000099');
insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Ребёнок Б','dddddddd-0000-0000-0000-00000000000b');

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','8 занятий','lessons',8,400000);

insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner', null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner', null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','finance', null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001'),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','parent', null),
  ('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a','registrar', null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_ins (name text primary key, id uuid);
grant select, insert on t_ins to authenticated;
create temporary table t_src as
  select id from public.payment_sources
   where center_id = 'cccccccc-0000-0000-0000-00000000000a' order by sort, code limit 1;
grant select on t_src to authenticated;


-- 1-2. Схема ----------------------------------------------------------------------------

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'payments'
           and indexname = 'payments_refund_once_key' and indexdef like '%WHERE%kind = %refund%'),
  'Частичный unique — один возврат на абонемент'
);
select ok(
  exists (select 1 from pg_trigger t
           where t.tgname = 'payments_recalc_paid_overpay_guard' and t.tgrelid = 'public.payments'::regclass
             and pg_get_triggerdef(t.oid) like 'CREATE TRIGGER%AFTER%'),
  'Триггер payments_recalc_paid_overpay_guard — AFTER (имя по алфавиту после payments_recalc_paid, Р13)'
);


-- 3-10. Чек-лист п.4: частично оплаченный абонемент — возврат ограничен внесённым (Р1) ----

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

create temporary table t_sale as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
    '55550000-0000-0000-0000-000000000030', null, null, 200000, (select id from t_src));
insert into t_ins select 'sub1', subscription_id from t_sale limit 1;

select is(
  public.refund_calc((select id from t_ins where name = 'sub1')), 400000,
  'refund_calc: ничего не отработано — стоимость неотработанных занятий равна полной цене'
);
select is(
  public.refund_subscription((select id from t_ins where name = 'sub1'), 400000, (select id from t_src)),
  400000,
  'refund_subscription возвращает refund_calc (стоимость занятий), не капнутую сумму денег'
);
select is(
  (select paid_tiyin from public.subscriptions where id = (select id from t_ins where name = 'sub1')), 0,
  'paid_tiyin после возврата — 0 (вернули ровно внесённое: 2 000, не 4 000)'
);
select is(
  (select status from public.subscriptions where id = (select id from t_ins where name = 'sub1')), 'cancelled',
  'Абонемент отменён'
);
select is(
  (select amount_tiyin from public.payments where subscription_id = (select id from t_ins where name = 'sub1') and kind = 'refund'),
  -200000, 'Платёж-возврат — ровно на внесённые 2 000, не на 4 000 (иначе subscriptions_paid_not_negative)'
);
select is(
  (select comment from public.payments where subscription_id = (select id from t_ins where name = 'sub1') and kind = 'refund'),
  'Возврат при отмене абонемента', 'Комментарий проставлен'
);
select is(
  (select (payload->>'amount_tiyin')::int from public.events
    where type = 'subscription.refunded' and (payload->>'subscription_id')::uuid = (select id from t_ins where name = 'sub1')),
  400000, 'Событие subscription.refunded: amount_tiyin — по-прежнему полная стоимость неотработанных занятий (refund_calc)'
);
select is(
  (select (payload->>'refund_tiyin')::int from public.events
    where type = 'subscription.refunded' and (payload->>'subscription_id')::uuid = (select id from t_ins where name = 'sub1')),
  200000, '…а refund_tiyin — реально возвращённые деньги (капнутые внесённым)'
);
select ok(
  exists (select 1 from public.events
           where type = 'payment.refunded' and (payload->>'amount_tiyin')::int = -200000
             and (payload->>'subscription_id')::uuid = (select id from t_ins where name = 'sub1')),
  'record_payment внутри refund_subscription эмитит своё payment.refunded — тот же путь, что у любых денег'
);
reset role;


-- 11-14. Источник обязателен, только если возврат денег > 0 (Р2), атомарность --------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

create temporary table t_sale2 as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000002',
    '55550000-0000-0000-0000-000000000031', null, null, 200000, (select id from t_src));
insert into t_ins select 'sub2', subscription_id from t_sale2 limit 1;

select throws_ok(
  $q$ select public.refund_subscription((select id from t_ins where name = 'sub2'), 400000) $q$,
  '22023', 'Укажите источник оплаты',
  'Возврат 2 000 без источника — отказ (деньги реально возвращаются)'
);
reset role;

select is(
  (select status from public.subscriptions where id = (select id from t_ins where name = 'sub2')), 'active',
  'После отказа — абонемент остался активным (откат целиком)'
);
select is(
  (select count(*)::int from public.payments where subscription_id = (select id from t_ins where name = 'sub2')), 1,
  'Ни одной новой строки платежа — только исходная оплата продажи'
);


-- 15-19. Абонемент без единого платежа — возврат без источника (Р1, нулевой случай) --------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into t_ins values ('sub3', public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000003'));

select is(public.refund_calc((select id from t_ins where name = 'sub3')), 400000, 'refund_calc sub3 — полная цена');
select is(
  (select paid_tiyin from public.subscriptions where id = (select id from t_ins where name = 'sub3')), 0,
  'sub3 не оплачен вовсе'
);
select is(
  public.refund_subscription((select id from t_ins where name = 'sub3'), 400000), 400000,
  'Возврат по неоплаченному абонементу проходит без источника — реальных денег 0'
);
select is(
  (select count(*)::int from public.payments where subscription_id = (select id from t_ins where name = 'sub3')), 0,
  'Ни одной платёжной строки — возвращать нечего'
);
select is(
  (select status from public.subscriptions where id = (select id from t_ins where name = 'sub3')), 'cancelled',
  'Абонемент всё равно отменён'
);


-- 20. Повторный возврат — явный отказ до расчёта (Р4) ---------------------------------------

select throws_ok(
  $q$ select public.refund_subscription((select id from t_ins where name = 'sub3'), 0) $q$,
  '22023', 'Абонемент уже отменён',
  'Повторный возврат — отказ раньше пересчёта (lessons_written_off не списывается второй раз)'
);
reset role;


-- 21. Повторная строка возврата в обход RPC — частичный unique (Р3) -----------------------

select throws_like(
  format($q$ insert into public.payments (center_id, payer_id, student_id, subscription_id, amount_tiyin, kind)
      values ('cccccccc-0000-0000-0000-00000000000a', 'dddddddd-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000001', %L, -1, 'refund') $q$,
    (select id from t_ins where name = 'sub1')),
  '%payments_refund_once_key%',
  'Вторая строка kind=refund на тот же абонемент невозможна даже в обход RPC'
);


-- 22-27. Переплата — инвариант для kind=payment, не для correction (Р6, Р16) --------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into t_ins values ('sub4', public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000004'));

select lives_ok(
  $q$ insert into t_ins select 'pay4_price', public.record_payment('dddddddd-0000-0000-0000-000000000001', 400000, 'payment',
        'eeeeeeee-0000-0000-0000-000000000004', (select id from t_ins where name = 'sub4'), (select id from t_src)) $q$,
  'Оплата ровно в размер цены — не переплата, граница включительно'
);
select throws_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 1, 'payment',
        'eeeeeeee-0000-0000-0000-000000000004', (select id from t_ins where name = 'sub4'), (select id from t_src)) $q$,
  '22023', 'Оплата больше остатка по абонементу — переплату проводите корректировкой',
  'Один тыйын сверх цены через kind=payment — отказ триггера'
);
select lives_ok(
  $q$ insert into t_ins select 'pay4_corr', public.record_payment('dddddddd-0000-0000-0000-000000000001', 100000, 'correction',
        'eeeeeeee-0000-0000-0000-000000000004', (select id from t_ins where name = 'sub4'), (select id from t_src)) $q$,
  'Корректировка сверх цены — проходит: единственный санкционированный путь переплаты (stages.md). Сумма не «тот же тыйын» специально — ниже нужен запас, чтобы уменьшение всё равно осталось выше цены'
);
select is(
  (select paid_tiyin from public.subscriptions where id = (select id from t_ins where name = 'sub4')), 500000,
  'paid_tiyin отражает переплату — correction её не прячет, просто не блокирует'
);
select lives_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 5000000, 'payment') $q$,
  'Платёж без subscription_id — переплаты по абонементу нет, guard не применяется'
);
select ok(
  (select payment_state from public.subscription_payment_summary((select id from t_ins where name = 'sub4'))) = 'overpaid',
  'summary sub4: overpaid, как и раньше — sum(amount_tiyin) не изменился по смыслу'
);


-- 28. Guard реагирует на рост, не на состояние (Р16) — правка, доступная authenticated ----
-- sub4 уже переплачен (500 000 при цене 400 000) через correction —
-- санкционированно и намеренно. Правка комментария (единственная колонка
-- payments, грантованная authenticated на update, 0013) не должна
-- спотыкаться об это состояние второй раз.

select lives_ok(
  format($q$ update public.payments set comment = 'Уточнение' where id = %L $q$,
    (select id from t_ins where name = 'pay4_price')),
  'Правка комментария у kind=payment строки уже переплаченного абонемента — не новая переплата (Р16: до фикса эта же правка отказывала ни за что)'
);
reset role;


-- 29-30. Уменьшение суммы переплаченной строки — прямой обход (грант update на
-- amount_tiyin у authenticated нет, 0013) — не блокируется тем не менее (Р16) ------------

select lives_ok(
  format($q$ update public.payments set amount_tiyin = amount_tiyin - 50000 where id = %L $q$,
    (select id from t_ins where name = 'pay4_price')),
  'Уменьшение суммы переплаченной строки не блокируется, даже если итог всё ещё выше цены (Р16)'
);
select is(
  (select paid_tiyin from public.subscriptions where id = (select id from t_ins where name = 'sub4')), 450000,
  'paid_tiyin отразил уменьшение (500 000 − 50 000), 450 000 всё ещё выше цены 400 000 — и это ожидаемо: уменьшение не проверяется вовсе'
);


-- 31-34. Многострочный insert и рост суммы на UPDATE — гарантия переживает прямой обход
-- (Р13-Р14, Р16). Вне set local role authenticated (как и обход unique-индекса выше,
-- п.21): держит service_role/суперпользователя, а не только штатный RPC.

insert into t_ins values ('sub6', public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001'));

select throws_ok(
  format($q$ insert into public.payments (center_id, payer_id, student_id, subscription_id, amount_tiyin, kind)
      values ('cccccccc-0000-0000-0000-00000000000a', 'dddddddd-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000001', %L, 200000, 'payment'),
             ('cccccccc-0000-0000-0000-00000000000a', 'dddddddd-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000001', %L, 200001, 'payment') $q$,
    (select id from t_ins where name = 'sub6'), (select id from t_ins where name = 'sub6')),
  '22023', 'Оплата больше остатка по абонементу — переплату проводите корректировкой',
  'Многострочный insert одной командой: обе строки уже физически вставлены к моменту первого же AFTER-события, payments_recalc_paid считает готовую полную сумму — guard видит итог, а не «до» (Р13)'
);
select is(
  (select count(*)::int from public.payments where subscription_id = (select id from t_ins where name = 'sub6')), 0,
  'Отказ многострочного insert атомарен — ни одна из двух строк не осталась'
);

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ insert into t_ins select 'pay6', public.record_payment('dddddddd-0000-0000-0000-000000000001', 400000, 'payment',
        'eeeeeeee-0000-0000-0000-000000000001', (select id from t_ins where name = 'sub6'), (select id from t_src)) $q$,
  'sub6 оплачен ровно в цену — исходное состояние для проверки роста суммы на UPDATE'
);
reset role;

select throws_ok(
  format($q$ update public.payments set amount_tiyin = amount_tiyin + 1 where id = %L $q$,
    (select id from t_ins where name = 'pay6')),
  '22023', 'Оплата больше остатка по абонементу — переплату проводите корректировкой',
  'Рост суммы уже существующей kind=payment строки выше цены ловится и на UPDATE — ранний выход Р16 не открывает дыру для роста'
);
select throws_ok(
  format($q$ update public.payments set kind = 'payment' where id = %L $q$,
    (select id from t_ins where name = 'pay4_corr')),
  '22023', 'Оплата больше остатка по абонементу — переплату проводите корректировкой',
  'update kind на уже переплаченной correction-строке ловится: guard видит смену kind даже без изменения суммы (Р14, Р16)'
);


-- 35. Переплата — чужой центр не различим по сумме (Р10) ----------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select throws_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-00000000000b', 999999999, 'payment',
        'eeeeeeee-0000-0000-0000-00000000000b', (select id from t_ins where name = 'sub4')) $q$,
  '23503', null,
  'Владелец центра Б платит по чужому (центр А) subscription_id: отказ FK, не 22023 «больше остатка» — иначе подбором суммы читается остаток чужого центра'
);
reset role;


-- 36-40. Роли: возврат — стойка (can_front_desk), не бухгалтерия --------------------------

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
insert into t_ins values ('sub5', public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000005'));
select lives_ok(
  $q$ select public.refund_subscription((select id from t_ins where name = 'sub5'), 400000) $q$,
  'registrar — возврат (can_front_desk)'
);
reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.refund_subscription((select id from t_ins where name = 'sub4'), 0) $q$,
  '42501', null, 'finance не оформляет возврат (Р7 из 0026)'
);
reset role;

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.refund_subscription((select id from t_ins where name = 'sub4'), 0) $q$,
  '42501', null, 'teacher не оформляет возврат'
);
reset role;

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.refund_subscription((select id from t_ins where name = 'sub4'), 0) $q$,
  '42501', null, 'parent не оформляет возврат'
);
reset role;

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select throws_ok(
  $q$ select public.refund_subscription((select id from t_ins where name = 'sub4'), 0) $q$,
  '42704', null, 'Владелец центра Б по абонементу центра А — не найден'
);
reset role;


-- 41-46. Гранты и последнее определение ---------------------------------------------------

select ok(
  has_function_privilege('authenticated', 'public.refund_subscription(uuid,integer,uuid)', 'EXECUTE'),
  'refund_subscription(uuid,integer,uuid) — исполняется authenticated (грант явный, не унаследован)'
);
select ok(
  not has_function_privilege('anon', 'public.refund_subscription(uuid,integer,uuid)', 'EXECUTE')
  and not has_function_privilege('public', 'public.refund_subscription(uuid,integer,uuid)', 'EXECUTE'),
  'anon и public — нет'
);
select ok(
  not exists (select 1 from pg_proc where proname = 'refund_subscription' and pronargs = 2),
  'Старая двухпараметровая сигнатура не существует отдельно — ровно одна перегрузка'
);
select ok(
  not has_function_privilege('authenticated', 'public.payments_no_overpay()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.payments_no_overpay()', 'EXECUTE'),
  'payments_no_overpay — только триггер, ни одной роли'
);
select is(
  (select count(*)::int from public.payments where kind = 'refund'), 1,
  'Ровно один возврат состоялся за весь файл (sub1) — sub3/sub5 без единого платежа денег не двигали'
);

select * from finish();

rollback;
