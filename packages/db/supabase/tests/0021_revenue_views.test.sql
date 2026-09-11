-- pgTAP: витрины выручки и кассы (миграция 0021).
-- Цены в отметки приходят сами: из services.default_price_tiyin (отметка без
-- абонемента) и из безлимитного абонемента (lesson_price_tiyin null → 0) —
-- attendance_fill_and_check перетирает price_tiyin, литералом её не задать.
-- Якорь дат — первое число прошлого месяца в UTC (t_anchor.m1): занятия на
-- 10–16-е числа в 09:00 UTC (15:00 Бишкек) — один и тот же месяц в любом
-- поясе; граница проверяется отдельным занятием в 23:30 UTC последнего дня
-- позапрошлого месяца — по Бишкеку это уже 05:30 первого числа прошлого.
-- Claims владельца А — до первой сырой вставки (emit_event требует auth.uid()).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(58);

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
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-rev','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-rev','{"timezone":"Asia/Bishkek"}'::jsonb);

-- Справочники центра А — сидами (закрыты для ролей, as postgres можно).
select public.seed_payment_sources('cccccccc-0000-0000-0000-00000000000a');
select public.seed_expense_categories('cccccccc-0000-0000-0000-00000000000a');

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Специалист 1'),
  ('aaaaaaaa-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Специалист 2');

insert into public.payers (id, center_id, full_name, phone) values
  ('dddddddd-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Плательщик','+996700000001');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner', null, null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner', null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001', null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','parent', null, 'dddddddd-0000-0000-0000-000000000001');

insert into public.students (id, center_id, full_name, payer_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Ребёнок 1','dddddddd-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Ребёнок 2','dddddddd-0000-0000-0000-000000000001');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin, kind) values
  ('f1111111-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Индивидуальное',45,50000,'individual'),
  ('f1111111-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Групповое',60,30000,'group');

insert into public.groups (id, center_id, name, service_id, teacher_id) values
  ('99999999-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Группа','f1111111-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001');

insert into public.group_students (center_id, group_id, student_id, joined_at) values
  ('cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
   (date_trunc('month', now() - interval '3 months'))::date),
  ('cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000002',
   (date_trunc('month', now() - interval '3 months'))::date);

-- Безлимит для ребёнка 2 по индивидуальной услуге: price_tiyin отметки = 0.
insert into public.subscription_types (id, center_id, name, service_id, kind, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Безлимит',
   'f1111111-0000-0000-0000-000000000001','unlimited',800000);
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                   lesson_price_tiyin, starts_at)
values ('88880000-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
        'eeeeeeee-0000-0000-0000-000000000002','dddddddd-0000-0000-0000-000000000001',
        '77777777-0000-0000-0000-000000000001', null, 800000, null,
        (date_trunc('month', now() - interval '3 months'))::date);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

-- security invoker: динамический select идёт от вызывающего — RLS и ролевой
-- фильтр витрины работают как для живого пользователя.
create or replace function public.tests_count(p_sql text)
  returns bigint language plpgsql as $$
declare n bigint;
begin
  execute p_sql into n;
  return n;
end;
$$;
grant execute on function public.tests_count(text) to authenticated;

-- Якорь: первое число прошлого месяца, полночь UTC (timestamp без пояса).
create temporary table t_anchor as
  select date_trunc('month', (now() at time zone 'UTC') - interval '1 month') as m1;
grant select on t_anchor to authenticated;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');

-- Занятия (все в прошлом, разные дни, 09:00 UTC = 15:00 Бишкек):
--   L1 t1 s1 svc1 done            → 50000 (без абонемента — цена услуги)
--   L2 t1 s1 svc1 done + замена   → 50000, paid_teacher_id остаётся t1
--   L3 t2 s1 svc1 done            → 50000
--   L4 t1 s1 svc1 planned         → deducted, но не в выручке
--   L5 t1 s1 svc1 done → отмена   → не в выручке
--   L6 t1 группа svc2 done        → s1 30000 + s2 30000 (безлимит по svc1 не подходит)
--   L7 t2 s2 svc1 done            → 0 (безлимит) — unpriced
--   L8 t1 s1 svc1 done, M-2       → 50000 в позапрошлом месяце
--   L9 t2 s1 svc1 done, 23:30 UTC последнего дня M-2 → по Бишкеку M-1
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, group_id, starts_at, ends_at, status)
select x.id, 'cccccccc-0000-0000-0000-00000000000a', x.svc, x.t, x.s, x.g,
       x.starts, x.starts + interval '45 min', x.st
  from t_anchor a,
  lateral (values
    ('44440000-0000-0000-0000-000000000001'::uuid,'f1111111-0000-0000-0000-000000000001'::uuid,'aaaaaaaa-0000-0000-0000-000000000001'::uuid,'eeeeeeee-0000-0000-0000-000000000001'::uuid,null::uuid,(a.m1 + interval '10 days 9 hours') at time zone 'UTC','done'),
    ('44440000-0000-0000-0000-000000000002','f1111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',null,(a.m1 + interval '11 days 9 hours') at time zone 'UTC','done'),
    ('44440000-0000-0000-0000-000000000003','f1111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000001',null,(a.m1 + interval '12 days 9 hours') at time zone 'UTC','done'),
    ('44440000-0000-0000-0000-000000000004','f1111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',null,(a.m1 + interval '13 days 9 hours') at time zone 'UTC','planned'),
    ('44440000-0000-0000-0000-000000000005','f1111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',null,(a.m1 + interval '14 days 9 hours') at time zone 'UTC','done'),
    ('44440000-0000-0000-0000-000000000006','f1111111-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001',null,'99999999-0000-0000-0000-000000000001',(a.m1 + interval '15 days 10 hours') at time zone 'UTC','done'),
    ('44440000-0000-0000-0000-000000000007','f1111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002',null,(a.m1 + interval '16 days 9 hours') at time zone 'UTC','done'),
    ('44440000-0000-0000-0000-000000000008','f1111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',null,(a.m1 - interval '1 month' + interval '10 days 9 hours') at time zone 'UTC','done'),
    ('44440000-0000-0000-0000-000000000009','f1111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000001',null,(a.m1 - interval '30 minutes') at time zone 'UTC','done')
  ) as x(id, svc, t, s, g, starts, st);

-- Отметки «пришёл» (as postgres с claims владельца: attendance_recalc → emit_event).
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a', x.l, x.s, st.id
  from (values
    ('44440000-0000-0000-0000-000000000001'::uuid,'eeeeeeee-0000-0000-0000-000000000001'::uuid),
    ('44440000-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000001'),
    ('44440000-0000-0000-0000-000000000003','eeeeeeee-0000-0000-0000-000000000001'),
    ('44440000-0000-0000-0000-000000000004','eeeeeeee-0000-0000-0000-000000000001'),
    ('44440000-0000-0000-0000-000000000005','eeeeeeee-0000-0000-0000-000000000001'),
    ('44440000-0000-0000-0000-000000000006','eeeeeeee-0000-0000-0000-000000000001'),
    ('44440000-0000-0000-0000-000000000006','eeeeeeee-0000-0000-0000-000000000002'),
    ('44440000-0000-0000-0000-000000000007','eeeeeeee-0000-0000-0000-000000000002'),
    ('44440000-0000-0000-0000-000000000008','eeeeeeee-0000-0000-0000-000000000001'),
    ('44440000-0000-0000-0000-000000000009','eeeeeeee-0000-0000-0000-000000000001')
  ) as x(l, s),
  (select id from public.attendance_statuses
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present') as st(id);

set local role authenticated;

-- Замена ПОСЛЕ отметки и отмена ПОСЛЕ отметки — через штатные RPC.
select public.substitute_teacher('44440000-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002');
select public.cancel_lesson('44440000-0000-0000-0000-000000000005','заболел');

-- Касса прошлого месяца: платёж, возврат и расход по первому источнику,
-- корректировка без источника; платёж в позапрошлом месяце.
create temporary table t_src as
  select id from public.payment_sources
   where center_id = 'cccccccc-0000-0000-0000-00000000000a' order by sort, code limit 1;
grant select on t_src to authenticated;

select public.record_payment('dddddddd-0000-0000-0000-000000000001', 200000, 'payment',
  'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src),
  ((select m1 from t_anchor) + interval '5 days 12 hours') at time zone 'UTC', 'оплата');
select public.record_payment('dddddddd-0000-0000-0000-000000000001', -50000, 'refund',
  'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src),
  ((select m1 from t_anchor) + interval '6 days 12 hours') at time zone 'UTC', 'возврат');
select public.record_payment('dddddddd-0000-0000-0000-000000000001', 10000, 'correction',
  'eeeeeeee-0000-0000-0000-000000000001', null, null,
  ((select m1 from t_anchor) + interval '7 days 12 hours') at time zone 'UTC', 'корректировка без источника');
select public.record_payment('dddddddd-0000-0000-0000-000000000001', 70000, 'payment',
  'eeeeeeee-0000-0000-0000-000000000001', null, (select id from t_src),
  ((select m1 from t_anchor) - interval '1 month' + interval '5 days 12 hours') at time zone 'UTC', 'позапрошлый');
select public.record_expense(
  (select id from public.expense_categories
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' order by sort, code limit 1),
  30000, 'expense', (select id from t_src),
  ((select m1 from t_anchor) + interval '8 days')::date, 'аренда');


-- 1-3. Цены пришли сами -------------------------------------------------------------

select is(
  (select price_tiyin from public.attendance where lesson_id = '44440000-0000-0000-0000-000000000001'),
  50000,
  'Отметка без абонемента — цена услуги (50000), не литерал'
);
select is(
  (select price_tiyin from public.attendance where lesson_id = '44440000-0000-0000-0000-000000000007'),
  0,
  'Отметка по безлимиту — price_tiyin = 0'
);
select is(
  (select count(*)::int from public.attendance a join public.lessons l on l.id = a.lesson_id
    where a.deducted and l.starts_at >= ((select m1 from t_anchor) at time zone 'UTC')),
  8,
  'Списывающих отметок в прошлом месяце (UTC) — 8, из них planned и cancelled в выручку не попадут'
);


-- 4-9. revenue_by_month ------------------------------------------------------------

select is(
  (select visits from public.revenue_by_month where month = (select m1 from t_anchor)::date),
  7,
  'M-1: 7 посещений — L1, L2, L3, L6×2, L7, L9; planned и cancelled исключены'
);
select is(
  (select lessons from public.revenue_by_month where month = (select m1 from t_anchor)::date),
  6,
  'M-1: 6 занятий — групповое считается один раз'
);
select is(
  (select unpriced_visits from public.revenue_by_month where month = (select m1 from t_anchor)::date),
  1,
  'M-1: одно посещение без цены (безлимит) — ноль виден, а не растворён'
);
select is(
  (select revenue_tiyin from public.revenue_by_month where month = (select m1 from t_anchor)::date),
  260000::bigint,
  'M-1: выручка 4×50000 + 2×30000 = 260000, включая L9 (по Бишкеку — прошлый месяц)'
);
select is(
  (select revenue_tiyin from public.revenue_by_month
    where month = ((select m1 from t_anchor) - interval '1 month')::date),
  50000::bigint,
  'M-2: только L8 — 50000; L9 (23:30 UTC последнего дня M-2) сюда не попал'
);
select is(
  (select count(*)::int from public.revenue_by_month), 2,
  'Строки только за месяцы с выручкой — два'
);


-- 10-14. revenue_by_teacher ----------------------------------------------------------

select is(
  (select revenue_tiyin from public.revenue_by_teacher
    where month = (select m1 from t_anchor)::date and teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  160000::bigint,
  'Специалист 1: L1 + L2 (замена после отметки не перенесла) + L6×2 = 160000'
);
select is(
  (select visits from public.revenue_by_teacher
    where month = (select m1 from t_anchor)::date and teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  4, 'Специалист 1: 4 посещения'
);
select is(
  (select lessons from public.revenue_by_teacher
    where month = (select m1 from t_anchor)::date and teacher_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  3, 'Специалист 1: 3 занятия'
);
select is(
  (select revenue_tiyin from public.revenue_by_teacher
    where month = (select m1 from t_anchor)::date and teacher_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  100000::bigint,
  'Специалист 2: L3 + L7 (0, безлимит) + L9 = 100000 — атрибуция по paid_teacher_id, как в зарплате'
);
select is(
  (select unpriced_visits from public.revenue_by_teacher
    where month = (select m1 from t_anchor)::date and teacher_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  1, 'Специалист 2: одно посещение без цены'
);


-- 15-19. revenue_by_service ----------------------------------------------------------

select is(
  (select revenue_tiyin from public.revenue_by_service
    where month = (select m1 from t_anchor)::date and service_id = 'f1111111-0000-0000-0000-000000000001'),
  200000::bigint, 'Индивидуальное: 4×50000 + безлимит 0 = 200000'
);
select is(
  (select visits from public.revenue_by_service
    where month = (select m1 from t_anchor)::date and service_id = 'f1111111-0000-0000-0000-000000000001'),
  5, 'Индивидуальное: 5 посещений'
);
select is(
  (select revenue_tiyin from public.revenue_by_service
    where month = (select m1 from t_anchor)::date and service_id = 'f1111111-0000-0000-0000-000000000002'),
  60000::bigint, 'Групповое: 2×30000'
);
select is(
  (select visits from public.revenue_by_service
    where month = (select m1 from t_anchor)::date and service_id = 'f1111111-0000-0000-0000-000000000002'),
  2, 'Групповое: 2 посещения'
);
select is(
  (select lessons from public.revenue_by_service
    where month = (select m1 from t_anchor)::date and service_id = 'f1111111-0000-0000-0000-000000000002'),
  1, 'Групповое: 1 занятие'
);


-- 20-29. cash_by_source ----------------------------------------------------------------

select is(
  (select received_tiyin from public.cash_by_source
    where month = (select m1 from t_anchor)::date and source_id = (select id from t_src)),
  200000::bigint, 'Источник 1, M-1: поступило 200000'
);
select is(
  (select refunded_tiyin from public.cash_by_source
    where month = (select m1 from t_anchor)::date and source_id = (select id from t_src)),
  -50000::bigint, 'Источник 1, M-1: возвраты −50000 (знак как в payments)'
);
select is(
  (select spent_tiyin from public.cash_by_source
    where month = (select m1 from t_anchor)::date and source_id = (select id from t_src)),
  -30000::bigint, 'Источник 1, M-1: расход −30000 (знак инвертирован относительно expenses)'
);
select is(
  (select corrections_tiyin from public.cash_by_source
    where month = (select m1 from t_anchor)::date and source_id = (select id from t_src)),
  0::bigint, 'Источник 1, M-1: корректировок нет — 0, не NULL'
);
select is(
  (select other_tiyin from public.cash_by_source
    where month = (select m1 from t_anchor)::date and source_id = (select id from t_src)),
  0::bigint, 'Источник 1, M-1: неизвестных kind нет — 0'
);
select is(
  (select total_tiyin from public.cash_by_source
    where month = (select m1 from t_anchor)::date and source_id = (select id from t_src)),
  120000::bigint, 'Источник 1, M-1: итог 200000 − 50000 − 30000 = 120000'
);
select is(
  (select corrections_tiyin from public.cash_by_source
    where month = (select m1 from t_anchor)::date and source_id is null),
  10000::bigint, 'Без источника, M-1: корректировка 10000 — отдельная группа'
);
select is(
  (select total_tiyin from public.cash_by_source
    where month = (select m1 from t_anchor)::date and source_id is null),
  10000::bigint, 'Без источника, M-1: итог 10000'
);
select is(
  (select total_tiyin from public.cash_by_source
    where month = ((select m1 from t_anchor) - interval '1 month')::date and source_id = (select id from t_src)),
  70000::bigint, 'Источник 1, M-2: 70000'
);
select is(
  (select refunded_tiyin from public.cash_by_source
    where month = ((select m1 from t_anchor) - interval '1 month')::date and source_id = (select id from t_src)),
  0::bigint, 'Месяц без возвратов — refunded 0, не NULL'
);

reset role;


-- 30-33. Типы и гранты -----------------------------------------------------------------

select col_type_is('public', 'revenue_by_month', 'revenue_tiyin', 'bigint',
  'revenue_tiyin — bigint: за год центр перевалит integer');
select col_type_is('public', 'cash_by_source', 'total_tiyin', 'bigint',
  'total_tiyin — bigint');
select ok(
  (select bool_and(not has_table_privilege('anon', 'public.' || table_name, 'SELECT'))
     from information_schema.views
    where table_schema = 'public' and (table_name like 'revenue\_%' or table_name like 'cash\_%')),
  'anon не читает ни одну витрину'
);
select ok(
  (select bool_and(
       not has_table_privilege('authenticated', 'public.' || table_name, 'INSERT')
       and not has_table_privilege('authenticated', 'public.' || table_name, 'UPDATE')
       and not has_table_privilege('authenticated', 'public.' || table_name, 'DELETE'))
     from information_schema.views
    where table_schema = 'public' and (table_name like 'revenue\_%' or table_name like 'cash\_%')),
  'authenticated не пишет ни в одну витрину (автообновляемая вью — не путь мимо record_payment)'
);


-- 34-46. Изоляция: перебор витрин из каталога, не поимённо --------------------------

select is(
  (select count(*)::int from information_schema.views
    where table_schema = 'public' and (table_name like 'revenue\_%' or table_name like 'cash\_%')),
  4,
  'Витрин revenue_%/cash_% — четыре (перебор ниже не пуст)'
);

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  public.tests_count(format('select count(*) from public.%I', table_name)), 0::bigint,
  format('teacher: %s пуста (свои занятия по RLS видит, агрегат центра — нет)', table_name)
)
from information_schema.views
where table_schema = 'public' and (table_name like 'revenue\_%' or table_name like 'cash\_%')
order by table_name;
reset role;

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  public.tests_count(format('select count(*) from public.%I', table_name)), 0::bigint,
  format('parent: %s пуста (свои платежи по RLS видит, касса центра — нет)', table_name)
)
from information_schema.views
where table_schema = 'public' and (table_name like 'revenue\_%' or table_name like 'cash\_%')
order by table_name;
reset role;

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select is(
  public.tests_count(format('select count(*) from public.%I', table_name)), 0::bigint,
  format('owner центра Б: %s пуста — данные центра А не видны', table_name)
)
from information_schema.views
where table_schema = 'public' and (table_name like 'revenue\_%' or table_name like 'cash\_%')
order by table_name;
reset role;


-- 47-48. Индексы под группировку ---------------------------------------------------------

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'payments_center_paid_at_idx'),
  'payments (center_id, paid_at) — есть'
);
select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'payments_source_idx'),
  'payments (source_id) — есть (Advisor: unindexed_foreign_keys)'
);


-- 49-58. Контроль: витрина и замок месяца — один и тот же месяц ------------------------

-- L9 по Бишкеку в M-1: закрытие M-2 его не задевает — отметку по нему
-- можно править; закрытие M-1 — задевает.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select lives_ok(
  $q$ select public.close_month(((select m1 from t_anchor) - interval '1 month')::date) $q$,
  'close_month(M-2) проходит: единственное занятие M-2 (L8) проведено и отмечено'
);
select lives_ok(
  $q$ select public.mark_attendance('44440000-0000-0000-0000-000000000009','eeeeeeee-0000-0000-0000-000000000001','present','ещё раз') $q$,
  'Отметка L9 после закрытия M-2 проходит — замок и витрина считают его прошлым месяцем (по Бишкеку)'
);
select throws_like(
  $q$ select public.mark_attendance('44440000-0000-0000-0000-000000000008','eeeeeeee-0000-0000-0000-000000000001','present','ещё раз') $q$,
  '%закрыт%',
  'Отметка L8 после закрытия M-2 отбита — L8 в M-2 и по витрине, и по замку'
);

reset role;

select is(
  (select count(*)::int from public.payments), 4,
  'Платежей за файл — четыре'
);
select is(
  (select count(*)::int from public.expenses), 1,
  'Расходов — один'
);
-- reset role claims не сбрасывает — обнуляем явно.
select public.tests_claims(null, null);
select is(
  (select sum(total_tiyin) from public.cash_by_source), null::bigint,
  'Под postgres без claims владельца витрина пуста: ролевой фильтр в теле, не только RLS'
);

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(
  (select sum(total_tiyin) from public.cash_by_source), 200000::bigint,
  'Владелец: касса за всё время = 200000 − 50000 + 10000 + 70000 − 30000'
);
select is(
  (select sum(revenue_tiyin) from public.revenue_by_month), 310000::bigint,
  'Владелец: выручка за всё время = 260000 + 50000'
);
select is(
  (select sum(visits) from public.revenue_by_teacher), (select sum(visits) from public.revenue_by_month),
  'Сумма посещений по специалистам сходится с помесячной'
);
select is(
  (select sum(revenue_tiyin) from public.revenue_by_service), (select sum(revenue_tiyin) from public.revenue_by_month),
  'Сумма выручки по услугам сходится с помесячной'
);
reset role;

select * from finish();

rollback;
