-- pgTAP: продажа абонемента с оплатой и рассрочкой одной транзакцией (0023).
-- Атомарность проверяется счётчиками (tests_snapshot) до и после каждого
-- отказа, а не select по id: id откатившейся строки неизвестен.
-- Второй центр — America/New_York: полночь дня оплаты считается по поясу
-- центра, а не раннера. M1 = позапрошлый месяц — единственный закрываемый.
-- Claims владельца А — до первой сырой вставки (emit_event требует auth.uid()).

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
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-ny@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-sale','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр NY','centr-ny-sale','{"timezone":"America/New_York"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист');

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик А','+996700000001'),
  ('dddddddd-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Плательщик NY','+996700000002');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner', null, null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner', null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001', null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000001');

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок А','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Ребёнок NY','dddddddd-0000-0000-0000-00000000000b');

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','8 занятий','lessons',8,400000),
  ('77777777-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','2 занятия','lessons',2,100000);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

-- Счётчики четырёх таблиц одной строкой — сравнивать до/после отказа.
create or replace function public.tests_snapshot()
  returns text language sql as $$
  select (select count(*) from public.subscriptions) || '/' ||
         (select count(*) from public.payments) || '/' ||
         (select count(*) from public.installment_plans) || '/' ||
         (select count(*) from public.installments)
$$;

create temporary table t_snap (name text primary key, v text);
create temporary table t_ins (name text primary key, id uuid);
grant select, insert on t_ins to authenticated;

-- Источники — сеются триггером при вставке центра.
create temporary table t_src as
  select id from public.payment_sources
   where center_id = 'cccccccc-0000-0000-0000-00000000000a' order by sort, code limit 1;
create temporary table t_src_ny as
  select id from public.payment_sources
   where center_id = 'cccccccc-0000-0000-0000-00000000000b' order by sort, code limit 1;
grant select on t_src, t_src_ny to authenticated;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');


-- 1-9. Чек-лист п.1: продать 4 000, оплата 2 000 + рассрочка 2×1 000 ------------

set local role authenticated;

create temporary table t_sale1 as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
    '55550000-0000-0000-0000-000000000001',
    null, null, 200000, (select id from t_src), null, 2, null, 1::smallint, 200000);

insert into t_ins select 'sub1', subscription_id from t_sale1 limit 1;
insert into t_ins select 'pay1', payment_id from t_sale1 limit 1;

select is((select count(*)::int from t_sale1), 2, 'В ответе две строки графика — интерфейс рисует по ответу сервера');
select is(
  (select array_agg(amount_tiyin order by seq) from t_sale1), array[100000, 100000],
  'Чек-лист: 2 installments по 1 000 сом'
);
select is(
  (select paid_tiyin from public.subscriptions where id = (select id from t_ins where name = 'sub1')),
  200000, 'paid_tiyin = 200000 сразу после продажи'
);
select is(
  (select base_paid_tiyin from public.installment_plans
    where subscription_id = (select id from t_ins where name = 'sub1')),
  200000, 'base_paid_tiyin плана = внесённому: аванс не закрывает первую строку'
);
select is(
  (select amount_tiyin from public.payments where id = (select id from t_ins where name = 'pay1')),
  200000, 'Платёж на 200000 с id из ответа'
);
select is(
  (select comment from public.payments where id = (select id from t_ins where name = 'pay1')),
  'Оплата при продаже абонемента', 'Комментарий платежа проставлен'
);
select is(
  (select sale_key from public.subscriptions where id = (select id from t_ins where name = 'sub1')),
  '55550000-0000-0000-0000-000000000001'::uuid, 'sale_key записан'
);
select ok(
  (select min(e.id) filter (where e.type = 'payment.received') < min(e.id) filter (where e.type = 'installment_plan.created')
     from public.events e),
  'payment.received раньше installment_plan.created — base_paid_tiyin зависит от порядка'
);
select is(
  (select count(*)::int from public.events where type in ('subscription.created', 'payment.received', 'installment_plan.created')),
  3, 'Три события — по одному от каждого вложенного RPC, обёртка своих не добавляет'
);


-- 10-12. Полная оплата без рассрочки -------------------------------------------------

create temporary table t_sale2 as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
    '55550000-0000-0000-0000-000000000002',
    null, null, 400000, (select id from t_src), null, null, null, 1::smallint, 0);
insert into t_ins select 'sub2', subscription_id from t_sale2 limit 1;

select is((select count(*)::int from t_sale2), 1, 'Без рассрочки — одна строка ответа');
select ok((select seq is null from t_sale2), '…с пустым графиком (seq null)');
select is(
  (select payment_state from public.subscription_payment_summary((select id from t_ins where name = 'sub2'))),
  'paid', 'Оплачен целиком — paid'
);


-- 13-15. Без аванса, вся цена в рассрочку ----------------------------------------------

create temporary table t_sale3 as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
    '55550000-0000-0000-0000-000000000003',
    null, null, null, null, null, 4, null, 1::smallint, 400000);

select is((select count(*)::int from t_sale3), 4, 'Четыре строки рассрочки');
select is((select sum(amount_tiyin)::int from t_sale3), 400000, 'Сумма графика = всей цене');
select ok((select bool_and(payment_id is null) from t_sale3), 'Платежа нет — payment_id null');

reset role;


-- 16-30. Отказы — и полный откат ---------------------------------------------------------

insert into t_snap values ('before', public.tests_snapshot());

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000010', null, null, 400001, (select id from t_src)) $q$,
  '22023', 'Оплата больше цены абонемента', 'Переплата при продаже — отказ'
);
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000011', null, null, 400000, (select id from t_src), null, 2) $q$,
  '22023', null, 'Оплачено целиком + рассрочка — «нечего рассрочивать», откат всей продажи'
);
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000012', null, null, 399999, (select id from t_src), null, 2) $q$,
  '22023', null, 'Остаток 1 тыйын на 2 платежа — отказ плана, откат продажи'
);
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000013', null, null, -1, (select id from t_src)) $q$,
  '22023', null, 'Отрицательная сумма — отказ'
);
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000014', null, null, 100000, null) $q$,
  '22023', 'Укажите источник оплаты', 'Оплата без источника — отказ (иначе выпадает из сверки кассы)'
);
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000015', null, null, 100000, (select id from t_src),
        public.center_today('cccccccc-0000-0000-0000-00000000000a') + 1) $q$,
  '22023', 'Дата оплаты не может быть в будущем', 'Дата в будущем — отказ (опечатка в годе не проходит)'
);
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000016', null, null, null, null, null, 0) $q$,
  '22023', null, 'p_installments = 0 — отказ, «без рассрочки» только null'
);
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000001', null, null, 200000, (select id from t_src), null, 2) $q$,
  '22023', 'Эта продажа уже проведена — обновите страницу', 'Повтор с тем же sale_key (двойной клик) — отказ'
);
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000017', null, null, 200000, (select id from t_src), null, 2, null, 1::smallint, 150000) $q$,
  '23514', null, 'Ожидаемый остаток разошёлся с серверным — 23514, откат'
);

select lives_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  'close_month(M1) проходит — в M1 нет занятий'
);
select throws_like(
  format($q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000018', null, null, 200000, %L, %L) $q$,
    (select id from t_src), (date_trunc('month', now() - interval '2 months'))::date + 3),
  '%закрыт%', 'Дата оплаты в закрытом месяце — замок на payments откатывает всю продажу'
);

reset role;

select is(public.tests_snapshot(), (select v from t_snap where name = 'before'),
  'После девяти отказов — ни абонемента, ни платежа, ни плана, ни строки графика');

-- Роли и чужой центр.
select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000020') $q$,
  '42501', null, 'Специалист не продаёт'
);
reset role;
select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000021') $q$,
  '42501', null, 'Родитель не продаёт'
);
reset role;
select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000022') $q$,
  '42704', null, 'Владелец NY по типу центра А — 42704 (от sell_subscription)'
);
reset role;
select is(public.tests_snapshot(), (select v from t_snap where name = 'before'),
  'Отказы по ролям — до создания чего-либо');


-- 31-32. Пояс центра, не раннера ---------------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;

create temporary table t_sale_ny as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-00000000000b', 'eeeeeeee-0000-0000-0000-00000000000b',
    '55550000-0000-0000-0000-000000000030',
    null, null, 100000, (select id from t_src_ny));

select is(
  (select (p.paid_at at time zone 'America/New_York')::date from public.payments p
    where p.subscription_id = (select subscription_id from t_sale_ny limit 1)),
  public.center_today('cccccccc-0000-0000-0000-00000000000b'),
  'p_paid_on null → день оплаты = сегодня по поясу центра (Нью-Йорк), не раннера'
);
select is(
  (select p.paid_at from public.payments p
    where p.subscription_id = (select subscription_id from t_sale_ny limit 1)),
  (public.center_today('cccccccc-0000-0000-0000-00000000000b')::timestamp) at time zone 'America/New_York',
  'Момент платежа — полночь дня оплаты по поясу центра, как у record_expense'
);

reset role;


-- 33-37. Ключ продажи: NULL-дыра, чужой центр, запись в обход, 25 платежей ----------------

insert into t_snap values ('keys', public.tests_snapshot());

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- Частичный unique не видит NULL: без этой проверки две продажи с пустым
-- ключом прошли бы обе.
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        null, null, null, 200000, (select id from t_src)) $q$,
  '22004', null, 'Пустой ключ продажи — отказ, а не «уникальный» NULL'
);
-- Ключ уже занят абонементом центра NY: тот же 22023, факт существования
-- чужой строки текстом не выдаётся.
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000030', null, null, 200000, (select id from t_src)) $q$,
  '22023', 'Эта продажа уже проведена — обновите страницу', 'Ключ чужого центра — тот же отказ, без утечки'
);
select throws_ok(
  $q$ update public.subscriptions set sale_key = '55550000-0000-0000-0000-000000000099'
       where id = (select id from t_ins where name = 'sub2') $q$,
  '42501', null, 'sale_key не в grant update — владелец не перепишет ключ прямым запросом'
);
select throws_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000031', null, null, null, null, null, 25) $q$,
  '22023', null, '25 платежей — отказ вложенного плана, продажа откатывается'
);

reset role;

select is(public.tests_snapshot(), (select v from t_snap where name = 'keys'),
  'После четырёх отказов по ключу и графику — счётчики на месте');


-- 38-39. Известные ограничения — закреплены, чтобы не изменились молча -------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select public.archive_student('eeeeeeee-0000-0000-0000-000000000001');

select lives_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000040', null, null, 100000, (select id from t_src)) $q$,
  'Архивному ученику (status = archived) продажа проходит — sell_subscription смотрит только deleted_at (известное ограничение)'
);
select lives_ok(
  $q$ select * from public.sell_subscription_paid('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '55550000-0000-0000-0000-000000000041', 350000, null, 350000, (select id from t_src), null, null, null, 1::smallint, 0) $q$,
  'Цена переопределена (скидка 3 500) и внесена целиком — ожидаемый остаток 0 сходится'
);

reset role;


-- 35-38. Гранты и хранимый инвариант ключа -------------------------------------------------

select ok(
  has_function_privilege('authenticated', 'public.sell_subscription_paid(uuid,uuid,uuid,integer,date,integer,uuid,date,integer,date,smallint,integer)', 'EXECUTE'),
  'sell_subscription_paid исполняется authenticated'
);
select ok(
  not has_function_privilege('anon', 'public.sell_subscription_paid(uuid,uuid,uuid,integer,date,integer,uuid,date,integer,date,smallint,integer)', 'EXECUTE'),
  'anon — нет'
);
select ok(
  not has_function_privilege('public', 'public.sell_subscription_paid(uuid,uuid,uuid,integer,date,integer,uuid,date,integer,date,smallint,integer)', 'EXECUTE'),
  'public — нет'
);
select throws_like(
  $q$ update public.subscriptions set sale_key = '55550000-0000-0000-0000-000000000001'
       where id = (select id from t_ins where name = 'sub2') $q$,
  '%subscriptions_sale_key_key%',
  'Два абонемента с одним sale_key невозможны и в обход RPC — частичный unique'
);


-- 39-41. Контрольные суммы ----------------------------------------------------------------

select is(
  (select count(*)::int from public.subscriptions where sale_key is not null), 6,
  'Продаж с ключом за файл — шесть (sub1, sub2, sub3, NY, две у архивного)'
);
select is(
  (select count(*)::int from public.payments), 5,
  'Платежей — пять: 200000, 400000, NY 100000, архивному 100000, скидка 350000'
);
select is(
  (select count(*)::int from public.installment_plans), 2,
  'Планов — два: чек-лист и «вся цена в рассрочку»'
);

select * from finish();

rollback;
