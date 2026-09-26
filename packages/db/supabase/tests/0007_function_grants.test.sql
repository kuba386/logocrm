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
  'public.payments_no_overpay()',
  'public.seed_goal_stages(uuid)',
  'public.centers_seed_goal_stages()',
  'public.homework_exercises_check_center_refs()',
  'public.goals_sync_achieved_at()',
  'public.homework_status_transition()',
  'public.clinical_teacher_taught(uuid,uuid)',
  'public.notification_homework_recipients(uuid,uuid)',
  'public.notification_homework_targets(uuid,uuid,text)',
  'public.notification_user_targets(uuid,uuid,text)',
  'public.centers_protect_plan()',
  'public.center_readonly_guard()',
  'public.readonly_guard_exempt_tables()',
  'public.apply_readonly_guard(text, boolean)',
  'public.center_writable(uuid)',
  'public.emit_event_platform(text,jsonb,uuid)',
  'public.notification_platform_targets(text)',
  'public.message_templates_platform_audience()',
  'public.message_templates_mandatory_active()',
  'public.subscription_reminders()',
  'public.assert_one_trial_center(uuid, boolean)',
  'public.memberships_one_trial_per_owner()',
  'public.center_month_start(uuid)',
  'public.center_ai_notes_used(uuid)',
  'public.ai_notes_reserved(uuid, bigint)',
  'public.assert_ai_quota(uuid)',
  'public.funnel_stage_rank(text)',
  'public.students_funnel_stage_guard()',
  'public.students_funnel_events()',
  'public.subscriptions_funnel_transition()',
  'public.attendance_funnel_transition()',
  'public.plan_limit(uuid,text)',
  'public.center_plan_name(uuid)',
  'public.assert_center_limit(uuid,text,integer,text)',
  'public.teachers_check_limit()',
  'public.students_check_limit()',
  'public.lesson_notes_approval_transition()',
  'public.clinical_check_lesson_participant()',
  'public.goals_student_immutable()',
  'public.arm_voice_request(text,bigint)',
  'public.report_voice_note(bigint,text,integer)',
  'public.ai_job_begin(bigint)',
  'public.ai_job_finish(bigint)',
  'public.ai_job_fail(bigint,text)',
  'public.ai_usage_record(bigint,text,text,integer,integer,integer,text)',
  'public.ai_write_lesson_note(bigint,jsonb)',
  'public.lesson_note_goal_scores_check_student()',
  'public.notification_log_transition()',
  'public.notification_log_subject_required()',
  'public.center_write_state(uuid)',
  'public.export_center_excluded_tables()',
  'public.booking_published(uuid)',
  'public.notification_front_desk_targets(uuid,text)',
  'public.booking_center_info(text)',
  'public.booking_teacher_busy(text,uuid,date)',
  'public.submit_booking_request(text,uuid,uuid,timestamptz,text,text,text)',
  'public.report_period_check(date,date)',
  'public.ai_model_rates()',
  'public.assistant_intents_for(text)',
  'public.center_ai_questions_used(uuid)',
  'public.assistant_questions_reserved(uuid)',
  'public.diagnostic_set_details(uuid,uuid,text[],jsonb)'
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
    ('assistant_begin()'),
    ('assistant_finish(uuid,text,text,text,integer,integer,text)'),
    ('assistant_quota()'),
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
    ('create_invitation(text,text,text,text,uuid,uuid)'),
    ('create_lesson_series(jsonb)'),
    ('create_lesson_series_preview(jsonb)'),
    ('create_student_with_payer(text,uuid,text,text,text,date,text,uuid,text,text,text)'),
    ('set_funnel_stage(uuid,text,text,boolean)'),
    ('funnel_summary(date,date)'),
    ('global_search(text,integer)'),
    ('funnel_stuck(integer)'),
    ('current_center()'),
    ('emit_event(text,jsonb,uuid)'),
    ('find_payer_by_phone(text)'),
    ('has_feature(text)'),
    ('invitation_preview(text)'),
    ('is_member(uuid)'),
    ('link_parent_payer(uuid,uuid)'),
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
    ('export_payments(date,date)'),
    ('export_salary_summary(date)'),
    ('export_salary_details(date)'),
    ('export_attendance(date,date)'),
    ('export_debts()'),
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
    ('student_subscriptions_overdue()'),
    ('revenue_facts()'),
    ('month_open_lessons_count(date)'),
    ('create_telegram_link_code()'),
    ('unlink_telegram()'),
    ('payer_telegram_linked(uuid)'),
    ('preview_message(text,jsonb)'),
    ('upsert_message_template(text,text,text,boolean)'),
    ('reset_message_template(text,text)'),
    ('clinical_teacher_sees(uuid)'),
    ('clinical_goal_visible(uuid)'),
    ('clinical_role_allowed(text)'),
    ('request_voice_note(uuid,uuid)'),
    ('ai_usage_summary(date,date)'),
    ('student_attendance_brief(uuid,date,date)'),
    ('student_goal_dynamics_brief(uuid,date,date)'),
    ('student_monthly_report(uuid,date)'),
    ('send_monthly_report(uuid,date,text,boolean)'),
    ('clinical_homework_visible(uuid)'),
    ('clinical_visible_to_caller(uuid)'),
    ('student_diagnostics_brief(uuid)'),
    ('student_goals_brief(uuid)'),
    ('student_notes_brief(uuid)'),
    ('is_platform_admin()'),
    ('center_limits()'),
    ('submit_platform_payment(text,integer,text,text)'),
    ('withdraw_platform_payment(uuid)'),
    ('reject_platform_payment(uuid,text)'),
    ('extend_subscription(uuid,text,integer,integer,boolean)'),
    ('platform_open_payments()'),
    ('platform_centers()'),
    ('platform_summary()'),
    ('platform_create_center(text,text,text)'),
    ('record_diagnostic(uuid,text,jsonb,jsonb,date,uuid,text,text[],jsonb)'),
    ('update_diagnostic(uuid,text,jsonb,jsonb,date,text,text[],jsonb)'),
    ('archive_diagnostic(uuid)'),
    ('clinical_diagnostic_visible(uuid)'),
    ('student_conclusions()'),
    ('export_center_lookups()'),
    ('suggest_speech_conclusion(jsonb)'),
    ('student_alive(uuid)'),
    ('clinical_student_visible(uuid)'),
    ('set_student_anamnesis(uuid,jsonb,timestamp with time zone)'),
    ('student_primary_teacher(uuid)'),
    ('set_student_articulation(uuid,jsonb,timestamp with time zone)'),
    ('record_syllable_assessment(uuid,date,uuid,text[],text[],text)'),
    ('update_syllable_assessment(uuid,date,text[],text[],text,timestamp with time zone)'),
    ('archive_syllable_assessment(uuid)'),
    ('record_prosody_assessment(uuid,date,uuid,text,text,text,text,text,text,text)'),
    ('update_prosody_assessment(uuid,date,text,text,text,text,text,text,text,timestamp with time zone)'),
    ('archive_prosody_assessment(uuid)'),
    ('record_reading_writing_assessment(uuid,date,uuid,text,text,text,text[],text,text[],text)'),
    ('update_reading_writing_assessment(uuid,date,text,text,text,text[],text,text[],text,timestamp with time zone)'),
    ('archive_reading_writing_assessment(uuid)'),
    ('create_goal(uuid,uuid,text,text,text,date)'),
    ('update_goal(uuid,text,text,text,uuid,date)'),
    ('set_goal_status(uuid,text)'),
    ('archive_goal(uuid)'),
    ('record_goal_progress(uuid,integer,text,uuid,date,uuid)'),
    ('update_goal_progress(uuid,integer,text)'),
    ('archive_goal_progress(uuid)'),
    ('assign_homework(uuid,text,uuid[],uuid,date,uuid)'),
    ('update_homework(uuid,date,text,uuid[])'),
    ('submit_homework(uuid,text)'),
    ('review_homework(uuid,text)'),
    ('archive_homework(uuid)'),
    ('write_lesson_note(uuid,uuid,jsonb,text,uuid)'),
    ('approve_lesson_note(uuid)'),
    ('archive_lesson_note(uuid)'),
    ('complete_lesson(uuid,jsonb)'),
    ('save_exercise(text,uuid,text,text,text,text,text,integer,integer,text[],boolean)'),
    ('export_center_tables()'),
    ('export_center_table(text)'),
    ('export_center_audit(date,date)'),
    ('record_center_export()'),
    ('export_center_info()'),
    ('my_memberships()'),
    ('request_center_deletion(text)'),
    ('cancel_center_deletion()'),
    ('center_deletion_state()'),
    ('set_booking_enabled(boolean)'),
    ('booking_request_payer_match(uuid)'),
    ('confirm_booking_request(uuid,uuid)'),
    ('decline_booking_request(uuid,text)')
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
