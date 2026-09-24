-- pgTAP: выгрузка отчётов в CSV (0058) — роли, период по поясу центра, след
-- report.exported с актором и счётом строк, оба долга, сходимость зарплаты.
--
-- Даты — от center_today центра А (Asia/Bishkek), не фиксированные:
-- фиксированная дата в фикстуре уже стоила проекту трёх кругов CI на 0018.
-- M1 — прошлый месяц (полностью прошёл — зарплату можно утвердить), M2 —
-- позапрошлый (ставка действует с него). Claims — явно перед каждым
-- блоком: reset role их не сбрасывает (pgtap-reset-role-keeps-claims).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
set local time zone 'UTC';

select * from no_plan();

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a-0058@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-b-0058@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-a-0058@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-a-0058@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent-a-0058@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','registrar-a-0058@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-000000000058','Центр А 0058','centr-a-0058','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-000000000059','Центр Б 0058','centr-b-0058','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000581','cccccccc-0000-0000-0000-000000000058','Специалист А'),
  ('aaaaaaaa-0000-0000-0000-000000000582','cccccccc-0000-0000-0000-000000000058','Специалист Б');

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000581','cccccccc-0000-0000-0000-000000000058','Плательщик А','+996700000058'),
  ('dddddddd-0000-0000-0000-000000000582','cccccccc-0000-0000-0000-000000000058','Плательщик Б','+996700000059');

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000581','cccccccc-0000-0000-0000-000000000058','Ребёнок Один','dddddddd-0000-0000-0000-000000000581'),
  ('eeeeeeee-0000-0000-0000-000000000582','cccccccc-0000-0000-0000-000000000058','Ребёнок Два','dddddddd-0000-0000-0000-000000000582');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('99990000-0000-0000-0000-000000000581','cccccccc-0000-0000-0000-000000000058','Логопед',30000);

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000581','cccccccc-0000-0000-0000-000000000058','8 занятий','lessons',8,400000);

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000058','owner', null, null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-000000000059','owner', null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000058','finance', null, null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-000000000058','teacher', 'aaaaaaaa-0000-0000-0000-000000000581', null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-000000000058','parent', null, 'dddddddd-0000-0000-0000-000000000581'),
  ('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-000000000058','registrar', null, null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_month as
  select (date_trunc('month', public.center_today('cccccccc-0000-0000-0000-000000000058')) - interval '1 month')::date as m1,
         (date_trunc('month', public.center_today('cccccccc-0000-0000-0000-000000000058')) - interval '2 months')::date as m2,
         (date_trunc('month', public.center_today('cccccccc-0000-0000-0000-000000000058')))::date as m0,
         public.center_today('cccccccc-0000-0000-0000-000000000058') as today;
grant select on t_month to authenticated;

create temporary table t_ins (name text primary key, id uuid);
grant select, insert on t_ins to authenticated;
create temporary table t_src as
  select id from public.payment_sources
   where center_id = 'cccccccc-0000-0000-0000-000000000058' order by sort, code limit 1;
grant select on t_src to authenticated;

-- Два занятия в M1 (день 4, 09:00 и 10:00 по Бишкеку) — как в 0029.
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, starts_at, ends_at)
select ('44440000-0000-0000-0000-00000000058' || n)::uuid, 'cccccccc-0000-0000-0000-000000000058',
       'aaaaaaaa-0000-0000-0000-000000000581',
       ('eeeeeeee-0000-0000-0000-00000000058' || n)::uuid,
       '99990000-0000-0000-0000-000000000581',
       ((m1 + 4)::timestamp + make_interval(hours => 8 + n)) at time zone 'Asia/Bishkek',
       ((m1 + 4)::timestamp + make_interval(hours => 8 + n, mins => 45)) at time zone 'Asia/Bishkek'
  from t_month, generate_series(1, 2) n;

-- Ставка специалиста А с M2: 300 сом за занятие.
insert into public.teacher_rates (center_id, teacher_id, service_id, model, value, valid_from) values
  ('cccccccc-0000-0000-0000-000000000058','aaaaaaaa-0000-0000-0000-000000000581', null, 'per_lesson', 30000, (select m2 from t_month));

-- Абонемент ребёнку Один с частичной оплатой: 400 000 цена, 200 000 внесено.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;
create temporary table t_sale as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-000000000581', 'eeeeeeee-0000-0000-0000-000000000581',
    '55550000-0000-0000-0000-000000000581', null, (select m1 from t_month), 200000, (select id from t_src));
insert into t_ins select 'sub1', subscription_id from t_sale limit 1;

-- Платежи: 1 000 сом ребёнку Один (10-е M1), 50 сом плательщику Б в 23:30
-- последнего дня M1 (внутри периода) и 70 сом в 23:30 последнего дня M2
-- (снаружи — по UTC это уже 17:30, день тот же, но по Бишкеку месяц ещё M2).
select public.record_payment('dddddddd-0000-0000-0000-000000000581', 100000, 'payment',
  'eeeeeeee-0000-0000-0000-000000000581', (select id from t_ins where name = 'sub1'), (select id from t_src),
  (((select m1 from t_month) + 10)::timestamp + interval '12 hours') at time zone 'Asia/Bishkek', 'наличными');
select public.record_payment('dddddddd-0000-0000-0000-000000000582', 5000, 'payment',
  'eeeeeeee-0000-0000-0000-000000000582', null, (select id from t_src),
  ((select m0 from t_month)::timestamp - interval '30 minutes') at time zone 'Asia/Bishkek', 'граница внутри');
select public.record_payment('dddddddd-0000-0000-0000-000000000582', 7000, 'payment',
  null, null, (select id from t_src),
  ((select m1 from t_month)::timestamp - interval '30 minutes') at time zone 'Asia/Bishkek', 'граница снаружи');
reset role;

-- Отметки — как postgres (триггер сам подбирает абонемент и цену): ребёнок
-- Один — с абонемента (500 сом за занятие), ребёнок Два — без абонемента,
-- цена из услуги (300 сом) = долг по занятиям.
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-000000000058', l.id, l.student_id, st.id
  from public.lessons l,
       (select id from public.attendance_statuses
         where center_id = 'cccccccc-0000-0000-0000-000000000058' and code = 'present') st
 where l.center_id = 'cccccccc-0000-0000-0000-000000000058';
update public.lessons set status = 'done' where center_id = 'cccccccc-0000-0000-0000-000000000058';

-- Замена на втором занятии ПОСЛЕ отметки: вёл Б, оплачено А (paid_teacher_id
-- заморожен при отметке).
update public.lessons set substitute_teacher_id = 'aaaaaaaa-0000-0000-0000-000000000582'
 where id = '44440000-0000-0000-0000-000000000582';

-- Плательщик Б уходит в архив — его платежи остаются платежами.
update public.payers set deleted_at = now() where id = 'dddddddd-0000-0000-0000-000000000582';


-- 1-8. Платежи: период по поясу центра, архивный плательщик, след ------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;

create temporary table t_pay as
  select * from public.export_payments((select m1 from t_month), ((select m0 from t_month) - 1));

select is((select count(*)::int from t_pay), 2,
  'Платежи M1: 1 000 сом и 50 сом в 23:30 последнего дня — внутри; 70 сом в 23:30 последнего дня M2 — снаружи; аванс продажи (сегодня) — не в M1');
select is((select sum(amount_tiyin)::int from t_pay), 105000,
  'Сумма за M1 совпадает с прямым подсчётом по поясу центра (105 000 тыйын)');
select is(
  (select sum(p.amount_tiyin)::int from public.payments p
    where p.center_id = 'cccccccc-0000-0000-0000-000000000058'
      and (p.paid_at at time zone 'Asia/Bishkek')::date between (select m1 from t_month) and ((select m0 from t_month) - 1)),
  105000, 'Контроль: тот же итог, что даёт приведение каждой строки к поясу центра');
select is((select payer_name from t_pay where amount_tiyin = 5000), 'Плательщик Б',
  'Архивный плательщик остаётся в файле с именем — платёж не исчезает вместе с карточкой (Р7)');
select is((select paid_time from t_pay where amount_tiyin = 5000), '23:30',
  'Время в строке — по поясу центра, не UTC');
select is((select subscription_type from t_pay where amount_tiyin = 100000), '8 занятий',
  'Тип абонемента подставлен по платежу с subscription_id');
-- SRF — в FROM, не в списке выборки: `select jsonb_object_keys(...) limit 1`
-- отдал бы один ключ, а не все ключи одной строки (как в 0048).
select is(
  (select array_agg(k order by k) from (select to_jsonb(r) j from t_pay r limit 1) s, jsonb_object_keys(s.j) k),
  array['amount_tiyin','comment','kind','paid_on','paid_time','payer_name','payer_phone','source_name','student_name','subscription_type'],
  'Забор по колонкам платежей: ровно этот набор, notes/custom_fields нет (Р4)');

-- Журнал событий читаем как postgres: RLS events не отдаёт строки finance,
-- а проверяется здесь запись функции, не право чтения.
reset role;
select is(
  (select count(*)::int from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000058' and type = 'report.exported'
      and payload->>'report' = 'payments'),
  1, 'report.exported для платежей записано ровно один раз');
select is(
  (select (payload->>'rows')::int from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000058' and type = 'report.exported'
      and payload->>'report' = 'payments'),
  2, 'В событии — число строк, посчитанное самой функцией');
select is(
  (select payload->>'by' from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000058' and type = 'report.exported'
      and payload->>'report' = 'payments'),
  '33333333-3333-3333-3333-333333333333', 'В событии — актор (auth.uid()), Р2');
select is(
  (select payload->>'role' from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000058' and type = 'report.exported'
      and payload->>'report' = 'payments'),
  'finance', '…и роль на момент выгрузки');


-- 9-12. Границы периода — исключение, не пустой файл (Р3) ----------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;
select throws_ok(
  $q$ select * from public.export_payments(null, current_date) $q$,
  '22023', 'Укажите период выгрузки', 'null вместо даты — 22023');
select throws_ok(
  $q$ select * from public.export_payments(current_date, current_date - 1) $q$,
  '22023', 'Начало периода позже его конца', 'from > to — 22023');
select throws_ok(
  $q$ select * from public.export_payments(current_date - 366, current_date) $q$,
  '22023', 'Период выгрузки — не больше года', '367 дней — 22023 (В5)');
select lives_ok(
  $q$ select * from public.export_payments(current_date - 365, current_date) $q$,
  '366 дней — ещё можно');


-- 13-16. Долги: два определения двумя колонками (В3) --------------------------------

create temporary table t_debts as select * from public.export_debts();

select is((select count(*)::int from t_debts), 2, 'Два должника: один по абонементу, другой по занятиям');
select is(
  (select subscriptions_unpaid_tiyin from t_debts where student_name = 'Ребёнок Один'), 100000,
  'Ребёнок Один: недоплата по абонементу 400 000 − 200 000 − 100 000 = 100 000; по занятиям — нет');
select is(
  (select lessons_debt_tiyin from t_debts where student_name = 'Ребёнок Один'), 0,
  '…и долг по занятиям у него 0 — отметка списана с абонемента');
select is(
  (select lessons_debt_tiyin from t_debts where student_name = 'Ребёнок Два'),
  (select debt_tiyin from public.student_debts() where student_id = 'eeeeeeee-0000-0000-0000-000000000582'),
  'Ребёнок Два: долг по занятиям = student_debts() — то же, что на /app/debts');
select is(
  (select lessons_debt_tiyin from t_debts where student_name = 'Ребёнок Два'), 30000,
  '…и это 300 сом из цены услуги: отметка без абонемента');
select is(
  (select array_agg(k order by k) from (select to_jsonb(r) j from t_debts r limit 1) s, jsonb_object_keys(s.j) k),
  array['lessons_debt_tiyin','payer_name','payer_phone','student_name','student_status','subscriptions_unpaid_tiyin'],
  'Забор по колонкам долгов: ровно этот набор');
reset role;


-- 17-21. Зарплата: сводка и детализация из одного источника (Р5) ---------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;

create temporary table t_sum_before as select * from public.export_salary_summary((select m1 from t_month));
create temporary table t_det_before as select * from public.export_salary_details((select m1 from t_month));

select is((select count(*)::int from t_sum_before), 2, 'Сводка: оба живых специалиста, даже с нулём');
select is((select total_tiyin from t_sum_before where teacher_name = 'Специалист А'), 60000,
  'Специалист А до утверждения: 2 занятия × 300 сом = 600 сом');
select is((select sum(amount_tiyin)::int from t_det_before where teacher_name = 'Специалист А'), 60000,
  'Детализация сходится со сводкой (неутверждённый месяц — calc_salary)');
select is((select bool_or(approved) from t_det_before), false, 'Детализация помечена как предварительная');
select is(
  (select array_agg(k order by k) from (select to_jsonb(r) j from t_sum_before r limit 1) s, jsonb_object_keys(s.j) k),
  array['adjustments_tiyin','approved','approved_on','calc_tiyin','teacher_name','total_tiyin'],
  'Забор по колонкам сводки зарплаты: ровно этот набор');
select is(
  (select array_agg(k order by k) from (select to_jsonb(r) j from t_det_before r limit 1) s, jsonb_object_keys(s.j) k),
  array['amount_tiyin','approved','lesson_date','lesson_price_tiyin','model','note','teacher_name'],
  'Забор по колонкам детализации: имени ребёнка нет — finance не видит посещений (0031, В2)');

insert into t_ins values ('run1', public.approve_salary('aaaaaaaa-0000-0000-0000-000000000581', (select m1 from t_month)));
reset role;

-- После утверждения меняем ставку задним числом: снимок не должен поплыть.
insert into public.teacher_rates (center_id, teacher_id, service_id, model, value, valid_from) values
  ('cccccccc-0000-0000-0000-000000000058','aaaaaaaa-0000-0000-0000-000000000581', null, 'per_lesson', 99900, (select m2 from t_month) + 1);

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;
create temporary table t_sum_after as select * from public.export_salary_summary((select m1 from t_month));
create temporary table t_det_after as select * from public.export_salary_details((select m1 from t_month));

select is((select total_tiyin from t_sum_after where teacher_name = 'Специалист А'), 60000,
  'После утверждения сводка держит замороженные 600 сом, хотя ставка задним числом изменилась');
select is((select sum(amount_tiyin)::int from t_det_after where teacher_name = 'Специалист А'), 60000,
  'Детализация — из снимка salary_runs.lines, те же 600 сом: сводка и детали не расходятся (Р5)');
select is((select bool_and(approved) from t_det_after where teacher_name = 'Специалист А'), true,
  '…и помечена как утверждённая');
select is((select approved from t_sum_after where teacher_name = 'Специалист Б'), false,
  'Специалист Б без снимка — предварительный ноль');
select is(
  (select approved_on from t_sum_after where teacher_name = 'Специалист А'),
  (select (approved_at at time zone 'Asia/Bishkek')::date from public.salary_runs where id = (select id from t_ins where name = 'run1')),
  'approved_on — день утверждения по поясу центра');
reset role;

-- Пояс с большим сдвигом: дата утверждения следует за поясом центра, не за UTC.
update public.centers set settings = settings || '{"timezone":"Pacific/Kiritimati"}'::jsonb
 where id = 'cccccccc-0000-0000-0000-000000000058';
select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;
select is(
  (select approved_on from public.export_salary_summary((select m1 from t_month)) where teacher_name = 'Специалист А'),
  (select (approved_at at time zone 'Pacific/Kiritimati')::date from public.salary_runs where id = (select id from t_ins where name = 'run1')),
  'approved_on пересчитывается по текущему поясу центра (UTC+14), не по UTC');
reset role;
update public.centers set settings = settings || '{"timezone":"Asia/Bishkek"}'::jsonb
 where id = 'cccccccc-0000-0000-0000-000000000058';


-- 22-26. Посещаемость: только owner/admin, два специалиста, статус занятия (Р6) --------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;
create temporary table t_att as
  select * from public.export_attendance((select m1 from t_month), ((select m0 from t_month) - 1));

select is((select count(*)::int from t_att), 2, 'Две отметки за M1');
select is((select teacher_name from t_att where student_name = 'Ребёнок Два'), 'Специалист Б',
  'Специалист занятия — с учётом замены (effective_teacher_id)');
select is((select paid_teacher_name from t_att where student_name = 'Ребёнок Два'), 'Специалист А',
  'Кому оплачено — заморожено при отметке, замена не переписала (сверка с зарплатой, Р6)');
select is((select lesson_status from t_att where student_name = 'Ребёнок Один'), 'done', 'Статус занятия — колонкой');
select is(
  (select array_agg(k order by k) from (select to_jsonb(r) j from t_att r limit 1) s, jsonb_object_keys(s.j) k),
  array['deducted','group_name','is_present','lesson_date','lesson_status','lesson_time','paid_teacher_name',
        'pays_teacher','price_tiyin','service_name','status_name','student_name','teacher_name'],
  'Забор по колонкам посещаемости: attendance.comment отсутствует (0031/0044)');
reset role;


-- 27-34. Роли: отказ — исключение, не пустота (Р13) ----------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;
select throws_ok(
  $q$ select * from public.export_attendance(current_date - 7, current_date) $q$,
  '42501', null, 'finance не выгружает посещаемость (0031, В2)');
reset role;

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;
select throws_ok($q$ select * from public.export_payments(current_date - 7, current_date) $q$, '42501', null, 'registrar — платежи нет (В2)');
select throws_ok($q$ select * from public.export_debts() $q$, '42501', null, 'registrar — долги нет');
select throws_ok($q$ select * from public.export_attendance(current_date - 7, current_date) $q$, '42501', null, 'registrar — посещаемость нет');
reset role;

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;
select throws_ok($q$ select * from public.export_salary_summary(current_date) $q$, '42501', null, 'teacher — зарплата нет');
select throws_ok($q$ select * from public.export_salary_details(current_date) $q$, '42501', null, 'teacher — детализация нет');
reset role;

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-000000000058');
set local role authenticated;
select throws_ok($q$ select * from public.export_payments(current_date - 7, current_date) $q$, '42501', null, 'parent — платежи нет');
select throws_ok($q$ select * from public.export_debts() $q$, '42501', null, 'parent — долги нет');
reset role;

-- Владелец другого центра: свой центр пуст, чужие строки не текут.
select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-000000000059');
set local role authenticated;
select is((select count(*)::int from public.export_payments((select m1 from t_month), ((select m0 from t_month) - 1))), 0,
  'Владелец центра Б за тот же период — 0 строк, платежи центра А не видны (ADR-002)');
select is((select count(*)::int from public.export_debts()), 0, '…и долгов чужого центра тоже');
reset role;


-- 35-37. События: по одному на вызов, только у центра-владельца -------------------------

select is(
  (select count(*)::int from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000058' and type = 'report.exported'),
  9, 'Центр А: 9 успешных выгрузок = 9 событий (платежи ×2, долги ×1, сводка ×3, детализация ×2, посещаемость ×1); отказы событий не пишут');
select is(
  (select count(*)::int from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000059' and type = 'report.exported'),
  2, 'Центр Б: свои два пустых экспорта — след пишется и при нуле строк');
select is(
  (select (payload->>'rows')::int from public.events
    where center_id = 'cccccccc-0000-0000-0000-000000000059' and type = 'report.exported' and payload->>'report' = 'debts'),
  0, '…с rows = 0');


-- 38-40. Гранты ----------------------------------------------------------------------------

select ok(
  (select bool_and(has_function_privilege('authenticated', f, 'EXECUTE'))
     from unnest(array['public.export_payments(date,date)', 'public.export_salary_summary(date)',
                       'public.export_salary_details(date)', 'public.export_attendance(date,date)',
                       'public.export_debts()']) f),
  'Пять export_* — исполняются authenticated (роль отсекается внутри)');
select ok(
  not (select bool_or(has_function_privilege('anon', f, 'EXECUTE') or has_function_privilege('service_role', f, 'EXECUTE'))
         from unnest(array['public.export_payments(date,date)', 'public.export_salary_summary(date)',
                           'public.export_salary_details(date)', 'public.export_attendance(date,date)',
                           'public.export_debts()']) f),
  'anon и service_role — нет');
select ok(
  not has_function_privilege('authenticated', 'public.report_period_check(date,date)', 'EXECUTE'),
  'report_period_check — внутренний хелпер, authenticated не зовёт');

select * from finish();

rollback;
