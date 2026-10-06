-- pgTAP: сохранённые фильтры (0094).
--
-- Каталог: authenticated — только SELECT, у anon и service_role ничего,
-- политик на запись нет, readonly-guard на все операции, гранты функций.
-- Изоляция: набор видит только автор и только в том центре, где сохранил
-- (один человек в двух центрах — главная ось), admin не видит наборы owner,
-- parent и отозванный участник не видят даже свою строку. Роли по странице
-- (Р4). Значения — CHECK в базе (Р3), тот же набор случаев, что в Vitest
-- (packages/core/src/saved-filters.test.ts). Перезапись по имени без учёта регистра,
-- лимит 20, архивация чужого и архивного — 42704, просроченный центр — PT402.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(44);


-- 1. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', ('94000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       'authenticated', 'authenticated', 'u' || n || '-0094@test.kg', '', '', '', '', '', '', '', ''
  from generate_series(1, 7) n;

insert into public.centers (id, name, slug, settings) values
  ('94000000-0000-0000-0000-0000000000c1', 'Центр 0094', 'centr-0094', '{"timezone":"Asia/Bishkek"}'::jsonb),
  ('94000000-0000-0000-0000-0000000000c2', 'Центр Б 0094', 'centr-0094-b', '{"timezone":"Asia/Bishkek"}'::jsonb);
insert into public.centers (id, name, slug, plan, subscription_until, settings) values
  ('94000000-0000-0000-0000-0000000000c3', 'Центр 0094 просрочен', 'centr-0094-c', 'solo', now() - interval '2 days',
   '{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.payers (id, center_id, full_name, phone) values
  ('94000000-0000-0000-0000-00000000dd01', '94000000-0000-0000-0000-0000000000c1', 'Плательщик 0094', '+996700009401');

-- 1 owner c1 и admin c2 · 2 admin c1 · 3 teacher c1 · 4 finance c1 · 5 parent c1 ·
-- 6 без членства (отозван, claim c1 остался) · 7 owner просроченного c3.
insert into public.memberships (user_id, center_id, role, payer_id) values
  ('94000000-0000-0000-0000-000000000001', '94000000-0000-0000-0000-0000000000c1', 'owner', null),
  ('94000000-0000-0000-0000-000000000001', '94000000-0000-0000-0000-0000000000c2', 'admin', null),
  ('94000000-0000-0000-0000-000000000002', '94000000-0000-0000-0000-0000000000c1', 'admin', null),
  ('94000000-0000-0000-0000-000000000003', '94000000-0000-0000-0000-0000000000c1', 'teacher', null),
  ('94000000-0000-0000-0000-000000000004', '94000000-0000-0000-0000-0000000000c1', 'finance', null),
  ('94000000-0000-0000-0000-000000000005', '94000000-0000-0000-0000-0000000000c1', 'parent', '94000000-0000-0000-0000-00000000dd01'),
  ('94000000-0000-0000-0000-000000000007', '94000000-0000-0000-0000-0000000000c3', 'owner', null);

-- Строка parent, вставленная владельцем таблицы: политика всё равно её не покажет.
insert into public.saved_filters (id, center_id, user_id, page, name, params) values
  ('94000000-0000-0000-0000-0000000000f5', '94000000-0000-0000-0000-0000000000c1',
   '94000000-0000-0000-0000-000000000005', 'schedule', 'Родительский', '{}');
-- И строка отозванного участника.
insert into public.saved_filters (id, center_id, user_id, page, name, params) values
  ('94000000-0000-0000-0000-0000000000f6', '94000000-0000-0000-0000-0000000000c1',
   '94000000-0000-0000-0000-000000000006', 'debts', 'Старый', '{"filter":"debt"}');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- 2. Каталог --------------------------------------------------------------------------------------

select is_empty(
  $$ select a.grantee::regrole::text || ' ' || a.privilege_type
       from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      where c.oid = 'public.saved_filters'::regclass
        and a.grantee <> c.relowner
        and not (a.grantee = 'authenticated'::regrole and a.privilege_type = 'SELECT') $$,
  'saved_filters: authenticated — только SELECT, у anon и service_role нет ничего');

select is_empty(
  $$ select policyname from pg_policies
      where schemaname = 'public' and tablename = 'saved_filters' and cmd <> 'SELECT' $$,
  'saved_filters: ни одной политики на запись — только RPC');

select is_empty(
  $$ select p.oid::regprocedure::text || ' ' || r
       from pg_proc p, unnest(array['public', 'anon', 'service_role']) r
      where p.oid in ('public.save_filter(text,text,jsonb)'::regprocedure,
                      'public.archive_saved_filter(uuid)'::regprocedure,
                      'public.saved_filter_pages()'::regprocedure)
        and has_function_privilege(r, p.oid, 'EXECUTE') $$,
  'RPC сохранённых фильтров: ни PUBLIC, ни anon, ни service_role');

select ok(
  has_function_privilege('authenticated', 'public.save_filter(text,text,jsonb)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.archive_saved_filter(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.saved_filter_pages()', 'EXECUTE'),
  'authenticated исполняет save_filter, archive_saved_filter и saved_filter_pages');

select is_empty(
  $$ select r from unnest(array['public', 'anon', 'authenticated', 'service_role']) r
      where has_function_privilege(r, 'public.saved_filter_params_ok(text,jsonb)', 'EXECUTE') $$,
  'Валидатор params закрыт для всех ролей — его исполняют CHECK и RPC от владельца');

select ok(
  exists (select 1 from pg_trigger tg
           where tg.tgrelid = 'public.saved_filters'::regclass and tg.tgname = 'a00_readonly_guard'
             and (tg.tgtype & 2) = 2 and (tg.tgtype & 28) = 28),
  'readonly-guard: BEFORE на insert, update и delete');

select ok(
  exists (select 1 from public.export_center_excluded_tables() x where x.table_name = 'saved_filters')
  and not exists (select 1 from public.export_center_tables() x where x.table_name = 'saved_filters'),
  'Экспорт центра: saved_filters в deny-list, не в выгрузке');


-- 3. Значения — CHECK в базе (Р3) ------------------------------------------------------------------
-- Тот же набор, что в packages/core/src/saved-filters.test.ts.

select ok(
  public.saved_filter_params_ok('schedule', '{"teacher":"94000000-0000-0000-0000-000000000003","room":"none"}')
  and public.saved_filter_params_ok('schedule', '{}')
  and public.saved_filter_params_ok('debts', '{"filter":"debt","sort":"name","min":"5000"}')
  and public.saved_filter_params_ok('debts', '{"min":"9999999"}'),
  'Допустимые наборы проходят: uuid, room=none, пустой, перечни, min до 9 999 999');

select is(
  (select array_agg(c.ok order by c.n)
     from (values
       (1, public.saved_filter_params_ok('schedule', '{"week":"2026-10-05"}')),
       (2, public.saved_filter_params_ok('schedule', '{"teacher":"нет"}')),
       (3, public.saved_filter_params_ok('schedule', '{"teacher":123}')),
       (4, public.saved_filter_params_ok('debts', '{"min":"0"}')),
       (5, public.saved_filter_params_ok('debts', '{"min":"05"}')),
       (6, public.saved_filter_params_ok('debts', '{"min":"5000.5"}')),
       (7, public.saved_filter_params_ok('debts', '{"min":"10000000"}')),
       (8, public.saved_filter_params_ok('debts', '{"filter":"overdue"}')),
       (9, public.saved_filter_params_ok('debts', '{"teacher":"94000000-0000-0000-0000-000000000003"}')),
       (10, public.saved_filter_params_ok('schedule', '[]')),
       (11, public.saved_filter_params_ok('debts', '{"min":5000}'))
     ) c(n, ok)),
  array[false, false, false, false, false, false, false, false, false, false, false],
  'Недопустимые: чужой ключ (week), не uuid, не строка, min 0/05/дробь/8 цифр, вне перечня, ключ другой страницы, массив');

select throws_ok(
  $$ insert into public.saved_filters (center_id, user_id, page, name, params)
     values ('94000000-0000-0000-0000-0000000000c1', '94000000-0000-0000-0000-000000000001', 'debts', 'Обход', '{"min":"1e9"}') $$,
  '23514', null,
  'Прямая вставка владельцем таблицы с плохим min падает на CHECK — гарантия в базе, не в функции');

select throws_ok(
  $$ insert into public.saved_filters (center_id, user_id, page, name, params)
     values ('94000000-0000-0000-0000-0000000000c1', '94000000-0000-0000-0000-000000000001', 'schedule', ' Пробел', '{}') $$,
  '23514', null,
  'Имя с пробелом по краю не проходит CHECK');


-- 4. Сохранение, перезапись, изоляция ---------------------------------------------------------------

select public.tests_claims('94000000-0000-0000-0000-000000000001', '94000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select lives_ok(
  $$ select public.save_filter('schedule', '  Мои кабинеты  ', '{"room":"none"}') $$,
  'owner сохраняет набор расписания');
select is(
  (select name from public.saved_filters where page = 'schedule'),
  'Мои кабинеты', 'Имя без пробелов по краям, набор виден автору');
select is(
  public.save_filter('schedule', 'МОИ КАБИНЕТЫ', '{"room":"none","teacher":"94000000-0000-0000-0000-000000000003"}'),
  (select id from public.saved_filters where page = 'schedule'),
  'То же имя в другом регистре (кириллица) — тот же id');
select is(
  (select count(*)::int from public.saved_filters where page = 'schedule'), 1,
  'Перезапись, а не дубль: живой набор один');
select is(
  (select name || ' ' || (params ->> 'teacher') from public.saved_filters where page = 'schedule'),
  'МОИ КАБИНЕТЫ 94000000-0000-0000-0000-000000000003',
  'Перезапись обновила и регистр имени, и params');
select lives_ok(
  $$ select public.save_filter('debts', 'Больше 5 000', '{"filter":"debt","min":"5000"}') $$,
  'owner сохраняет набор долгов');

select throws_ok(
  $$ select public.save_filter('schedule', 'Неделя', '{"week":"2026-10-05"}') $$,
  '23514', 'Фильтр не сохранён: в нём есть недопустимое значение',
  'Неделя не сохраняется — русский текст из функции до CHECK');
select throws_ok(
  $$ select public.save_filter('schedule', '   ', '{}') $$,
  '23514', 'Укажите название фильтра',
  'Пустое имя — отказ');
select throws_ok(
  $$ select public.save_filter('reports', 'Чужая страница', '{}') $$,
  '42501', 'Недостаточно прав',
  'Неизвестная страница — отказ');

-- Прямая запись от authenticated.
select throws_ok(
  $$ insert into public.saved_filters (page, name, params) values ('schedule', 'Напрямую', '{}') $$,
  '42501', null, 'Прямой insert от authenticated запрещён');
select throws_ok(
  $$ update public.saved_filters set name = 'Правка' $$,
  '42501', null, 'Прямой update от authenticated запрещён');
select throws_ok(
  $$ delete from public.saved_filters $$,
  '42501', null, 'Прямой delete от authenticated запрещён');
reset role;

-- Тот же человек в центре Б (admin) — наборы центра А не видны.
select public.tests_claims('94000000-0000-0000-0000-000000000001', '94000000-0000-0000-0000-0000000000c2');
set local role authenticated;
select is(
  (select count(*)::int from public.saved_filters), 0,
  'Один человек в двух центрах: в центре Б не видны наборы центра А');
select lives_ok(
  $$ select public.save_filter('schedule', 'Мои кабинеты', '{}') $$,
  'В центре Б то же имя — отдельный набор, не конфликт');
reset role;

-- admin того же центра.
select public.tests_claims('94000000-0000-0000-0000-000000000002', '94000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.saved_filters), 0,
  'admin того же центра не видит наборы owner');
reset role;

-- Чужой id — тот же ответ, что несуществующий.
select public.tests_claims('94000000-0000-0000-0000-000000000002', '94000000-0000-0000-0000-0000000000c1');
create temporary table t0094_owner_ids on commit drop as
  select id, page from public.saved_filters
   where user_id = '94000000-0000-0000-0000-000000000001' and center_id = '94000000-0000-0000-0000-0000000000c1';
grant select on t0094_owner_ids to authenticated;
set local role authenticated;
select throws_ok(
  $$ select public.archive_saved_filter((select id from t0094_owner_ids where page = 'debts')) $$,
  '42704', 'Фильтр не найден',
  'admin не архивирует набор owner — неотличимо от несуществующего');
reset role;


-- 5. Роли по странице (Р4) -------------------------------------------------------------------------

select public.tests_claims('94000000-0000-0000-0000-000000000003', '94000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.save_filter('schedule', 'Мои занятия', '{}') $$,
  'teacher сохраняет набор расписания');
select throws_ok(
  $$ select public.save_filter('debts', 'Долги', '{}') $$,
  '42501', 'Недостаточно прав', 'teacher не сохраняет набор долгов');
reset role;

select public.tests_claims('94000000-0000-0000-0000-000000000004', '94000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $$ select public.save_filter('debts', 'Просрочки', '{"filter":"debt"}') $$,
  'finance сохраняет набор долгов (can_payments)');
select throws_ok(
  $$ select public.save_filter('schedule', 'Расписание', '{}') $$,
  '42501', 'Недостаточно прав', 'finance не сохраняет набор расписания — страница его не пускает');
reset role;

select public.tests_claims('94000000-0000-0000-0000-000000000005', '94000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.saved_filters), 0,
  'parent не видит даже свою строку');
select throws_ok(
  $$ select public.save_filter('schedule', 'Моё', '{}') $$,
  '42501', 'Недостаточно прав', 'parent не сохраняет наборы');
select throws_ok(
  $$ select public.archive_saved_filter('94000000-0000-0000-0000-0000000000f5') $$,
  '42704', 'Фильтр не найден', 'parent не архивирует и свою строку — страница ему не положена');
reset role;

select public.tests_claims('94000000-0000-0000-0000-000000000006', '94000000-0000-0000-0000-0000000000c1');
set local role authenticated;
select is(
  (select count(*)::int from public.saved_filters), 0,
  'Отозванный участник со старым claim не видит свои прежние наборы');
select throws_ok(
  $$ select public.save_filter('debts', 'Ещё', '{}') $$,
  '42501', 'Недостаточно прав', 'Отозванный участник не сохраняет');
reset role;


-- 6. Лимит 20, архивация --------------------------------------------------------------------------

select public.tests_claims('94000000-0000-0000-0000-000000000001', '94000000-0000-0000-0000-0000000000c1');
set local role authenticated;
-- Уже есть «Больше 5 000» — добавляем ещё 19 до 20.
select lives_ok(
  $$ select public.save_filter('debts', 'Набор ' || n, '{}') from generate_series(1, 19) n $$,
  '20 живых наборов долгов сохраняются');
select throws_ok(
  $$ select public.save_filter('debts', 'Двадцать первый', '{}') $$,
  '23514', 'Не больше 20 сохранённых фильтров на странице — удалите ненужный',
  '21-й новый набор — отказ');
select lives_ok(
  $$ select public.save_filter('debts', 'набор 7', '{"sort":"name"}') $$,
  'Перезапись при 20 живых проходит — лимит только на новые');
select lives_ok(
  $$ select public.archive_saved_filter((select id from public.saved_filters where name = 'Набор 1' or name = 'набор 1')) $$,
  'Свой набор архивируется');
select lives_ok(
  $$ select public.save_filter('debts', 'Двадцать первый', '{}') $$,
  'После архивации место освободилось');
select is(
  (select count(*)::int from public.saved_filters where page = 'debts'), 20,
  'Живых наборов долгов снова 20');
reset role;

select public.tests_claims('94000000-0000-0000-0000-000000000001', '94000000-0000-0000-0000-0000000000c1');
create temporary table t0094_archived on commit drop as
  select id from public.saved_filters where name = 'Набор 1' and deleted_at is not null;
grant select on t0094_archived to authenticated;
set local role authenticated;
select throws_ok(
  $$ select public.archive_saved_filter((select id from t0094_archived)) $$,
  '42704', 'Фильтр не найден', 'Повторная архивация — «не найден»');
reset role;


-- 7. Просроченный центр — PT402 (Р7) ---------------------------------------------------------------

select public.tests_claims('94000000-0000-0000-0000-000000000007', '94000000-0000-0000-0000-0000000000c3');
set local role authenticated;
select throws_ok(
  $$ select public.save_filter('schedule', 'Не сохранится', '{}') $$,
  'PT402', null, 'Владелец просроченного центра не сохраняет набор — режим только чтения');
reset role;
select public.tests_claims(null, null);


select * from finish();
rollback;
