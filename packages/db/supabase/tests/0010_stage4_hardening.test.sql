-- pgTAP: закрытие находок ревью этапа 4 (миграция 0010).
-- Два центра, пять пользователей, включая отозванного с живым JWT. Главное
-- здесь — что чужой абонемент не читается ни калькулятором, ни бейджем; что
-- замороженные факты отметки переживают правки; что allow_negative виден.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(52);

-- Фикстуры ---------------------------------------------------------------------

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
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','revoked@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Препод А');

insert into public.payers (id, center_id, full_name, phone) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Иванова А.','+996700111222'),
  ('bbbbbbbb-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Петрова Б.','+996700333444'),
  ('bbbbbbbb-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Чужая В.','+996700999888');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Данияр','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Айлин','bbbbbbbb-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001'),
  ('eeeeeeee-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Чужой','bbbbbbbb-0000-0000-0000-00000000000b',null);

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('99999999-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Индивидуальное',45,50000),
  ('99999999-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Индивидуальное',45,70000);

-- Отозванный (6666) — членства нет намеренно: JWT ещё живой, а права уже нет.
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

insert into public.subscription_types (id, center_id, name, service_id, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Восемь занятий','99999999-0000-0000-0000-000000000001','lessons',8,400000),
  ('77777777-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Четыре занятия','99999999-0000-0000-0000-00000000000b','lessons',4,200000);
insert into public.subscription_types (id, center_id, name, service_id, kind, price_tiyin) values
  ('77777777-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','Безлимит',null,'unlimited',900000);

-- Занятия Данияра: два «январских» (-40, -30 дней) и семь недавних.
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at) values
  ('44444444-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '40 days', now() - interval '40 days' + interval '45 min'),
  ('44444444-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '30 days', now() - interval '30 days' + interval '45 min'),
  ('44444444-0000-0000-0000-000000000007','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '6 days',  now() - interval '6 days'  + interval '45 min'),
  ('44444444-0000-0000-0000-000000000008','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '5 days',  now() - interval '5 days'  + interval '45 min'),
  ('44444444-0000-0000-0000-000000000009','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '4 days',  now() - interval '4 days'  + interval '45 min'),
  ('44444444-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '3 days',  now() - interval '3 days'  + interval '45 min'),
  ('44444444-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '2 days',  now() - interval '2 days'  + interval '45 min'),
  ('44444444-0000-0000-0000-000000000005','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '1 day',   now() - interval '1 day'   + interval '45 min'),
  ('44444444-0000-0000-0000-000000000006','cccccccc-0000-0000-0000-00000000000a','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', now() - interval '12 hours', now() - interval '12 hours' + interval '45 min');

-- A1: «январский», покрывает -40 и -30 дней. A2: текущий, с -10 дней.
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','77777777-0000-0000-0000-000000000001', 4, 200000, 50000, current_date - 60, current_date - 20),
  ('88888888-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','77777777-0000-0000-0000-000000000001', 3, 150000, 50000, current_date - 10, null),
  ('88888888-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-00000000000b','77777777-0000-0000-0000-00000000000b', 4, 200000, 50000, current_date - 10, null);

-- Claims владельца А: триггеры зовут emit_event, а тот требует auth.uid().
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');


-- Изоляция: чужой центр -------------------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;

-- 1–4. Калькуляторы от владельца Б по абонементу центра А — NULL, не цифры
select is(public.subscription_lessons_left('88888888-0000-0000-0000-000000000002'), null::integer,
  'Остаток чужого абонемента не читается: NULL');
select is(public.subscription_state('88888888-0000-0000-0000-000000000002'), null::text,
  'Состояние чужого абонемента не читается: NULL');
select is(public.refund_calc('88888888-0000-0000-0000-000000000002'), null::integer,
  'Сумма возврата чужого абонемента не читается: NULL');
-- 0014: subscription_freeze_days стала definer и закрыта от authenticated
-- совсем (см. 0014_freeze_state_unification.sql, раздел "Права") — точные
-- дни заморозки отдаёт только subscription_summary (owner/admin своего
-- центра), а не прямой RPC ни для чужого, ни для своего абонемента.
select throws_ok(
  $q$ select public.subscription_freeze_days('88888888-0000-0000-0000-000000000002') $q$,
  '42501', null, 'Дни заморозки не выдаются прикладной роли напрямую — только через subscription_summary');

-- 5–6. Бейдж и сводка чужого ребёнка/абонемента — отказ, не значение
select throws_ok(
  $q$ select public.student_subscription_badge('eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', null, 'Бейдж чужого ребёнка от владельца другого центра отклонён');
select throws_ok(
  $q$ select * from public.subscription_summary('88888888-0000-0000-0000-000000000002') $q$,
  '42704', null, 'Сводка чужого абонемента: «не найден», а не цифры');

reset role;


-- Изоляция: свой центр, роли ----------------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- 7. 0014: тот же прямой RPC закрыт и для своего абонемента — точное
-- число дней теперь только внутри subscription_summary, не отдельным вызовом.
select throws_ok(
  $q$ select public.subscription_freeze_days('88888888-0000-0000-0000-000000000002') $q$,
  '42501', null, 'Дни заморозки своего абонемента — тоже не прямым RPC, только через subscription_summary');

-- 8. Витрина жива: калькуляторы внутри security_invoker-вью исполняются вызывающим
select cmp_ok((select count(*)::int from public.student_balance), '>=', 1,
  'student_balance читается владельцем после перевода калькуляторов в invoker');

-- 9. Прямой insert в subscriptions закрыт
select throws_ok(
  $q$ insert into public.subscriptions (center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at)
      values ('cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001',
              'bbbbbbbb-0000-0000-0000-000000000001',8,400000,50000,current_date) $q$,
  '42501', null, 'Прямая вставка абонемента от прикладной роли отклонена — продажа только через RPC');

-- 10. Сводка своего абонемента
select is((select lessons_left from public.subscription_summary('88888888-0000-0000-0000-000000000002')), 3,
  'subscription_summary отдаёт остаток своего абонемента');

reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- 11–12. Специалист: ни сводки, ни прямой вставки отметки
select throws_ok(
  $q$ select * from public.subscription_summary('88888888-0000-0000-0000-000000000002') $q$,
  '42501', null, 'Специалисту сводка абонемента недоступна');
select throws_ok(
  $q$ insert into public.attendance (center_id, lesson_id, student_id, status_id)
      select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000004',
             'eeeeeeee-0000-0000-0000-000000000001', id
        from public.attendance_statuses
       where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present' $q$,
  '42501', null, 'Прямая вставка отметки специалистом отклонена RLS');

reset role;

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- 13–15. Родитель: бейдж своего ребёнка — да, чужого ребёнка того же центра — нет
select ok(public.student_subscription_badge('eeeeeeee-0000-0000-0000-000000000001') in ('нет','заканчивается','есть'),
  'Родитель получает бейдж своего ребёнка');
select throws_ok(
  $q$ select public.student_subscription_badge('eeeeeeee-0000-0000-0000-000000000002') $q$,
  '42501', null, 'Родителю бейдж чужого ребёнка того же центра недоступен');
select throws_ok(
  $q$ insert into public.attendance (center_id, lesson_id, student_id, status_id)
      select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000004',
             'eeeeeeee-0000-0000-0000-000000000001', id
        from public.attendance_statuses
       where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present' $q$,
  '42501', null, 'Прямая вставка отметки родителем отклонена RLS');

reset role;

-- 16. Архивный ребёнок своего центра: «нет», а не отказ в правах
update public.students set deleted_at = now() where id = 'eeeeeeee-0000-0000-0000-000000000002';
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select is(public.student_subscription_badge('eeeeeeee-0000-0000-0000-000000000002'), 'нет',
  'Бейдж архивного ребёнка для владельца — «нет», не 42501');
reset role;
update public.students set deleted_at = null where id = 'eeeeeeee-0000-0000-0000-000000000002';

-- A4 Айлин — для заморозки и переноса ниже.
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at)
values ('88888888-0000-0000-0000-000000000004','cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000002',
        'bbbbbbbb-0000-0000-0000-000000000002','77777777-0000-0000-0000-000000000001', 5, 250000, 50000, current_date - 10);


-- Отозванное членство при живом JWT --------------------------------------------------

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- 17–20. my_role() = NULL больше не проходит проверку «not in»
select throws_ok(
  $q$ select public.sell_subscription('77777777-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001') $q$,
  '42501', null, 'Отозванный не продаёт абонемент');
select throws_ok(
  $q$ select public.mark_attendance('44444444-0000-0000-0000-000000000004','eeeeeeee-0000-0000-0000-000000000001','present') $q$,
  '42501', null, 'Отозванный не отмечает посещение');
select throws_ok(
  $q$ select * from public.find_payer_by_phone('+996700111222') $q$,
  '42501', null, 'Отозванный не ищет родителей по телефону');
select is(public.user_email('11111111-1111-1111-1111-111111111111'), null::text,
  'Отозванный не читает почту другого участника');

reset role;


-- Замороженные факты отметки ----------------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');

-- 21. Отметка «январского» занятия берёт абонемент по дате занятия, а не по сегодня
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';
select is((select subscription_id from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000001'),
  '88888888-0000-0000-0000-000000000001'::uuid, 'Занятие 40 дней назад списано с абонемента того периода, а не с текущего');

-- 22. Правка комментария не трогает привязку и цену
update public.attendance set comment = 'правка' where lesson_id = '44444444-0000-0000-0000-000000000001';
select ok((select subscription_id = '88888888-0000-0000-0000-000000000001' and price_tiyin = 50000
             from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000001'),
  'Правка комментария не меняет абонемент и цену отметки');

-- 23. Первое списание при смене статуса задним числом — по дате занятия
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'sick';
update public.attendance a set status_id = st.id
  from public.attendance_statuses st
 where st.center_id = a.center_id and st.code = 'present' and a.lesson_id = '44444444-0000-0000-0000-000000000002';
select is((select subscription_id from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000002'),
  '88888888-0000-0000-0000-000000000001'::uuid, '«Болел» → «пришёл» задним числом списывает с абонемента того периода');

-- 24. Круг «пришёл → болел → пришёл» остаётся на том же абонементе
update public.attendance a set status_id = st.id from public.attendance_statuses st
 where st.center_id = a.center_id and st.code = 'sick' and a.lesson_id = '44444444-0000-0000-0000-000000000001';
update public.attendance a set status_id = st.id from public.attendance_statuses st
 where st.center_id = a.center_id and st.code = 'present' and a.lesson_id = '44444444-0000-0000-0000-000000000001';
select ok((select subscription_id = '88888888-0000-0000-0000-000000000001'
             from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000001')
          and (select lessons_used from public.subscriptions where id = '88888888-0000-0000-0000-000000000001') = 2,
  'Круг статусов не перевыбирает абонемент; lessons_used вернулось к 2');

-- 25–27. Замороженный сегодня абонемент не мешает править старую отметку
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000007','eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';
set local role authenticated;
select public.freeze_subscription('88888888-0000-0000-0000-000000000002', current_date);
reset role;
select lives_ok(
  $q$ update public.attendance a set status_id = st.id from public.attendance_statuses st
       where st.center_id = a.center_id and st.code = 'late' and a.lesson_id = '44444444-0000-0000-0000-000000000007' $q$,
  'Смена статуса отметки при замороженном сегодня абонементе не падает');
select is((select subscription_id from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000007'),
  '88888888-0000-0000-0000-000000000002'::uuid, 'Привязка к абонементу сохранена после смены статуса');
set local role authenticated;
-- current_date вместо умолчания: unfreeze_subscription без p_to сама берёт
-- center_today() (пояс центра), а фикстура выше открыла заморозку через
-- current_date (пояс сессии psql, обычно UTC) — 6 часов в сутки (18:00-
-- 23:59 UTC, когда в Бишкеке уже следующий день) эти два «сегодня»
-- расходятся, freeze_subscription/unfreeze_subscription в те же полсуток
-- открывают и закрывают заморозку РАЗНЫМИ днями вместо no-op, и в
-- subscription_freezes остаётся однодневный хвост. Он не мешает этому
-- тесту, но глушит allow_negative у теста 37 (та же подписка), потому что
-- attendance_fill_and_check исключает подписку из кандидатов на дату,
-- которую хвост накрывает. Фиксируем оба конца интервала одним временем.
select public.unfreeze_subscription('88888888-0000-0000-0000-000000000002', current_date);
reset role;
select is(public.subscription_state('88888888-0000-0000-0000-000000000002'), 'active',
  'После разморозки абонемент снова действующий');

-- 28. Заморозка на 7 дней и разморозка: дни считаются
set local role authenticated;
select public.freeze_subscription('88888888-0000-0000-0000-000000000004', current_date - 7);
-- current_date вторым аргументом — та же причина, что у теста 25-27 выше:
-- без него unfreeze берёт center_today() (пояс Бишкека), а p_from здесь
-- уже посчитан в поясе сессии (current_date) — при расхождении интервал
-- получается 6 или 8 дней вместо 7, не всегда 7.
select public.unfreeze_subscription('88888888-0000-0000-0000-000000000004', current_date);
reset role;
select ok(public.subscription_freeze_days('88888888-0000-0000-0000-000000000004') = 7
          and public.subscription_state('88888888-0000-0000-0000-000000000004') = 'active',
  'unfreeze_subscription: 7 дней заморозки учтены, абонемент действующий');


-- Отметка через RPC --------------------------------------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- 29. mark_attendance не трогает статус занятия
select public.mark_attendance('44444444-0000-0000-0000-000000000004','eeeeeeee-0000-0000-0000-000000000001','present');
select is((select status from public.lessons where id = '44444444-0000-0000-0000-000000000004'), 'planned',
  'mark_attendance не меняет lessons.status');

-- 30. Смена статуса через ту же RPC
select public.mark_attendance('44444444-0000-0000-0000-000000000004','eeeeeeee-0000-0000-0000-000000000001','sick');
select is((select st.code from public.attendance a join public.attendance_statuses st on st.id = a.status_id
            where a.lesson_id = '44444444-0000-0000-0000-000000000004'), 'sick',
  'Повторный mark_attendance другим статусом меняет отметку');

reset role;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- 31–32. Массовая отметка — всё или ничего
select throws_ok(
  $q$ select public.mark_attendance_bulk('44444444-0000-0000-0000-000000000005',
        '[{"student_id":"eeeeeeee-0000-0000-0000-000000000001","status_code":"present"},
          {"student_id":"eeeeeeee-0000-0000-0000-00000000000b","status_code":"present"}]'::jsonb) $q$,
  '22023', null, 'Bulk с чужим ребёнком отклонён целиком');
select is((select count(*)::int from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000005'), 0,
  'После отказа bulk не отмечен никто');

reset role;


-- Остаток, минус, события ----------------------------------------------------------------

-- 33–34. Два прогула доводят A2 до нуля; exhausted — один раз
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000008','eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'absent';
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000009','eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'absent';
select is(public.subscription_lessons_left('88888888-0000-0000-0000-000000000002'), 0,
  'Опоздание и два прогула исчерпали абонемент из трёх занятий');
select is((select count(*)::int from public.events where type = 'subscription.exhausted'
            and payload ->> 'subscription_id' = '88888888-0000-0000-0000-000000000002'), 1,
  'subscription.exhausted отправлено ровно один раз');

-- 35–36. Серия из двух пропусков — одно событие; третий пропуск не повторяет
select is((select count(*)::int from public.events where type = 'student.absent_streak'), 1,
  'Два прогула подряд дали ровно одно student.absent_streak');
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000003','eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'absent';
select is((select count(*)::int from public.events where type = 'student.absent_streak'), 1,
  'Третий прогул подряд события не повторяет');

-- 37–38. allow_negative: списание идёт в минус, событие overdrawn один раз
update public.subscriptions set allow_negative = true where id = '88888888-0000-0000-0000-000000000002';
insert into public.attendance (center_id, lesson_id, student_id, status_id)
select 'cccccccc-0000-0000-0000-00000000000a','44444444-0000-0000-0000-000000000005','eeeeeeee-0000-0000-0000-000000000001', id
  from public.attendance_statuses where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';
select is(public.subscription_lessons_left('88888888-0000-0000-0000-000000000002'), -1,
  'С allow_negative отметка списывается с абонемента в минус, а не в долг');
select is((select count(*)::int from public.events where type = 'subscription.overdrawn'), 1,
  'subscription.overdrawn отправлено один раз при переходе через ноль');

-- 39–40. Витрина: минус и долг видны отдельно
select is((select overdrawn_tiyin from public.student_balance where student_id = 'eeeeeeee-0000-0000-0000-000000000001'), 50000,
  'student_balance показывает перерасход в тыйынах');
select is((select debt_tiyin from public.student_balance where student_id = 'eeeeeeee-0000-0000-0000-000000000001'), 50000,
  'student_balance показывает долг за занятие без абонемента');

-- 41. Правки комментария не размножают attendance.marked
update public.attendance set comment = 'раз'  where lesson_id = '44444444-0000-0000-0000-000000000001';
update public.attendance set comment = 'два'  where lesson_id = '44444444-0000-0000-0000-000000000001';
update public.attendance set comment = 'три'  where lesson_id = '44444444-0000-0000-0000-000000000001';
select is((select count(*)::int from public.events e where e.type = 'attendance.marked'
            and e.payload ->> 'attendance_id' = (select id::text from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000001')), 3,
  'attendance.marked отправлено по числу смен статуса (3), а не правок комментария');

-- 42. Смена флага у статуса не меняет уже замороженные факты
update public.attendance_statuses set deducts_lesson = false
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';
select ok((select deducted from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000001')
          and (select lessons_used from public.subscriptions where id = '88888888-0000-0000-0000-000000000001') = 2,
  'Снятие «списывает» у статуса не трогает старые отметки и остатки');
update public.attendance_statuses set deducts_lesson = true
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';


-- Перенос, возврат, архив ----------------------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

-- 43–45. Перенос остатка
select lives_ok(
  $q$ select public.transfer_remaining('88888888-0000-0000-0000-000000000004','eeeeeeee-0000-0000-0000-000000000001') $q$,
  'transfer_remaining переносит остаток другому ребёнку своего центра');
select is((select count(*)::int from public.subscriptions
            where student_id = 'eeeeeeee-0000-0000-0000-000000000001' and lessons_total = 5 and notes like 'Перенос%'), 1,
  'Новый абонемент на 5 занятий создан и прошёл CHECK согласования цены');
select throws_ok(
  $q$ select public.transfer_remaining('88888888-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b') $q$,
  '42704', null, 'Перенос ребёнку чужого центра отклонён');

-- 46–48. Возврат: защита от гонки по ожидаемой сумме
select throws_ok(
  $q$ select public.refund_subscription('88888888-0000-0000-0000-000000000001', 1) $q$,
  '23514', null, 'Возврат с устаревшей суммой отклонён');
select lives_ok(
  $q$ select public.refund_subscription('88888888-0000-0000-0000-000000000001', 100000) $q$,
  'Возврат с верной суммой (2 × 500 сом) проходит');
select ok((select status = 'cancelled' and lessons_written_off = 2
             from public.subscriptions where id = '88888888-0000-0000-0000-000000000001'),
  'После возврата абонемент отменён, остаток списан в lessons_written_off');

reset role;

-- 49. Архив абонемента с остатком запрещён
select throws_ok(
  $q$ update public.subscriptions set deleted_at = now()
       where student_id = 'eeeeeeee-0000-0000-0000-000000000001' and notes like 'Перенос%' $q$,
  '22023', null, 'Мягкое удаление абонемента с остатком отклонено');

-- 50. CHECK согласования цены держит и прямую вставку
select throws_ok(
  $q$ insert into public.subscriptions (center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at)
      values ('cccccccc-0000-0000-0000-00000000000a','eeeeeeee-0000-0000-0000-000000000001',
              'bbbbbbbb-0000-0000-0000-000000000001', 5, 100, 1000000, current_date) $q$,
  '23514', null, 'lesson_price_tiyin, не равная price/lessons_total, отклонена CHECK-ом');

-- 51. Безлимит продаётся: lessons_total null проходит новый CHECK
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.sell_subscription('77777777-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002') $q$,
  'Продажа безлимитного абонемента проходит CHECK');
reset role;

-- 52. Долг за занятие без абонемента — событие один раз
select is((select count(*)::int from public.events e where e.type = 'attendance.no_subscription'
            and e.payload ->> 'attendance_id' = (select id::text from public.attendance where lesson_id = '44444444-0000-0000-0000-000000000003')), 1,
  'attendance.no_subscription отправлено один раз на отметку');


select * from finish();

rollback;
