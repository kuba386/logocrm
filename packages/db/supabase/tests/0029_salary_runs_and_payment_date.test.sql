-- pgTAP: отмена снимка зарплаты, неизменяемость, дата платежа (0029).
-- Месяцы M1/M2 — от center_today: снимки и корректировки не привязаны к
-- занятиям, скользящее окно здесь безопасно. Два центра с разными поясами:
-- полночь дня оплаты считается по центру, а не по сессии (UTC).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
set local time zone 'UTC';

select plan(51);

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-ny@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','admin-a@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-0029','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр NY','centr-ny-0029','{"timezone":"America/New_York"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист А');

insert into public.memberships (user_id, center_id, role) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner'),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner'),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','finance'),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','admin');

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик А','+996700000001'),
  ('dddddddd-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Плательщик NY','+996700000002');

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок А','dddddddd-0000-0000-0000-000000000001');

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','8 занятий','lessons',8,400000);

-- Два незакрытых занятия в M1 — для текста close_month с числом.
create temporary table t_month as
  select (date_trunc('month', public.center_today('cccccccc-0000-0000-0000-00000000000a')) - interval '1 month')::date as m1,
         (date_trunc('month', public.center_today('cccccccc-0000-0000-0000-00000000000a')) - interval '2 months')::date as m2,
         (date_trunc('month', public.center_today('cccccccc-0000-0000-0000-00000000000a')) - interval '3 months')::date as m3,
         public.center_today('cccccccc-0000-0000-0000-00000000000a') as today;
grant select on t_month to authenticated;

insert into public.lessons (id, center_id, teacher_id, student_id, starts_at, ends_at)
select 'ffffffff-0000-0000-0000-00000000000' || n, 'cccccccc-0000-0000-0000-00000000000a',
       'aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
       ((m1 + 4)::timestamp + make_interval(hours => 9 + n)) at time zone 'Asia/Bishkek',
       ((m1 + 4)::timestamp + make_interval(hours => 9 + n, mins => 45)) at time zone 'Asia/Bishkek'
  from t_month, generate_series(1, 2) n;

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


-- 1-3. Схема ----------------------------------------------------------------------------

select has_column('public', 'salary_runs', 'cancelled_at', 'salary_runs.cancelled_at');
select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'salary_runs'
           and indexname = 'salary_runs_teacher_month_live_key' and indexdef like '%WHERE (cancelled_at IS NULL)%'),
  'Частичный unique по живым снимкам'
);
select ok(
  not exists (select 1 from pg_constraint where conname = 'salary_runs_teacher_month_key'),
  'Старый полный unique снят'
);


-- 4-16. Снимок: утвердить, повторить, отменить, переутвердить ---------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
insert into t_ins values ('run1', public.approve_salary('aaaaaaaa-0000-0000-0000-000000000001', (select m2 from t_month)));
select throws_ok(
  $q$ select public.approve_salary('aaaaaaaa-0000-0000-0000-000000000001', (select m2 from t_month)) $q$,
  '23505', null, 'Повторный approve без отмены — 23505 по salary_runs_teacher_month_live_key'
);
select throws_ok(
  $q$ select public.cancel_salary_run('aaaaaaaa-0000-0000-0000-000000000001', (select m2 from t_month)) $q$,
  '42501', null, 'cancel_salary_run — finance нет'
);
select throws_ok(
  $q$ select public.record_salary_adjustment('aaaaaaaa-0000-0000-0000-000000000001', (select m2 from t_month), 1000, 'поздно') $q$,
  '22023', null, 'Корректировка в месяц с живым снимком — approved_salary_guard'
);
reset role;

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.cancel_salary_run('aaaaaaaa-0000-0000-0000-000000000001', (select m2 from t_month)) $q$,
  '42501', null, 'cancel_salary_run — admin нет, только owner'
);
reset role;

-- Чужой центр: владелец NY не отменяет снимок центра А (ADR-002).
select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select throws_ok(
  $q$ select public.cancel_salary_run('aaaaaaaa-0000-0000-0000-000000000001', (select m2 from t_month)) $q$,
  '42704', null, 'Владелец другого центра — «снимка нет», не отмена'
);
reset role;
select is(
  (select cancelled_at from public.salary_runs where id = (select id from t_ins where name = 'run1')),
  null::timestamptz, 'Снимок центра А остался живым после попытки из NY'
);

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  public.cancel_salary_run('aaaaaaaa-0000-0000-0000-000000000001', (select m2 from t_month)),
  (select id from t_ins where name = 'run1'), 'cancel_salary_run — owner, возвращает id снимка'
);
select throws_ok(
  $q$ select public.cancel_salary_run('aaaaaaaa-0000-0000-0000-000000000001', (select m2 from t_month)) $q$,
  '42704', null, 'Повторная отмена — живого снимка нет'
);
select is(
  (select count(*)::int from public.salary_summary((select m2 from t_month))
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  1, 'salary_summary отдаёт строку специалиста — следующий null не от пустого результата'
);
select is(
  (select approved_run_id from public.salary_summary((select m2 from t_month))
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  null::uuid, 'salary_summary после отмены: живого снимка нет'
);
select is(
  (select cancelled_runs from public.salary_summary((select m2 from t_month))
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  1, 'salary_summary после отмены: отменённый виден как история'
);
select lives_ok(
  $q$ select public.record_salary_adjustment('aaaaaaaa-0000-0000-0000-000000000001', (select m2 from t_month), 20000, 'бонус после отмены') $q$,
  'Корректировка после отмены снимка проходит — guard смотрит только живые'
);
reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
insert into t_ins values ('run2', public.approve_salary('aaaaaaaa-0000-0000-0000-000000000001', (select m2 from t_month)));
select is(
  (select total_tiyin from public.salary_summary((select m2 from t_month))
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  20000, 'Переутверждение: новый снимок с корректировкой, salary_summary отдаёт его'
);
select is(
  (select approved_run_id from public.salary_summary((select m2 from t_month))
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  (select id from t_ins where name = 'run2'), 'approved_run_id — второй снимок'
);
reset role;

select is(
  (select count(*)::int from public.salary_runs where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 2,
  'Два снимка: отменённый и живой'
);
select is(
  (select count(*)::int from public.events where type = 'salary.run_cancelled'), 1,
  'Событие salary.run_cancelled — ровно одно, точная строка типа'
);


-- 17-21. Неизменяемость и старая ветка guard --------------------------------------------------

select throws_ok(
  $q$ update public.salary_runs set total_tiyin = 1 where id = (select id from t_ins where name = 'run2') $q$,
  '22023', null, 'Правка суммы снимка — отказ триггера (даже от postgres)'
);
select throws_ok(
  $q$ delete from public.salary_runs where id = (select id from t_ins where name = 'run2') $q$,
  '22023', null, 'Удаление снимка — отказ'
);
select throws_ok(
  $q$ update public.salary_runs set cancelled_at = null where id = (select id from t_ins where name = 'run1') $q$,
  '22023', null, 'Обратный переход cancelled → живой — отказ'
);
select ok(
  not has_table_privilege('authenticated', 'public.salary_runs', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.salary_runs', 'DELETE'),
  'Гранта update/delete на salary_runs по-прежнему нет — триггер второй слой'
);
-- Старая ветка guard: корректировка за M1 (снимка нет) переносится в M2 (живой снимок run2).
insert into public.salary_adjustments (center_id, teacher_id, month, amount_tiyin, reason)
values ('cccccccc-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001', (select m1 from t_month), 3000, 'M1');
select throws_ok(
  $q$ update public.salary_adjustments set month = (select m2 from t_month) where reason = 'M1' $q$,
  '22023', null, 'Перенос корректировки в месяц с живым снимком — old/new ветки guard'
);


-- 22-35. Дата платежа ------------------------------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into t_ins values ('pay_on', public.record_payment(
  'dddddddd-0000-0000-0000-000000000001', 10000, 'payment', 'eeeeeeee-0000-0000-0000-000000000001', null,
  (select id from t_src), null, 'вчера', (select today - 1 from t_month)));
select is(
  (select paid_at from public.payments where id = (select id from t_ins where name = 'pay_on')),
  (((select today - 1 from t_month)::timestamp) at time zone 'Asia/Bishkek'),
  'p_paid_on — полночь дня по поясу центра (Бишкек), не сессии'
);
select is(
  (select (paid_at at time zone 'Asia/Bishkek')::date from public.payments where id = (select id from t_ins where name = 'pay_on')),
  (select today - 1 from t_month), '…и это вчерашний день по центру'
);
insert into t_ins values ('pay_now', public.record_payment(
  'dddddddd-0000-0000-0000-000000000001', 5000, 'payment', 'eeeeeeee-0000-0000-0000-000000000001', null,
  (select id from t_src), null, 'сейчас'));
select ok(
  (select abs(extract(epoch from (paid_at - now()))) < 5 from public.payments where id = (select id from t_ins where name = 'pay_now')),
  'Ни момента, ни дня — now()'
);
select lives_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 5000, 'payment',
        'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src), now() - interval '1 hour', 'позиционно 8') $q$,
  'Позиционный вызов на 8 аргументов (как pay_installment) резолвится в новую перегрузку'
);
select throws_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 5000, 'payment',
        'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src), now(), 'оба', (select today from t_month)) $q$,
  '22023', null, 'Момент и день одновременно — отказ, не приоритет'
);
select throws_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 5000, 'payment',
        'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src), null, 'завтра', (select today + 1 from t_month)) $q$,
  '22023', null, 'День в будущем — отказ'
);
select throws_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 5000, 'payment',
        'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src), null, 'год назад', (select today - 400 from t_month)) $q$,
  '22023', null, 'День старше года — отказ (промах годом в календаре)'
);
select lives_ok(
  $q$ select public.close_month((select m2 from t_month)) $q$,
  'close_month(M2) — занятий в M2 нет'
);
select throws_like(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 5000, 'payment',
        'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src), null, 'в замок', (select m2 + 3 from t_month)) $q$,
  '%закрыт%', 'День в закрытом месяце — замок (financial_period_guard по paid_at)'
);
select throws_like(
  $q$ select public.close_month((select m1 from t_month)) $q$,
  '%— 2,%', 'close_month с двумя неотмеченными занятиями называет число'
);

-- Продажа с оплатой вчера: одна конвертация — через record_payment.
create temporary table t_sale as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
    '55550000-0000-0000-0000-000000000029', null, null, 100000, (select id from t_src), (select today - 1 from t_month));
select is(
  (select paid_at from public.payments where id = (select payment_id from t_sale limit 1)),
  (((select today - 1 from t_month)::timestamp) at time zone 'Asia/Bishkek'),
  'sell_subscription_paid: платёж при продаже — полночь дня по центру, через record_payment(p_paid_on)'
);
select is(
  (select comment from public.payments where id = (select payment_id from t_sale limit 1)),
  'Оплата при продаже абонемента', 'Комментарий продажи сохранён'
);
reset role;

-- Второй пояс: та же дата, другая полночь.
select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
insert into t_ins values ('pay_ny', public.record_payment(
  'dddddddd-0000-0000-0000-00000000000b', 7000, 'payment', null, null, null, null, 'NY',
  public.center_today('cccccccc-0000-0000-0000-00000000000b') - 1));
select is(
  (select paid_at from public.payments where id = (select id from t_ins where name = 'pay_ny')),
  ((public.center_today('cccccccc-0000-0000-0000-00000000000b') - 1)::timestamp) at time zone 'America/New_York',
  'Нью-Йорк: полночь того же «вчера» — на 10–11 часов позже бишкекской'
);
reset role;

select ok(
  (select p_ny.paid_at > p_a.paid_at
     from public.payments p_ny, public.payments p_a
    where p_ny.id = (select id from t_ins where name = 'pay_ny') and p_a.id = (select id from t_ins where name = 'pay_on')),
  'Одна и та же календарная дата даёт разные моменты по центрам'
);


-- 36-40. Роли на новом record_payment и cancel_salary_run ------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 1000, 'payment',
        'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src), null, 'finance', (select today from t_month)) $q$,
  'finance проводит платёж с датой (тело из 0026 — can_payments, не 0013)'
);
select lives_ok(
  $q$ select public.approve_salary('aaaaaaaa-0000-0000-0000-000000000001', (select m1 from t_month)) $q$,
  'finance утверждает зарплату после 0029 (тело из 0027 — can_finance)'
);
reset role;

-- Старая ветка guard: корректировка M1 (снимок теперь живой) переносится в
-- M3, где снимка нет — срабатывает только elsif по old.month.
select throws_ok(
  $q$ update public.salary_adjustments set month = (select m3 from t_month) where reason = 'M1' $q$,
  '22023', null, 'Перенос корректировки ИЗ месяца с живым снимком — старая ветка guard (old.month)'
);

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select cancelled_runs from public.salary_summary((select m2 from t_month))
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  1, 'salary_summary — admin видит cancelled_runs'
);
reset role;

select ok(
  not has_function_privilege('anon', 'public.record_payment(uuid,integer,text,uuid,uuid,uuid,timestamptz,text,date)', 'EXECUTE')
  and not has_function_privilege('public', 'public.record_payment(uuid,integer,text,uuid,uuid,uuid,timestamptz,text,date)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.record_payment(uuid,integer,text,uuid,uuid,uuid,timestamptz,text,date)', 'EXECUTE'),
  'Гранты новой record_payment выставлены заново после drop'
);
select ok(
  not has_function_privilege('anon', 'public.cancel_salary_run(uuid,date)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.cancel_salary_run(uuid,date)', 'EXECUTE'),
  'cancel_salary_run — authenticated да, anon нет'
);


-- 41-47. Итоги ------------------------------------------------------------------------------

select ok(
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'record_payment' and p.pronargs = 8),
  'Старая 8-параметровая record_payment удалена — у PostgREST один кандидат'
);
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'salary_summary'), 1,
  'salary_summary — одна перегрузка'
);
select has_column('public', 'salary_runs', 'cancelled_by', 'salary_runs.cancelled_by');
select is(
  (select cancelled_by from public.salary_runs where id = (select id from t_ins where name = 'run1')),
  '11111111-1111-1111-1111-111111111111'::uuid, 'cancelled_by — владелец, который отменил'
);
select is(
  (select count(*)::int from public.payments where center_id = 'cccccccc-0000-0000-0000-00000000000a'), 5,
  'Пять платежей центра А: вчера, сейчас, позиционный, продажа, finance'
);
select is(
  (select count(*)::int from public.events where type = 'payment.received'), 6,
  'Шесть payment.received (пять А + NY) — событие эмитится новой перегрузкой'
);
select ok(
  (select prosrc not like '%at time zone public.center_timezone%' from pg_proc where proname = 'sell_subscription_paid'),
  'sell_subscription_paid больше не считает полночь сам — одна конвертация в record_payment'
);

select * from finish();

rollback;
