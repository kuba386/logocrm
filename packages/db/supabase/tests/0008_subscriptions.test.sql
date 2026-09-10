-- pgTAP: абонементы.
-- Главное здесь — что деньги и остаток держит база, а не функция: перенос
-- в чужой центр, переполнение, правка счётчиков напрямую, пересечение
-- заморозок и цена, замороженная на момент продажи.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(18);

-- Фикстуры: два центра, чтобы проверять границу, а не только «работает» ------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-b@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Препод А');

insert into public.payers (id, center_id, full_name, phone) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Иванова А.','+996700111222'),
  ('bbbbbbbb-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Чужая Б.','+996700999888');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Данияр','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Айлин','bbbbbbbb-0000-0000-0000-000000000001',null),
  ('eeeeeeee-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Чужой','bbbbbbbb-0000-0000-0000-00000000000b',null);

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('99999999-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Индивидуальное',45,50000);

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',null,null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner',null,null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001',null),
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


-- 1. Сид статусов: четыре штуки каждому центру -------------------------------

select is(
  (select count(*)::int from public.attendance_statuses
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and deleted_at is null),
  4,
  'Новому центру засеяны четыре статуса посещения'
);

-- 2. Сид попал в свой центр, а не в чужой ------------------------------------

select is(
  (select count(*)::int from public.attendance_statuses
    where center_id = 'cccccccc-0000-0000-0000-00000000000b'),
  4,
  'Второму центру засеяны свои статусы, а не дубли в первый'
);

-- 3. Код статуса уникален в центре -------------------------------------------

select throws_ok(
  $q$ insert into public.attendance_statuses (center_id, code, name)
      values ('cccccccc-0000-0000-0000-00000000000a','present','Дубль') $q$,
  '23505', null,
  'Повторный код статуса в одном центре отклонён'
);


-- Продажа --------------------------------------------------------------------

-- Продажа идёт отдельным стейтментом, а её результат кладётся сюда.
-- Вызвать функцию прямо в `where id = sell_subscription(...)` нельзя:
-- на пустой таблице сканирование не даёт ни одной строки, условие не
-- вычисляется ни разу, и функция не вызывается вовсе — абонемент не
-- создаётся, а тест показывает NULL вместо цены.
create temporary table t_sub (name text primary key, id uuid);
-- Таблица создана от postgres, а писать и читать её будет роль authenticated
-- после set local role. Чужая временная таблица для неё закрыта так же, как
-- обычная: без гранта первая же вставка падает с 42501, транзакция
-- обрывается, и pgTAP видит «planned 18, ran 3».
grant select, insert on t_sub to authenticated;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into t_sub (name, id)
values ('pack8', public.sell_subscription('77777777-0000-0000-0000-000000000001',
                                          'eeeeeeee-0000-0000-0000-000000000001'));

-- 4. Пункт 1 чек-листа: 8 занятий за 4000 сом → 500 сом за занятие -----------

select is(
  (select lesson_price_tiyin from public.subscriptions
    where id = (select id from t_sub where name = 'pack8')),
  50000,
  'Продажа 8 занятий за 400000 тыйын даёт цену занятия 50000'
);

-- 5. Остаток сразу после продажи ---------------------------------------------

select is(
  (select public.subscription_lessons_left(id) from t_sub where name = 'pack8'),
  8,
  'Остаток нового абонемента равен проданному количеству'
);

-- 6. Цена не считается браузером: аргумент переопределяет тип ----------------

insert into t_sub (name, id)
values ('custom', public.sell_subscription('77777777-0000-0000-0000-000000000001',
                                           'eeeeeeee-0000-0000-0000-000000000002', 200000));

select is(
  (select price_tiyin from public.subscriptions
    where id = (select id from t_sub where name = 'custom')),
  200000,
  'Явная цена в аргументе переопределяет цену типа'
);

reset role;


-- Границы центра -------------------------------------------------------------

-- 7. Абонемент на ребёнка чужого центра — отказ констрейнта, а не политики ---

select throws_ok(
  $q$ insert into public.subscriptions
        (center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at)
      values ('cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-00000000000b',
              'bbbbbbbb-0000-0000-0000-000000000001',8,400000,50000,current_date) $q$,
  '23503', null,
  'Ссылка на ребёнка чужого центра отклонена составным ключом'
);

-- 8. И плательщик тоже ---------------------------------------------------------

select throws_ok(
  $q$ insert into public.subscriptions
        (center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at)
      values ('cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001',
              'bbbbbbbb-0000-0000-0000-00000000000b',8,400000,50000,current_date) $q$,
  '23503', null,
  'Ссылка на плательщика чужого центра отклонена составным ключом'
);


-- Переполнение и счётчики -------------------------------------------------------

-- 9. Не уйти за оплаченное — CHECK, а не проверка в функции ------------------

select throws_ok(
  $q$ update public.subscriptions set lessons_used = 9
       where student_id = 'eeeeeeee-0000-0000-0000-000000000001' $q$,
  '23514', null,
  'Списание сверх оплаченного отклонено CHECK-ом'
);

-- 10. С разрешением уйти в минус — проходит ----------------------------------

select lives_ok(
  $q$ update public.subscriptions set allow_negative = true, lessons_used = 9
       where student_id = 'eeeeeeee-0000-0000-0000-000000000001' $q$,
  'При allow_negative списание сверх оплаченного разрешено'
);

update public.subscriptions set allow_negative = false, lessons_used = 0
 where student_id = 'eeeeeeee-0000-0000-0000-000000000001';

-- 11. Счётчик закрыт от прикладной роли колоночным грантом -------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ update public.subscriptions set lessons_used = 0
       where student_id = 'eeeeeeee-0000-0000-0000-000000000001' $q$,
  '42501', null,
  'Прямая правка lessons_used отклонена колоночным грантом'
);

-- 12. А разрешённые колонки правятся ------------------------------------------

select lives_ok(
  $q$ update public.subscriptions set notes = 'проверка'
       where student_id = 'eeeeeeee-0000-0000-0000-000000000001' $q$,
  'Разрешённые колонки абонемента правятся из-под роли'
);

reset role;


-- Заморозка ---------------------------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- 13. Пункт 3 чек-листа: заморозка на 7 дней -----------------------------------

do $$
declare v_sub uuid;
begin
  select id into v_sub from public.subscriptions
   where student_id = 'eeeeeeee-0000-0000-0000-000000000001' limit 1;
  perform public.freeze_subscription(v_sub, current_date, current_date + 7);
end $$;

select is(
  (select public.subscription_freeze_days(id) from public.subscriptions
    where student_id = 'eeeeeeee-0000-0000-0000-000000000001' limit 1),
  7,
  'Заморозка на 7 дней даёт сдвиг ровно в 7 дней'
);

-- Дальше от postgres: прямой insert в subscription_freezes роли authenticated
-- закрыт намеренно (заморозка — только через freeze_subscription), и тест
-- ограничения получил бы 42501 вместо 23P01. Claims остаются — они живут в
-- транзакции, а не в роли, и freeze_subscription в тесте 15 читает роль из них.
reset role;

-- 14. Пересекающаяся заморозка отклонена EXCLUDE-ом ---------------------------

select throws_ok(
  $q$ insert into public.subscription_freezes (center_id, subscription_id, period)
      select center_id, id, daterange(current_date + 3, current_date + 10, '[)')
        from public.subscriptions
       where student_id = 'eeeeeeee-0000-0000-0000-000000000001' limit 1 $q$,
  '23P01', null,
  'Пересекающиеся заморозки одного абонемента отклонены'
);

-- 15. Замороженный абонемент нельзя заморозить снова --------------------------

select throws_ok(
  $q$ select public.freeze_subscription(
        (select id from public.subscriptions
          where student_id = 'eeeeeeee-0000-0000-0000-000000000001' limit 1),
        current_date + 30, current_date + 40) $q$,
  '22023', null,
  'Повторная заморозка уже замороженного абонемента отклонена'
);

reset role;


-- Роли ---------------------------------------------------------------------------

-- 16. Специалист не видит абонементы вовсе ------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.subscriptions),
  0,
  'Специалист не видит ни одного абонемента'
);

reset role;

-- 17. Родитель видит абонементы своих детей ------------------------------------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select cmp_ok(
  (select count(*)::int from public.subscriptions), '>=', 1,
  'Родитель видит абонементы своих детей'
);

reset role;

-- 18. Владелец чужого центра не видит ничего -----------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;

select is(
  (select count(*)::int from public.subscriptions),
  0,
  'Владелец другого центра не видит чужие абонементы'
);

reset role;


select * from finish();

rollback;
