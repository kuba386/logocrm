-- pgTAP: attendance.comment закрыт от родителя (0044).
--
-- Главная ловушка этого файла — тест, зелёный вхолостую: если фикстура
-- случайно не создала строку (занятие в будущем, ребёнок не в составе),
-- «0 строк у родителя» ничего не докажет. Поэтому непустота фикстуры
-- проверяется явно, под владельцем, до переключения на родителя.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(15);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','71111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-att@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','74444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-att@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','77777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-att@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','72222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-att@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','73333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-att@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('7ccccccc-0000-0000-0000-00000000000a','Центр посещений','centr-att','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('7aaaaaaa-0000-0000-0000-000000000001','7ccccccc-0000-0000-0000-00000000000a','Специалист');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('7bbbbbbb-0000-0000-0000-000000000001','7ccccccc-0000-0000-0000-00000000000a','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('7ddddddd-0000-0000-0000-000000000001','7ccccccc-0000-0000-0000-00000000000a','Родитель','+996700000701');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('71111111-1111-1111-1111-111111111111','7ccccccc-0000-0000-0000-00000000000a','owner',    null, null),
  ('74444444-4444-4444-4444-444444444444','7ccccccc-0000-0000-0000-00000000000a','teacher','7aaaaaaa-0000-0000-0000-000000000001', null),
  ('77777777-7777-7777-7777-777777777777','7ccccccc-0000-0000-0000-00000000000a','parent',   null, '7ddddddd-0000-0000-0000-000000000001'),
  ('72222222-2222-2222-2222-222222222222','7ccccccc-0000-0000-0000-00000000000a','registrar',null, null),
  ('73333333-3333-3333-3333-333333333333','7ccccccc-0000-0000-0000-00000000000a','finance',  null, null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('7eeeeeee-0000-0000-0000-000000000001','7ccccccc-0000-0000-0000-00000000000a','Ребёнок','7ddddddd-0000-0000-0000-000000000001');

insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('7fffffff-0000-0000-0000-000000000001','7ccccccc-0000-0000-0000-00000000000a','7aaaaaaa-0000-0000-0000-000000000001','7eeeeeee-0000-0000-0000-000000000001','7bbbbbbb-0000-0000-0000-000000000001','done', now() - interval '2 hours', now() - interval '1 hour 15 minutes');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

select public.tests_claims('71111111-1111-1111-1111-111111111111','7ccccccc-0000-0000-0000-00000000000a');

insert into public.attendance (center_id, lesson_id, student_id, status_id, comment)
select '7ccccccc-0000-0000-0000-00000000000a', l.id, '7eeeeeee-0000-0000-0000-000000000001',
       (select id from public.attendance_statuses
         where center_id = '7ccccccc-0000-0000-0000-00000000000a' and code = 'present'),
       'КАНАРЕЙКА-МАМА-ОПОЗДАЛА'
  from public.lessons l where l.id = '7fffffff-0000-0000-0000-000000000001';


-- Забор: полный каталог политик attendance -------------------------------------------------------

-- Роняет будущий apply_role_rls('attendance', 'parent', …) внятным
-- сообщением, а не тихим возвратом доступа через «0 строк снова 0».
select set_eq(
  $$ select policyname from pg_policies where schemaname = 'public' and tablename = 'attendance' $$,
  $$ values ('tenant_admin'), ('attendance_teacher_read'),
            ('tenant_registrar_select'), ('tenant_registrar_insert'), ('tenant_registrar_update') $$,
  'Ровно пять политик — attendance_parent_read снята и не вернулась'
);

-- Имена политик не единственная защита: расширение qual у существующей
-- политики (например attendance_teacher_read до my_role() in ('teacher',
-- 'parent')) оставило бы набор имён прежним. Ловит текст условия, а не
-- только факт наличия политики.
select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and tablename = 'attendance' and qual like '%parent%'),
  0, 'Ни одна политика attendance не упоминает parent в условии');


-- Фикстура доказана непустой — иначе «0 строк у родителя» ничего не доказывает.
-- Выполняется от postgres (до первого set local role), RLS тут ни при
-- чём: это проверка самой фикстуры, а не прав владельца — его права под
-- RLS проверяются отдельно, ниже.

select is(
  (select count(*)::int from public.attendance where student_id = '7eeeeeee-0000-0000-0000-000000000001'),
  1, 'Под владельцем строка есть — фикстура не пуста');

select is(
  (select comment from public.attendance where student_id = '7eeeeeee-0000-0000-0000-000000000001'),
  'КАНАРЕЙКА-МАМА-ОПОЗДАЛА', 'И канарейка в comment на месте');


-- Родитель: таблица закрыта целиком, канарейка недостижима -----------------------------------------

select public.tests_claims('77777777-7777-7777-7777-777777777777','7ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.attendance), 0,
  'Родитель своего ребёнка — 0 строк в attendance целиком, не только в comment');

select is(
  (select count(*)::int from public.attendance where comment like '%КАНАРЕЙКА%'), 0,
  'Канарейка недостижима и через фильтр по comment — на случай будущей политики «кроме comment»');

select throws_ok(
  $q$ insert into public.attendance (center_id, lesson_id, student_id, status_id)
      values ('7ccccccc-0000-0000-0000-00000000000a','7fffffff-0000-0000-0000-000000000001',
              '7eeeeeee-0000-0000-0000-000000000001',
              (select id from public.attendance_statuses where code = 'present' limit 1)) $q$,
  '42501', null,
  'Запись родителю по-прежнему закрыта — «нет чтения» не превратилось в «нет и проверки записи»');

-- Грант update(comment) у authenticated не тронут (0009/0010) — родителя
-- держит только RLS. RLS на update не бросает, а фильтрует строки: без
-- отдельной проверки такой update молча тронул бы 0 строк и выглядел бы
-- «успешным». Проверяем результатом, а не исключением — throws_ok здесь
-- не тот механизм (тот же урок, что правка exercise_library в 0040).
update public.attendance set comment = 'КАНАРЕЙКА-ОТ-РОДИТЕЛЯ'
 where student_id = '7eeeeeee-0000-0000-0000-000000000001';

select is(
  (select count(*)::int from public.student_attendance_brief(
     '7eeeeeee-0000-0000-0000-000000000001', (now() - interval '1 day')::date, (now() + interval '1 day')::date)),
  1, 'Замена работает: узкая функция отдаёт ровно ту же отметку');

select is(
  pg_get_function_result('public.student_attendance_brief(uuid,date,date)'::regprocedure),
  'TABLE(lesson_at timestamp with time zone, status_name text, counts_absence boolean)',
  'В возвращаемом типе по-прежнему нет comment, price_tiyin, subscription_id — физически');

reset role;


-- Соседи не задеты -----------------------------------------------------------------------------------

select public.tests_claims('74444444-4444-4444-4444-444444444444','7ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.attendance), 1,
  'Специалист своего занятия видит отметку как прежде — attendance_teacher_read не тронута');
reset role;

select public.tests_claims('71111111-1111-1111-1111-111111111111','7ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.attendance), 1,
  'Владелец видит отметку как прежде');
reset role;

select is(
  (select comment from public.attendance where student_id = '7eeeeeee-0000-0000-0000-000000000001'),
  'КАНАРЕЙКА-МАМА-ОПОЗДАЛА',
  'Update родителя не изменил ни строки: комментарий тот же, что был');

select public.tests_claims('72222222-2222-2222-2222-222222222222','7ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.attendance), 1,
  'Регистратору посещаемость положена (0028) и осталась нетронутой');
reset role;

select public.tests_claims('73333333-3333-3333-3333-333333333333','7ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select count(*)::int from public.attendance), 0,
  'Бухгалтеру как было закрыто в 0031, так и осталось');
reset role;


-- Родитель по-прежнему считает долг: единственное место, где снятие политики могло бы отозваться ---

select public.tests_claims('77777777-7777-7777-7777-777777777777','7ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select debt_tiyin from public.student_balance
    where student_id = '7eeeeeee-0000-0000-0000-000000000001'),
  70000,
  'Долг родителю по-прежнему считает student_debts (definer, обходит RLS), а не прямое чтение attendance — 70000 тыйын за отмеченное занятие без абонемента');
reset role;

select * from finish();

rollback;
