-- pgTAP: пересчёт остатка при смене тарифа (0096).
--
-- Р3: общий набор случаев plan_switch_days с Vitest (planSwitchDays). Р1:
-- Studio → Center при 30 оплаченных днях — срок = сегодня + 15 дней + 1 месяц;
-- Center → Studio — + 61 день + 1 месяц; тот же тариф — + 1 месяц к текущему
-- сроку, как раньше. Событие несёт converted_days. Гранты.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(11);


-- 1. Общий набор случаев (Р3) — те же, что в packages/core/src/platform-payment.test.ts ------------

select is(public.plan_switch_days(30, 390000, 790000), 15, 'Studio → Center: 30 × 3900 / 7900 = 14,81 → 15');
select is(public.plan_switch_days(30, 790000, 390000), 61, 'Center → Studio: 60,77 → 61');
select is(public.plan_switch_days(10, 390000, 99000), 39, 'Studio → Solo: 39,39 → 39');
select is(public.plan_switch_days(0, 390000, 790000), 0, 'Остатка нет — 0');
select is(public.plan_switch_days(12, 0, 790000), 12, 'Цена старого 0 — дни как есть');


-- 2. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
) values
  ('00000000-0000-0000-0000-000000000000', '96000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner-0096@test.kg', '', '', '', '', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '96000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'platform-0096@test.kg', '', '', '', '', '', '', '', '');
update auth.users set email_confirmed_at = now() where id = '96000000-0000-0000-0000-000000000002';
insert into public.platform_admins (email) values ('platform-0096@test.kg');

-- Все три оплачены на 30 дней вперёд (дата в поясе центра + полдень).
insert into public.centers (id, name, slug, plan, subscription_until, settings)
select x.id::uuid, x.name, x.slug, x.plan,
       (((now() at time zone 'Asia/Bishkek')::date + 30)::timestamp + interval '12 hours') at time zone 'Asia/Bishkek',
       '{"timezone":"Asia/Bishkek"}'::jsonb
  from (values
    ('96000000-0000-0000-0000-0000000000c1', 'Studio → Center 0096', 'centr-0096-a', 'studio'),
    ('96000000-0000-0000-0000-0000000000c2', 'Center → Studio 0096', 'centr-0096-b', 'center'),
    ('96000000-0000-0000-0000-0000000000c3', 'Studio → Studio 0096', 'centr-0096-c', 'studio')
  ) as x(id, name, slug, plan);

insert into public.memberships (user_id, center_id, role)
select '96000000-0000-0000-0000-000000000001', c.id, 'owner'
  from public.centers c where c.id::text like '96000000-0000-0000-0000-0000000000c_';

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_until as select id, subscription_until from public.centers where id::text like '96000000-0000-0000-0000-0000000000c_';

-- Заявки владельца.
select public.tests_claims('96000000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.submit_platform_payment('center', 1, 'mbank', null);
reset role;
select public.tests_claims('96000000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-0000000000c2');
set local role authenticated;
select public.submit_platform_payment('studio', 1, 'mbank', null);
reset role;
select public.tests_claims('96000000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-0000000000c3');
set local role authenticated;
select public.submit_platform_payment('studio', 1, 'mbank', null);
reset role;

-- Подтверждение платформой.
select public.tests_claims('96000000-0000-0000-0000-000000000002', null);
set local role authenticated;
select public.extend_subscription(p.id, p.claimed_plan, p.claimed_months, p.claimed_amount_tiyin, false)
  from public.platform_payments p
 where p.center_id::text like '96000000-0000-0000-0000-0000000000c_'
 order by p.center_id;
reset role;


-- 3. Пересчёт при подтверждении (Р1, Р2) ----------------------------------------------------------

select is(
  (select row(c.plan, (c.subscription_until at time zone 'Asia/Bishkek')::date)::text from public.centers c
    where c.id = '96000000-0000-0000-0000-0000000000c1'),
  row('center', ((now() + interval '15 days' + interval '1 month') at time zone 'Asia/Bishkek')::date)::text,
  'Studio → Center: 30 дней Studio = 15 дней Center, срок = сегодня + 15 дней + 1 месяц');
select is(
  (select (c.subscription_until at time zone 'Asia/Bishkek')::date from public.centers c
    where c.id = '96000000-0000-0000-0000-0000000000c2'),
  ((now() + interval '61 days' + interval '1 month') at time zone 'Asia/Bishkek')::date,
  'Center → Studio: 30 дней Center = 61 день Studio');
select is(
  (select c.subscription_until from public.centers c where c.id = '96000000-0000-0000-0000-0000000000c3'),
  (select t.subscription_until + interval '1 month' from t_until t where t.id = '96000000-0000-0000-0000-0000000000c3'),
  'Тот же тариф — + 1 месяц к текущему сроку, без пересчёта');
select is(
  (select (e.payload ->> 'converted_days')::int from public.events e
    where e.type = 'subscription.extended' and e.center_id = '96000000-0000-0000-0000-0000000000c1'),
  15, 'Событие subscription.extended несёт converted_days');
select ok(
  (select e.payload ->> 'converted_days' is null from public.events e
    where e.type = 'subscription.extended' and e.center_id = '96000000-0000-0000-0000-0000000000c3'),
  'Без смены тарифа converted_days пуст');


-- 4. Гранты ---------------------------------------------------------------------------------------

select ok(
  not has_function_privilege('authenticated', 'public.plan_switch_days(integer,integer,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.plan_switch_days(integer,integer,integer)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.plan_switch_days(integer,integer,integer)', 'EXECUTE'),
  'plan_switch_days — внутренняя, ни одной роли приложения');

select * from finish();
rollback;
