-- pgTAP: возврат за period-абонемент, пропорционально оставшимся дням (0054).
--
-- Все даты выражены через public.center_today(center) минус/плюс дни, не
-- фиксированными календарными датами — фиксированная дата в фикстуре уже
-- стоила проекту трёх кругов CI на 0018 (see memory
-- e2e-fixture-timing-fixes-need-full-trace / see git log 0019). starts_at в
-- прошлом sell_subscription не запрещает (запрет «не раньше сегодня» — только
-- у create_installment_plan/installments, не у самой продажи).
--
-- Claims — явно перед каждым блоком: reset role их не сбрасывает
-- (pgtap-reset-role-keeps-claims).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select * from no_plan();

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a-0054@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-b-0054@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-a-0054@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-a-0054@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent-a-0054@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','registrar-a-0054@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-0000000000a3','Центр А 0054','centr-a-0054','{}'::jsonb),
  ('cccccccc-0000-0000-0000-0000000000b3','Центр Б 0054','centr-b-0054','{}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-0000000000a3','cccccccc-0000-0000-0000-0000000000a3','Специалист А');

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-0000000000a3','cccccccc-0000-0000-0000-0000000000a3','Плательщик А','+996700000054');

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-0000000000a3','Ребёнок 1','dddddddd-0000-0000-0000-0000000000a3'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-0000000000a3','Ребёнок 2','dddddddd-0000-0000-0000-0000000000a3'),
  ('eeeeeeee-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-0000000000a3','Ребёнок 3','dddddddd-0000-0000-0000-0000000000a3'),
  ('eeeeeeee-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-0000000000a3','Ребёнок 4','dddddddd-0000-0000-0000-0000000000a3'),
  ('eeeeeeee-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-0000000000a3','Ребёнок 5','dddddddd-0000-0000-0000-0000000000a3'),
  ('eeeeeeee-0000-0000-0000-000000000006','cccccccc-0000-0000-0000-0000000000a3','Ребёнок 6','dddddddd-0000-0000-0000-0000000000a3'),
  ('eeeeeeee-0000-0000-0000-000000000007','cccccccc-0000-0000-0000-0000000000a3','Ребёнок 7','dddddddd-0000-0000-0000-0000000000a3'),
  ('eeeeeeee-0000-0000-0000-000000000008','cccccccc-0000-0000-0000-0000000000a3','Ребёнок 8','dddddddd-0000-0000-0000-0000000000a3');

-- period=10 (общий рабочий кейс), period=20 (заморозка), period=5 (истёк
-- ровно сегодня), period=365 (переполнение int4), unlimited+период=15 (Р4:
-- дискриминатор — ends_at, не буквальный kind), unlimited без периода
-- (регрессия — 0), lessons (регрессия — старая формула).
insert into public.subscription_types (id, center_id, name, kind, period_days, price_tiyin) values
  ('77777777-0000-0000-0000-000000000010','cccccccc-0000-0000-0000-0000000000a3','Месяц (10 дн)','period',10,100000),
  ('77777777-0000-0000-0000-000000000020','cccccccc-0000-0000-0000-0000000000a3','Месяц (20 дн)','period',20,200000),
  ('77777777-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-0000000000a3','Неделя (5 дн)','period',5,50000),
  ('77777777-0000-0000-0000-000000000365','cccccccc-0000-0000-0000-0000000000a3','Год (365 дн)','period',365,6000000),
  ('77777777-0000-0000-0000-000000000015','cccccccc-0000-0000-0000-0000000000a3','Безлимит на 15 дн','unlimited',15,150000);
insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-00000000000c','cccccccc-0000-0000-0000-0000000000a3','8 занятий','lessons',8,400000);
insert into public.subscription_types (id, center_id, name, kind, price_tiyin) values
  ('77777777-0000-0000-0000-00000000000e','cccccccc-0000-0000-0000-0000000000a3','Безлимит без срока','unlimited',300000);

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-0000000000a3','owner', null, null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-0000000000b3','owner', null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-0000000000a3','finance', null, null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-0000000000a3','teacher', 'aaaaaaaa-0000-0000-0000-0000000000a3', null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-0000000000a3','parent', null, 'dddddddd-0000-0000-0000-0000000000a3'),
  ('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-0000000000a3','registrar', null, null);

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
   where center_id = 'cccccccc-0000-0000-0000-0000000000a3' order by sort, code limit 1;
grant select on t_src to authenticated;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-0000000000a3');
set local role authenticated;


-- 1-3. Базовый кейс: 6 из 10 дней прошло, 4 осталось --------------------------------------

insert into t_ins values ('p10',
  public.sell_subscription('77777777-0000-0000-0000-000000000010', 'eeeeeeee-0000-0000-0000-000000000001',
    null, (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 6)));

select is(
  public.refund_calc((select id from t_ins where name = 'p10')), 40000,
  'period, 4 из 10 дней осталось: 100 000 * 4/10 = 40 000'
);
select is(
  public.refund_subscription((select id from t_ins where name = 'p10'), 40000), 40000,
  'refund_subscription на неоплаченном period — считает и отменяет без источника'
);
select is(
  (select status from public.subscriptions where id = (select id from t_ins where name = 'p10')), 'cancelled',
  'period-абонемент можно закрыть даже без единого платежа — раньше кнопки не было вовсе'
);


-- 4. После отмены возврат не течёт дальше (Р5) --------------------------------------------

select is(
  public.refund_calc((select id from t_ins where name = 'p10')), 0,
  'refund_calc отменённого period — 0, не продолжает уменьшаться по дням (Р5)'
);


-- 5-6. Возврат капается внесённым, не расчётной стоимостью срока (0030, Р1, без изменений) --

insert into t_ins values ('p10b',
  public.sell_subscription('77777777-0000-0000-0000-000000000010', 'eeeeeeee-0000-0000-0000-000000000002',
    null, (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 5)));
insert into t_ins select 'p10b_pay', public.record_payment('dddddddd-0000-0000-0000-0000000000a3', 30000, 'payment',
  'eeeeeeee-0000-0000-0000-000000000002', (select id from t_ins where name = 'p10b'), (select id from t_src));

select is(
  public.refund_calc((select id from t_ins where name = 'p10b')), 50000,
  'refund_calc: 5 из 10 дней осталось — 100 000 * 5/10 = 50 000 (стоимость срока, не деньги)'
);
select is(
  public.refund_subscription((select id from t_ins where name = 'p10b'), 50000, (select id from t_src)), 50000,
  'refund_subscription возвращает refund_calc целиком (контракт не менялся)'
);
select is(
  (select amount_tiyin from public.payments where subscription_id = (select id from t_ins where name = 'p10b') and kind = 'refund'),
  -30000, 'Деньгами вернулось ровно внесённое (30 000), не расчётная стоимость срока (50 000)'
);


-- 7-8. Истёк ровно сегодня — возврат 0, отмена всё равно проходит -------------------------

insert into t_ins values ('p5',
  public.sell_subscription('77777777-0000-0000-0000-000000000005', 'eeeeeeee-0000-0000-0000-000000000003',
    null, (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 5)));

select is(
  public.refund_calc((select id from t_ins where name = 'p5')), 0,
  'period истёк ровно сегодня (ends_at = today): остаток 0, не отрицательное число'
);
select lives_ok(
  $q$ select public.refund_subscription((select id from t_ins where name = 'p5'), 0) $q$,
  'Отмена истёкшего абонемента без возврата — не падает и не требует источника'
);


-- 9. Будущий старт — капается полной ценой, не «больше 100%» (least по total_days) ---------

insert into t_ins values ('p10f',
  public.sell_subscription('77777777-0000-0000-0000-000000000010', 'eeeeeeee-0000-0000-0000-000000000004',
    null, (public.center_today('cccccccc-0000-0000-0000-0000000000a3') + 3)));

select is(
  public.refund_calc((select id from t_ins where name = 'p10f')), 100000,
  'Абонемент ещё не начался (starts_at в будущем) — возврат капается полной ценой, не суммой сверх нее'
);


-- 10-11. Закрытая заморозка: знаменатель — period_days типа, не ends_at-starts_at (Р3, ключевой кейс) --

insert into t_ins values ('p20',
  public.sell_subscription('77777777-0000-0000-0000-000000000020', 'eeeeeeee-0000-0000-0000-000000000005',
    null, (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 15)));

-- Заморозка на 8 дней, полностью в прошлом (со 2 по 10 день после старта) —
-- ends_at сдвигается на +8 триггером subscriptions_apply_freeze_shift (0015).
select public.freeze_subscription(
  (select id from t_ins where name = 'p20'),
  (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 13),
  (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 5)
);

select is(
  (select ends_at from public.subscriptions where id = (select id from t_ins where name = 'p20')),
  (public.center_today('cccccccc-0000-0000-0000-0000000000a3') + 13),
  'ends_at сдвинут заморозкой: starts_at(-15) + period_days(20) + freeze(8) = today + 13'
);
select is(
  public.refund_calc((select id from t_ins where name = 'p20')), 130000,
  'Знаменатель — period_days типа (20), не ends_at-starts_at (28): 200 000 * 13/20 = 130 000, не 200 000*13/28=92 857'
);


-- 12-13. Открытая заморозка: её дни считаются, ends_at ещё не сдвинут (Р1, ключевой кейс) ---

insert into t_ins values ('p10z',
  public.sell_subscription('77777777-0000-0000-0000-000000000010', 'eeeeeeee-0000-0000-0000-000000000006',
    null, (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 3)));

-- Открытая заморозка началась вчера (p_to не передан).
select public.freeze_subscription(
  (select id from t_ins where name = 'p10z'),
  (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 1)
);

select is(
  (select ends_at from public.subscriptions where id = (select id from t_ins where name = 'p10z')),
  (public.center_today('cccccccc-0000-0000-0000-0000000000a3') + 7),
  'Открытая заморозка НЕ сдвигает ends_at (subscription_freeze_days_unchecked считает только закрытые периоды)'
);
select is(
  public.refund_calc((select id from t_ins where name = 'p10z')), 80000,
  'Без учёта открытой заморозки было бы 100 000*7/10=70 000; с 1 днём открытой заморозки — 100 000*8/10=80 000 (Р1)'
);


-- 14-15. Переполнение int4: 6 000 000 * 365 > 2^31 — не должно падать (Р6) -----------------

insert into t_ins values ('p365',
  public.sell_subscription('77777777-0000-0000-0000-000000000365', 'eeeeeeee-0000-0000-0000-000000000007',
    null, public.center_today('cccccccc-0000-0000-0000-0000000000a3')));

select lives_ok(
  $q$ select public.refund_calc((select id from t_ins where name = 'p365')) $q$,
  '6 000 000 * 365 = 2 190 000 000 > int4 max — bigint-умножение не падает (Р6)'
);
select is(
  public.refund_calc((select id from t_ins where name = 'p365')), 6000000,
  'Отмена в первый день срока — вся цена целиком, без потери точности'
);


-- 16. Unlimited С периодом — тот же пропорциональный возврат, что и period (Р4) ------------

insert into t_ins values ('u15',
  public.sell_subscription('77777777-0000-0000-0000-000000000015', 'eeeeeeee-0000-0000-0000-000000000008',
    null, (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 5)));

select is(
  public.refund_calc((select id from t_ins where name = 'u15')), 100000,
  'unlimited с period_days=15, 10 дней осталось: 150 000*10/15=100 000 — дискриминатор ends_at, не буквальный kind (Р4)'
);


-- 17. Unlimited БЕЗ периода — регрессия, всё ещё 0 -----------------------------------------

insert into t_ins values ('u_plain', public.sell_subscription('77777777-0000-0000-0000-00000000000e', 'eeeeeeee-0000-0000-0000-000000000001'));

select is(
  public.refund_calc((select id from t_ins where name = 'u_plain')), 0,
  'unlimited без ends_at — регрессия не тронута, возврат по-прежнему 0'
);


-- 18. Lessons — регрессия, формула не поменялась -------------------------------------------

insert into t_ins values ('l8', public.sell_subscription('77777777-0000-0000-0000-00000000000c', 'eeeeeeee-0000-0000-0000-000000000002'));

select is(
  public.refund_calc((select id from t_ins where name = 'l8')), 400000,
  'lessons: ничего не отработано — стоимость неотработанных занятий, формула не изменилась'
);


-- 19. Рассрочка на период-абонементе гасится тем же триггером, что у lessons (Р8, регрессия) --

create temporary table t_sale_inst as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-000000000020', 'eeeeeeee-0000-0000-0000-000000000003',
    '55550000-0000-0000-0000-000000000541', null,
    (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 1),
    null, null, null, 2, (public.center_today('cccccccc-0000-0000-0000-0000000000a3')));
insert into t_ins select 'p20_inst', subscription_id from t_sale_inst limit 1;

select ok(
  (select count(*)::int from public.installment_plans where subscription_id = (select id from t_ins where name = 'p20_inst') and cancelled_at is null) = 1,
  'План рассрочки на period-абонементе живой сразу после продажи'
);
select public.refund_subscription((select id from t_ins where name = 'p20_inst'), 190000);
select ok(
  (select count(*)::int from public.installment_plans where subscription_id = (select id from t_ins where name = 'p20_inst') and cancelled_at is null) = 0,
  'Отмена period-абонемента гасит его план рассрочки — тем же AFTER-триггером subscriptions_cancel_installments (0018/0020), без правки в этой миграции (Р8)'
);

reset role;


-- 20-23. Видимость: refund_calc (definer+gate) под parent/registrar совпадает с
-- subscription_summary под owner — единый механизм видимости вместо RLS-join (Р2) --------

insert into t_ins values ('p10v',
  public.sell_subscription('77777777-0000-0000-0000-000000000010', 'eeeeeeee-0000-0000-0000-000000000004',
    null, (public.center_today('cccccccc-0000-0000-0000-0000000000a3') - 6)));

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-0000000000a3');
set local role authenticated;
create temporary table t_ref_owner as
  select refund_tiyin from public.subscription_summary((select id from t_ins where name = 'p10v'));
reset role;

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-0000000000a3');
set local role authenticated;
select is(
  public.refund_calc((select id from t_ins where name = 'p10v')), (select refund_tiyin from t_ref_owner),
  'refund_calc под parent (своего ребёнка) — то же число, что subscription_summary под owner (Р2: один механизм видимости на оба пути)'
);
reset role;

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-0000000000a3');
set local role authenticated;
select is(
  public.refund_calc((select id from t_ins where name = 'p10v')), (select refund_tiyin from t_ref_owner),
  'refund_calc под registrar — то же число (can_payments включает registrar)'
);
reset role;

-- Специалист не видит абонементов вовсе (ADR-005) — refund_calc тоже NULL, не 0.
select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-0000000000a3');
set local role authenticated;
select is(
  public.refund_calc((select id from t_ins where name = 'p10v')), null::integer,
  'refund_calc под teacher — NULL (специалист не видит абонементов и денег, ADR-005)'
);
reset role;

-- Чужой центр — NULL, не 0 и не «подобранная» цифра (регрессия 0010_stage4_hardening.test.sql:104).
select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-0000000000b3');
set local role authenticated;
select is(
  public.refund_calc((select id from t_ins where name = 'p10v')), null::integer,
  'refund_calc чужого центра — NULL (definer+subscription_visible_to_caller не открывает больше, чем RLS раньше)'
);
reset role;


-- 24-25. Гранты: refund_calc остаётся authenticated-only, refund_calc_unchecked — никому ----

select ok(
  has_function_privilege('authenticated', 'public.refund_calc(uuid)', 'EXECUTE'),
  'refund_calc(uuid) — по-прежнему исполняется authenticated после перехода invoker -> definer'
);
select ok(
  not has_function_privilege('authenticated', 'public.refund_calc_unchecked(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.refund_calc_unchecked(uuid)', 'EXECUTE')
  and not has_function_privilege('public', 'public.refund_calc_unchecked(uuid)', 'EXECUTE'),
  'refund_calc_unchecked — внутренний хелпер, ни одной роли (та же схема, что subscription_freeze_days_unchecked, 0015)'
);

select * from finish();

rollback;
