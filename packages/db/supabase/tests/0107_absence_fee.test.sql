-- pgTAP: штраф за пропуск (0107, этап 16).
--
-- Р1 статус со штрафом (check, грант); Р2 штраф не трогает абонемент, круги
-- смены статуса идемпотентны; Р3 база — снимок цены, 0 — штрафа нет; Р4 штраф
-- в счёте долга; Р6 отмена только владельцем и держится; подделка суммы.
-- reset role не сбрасывает claims — tests_claims явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(37);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('01070000-0000-0000-0000-0000000000a' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0107@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 3) n;

insert into public.centers (id, name, slug, settings) values
  ('01070000-0000-0000-0000-0000000000c1', 'Центр 0107', 'centr-0107', '{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.teachers (id, center_id, full_name) values
  ('01070000-0000-0000-0000-0000000000b1', '01070000-0000-0000-0000-0000000000c1', 'Специалист 0107');
insert into public.payers (id, center_id, full_name, phone) values
  ('01070000-0000-0000-0000-0000000000d1', '01070000-0000-0000-0000-0000000000c1', 'Мама 0107', '+996700010701');
insert into public.students (id, center_id, full_name, payer_id) values
  ('01070000-0000-0000-0000-000000000e01', '01070000-0000-0000-0000-0000000000c1', 'Аня 0107', '01070000-0000-0000-0000-0000000000d1'),
  ('01070000-0000-0000-0000-000000000e02', '01070000-0000-0000-0000-0000000000c1', 'Боря 0107', '01070000-0000-0000-0000-0000000000d1');

-- 1 owner · 2 admin · 3 teacher.
insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('01070000-0000-0000-0000-0000000000a1', '01070000-0000-0000-0000-0000000000c1', 'owner',   null),
  ('01070000-0000-0000-0000-0000000000a2', '01070000-0000-0000-0000-0000000000c1', 'admin',   null),
  ('01070000-0000-0000-0000-0000000000a3', '01070000-0000-0000-0000-0000000000c1', 'teacher', '01070000-0000-0000-0000-0000000000b1');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('01070000-0000-0000-0000-0000000005e1', '01070000-0000-0000-0000-0000000000c1', 'Логопед 0107', 100000),
  ('01070000-0000-0000-0000-0000000005e2', '01070000-0000-0000-0000-0000000000c1', 'Бесплатно 0107', 0);

insert into public.attendance_statuses (center_id, code, name, color, deducts_lesson, pays_teacher, counts_absence, sort, fee_percent)
values ('01070000-0000-0000-0000-0000000000c1', 'late_cancel', 'Предупредил поздно', 'amber', false, false, true, 33, 50);

insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin,
                                  starts_at, ends_at, allow_negative, lessons_used) values
  ('01070000-0000-0000-0000-0000000055a1', '01070000-0000-0000-0000-0000000000c1', '01070000-0000-0000-0000-000000000e01',
   '01070000-0000-0000-0000-0000000000d1', 8, 400000, 50000, current_date - 30, current_date + 60, false, 0);

-- L1..L4 Ани (услуга с ценой), L5 Бори (бесплатная услуга).
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at)
select x.id::uuid, '01070000-0000-0000-0000-0000000000c1', '01070000-0000-0000-0000-0000000000b1', x.svc::uuid, x.st::uuid, 'planned',
       date_trunc('hour', now()) - interval '3 days' + x.h * interval '1 hour',
       date_trunc('hour', now()) - interval '3 days' + x.h * interval '1 hour' + interval '45 minutes'
  from (values
    ('01070000-0000-0000-0000-000000000101', '01070000-0000-0000-0000-0000000005e1', '01070000-0000-0000-0000-000000000e01', 1),
    ('01070000-0000-0000-0000-000000000102', '01070000-0000-0000-0000-0000000005e1', '01070000-0000-0000-0000-000000000e01', 2),
    ('01070000-0000-0000-0000-000000000103', '01070000-0000-0000-0000-0000000005e1', '01070000-0000-0000-0000-000000000e01', 3),
    ('01070000-0000-0000-0000-000000000104', '01070000-0000-0000-0000-0000000005e1', '01070000-0000-0000-0000-000000000e01', 4),
    ('01070000-0000-0000-0000-000000000105', '01070000-0000-0000-0000-0000000005e2', '01070000-0000-0000-0000-000000000e02', 5)
  ) x(id, svc, st, h);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create or replace function public.tests_mark(p_lesson uuid, p_student uuid, p_code text)
  returns void language sql as $$
  insert into public.attendance (center_id, lesson_id, student_id, status_id)
  values ('01070000-0000-0000-0000-0000000000c1', p_lesson, p_student,
          (select s.id from public.attendance_statuses s
            where s.center_id = '01070000-0000-0000-0000-0000000000c1' and s.code = p_code and s.deleted_at is null))
  on conflict (lesson_id, student_id) do update set status_id = excluded.status_id;
$$;

create or replace function public.tests_att(p_lesson uuid)
  returns public.attendance language sql as $$
  select a.* from public.attendance a where a.lesson_id = p_lesson;
$$;

create or replace function public.tests_accrued(p_student uuid)
  returns integer language sql as $$
  select coalesce((select x.accrued_tiyin from public.lesson_debt_accounts_unchecked('01070000-0000-0000-0000-0000000000c1', p_student) x), 0);
$$;

create or replace function public.tests_used()
  returns integer language sql as $$
  select lessons_used from public.subscriptions where id = '01070000-0000-0000-0000-0000000055a1';
$$;


-- 2. Статус со штрафом (Р1) -----------------------------------------------------------------------

select throws_ok($$ update public.attendance_statuses set fee_percent = 50
  where center_id = '01070000-0000-0000-0000-0000000000c1' and code = 'absent' $$, '23514', null, 'Штраф у списывающего статуса — check');
select throws_ok($$ update public.attendance_statuses set fee_percent = 50
  where center_id = '01070000-0000-0000-0000-0000000000c1' and code = 'present' $$, '23514', null, 'Штраф у «Пришёл» — check');
select throws_ok($$ update public.attendance_statuses set fee_percent = 0
  where center_id = '01070000-0000-0000-0000-0000000000c1' and code = 'sick' $$, '23514', null, 'Штраф 0% — check (пусто, а не ноль)');
select throws_ok($$ update public.attendance_statuses set deducts_lesson = true
  where center_id = '01070000-0000-0000-0000-0000000000c1' and code = 'late_cancel' $$, '23514', null,
  'Включить списание у штрафного статуса — check');
select ok(has_column_privilege('authenticated', 'public.attendance_statuses', 'fee_percent', 'UPDATE'),
  'Штраф правится из «Статусов посещения» (колоночный грант)');
select ok(not has_column_privilege('authenticated', 'public.attendance', 'fee_tiyin', 'UPDATE')
          and not has_column_privilege('authenticated', 'public.attendance', 'fee_cancelled_at', 'UPDATE'),
  'Сумму и отмену штрафа клиент напрямую не пишет');


-- 3. Отметка со штрафом (Р2, Р3, Р4) --------------------------------------------------------------

select public.tests_claims('01070000-0000-0000-0000-0000000000a1', '01070000-0000-0000-0000-0000000000c1');
select public.tests_mark('01070000-0000-0000-0000-000000000101', '01070000-0000-0000-0000-000000000e01', 'late_cancel');
select ok(
  (select not a.deducted and a.fee_tiyin = 25000 and a.price_tiyin = 50000 from public.tests_att('01070000-0000-0000-0000-000000000101') a),
  'Штраф 50% от цены занятия в абонементе (500 → 250 сом); занятие не списано');
select is(public.tests_used(), 0, 'Абонемент не тронут');
select is(public.tests_accrued('01070000-0000-0000-0000-000000000e01'), 25000, 'Штраф в счёте долга семьи');

-- «штраф → Болел → штраф» — та же сумма, без 50% от 50%.
select public.tests_mark('01070000-0000-0000-0000-000000000101', '01070000-0000-0000-0000-000000000e01', 'sick');
select is((public.tests_att('01070000-0000-0000-0000-000000000101')).fee_tiyin, 0, '«Болел» — штрафа нет');
select public.tests_mark('01070000-0000-0000-0000-000000000101', '01070000-0000-0000-0000-000000000e01', 'late_cancel');
select is((public.tests_att('01070000-0000-0000-0000-000000000101')).fee_tiyin, 25000, 'Обратно штраф — та же сумма');

-- «Пришёл → штраф → Пришёл» — тот же абонемент.
select public.tests_mark('01070000-0000-0000-0000-000000000102', '01070000-0000-0000-0000-000000000e01', 'present');
select is(public.tests_used(), 1, '«Пришёл» списал занятие');
select public.tests_mark('01070000-0000-0000-0000-000000000102', '01070000-0000-0000-0000-000000000e01', 'late_cancel');
select ok(
  (select not a.deducted and a.fee_tiyin = 25000 from public.tests_att('01070000-0000-0000-0000-000000000102') a)
  and public.tests_used() = 0,
  'Исправили на штраф — занятие вернулось в абонемент, штраф по цене занятия');
select public.tests_mark('01070000-0000-0000-0000-000000000102', '01070000-0000-0000-0000-000000000e01', 'present');
select ok(
  (select a.subscription_id = '01070000-0000-0000-0000-0000000055a1' and a.deducted and a.fee_tiyin = 0
     from public.tests_att('01070000-0000-0000-0000-000000000102') a)
  and public.tests_used() = 1,
  'Обратно «Пришёл» — тот же абонемент, штрафа нет');

-- База 0 — штрафа нет, отметка проходит.
select lives_ok(
  $$ select public.tests_mark('01070000-0000-0000-0000-000000000105', '01070000-0000-0000-0000-000000000e02', 'late_cancel') $$,
  'Бесплатная услуга без абонемента — отметка проходит');
select is((public.tests_att('01070000-0000-0000-0000-000000000105')).fee_tiyin, 0, 'База 0 — штраф 0');

-- Подделка суммы при прямой вставке.
set local role authenticated;
select lives_ok(
  $$ insert into public.attendance (center_id, lesson_id, student_id, status_id, fee_tiyin)
     values ('01070000-0000-0000-0000-0000000000c1', '01070000-0000-0000-0000-000000000103', '01070000-0000-0000-0000-000000000e01',
             (select id from public.attendance_statuses where center_id = '01070000-0000-0000-0000-0000000000c1' and code = 'present'),
             99999) $$,
  'Владелец вставляет отметку «Пришёл» с выдуманным штрафом');
select is((public.tests_att('01070000-0000-0000-0000-000000000103')).fee_tiyin, 0, 'Сумма штрафа перетёрта триггером');
reset role;


-- 4. Метка панели --------------------------------------------------------------------------------

select public.tests_mark('01070000-0000-0000-0000-000000000104', '01070000-0000-0000-0000-000000000e01', 'late_cancel');
select public.tests_claims('01070000-0000-0000-0000-0000000000a1', '01070000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select row(b.kind, b.price_tiyin)::text from public.lesson_attendance_balances('01070000-0000-0000-0000-000000000104') b),
  '(fee,25000)', 'Панель: вид fee и сумма штрафа — стойке');
reset role;
select public.tests_claims('01070000-0000-0000-0000-0000000000a3', '01070000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select row(b.kind, b.price_tiyin)::text from public.lesson_attendance_balances('01070000-0000-0000-0000-000000000104') b),
  '(fee,)', 'Специалисту — вид без суммы');
reset role;


-- 5. Отмена штрафа (Р6) --------------------------------------------------------------------------

select public.tests_claims('01070000-0000-0000-0000-0000000000a2', '01070000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.cancel_attendance_fee((public.tests_att('01070000-0000-0000-0000-000000000101')).id, 'ошибка') $$,
  '42501', null, 'Админ штраф не отменяет');
reset role;

select public.tests_claims('01070000-0000-0000-0000-0000000000a1', '01070000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.cancel_attendance_fee((public.tests_att('01070000-0000-0000-0000-000000000101')).id, ' ') $$,
  '22023', null, 'Без причины — отказ');
select lives_ok($$ select public.cancel_attendance_fee((public.tests_att('01070000-0000-0000-0000-000000000101')).id, 'уважительная причина') $$,
  'Владелец отменяет штраф');
reset role;
select is(public.tests_accrued('01070000-0000-0000-0000-000000000e01'), 25000,
  'Отменённый штраф ушёл из долга — остался только штраф за L4');

select public.tests_claims('01070000-0000-0000-0000-0000000000a1', '01070000-0000-0000-0000-0000000000c1');
select public.tests_mark('01070000-0000-0000-0000-000000000101', '01070000-0000-0000-0000-000000000e01', 'sick');
select public.tests_mark('01070000-0000-0000-0000-000000000101', '01070000-0000-0000-0000-000000000e01', 'late_cancel');
select ok((select a.fee_cancelled_at is not null from public.tests_att('01070000-0000-0000-0000-000000000101') a),
  'Отмена держится при смене статуса туда-обратно');

-- Р9: отмену держит триггер, а не только грант — не-владелец не снимет её даже
-- в обход колоночного гранта (superuser, claims админа).
select public.tests_claims('01070000-0000-0000-0000-0000000000a2', '01070000-0000-0000-0000-0000000000c1');
update public.attendance set fee_cancelled_at = null, fee_cancelled_by = null, fee_cancel_reason = null
 where lesson_id = '01070000-0000-0000-0000-000000000101';
select ok((select a.fee_cancelled_at is not null from public.tests_att('01070000-0000-0000-0000-000000000101') a),
  'Админ в обход гранта отмену не снимает — триггер вернул');

select public.tests_claims('01070000-0000-0000-0000-0000000000a3', '01070000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok($$ select public.restore_attendance_fee((public.tests_att('01070000-0000-0000-0000-000000000101')).id) $$,
  '42501', null, 'Специалист штраф не возвращает');
reset role;

select public.tests_claims('01070000-0000-0000-0000-0000000000a1', '01070000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok($$ select public.restore_attendance_fee((public.tests_att('01070000-0000-0000-0000-000000000101')).id) $$,
  'Владелец возвращает ошибочно отменённый штраф');
reset role;
select public.tests_claims('01070000-0000-0000-0000-0000000000a1', '01070000-0000-0000-0000-0000000000c1');
select is(public.tests_accrued('01070000-0000-0000-0000-000000000e01'), 50000, 'Возвращённый штраф снова в долге');

set local role authenticated;
select throws_ok($$ select public.cancel_attendance_fee((public.tests_att('01070000-0000-0000-0000-000000000102')).id, 'нет штрафа') $$,
  '22023', null, 'Отметка без штрафа — отказ');
select throws_ok($$ select public.cancel_attendance_fee(gen_random_uuid(), 'нет отметки') $$,
  '42704', null, 'Чужая или несуществующая отметка — не найдена');
select lives_ok($$ select public.cancel_attendance_fee((public.tests_att('01070000-0000-0000-0000-000000000101')).id, 'снова') $$,
  'Повторная отмена после возврата');
select lives_ok($$ select public.cancel_attendance_fee((public.tests_att('01070000-0000-0000-0000-000000000101')).id, 'ещё раз') $$,
  'Отмена уже отменённого — молча');
reset role;
select public.tests_claims('01070000-0000-0000-0000-0000000000a1', '01070000-0000-0000-0000-0000000000c1');
select is((public.tests_att('01070000-0000-0000-0000-000000000101')).fee_cancel_reason, 'снова',
  'Повторная отмена причину не перезаписывает');

-- Р9: безлимит — база 0 при любом порядке кликов (как в списывающей ветке).
insert into public.students (id, center_id, full_name, payer_id) values
  ('01070000-0000-0000-0000-000000000e03', '01070000-0000-0000-0000-0000000000c1', 'Вера 0107', '01070000-0000-0000-0000-0000000000d1');
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin,
                                  starts_at, ends_at, allow_negative, lessons_used) values
  ('01070000-0000-0000-0000-0000000055a3', '01070000-0000-0000-0000-0000000000c1', '01070000-0000-0000-0000-000000000e03',
   '01070000-0000-0000-0000-0000000000d1', null, 300000, null, current_date - 30, current_date + 60, false, 0);
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, status, starts_at, ends_at)
select x.id::uuid, '01070000-0000-0000-0000-0000000000c1', '01070000-0000-0000-0000-0000000000b1',
       '01070000-0000-0000-0000-0000000005e1', '01070000-0000-0000-0000-000000000e03', 'planned',
       date_trunc('hour', now()) - interval '3 days' + x.h * interval '1 hour',
       date_trunc('hour', now()) - interval '3 days' + x.h * interval '1 hour' + interval '45 minutes'
  from (values ('01070000-0000-0000-0000-000000000106', 6), ('01070000-0000-0000-0000-000000000107', 7)) x(id, h);
select public.tests_mark('01070000-0000-0000-0000-000000000106', '01070000-0000-0000-0000-000000000e03', 'late_cancel');
select is((public.tests_att('01070000-0000-0000-0000-000000000106')).fee_tiyin, 0, 'Безлимит, штраф сразу — 0');
select public.tests_mark('01070000-0000-0000-0000-000000000107', '01070000-0000-0000-0000-000000000e03', 'present');
select public.tests_mark('01070000-0000-0000-0000-000000000107', '01070000-0000-0000-0000-000000000e03', 'late_cancel');
select is((public.tests_att('01070000-0000-0000-0000-000000000107')).fee_tiyin, 0, 'Безлимит, «Пришёл → штраф» — тоже 0');

update public.lessons set status = 'cancelled' where id = '01070000-0000-0000-0000-000000000104';
select is(public.tests_accrued('01070000-0000-0000-0000-000000000e01'), 0,
  'Отмена занятия убирает его штраф из долга');

select * from finish();
rollback;
