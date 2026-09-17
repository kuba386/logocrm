-- pgTAP: кому разрешено исполнять функции в public.
-- Запуск: pnpm db:test   (supabase test db)
--
-- CLAUDE.md отмечает, что pgTAP ходит от роли authenticated и грантов не
-- проверяет. Здесь это обходится: has_function_privilege принимает имя роли
-- аргументом, переключаться на неё не нужно.
--
-- Тест появился после того, как линтер Supabase нашёл в 0006 четыре
-- служебные функции, открытые роли authenticated: `revoke ... from public,
-- anon` не снимает грант, который Supabase выдаёт authenticated по
-- умолчанию.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select * from no_plan();


-- 1. Четыре функции из 0007 закрыты для всех прикладных ролей ------------------

select ok(
  not has_function_privilege(role_name, func, 'EXECUTE'),
  format('%s не может исполнять %s', role_name, func)
)
from unnest(array[
  'public.rebuild_lesson_participants(uuid)',
  'public.lessons_participants_trigger()',
  'public.group_students_participants_trigger()',
  'public.lesson_slot_conflicts(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid)',
  'public.seed_attendance_statuses(uuid)',
  'public.centers_seed_statuses()',
  'public.subscriptions_apply_freeze_shift()',
  'public.attendance_fill_and_check()',
  'public.attendance_recalc_trigger()',
  'public.lessons_recalc_attendance_trigger()',
  'public.recalc_subscription_usage(uuid)',
  'public.check_absent_streak(uuid, uuid, uuid)',
  'public.subscriptions_guard_soft_delete()',
  'public.attendance_statuses_check_default()',
  'public.centers_seed_payment_sources()',
  'public.payments_recalc_trigger()',
  'public.financial_period_guard()',
  'public.subscription_types_guard_sold_fields()',
  'public.subscription_freezes_guard_backdate()',
  'public.seed_payment_sources(uuid)',
  'public.recalc_subscription_paid(uuid)',
  'public.students_track_payer()',
  'public.backfill_subscription_payments()',
  'public.backfill_student_payers_history()',
  'public.centers_seed_expense_categories()',
  'public.seed_expense_categories(uuid)',
  'public.teacher_rates_set_created_by()',
  'public.approved_salary_guard()',
  'public.emit_event_unchecked(text,jsonb,uuid)',
  'public.installments_notify()',
  'public.installment_plans_cancel_live(uuid)',
  'public.subscriptions_cancel_installments()',
  'public.memberships_last_owner_guard()',
  'public.apply_role_rls(text, text, text, boolean)',
  'public.salary_runs_immutable()',
  'public.payments_no_overpay()'
]) as func,
unnest(array['public', 'anon', 'authenticated']) as role_name;


-- 2. Забор: что вообще доступно каждой роли -----------------------------------

-- Смысл не в проверке текущего состояния, а в том, что любая новая функция
-- в будущей миграции ломает тест, пока автор явно не решит, кому она видна.
-- Фильтр по pg_depend отсекает функции расширений — иначе набор поедет от
-- смены версии Postgres.

select is_empty(
  $$ select p.oid::regprocedure::text
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind in ('f','p')
        and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
        and has_function_privilege('public', p.oid, 'EXECUTE') $$,
  'Роль PUBLIC не исполняет ни одной функции в public'
);

select set_eq(
  $$ select p.oid::regprocedure::text
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind in ('f','p')
        and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
        and has_function_privilege('anon', p.oid, 'EXECUTE') $$,
  $$ values ('invitation_preview(text)') $$,
  'anon исполняет только invitation_preview — единственную функцию до входа'
);

select set_eq(
  $$ select p.oid::regprocedure::text
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind in ('f','p')
        and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
        and has_function_privilege('authenticated', p.oid, 'EXECUTE') $$,
  $$ values
    ('accept_invitation(text)'),
    ('age_years(date)'),
    ('archive_attendance_status(uuid)'),
    ('archive_expense_category(uuid)'),
    ('archive_payment_source(uuid)'),
    ('archive_student(uuid)'),
    ('archive_subscription_type(uuid)'),
    ('cancel_lesson(uuid,text)'),
    ('cancel_series_from(uuid,date,text)'),
    ('center_timezone(uuid)'),
    ('change_member_role(uuid,text)'),
    ('close_month(date)'),
    ('create_center(text,text)'),
    ('create_invitation(text,text,text,text,uuid)'),
    ('create_lesson_series(jsonb)'),
    ('create_lesson_series_preview(jsonb)'),
    ('create_student_with_payer(text,uuid,text,text,text,date,text,uuid,text,text)'),
    ('current_center()'),
    ('emit_event(text,jsonb,uuid)'),
    ('find_payer_by_phone(text)'),
    ('has_feature(text)'),
    ('invitation_preview(text)'),
    ('is_member(uuid)'),
    ('mark_lesson_status(uuid,text,text)'),
    ('my_payer_id()'),
    ('my_role()'),
    ('my_teacher_id()'),
    ('normalize_kg_phone(text)'),
    ('parent_of_lesson(uuid)'),
    ('parent_of_student(uuid)'),
    ('payer_display_name(uuid)'),
    ('record_expense(uuid,integer,text,uuid,date,text)'),
    ('record_payment(uuid,integer,text,uuid,uuid,uuid,timestamp with time zone,text,date)'),
    ('cancel_salary_run(uuid,date)'),
    ('reopen_month(date)'),
    ('reschedule_lesson(uuid,timestamp with time zone,timestamp with time zone)'),
    ('restore_attendance_status(uuid)'),
    ('restore_expense_category(uuid)'),
    ('restore_payment_source(uuid)'),
    ('restore_student(uuid)'),
    ('restore_subscription_type(uuid)'),
    ('revoke_membership(uuid)'),
    ('role_in(uuid)'),
    ('ru_month_year(date)'),
    ('series_dates(jsonb)'),
    ('set_default_attendance_status(uuid)'),
    ('substitute_teacher(uuid,uuid)'),
    ('switch_center(uuid)'),
    ('teacher_of_lesson(uuid)'),
    ('teacher_teaches_student(uuid)'),
    ('teacher_vacation(uuid,date,date)'),
    ('teacher_vacation_preview(uuid,date,date)'),
    ('user_email(uuid)'),
    ('was_access_revoked()'),
    ('calc_lesson_price(integer,integer)'),
    ('center_today(uuid)'),
    ('freeze_subscription(uuid,date,date)'),
    ('mark_attendance(uuid,uuid,text,text)'),
    ('mark_attendance_bulk(uuid,jsonb)'),
    ('refund_calc(uuid)'),
    ('refund_subscription(uuid,integer,uuid)'),
    ('sell_subscription(uuid,uuid,integer,date)'),
    ('student_subscription_badge(uuid)'),
    ('student_balance_pick(uuid)'),
    ('subscription_current_freeze(uuid,date)'),
    ('subscription_freeze_days(uuid)'),
    ('subscription_lessons_left(uuid)'),
    ('subscription_state(uuid)'),
    ('subscription_summary(uuid)'),
    ('transfer_remaining(uuid,uuid)'),
    ('unfreeze_subscription(uuid,date)'),
    ('archive_teacher(uuid)'),
    ('restore_teacher(uuid)'),
    ('record_salary_adjustment(uuid,date,integer,text)'),
    ('calc_salary(uuid,date)'),
    ('approve_salary(uuid,date)'),
    ('salary_summary(date)'),
    ('create_installment_plan(uuid,integer,date,smallint,integer)'),
    ('pay_installment(uuid,uuid,timestamp with time zone,text)'),
    ('cancel_installment_plan(uuid)'),
    ('subscription_payment_summary(uuid)'),
    ('sell_subscription_paid(uuid,uuid,uuid,integer,date,integer,uuid,date,integer,date,smallint,integer)'),
    ('can_front_desk(uuid)'),
    ('can_finance(uuid)'),
    ('can_payments(uuid)'),
    ('students_brief()'),
    ('payers_brief()'),
    ('student_debts()'),
    ('revenue_facts()'),
    ('month_open_lessons_count(date)'),
    ('create_telegram_link_code()'),
    ('unlink_telegram()'),
    ('payer_telegram_linked(uuid)'),
    ('preview_message(text,jsonb)')
  $$,
  'authenticated исполняет только функции из белого списка'
);


-- 3. Триггер жив после снятия грантов ------------------------------------------

-- Прямое доказательство того, что revoke не сломал состав участников:
-- вложенный вызов проходит, потому что триггерные функции security definer
-- и внутри них current_user = postgres, владелец функции.

insert into auth.users (instance_id, id, aud, role, email)
values ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111',
        'authenticated', 'authenticated', 'grants-owner@test.kg');

insert into public.centers (id, name, slug, settings)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Центр прав', 'centr-prav', '{}'::jsonb);

insert into public.memberships (user_id, center_id, role)
values ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'owner');

insert into public.teachers (id, center_id, full_name)
values ('cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Специалист');

insert into public.payers (id, center_id, full_name, phone)
values ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Родитель', '+996700000001');

insert into public.students (id, center_id, full_name, payer_id)
values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Ребёнок',
        'dddddddd-dddd-dddd-dddd-dddddddddddd');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
                      'app_metadata', json_build_object('center_id', p_center))::text,
    true
  );
end;
$$;

select public.tests_claims('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
set local role authenticated;

insert into public.lessons (id, teacher_id, student_id, starts_at, ends_at)
values ('ffffffff-ffff-ffff-ffff-ffffffffffff',
        'cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid,
        'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
        '2026-10-05 10:00:00+06', '2026-10-05 10:45:00+06');

select is(
  (select count(*) from public.lesson_participants
    where lesson_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff')::int,
  1,
  'Триггер состава сработал, несмотря на снятые гранты'
);

select throws_ok(
  $q$ select public.rebuild_lesson_participants('ffffffff-ffff-ffff-ffff-ffffffffffff') $q$,
  '42501',
  null,
  'Прямой вызов rebuild_lesson_participants отбивается'
);

reset role;


select * from finish();

rollback;
