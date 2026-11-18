-- pgTAP: оплата специалисту по статусу — к прошлым отметкам (0112).
--
-- Р1 права и центр; Р2 удалённые и отменённые занятия вне отбора; Р3 месяцы
-- со снимком, выплатой и закрытым периодом не трогаются; Р5 счёт сходится с
-- данными, повтор — ноль; Р6 снимок меняет только RPC под флагом и только в
-- значение статуса; Р7 только чтение — PT402 на применении.
-- reset role не сбрасывает claims — tests_claims явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(27);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('01120000-0000-0000-0000-0000000000a' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0112@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 4) n;

insert into public.centers (id, name, slug, settings) values
  ('01120000-0000-0000-0000-0000000000c1', 'Центр 0112', 'centr-0112', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('01120000-0000-0000-0000-0000000000c2', 'Чужой 0112', 'chuzhoy-0112', '{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.teachers (id, center_id, full_name) values
  ('01120000-0000-0000-0000-0000000000b1', '01120000-0000-0000-0000-0000000000c1', 'Первый 0112'),
  ('01120000-0000-0000-0000-0000000000b2', '01120000-0000-0000-0000-0000000000c1', 'Второй 0112');
insert into public.payers (id, center_id, full_name, phone) values
  ('01120000-0000-0000-0000-0000000000d1', '01120000-0000-0000-0000-0000000000c1', 'Мама 0112', '+996700011201');
insert into public.students (id, center_id, full_name, payer_id) values
  ('01120000-0000-0000-0000-000000000e01', '01120000-0000-0000-0000-0000000000c1', 'Аня 0112', '01120000-0000-0000-0000-0000000000d1');

-- 1 owner · 2 admin · 3 teacher · 4 owner чужого центра.
insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('01120000-0000-0000-0000-0000000000a1', '01120000-0000-0000-0000-0000000000c1', 'owner',   null),
  ('01120000-0000-0000-0000-0000000000a2', '01120000-0000-0000-0000-0000000000c1', 'admin',   null),
  ('01120000-0000-0000-0000-0000000000a3', '01120000-0000-0000-0000-0000000000c1', 'teacher', '01120000-0000-0000-0000-0000000000b1'),
  ('01120000-0000-0000-0000-0000000000a4', '01120000-0000-0000-0000-0000000000c2', 'owner',   null);

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('01120000-0000-0000-0000-0000000005e1', '01120000-0000-0000-0000-0000000000c1', 'Логопед 0112', 100000);
insert into public.teacher_rates (center_id, teacher_id, service_id, model, value, valid_from) values
  ('01120000-0000-0000-0000-0000000000c1', '01120000-0000-0000-0000-0000000000b2', null, 'per_lesson', 30000, current_date - 400);

-- Месяцы назад от текущего в поясе центра: M1 — прошлый, M4 — четыре назад.
create temporary table t0112 as
select n, (date_trunc('month', now() at time zone 'Asia/Bishkek') - make_interval(months => n))::date as month
  from generate_series(1, 4) n;
-- Читают и под set local role authenticated.
grant select on t0112 to authenticated;

-- Как в kadamlogo: «Пришёл» отмечали, пока галочка оплаты была снята.
update public.attendance_statuses set pays_teacher = false
 where center_id = '01120000-0000-0000-0000-0000000000c1' and code = 'present';

-- L0 M4 — раньше даты пересчёта; L1 M3 — закрытый месяц; L2 M2 T1 — снимок
-- зарплаты; L3 M2 T2 — меняется; L4 M1 T1 — выплата; L5 M1 T2 — меняется;
-- L6 M1 T2 — отменено после отметки; L7 M1 T2 — удалено после отметки;
-- L8 M1 T2 — для проверок флага в триггере; L9 M1 T2 — «Болел».
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at)
select x.id::uuid, '01120000-0000-0000-0000-0000000000c1', x.t::uuid, '01120000-0000-0000-0000-0000000005e1',
       '01120000-0000-0000-0000-000000000e01', 'done',
       ((select month from t0112 where n = x.m) + (x.d - 1) * interval '1 day' + interval '10 hours') at time zone 'Asia/Bishkek',
       ((select month from t0112 where n = x.m) + (x.d - 1) * interval '1 day' + interval '10 hours 45 minutes') at time zone 'Asia/Bishkek'
  from (values
    ('01120000-0000-0000-0000-000000000100', '01120000-0000-0000-0000-0000000000b2', 4, 10),
    ('01120000-0000-0000-0000-000000000101', '01120000-0000-0000-0000-0000000000b2', 3, 10),
    ('01120000-0000-0000-0000-000000000102', '01120000-0000-0000-0000-0000000000b1', 2, 10),
    ('01120000-0000-0000-0000-000000000103', '01120000-0000-0000-0000-0000000000b2', 2, 11),
    ('01120000-0000-0000-0000-000000000104', '01120000-0000-0000-0000-0000000000b1', 1, 10),
    ('01120000-0000-0000-0000-000000000105', '01120000-0000-0000-0000-0000000000b2', 1, 11),
    ('01120000-0000-0000-0000-000000000106', '01120000-0000-0000-0000-0000000000b2', 1, 12),
    ('01120000-0000-0000-0000-000000000107', '01120000-0000-0000-0000-0000000000b2', 1, 13),
    ('01120000-0000-0000-0000-000000000108', '01120000-0000-0000-0000-0000000000b2', 1, 14),
    ('01120000-0000-0000-0000-000000000109', '01120000-0000-0000-0000-0000000000b2', 1, 15)
  ) x(id, t, m, d);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create or replace function public.tests_status(p_code text)
  returns uuid language sql as $$
  select s.id from public.attendance_statuses s
   where s.center_id = '01120000-0000-0000-0000-0000000000c1' and s.code = p_code and s.deleted_at is null;
$$;

-- pays_teacher отметки занятия L<n>.
create or replace function public.tests_pays(p_n int)
  returns boolean language sql as $$
  select a.pays_teacher from public.attendance a
   where a.lesson_id = ('01120000-0000-0000-0000-00000000010' || p_n)::uuid;
$$;

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select '01120000-0000-0000-0000-0000000000c1', l.id, '01120000-0000-0000-0000-000000000e01',
       public.tests_status(case when l.id = '01120000-0000-0000-0000-000000000109' then 'sick' else 'present' end)
  from public.lessons l where l.center_id = '01120000-0000-0000-0000-0000000000c1';

-- После отметок: отмена и удаление занятий, снимок, выплата, закрытый месяц.
update public.lessons set status = 'cancelled' where id = '01120000-0000-0000-0000-000000000106';
update public.lessons set deleted_at = now() where id = '01120000-0000-0000-0000-000000000107';
insert into public.salary_runs (center_id, teacher_id, month, total_tiyin, lines) values
  ('01120000-0000-0000-0000-0000000000c1', '01120000-0000-0000-0000-0000000000b1', (select month from t0112 where n = 2), 0, '[]'::jsonb);
insert into public.expenses (center_id, category_id, amount_tiyin, paid_at, kind, teacher_id, salary_month)
values ('01120000-0000-0000-0000-0000000000c1', public.salary_expense_category_unchecked('01120000-0000-0000-0000-0000000000c1'),
        50000, now(), 'expense', '01120000-0000-0000-0000-0000000000b1', (select month from t0112 where n = 1));
insert into public.financial_periods (center_id, month, closed_at)
values ('01120000-0000-0000-0000-0000000000c1', (select month from t0112 where n = 3), now());

-- Галочку вернули.
update public.attendance_statuses set pays_teacher = true
 where center_id = '01120000-0000-0000-0000-0000000000c1' and code = 'present';


-- 2. Гранты и снимок вне RPC (Р6) ------------------------------------------------------------------

select ok(not has_function_privilege('anon', 'public.apply_status_pay_to_marks(uuid,date,boolean)', 'EXECUTE')
          and has_function_privilege('authenticated', 'public.apply_status_pay_to_marks(uuid,date,boolean)', 'EXECUTE'),
  'RPC: anon — нет, authenticated — да');
select ok(not has_column_privilege('authenticated', 'public.attendance', 'pays_teacher', 'UPDATE'),
  'Клиент не пишет pays_teacher напрямую (колоночный грант)');
select ok(public.tests_pays(5) = false, 'Возврат галочки старую отметку не меняет');

update public.attendance set pays_teacher = true where lesson_id = '01120000-0000-0000-0000-000000000108';
select is(public.tests_pays(8), false, 'Без флага даже значение статуса перетирается (postgres)');

select set_config('logocrm.status_pay_apply', '1', true);
update public.attendance set pays_teacher = true where lesson_id = '01120000-0000-0000-0000-000000000108';
select is(public.tests_pays(8), true, 'Под флагом — в текущее значение статуса');
update public.attendance set pays_teacher = false where lesson_id = '01120000-0000-0000-0000-000000000108';
select is(public.tests_pays(8), true, 'Под флагом, но не в значение статуса — перетирается');
select set_config('logocrm.status_pay_apply', '', true);

-- Обычная правка отметки владельцем снимок не трогает.
select public.tests_claims('01120000-0000-0000-0000-0000000000a1', '01120000-0000-0000-0000-0000000000c1');
set local role authenticated;
update public.attendance set comment = 'правка 0112' where lesson_id = '01120000-0000-0000-0000-000000000105';
reset role;
select ok((select a.comment = 'правка 0112' and not a.pays_teacher from public.attendance a
            where a.lesson_id = '01120000-0000-0000-0000-000000000105'),
  'Правка комментария прошла, pays_teacher остался прежним');


-- 3. Права и центр (Р1) ----------------------------------------------------------------------------

select public.tests_claims('01120000-0000-0000-0000-0000000000a3', '01120000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  format('select public.apply_status_pay_to_marks(%L, %L, true)', public.tests_status('present'),
         (select month from t0112 where n = 3)),
  '42501', 'Недостаточно прав', 'Специалист — отказ');
reset role;

select public.tests_claims('01120000-0000-0000-0000-0000000000a4', '01120000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_ok(
  format('select public.apply_status_pay_to_marks(%L, %L, true)', public.tests_status('present'),
         (select month from t0112 where n = 3)),
  '42704', 'Статус посещения не найден', 'Статус чужого центра — не найден');
reset role;


-- 4. Предпросмотр и применение (Р2, Р3, Р5) --------------------------------------------------------

select public.tests_claims('01120000-0000-0000-0000-0000000000a1', '01120000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  public.apply_status_pay_to_marks(public.tests_status('present'), (select month from t0112 where n = 3), true),
  '{"updated": 2, "skipped_salary": 1, "skipped_paid": 1, "skipped_period": 1, "pays_teacher": true}'::jsonb,
  'Предпросмотр: L3 и L5 меняются; снимок, выплата и закрытый месяц — пропуск; L0, L6, L7, L9 вне отбора');
reset role;
select ok(not public.tests_pays(3) and not public.tests_pays(5), 'Предпросмотр ничего не пишет');

select public.tests_claims('01120000-0000-0000-0000-0000000000a2', '01120000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  public.apply_status_pay_to_marks(public.tests_status('present'), (select month from t0112 where n = 3)),
  '{"updated": 2, "skipped_salary": 1, "skipped_paid": 1, "skipped_period": 1, "pays_teacher": true}'::jsonb,
  'Администратор применяет — тот же счёт');
reset role;

select ok(public.tests_pays(3) and public.tests_pays(5), 'L3 и L5 теперь оплачиваются');
select is(public.tests_pays(0), false, 'L0 раньше даты — не тронут');
select is(public.tests_pays(1), false, 'L1 в закрытом месяце — не тронут');
select is(public.tests_pays(2), false, 'L2 с утверждённой зарплатой — не тронут');
select is(public.tests_pays(4), false, 'L4 с выплатой за месяц — не тронут');
select ok(not public.tests_pays(6) and not public.tests_pays(7), 'Отменённое и удалённое занятия — не тронуты');
select is(public.tests_pays(9), false, '«Болел» — другой статус, не тронут');

select public.tests_claims('01120000-0000-0000-0000-0000000000a1', '01120000-0000-0000-0000-0000000000c1');
set local role authenticated;
select ok(
  (select c.note is null and c.amount_tiyin = 30000
     from public.calc_salary('01120000-0000-0000-0000-0000000000b2', (select month from t0112 where n = 2)) c
    where c.lesson_id = '01120000-0000-0000-0000-000000000103'),
  'Зарплата: L3 оплачено по ставке, без «статус не оплачивается»');
select is(
  public.apply_status_pay_to_marks(public.tests_status('present'), (select month from t0112 where n = 3)) ->> 'updated',
  '0', 'Повтор — менять нечего');

-- Обратный круг: галочку сняли — L3, L5 и L8 снова не оплачиваются.
reset role;
update public.attendance_statuses set pays_teacher = false
 where center_id = '01120000-0000-0000-0000-0000000000c1' and code = 'present';
select public.tests_claims('01120000-0000-0000-0000-0000000000a1', '01120000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  public.apply_status_pay_to_marks(public.tests_status('present'), (select month from t0112 where n = 3)) ->> 'updated',
  '3', 'Обратный круг: три отметки снова без оплаты');
reset role;
select ok(not public.tests_pays(3) and not public.tests_pays(5) and not public.tests_pays(8),
  'L3, L5, L8 — false');


-- 5. Замок с утверждением зарплаты (Р4) ------------------------------------------------------------

select ok(
  (select p.prosrc like '%salary_payout:%' from pg_proc p where p.oid = 'public.approve_salary(uuid,date)'::regprocedure)
  and (select p.prosrc like '%salary_payout:%' from pg_proc p where p.oid = 'public.apply_status_pay_to_marks(uuid,date,boolean)'::regprocedure),
  'approve_salary и пересчёт берут один ключ с pay_salary');


-- 6. Только чтение (Р7) — последним ----------------------------------------------------------------

update public.attendance_statuses set pays_teacher = true
 where center_id = '01120000-0000-0000-0000-0000000000c1' and code = 'present';
alter table public.centers disable trigger centers_protect_plan;
update public.centers set plan = 'studio', subscription_until = null where id = '01120000-0000-0000-0000-0000000000c1';
alter table public.centers enable trigger centers_protect_plan;

select public.tests_claims('01120000-0000-0000-0000-0000000000a1', '01120000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  public.apply_status_pay_to_marks(public.tests_status('present'), (select month from t0112 where n = 3), true) ->> 'updated',
  '3', 'Только чтение: предпросмотр работает');
select throws_ok(
  format('select public.apply_status_pay_to_marks(%L, %L)', public.tests_status('present'),
         (select month from t0112 where n = 3)),
  'PT402', null, 'Только чтение: применение — PT402');
reset role;
select public.tests_claims('01120000-0000-0000-0000-0000000000a1', '01120000-0000-0000-0000-0000000000c1');
select is(public.tests_pays(3), false, 'После отказа ничего не изменилось');

select * from finish();
rollback;
