-- pgTAP: ученики и плательщики.
-- Главное здесь — колоночная приватность: специалист видит ребёнка,
-- но не телефон его родителя.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(12);

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent@test.kg','','','','','','','','');

insert into public.centers (id, name, slug) values
  ('cccccccc-cccc-cccc-cccc-cccccccccccc','Центр А','centr-a'),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd','Центр Б','centr-b');

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Мой Специалист'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-cccc-cccc-cccc-cccccccccccc','Чужой Специалист');

insert into public.payers (id, center_id, full_name, phone) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Иванова А.','+996700111222'),
  ('bbbbbbbb-0000-0000-0000-000000000009','cccccccc-cccc-cccc-cccc-cccccccccccc','Сидорова В.','+996700999999');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-cccc-cccc-cccc-cccccccccccc','Данияр','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-cccc-cccc-cccc-cccccccccccc','Айлин','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000009','cccccccc-cccc-cccc-cccc-cccccccccccc','Чужой ученик','bbbbbbbb-0000-0000-0000-000000000009','aaaaaaaa-0000-0000-0000-000000000002');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-cccc-cccc-cccc-cccccccccccc','owner',null,null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-cccc-cccc-cccc-cccccccccccc','teacher','aaaaaaaa-0000-0000-0000-000000000001',null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-cccc-cccc-cccc-cccccccccccc','parent',null,'bbbbbbbb-0000-0000-0000-000000000001');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text,
    true);
end;
$$;


-- 1. Нормализация телефона ----------------------------------------------------

select is(public.normalize_kg_phone('0700 12-34-56'), '+996700123456', 'normalize_kg_phone: местная запись с нулём');
select is(public.normalize_kg_phone('+996 700 123 456'), '+996700123456', 'normalize_kg_phone: международная запись');
select is(public.normalize_kg_phone('12345'), null, 'normalize_kg_phone: мусор отбрасывается');


-- 2. Колоночная приватность ---------------------------------------------------

-- Главная проверка этапа: в витрине специалиста контактных колонок нет физически.
select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public'
      and table_name = 'students_teacher_view'
      and column_name in ('phone', 'phone_alt', 'email', 'payer_id')),
  0,
  'В students_teacher_view нет колонок phone/phone_alt/email/payer_id'
);

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-cccc-cccc-cccc-cccccccccccc');
set local role authenticated;

select is(
  (select count(*) from public.payers)::int, 0,
  'Специалист не видит ни одной строки в payers'
);

select results_eq(
  'select full_name from public.students order by full_name',
  array['Айлин', 'Данияр'],
  'Специалист видит только своих учеников'
);

select is(
  (select count(*) from public.students_teacher_view)::int, 2,
  'Витрина отдаёт специалисту его учеников (join к payers её не обнуляет)'
);

select is(
  public.payer_display_name('bbbbbbbb-0000-0000-0000-000000000001'), 'Иванова А.',
  'Специалист видит имя родителя своего ученика'
);

select is(
  public.payer_display_name('bbbbbbbb-0000-0000-0000-000000000009'), null,
  'Специалист не видит имя родителя чужого ученика'
);

reset role;


-- 3. Родитель -----------------------------------------------------------------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-cccc-cccc-cccc-cccccccccccc');
set local role authenticated;

select results_eq(
  'select full_name from public.students order by full_name',
  array['Айлин', 'Данияр'],
  'Родитель видит только детей своего payer_id'
);

reset role;


-- 4. Дубли телефона -----------------------------------------------------------

select throws_ok(
  $q$ insert into public.payers (center_id, full_name, phone)
      values ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Дубль', '0700 111-222') $q$,
  '23505',
  null,
  'Тот же телефон в том же центре отклонён (номер сверяется нормализованным)'
);

select lives_ok(
  $q$ insert into public.payers (center_id, full_name, phone)
      values ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'Иванова А.', '+996700111222') $q$,
  'Тот же телефон в другом центре разрешён'
);

select * from finish();

rollback;
