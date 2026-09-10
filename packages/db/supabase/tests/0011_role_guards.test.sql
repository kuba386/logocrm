-- pgTAP: проверка роли при NULL в RPC этапов 0–3 (миграция 0011).
-- Пользователь с валидным JWT на центр, но без членства — каждая из девяти
-- RPC отвечает 42501 первой строкой, а не падает позже на emit_event.
-- Плюс контроль: настоящий владелец теми же функциями пользуется.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(11);

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','revoked@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings)
values ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Препод А'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Препод Б');

insert into public.payers (id, center_id, full_name, phone)
values ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Иванова А.','+996700111222');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id)
values ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Данияр','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin)
values ('99999999-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Индивидуальное',45,50000);

-- Членство только у владельца. Отозванный (6666) — без строки: JWT живой, прав нет.
insert into public.memberships (user_id, center_id, role)
values ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

-- Занятие в будущем — чтобы владелец мог его отменить в контрольной проверке.
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at)
values ('44444444-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
        '99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-000000000001', now() + interval '1 day', now() + interval '1 day' + interval '45 min');


-- Отозванное членство при живом JWT --------------------------------------------

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok($q$ select public.archive_student('eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', 'Недостаточно прав', 'archive_student: отозванный получает 42501, не ошибку emit_event');
select throws_ok($q$ select public.restore_student('eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', 'Недостаточно прав', 'restore_student: 42501');
select throws_ok($q$ select public.create_student_with_payer('Тест', null, 'Мама', '+996700000001', 'mother', null, null, null, null, null) $q$,
  '42501', 'Недостаточно прав', 'create_student_with_payer: 42501');
select throws_ok($q$ select * from public.create_lesson_series('{}'::jsonb) $q$,
  '42501', 'Недостаточно прав', 'create_lesson_series: 42501');
select throws_ok($q$ select public.cancel_lesson('44444444-0000-0000-0000-000000000001', 'x') $q$,
  '42501', 'Недостаточно прав', 'cancel_lesson: 42501');
select throws_ok($q$ select public.cancel_series_from(gen_random_uuid(), current_date, 'x') $q$,
  '42501', 'Недостаточно прав', 'cancel_series_from: 42501');
select throws_ok($q$ select public.substitute_teacher('44444444-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002') $q$,
  '42501', 'Недостаточно прав', 'substitute_teacher: 42501');
select throws_ok($q$ select public.teacher_vacation('aaaaaaaa-0000-0000-0000-000000000001', current_date + 10, current_date + 12) $q$,
  '42501', 'Недостаточно прав', 'teacher_vacation: 42501');
select throws_ok($q$ select public.reschedule_lesson('44444444-0000-0000-0000-000000000001', now() + interval '2 days', now() + interval '2 days' + interval '45 min') $q$,
  '42501', 'Недостаточно прав', 'reschedule_lesson: 42501');

reset role;


-- Контроль: настоящий владелец ---------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select lives_ok($q$ select public.cancel_lesson('44444444-0000-0000-0000-000000000001', 'проверка') $q$,
  'Владелец отменяет занятие той же функцией');
select is((select status from public.lessons where id = '44444444-0000-0000-0000-000000000001'), 'cancelled',
  'Занятие отменено — функция после правки работает');

reset role;


select * from finish();

rollback;
