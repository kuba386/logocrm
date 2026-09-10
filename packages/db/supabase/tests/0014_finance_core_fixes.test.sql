-- pgTAP: закрытие находок третьего ревью 0013 (миграция 0014).
-- Смена плательщика у ребёнка с платежом теперь не блокируется (была
-- заблокирована составным FK без on update); история платежа не
-- переписывается; самокорректирующийся бэкфилл заводит payments-строку;
-- DELETE-ветка замка не падает 55000; перенос занятия в закрытый месяц
-- блокируется; close_month ловит "done без отметки", не только "planned".
--
-- Плюс находки второго (архитекторского) раунда против самого 0014: оба
-- бэкфилла вынесены в функции и вызываются здесь на своей фикстуре — иначе
-- их нельзя было бы проверить (на CI supabase db reset они отрабатывают
-- на пустой базе, раньше, чем существуют s1/s2/эта фикстура вообще);
-- seed_payment_sources больше не отбивает свой же триггер при создании
-- центра (проверялась инвертированная роль); close_month видит занятие без
-- единого участника (был inner join); бэкфилл истории подхватывает
-- плательщика из subscriptions, не только текущего students.payer_id.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(30);

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Препод А');

insert into public.payers (id, center_id, full_name, phone) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Иванова А. (старая)','+996700111222'),
  ('bbbbbbbb-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Петрова Б. (новая)','+996700333444');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Данияр','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('99999999-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Индивидуальное',45,50000);

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',null,null);

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

-- s1: обычный абонемент, будет оплачен через record_payment ниже — тест на
-- смену плательщика. s2: имитирует уже применённый на живой базе бэкфилл
-- 0013 — paid_tiyin проставлен напрямую, ни одной строки payments.
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, paid_tiyin)
values
  ('88888888-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
   'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
   '77777777-0000-0000-0000-000000000001', 8, 400000, 50000, current_date - 10, 0),
  ('88888888-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a',
   'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
   '77777777-0000-0000-0000-000000000001', 8, 400000, 50000, current_date - 20, 400000);

-- Занятие "вчера" — для reschedule/DELETE-веток, целится в M1 (2 месяца
-- назад), который в тестах 5-9 закрывается и остаётся ЧИСТЫМ (в нём самом
-- изначально нет ни одного занятия — closeable без исключений). Занятие
-- ...002 — в M2 (3 месяца назад), status='done', БЕЗ единой строки
-- attendance: ровно сценарий находки 6 (mark_lesson_status закрыл занятие,
-- отметки посещения нет), M2 закрывается отдельно и именно от этого падает.
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('44444444-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
   '99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-000000000001', now() - interval '1 day', now() - interval '1 day' + interval '45 min', 'planned'),
  ('44444444-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a',
   '99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-000000000001',
   date_trunc('month', now() - interval '3 months') + interval '10 days',
   date_trunc('month', now() - interval '3 months') + interval '10 days' + interval '45 min', 'done');


-- 1. Бэкфилл 0013 самокорректируется: у s2 теперь есть строка payments -----------

-- Миграция вызывает backfill_subscription_payments() один раз при
-- применении — на пустой CI базе (supabase db reset) это происходит
-- раньше, чем существуют s1/s2 этого файла, и результат такого вызова
-- проверить нельзя. Зовём функцию здесь же, на своей фикстуре — это и
-- проверяет её логику, и не зависит от момента, когда 0014 применилась.
select public.backfill_subscription_payments();

select is(
  (select count(*)::int from public.payments where subscription_id = '88888888-0000-0000-0000-000000000002'),
  1,
  'backfill_subscription_payments завела корректирующий payments для уже забэкфилленного paid_tiyin (s2)'
);
select is(
  (select amount_tiyin from public.payments
    where subscription_id = '88888888-0000-0000-0000-000000000002' and kind = 'correction'),
  400000,
  'Сумма корректирующей строки равна прежнему paid_tiyin'
);
select is(
  (select paid_tiyin from public.subscriptions where id = '88888888-0000-0000-0000-000000000002'),
  400000,
  'paid_tiyin после пересчёта из новой payments-строки не изменился (идемпотентно)'
);

-- s1 (paid_tiyin=0 изначально) корректирующей строки получить не должен —
-- фильтр "paid_tiyin > 0" отсекает его.
select is(
  (select count(*)::int from public.payments where subscription_id = '88888888-0000-0000-0000-000000000001'),
  0,
  'У s1 (paid_tiyin=0 до миграции) корректирующая строка не заводится'
);

-- Повторный вызов не плодит вторую корректирующую строку — not exists уже
-- видит заведённую (та же гарантия, что нужна и при повторном db push).
select public.backfill_subscription_payments();

select is(
  (select count(*)::int from public.payments where subscription_id = '88888888-0000-0000-0000-000000000002'),
  1,
  'Повторный вызов backfill_subscription_payments идемпотентен — вторая строка не появилась'
);


-- 2-4. Смена плательщика у ребёнка с платежом — больше не тупик ------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

create temporary table t_pay (name text primary key, id uuid);
grant select, insert on t_pay to authenticated;

insert into t_pay (name, id)
select 'p1', public.record_payment('bbbbbbbb-0000-0000-0000-000000000001', 100000, 'payment',
                                   'eeeeeeee-0000-0000-0000-000000000001', '88888888-0000-0000-0000-000000000001');

reset role;

select lives_ok(
  $q$ update public.students set payer_id = 'bbbbbbbb-0000-0000-0000-000000000002'
       where id = 'eeeeeeee-0000-0000-0000-000000000001' $q$,
  'Смена плательщика у ребёнка с существующим платежом проходит (payments_student_payer_fk теперь на student_payers)'
);

select is(
  (select payer_id from public.payments where id = (select id from t_pay where name = 'p1')),
  'bbbbbbbb-0000-0000-0000-000000000001'::uuid,
  'Старый платёж по-прежнему указывает на прежнего плательщика — история не переписана'
);

select is(
  (select count(*)::int from public.student_payers where student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  2,
  'student_payers хранит обоих плательщиков ребёнка — старого и нового'
);


-- 5-6. DELETE-ветка замка не падает 55000 ------------------------------------------

-- Отдельный платёж с явной датой в M1 — payments s2 (из бэкфилла) датирован
-- created_at (сегодня), M1 сам по себе без единого занятия/платежа не
-- зацепить иначе.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into t_pay (name, id)
select 'm1', public.record_payment('bbbbbbbb-0000-0000-0000-000000000002', 50000, 'payment',
                                   null, null, null,
                                   (date_trunc('month', now() - interval '2 months') + interval '5 days'));

reset role;

select lives_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  'close_month(M1) проходит: в M1 нет ни одного занятия'
);

select throws_ok(
  $q$ delete from public.payments where id = (select id from t_pay where name = 'm1') $q$,
  '22023', null,
  'DELETE платежа в закрытом месяце отклонён замком (22023), а не падает 55000'
);


-- 7. Русское название месяца в сообщении --------------------------------------------

select throws_like(
  $q$ select public.close_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  '%уже закрыт%',
  'Повторное закрытие — читаемое сообщение'
);
select is(
  (select public.ru_month_year(date_trunc('month', now() - interval '2 months')::date) !~ '[A-Za-z]'),
  true,
  'ru_month_year не содержит латиницы — название месяца по-русски, не по локали сервера'
);


-- 8. close_month: 'done' без единой отметки посещения — тоже блокирует (находка 6) -

select throws_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '3 months')::date) $q$,
  '22023', null,
  'close_month(M2) отклонён: занятие ...002 уже done, но attendance на участника нет вовсе'
);


-- 9. Перенос занятия в закрытый месяц отклонён (находка 3) -------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  format($q$ select public.reschedule_lesson('44444444-0000-0000-0000-000000000001', %L, %L) $q$,
    (date_trunc('month', now() - interval '2 months') + interval '12 days'),
    (date_trunc('month', now() - interval '2 months') + interval '12 days' + interval '45 min')),
  '22023', null,
  'Перенос занятия в закрытый месяц отклонён замком — не только смена status'
);

reset role;


-- 10-11. payment_sources: DELETE закрыт, SELECT/INSERT/узкий UPDATE есть --------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select ok(
  not has_table_privilege('authenticated', 'public.payment_sources', 'DELETE'),
  'payment_sources: DELETE закрыт даже для владельца (0014 добавила revoke all, не было в 0013)'
);
select throws_ok(
  $q$ delete from public.payment_sources where center_id = 'cccccccc-0000-0000-0000-00000000000a' $q$,
  '42501', null,
  'Прямой DELETE источника оплаты отклонён'
);

reset role;


-- 12-14. Гранты: белый список 0007 дополнен ---------------------------------------

select ok(
  not has_function_privilege('authenticated', 'public.students_track_payer()', 'EXECUTE'),
  'Триггерная students_track_payer закрыта для authenticated'
);
select ok(
  not has_function_privilege('authenticated', 'public.seed_payment_sources(uuid)', 'EXECUTE'),
  'seed_payment_sources закрыта для authenticated, как и seed_attendance_statuses'
);
select ok(
  has_function_privilege('authenticated', 'public.ru_month_year(date)', 'EXECUTE'),
  'ru_month_year исполняется authenticated'
);


-- 15-16. archive/restore_payment_source теперь эмитят события (находка 13) -------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into t_pay (name, id)
select 'src', id from public.payment_sources
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'cash';

select public.archive_payment_source((select id from t_pay where name = 'src'));

reset role;

select is(
  (select count(*)::int from public.events where type = 'payment_source.archived'),
  1,
  'archive_payment_source эмитит событие — было тихо в 0013'
);


-- 17. payments_recalc_paid не срабатывает зря на правке одного comment -----------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

create temporary table t_snap (name text primary key, at timestamptz);
grant select, insert on t_snap to authenticated;

insert into t_snap (name, at)
select 'before', updated_at from public.subscriptions where id = '88888888-0000-0000-0000-000000000001';

-- Разрешённая прямая правка (grant update (comment) on payments) — единственное
-- поле, доступное клиенту напрямую.
update public.payments set comment = 'правка комментария'
 where id = (select id from t_pay where name = 'p1');

select is(
  (select updated_at from public.subscriptions where id = '88888888-0000-0000-0000-000000000001'),
  (select at from t_snap where name = 'before'),
  'Правка только comment у payments не трогает subscriptions.updated_at — payments_recalc_paid не сработал (триггер сузен до amount_tiyin/subscription_id)'
);

reset role;


-- 18. ru_month_year по всем двенадцати месяцам ---------------------------------------

select set_eq(
  $q$ select extract(month from d)::int, public.ru_month_year(d)
        from generate_series('2026-01-01'::date, '2026-12-01'::date, interval '1 month') d $q$,
  $q$ values
    (1,'январь 2026'),(2,'февраль 2026'),(3,'март 2026'),(4,'апрель 2026'),
    (5,'май 2026'),(6,'июнь 2026'),(7,'июль 2026'),(8,'август 2026'),
    (9,'сентябрь 2026'),(10,'октябрь 2026'),(11,'ноябрь 2026'),(12,'декабрь 2026') $q$,
  'ru_month_year верно называет все двенадцать месяцев — сдвиг индекса массива задел бы один и не был бы виден на случайном месяце'
);


-- 19. Прямой вызов seed_payment_sources вне триггера отбивается (находка Б1) --------

-- Не set local role authenticated: тогда упало бы на гранте (её нет в
-- белом списке 0007), а не на проверяемой здесь ветке кода. auth.uid()
-- берётся из tests_claims, роль в сессии остаётся postgres — pg_trigger_
-- depth() = 0, auth.uid() не null, ровно прямой вызов живым пользователем.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');

select throws_ok(
  $q$ select public.seed_payment_sources('cccccccc-0000-0000-0000-00000000000a') $q$,
  '42501', 'Недостаточно прав',
  'Прямой вызов seed_payment_sources (не из триггера centers) отбивается'
);


-- 20. Онбординг настоящим пользователем — create_center не падает на своём же
--     триггере (находка Б1: прежняя проверка отбивала ровно вызов из
--     centers_seed_payment_sources, роли у только что созданного центра ещё нет)

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values (
  '00000000-0000-0000-0000-000000000000','99999999-9999-9999-9999-999999999999',
  'authenticated','authenticated','new-owner@test.kg','','','','','','','',''
);

select public.tests_claims('99999999-9999-9999-9999-999999999999', null);
set local role authenticated;

create temporary table t_center (name text primary key, id uuid);
grant select, insert on t_center to authenticated;

select lives_ok(
  $q$ insert into t_center (name, id) select 'new', public.create_center('Новый центр', 'Бишкек') $q$,
  'create_center от пользователя без единого членства не падает (до фикса — 42501 из seed_payment_sources)'
);

reset role;

select is(
  (select count(*)::int from public.payment_sources
    where center_id = (select id from t_center where name = 'new')),
  5,
  'Пять источников оплаты заведены для только что созданного центра'
);


-- 21. close_month блокирует занятие без единого участника (находка Б5) -------------

-- Симулирует групповое занятие, из которого вышли все участники: обычное
-- занятие, автосозданную запись в lesson_participants убираем как postgres
-- (тот же приём, что и с attendance — фикстуре нужна не РЕАЛЬНАЯ группа,
-- а именно пустой состав на дату). До Б5 inner join выкидывал такое занятие
-- из подсчёта вовсе, и месяц закрывался, хотя отметить участие здесь
-- физически нельзя.
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status) values
  ('44444444-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a',
   '99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-000000000001',
   date_trunc('month', now() - interval '4 months') + interval '10 days',
   date_trunc('month', now() - interval '4 months') + interval '10 days' + interval '45 min', 'done');

delete from public.lesson_participants where lesson_id = '44444444-0000-0000-0000-000000000003';

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '4 months')::date) $q$,
  '22023', null,
  'close_month отклонён: занятие без единого участника не должно выпадать из подсчёта (left join, не inner)'
);


-- 22. Вставка занятия задним числом в закрытый месяц отклонена ----------------------

-- Доп. ветка находки 3: расширенный триггер ловит не только update (перенос),
-- но и insert — до этого объявление было "before update", insert ничем не
-- перекрывался.
select throws_ok(
  format($q$ insert into public.lessons (center_id, service_id, teacher_id, student_id, starts_at, ends_at)
             values ('cccccccc-0000-0000-0000-00000000000a', '99999999-0000-0000-0000-000000000001',
                     'aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', %L, %L) $q$,
    (date_trunc('month', now() - interval '2 months') + interval '20 days'),
    (date_trunc('month', now() - interval '2 months') + interval '20 days' + interval '45 min')),
  '22023', null,
  'Занятие, вставленное датой в уже закрытый месяц (M1), отклонено замком'
);

reset role;


-- 23-24. Бэкфилл истории подхватывает плательщика из subscriptions, не только из
--        текущего students.payer_id (находка Б4) ------------------------------------

-- Третий, ни разу не бывший students.payer_id этого ребёнка плательщик —
-- изолирует именно ветку subscriptions.payer_id от уже проверенной ветки
-- "смена students.payer_id заводит запись триггером" (тесты 2-4 выше).
insert into public.payers (id, center_id, full_name, phone) values
  ('bbbbbbbb-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Третья Плательщица','+996700555666');

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at)
values ('88888888-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a',
        'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000003',
        '77777777-0000-0000-0000-000000000001', 8, 400000, 50000, current_date - 30);

select is(
  (select count(*)::int from public.student_payers
    where student_id = 'eeeeeeee-0000-0000-0000-000000000001'
      and payer_id = 'bbbbbbbb-0000-0000-0000-000000000003'),
  0,
  'До вызова бэкфилла пара «плательщик из подписки» в student_payers ещё не появлялась'
);

-- reset role возвращает роль postgres, но не трогает request.jwt.claims —
-- он transaction-local (set_config(..., true)) и держит значение из
-- последнего tests_claims (тест 22) до конца транзакции. Без явного
-- обнуления auth.uid() здесь всё ещё не null, и функция отбила бы
-- собственный же вызов (та же проверка, что и у backfill_subscription_
-- payments/seed_payment_sources).
select public.tests_claims(null, null);

select public.backfill_student_payers_history();

select is(
  (select count(*)::int from public.student_payers
    where student_id = 'eeeeeeee-0000-0000-0000-000000000001'
      and payer_id = 'bbbbbbbb-0000-0000-0000-000000000003'),
  1,
  'backfill_student_payers_history подхватывает плательщика из subscriptions.payer_id (Б4)'
);

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select lives_ok(
  $q$ select public.record_payment('bbbbbbbb-0000-0000-0000-000000000003', 10000, 'payment',
                                   'eeeeeeee-0000-0000-0000-000000000001', '88888888-0000-0000-0000-000000000003') $q$,
  'Платёж от плательщика подписки проходит FK — до Б4 своп constraint падал бы именно на этой связке на живых данных'
);

reset role;

select * from finish();

rollback;
