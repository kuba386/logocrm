-- pgTAP: роли registrar/finance, шаг 3 — политики, витрины, лестница (0028).
-- Забор по pg_policies: список таблиц с tenant_admin БЕЗ решения по новым
-- ролям. Таблица этапа 7 без вызова apply_role_rls роняет его. Полный
-- ожидаемый набор tenant_registrar_*/tenant_finance_* — в tests/0031: 0031
-- сняла tenant_finance_select со students/lessons/attendance/payers, и
-- финансовые ассерты ниже правлены под это (finance видит 0 строк).
-- Проверки видимости — is(count, N), не lives_ok: отсутствующая политика
-- даёт ноль строк, не ошибку. Claims — явно перед каждым блоком.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(88);


-- 1-3. Заборы по каталогу политик --------------------------------------------------------

select set_eq(
  $$ select t.tablename from pg_policies t
      where t.schemaname = 'public' and t.policyname = 'tenant_admin'
        and not exists (select 1 from pg_policies r
                         where r.schemaname = 'public' and r.tablename = t.tablename
                           and (r.policyname like 'tenant_registrar%' or r.policyname like 'tenant_finance%')) $$,
  $$ values ('attendance_statuses'), ('invitations'), ('message_templates'),
            ('goal_stages'), ('diagnostics'), ('goals'), ('goal_progress'),
            ('exercise_library'), ('homework'), ('homework_exercises'),
            ('lesson_notes'), ('lesson_note_goal_scores') $$,
  'Таблицы с tenant_admin без решения по новым ролям: attendance_statuses (read_all), invitations, message_templates (0034 — настройка центра) и девять клинических таблиц (0036 — ни стойке, ни бухгалтеру не положены, FEATURE_MATRIX сноска ⁵); новая таблица роняет'
);
select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and policyname like 'tenant_%' and cmd = 'DELETE'),
  0, 'Ни одной политики новых ролей на DELETE'
);
select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and tablename = 'teacher_rates' and cmd in ('UPDATE', 'DELETE')),
  0, 'teacher_rates — append-only: ни одной политики UPDATE/DELETE ни у одной роли (гварды 0017 — только insert)'
);
select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and tablename in ('lesson_participants', 'student_payers')
      and (policyname like 'tenant_registrar%' or policyname like 'tenant_finance%')
      and cmd <> 'SELECT'),
  0, 'lesson_participants и student_payers — у новых ролей только SELECT (строки кладут триггеры; tenant_admin for all — 0004, не здесь)'
);


-- Фикстура ----------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','admin-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','nobody@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','88888888-8888-8888-8888-888888888888','authenticated','authenticated','spare-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','99999999-9999-9999-9999-999999999999','authenticated','authenticated','registrar-b@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-pol','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-pol','{}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист А'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Специалист Б');

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик А','+996700000001');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner', null, null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a','registrar', null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','finance', null, null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001', null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','admin', null, null),
  ('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000001'),
  ('88888888-8888-8888-8888-888888888888','cccccccc-0000-0000-0000-00000000000a','parent', null, null),
  ('99999999-9999-9999-9999-999999999999','cccccccc-0000-0000-0000-00000000000b','registrar', null, null);

insert into public.students (id, center_id, full_name, payer_id, notes) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок 1','dddddddd-0000-0000-0000-000000000001','заметка приёма'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Ребёнок 2','dddddddd-0000-0000-0000-000000000001', null);

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','8 занятий','lessons',8,400000);

-- L_done — август 2026, будет проведено с отметкой (выручка 50000);
-- L_plan — будущее, planned.
insert into public.lessons (id, center_id, teacher_id, student_id, starts_at, ends_at) values
  ('ffffffff-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2026-08-10 10:00+06','2026-08-10 10:45+06'),
  ('ffffffff-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2027-03-10 10:00+06','2027-03-10 10:45+06');

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
create temporary table t_cat as
  select id, row_number() over (order by sort, code) as n from public.expense_categories
   where center_id = 'cccccccc-0000-0000-0000-00000000000a';
grant select on t_src, t_cat to authenticated;

-- Данные — руками владельца через RPC: абонемент с 1 августа, отметка,
-- закрытие, платёж, расход, корректировка, снимок зарплаты, замок июля
-- (фиксированный месяц, не center_today() − 2: иначе через два месяца
-- замок лёг бы на месяц самой отметки), архив второй статьи расхода.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
insert into t_ins values ('sub1', public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', null, '2026-08-01'));
select public.mark_attendance('ffffffff-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001');
select public.mark_lesson_status('ffffffff-0000-0000-0000-000000000001', 'done');
select public.record_payment('dddddddd-0000-0000-0000-000000000001', 100000, 'payment', 'eeeeeeee-0000-0000-0000-000000000001', (select id from t_ins where name = 'sub1'), (select id from t_src));
select public.record_expense((select id from t_cat where n = 1), 30000, 'expense', (select id from t_src));
select public.record_salary_adjustment('aaaaaaaa-0000-0000-0000-000000000001', '2026-08-01', 5000, 'бонус');
select public.approve_salary('aaaaaaaa-0000-0000-0000-000000000001', '2026-08-01');
select public.close_month('2026-07-01');
select public.archive_expense_category((select id from t_cat where n = 2));
reset role;

select is(
  (select price_tiyin from public.attendance where lesson_id = 'ffffffff-0000-0000-0000-000000000001'), 50000,
  'Фикстура: отметка списала 50000 с абонемента — есть что показывать в выручке'
);

-- Эталон для invoker-калькулятора под registrar — от postgres, без RLS.
create temporary table t_ref as
  select public.refund_calc((select id from t_ins where name = 'sub1')) as v;
grant select on t_ref to authenticated;


-- 5-19. registrar: свой центр по списку ---------------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is((select count(*)::int from public.students), 2, 'registrar видит учеников');
select is((select count(*)::int from public.lessons), 2, 'registrar видит занятия');
select is((select count(*)::int from public.lesson_participants), 2, 'registrar видит состав занятий (иначе на экране пусто)');
select is((select count(*)::int from public.attendance), 1, 'registrar видит отметки');
select is((select count(*)::int from public.payments), 1, 'registrar видит платежи');
select is((select count(*)::int from public.subscriptions), 1, 'registrar видит абонементы');
select is((select count(*)::int from public.financial_periods), 1, 'registrar видит замок месяца');
select is((select count(*)::int from public.teachers), 2, 'registrar видит специалистов');
select is((select count(*)::int from public.expenses), 0, 'registrar НЕ видит расходов — ноль строк, не ошибка');
select is((select count(*)::int from public.teacher_rates), 0, 'registrar НЕ видит ставок');
select is((select count(*)::int from public.salary_runs), 0, 'registrar НЕ видит снимков зарплаты');
select is((select count(*)::int from public.salary_adjustments), 0, 'registrar НЕ видит корректировок');
select lives_ok(
  $q$ update public.students set notes = 'записал регистратор' where id = 'eeeeeeee-0000-0000-0000-000000000002' $q$,
  'registrar правит карточку ученика прямым update');
-- Прямые insert — те же, что делает приложение от admin (0024 вернуло гранты).
select lives_ok(
  $q$ insert into public.payers (center_id, full_name, phone)
      values ('cccccccc-0000-0000-0000-00000000000a', 'Плательщик от стойки', '+996700000055') $q$,
  'registrar создаёт плательщика прямым insert');
select lives_ok(
  $q$ insert into public.students (center_id, full_name, payer_id)
      values ('cccccccc-0000-0000-0000-00000000000a', 'Ребёнок от стойки', 'dddddddd-0000-0000-0000-000000000001') $q$,
  'registrar создаёт ученика прямым insert (with check: deleted_at null по умолчанию)');
select lives_ok(
  $q$ insert into public.groups (center_id, name) values ('cccccccc-0000-0000-0000-00000000000a', 'Группа от стойки') $q$,
  'registrar создаёт группу');
select lives_ok(
  $q$ insert into public.lessons (center_id, teacher_id, student_id, starts_at, ends_at)
      values ('cccccccc-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000002', '2027-05-03 10:00+06', '2027-05-03 10:45+06') $q$,
  'registrar создаёт занятие прямым insert (состав кладёт definer-триггер)');
select throws_ok(
  $q$ insert into public.lesson_participants (lesson_id, student_id, center_id, starts_at, ends_at)
      values ('ffffffff-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-00000000000a', now(), now()) $q$,
  '42501', null, 'registrar не пишет в состав напрямую — только триггеры');
select throws_ok(
  $q$ insert into public.expenses (center_id, category_id, amount_tiyin, paid_at, kind)
      values ('cccccccc-0000-0000-0000-00000000000a', (select id from t_cat where n = 1), 1, now(), 'expense') $q$,
  '42501', null, 'registrar не пишет расходы');
select throws_ok(
  $q$ update public.students set deleted_at = now() where id = 'eeeeeeee-0000-0000-0000-000000000002' $q$,
  '42501', null, 'registrar не архивирует прямым update deleted_at — with check требует null; только archive_student');
select is(
  public.refund_calc((select id from t_ins where name = 'sub1')), (select v from t_ref),
  'refund_calc (invoker) под registrar — то же число, что у postgres: subscriptions открыты политикой');
reset role;

select is(
  (select notes from public.students where id = 'eeeeeeee-0000-0000-0000-000000000002'), 'записал регистратор',
  'update registrar прошёл (RETURNING-ловушки нет: колонка не deleted_at)'
);


-- 21-38. finance: деньги и всё, что нужно витринам ---------------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is((select count(*)::int from public.payments), 1, 'finance видит платежи');
select is((select count(*)::int from public.expenses), 1, 'finance видит расходы');
select is((select count(*)::int from public.financial_periods), 1, 'finance видит замок месяца');
select is((select count(*)::int from public.salary_adjustments), 1, 'finance видит корректировки');
select is((select count(*)::int from public.salary_runs), 1, 'finance видит снимки зарплаты');
select is((select count(*)::int from public.students), 0, 'finance НЕ видит таблицу учеников (0031: ученики — через students_brief)');
select is((select count(*)::int from public.lessons), 0, 'finance НЕ видит занятий (0031: витрины выручки — через revenue_facts)');
select is((select count(*)::int from public.attendance), 0, 'finance НЕ видит отметок (0031)');
select is(
  (select count(*)::int from public.expense_categories where deleted_at is not null), 1,
  'finance видит архивную статью (expense_categories_read_archived — can_finance)');
select is((select count(*)::int from public.lesson_participants), 0, 'finance НЕ видит состав занятий');
select is((select count(*)::int from public.groups), 0, 'finance НЕ видит групп');
select lives_ok(
  $q$ insert into public.teacher_rates (center_id, teacher_id, model, value, valid_from)
      values ('cccccccc-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000002', 'per_lesson', 10000, '2026-01-01') $q$,
  'finance задаёт ставку прямым insert (RPC нет)');
select is((select count(*)::int from public.teacher_rates), 1, 'finance видит ставку, которую задал');
select lives_ok(
  $q$ insert into public.expense_categories (center_id, code, name, sort)
      values ('cccccccc-0000-0000-0000-00000000000a', 'fin_test', 'Статья бухгалтера', 99) $q$,
  'finance создаёт статью расхода');
select lives_ok(
  $q$ update public.payment_sources set name = 'Переименовано' where id = (select id from t_src) $q$,
  'finance переименовывает источник оплаты');
select throws_ok(
  $q$ insert into public.lessons (center_id, teacher_id, student_id, starts_at, ends_at)
      values ('cccccccc-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', '2027-04-01 10:00+06', '2027-04-01 10:45+06') $q$,
  '42501', null, 'finance не создаёт занятий — политики на insert нет');
select throws_ok(
  $q$ update public.payment_sources set deleted_at = now() where id = (select id from t_src) $q$,
  '42501', null, 'finance не архивирует источник прямым update — deleted_at не в колоночном гранте');
select throws_like(
  $q$ insert into public.teacher_rates (center_id, teacher_id, model, value, valid_from)
      values ('cccccccc-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000002', 'per_lesson', 1, '2026-07-15') $q$,
  '%закрыт%', 'finance: ставка задним числом в закрытый июль — замок месяца (financial_period_guard_teacher_rates)');
select throws_ok(
  $q$ insert into public.teacher_rates (center_id, teacher_id, model, value, valid_from)
      values ('cccccccc-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001', 'per_lesson', 1, '2026-08-01') $q$,
  '22023', null, 'finance: ставка в месяц с утверждённой зарплатой специалиста — approved_salary_guard');
-- Р5 из 0028 отменено 0031: заметки бухгалтеру закрыты. Подробные проверки — tests/0031.
select is_empty(
  $q$ select notes from public.students where id = 'eeeeeeee-0000-0000-0000-000000000001' $q$,
  'finance не читает students.notes — таблица закрыта (0031 отменяет Р5)');
reset role;

select is(
  (select name from public.payment_sources where id = (select id from t_src)), 'Переименовано',
  'update finance прошёл'
);


-- 39-46. Витрины: непусто и равно владельцу ------------------------------------------------------

create temporary table t_owner_rev as select * from public.revenue_by_month where false;
create temporary table t_owner_cash as select * from public.cash_by_source where false;
grant select, insert on t_owner_rev, t_owner_cash to authenticated;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
insert into t_owner_rev select * from public.revenue_by_month;
insert into t_owner_cash select * from public.cash_by_source;
reset role;

select is((select count(*)::int from t_owner_rev), 1, 'У владельца одна строка выручки (август 2026)');

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select revenue_tiyin from public.revenue_by_month where month = '2026-08-01'),
  (select revenue_tiyin from t_owner_rev where month = '2026-08-01'),
  'revenue_by_month у finance равна владельцу — не «выручка 0»');
select is(
  (select revenue_tiyin from public.revenue_by_month where month = '2026-08-01'), 50000::bigint,
  '…и это 50000');
select is(
  (select count(*)::int from public.revenue_by_teacher), 1, 'revenue_by_teacher у finance непуста');
select is(
  (select sum(total_tiyin) from public.cash_by_source), (select sum(total_tiyin) from t_owner_cash),
  'cash_by_source у finance равна владельцу');
select is(
  (select active_subscription_id from public.student_balance where student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  (select id from t_ins where name = 'sub1'),
  'student_balance у finance: живой абонемент виден (subscription_visible_to_caller — can_payments)');
select is(
  (select state from public.student_balance where student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  'active', 'student_balance у finance: колонка state (0015) на месте и заполнена — тело взято из 0015, не 0010');
reset role;

select has_column('public', 'student_balance', 'state', 'student_balance.state не потеряна пересозданием');

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select active_subscription_id from public.student_balance where student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  (select id from t_ins where name = 'sub1'),
  'student_balance у registrar: живой абонемент виден');
select is((select count(*)::int from public.revenue_by_month), 0, 'revenue_by_month у registrar пуста — выручка не его');
reset role;


-- 47-52. Чужой центр, teacher, parent — как раньше -------------------------------------------------

select public.tests_claims('99999999-9999-9999-9999-999999999999','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select is((select count(*)::int from public.students), 0, 'registrar Б не видит учеников А');
select is((select count(*)::int from public.payments), 0, 'registrar Б не видит платежей А');
select is((select count(*)::int from public.student_balance), 0, 'student_balance у registrar Б пуст');
reset role;

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.teachers), 1, 'teacher по-прежнему видит только себя');
select is((select count(*)::int from public.payments), 0, 'teacher по-прежнему без платежей');
reset role;

select public.tests_claims('77777777-7777-7777-7777-777777777777','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is((select count(*)::int from public.students), 3, 'parent видит своих детей (все трое у одного плательщика, включая созданного registrar)');
reset role;


-- 53-66. Лестница назначений ----------------------------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.change_member_role('88888888-8888-8888-8888-888888888888', 'registrar') $q$,
  'owner назначает registrar');
select lives_ok(
  $q$ select * from public.create_invitation('finance', null, null, 'buh@test.kg') $q$,
  'owner приглашает finance');
select throws_ok(
  $q$ select * from public.create_invitation('owner') $q$,
  '22023', null, 'owner не приглашается никем — роль вне списка');
reset role;

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.change_member_role('88888888-8888-8888-8888-888888888888', 'finance') $q$,
  'admin переводит registrar → finance');
select lives_ok(
  $q$ select public.change_member_role('88888888-8888-8888-8888-888888888888', 'teacher') $q$,
  'admin назначает teacher, как раньше');
select throws_ok(
  $q$ select public.change_member_role('88888888-8888-8888-8888-888888888888', 'admin') $q$,
  '42501', null, 'admin не назначает admin');
select throws_ok(
  $q$ select public.change_member_role('88888888-8888-8888-8888-888888888888', 'owner') $q$,
  '42501', null, 'admin не назначает owner');
select throws_ok(
  $q$ select public.change_member_role('88888888-8888-8888-8888-888888888888', 'parent') $q$,
  '42501', null, 'admin не переводит сотрудника в parent — белый список из трёх ролей, не чёрный');
select throws_ok(
  $q$ select public.change_member_role('11111111-1111-1111-1111-111111111111', 'finance') $q$,
  '42501', null, 'admin не трогает владельца');
select lives_ok(
  $q$ select * from public.create_invitation('registrar', null, '+996700000077') $q$,
  'admin приглашает registrar');
select throws_ok(
  $q$ select * from public.create_invitation('admin') $q$,
  '42501', null, 'admin не приглашает admin');
reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.change_member_role('88888888-8888-8888-8888-888888888888', 'registrar') $q$,
  '42501', null, 'finance не назначает роли');
select throws_ok(
  $q$ select * from public.create_invitation('parent') $q$,
  '42501', null, 'finance не приглашает');
reset role;

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select * from public.create_invitation('parent') $q$,
  '42501', null, 'Без членства create_invitation — 42501 от гейта, не откат emit_event (Р7)');
select throws_ok(
  $q$ select public.revoke_membership('88888888-8888-8888-8888-888888888888') $q$,
  '42501', null, 'Без членства revoke_membership — 42501 от гейта');
reset role;


-- 67-74. Гранты, инварианты процедуры, итог ------------------------------------------------------

select ok(
  not has_function_privilege('authenticated', 'public.apply_role_rls(text,text,text,boolean)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.apply_role_rls(text,text,text,boolean)', 'EXECUTE'),
  'apply_role_rls закрыта для прикладных ролей'
);
select throws_ok(
  $q$ call public.apply_role_rls('students', 'teacher', 'read', true) $q$,
  'P0001', null, 'apply_role_rls не принимает роль вне списка новых'
);
select throws_ok(
  $q$ call public.apply_role_rls('students', 'registrar', 'delete', true) $q$,
  'P0001', null, 'apply_role_rls не принимает режим вне read/insert/write'
);
select ok(
  (select bool_and(coalesce(array_to_string(c.reloptions, ','), '') like '%security_invoker=true%')
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'),
  'Все вью public остались security_invoker'
);
select ok(
  (select bool_and(not has_table_privilege('anon', c.oid, 'SELECT'))
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'),
  'anon не читает ни одну вью после пересоздания'
);
select is(
  (select role from public.memberships where user_id = '88888888-8888-8888-8888-888888888888'), 'teacher',
  'Запасной участник закончил как teacher — лестница прошла три ступени'
);
select is(
  (select count(*)::int from public.invitations where role in ('finance', 'registrar')), 2,
  'Два приглашения с новыми ролями созданы'
);
select is(
  (select count(*)::int from public.events where type = 'membership.role_changed'), 3,
  'Три смены роли — по одному событию'
);
select ok(
  (select prosrc like '%coalesce(public.my_role()%' from pg_proc where proname = 'revoke_membership'),
  'revoke_membership с coalesce — NULL-роль отбивается гейтом'
);

select * from finish();

rollback;
