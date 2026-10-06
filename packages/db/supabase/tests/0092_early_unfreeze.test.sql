-- pgTAP: разморозить раньше срока (0092).
--
-- Р1: датированная заморозка, которая уже идёт, заканчивается сегодня —
-- абонемент снова действует, срок абонемента на период пересчитан триггером
-- (3 прошедших дня заморозки вместо 13). То же у пакета занятий. Будущая дата
-- конца по-прежнему отказ. Р3: без сессии — 42501 первой строкой.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(7);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
) values
  ('00000000-0000-0000-0000-000000000000', '92000000-0000-0000-0000-000000000001',
   'authenticated', 'authenticated', 'u1-0092@test.kg', '', '', '', '', '', '', '', '');

insert into public.centers (id, name, slug, settings) values
  ('92000000-0000-0000-0000-0000000000c1', 'Центр 0092', 'centr-0092', '{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.memberships (user_id, center_id, role) values
  ('92000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-0000000000c1', 'owner');
insert into public.payers (id, center_id, full_name, phone) values
  ('92000000-0000-0000-0000-00000000dd01', '92000000-0000-0000-0000-0000000000c1', 'Плательщик 0092', '+996700009201');
insert into public.students (id, center_id, full_name, payer_id) values
  ('92000000-0000-0000-0000-00000000ee01', '92000000-0000-0000-0000-0000000000c1', 'Ученик 0092', '92000000-0000-0000-0000-00000000dd01');
insert into public.subscription_types (id, center_id, name, kind, period_days, price_tiyin) values
  ('92000000-0000-0000-0000-0000000007a1', '92000000-0000-0000-0000-0000000000c1', 'Месяц 0092', 'period', 30, 300000);

-- M: абонемент на месяц с 10 дней назад; L: пакет 8 занятий.
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin,
                                  lesson_price_tiyin, starts_at, ends_at) values
  ('92000000-0000-0000-0000-0000000055a1', '92000000-0000-0000-0000-0000000000c1', '92000000-0000-0000-0000-00000000ee01',
   '92000000-0000-0000-0000-00000000dd01', '92000000-0000-0000-0000-0000000007a1', null, 300000, null,
   public.center_today('92000000-0000-0000-0000-0000000000c1') - 10,
   public.center_today('92000000-0000-0000-0000-0000000000c1') + 20),
  ('92000000-0000-0000-0000-0000000055a2', '92000000-0000-0000-0000-0000000000c1', '92000000-0000-0000-0000-00000000ee01',
   '92000000-0000-0000-0000-00000000dd01', null, 8, 400000, 50000,
   public.center_today('92000000-0000-0000-0000-0000000000c1') - 10, null);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Абонемент на месяц: заморозка с 3 дней назад на 13 дней, разморозка сегодня -----------------

select public.tests_claims('92000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.freeze_subscription('92000000-0000-0000-0000-0000000055a1',
  public.center_today('92000000-0000-0000-0000-0000000000c1') - 3,
  public.center_today('92000000-0000-0000-0000-0000000000c1') + 10);
select is(public.subscription_state('92000000-0000-0000-0000-0000000055a1'), 'frozen', 'Датированная заморозка идёт');
select throws_ok(
  $$ select public.unfreeze_subscription('92000000-0000-0000-0000-0000000055a1',
       public.center_today('92000000-0000-0000-0000-0000000000c1') + 2) $$,
  '22023', null, 'Будущей датой — по-прежнему отказ: конец вперёд задаётся при заморозке');
select lives_ok(
  $$ select public.unfreeze_subscription('92000000-0000-0000-0000-0000000055a1') $$,
  'Датированную идущую заморозку можно закончить сегодня (раньше — «нет открытой заморозки»)');
select is(public.subscription_state('92000000-0000-0000-0000-0000000055a1'), 'active', 'Абонемент снова действует');
reset role;

select is(
  (select s.ends_at - s.starts_at from public.subscriptions s where s.id = '92000000-0000-0000-0000-0000000055a1'),
  33, 'Срок пересчитан: 30 дней + 3 дня заморозки, а не 13');


-- 3. Пакет занятий ---------------------------------------------------------------------------------

select public.tests_claims('92000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select public.freeze_subscription('92000000-0000-0000-0000-0000000055a2',
  public.center_today('92000000-0000-0000-0000-0000000000c1') - 2,
  public.center_today('92000000-0000-0000-0000-0000000000c1') + 14);
select public.unfreeze_subscription('92000000-0000-0000-0000-0000000055a2');
select is(public.subscription_state('92000000-0000-0000-0000-0000000055a2'), 'active', 'Пакет занятий тоже размораживается раньше срока');
reset role;


-- 4. Без сессии ------------------------------------------------------------------------------------

select set_config('request.jwt.claims', '{}', true);
set local role authenticated;
select throws_ok(
  $$ select public.unfreeze_subscription('92000000-0000-0000-0000-0000000055a2') $$,
  '42501', 'Требуется авторизация', 'Без сессии — 42501 первой строкой');
reset role;

select * from finish();
rollback;
