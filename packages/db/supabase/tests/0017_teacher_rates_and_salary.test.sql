-- pgTAP: ставки специалистов и расчёт зарплаты (миграция 0017).
-- Даты тестовых занятий — прошлый месяц (now() - 1 month), не текущий: в
-- первые дни месяца "текущий месяц + 10 дней" рисковал бы оказаться в
-- будущем (тот же урок, что уже стоил трёх кругов CI в этой сессии на
-- e2e-фикстуре). M1 = позапрошлый месяц — единственный, который здесь
-- закрывается, по тому же соглашению, что 0013/0016.
--
-- Claims выставляются ДО первой сырой вставки в attendance: attendance_recalc
-- (after insert) зовёт emit_event, а тот падает на auth.uid() is null — та
-- же находка, что стоила правки 0013.test. reset role claims не сбрасывает.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(65);

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-b@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher1@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher2@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','revoked@test.kg','','','','','','','','');

-- plan = 'center': фикстура заводит 9 специалистов, а trial с 0049 ограничен
-- пятью — лимит держится триггером и на тестовых данных тоже.
-- subscription_until: с 0050 платный тариф без срока — только чтение.
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-sal','center', now() + interval '1 year','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-sal','center', now() + interval '1 year','{"timezone":"Asia/Bishkek"}'::jsonb);

-- t1/t2 — с полным членством (нужны для ролевых тестов: "специалист видит
-- только своё"). Остальные — только карточка, без входа: calc_salary/
-- record_salary_adjustment от owner/admin членства не требуют вовсе.
-- Специалист центра Б — только для теста составного FK на lessons.
insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист 1 (per_lesson)'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Специалист 2 (замена)'),
  ('aaaaaaaa-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Специалист 3 (per_hour)'),
  ('aaaaaaaa-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','Специалист 4 (percent_payment)'),
  ('aaaaaaaa-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-00000000000a','Специалист 5 (per_student)'),
  ('aaaaaaaa-0000-0000-0000-000000000006','cccccccc-0000-0000-0000-00000000000a','Специалист 6 (без ставки)'),
  ('aaaaaaaa-0000-0000-0000-000000000007','cccccccc-0000-0000-0000-00000000000a','Специалист 7 (специфичность ставки)'),
  ('aaaaaaaa-0000-0000-0000-000000000008','cccccccc-0000-0000-0000-00000000000a','Специалист 8 (per_lesson, группа)'),
  ('aaaaaaaa-0000-0000-0000-000000000009','cccccccc-0000-0000-0000-00000000000a','Специалист 9 (per_hour, группа)'),
  ('aaaaaaaa-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Специалист центра Б');

insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner', null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner', null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-00000000000a','teacher', 'aaaaaaaa-0000-0000-0000-000000000002'),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','parent', null);

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик','+996700000001');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок 1','dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Ребёнок 2','dddddddd-0000-0000-0000-000000000001',null),
  ('eeeeeeee-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Ребёнок 3','dddddddd-0000-0000-0000-000000000001',null);

insert into public.services (id, center_id, name, duration_min, default_price_tiyin, kind) values
  ('f1111111-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Индивидуальное',45,50000,'individual'),
  ('f1111111-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Групповое',60,30000,'group'),
  ('f1111111-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','Индивидуальное (зеркало специфичности)',45,50000,'individual');

insert into public.groups (id, center_id, name, service_id, teacher_id) values
  ('99999999-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Группа','f1111111-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000005');

-- joined_at — явно и раньше всех занятий фикстуры. Дефолт current_date
-- (сегодня) позже занятий прошлого месяца, а rebuild_lesson_participants
-- берёт состав по joined_at <= starts_at::date — состав групповых занятий
-- был бы пуст, и первая же отметка падала бы на "не участник занятия"
-- (та же ловушка, что описана в 0015.test; стоила красного db-джоба).
insert into public.group_students (center_id, group_id, student_id, joined_at) values
  ('cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
   (date_trunc('month', now() - interval '2 months'))::date),
  ('cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000002',
   (date_trunc('month', now() - interval '2 months'))::date),
  ('cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000003',
   (date_trunc('month', now() - interval '2 months'))::date);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

create temporary table t_sal (name text primary key, id uuid);
grant select, insert on t_sal to authenticated;

-- Claims владельца А — до любой сырой вставки в attendance (см. шапку).
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');


-- 1. Ставки заводятся заранее (as postgres — прямой insert доступен owner,
--    но фикстуре гранты не нужны) --------------------------------------------

insert into public.teacher_rates (center_id, teacher_id, service_id, model, value, valid_from) values
  ('cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001', null, 'per_lesson', 30000,
    (date_trunc('month', now() - interval '1 month'))::date),
  ('cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000003', null, 'per_hour', 40000,
    (date_trunc('month', now() - interval '1 month'))::date),
  ('cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000004', null, 'percent_payment', 3000,
    (date_trunc('month', now() - interval '1 month'))::date),
  ('cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000005', null, 'per_student', 10000,
    (date_trunc('month', now() - interval '1 month'))::date),
  ('cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000008', null, 'per_lesson', 45000,
    (date_trunc('month', now() - interval '1 month'))::date),
  ('cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000009', null, 'per_hour', 40000,
    (date_trunc('month', now() - interval '1 month'))::date);

-- Специалист 7 — отдельно от чек-листа (специалист 1), чтобы частные ставки
-- не заражали его сумму. Общая ставка НОВЕЕ обеих частных: иначе "order by
-- valid_from desc" без ключа специфичности дал бы тот же ответ, и тест
-- проходил бы на реализации, где специфичность выкинута (находка 12 первого
-- раунда, Б7 второго). Частная по услуге 1 дороже общей, по услуге 3 —
-- дешевле: побеждать обязана в обоих случаях, "самая дорогая" — не объяснение.
insert into public.teacher_rates (center_id, teacher_id, service_id, model, value, valid_from) values
  ('cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000007', null, 'per_lesson', 20000,
    (date_trunc('month', now() - interval '1 month'))::date),
  ('cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000007',
   'f1111111-0000-0000-0000-000000000001', 'per_lesson', 25000,
   (date_trunc('month', now() - interval '1 month'))::date - 10),
  ('cccccccc-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000007',
   'f1111111-0000-0000-0000-000000000003', 'per_lesson', 15000,
   (date_trunc('month', now() - interval '1 month'))::date - 10);


-- 2. Занятия и отметки прошлого месяца — специалист 1, per_lesson ------------

-- Чек-лист этапа: ставка 300 сом/занятие (30000 тыйын) → 5 "пришёл" + 1
-- "болел" → зарплата 1500 сом (150000). Даты — прошлый месяц (безопасно в
-- прошлом независимо от того, какое сегодня число).
do $$
declare
  v_base timestamptz := date_trunc('month', now() - interval '1 month') + interval '10 days' + interval '9 hours';
  v_lesson_id uuid;
  v_status_present uuid;
  v_status_sick uuid;
  i int;
begin
  select id into v_status_present from public.attendance_statuses
   where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';
  select id into v_status_sick from public.attendance_statuses
   where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'sick';

  for i in 0..5 loop
    v_lesson_id := ('44440000-0000-0000-0000-00000000000' || i)::uuid;
    insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status)
    values (v_lesson_id, 'cccccccc-0000-0000-0000-00000000000a', 'f1111111-0000-0000-0000-000000000001',
            'aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001',
            v_base + (i || ' hours')::interval, v_base + (i || ' hours')::interval + interval '45 min', 'done');

    insert into public.attendance (center_id, lesson_id, student_id, status_id)
    values ('cccccccc-0000-0000-0000-00000000000a', v_lesson_id, 'eeeeeeee-0000-0000-0000-000000000001',
            case when i = 5 then v_status_sick else v_status_present end);
  end loop;
end $$;

set local role authenticated;

-- 1-3.
select is(
  (select count(*)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000001',
     (date_trunc('month', now() - interval '1 month'))::date)),
  6,
  'calc_salary возвращает все 6 отметок, включая неоплачиваемую — "болел" не исчезает из детализации'
);

select is(
  (select coalesce(sum(amount_tiyin), 0)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000001',
     (date_trunc('month', now() - interval '1 month'))::date)),
  150000,
  'Чек-лист этапа: ставка 300 сом/занятие × 5 "пришёл" = 1500 сом (150000 тыйын)'
);

select is(
  (select model from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000001',
     (date_trunc('month', now() - interval '1 month'))::date) limit 1),
  'per_lesson',
  'Модель верно определена как per_lesson'
);

reset role;


-- 4-5. Специфичность важнее свежести — в обе стороны по цене -------------------

insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status)
values
  ('44440000-0000-0000-0000-000000000020','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000007','eeeeeeee-0000-0000-0000-000000000001',
   date_trunc('month', now() - interval '1 month') + interval '10 days',
   date_trunc('month', now() - interval '1 month') + interval '10 days' + interval '45 min', 'done'),
  ('44440000-0000-0000-0000-000000000021','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000003',
   'aaaaaaaa-0000-0000-0000-000000000007','eeeeeeee-0000-0000-0000-000000000001',
   date_trunc('month', now() - interval '1 month') + interval '15 days',
   date_trunc('month', now() - interval '1 month') + interval '15 days' + interval '45 min', 'done');

set local role authenticated;

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', l.id, 'eeeeeeee-0000-0000-0000-000000000001', st.id
  from unnest(array['44440000-0000-0000-0000-000000000020'::uuid,
                     '44440000-0000-0000-0000-000000000021'::uuid]) as l(id),
       (select id from public.attendance_statuses
         where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present') as st(id);

select is(
  (select amount_tiyin from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000007',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000020'),
  25000,
  'Частная ставка по услуге (25000, СТАРШЕ) побеждает общую (20000, новее) — специфичность важнее свежести'
);

select is(
  (select amount_tiyin from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000007',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000021'),
  15000,
  'Зеркало: частная дешевле общей (15000 < 20000) и тоже старше — побеждает всё равно, "самая дорогая/свежая" не объяснение'
);


-- 6. "Болел" не платит, отдельной строкой с причиной ----------------------------

select is(
  (select count(*)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000001',
     (date_trunc('month', now() - interval '1 month'))::date)
    where amount_tiyin = 0 and note = 'статус не оплачивается'),
  1,
  'Ровно одна строка "болел" — amount 0, причина явная, не пропала из выдачи'
);

reset role;


-- 7-8. Круг "пришёл → болел → пришёл" возвращает pays_teacher к true -----------

-- Прямая проверка находки 4: реализация "в лоб" (заморозить как price_tiyin)
-- сломала бы этот круг — pays_teacher остался бы false навсегда.
set local role authenticated;

select public.mark_attendance('44440000-0000-0000-0000-000000000000','eeeeeeee-0000-0000-0000-000000000001','sick');

select is(
  (select pays_teacher from public.attendance
    where lesson_id = '44440000-0000-0000-0000-000000000000'
      and student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  false,
  'pays_teacher следует за статусом при смене — стало false на "болел"'
);

select public.mark_attendance('44440000-0000-0000-0000-000000000000','eeeeeeee-0000-0000-0000-000000000001','present');

select is(
  (select pays_teacher from public.attendance
    where lesson_id = '44440000-0000-0000-0000-000000000000'
      and student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  true,
  'Круг "пришёл → болел → пришёл" возвращает pays_teacher к true (не заморожен, как price_tiyin/subscription_id)'
);

reset role;


-- 9-10. Замена специалиста не переносит уже отмеченную оплату задним числом ---

-- attendance ...000 уже отмечена (тесты 7-8) как paid_teacher_id=t1.
-- substitute_teacher на этом занятии НЕ должен задним числом переписать,
-- кому идёт уже начисленная оплата (находка 3 — платит замороженный
-- paid_teacher_id, не живой effective_teacher_id).
set local role authenticated;

select public.substitute_teacher('44440000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000002');

select is(
  (select paid_teacher_id from public.attendance
    where lesson_id = '44440000-0000-0000-0000-000000000000'
      and student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
  'paid_teacher_id остаётся у изначального специалиста — замена задним числом не переносит уже начисленную оплату'
);

select is(
  (select count(*)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000002',
     (date_trunc('month', now() - interval '1 month'))::date)),
  0,
  'У специалиста-заменщика в зарплате прошлого месяца по-прежнему ничего нет'
);

reset role;


-- 11. per_hour — округление до ближайшего, не усечение -------------------------

insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status)
values ('44440000-0000-0000-0000-000000000010','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000003','eeeeeeee-0000-0000-0000-000000000001',
        date_trunc('month', now() - interval '1 month') + interval '11 days',
        -- 47 минут при ставке 400 сом/час: 40000×47×60/3600 = 31333.33 —
        -- округление до ближайшего целого тыйына даёт 31333 (не 31334 —
        -- .33 округляется вниз), проверяет именно формулу (a*b+d/2)/d,
        -- а не совпадение с "круглым" числом.
        date_trunc('month', now() - interval '1 month') + interval '11 days' + interval '47 min',
        'done');

set local role authenticated;

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', '44440000-0000-0000-0000-000000000010',
       'eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';

select is(
  (select amount_tiyin from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000003',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000010'),
  31333,
  'per_hour: 47 минут × 400 сом/час = 31333.33 тыйын, округление до ближайшего целого — 31333'
);

reset role;


-- 12. percent_payment — включая безлимитный абонемент (price_tiyin=0) ----------

insert into public.subscription_types (id, center_id, name, service_id, kind, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Безлимит',
   'f1111111-0000-0000-0000-000000000001','unlimited',500000);

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                   lesson_price_tiyin, starts_at)
values ('88880000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
        'eeeeeeee-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001',
        '77777777-0000-0000-0000-000000000001', null, 500000, null,
        (date_trunc('month', now() - interval '1 month'))::date);

insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status)
values ('44440000-0000-0000-0000-000000000011','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000004','eeeeeeee-0000-0000-0000-000000000001',
        date_trunc('month', now() - interval '1 month') + interval '12 days',
        date_trunc('month', now() - interval '1 month') + interval '12 days' + interval '45 min', 'done');

set local role authenticated;

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', '44440000-0000-0000-0000-000000000011',
       'eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';

select is(
  (select amount_tiyin from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000004',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000011'),
  0,
  'percent_payment на безлимитном абонементе: price_tiyin=0 (lesson_price_tiyin null) → amount 0, не молчаливая ошибка'
);

reset role;


-- 13-14. per_student — групповое занятие, три ребёнка ---------------------------

insert into public.lessons (id, center_id, service_id, teacher_id, group_id, starts_at, ends_at, status)
values ('44440000-0000-0000-0000-000000000012','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000002',
        'aaaaaaaa-0000-0000-0000-000000000005', '99999999-0000-0000-0000-000000000001',
        date_trunc('month', now() - interval '1 month') + interval '13 days',
        date_trunc('month', now() - interval '1 month') + interval '13 days' + interval '60 min', 'done');

set local role authenticated;

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', '44440000-0000-0000-0000-000000000012', s.id, st.id
  from unnest(array['eeeeeeee-0000-0000-0000-000000000001'::uuid,
                     'eeeeeeee-0000-0000-0000-000000000002'::uuid,
                     'eeeeeeee-0000-0000-0000-000000000003'::uuid]) as s(id),
       (select id from public.attendance_statuses
         where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present') as st(id);

select is(
  (select count(*)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000005',
     (date_trunc('month', now() - interval '1 month'))::date)),
  3,
  'per_student: три строки детализации — по одной на ребёнка'
);

select is(
  (select coalesce(sum(amount_tiyin), 0)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000005',
     (date_trunc('month', now() - interval '1 month'))::date)),
  30000,
  'per_student: 100 сом × 3 ребёнка = 300 сом (30000 тыйын) — каждая строка платит отдельно'
);

reset role;


-- 15-18. per_lesson на групповом занятии: платит первая ПЛАТЯЩАЯ строка --------

-- Ребёнок 1 (наименьший student_id) "болел", 2 и 3 пришли. До правки
-- row_number шёл по student_id без учёта pays_teacher: "болел" получал rn=1
-- и amount 0 как неоплачиваемый, а дети 2 и 3 — amount 0 с причиной
-- "оплачено в другой строке". Итого за состоявшееся занятие — 0 и ложь в
-- двух строках (находка Б2 архитектора).
insert into public.lessons (id, center_id, service_id, teacher_id, group_id, starts_at, ends_at, status)
values ('44440000-0000-0000-0000-000000000014','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000002',
        'aaaaaaaa-0000-0000-0000-000000000008', '99999999-0000-0000-0000-000000000001',
        date_trunc('month', now() - interval '1 month') + interval '16 days' + interval '10 hours',
        date_trunc('month', now() - interval '1 month') + interval '16 days' + interval '11 hours', 'done');

set local role authenticated;

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', '44440000-0000-0000-0000-000000000014', s.id, st.id
  from (values ('eeeeeeee-0000-0000-0000-000000000001'::uuid, 'sick'),
               ('eeeeeeee-0000-0000-0000-000000000002'::uuid, 'present'),
               ('eeeeeeee-0000-0000-0000-000000000003'::uuid, 'present')) as s(id, code)
  join public.attendance_statuses st
    on st.center_id = 'cccccccc-0000-0000-0000-00000000000a' and st.code = s.code;

select is(
  (select coalesce(sum(amount_tiyin), 0)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000008',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000014'),
  45000,
  'per_lesson на группе: одна ставка за состоявшееся занятие (45000), а не 0 из-за "болел" на первой позиции'
);

select is(
  (select note from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000008',
     (date_trunc('month', now() - interval '1 month'))::date)
    where student_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  'статус не оплачивается',
  'Ребёнок 1 ("болел") — своя причина, не ложное "оплачено в другой строке"'
);

select is(
  (select amount_tiyin from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000008',
     (date_trunc('month', now() - interval '1 month'))::date)
    where student_id = 'eeeeeeee-0000-0000-0000-000000000002'),
  45000,
  'Платит первая ПЛАТЯЩАЯ строка — ребёнок 2, а не первая по student_id'
);

select is(
  (select note from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000008',
     (date_trunc('month', now() - interval '1 month'))::date)
    where student_id = 'eeeeeeee-0000-0000-0000-000000000003'),
  'оплачено в другой строке занятия',
  'Ребёнок 3 (пришёл, вторая платящая позиция) — честное "оплачено в другой строке"'
);

reset role;


-- 19-20. per_hour на групповом занятии: час работы один, детей трое ------------

-- До правки per_hour считался на каждой строке attendance: 60 минут × 400
-- сом/час × 3 ребёнка = 1200 сом за один час (находка Б1 архитектора).
insert into public.lessons (id, center_id, service_id, teacher_id, group_id, starts_at, ends_at, status)
values ('44440000-0000-0000-0000-000000000015','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000002',
        'aaaaaaaa-0000-0000-0000-000000000009', '99999999-0000-0000-0000-000000000001',
        date_trunc('month', now() - interval '1 month') + interval '17 days' + interval '10 hours',
        date_trunc('month', now() - interval '1 month') + interval '17 days' + interval '11 hours', 'done');

set local role authenticated;

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', '44440000-0000-0000-0000-000000000015', s.id, st.id
  from unnest(array['eeeeeeee-0000-0000-0000-000000000001'::uuid,
                     'eeeeeeee-0000-0000-0000-000000000002'::uuid,
                     'eeeeeeee-0000-0000-0000-000000000003'::uuid]) as s(id),
       (select id from public.attendance_statuses
         where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present') as st(id);

select is(
  (select coalesce(sum(amount_tiyin), 0)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000009',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000015'),
  40000,
  'per_hour на группе: 60 минут × 400 сом/час = 40000 один раз, не ×3 по числу детей'
);

select is(
  (select count(*)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000009',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000015' and amount_tiyin > 0),
  1,
  'Платит ровно одна строка занятия, остальные — 0 с причиной'
);

reset role;


-- 21-25. Без ставки и непроведённое занятие — не исчезают из выдачи ------------

insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status)
values
  ('44440000-0000-0000-0000-000000000013','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000006','eeeeeeee-0000-0000-0000-000000000001',
   date_trunc('month', now() - interval '1 month') + interval '14 days',
   date_trunc('month', now() - interval '1 month') + interval '14 days' + interval '45 min', 'done'),
  -- Отметка есть, а занятие так и не переведено в done ("Занятие проведено"
  -- — отдельное действие). До правки строка молча исчезала из calc_salary
  -- (фильтр status='done' в where), в отличие от "ставка не задана" и
  -- "статус не оплачивается" — администратор недосчитывался, не зная об
  -- этом (находка Б4 архитектора).
  ('44440000-0000-0000-0000-000000000016','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000006','eeeeeeee-0000-0000-0000-000000000001',
   date_trunc('month', now() - interval '1 month') + interval '18 days',
   date_trunc('month', now() - interval '1 month') + interval '18 days' + interval '45 min', 'planned');

set local role authenticated;

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', l.id, 'eeeeeeee-0000-0000-0000-000000000001', st.id
  from unnest(array['44440000-0000-0000-0000-000000000013'::uuid,
                     '44440000-0000-0000-0000-000000000016'::uuid]) as l(id),
       (select id from public.attendance_statuses
         where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present') as st(id);

select is(
  (select count(*)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000006',
     (date_trunc('month', now() - interval '1 month'))::date)),
  2,
  'Обе строки специалиста 6 в выдаче — без ставки и по непроведённому занятию, ни одна не отфильтрована'
);

select is(
  (select coalesce(sum(amount_tiyin), 0)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000006',
     (date_trunc('month', now() - interval '1 month'))::date)),
  0,
  'Сумма по ним — 0, не пропущена молча'
);

select is(
  (select note from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000006',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000013'),
  'ставка не задана',
  'Проведённое занятие без ставки — причина "ставка не задана"'
);

select is(
  (select amount_tiyin from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000006',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000016'),
  0,
  'Занятие в статусе planned с отметкой "пришёл" — amount 0: фильтр done ограничивает оплату'
);

select is(
  (select note from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000006',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000016'),
  'занятие не проведено',
  '...но не видимость: причина "занятие не проведено" — администратор видит, что утверждать рано'
);

reset role;


-- 26-30. Изоляция и роли --------------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;

select throws_ok(
  format($q$ select * from public.calc_salary(%L, (date_trunc('month', now() - interval '1 month'))::date) $q$,
    'aaaaaaaa-0000-0000-0000-000000000001'),
  '42704', null,
  'calc_salary: владелец центра Б не видит специалиста центра А — 42704, не пустой результат'
);

reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select ok(
  (select count(*)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000001',
     (date_trunc('month', now() - interval '1 month'))::date)) > 0,
  'Специалист 1 видит свою зарплату через calc_salary(свой teacher_id)'
);

select throws_ok(
  format($q$ select * from public.calc_salary(%L, (date_trunc('month', now() - interval '1 month'))::date) $q$,
    'aaaaaaaa-0000-0000-0000-000000000003'),
  '42501', 'Недостаточно прав',
  'Специалист 1 не может позвать calc_salary с чужим teacher_id (специалиста 3)'
);

select is(
  (select count(*)::int from public.teacher_rates where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000003'),
  0,
  'Специалист 1 не видит ставки специалиста 3 — teacher_rates_read_own фильтрует по my_teacher_id()'
);

reset role;

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  format($q$ select * from public.calc_salary(%L, (date_trunc('month', now() - interval '1 month'))::date) $q$,
    'aaaaaaaa-0000-0000-0000-000000000001'),
  '42501', null,
  'Родитель не может звать calc_salary вовсе'
);

reset role;


-- 31. Специалисту скрыта цена занятия там, где это не его собственный процент --

-- Специалист 1 (модель per_lesson) смотрит свою же зарплату — lesson_price_
-- tiyin в его строках был бы ценой абонемента конкретного ребёнка (ADR-005),
-- а ему для per_lesson не нужен вовсе: должен быть скрыт (null), не только
-- для percent_payment других специалистов.
select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000001',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_price_tiyin is not null),
  0,
  'Специалист 1 (модель per_lesson) не видит lesson_price_tiyin своих строк — поле раскрывается только для его собственной percent_payment'
);

reset role;


-- 32-35. Прямая запись закрыта, гранты ------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select ok(
  not has_table_privilege('authenticated', 'public.teacher_rates', 'UPDATE'),
  'authenticated не может изменить ставку — только новая строка'
);
select ok(
  not has_table_privilege('authenticated', 'public.teacher_rates', 'DELETE'),
  'authenticated не может удалить ставку'
);
select ok(
  not has_table_privilege('authenticated', 'public.salary_adjustments', 'INSERT'),
  'authenticated не может вставить корректировку напрямую — только через record_salary_adjustment'
);
select ok(
  not has_table_privilege('authenticated', 'public.salary_runs', 'INSERT'),
  'authenticated не может вставить строку зарплаты напрямую — только через approve_salary'
);


-- 36. created_by на teacher_rates нельзя подделать прямым insert ---------------

-- insert открыт authenticated целиком; default auth.uid() на колонке
-- подменяется явным значением в запросе — триггер обязан перетереть его.
insert into public.teacher_rates (center_id, teacher_id, service_id, model, value, valid_from, created_by)
values ('cccccccc-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000002', null, 'per_lesson', 10000,
        (date_trunc('month', now() - interval '1 month'))::date, '22222222-2222-2222-2222-222222222222');

select is(
  (select created_by from public.teacher_rates where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'created_by перетёрт триггером на auth.uid() вызывающего — подставленный uuid владельца Б не сохранился'
);

reset role;


-- 37-39. record_salary_adjustment + замок месяца --------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into t_sal (name, id)
select 'adj', public.record_salary_adjustment(
  'aaaaaaaa-0000-0000-0000-000000000001',
  (date_trunc('month', now() - interval '1 month'))::date,
  50000, 'Премия за месяц'
);

select is(
  (select created_by from public.salary_adjustments where id = (select id from t_sal where name = 'adj')),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'created_by — auth.uid() вызывающего, не то, что мог бы прислать клиент'
);

select lives_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  'close_month(M1, позапрошлый) проходит — в M1 нет ни занятий, ни расходов'
);

select throws_ok(
  format($q$ select public.record_salary_adjustment(%L, %L, 10000, 'штраф') $q$,
    'aaaaaaaa-0000-0000-0000-000000000001',
    (date_trunc('month', now() - interval '2 months'))::date),
  '22023', null,
  'record_salary_adjustment на уже закрытый месяц (M1) отклонён замком'
);


-- 40. Ставка задним числом в закрытый месяц — замок financial_period_guard ------

select throws_like(
  format($q$ insert into public.teacher_rates (center_id, teacher_id, service_id, model, value, valid_from)
             values (%L, %L, null, 'per_hour', 50000, %L) $q$,
    'cccccccc-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000003',
    (date_trunc('month', now() - interval '2 months'))::date + 5),
  '%закрыт%',
  'Ставка с valid_from в закрытом M1 отбита замком месяца — append-only сам по себе этого не защищал'
);

reset role;


-- 41-43. approve_salary — только прошедший месяц, снимок, идемпотентность -------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  format($q$ select public.approve_salary(%L, %L) $q$,
    'aaaaaaaa-0000-0000-0000-000000000001',
    date_trunc('month', public.center_today('cccccccc-0000-0000-0000-00000000000a'))::date),
  '22023', null,
  'approve_salary за текущий месяц отклонён — утверждать можно только полностью прошедший (как close_month)'
);

insert into t_sal (name, id)
select 'run', public.approve_salary('aaaaaaaa-0000-0000-0000-000000000001',
  (date_trunc('month', now() - interval '1 month'))::date);

select is(
  (select total_tiyin from public.salary_runs where id = (select id from t_sal where name = 'run')),
  200000,
  'approve_salary: 150000 (calc_salary, чек-лист) + 50000 (премия из теста 37) = 200000 — та же пропорция 1500→2000, что в чек-листе этапа, тыйынами вместо сомов'
);

select throws_ok(
  format($q$ select public.approve_salary(%L, %L) $q$,
    'aaaaaaaa-0000-0000-0000-000000000001',
    (date_trunc('month', now() - interval '1 month'))::date),
  '23505', null,
  'Повторное approve_salary того же специалиста за тот же месяц — unique_violation, не дубль строки'
);


-- 44. Ставка задним числом в месяц с утверждённой зарплатой ---------------------

-- Месяц при этом НЕ закрыт (close_month был только для M1) — это второй,
-- независимый от financial_period_guard замок.
select throws_like(
  format($q$ insert into public.teacher_rates (center_id, teacher_id, service_id, model, value, valid_from)
             values (%L, %L, null, 'per_lesson', 50000, %L) $q$,
    'cccccccc-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001',
    (date_trunc('month', now() - interval '1 month'))::date + 15),
  '%уже утверждена%',
  'Ставка задним числом в месяц с утверждённым снимком отбита — новая строка меняла бы calc_salary так же, как правка'
);


-- 45-52. salary_summary — итог по специалистам одним вызовом --------------------

select is(
  (select total_tiyin from public.salary_summary((date_trunc('month', now() - interval '1 month'))::date)
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  200000,
  'salary_summary: у специалиста 1 итог — из утверждённого снимка (200000), не пересчёт'
);

select is(
  (select approved_run_id from public.salary_summary((date_trunc('month', now() - interval '1 month'))::date)
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  (select id from t_sal where name = 'run'),
  'salary_summary: approved_run_id указывает на снимок approve_salary'
);

select is(
  (select total_tiyin from public.salary_summary((date_trunc('month', now() - interval '1 month'))::date)
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000005'),
  30000,
  'salary_summary: у неутверждённого специалиста 5 — живой расчёт (30000) + корректировки (0)'
);

select ok(
  (select approved_run_id is null from public.salary_summary((date_trunc('month', now() - interval '1 month'))::date)
    where teacher_id = 'aaaaaaaa-0000-0000-0000-000000000005'),
  'salary_summary: у неутверждённого специалиста approved_run_id пуст'
);

select is(
  (select count(*)::int from public.salary_summary((date_trunc('month', now() - interval '1 month'))::date)),
  9,
  'salary_summary для owner — строка на каждого живого специалиста центра А (9), центр Б не виден'
);

reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select array_agg(teacher_id) from public.salary_summary((date_trunc('month', now() - interval '1 month'))::date)),
  array['aaaaaaaa-0000-0000-0000-000000000001'::uuid],
  'salary_summary для teacher — ровно своя строка, чужих специалистов нет'
);

select is(
  (select count(*)::int from public.salary_runs),
  0,
  'Специалист не читает salary_runs напрямую вовсе — lines с ценами абонементов недоступны в обход маскировки calc_salary (нет _read_own)'
);

reset role;

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select * from public.salary_summary((date_trunc('month', now() - interval '1 month'))::date) $q$,
  '42501', null,
  'Родитель не может звать salary_summary'
);

reset role;


-- 53. Событие эмитировано вместе со снимком, в той же транзакции ----------------

select is(
  (select count(*)::int from public.events where type = 'salary.calculated'),
  1,
  'salary.calculated эмитирован ровно один раз, вместе с approve_salary'
);


-- 54-55. teachers — грант и archive/restore --------------------------------------

select ok(
  not has_table_privilege('authenticated', 'public.teachers', 'DELETE'),
  'authenticated не может удалить специалиста физически'
);

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select public.archive_teacher('aaaaaaaa-0000-0000-0000-000000000006');

reset role;

select is(
  (select count(*)::int from public.events where type = 'teacher.archived'),
  1,
  'archive_teacher эмитирует событие'
);


-- 56-57. Гранты новых функций — белый список 0007 актуален ----------------------

select ok(
  has_function_privilege('authenticated', 'public.calc_salary(uuid,date)', 'EXECUTE'),
  'calc_salary исполняется authenticated'
);
select ok(
  not has_function_privilege('authenticated', 'public.centers_seed_payment_sources()', 'EXECUTE'),
  'Контрольная проверка: не задели гранты не своих функций (payment_sources из 0013 по-прежнему закрыта)'
);


-- 58. financial_period_guard: ветка salary_adjustments не путает даты с payments -

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_like(
  format($q$ select public.record_salary_adjustment(%L, %L, 5000, 'после закрытия') $q$,
    'aaaaaaaa-0000-0000-0000-000000000001',
    (date_trunc('month', now() - interval '2 months'))::date),
  '%закрыт%',
  'Сообщение замка на salary_adjustments — то же читаемое "Месяц ... закрыт", что и у остальных таблиц'
);

reset role;


-- 59. Составной FK lessons → teachers: специалист чужого центра -----------------

-- До 0017 FK был только на teachers(id): RLS занятия проверяет center_id
-- строки, центр специалиста — никто. As postgres — проверяется сам
-- констрейнт, а не RLS.
--
-- 0021 добавила BEFORE-триггер lessons_check_center_refs на ту же проверку
-- (нужен, чтобы центр проверялся раньше AFTER-триггера синхронизации
-- участников — детали в 0022_center_scoped_fks.sql, раздел 3). Он всегда
-- срабатывает раньше составного FK на insert, поэтому строка теперь падает
-- на читаемых 42704, а не на голых 23503 — дыра изоляции закрыта базой
-- по-прежнему, просто другим механизмом.
select throws_ok(
  $q$ insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at, status)
      values ('44440000-0000-0000-0000-000000000030','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000001',
              'aaaaaaaa-0000-0000-0000-00000000000b','eeeeeeee-0000-0000-0000-000000000001',
              date_trunc('month', now() - interval '1 month') + interval '20 days' + interval '9 hours',
              date_trunc('month', now() - interval '1 month') + interval '20 days' + interval '9 hours 45 minutes',
              'planned') $q$,
  '42704', 'Специалист не найден в этом центре',
  'lessons_check_center_refs (0021): специалист центра Б в занятии центра А — дыра изоляции закрыта базой'
);


-- 60-62. Замена посреди отметок: одна оплата на занятие, не на специалиста ----

-- Ребёнок 1 отмечен при специалисте 8 (paid_teacher_id=8), затем замена на
-- специалиста 9, затем отмечены дети 2 и 3 (paid_teacher_id=9). До правки
-- rn_in_lesson считался поверх строк, уже отфильтрованных по специалисту:
-- 8 платил полную ставку за свою единственную строку, 9 — ещё раз за свою
-- первую (находка В3 архитектора — за один час работы центр платил дважды).
insert into public.lessons (id, center_id, service_id, teacher_id, group_id, starts_at, ends_at, status)
values ('44440000-0000-0000-0000-000000000017','cccccccc-0000-0000-0000-00000000000a','f1111111-0000-0000-0000-000000000002',
        'aaaaaaaa-0000-0000-0000-000000000008', '99999999-0000-0000-0000-000000000001',
        date_trunc('month', now() - interval '1 month') + interval '19 days' + interval '10 hours',
        date_trunc('month', now() - interval '1 month') + interval '19 days' + interval '11 hours', 'done');

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', '44440000-0000-0000-0000-000000000017',
       'eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';

select public.substitute_teacher('44440000-0000-0000-0000-000000000017','aaaaaaaa-0000-0000-0000-000000000009');

insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', '44440000-0000-0000-0000-000000000017', s.id, st.id
  from unnest(array['eeeeeeee-0000-0000-0000-000000000002'::uuid,
                     'eeeeeeee-0000-0000-0000-000000000003'::uuid]) as s(id),
       (select id from public.attendance_statuses
         where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present') as st(id);

select is(
  (select coalesce(sum(amount_tiyin), 0)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000008',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000017'),
  45000,
  'Замена посреди отметок: занятие оплачено один раз — первой платящей строке (специалист 8, ребёнок 1)'
);

select is(
  (select coalesce(sum(amount_tiyin), 0)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000009',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000017'),
  0,
  'Специалист 9 за то же занятие не получает ничего — не вторая полная ставка за тот же час'
);

select is(
  (select count(*)::int from public.calc_salary('aaaaaaaa-0000-0000-0000-000000000009',
     (date_trunc('month', now() - interval '1 month'))::date)
    where lesson_id = '44440000-0000-0000-0000-000000000017' and note = 'оплачено в другой строке занятия'),
  2,
  'Обе строки специалиста 9 видны с честной причиной: платящая строка занятия — у другого специалиста'
);


-- 63. Корректировка задним числом в месяц с утверждённой зарплатой ------------

-- approve_salary за прошлый месяц уже прошёл (тест 42). Премия после него
-- числилась бы в salary_summary.adjustments_tiyin, а total_tiyin брался бы
-- из снимка — начислено и не выплачено (находка В2 архитектора).
select throws_like(
  format($q$ select public.record_salary_adjustment(%L, %L, 10000, 'поздняя премия') $q$,
    'aaaaaaaa-0000-0000-0000-000000000001',
    (date_trunc('month', now() - interval '1 month'))::date),
  '%уже утверждена%',
  'record_salary_adjustment после approve_salary отбит триггером — тот же замок, что у ставки'
);

reset role;


-- 64-65. Контрольные суммы за весь файл ------------------------------------------

select is(
  (select count(*)::int from public.payments), 0,
  'Этот файл не создал ни одного payments'
);
select is(
  (select count(*)::int from public.salary_runs), 1,
  'Ровно один снимок зарплаты за весь файл'
);

select * from finish();

rollback;
