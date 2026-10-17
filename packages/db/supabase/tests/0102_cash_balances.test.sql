-- pgTAP: остатки касс и сверка кассы (0102).
--
-- Р1/Р2 формула: без сверки — все движения; сверка — якорь; движение того же
-- дня, внесённое после сверки, входит; внесённое позже задним числом — нет.
-- Р3 расхождение при чтении (запись задним числом меняет его, а не остаток).
-- Р4 первая сверка — начальный остаток. Р5 отмена. Ключ, гонка суммы, порядок
-- сверок, права, readonly, закрытый месяц, неизменяемость, тождество отчёта и
-- сверка оборотов с cash_by_source.
--
-- В одной транзакции now() постоянен: движение «после сверки» вставляется от
-- postgres с явным created_at. reset role не сбрасывает claims — tests_claims явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(36);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('01020000-0000-0000-0000-0000000000a' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0102@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 7) n;

insert into public.centers (id, name, slug, settings) values
  ('01020000-0000-0000-0000-0000000000c1', 'Центр 0102 А', 'centr-0102-a', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('01020000-0000-0000-0000-0000000000c2', 'Центр 0102 Б', 'centr-0102-b', '{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('01020000-0000-0000-0000-0000000000c3', 'Центр 0102 В', 'centr-0102-c', 'solo', now() - interval '2 days',
   '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('01020000-0000-0000-0000-0000000000b1', '01020000-0000-0000-0000-0000000000c1', 'Специалист 0102');

insert into public.payers (id, center_id, full_name, phone) values
  ('01020000-0000-0000-0000-0000000000d1', '01020000-0000-0000-0000-0000000000c1', 'П1', '+996700030001');

-- 1 owner А · 2 finance А · 3 registrar А · 4 teacher А · 5 admin А · 6 owner Б · 7 owner В.
insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('01020000-0000-0000-0000-0000000000a1', '01020000-0000-0000-0000-0000000000c1', 'owner', null),
  ('01020000-0000-0000-0000-0000000000a2', '01020000-0000-0000-0000-0000000000c1', 'finance', null),
  ('01020000-0000-0000-0000-0000000000a3', '01020000-0000-0000-0000-0000000000c1', 'registrar', null),
  ('01020000-0000-0000-0000-0000000000a4', '01020000-0000-0000-0000-0000000000c1', 'teacher', '01020000-0000-0000-0000-0000000000b1'),
  ('01020000-0000-0000-0000-0000000000a5', '01020000-0000-0000-0000-0000000000c1', 'admin', null),
  ('01020000-0000-0000-0000-0000000000a6', '01020000-0000-0000-0000-0000000000c2', 'owner', null),
  ('01020000-0000-0000-0000-0000000000a7', '01020000-0000-0000-0000-0000000000c3', 'owner', null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('01020000-0000-0000-0000-000000000e01', '01020000-0000-0000-0000-0000000000c1', 'K1', '01020000-0000-0000-0000-0000000000d1');

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
  select (select id from public.payment_sources where center_id = '01020000-0000-0000-0000-0000000000c1' order by sort, code limit 1) as cash,
         (select id from public.payment_sources where center_id = '01020000-0000-0000-0000-0000000000c1' order by sort, code offset 1 limit 1) as bank,
         (select id from public.payment_sources where center_id = '01020000-0000-0000-0000-0000000000c2' order by sort, code limit 1) as b_cash,
         (select id from public.payment_sources where center_id = '01020000-0000-0000-0000-0000000000c3' order by sort, code limit 1) as c_cash,
         public.center_today('01020000-0000-0000-0000-0000000000c1') as today,
         (public.center_today('01020000-0000-0000-0000-0000000000c1')::timestamp at time zone 'Asia/Bishkek') as day_start;
grant select on t_src to authenticated;

create temporary table t_ids (name text primary key, id uuid);
grant select, insert on t_ids to authenticated;


-- 2. Формула и сверка ------------------------------------------------------------------------------

select public.tests_claims('01020000-0000-0000-0000-0000000000a2', '01020000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 1
select is(
  (select array[expected_tiyin::text, coalesce(last_count_on::text, '-')] from public.cash_count_preview((select cash from t_src))),
  array['0', '-'],
  'Касса без движений и сверок: по учёту 0, сверок не было');

select public.record_payment('01020000-0000-0000-0000-0000000000d1', 1000000, 'payment', '01020000-0000-0000-0000-000000000e01',
                             null, (select cash from t_src), null, 'наличными', (select today from t_src));

-- 2
select is(
  (select expected_tiyin from public.cash_count_preview((select cash from t_src))),
  1000000::bigint,
  'Без сверки остаток — все движения кассы');

-- 3
select is(
  (select array[difference_tiyin::text, is_opening::text]
     from public.record_cash_count((select cash from t_src), (select today from t_src), 900000, 1000000,
                                   '01020000-0000-0000-0000-00000000c001', 'вечер')),
  array['-100000', 'true'],
  'Первая сверка: недостача 1 000 и признак начального остатка');

-- 4
select throws_ok(
  $q$ select * from public.record_cash_count((select cash from t_src), (select today from t_src), 900000, 900000,
                                             '01020000-0000-0000-0000-00000000c001') $q$,
  '22023', 'Эта сверка уже сохранена — обновите страницу',
  'Повтор ключа — 22023 раньше сверки суммы');

-- 5
select throws_ok(
  $q$ select * from public.record_cash_count((select cash from t_src), (select today from t_src), 900000, 123,
                                             '01020000-0000-0000-0000-00000000c002') $q$,
  '23514', null,
  'Остаток по учёту не совпал с формой — 23514 со свежей суммой');

-- 6
select throws_ok(
  $q$ select * from public.record_cash_count((select cash from t_src), (select today from t_src) - 1, 0, 0,
                                             '01020000-0000-0000-0000-00000000c003') $q$,
  '22023', null,
  'Сверка раньше последней — отказ');

-- 7
select throws_ok(
  $q$ select * from public.record_cash_count((select cash from t_src), (select today from t_src) + 1, 0, 0,
                                             '01020000-0000-0000-0000-00000000c004') $q$,
  '22023', 'Дата сверки не может быть в будущем',
  'Сверка завтрашним днём — отказ');

-- 8
select throws_ok(
  $q$ select * from public.cash_count_preview((select b_cash from t_src)) $q$,
  '42704', 'Касса не найдена',
  'Предпросмотр чужой кассы — 42704, остаток чужого центра не раскрывается');

-- 9
select throws_ok(
  $q$ select * from public.record_cash_count((select b_cash from t_src), (select today from t_src), 0, 0,
                                             '01020000-0000-0000-0000-00000000c005') $q$,
  '42704', 'Касса не найдена',
  'Сверка чужой кассы — 42704');

reset role;

-- 10
select is(
  (select balance_tiyin from public.cash_balances_unchecked('01020000-0000-0000-0000-0000000000c1', (select today from t_src))
    where source_id = (select cash from t_src)),
  900000::bigint,
  'После сверки остаток — посчитанное');

-- Б1: платёж того же дня, внесённый после сверки, — входит в остаток.
insert into public.payments (center_id, payer_id, student_id, amount_tiyin, source_id, paid_at, kind, created_at)
values ('01020000-0000-0000-0000-0000000000c1', '01020000-0000-0000-0000-0000000000d1', '01020000-0000-0000-0000-000000000e01',
        50000, (select cash from t_src), (select day_start from t_src),
        'payment', (select counted_at from public.cash_counts where count_key = '01020000-0000-0000-0000-00000000c001') + interval '1 microsecond');

-- 11
select is(
  (select balance_tiyin from public.cash_balances_unchecked('01020000-0000-0000-0000-0000000000c1', (select today from t_src))
    where source_id = (select cash from t_src)),
  950000::bigint,
  'Движение того же дня после сверки входит в остаток (Б1)');

-- Внесено после сверки, но датой вчера — «до» неё: остаток не меняется, меняется расхождение.
insert into public.payments (center_id, payer_id, student_id, amount_tiyin, source_id, paid_at, kind, created_at)
values ('01020000-0000-0000-0000-0000000000c1', '01020000-0000-0000-0000-0000000000d1', '01020000-0000-0000-0000-000000000e01',
        30000, (select cash from t_src), (select day_start from t_src) - interval '30 minutes',
        'payment', (select counted_at from public.cash_counts where count_key = '01020000-0000-0000-0000-00000000c001') + interval '2 microseconds');

-- 12
select is(
  (select balance_tiyin from public.cash_balances_unchecked('01020000-0000-0000-0000-0000000000c1', (select today from t_src))
    where source_id = (select cash from t_src)),
  950000::bigint,
  'Запись задним числом до сверки остаток не меняет — посчитанное правда');

-- 13
select is(
  (select array[expected_tiyin, difference_tiyin] from public.cash_count_diffs_unchecked('01020000-0000-0000-0000-0000000000c1')
    where count_id = (select id from public.cash_counts where count_key = '01020000-0000-0000-0000-00000000c001')),
  array[1030000::bigint, -130000::bigint],
  'Расхождение — по текущим данным (Р3): поздняя запись вошла в «по учёту»');

-- 14
select is(
  pg_typeof((select balance_tiyin from public.cash_balances_unchecked('01020000-0000-0000-0000-0000000000c1', (select today from t_src)) limit 1))::text,
  'bigint',
  'Остаток — bigint (В7)');

select public.tests_claims('01020000-0000-0000-0000-0000000000a2', '01020000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 15
select is(
  (select array[difference_tiyin::text, is_opening::text]
     from public.record_cash_count((select cash from t_src), (select today from t_src), 940000, 950000,
                                   '01020000-0000-0000-0000-00000000c006')),
  array['-10000', 'false'],
  'Вторая сверка того же дня: недостача 100, не начальный остаток');

-- 16
select is(
  (select array_agg(array[expected_at_count::text, expected_tiyin::text, difference_tiyin::text, is_opening::text] order by counted_tiyin)
     from public.cash_counts_list((select today from t_src))),
  array[array['1000000', '1030000', '-130000', 'true'], array['950000', '950000', '-10000', 'false']],
  'Список сверок: что видел кассир и расхождение по текущим данным');

reset role;

-- 17
select is(
  (select balance_tiyin from public.cash_balances_unchecked('01020000-0000-0000-0000-0000000000c1', (select today from t_src))
    where source_id = (select cash from t_src)),
  940000::bigint,
  'Якорь — последняя сверка дня');

-- Платёж без кассы — для строки «без кассы» в отчёте.
select public.tests_claims('01020000-0000-0000-0000-0000000000a1', '01020000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.record_payment('01020000-0000-0000-0000-0000000000d1', -2000, 'correction', '01020000-0000-0000-0000-000000000e01',
                             null, null, null, 'корректировка', (select today from t_src));

reset role;

-- Перевод «после» первой сверки — от postgres с моментом сразу после неё (в транзакции
-- теста created_at из RPC = её начало, раньше сверки).
insert into public.cash_transfers (center_id, from_source_id, to_source_id, amount_tiyin, transferred_at, transfer_key, created_at)
values ('01020000-0000-0000-0000-0000000000c1', (select cash from t_src), (select bank from t_src), 40000,
        (select day_start from t_src), '01020000-0000-0000-0000-00000000c0aa',
        (select counted_at from public.cash_counts where count_key = '01020000-0000-0000-0000-00000000c001') + interval '3 microseconds');

select public.tests_claims('01020000-0000-0000-0000-0000000000a1', '01020000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 18
select throws_ok(
  $q$ select public.cancel_cash_count((select id from public.cash_counts where count_key = '01020000-0000-0000-0000-00000000c006'), '  ') $q$,
  '22023', 'Укажите причину отмены',
  'Отмена без причины — отказ');

-- 19
select lives_ok(
  $q$ select public.cancel_cash_count((select id from public.cash_counts where count_key = '01020000-0000-0000-0000-00000000c006'), 'не та сумма') $q$,
  'Владелец отменяет ошибочную сверку');

-- 20
select throws_ok(
  $q$ select public.cancel_cash_count((select id from public.cash_counts where count_key = '01020000-0000-0000-0000-00000000c006'), 'ещё') $q$,
  '22023', 'Сверка уже отменена',
  'Повторная отмена — отказ');

reset role;

-- 21
select is(
  (select balance_tiyin from public.cash_balances_unchecked('01020000-0000-0000-0000-0000000000c1', (select today from t_src))
    where source_id = (select cash from t_src)),
  910000::bigint,
  'Отменённая сверка не якорь: 9 000 + 500 после первой − перевод 400');

-- 22
select is(
  (select balance_tiyin from public.cash_balances_unchecked('01020000-0000-0000-0000-0000000000c1', (select today from t_src))
    where source_id = (select bank from t_src)),
  40000::bigint,
  'Перевод двигает вторую кассу');

select public.tests_claims('01020000-0000-0000-0000-0000000000a2', '01020000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 23
select ok(
  (select bool_and(closing_tiyin = opening_tiyin + turnover_tiyin + opening_adjustment_tiyin + counts_difference_tiyin)
     from public.cash_report((select today from t_src)) where source_id is not null),
  'Тождество отчёта: конец = начало + обороты + начальная поправка + расхождения');

-- 24
select is(
  (select array[opening_adjustment_tiyin, counts_difference_tiyin, closing_tiyin]
     from public.cash_report((select today from t_src)) where source_id = (select cash from t_src)),
  array[-130000::bigint, 0::bigint, 910000::bigint],
  'Первая сверка — поправка начального остатка, не расхождение; отменённая не считается');

-- 25
select ok(
  not exists (
    select 1 from public.cash_report((select today from t_src)) r
      full join (select * from public.cash_by_source where month = date_trunc('month', (select today from t_src))::date) c
        on c.source_id is not distinct from r.source_id
     where coalesce(r.turnover_tiyin, 0) <> coalesce(c.total_tiyin, 0)
        or coalesce(r.received_tiyin, 0) <> coalesce(c.received_tiyin, 0)
        or coalesce(r.spent_tiyin, 0) <> coalesce(c.spent_tiyin, 0)
        or coalesce(r.transfers_in_tiyin, 0) <> coalesce(c.transfers_in_tiyin, 0)),
  'Обороты отчёта совпадают с cash_by_source по каждой кассе, включая строку без кассы');

-- 26
select is(
  (select corrections_tiyin from public.cash_report((select today from t_src)) where source_id is null),
  -2000::bigint,
  'Деньги без кассы — отдельной строкой оборотов');

reset role;
select public.tests_claims('01020000-0000-0000-0000-0000000000a2', '01020000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 27
select throws_ok(
  $q$ select public.cancel_cash_count((select id from public.cash_counts where count_key = '01020000-0000-0000-0000-00000000c001'), 'x') $q$,
  '42501', 'Отменить сверку может только владелец центра',
  'Бухгалтер сверку не отменяет');

reset role;


-- 3. Права и запись -------------------------------------------------------------------------------

select public.tests_claims('01020000-0000-0000-0000-0000000000a3', '01020000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 28
select throws_ok(
  $q$ select * from public.cash_count_preview((select cash from t_src)) $q$,
  '42501', null,
  'Стойка остаток кассы не видит');

-- 29
select is(
  (select count(*)::integer from public.cash_counts),
  0,
  'Стойка сверок не читает');

reset role;
select public.tests_claims('01020000-0000-0000-0000-0000000000a4', '01020000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 30
select throws_ok(
  $q$ select * from public.cash_report((select today from t_src)) $q$,
  '42501', null,
  'Специалисту касса закрыта');

reset role;

-- 31
select throws_ok(
  $q$ update public.cash_counts set counted_tiyin = 1 where count_key = '01020000-0000-0000-0000-00000000c001' $q$,
  '22023', null,
  'Сверка не меняется — даже от postgres');

-- 32
select throws_ok(
  $q$ delete from public.cash_counts where count_key = '01020000-0000-0000-0000-00000000c001' $q$,
  '22023', null,
  'Сверка не удаляется');

-- 33
select ok(
  not has_table_privilege('service_role', 'public.cash_counts', 'SELECT')
  and not has_table_privilege('service_role', 'public.cash_counts', 'INSERT')
  and not has_table_privilege('authenticated', 'public.cash_counts', 'INSERT')
  and not has_function_privilege('authenticated', 'public.cash_balances_unchecked(uuid,date)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.record_cash_count(uuid,date,bigint,bigint,uuid,text)', 'EXECUTE'),
  'Запись только через RPC; помощники без грантов; аноним не сверяет');

select public.tests_claims('01020000-0000-0000-0000-0000000000a7', '01020000-0000-0000-0000-0000000000c3');
set local role authenticated;

-- 34
select throws_ok(
  $q$ select * from public.record_cash_count((select c_cash from t_src), public.center_today('01020000-0000-0000-0000-0000000000c3'),
                                             0, 0, '01020000-0000-0000-0000-00000000c007') $q$,
  'PT402', null,
  'Центр только для чтения — сверка не проводится');

reset role;


-- 4. Закрытый месяц — последним -------------------------------------------------------------------

insert into public.financial_periods (center_id, month, closed_at)
values ('01020000-0000-0000-0000-0000000000c1', date_trunc('month', (select today from t_src))::date, now());

select public.tests_claims('01020000-0000-0000-0000-0000000000a1', '01020000-0000-0000-0000-0000000000c1');
set local role authenticated;

-- 35
select throws_like(
  $q$ select * from public.record_cash_count((select bank from t_src), (select today from t_src), 40000, 40000,
                                             '01020000-0000-0000-0000-00000000c008') $q$,
  'Месяц % закрыт — переоткройте его во вкладке «Периоды», затем сверяйте',
  'Сверка в закрытом месяце — свой текст');

-- 36
select throws_like(
  $q$ select public.cancel_cash_count((select id from public.cash_counts where count_key = '01020000-0000-0000-0000-00000000c001'), 'поздно') $q$,
  'Месяц сверки (%) закрыт%',
  'Отмена сверки в закрытом месяце — отказ');

reset role;

select * from finish();
rollback;
