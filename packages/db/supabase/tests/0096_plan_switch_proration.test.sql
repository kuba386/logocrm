-- pgTAP: пересчёт остатка при смене тарифа (0096).
--
-- Р1/Р4: общий набор случаев plan_switch_days с Vitest (planSwitchDays),
-- включая половины и бесплатный старый тариф. Р1: Studio → Center при 30
-- оплаченных днях без истории оплат — по прайсу, + 15 дней + 1 месяц; Center →
-- Studio — + 61 день; тот же тариф — + 1 месяц к текущему сроку. Р2: по
-- уплаченной цене — Studio, оплаченный на 12 мес. со скидкой (3 120 сом в
-- месяц), → Center: 12 дней, а не 15. Р3: понижение с длинным остатком
-- упирается в потолок 24 месяца, излишек — в событии. Р6: предпросмотр
-- /admin совпадает с подтверждением; центру он закрыт. Гранты.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(20);


-- 1. Общий набор случаев (Р1, Р4) — те же, что в packages/core/src/platform-payment.test.ts --------

select is(public.plan_switch_days(30, 390000, 790000), 15, 'Studio → Center: 30 × 3900 / 7900 = 14,81 → 15');
select is(public.plan_switch_days(30, 790000, 390000), 61, 'Center → Studio: 60,77 → 61');
select is(public.plan_switch_days(10, 390000, 99000), 39, 'Studio → Solo: 39,39 → 39');
select is(public.plan_switch_days(0, 390000, 790000), 0, 'Остатка нет — 0');
select is(public.plan_switch_days(12, 0, 790000), 0, 'Бесплатный старый тариф — остаток сгорает');
select is(public.plan_switch_days(1, 1, 2), 1, 'Ровно половина — вверх');
select is(public.plan_switch_days(3, 1, 2), 2, '1,5 → 2');


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

-- Все оплачены на 30 дней вперёд (дата в поясе центра + полдень).
insert into public.centers (id, name, slug, plan, subscription_until, settings)
select x.id::uuid, x.name, x.slug, x.plan,
       (((now() at time zone 'Asia/Bishkek')::date + 30)::timestamp + interval '12 hours') at time zone 'Asia/Bishkek',
       '{"timezone":"Asia/Bishkek"}'::jsonb
  from (values
    ('96000000-0000-0000-0000-0000000000c1', 'Studio → Center 0096', 'centr-0096-a', 'studio'),
    ('96000000-0000-0000-0000-0000000000c2', 'Center → Studio 0096', 'centr-0096-b', 'center'),
    ('96000000-0000-0000-0000-0000000000c3', 'Studio → Studio 0096', 'centr-0096-c', 'studio'),
    ('96000000-0000-0000-0000-0000000000c4', 'Studio со скидкой 0096', 'centr-0096-d', 'studio'),
    ('96000000-0000-0000-0000-0000000000c5', 'Center → Solo 24 0096', 'centr-0096-e', 'center'),
    ('96000000-0000-0000-0000-0000000000c6', 'Studio 24+1 → Center 0096', 'centr-0096-f', 'studio'),
    ('96000000-0000-0000-0000-0000000000c7', 'Заявка Studio, подтверждён Center 0096', 'centr-0096-g', 'studio')
  ) as x(id, name, slug, plan);
-- C8: trial, конец trial через 10 дней.
insert into public.centers (id, name, slug, plan, trial_ends_at, settings) values
  ('96000000-0000-0000-0000-0000000000c8', 'Trial 0096', 'centr-0096-h', 'trial', now() + interval '10 days', '{"timezone":"Asia/Bishkek"}'::jsonb);

-- C4: Studio оплачен на 12 мес. со скидкой 20% — 3 744 000 тыйын, 312 000 в месяц.
insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source,
                                      confirmed_at, plan, months, amount_tiyin)
values ('96000000-0000-0000-0000-0000000000c4', 'studio', 12, 3744000, 'mbank', now() - interval '335 days', 'studio', 12, 3744000);
-- C6: Studio на 24 мес. со скидкой (7 488 000), потом докуплен 1 мес. по прайсу (390 000):
-- средняя цена месяца 7 878 000 / 25 = 315 120, а не 390 000 последней оплаты.
insert into public.platform_payments (center_id, claimed_plan, claimed_months, claimed_amount_tiyin, source,
                                      confirmed_at, plan, months, amount_tiyin) values
  ('96000000-0000-0000-0000-0000000000c6', 'studio', 24, 7488000, 'mbank', now() - interval '700 days', 'studio', 24, 7488000),
  ('96000000-0000-0000-0000-0000000000c6', 'studio', 1, 390000, 'mbank', now() - interval '20 days', 'studio', 1, 390000);

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
create temporary table t_prev (center_id uuid, new_until timestamptz);
grant select, insert on t_prev to authenticated;

-- Заявки владельца: C1 Center 1, C2 Studio 1, C3 Studio 1, C4 Center 1, C5 Solo 24.
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
select public.tests_claims('96000000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-0000000000c4');
set local role authenticated;
select public.submit_platform_payment('center', 1, 'mbank', null);
reset role;
select public.tests_claims('96000000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-0000000000c5');
set local role authenticated;
select public.submit_platform_payment('solo', 24, 'mbank', null);
reset role;
select public.tests_claims('96000000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-0000000000c6');
set local role authenticated;
select public.submit_platform_payment('center', 1, 'mbank', null);
reset role;
select public.tests_claims('96000000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-0000000000c7');
set local role authenticated;
select public.submit_platform_payment('studio', 1, 'mbank', null);
reset role;
select public.tests_claims('96000000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-0000000000c8');
set local role authenticated;
select public.submit_platform_payment('solo', 1, 'mbank', null);
reset role;


-- 3. Предпросмотр /admin (Р6) ---------------------------------------------------------------------

select public.tests_claims('96000000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select throws_ok(
  $$ select * from public.platform_payment_preview((select id from public.platform_payments where center_id = '96000000-0000-0000-0000-0000000000c1' and confirmed_at is null)) $$,
  '42501', null, 'Владельцу центра предпросмотр платформы закрыт');
reset role;

select public.tests_claims('96000000-0000-0000-0000-000000000002', null);
set local role authenticated;
select is(
  (select x.current_until from public.platform_payments p, public.platform_payment_preview(p.id) x
    where p.center_id = '96000000-0000-0000-0000-0000000000c8' and p.confirmed_at is null),
  (select c.trial_ends_at from public.centers c where c.id = '96000000-0000-0000-0000-0000000000c8'),
  'У trial текущий срок в предпросмотре — конец trial, а не пусто');

-- C7: заявка на Studio, платформа подтверждает Center на 1 мес. за 7 900 — предпросмотр с теми же значениями.
insert into t_prev
select p.center_id, x.new_until
  from public.platform_payments p,
       public.platform_payment_preview(p.id,
         case when p.center_id = '96000000-0000-0000-0000-0000000000c7' then 'center' end,
         null,
         case when p.center_id = '96000000-0000-0000-0000-0000000000c7' then 790000 end) x
 where p.center_id::text like '96000000-0000-0000-0000-0000000000c_' and p.confirmed_at is null;

-- Подтверждение платформой (C7 — с переопределением тарифа и суммы).
select public.extend_subscription(p.id,
         case when p.center_id = '96000000-0000-0000-0000-0000000000c7' then 'center' else p.claimed_plan end,
         p.claimed_months,
         case when p.center_id = '96000000-0000-0000-0000-0000000000c7' then 790000 else p.claimed_amount_tiyin end,
         false)
  from public.platform_payments p
 where p.center_id::text like '96000000-0000-0000-0000-0000000000c_' and p.confirmed_at is null
 order by p.center_id;
reset role;


-- 4. Пересчёт при подтверждении (Р1–Р3) -----------------------------------------------------------

select is(
  (select c.subscription_until from public.centers c where c.id = '96000000-0000-0000-0000-0000000000c1'),
  now() + interval '15 days' + interval '1 month',
  'Studio → Center по прайсу: 30 дней = 15 дней Center, срок = сейчас + 15 дней + 1 месяц');
select is(
  (select c.subscription_until from public.centers c where c.id = '96000000-0000-0000-0000-0000000000c2'),
  now() + interval '61 days' + interval '1 month',
  'Center → Studio: 30 дней Center = 61 день Studio');
select is(
  (select c.subscription_until from public.centers c where c.id = '96000000-0000-0000-0000-0000000000c3'),
  (select t.subscription_until + interval '1 month' from t_until t where t.id = '96000000-0000-0000-0000-0000000000c3'),
  'Тот же тариф — + 1 месяц к текущему сроку, без пересчёта');
select is(
  (select c.subscription_until from public.centers c where c.id = '96000000-0000-0000-0000-0000000000c4'),
  now() + interval '12 days' + interval '1 month',
  'По уплаченной цене: 30 × 3120 / 7900 = 11,85 → 12 дней, а не 15 по прайсу (Р2)');
select is(
  (select c.subscription_until from public.centers c where c.id = '96000000-0000-0000-0000-0000000000c5'),
  now() + interval '24 months',
  'Center → Solo на 24 мес.: срок упёрся в потолок 24 месяца (Р3)');
select is(
  (select c.subscription_until from public.centers c where c.id = '96000000-0000-0000-0000-0000000000c6'),
  now() + interval '12 days' + interval '1 month',
  'Средняя уплаченная цена (24 мес. со скидкой + 1 по прайсу): 30 × 3151,2 / 7900 = 11,97 → 12, а не 15 по последней оплате');
select ok(
  (select (e.payload ->> 'excess_days')::int between 290 and 305 and (e.payload ->> 'excess_tiyin')::int > 0
     from public.events e
    where e.type = 'subscription.extended' and e.center_id = '96000000-0000-0000-0000-0000000000c5'),
  'Излишек сверх потолка (~299 дней) и сумма к возврату — в событии');
select ok(
  (select (e.payload ->> 'converted_days')::int = 15 and e.payload ->> 'previous_until' is not null
     from public.events e
    where e.type = 'subscription.extended' and e.center_id = '96000000-0000-0000-0000-0000000000c1'),
  'Событие несёт converted_days и прежний срок');
select is(
  (select count(*)::int from public.centers c join t_prev p on p.center_id = c.id
    where c.id::text like '96000000-0000-0000-0000-0000000000c_' and c.subscription_until <> p.new_until),
  0, 'Предпросмотр /admin совпал с подтверждением у всех центров, в том числе с переопределённым тарифом и суммой (Р6)');


-- 5. Гранты ---------------------------------------------------------------------------------------

select ok(
  not has_function_privilege('authenticated', 'public.plan_switch_days(integer,integer,integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.platform_switch_calc(uuid,text,integer,integer)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.platform_switch_calc(uuid,text,integer,integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.platform_payment_preview(uuid,text,integer,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.platform_payment_preview(uuid,text,integer,integer)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.platform_payment_preview(uuid,text,integer,integer)', 'EXECUTE'),
  'Внутренние расчёты закрыты, предпросмотр — authenticated (проверка платформы внутри)');
select ok(
  not (select p.prosecdef from pg_proc p where p.oid = 'public.platform_switch_calc(uuid,text,integer,integer)'::regprocedure),
  'platform_switch_calc — не definer: без проверки сессии она не должна обходить RLS');

select * from finish();
rollback;
