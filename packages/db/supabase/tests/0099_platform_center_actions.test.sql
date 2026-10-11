-- pgTAP: ручные действия платформы над центрами (0099).
--
-- Каталог и гранты; не-платформа — 42501; ручное продление: последний день
-- в поясе центра (центр в Europe/Moscow), сверка с формой, сокращение только
-- флагом, платежи не тронуты, причины нет в events; продление trial; удаление:
-- открытая заявка и неверное имя — отказ, владелец не отменяет платформенное
-- удаление ни функцией, ни прямым update (триггер), удаление владельцем
-- платформа перехватывает, но не восстанавливает (решение владельца);
-- восстановление; журнал виден только платформе, не правится.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(55);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('99000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0099@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 5) n;
update auth.users set email_confirmed_at = now() where id = '99000000-0000-0000-0000-000000000001';
insert into public.platform_admins (email) values ('u1-0099@test.kg');

-- c1 — trial (Бишкек), c2 — solo (Москва, другой пояс), c3 — solo с открытой заявкой, c4 — solo.
insert into public.centers (id, name, slug, plan, trial_ends_at, settings) values
  ('99000000-0000-0000-0000-0000000000c1', 'Центр 0099 trial', 'centr-0099-1', 'trial', now() + interval '3 days', '{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('99000000-0000-0000-0000-0000000000c2', 'Центр 0099 Москва', 'centr-0099-2', 'solo', now() + interval '10 days', '{"timezone":"Europe/Moscow"}'::jsonb),
  ('99000000-0000-0000-0000-0000000000c3', 'Центр 0099 заявка', 'centr-0099-3', 'solo', now() + interval '10 days', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('99000000-0000-0000-0000-0000000000c4', 'Центр 0099 сам удалил', 'centr-0099-4', 'solo', now() + interval '10 days', '{"timezone":"Asia/Bishkek"}'::jsonb);

-- 1 платформа · 2 owner c1 · 3 owner c2 и c3 · 4 admin c2 · 5 owner c4.
insert into public.memberships (user_id, center_id, role) values
  ('99000000-0000-0000-0000-000000000002', '99000000-0000-0000-0000-0000000000c1', 'owner'),
  ('99000000-0000-0000-0000-000000000003', '99000000-0000-0000-0000-0000000000c2', 'owner'),
  ('99000000-0000-0000-0000-000000000003', '99000000-0000-0000-0000-0000000000c3', 'owner'),
  ('99000000-0000-0000-0000-000000000004', '99000000-0000-0000-0000-0000000000c2', 'admin'),
  ('99000000-0000-0000-0000-000000000005', '99000000-0000-0000-0000-0000000000c4', 'owner');

insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source, submitted_by)
values ('99000000-0000-0000-0000-0000000000c3', 'solo', 1, 99000, 'mbank', '99000000-0000-0000-0000-000000000003');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

-- Что «видела форма»: снимок от владельца таблиц — платформе centers под RLS не виден.
create temporary table t99 on commit drop as
  select (select subscription_until from public.centers where id = '99000000-0000-0000-0000-0000000000c2') as c2_until,
         (select trial_ends_at from public.centers where id = '99000000-0000-0000-0000-0000000000c1') as c1_trial,
         (now() at time zone 'Europe/Moscow')::date as msk_today,
         (now() at time zone 'Asia/Bishkek')::date as bsk_today;
grant select on t99 to authenticated;


-- 2. Каталог --------------------------------------------------------------------------------------

select is_empty(
  $$ select a.grantee::regrole::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where c.oid = 'public.platform_center_actions'::regclass
        and a.grantee <> c.relowner
        and not (a.grantee = 'authenticated'::regrole and a.privilege_type = 'SELECT') $$,
  'Журнал: authenticated — только SELECT, у anon и service_role нет ничего');

select is_empty(
  $$ select policyname from pg_policies
      where schemaname = 'public' and tablename = 'platform_center_actions' and cmd <> 'SELECT' $$,
  'Журнал: ни одной политики на запись — только RPC');

select is_empty(
  $$ select p.oid::regprocedure::text || ' ' || r
       from pg_proc p, unnest(array['public', 'anon', 'service_role']) r
      where p.oid in ('public.platform_grant_subscription(uuid,text,date,timestamptz,text,boolean)'::regprocedure,
                      'public.platform_extend_trial(uuid,date,timestamptz,text)'::regprocedure,
                      'public.platform_delete_center(uuid,text,text)'::regprocedure,
                      'public.platform_restore_center(uuid,text)'::regprocedure,
                      'public.platform_deleted_centers()'::regprocedure,
                      'public.platform_center_actions_recent(integer)'::regprocedure,
                      'public.platform_gifted_since_payment(uuid)'::regprocedure)
        and has_function_privilege(r, p.oid, 'EXECUTE') $$,
  'RPC платформы: ни PUBLIC, ни anon, ни service_role');

select is_empty(
  $$ select p.oid::regprocedure::text || ' ' || r
       from pg_proc p, unnest(array['public', 'anon', 'authenticated', 'service_role']) r
      where p.oid in ('public.platform_day_end(uuid,date)'::regprocedure,
                      'public.platform_reason(text)'::regprocedure,
                      'public.center_deleted_by_platform(uuid)'::regprocedure,
                      'public.platform_payments_center_live()'::regprocedure,
                      'public.centers_deletion_source_guard()'::regprocedure,
                      'public.platform_center_actions_immutable()'::regprocedure)
        and has_function_privilege(r, p.oid, 'EXECUTE') $$,
  'Помощники и триггерные функции закрыты для всех ролей');

select ok(
  exists (select 1 from pg_trigger tg
           where tg.tgrelid = 'public.platform_center_actions'::regclass and tg.tgname = 'a00_readonly_guard'),
  'Журнал под readonly-guard (забор 0050)');

select ok(
  exists (select 1 from public.export_center_excluded_tables() x where x.table_name = 'platform_center_actions')
  and not exists (select 1 from public.export_center_tables() x where x.table_name = 'platform_center_actions'),
  'Журнал — в deny-list экспорта центра');


-- 3. Не платформа ---------------------------------------------------------------------------------

select public.tests_claims('99000000-0000-0000-0000-000000000003', '99000000-0000-0000-0000-0000000000c2');
set local role authenticated;
select throws_ok(
  $$ select public.platform_grant_subscription('99000000-0000-0000-0000-0000000000c2', 'studio', current_date + 30, null, 'Хочу') $$,
  '42501', 'Недостаточно прав', 'Владелец центра не продлевает себе тариф');
select throws_ok(
  $$ select public.platform_delete_center('99000000-0000-0000-0000-0000000000c2', 'Центр 0099 Москва', 'Хочу') $$,
  '42501', 'Недостаточно прав', 'Владелец центра не вызывает платформенное удаление');
select throws_ok(
  $$ select public.platform_restore_center('99000000-0000-0000-0000-0000000000c2', 'Хочу') $$,
  '42501', 'Недостаточно прав', 'и восстановление');
select throws_ok(
  $$ select * from public.platform_deleted_centers() $$,
  '42501', 'Недостаточно прав', 'и список удалённых центров');
select throws_ok(
  $$ select public.platform_extend_trial('99000000-0000-0000-0000-0000000000c2', current_date + 5, null, 'Хочу') $$,
  '42501', 'Недостаточно прав', 'и продление trial');
select throws_ok(
  $$ select * from public.platform_center_actions_recent(10) $$,
  '42501', 'Недостаточно прав', 'и журнал через RPC');
select throws_ok(
  $$ select public.platform_gifted_since_payment('99000000-0000-0000-0000-0000000000c2') $$,
  '42501', 'Недостаточно прав', 'и признак подарка');
reset role;


-- 4. Ручное продление и смена тарифа (Р4, Р5, Р6) -------------------------------------------------

select public.tests_claims('99000000-0000-0000-0000-000000000001', null);
set local role authenticated;
select lives_ok(
  $$ select public.platform_grant_subscription('99000000-0000-0000-0000-0000000000c2', 'studio',
       (select msk_today + 40 from t99), (select c2_until from t99), 'Подарок за отзыв') $$,
  'Платформа продлевает и меняет тариф вручную');
reset role;

select is(
  (select plan || ' ' || to_char(subscription_until at time zone 'Europe/Moscow', 'YYYY-MM-DD') from public.centers where id = '99000000-0000-0000-0000-0000000000c2'),
  'studio ' || to_char((select msk_today + 40 from t99), 'YYYY-MM-DD'),
  'Тариф сменён, срок — последний день в поясе центра (Москва), без лишнего дня');
select is(
  (select count(*)::int from public.platform_payments where center_id = '99000000-0000-0000-0000-0000000000c2'), 0,
  'Ручное продление не создаёт платежа — в выручку не идёт');
select is(
  (select details #>> '{after,plan}' from public.platform_center_actions where center_id = '99000000-0000-0000-0000-0000000000c2' and action = 'grant'),
  'studio', 'Журнал: grant с было/стало');
select ok(
  (select bool_and(not (payload ? 'reason') and position('Подарок за отзыв' in payload::text) = 0)
     from public.events where center_id = '99000000-0000-0000-0000-0000000000c2' and type = 'center.subscription_granted'),
  'Причины нет в events — их читает центр (Р6)');

create temporary table t99b on commit drop as
  select subscription_until as c2_until_now from public.centers where id = '99000000-0000-0000-0000-0000000000c2';
grant select on t99b to authenticated;

select public.tests_claims('99000000-0000-0000-0000-000000000001', null);
set local role authenticated;
select throws_ok(
  $$ select public.platform_grant_subscription('99000000-0000-0000-0000-0000000000c2', 'studio',
       (select msk_today + 50 from t99), (select c2_until from t99), 'Ещё раз') $$,
  '40001', 'Срок центра изменился, пока была открыта форма — обновите страницу',
  'Форма видела старый срок — отказ, а не перезапись (Р5)');
select throws_ok(
  $$ select public.platform_grant_subscription('99000000-0000-0000-0000-0000000000c2', 'studio',
       (select msk_today - 1 from t99), (select c2_until_now from t99b), 'Ошибка') $$,
  '22023', 'Дата окончания — не раньше сегодняшнего дня', 'Дата в прошлом — отказ');
select throws_ok(
  $$ select public.platform_grant_subscription('99000000-0000-0000-0000-0000000000c2', 'studio',
       (select msk_today + 800 from t99), (select c2_until_now from t99b), 'Навсегда') $$,
  '22023', 'Не дальше 24 месяцев от сегодня', 'Дальше 24 месяцев — отказ');
select throws_ok(
  $$ select public.platform_grant_subscription('99000000-0000-0000-0000-0000000000c2', 'studio',
       (select msk_today + 10 from t99), (select c2_until_now from t99b), 'Сократить') $$,
  '22023', null, 'Сокращение срока без флага — отказ');
select throws_ok(
  $$ select public.platform_grant_subscription('99000000-0000-0000-0000-0000000000c2', 'trial',
       (select msk_today + 50 from t99), (select c2_until_now from t99b), 'Пробный') $$,
  '22023', 'Выберите платный тариф', 'trial ручным продлением не ставится');
select throws_ok(
  $$ select public.platform_grant_subscription('99000000-0000-0000-0000-0000000000c2', 'studio',
       (select msk_today + 50 from t99), (select c2_until_now from t99b), '  ') $$,
  '22023', 'Укажите причину — от 3 до 500 символов', 'Без причины — отказ');


-- 5. Продление trial -------------------------------------------------------------------------------

select lives_ok(
  $$ select public.platform_extend_trial('99000000-0000-0000-0000-0000000000c1',
       (select bsk_today + 20 from t99), (select c1_trial from t99), 'Не успели попробовать') $$,
  'Платформа продлевает пробный период');
reset role;
select is(
  (select to_char(trial_ends_at at time zone 'Asia/Bishkek', 'YYYY-MM-DD') from public.centers where id = '99000000-0000-0000-0000-0000000000c1'),
  to_char((select bsk_today + 20 from t99), 'YYYY-MM-DD'),
  'Пробный — до последнего дня в поясе центра');

create temporary table t99c on commit drop as
  select trial_ends_at as c1_trial_now from public.centers where id = '99000000-0000-0000-0000-0000000000c1';
grant select on t99c to authenticated;

select public.tests_claims('99000000-0000-0000-0000-000000000001', null);
set local role authenticated;
select throws_ok(
  $$ select public.platform_extend_trial('99000000-0000-0000-0000-0000000000c2',
       (select msk_today + 20 from t99), (select c2_until_now from t99b), 'Пробный') $$,
  '22023', 'Центр уже на платном тарифе — продлевайте подписку', 'Платному центру trial не продлевается');
select throws_ok(
  $$ select public.platform_extend_trial('99000000-0000-0000-0000-0000000000c1',
       (select bsk_today + 61 from t99), (select c1_trial_now from t99c), 'Долго') $$,
  '22023', 'Пробный период — не дальше 60 дней от сегодня', 'Пробный дальше 60 дней — отказ');
select throws_ok(
  $$ select public.platform_extend_trial('99000000-0000-0000-0000-0000000000c1',
       (select bsk_today + 5 from t99), (select c1_trial_now from t99c), 'Короче') $$,
  '22023', null, 'Пробный период только продлевается — раньше текущей даты нельзя');


-- 6. Удаление и восстановление (Р2, Р3, Р7) --------------------------------------------------------

select throws_ok(
  $$ select public.platform_delete_center('99000000-0000-0000-0000-0000000000c3', 'Центр 0099 заявка', 'Брошен') $$,
  '22023', 'У центра есть открытая заявка на оплату — сначала подтвердите или отклоните её',
  'Центр с открытой заявкой не удаляется (Р7)');
select throws_ok(
  $$ select public.platform_delete_center('99000000-0000-0000-0000-0000000000c1', 'Не тот центр', 'Спам') $$,
  '22023', 'Название центра не совпадает — удаление не выполнено', 'Неверное название — отказ');
select lives_ok(
  $$ select public.platform_delete_center('99000000-0000-0000-0000-0000000000c1', 'Центр 0099 trial', 'Спам-регистрация') $$,
  'Платформа удаляет центр');
reset role;

select is(
  (select deletion_source from public.centers where id = '99000000-0000-0000-0000-0000000000c1'),
  'platform', 'Источник удаления — платформа');

select public.tests_claims('99000000-0000-0000-0000-000000000002', '99000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select public.cancel_center_deletion() $$,
  '42501', 'Центр удалён администратором платформы — восстановить его может только платформа: 0707 001 107',
  'Владелец не отменяет платформенное удаление');
select is(
  (public.center_deletion_state() ->> 'by_platform')::boolean, true,
  'center_deletion_state говорит веб-интерфейсу, что удалила платформа');
select throws_ok(
  $$ select public.submit_platform_payment('solo', 1, 'mbank') $$,
  'PT402', 'Центр удалён администратором платформы — оплата недоступна. Вопросы: 0707 001 107',
  'Текст отказа в оплате — без «отмените удаление» (Р8)');
reset role;

-- Обход функции: прямой update из контекста с сессией владельца — триггер (Р2).
select public.tests_claims('99000000-0000-0000-0000-000000000002', '99000000-0000-0000-0000-0000000000c1');
select throws_ok(
  $$ update public.centers set deleted_at = null where id = '99000000-0000-0000-0000-0000000000c1' $$,
  '42501', null, 'Прямой update deleted_at с сессией владельца — отказ триггера');
select public.tests_claims(null, null);

-- Владелец удалил сам → платформа не восстанавливает, но перехватывает удаление.
select public.tests_claims('99000000-0000-0000-0000-000000000005', '99000000-0000-0000-0000-0000000000c4');
set local role authenticated;
select lives_ok(
  $$ select public.request_center_deletion('Центр 0099 сам удалил') $$,
  'Владелец удаляет свой центр сам');
reset role;

select public.tests_claims('99000000-0000-0000-0000-000000000001', null);
set local role authenticated;
select throws_ok(
  $$ select public.platform_restore_center('99000000-0000-0000-0000-0000000000c4', 'Попросили') $$,
  '22023', 'Центр удалил сам владелец — отменить удаление может только он, в настройках тарифа',
  'Удаление владельцем платформа не отменяет (решение владельца)');
select lives_ok(
  $$ select public.platform_delete_center('99000000-0000-0000-0000-0000000000c4', 'Центр 0099 сам удалил', 'Спам') $$,
  'Удаление владельцем платформа перехватывает');
reset role;

select public.tests_claims('99000000-0000-0000-0000-000000000005', '99000000-0000-0000-0000-0000000000c4');
set local role authenticated;
select throws_ok(
  $$ select public.cancel_center_deletion() $$,
  '42501', null, 'После перехвата владелец удаление уже не отменит');
reset role;

-- Заявка к удалённому центру база не примет (Р7, гонка с «Я оплатил»).
select throws_ok(
  $$ insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source)
     values ('99000000-0000-0000-0000-0000000000c4', 'solo', 1, 99000, 'mbank') $$,
  'PT402', 'Центр удалён — заявка на оплату недоступна', 'Заявка к удалённому центру не вставляется');

-- Владелец удалил центр с открытой заявкой сам — платформа перехватывает удаление.
select public.tests_claims('99000000-0000-0000-0000-000000000003', '99000000-0000-0000-0000-0000000000c3');
set local role authenticated;
select lives_ok(
  $$ select public.request_center_deletion('Центр 0099 заявка') $$,
  'Владелец удаляет центр с открытой заявкой сам');
reset role;
select public.tests_claims('99000000-0000-0000-0000-000000000001', null);
set local role authenticated;
select lives_ok(
  $$ select public.platform_delete_center('99000000-0000-0000-0000-0000000000c3', 'Центр 0099 заявка', 'Спам с заявкой') $$,
  'Удаление владельцем с открытой заявкой платформа перехватывает — заявка уже выпала из очереди');
reset role;

select public.tests_claims('99000000-0000-0000-0000-000000000001', null);
set local role authenticated;
select is(
  (select count(*)::int from public.platform_deleted_centers() where center_id in ('99000000-0000-0000-0000-0000000000c1', '99000000-0000-0000-0000-0000000000c4')),
  2, 'Удалённые центры — в списке платформы');
select lives_ok(
  $$ select public.platform_restore_center('99000000-0000-0000-0000-0000000000c1', 'Ошиблись, живой центр') $$,
  'Платформа восстанавливает центр, удалённый ею');
reset role;

select is(
  (select coalesce(deleted_at::text, 'null') || ' ' || coalesce(deletion_source, 'null') from public.centers where id = '99000000-0000-0000-0000-0000000000c1'),
  'null null', 'Восстановлен: ни даты удаления, ни источника');

select public.tests_claims('99000000-0000-0000-0000-000000000001', null);
set local role authenticated;
select throws_ok(
  $$ select public.platform_restore_center('99000000-0000-0000-0000-0000000000c1', 'Ещё раз') $$,
  '23514', 'Центр не удалён', 'Повторное восстановление — отказ');
reset role;


-- 7. Журнал (Р1) ----------------------------------------------------------------------------------

select public.tests_claims('99000000-0000-0000-0000-000000000003', '99000000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is(
  (select count(*)::int from public.platform_center_actions), 0,
  'Владелец центра журнал платформы не видит');
select throws_ok(
  $$ insert into public.platform_center_actions (center_id, action, reason) values ('99000000-0000-0000-0000-0000000000c2', 'grant', 'Сам себе') $$,
  '42501', null, 'Прямая запись в журнал — отказ');
reset role;

select public.tests_claims('99000000-0000-0000-0000-000000000001', null);
set local role authenticated;
select ok(
  (select count(*) >= 5 and bool_and(center_name is not null) and bool_and(created_by_email = 'u1-0099@test.kg')
     from public.platform_center_actions_recent(50) where center_id::text like '99000000-%'),
  'Платформа видит журнал с названием центра и автором');
select is(
  public.platform_gifted_since_payment('99000000-0000-0000-0000-0000000000c2'), true,
  'Подарок после последней оплаты виден — пульт предупредит при подтверждении (Р3)');
reset role;

select public.tests_claims('99000000-0000-0000-0000-000000000001', null);
select throws_ok(
  $$ update public.platform_center_actions set reason = 'Переписано' where center_id = '99000000-0000-0000-0000-0000000000c2' $$,
  '42501', 'Запись журнала платформы не изменяется и не удаляется',
  'Запись журнала не правится даже владельцем таблиц с сессией');
select public.tests_claims(null, null);

-- Оплата подтверждена после подарка — предупреждения больше нет.
insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source,
                                      confirmed_at, plan, months, amount_tiyin)
values ('99000000-0000-0000-0000-0000000000c2', 'studio', 1, 390000, 'mbank', now() + interval '1 second', 'studio', 1, 390000);
select public.tests_claims('99000000-0000-0000-0000-000000000001', null);
set local role authenticated;
select is(
  public.platform_gifted_since_payment('99000000-0000-0000-0000-0000000000c2'), false,
  'Оплата позже подарка — предупреждение снято');
reset role;
select public.tests_claims(null, null);

-- Удаление автора записей из auth.users (без сессии): FK set null проходит,
-- остальное в записи не меняется.
create temporary table t99d on commit drop as
  select id, reason from public.platform_center_actions where created_by = '99000000-0000-0000-0000-000000000001';
delete from auth.users where id = '99000000-0000-0000-0000-000000000001';
select ok(
  (select count(*) > 0 and bool_and(a.created_by is null and a.reason = d.reason)
     from t99d d join public.platform_center_actions a on a.id = d.id),
  'Автор удалён — created_by обнулён, причина и прочее не тронуты');


select * from finish();
rollback;
