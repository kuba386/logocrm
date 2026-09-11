-- pgTAP: расходы (миграция 0016).
-- Два центра — межтенантная граница; expense_categories видна только owner/
-- admin (без widely-read, в отличие от payment_sources — у expenses нет
-- родительского потребителя); expenses — только owner/admin; знак суммы —
-- expenses_sign_matches_kind; замок месяца — общий guard с payments, ветка
-- expenses; прямая запись закрыта совсем, кроме update(comment).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(36);

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

-- Оба центра сразу заводят по шесть категорий и пять источников — триггеры
-- centers_seed_expense_categories/centers_seed_payment_sources.
insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a-exp','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-exp','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.memberships (user_id, center_id, role) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner'),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner'),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher'),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a','parent');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

create temporary table t_exp (name text primary key, id uuid);
grant select, insert on t_exp to authenticated;

-- Id чужого (центра Б) справочника — забираются здесь, пока роль ещё
-- postgres и RLS не применяется. Тот же приём и по той же причине, что
-- 0013_finance_core.test.sql:74-88: если взять их подзапросом ПОЗЖЕ, внутри
-- format() под ролью authenticated центра А, политики expense_categories/
-- payment_sources отдадут пусто — %L напечатает NULL без кавычек, и тест
-- вместо составного FK проверит либо NOT NULL, либо (для нулевого source_id,
-- у которого MATCH SIMPLE пропускает NULL) вообще ничего, тихо создав
-- лишнюю строку.
insert into t_exp (name, id)
select 'cat_b', id from public.expense_categories
 where center_id = 'cccccccc-0000-0000-0000-00000000000b' and code = 'rent';
insert into t_exp (name, id)
select 'src_b', id from public.payment_sources
 where center_id = 'cccccccc-0000-0000-0000-00000000000b' and code = 'cash';

-- Расход центра А — до блока изоляции. Без него "владелец Б/специалист/
-- родитель не видят расходов А" проходило бы и при полностью открытых
-- политиках: расходов не было бы вообще ни у кого (тот же урок, что для
-- student_payers в 0013_finance_core.test.sql, тесты 1-3).
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into t_exp (name, id)
select 'seed', public.record_expense(
  (select id from public.expense_categories
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'supplies'),
  40000
);

reset role;


-- 1-7. Изоляция и роли ---------------------------------------------------------

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b');
set local role authenticated;

select is(
  (select count(*)::int from public.expense_categories where center_id = 'cccccccc-0000-0000-0000-00000000000a'),
  0,
  'Владелец центра Б не видит категории расходов центра А'
);
select is(
  (select count(*)::int from public.expense_categories where center_id = 'cccccccc-0000-0000-0000-00000000000b'),
  6,
  'Владелец центра Б видит все шесть своих категорий (сид create_center)'
);
select is(
  (select count(*)::int from public.expenses), 0,
  'Владелец центра Б не видит расходов центра А'
);

reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.expense_categories), 0,
  'Специалист не видит категории расходов вообще — apply_tenant_rls только owner/admin, широкого read_all нет (в отличие от payment_sources)'
);
select is(
  (select count(*)::int from public.expenses), 0,
  'Специалист не видит сами расходы'
);

reset role;

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.expense_categories), 0,
  'Родитель не видит категории расходов'
);
select is(
  (select count(*)::int from public.expenses), 0,
  'Родитель не видит расходы — в отличие от payments, у expenses нет политики для parent вовсе'
);

reset role;


-- 8. Отозванное членство ------------------------------------------------------

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.record_expense(
        (select id from public.expense_categories
          where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'rent'),
        50000
      ) $q$,
  '42501', 'Недостаточно прав', 'record_expense: отозванный получает 42501'
);

reset role;


-- 9-13. Прямая запись закрыта, кроме comment у expenses --------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select ok(
  not has_table_privilege('authenticated', 'public.expenses', 'INSERT'),
  'authenticated не может вставить расход напрямую — только через record_expense'
);
select ok(
  not has_table_privilege('authenticated', 'public.expenses', 'DELETE'),
  'authenticated не может удалить расход вообще'
);
select ok(
  not has_table_privilege('authenticated', 'public.expense_categories', 'DELETE'),
  'authenticated не может удалить категорию напрямую — только архивировать через RPC'
);

insert into t_exp (name, id)
select 'e1', public.record_expense(
  (select id from public.expense_categories
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'supplies'),
  70000
);

select throws_ok(
  format($q$ update public.expenses set paid_at = %L where id = %L $q$,
    now() - interval '2 months', (select id from t_exp where name = 'e1')),
  '42501', null,
  'paid_at не в гранте на update вовсе — перенос отбивается на гранте раньше, чем на замке (тот же приём, что у payments)'
);
select lives_ok(
  format($q$ update public.expenses set comment = 'правка комментария' where id = %L $q$,
    (select id from t_exp where name = 'e1')),
  'comment — единственное поле, доступное клиенту напрямую (как у payments)'
);

reset role;


-- 14-17. Замок месяца на expenses --------------------------------------------------

-- Расход в M1 заводится, пока M1 ещё открыт — сам insert иначе отбился бы
-- тем же замком, который здесь и проверяется чуть ниже на DELETE.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into t_exp (name, id)
select 'del_me', public.record_expense(
  (select id from public.expense_categories
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'marketing'),
  30000, 'expense', null,
  (date_trunc('month', now() - interval '2 months') + interval '10 days')::date
);

select lives_ok(
  $q$ select public.close_month(date_trunc('month', now() - interval '2 months')::date) $q$,
  'close_month(M1) проходит — в M1 нет ни одного занятия'
);

select throws_ok(
  format($q$ select public.record_expense(
        (select id from public.expense_categories
          where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'rent'),
        50000, 'expense', null, %L
      ) $q$,
    (date_trunc('month', now() - interval '2 months') + interval '5 days')::date),
  '22023', null,
  'Новый расход датой уже закрытого месяца (M1) отклонён замком'
);

insert into t_exp (name, id)
select 'e2', public.record_expense(
  (select id from public.expense_categories
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'rent'),
  50000
);

select is(
  (select count(*)::int from public.expenses where id = (select id from t_exp where name = 'e2')),
  1,
  'Расход текущим (открытым) месяцем проходит'
);

reset role;

-- DELETE-ветка не падает 55000 — тем же приёмом, что у payments в 0014:
-- authenticated не может удалить строку вообще (проверено в 9-13), значит
-- проверить, что триггер сам не падает на DELETE, можно только от postgres.
-- 'del_me' создан ДО close_month(M1) выше и датирован M1 — существующая в
-- уже закрытом месяце строка, ровно нужный для DELETE случай.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');

select throws_ok(
  format($q$ delete from public.expenses where id = %L $q$,
    (select id from t_exp where name = 'del_me')),
  '22023', null,
  'DELETE расхода в закрытом месяце отклонён замком (22023), а не падает 55000'
);


-- 18-20. Знак суммы и тип ---------------------------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.record_expense(
        (select id from public.expense_categories
          where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'other'),
        -1000, 'expense'
      ) $q$,
  '23514', null, 'expense с отрицательной суммой — CHECK expenses_sign_matches_kind'
);
select throws_ok(
  $q$ select public.record_expense(
        (select id from public.expense_categories
          where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'other'),
        1000, 'refund'
      ) $q$,
  '23514', null, 'refund с положительной суммой — CHECK expenses_sign_matches_kind'
);
select throws_ok(
  $q$ select public.record_expense(
        (select id from public.expense_categories
          where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'other'),
        0, 'expense'
      ) $q$,
  '23514', null, 'нулевая сумма отклонена (CHECK)'
);


-- 21-22. Ошибка правится correction, не update ---------------------------------------

insert into t_exp (name, id)
select 'e3', public.record_expense(
  (select id from public.expense_categories
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'other'),
  300000
);

select lives_ok(
  $q$ select public.record_expense(
        (select id from public.expense_categories
          where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'other'),
        -270000, 'correction', null, null, 'опечатка — 30000, не 300000'
      ) $q$,
  'Корректировка отрицательной суммой в открытом месяце проходит'
);

select is(
  (select coalesce(sum(amount_tiyin), 0)::int from public.expenses
    where category_id = (select id from public.expense_categories
                           where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'other')),
  30000,
  'Сумма по категории после корректировки верна (300000 - 270000 = 30000) — ошибку правит новая строка, не update'
);

reset role;


-- 23-24. Составной FK — категория/источник чужого центра --------------------------

-- t_exp['cat_b']/['src_b'] заведены как postgres в самом начале файла —
-- см. комментарий там же.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  format($q$ select public.record_expense(%L, 10000) $q$,
    (select id from t_exp where name = 'cat_b')),
  '23503', null,
  'Расход на категорию чужого (центра Б) центра отклонён составным FK'
);

select throws_ok(
  format($q$ select public.record_expense(
        (select id from public.expense_categories
          where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'other'),
        10000, 'expense', %L
      ) $q$,
    (select id from t_exp where name = 'src_b')),
  '23503', null,
  'Расход с источником чужого (центра Б) центра отклонён составным FK'
);

reset role;


-- 25-27. Архив/восстановление категории эмитят события ----------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

insert into t_exp (name, id)
select 'cat', id from public.expense_categories
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'utilities';

select public.archive_expense_category((select id from t_exp where name = 'cat'));

reset role;

select is(
  (select count(*)::int from public.events where type = 'expense_category.archived'),
  1,
  'archive_expense_category эмитит событие'
);
select is(
  (select count(*)::int from public.expense_categories
    where id = (select id from t_exp where name = 'cat') and deleted_at is not null),
  1,
  'Категория помечена архивной'
);

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select public.restore_expense_category((select id from t_exp where name = 'cat'));

reset role;

select is(
  (select count(*)::int from public.events where type = 'expense_category.restored'),
  1,
  'restore_expense_category эмитит событие'
);


-- 28. Идемпотентность сида — повторный вызов не плодит дублей ---------------------

-- auth.uid() всё ещё не null (последний tests_claims — из restore выше,
-- reset role его не трогает, он transaction-local) — seed_expense_categories
-- сама отбила бы прямой вызов живым пользователем (pg_trigger_depth() = 0).
-- Явное обнуление перед вызовом — тот же приём, что и у
-- backfill_student_payers_history в 0014.
select public.tests_claims(null, null);

select public.seed_expense_categories('cccccccc-0000-0000-0000-00000000000a');

select is(
  (select count(*)::int from public.expense_categories where center_id = 'cccccccc-0000-0000-0000-00000000000a'),
  6,
  'Повторный вызов seed_expense_categories не плодит дубли категорий (on conflict do nothing)'
);


-- 29-30. Гранты: белый список 0007 дополнен ---------------------------------------

select ok(
  not has_function_privilege('authenticated', 'public.seed_expense_categories(uuid)', 'EXECUTE'),
  'seed_expense_categories закрыта для authenticated'
);
select ok(
  has_function_privilege('authenticated', 'public.record_expense(uuid,integer,text,uuid,date,text)', 'EXECUTE'),
  'record_expense исполняется authenticated (белый список 0007 актуален)'
);


-- 31-32. Специалист отбивается и от записи, и от архивации ------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.record_expense(
        (select id from public.expense_categories
          where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'other'),
        10000
      ) $q$,
  '42501', 'Недостаточно прав', 'record_expense: специалист получает 42501'
);
select throws_ok(
  format($q$ select public.archive_expense_category(%L) $q$,
    (select id from t_exp where name = 'cat')),
  '42501', 'Недостаточно прав', 'archive_expense_category: специалист получает 42501'
);

reset role;


-- 33. financial_period_guard: неизвестная таблица не проходит молча --------------

-- Прямое доказательство находки архитектора против плана: guard, применённый
-- (по ошибке будущей миграции) к таблице без собственной ветки, обязан
-- упасть громко, а не тихо пропустить любую операцию — иначе замок месяца на
-- такой таблице не работал бы вообще, и это не было бы видно ни разу.
create temp table t_guard_probe (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null,
  paid_at timestamptz not null default now()
);

create trigger t_guard_probe_guard
  before insert or update or delete on t_guard_probe
  for each row execute function public.financial_period_guard();

select throws_ok(
  format($q$ insert into t_guard_probe (center_id) values (%L) $q$,
    'cccccccc-0000-0000-0000-00000000000a'),
  '42704', null,
  'financial_period_guard на таблице без собственной ветки падает громко (else raise), а не молчит'
);

drop table t_guard_probe;


-- 34-36. Контрольные суммы за весь файл --------------------------------------------

select is(
  (select count(*)::int from public.payments), 0,
  'Этот файл не создал ни одного payments — все суммы выше именно про expenses'
);
select is(
  (select count(*)::int from public.expenses where kind = 'correction'),
  1,
  'Ровно одна корректирующая строка за весь файл (тест 21)'
);
select is(
  (select count(*)::int from public.expenses where center_id = 'cccccccc-0000-0000-0000-00000000000a'),
  6,
  'Всего в центре А шесть строк expenses: seed(supplies), e1(supplies), del_me(marketing/M1 — DELETE отбит замком, строка жива), e2(rent), e3+correction(other)'
);

select * from finish();

rollback;
