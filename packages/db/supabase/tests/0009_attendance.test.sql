-- pgTAP: посещения и списание.
-- Главное здесь — что остаток держит триггер, а не функция: проверяется
-- прямой insert мимо mark_attendance, правка статуса задним числом и
-- отмена занятия. Плюс границы ролей и события ровно по одному разу.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(21);

-- Фикстуры ---------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher2@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings)
values ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Препод А'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Препод Б');

insert into public.payers (id, center_id, full_name, phone) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Иванова А.','+996700111222');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Данияр','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Айлин','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin)
values ('99999999-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Индивидуальное',45,50000);

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',null,null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001',null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000002',null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','parent',null,'bbbbbbbb-0000-0000-0000-000000000001');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

insert into public.subscription_types (id, center_id, name, service_id, kind, lessons_count, price_tiyin)
values ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
        'Восемь занятий','99999999-0000-0000-0000-000000000001','lessons',8,400000);

-- Три прошедших занятия у Данияра, одно у Айлин, одно у второго препода.
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at) values
  ('44444444-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '3 days', now() - interval '3 days' + interval '45 min'),
  ('44444444-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '2 days', now() - interval '2 days' + interval '45 min'),
  ('44444444-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '1 day', now() - interval '1 day' + interval '45 min'),
  ('44444444-0000-0000-0000-000000000009','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() + interval '2 days', now() + interval '2 days' + interval '45 min'),
  ('44444444-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002', now() - interval '1 day', now() - interval '1 day' + interval '30 min');

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at)
values ('88888888-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
        'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
        '77777777-0000-0000-0000-000000000001', 3, 150000, 50000, current_date - 10);


-- Claims выставляются до первой отметки, роль остаётся postgres. Триггер
-- отметки зовёт emit_event, а тот требует auth.uid() и членства в центре:
-- без claims весь файл падал на первом же insert, не дойдя до plan.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');


-- Списание держит триггер, а не функция ---------------------------------------

-- 1. Прямой insert мимо mark_attendance всё равно списывает -------------------

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000001',
       'eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';

select is(
  public.subscription_lessons_left('88888888-0000-0000-0000-000000000001'), 2,
  'Прямой insert мимо функции всё равно списал занятие'
);

-- 2. Правка статуса «пришёл» → «болел» возвращает занятие ---------------------

update public.attendance a set status_id = st.id
  from public.attendance_statuses st
 where st.center_id = a.center_id and st.code = 'sick'
   and a.lesson_id = '44444444-0000-0000-0000-000000000001';

select is(
  public.subscription_lessons_left('88888888-0000-0000-0000-000000000001'), 3,
  'Смена статуса на «болел» вернула занятие в остаток'
);

-- 3. И обратно ----------------------------------------------------------------

update public.attendance a set status_id = st.id
  from public.attendance_statuses st
 where st.center_id = a.center_id and st.code = 'present'
   and a.lesson_id = '44444444-0000-0000-0000-000000000001';

select is(
  public.subscription_lessons_left('88888888-0000-0000-0000-000000000001'), 2,
  'Возврат статуса «пришёл» снова списал занятие'
);

-- 4. Отмена занятия возвращает списание ---------------------------------------

update public.lessons set status = 'cancelled'
 where id = '44444444-0000-0000-0000-000000000001';

select is(
  public.subscription_lessons_left('88888888-0000-0000-0000-000000000001'), 3,
  'Отмена занятия задним числом вернула списание в остаток'
);

update public.lessons set status = 'planned'
 where id = '44444444-0000-0000-0000-000000000001';


-- Проверки триггера --------------------------------------------------------------

-- 5. Ребёнок не участник занятия ------------------------------------------------

select throws_ok(
  $q$ insert into public.attendance (center_id, lesson_id, student_id, status_id)
      select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000002',
             'eeeeeeee-0000-0000-0000-000000000002', id
        from public.attendance_statuses
       where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present' $q$,
  '22023', null,
  'Отметка ребёнка, которого нет на занятии, отклонена'
);

-- 6. Занятие ещё не началось ----------------------------------------------------

select throws_ok(
  $q$ insert into public.attendance (center_id, lesson_id, student_id, status_id)
      select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000009',
             'eeeeeeee-0000-0000-0000-000000000001', id
        from public.attendance_statuses
       where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present' $q$,
  '22023', null,
  'Отметка занятия в будущем отклонена'
);

-- 7. Отменённое занятие ---------------------------------------------------------

update public.lessons set status = 'cancelled' where id = '44444444-0000-0000-0000-000000000003';

select throws_ok(
  $q$ insert into public.attendance (center_id, lesson_id, student_id, status_id)
      select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000003',
             'eeeeeeee-0000-0000-0000-000000000001', id
        from public.attendance_statuses
       where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present' $q$,
  '22023', null,
  'Отметка отменённого занятия отклонена'
);

update public.lessons set status = 'planned' where id = '44444444-0000-0000-0000-000000000003';

-- 8. Факт списания заморожен в строке -------------------------------------------

select is(
  (select deducted from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000001'),
  true,
  'Факт списания заморожен в строке отметки'
);

-- 9. Цена заморожена из абонемента ------------------------------------------------

select is(
  (select price_tiyin from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000001'),
  50000,
  'Цена занятия заморожена в строке отметки'
);


-- Отметка через функцию -----------------------------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- 10. Специалист отмечает своё занятие ---------------------------------------------

select lives_ok(
  $q$ select public.mark_attendance('44444444-0000-0000-0000-000000000002',
                                    'eeeeeeee-0000-0000-0000-000000000001','present') $q$,
  'Специалист отмечает посещение на своём занятии'
);

-- 11. Повторная отметка тем же статусом идемпотентна ------------------------------

select lives_ok(
  $q$ select public.mark_attendance('44444444-0000-0000-0000-000000000002',
                                    'eeeeeeee-0000-0000-0000-000000000001','present') $q$,
  'Повторная отметка тем же статусом не ошибка, а тот же результат'
);

-- 12. Чужое занятие ------------------------------------------------------------------

select throws_ok(
  $q$ select public.mark_attendance('44444444-0000-0000-0000-00000000000b',
                                    'eeeeeeee-0000-0000-0000-000000000002','present') $q$,
  '42501', null,
  'Отметка на чужом занятии отклонена'
);

-- 13. Специалист не видит витрину остатков --------------------------------------------

select is(
  (select count(*)::int from public.student_balance), 0,
  'Специалист не видит витрину остатков и долгов'
);

-- 14. Но бейдж получает --------------------------------------------------------------

select isnt(
  public.student_subscription_badge('eeeeeeee-0000-0000-0000-000000000001'), null,
  'Специалист получает бейдж наличия абонемента'
);

-- 15. И бейдж не содержит чисел --------------------------------------------------------

select ok(
  public.student_subscription_badge('eeeeeeee-0000-0000-0000-000000000001') in ('нет','заканчивается','есть'),
  'Бейдж специалиста — только слово, без сумм и остатков'
);

reset role;

-- Claims возвращаются владельцу: они переживают reset role, а витрина
-- остатков фильтрует по роли и для специалиста пуста по построению.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');


-- События -------------------------------------------------------------------------------

-- 16. Остаток дошёл до 2 → ровно одно low_balance ---------------------------------------

select is(
  (select count(*)::int from public.events where type = 'subscription.low_balance'), 1,
  'Событие low_balance отправлено ровно один раз'
);

-- 17. «Болел» не списывает --------------------------------------------------------------

do $$
declare v_before int; v_after int;
begin
  v_before := public.subscription_lessons_left('88888888-0000-0000-0000-000000000001');
  insert into public.attendance (center_id, lesson_id, student_id, status_id)
  select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000003',
         'eeeeeeee-0000-0000-0000-000000000001', id
    from public.attendance_statuses
   where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'sick';
  v_after := public.subscription_lessons_left('88888888-0000-0000-0000-000000000001');
  if v_before is distinct from v_after then
    raise exception 'Статус «болел» списал занятие: было %, стало %', v_before, v_after;
  end if;
end $$;

select pass('Статус «болел» не списывает занятие');

-- 18. Долг: отметка без абонемента ---------------------------------------------------------

update public.subscriptions set status = 'cancelled' where id = '88888888-0000-0000-0000-000000000001';

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-00000000000b',
       'eeeeeeee-0000-0000-0000-000000000002', id
  from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';

select is(
  (select subscription_id from public.attendance
    where lesson_id = '44444444-0000-0000-0000-00000000000b'), null,
  'Без действующего абонемента отметка записана в долг, а не отклонена'
);

-- 19. И событие о долге ушло -----------------------------------------------------------------

select cmp_ok(
  (select count(*)::int from public.events where type = 'attendance.no_subscription'), '>=', 1,
  'Событие attendance.no_subscription отправлено'
);

-- 20. Долг посчитан по замороженной цене -------------------------------------------------------

select is(
  (select debt_tiyin from public.student_balance where student_id = 'eeeeeeee-0000-0000-0000-000000000002'),
  50000,
  'Долг посчитан по цене, замороженной в отметке'
);


-- 21. Замороженные факты не правятся напрямую: триггер перетирает --------------

-- На attendance у администратора есть update, и это нормально — правка
-- статуса идёт через него. Но deducted, price_tiyin и subscription_id
-- клиент задать не может: BEFORE-триггер вычисляет их заново из статуса,
-- услуги и действующего абонемента при каждой записи, а не только при
-- вставке. Иначе PATCH с price_tiyin=0 обнулял бы долг.
update public.attendance set deducted = false, price_tiyin = 0
 where lesson_id = '44444444-0000-0000-0000-000000000001';

select ok(
  (select deducted and price_tiyin = 50000 from public.attendance
    where lesson_id = '44444444-0000-0000-0000-000000000001'),
  'Прямая правка deducted и price_tiyin перетёрта триггером из статуса и услуги'
);

select * from finish();

rollback;
