-- pgTAP: роли registrar/finance, шаг 1 — чеки, предикаты, RPC стойки (0026).
-- Членства с новыми ролями сеются от postgres: лестница назначений до 0028
-- их не пускает (и это здесь тоже проверяется).
-- До 0028 у registrar нет ни одной политики на чтение: любой select из
-- базовой таблицы под его ролью — ноль строк. Поэтому идентификаторы,
-- которые RPC не возвращает (series_id, id строки рассрочки), берутся от
-- postgres в t_ins, а проверки состояния идут после reset role.
-- Даты занятий фиксированы (2027-03), не now(). Claims — явно перед каждым
-- блоком: reset role их не сбрасывает.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(69);

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
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','registrar-b@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','nobody@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-roles','{}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-roles','{}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист А'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Специалист А-2');

insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner', null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a','registrar', null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','finance', null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001'),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000b','registrar', null);

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик А','+996700000001');

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок 1','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Ребёнок 2','dddddddd-0000-0000-0000-000000000001');

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','8 занятий','lessons',8,400000);

-- L0 — прошедшее (отметка и закрытие registrar), L1 — перенос/замена/отмена,
-- L2 — отпуск, L3 — прошедшее для собственной отметки специалиста,
-- L4 — запланированное для попыток NULL-роли (остаётся planned).
insert into public.lessons (id, center_id, teacher_id, student_id, starts_at, ends_at) values
  ('ffffffff-0000-0000-0000-000000000000','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2026-09-01 10:00+06','2026-09-01 10:45+06'),
  ('ffffffff-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2027-03-03 10:00+06','2027-03-03 10:45+06'),
  ('ffffffff-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2027-03-04 10:00+06','2027-03-04 10:45+06'),
  ('ffffffff-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2026-09-02 10:00+06','2026-09-02 10:45+06'),
  ('ffffffff-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','2027-03-10 10:00+06','2027-03-10 10:45+06');

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


-- 1-3. Чеки и лестница ----------------------------------------------------------------

select is(
  (select role from public.memberships where user_id = '22222222-2222-2222-2222-222222222222'),
  'registrar', 'memberships_role_check принимает registrar (и finance — строка выше вставилась)'
);
select lives_ok(
  $q$ insert into public.invitations (center_id, role, token)
      values ('cccccccc-0000-0000-0000-00000000000a', 'finance', 'tok-0026-finance') $q$,
  'invitations_role_check принимает finance'
);

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_like(
  $q$ select public.change_member_role('44444444-4444-4444-4444-444444444444', 'registrar') $q$,
  'Неизвестная роль%', 'Лестница до 0028 не назначает registrar — роль существует только в чеке'
);
reset role;


-- 4-10. Предикаты ---------------------------------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select ok(public.can_front_desk() and not public.can_finance() and public.can_payments(),
  'registrar: стойка и платежи — да, финансы сотрудников — нет');
select ok(
  not public.can_front_desk('cccccccc-0000-0000-0000-00000000000b')
  and not public.can_finance('cccccccc-0000-0000-0000-00000000000b')
  and not public.can_payments('cccccccc-0000-0000-0000-00000000000b'),
  'Предикаты с явным чужим центром — все false');
select ok(not public.can_payments(null), 'can_payments(NULL) — false, не NULL');
reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select ok(not public.can_front_desk() and public.can_finance() and public.can_payments(),
  'finance: финансы и платежи — да, стойка — нет');
reset role;

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select ok(not public.can_front_desk() and not public.can_finance() and not public.can_payments(),
  'teacher: ни один предикат');
reset role;

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select ok(not public.can_front_desk() and not public.can_finance() and not public.can_payments(),
  'Без членства (role_in NULL): везде false, не NULL');
reset role;

select ok(
  has_function_privilege('authenticated', 'public.can_front_desk(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.can_payments(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.can_finance(uuid)', 'EXECUTE'),
  'Предикаты исполняет authenticated, anon — нет'
);


-- 11-34. Стойка под registrar: сквозной сценарий ------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- Ученики и плательщики.
insert into t_ins
  select 'new_student', student_id from public.create_student_with_payer(
    'Ребёнок Новый', null, 'Плательщик Новый', '+996700000009');
select ok((select id is not null from t_ins where name = 'new_student'),
  'create_student_with_payer — registrar');
select is(
  (select count(*)::int from public.find_payer_by_phone('+996700000009')), 1,
  'find_payer_by_phone — registrar');
select is(public.payer_display_name('dddddddd-0000-0000-0000-000000000001'), 'Плательщик А',
  'payer_display_name — registrar видит ФИО');
select lives_ok(
  $q$ select public.archive_student('eeeeeeee-0000-0000-0000-000000000002') $q$,
  'archive_student — registrar');
select lives_ok(
  $q$ select public.restore_student('eeeeeeee-0000-0000-0000-000000000002') $q$,
  'restore_student — registrar');

-- Серия: create_lesson_series → preview → lesson_slot_conflicts внутри.
insert into t_ins
  select 'series_lesson', lesson_id from public.create_lesson_series(jsonb_build_object(
    'teacher_id', 'aaaaaaaa-0000-0000-0000-000000000001',
    'student_id', 'eeeeeeee-0000-0000-0000-000000000001',
    'first_date', '2027-03-08', 'until', '2027-03-15', 'time', '10:00', 'weekdays', '[1]'::jsonb))
  limit 1;

reset role;

-- series_id RPC не возвращает — от postgres.
insert into t_ins
  select 'series', series_id from public.lessons where id = (select id from t_ins where name = 'series_lesson');
select is(
  (select count(*)::int from public.lessons where series_id = (select id from t_ins where name = 'series')),
  2, 'create_lesson_series — registrar, две встречи');

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  public.cancel_series_from((select id from t_ins where name = 'series'), '2027-03-15'),
  1, 'cancel_series_from — registrar, отменена одна');
select is(
  (select count(*)::int from public.teacher_vacation_preview('aaaaaaaa-0000-0000-0000-000000000001', '2027-03-04', '2027-03-04')),
  1, 'teacher_vacation_preview — registrar видит занятие в отпуске');
select is(
  public.teacher_vacation('aaaaaaaa-0000-0000-0000-000000000001', '2027-03-04', '2027-03-04'),
  1, 'teacher_vacation — registrar');
select lives_ok(
  $q$ select public.substitute_teacher('ffffffff-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002') $q$,
  'substitute_teacher — registrar');
select lives_ok(
  $q$ select public.reschedule_lesson('ffffffff-0000-0000-0000-000000000001', '2027-03-03 11:00+06', '2027-03-03 11:45+06') $q$,
  'reschedule_lesson (+lesson_slot_conflicts) — registrar');
select lives_ok(
  $q$ select public.cancel_lesson('ffffffff-0000-0000-0000-000000000001', 'тест') $q$,
  'cancel_lesson — registrar');
select lives_ok(
  $q$ select public.mark_attendance('ffffffff-0000-0000-0000-000000000000', 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  'mark_attendance — registrar');
select lives_ok(
  $q$ select public.mark_lesson_status('ffffffff-0000-0000-0000-000000000000', 'done') $q$,
  'mark_lesson_status — registrar (последнее определение — 0026, не 0025)');

-- Абонементы и платежи.
insert into t_ins values ('sub1', public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001'));
select ok((select id is not null from t_ins where name = 'sub1'), 'sell_subscription — registrar');
select lives_ok(
  $q$ select public.freeze_subscription((select id from t_ins where name = 'sub1'),
        public.center_today('cccccccc-0000-0000-0000-00000000000a')) $q$,
  'freeze_subscription (+subscription_state → subscription_visible_to_caller) — registrar');
select lives_ok(
  $q$ select public.unfreeze_subscription((select id from t_ins where name = 'sub1')) $q$,
  'unfreeze_subscription — registrar');
select is(
  (select state from public.subscription_summary((select id from t_ins where name = 'sub1'))),
  'active', 'subscription_summary — registrar');
select lives_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 50000, 'payment',
        'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src)) $q$,
  'record_payment — registrar');
insert into t_ins values ('sub2', public.transfer_remaining((select id from t_ins where name = 'sub1'), 'eeeeeeee-0000-0000-0000-000000000002'));
select ok((select id is not null from t_ins where name = 'sub2'), 'transfer_remaining — registrar');

-- Продажа с рассрочкой (sell_subscription_paid → sell_subscription,
-- record_payment, create_installment_plan).
create temporary table t_sale as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
    '55550000-0000-0000-0000-000000000026', null, null, 100000, (select id from t_src), null, 3);
select is((select count(*)::int from t_sale), 3, 'sell_subscription_paid с рассрочкой — registrar, три строки');

reset role;

-- id строки рассрочки — от postgres (installments под registrar не читается).
insert into t_ins
  select 'inst1', i.id from public.installments i
   where i.subscription_id = (select subscription_id from t_sale limit 1) and i.seq = 1;

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select lives_ok(
  $q$ select public.pay_installment((select id from t_ins where name = 'inst1'), (select id from t_src)) $q$,
  'pay_installment (→ record_payment) — registrar');
select is(
  public.cancel_installment_plan((select subscription_id from t_sale limit 1)),
  2, 'cancel_installment_plan — registrar, внутренняя installment_plans_cancel_live пропустила (было бы 42501)');

-- Возврат с живой рассрочкой: триггер subscriptions_cancel_installments зовёт
-- ту же внутреннюю функцию. Ожидаемая сумма — из subscription_summary (Р6):
-- refund_calc — invoker и под registrar отдаёт NULL.
create temporary table t_sale2 as
  select * from public.sell_subscription_paid(
    '77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000002',
    '55550000-0000-0000-0000-000000000027', null, null, null, null, null, 2);
select is(public.refund_calc((select subscription_id from t_sale2 limit 1)), null::integer,
  'refund_calc (invoker) под registrar — NULL до 0028: путь к сумме только subscription_summary (Р6)');
select lives_ok(
  $q$ select public.refund_subscription((select subscription_id from t_sale2 limit 1),
        (select refund_tiyin from public.subscription_summary((select subscription_id from t_sale2 limit 1)))) $q$,
  'refund_subscription с живой рассрочкой — registrar: триггерный installment_plans_cancel_live пропустил');

reset role;

select is(
  (select count(*)::int from public.installment_plans p
    where p.subscription_id = (select subscription_id from t_sale2 limit 1) and p.cancelled_at is not null),
  1, 'План погашен возвратом');


-- 35-45. finance: платежи и рассрочки — да, стойка и жизненный цикл абонемента — нет ------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 10000, 'payment',
        'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src)) $q$,
  'record_payment — finance');
select is(public.payer_display_name('dddddddd-0000-0000-0000-000000000001'), 'Плательщик А',
  'payer_display_name — finance видит ФИО плательщика');
select is(
  (select state from public.subscription_summary((select id from t_ins where name = 'sub2'))),
  'active', 'subscription_summary — finance');
select throws_ok(
  $q$ select public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', null, 'sell_subscription — finance не продаёт');
select throws_ok(
  $q$ select * from public.create_student_with_payer('Чужой', null, 'П', '+996700000010') $q$,
  '42501', null, 'create_student_with_payer — finance нет');
select throws_ok(
  $q$ select public.cancel_lesson('ffffffff-0000-0000-0000-000000000004') $q$,
  '42501', null, 'cancel_lesson — finance нет');
select throws_ok(
  $q$ select public.mark_attendance('ffffffff-0000-0000-0000-000000000000', 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', null, 'mark_attendance — finance нет');
select throws_ok(
  $q$ select public.freeze_subscription((select id from t_ins where name = 'sub2'), '2027-01-01') $q$,
  '42501', null, 'freeze_subscription — finance нет');
select throws_ok(
  $q$ select public.refund_subscription((select id from t_ins where name = 'sub2'), 0) $q$,
  '42501', null, 'refund_subscription — finance не гасит абонемент (Р7)');
select throws_ok(
  $q$ select public.transfer_remaining((select id from t_ins where name = 'sub2'), 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', null, 'transfer_remaining — finance нет');
select is(
  (select count(*)::int from public.teacher_vacation_preview('aaaaaaaa-0000-0000-0000-000000000001', '2027-03-01', '2027-03-31')),
  0, 'teacher_vacation_preview — finance получает пустой набор (предикат в where, не исключение)');
reset role;


-- 46-49. teacher: как раньше ----------------------------------------------------------------

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 10000, 'payment') $q$,
  '42501', null, 'record_payment — teacher нет');
select throws_ok(
  $q$ select public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', null, 'sell_subscription — teacher нет');
select lives_ok(
  $q$ select public.mark_attendance('ffffffff-0000-0000-0000-000000000003', 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  'mark_attendance на своём занятии — teacher по-прежнему может');
select is(public.payer_display_name('dddddddd-0000-0000-0000-000000000001'), null,
  'payer_display_name — teacher без закреплённого ребёнка получает NULL, как раньше');
reset role;


-- 50-52. Чужой центр --------------------------------------------------------------------------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select throws_ok(
  $q$ select public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42704', null, 'registrar Б по типу центра А — 42704');
select throws_ok(
  $q$ select public.cancel_lesson('ffffffff-0000-0000-0000-000000000004') $q$,
  '42704', null, 'registrar Б по занятию центра А — не найдено');
select throws_ok(
  $q$ select public.cancel_installment_plan((select id from t_ins where name = 'sub2')) $q$,
  '42704', null, 'registrar Б по абонементу центра А — не найден');
reset role;


-- 53-61. NULL-роль (членство отозвано, JWT старый) ---------------------------------------------

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.mark_lesson_status('ffffffff-0000-0000-0000-000000000004', 'done') $q$,
  '42501', null, 'mark_lesson_status done без членства — отказ');
select throws_ok(
  $q$ select public.mark_lesson_status('ffffffff-0000-0000-0000-000000000004', 'cancelled') $q$,
  '42501', null, 'mark_lesson_status cancelled без членства — отказ');
select throws_ok(
  $q$ select public.mark_lesson_status('ffffffff-0000-0000-0000-000000000004', 'planned') $q$,
  '42501', null, 'mark_lesson_status planned без членства — отказ');
select throws_ok(
  $q$ select public.mark_attendance('ffffffff-0000-0000-0000-000000000004', 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', null, 'mark_attendance без членства — отказ (not (false or NULL) закрыт coalesce)');
select throws_ok(
  $q$ select public.sell_subscription('77777777-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', null, 'sell_subscription без членства — отказ');
select throws_ok(
  $q$ select public.record_payment('dddddddd-0000-0000-0000-000000000001', 10000, 'payment') $q$,
  '42501', null, 'record_payment без членства — отказ');
select throws_ok(
  $q$ select public.cancel_installment_plan((select id from t_ins where name = 'sub2')) $q$,
  '42501', null, 'cancel_installment_plan без членства — отказ');
select is(
  (select count(*)::int from public.teacher_vacation_preview('aaaaaaaa-0000-0000-0000-000000000001', '2027-03-01', '2027-03-31')),
  0, 'teacher_vacation_preview без членства — пусто');
reset role;

select is(
  (select status from public.lessons where id = 'ffffffff-0000-0000-0000-000000000004'), 'planned',
  'L4 не тронуто ни одной попыткой NULL-роли (событие пишется только на cancelled — откат сам по себе не доказательство)'
);


-- 62-67. Гранты внутренних функций и итог сценария -------------------------------------------

select ok(
  not has_function_privilege('authenticated', 'public.lesson_slot_conflicts(uuid,uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid)', 'EXECUTE'),
  'lesson_slot_conflicts по-прежнему закрыта для authenticated'
);
select ok(
  not has_function_privilege('service_role', 'public.installment_plans_cancel_live(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.installment_plans_cancel_live(uuid)', 'EXECUTE'),
  'installment_plans_cancel_live закрыта для service_role и authenticated'
);
select ok(
  not has_function_privilege('authenticated', 'public.subscription_visible_to_caller(uuid)', 'EXECUTE'),
  'subscription_visible_to_caller без гранта — как в 0015, не регрессия'
);
select is(
  (select status from public.lessons where id = 'ffffffff-0000-0000-0000-000000000000'), 'done',
  'L0 закрыто registrar'
);
select is(
  (select status from public.lessons where id = 'ffffffff-0000-0000-0000-000000000002'), 'cancelled',
  'L2 отменено отпуском'
);
select is(
  (select count(*)::int from public.events where type = 'lesson.cancelled'), 2,
  'Два lesson.cancelled: cancel_series_from и cancel_lesson (отпуск пишет teacher.vacation) — и ничего от отказов'
);

select * from finish();

rollback;
