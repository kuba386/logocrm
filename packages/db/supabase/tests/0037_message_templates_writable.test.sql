-- pgTAP: шаблоны реально можно сохранить (0037).
--
-- 0034 проверял только чтение и права: все вставки в message_templates шли
-- от postgres при пустых claims, ни один тест не писал в неё от
-- authenticated — оттого баг («new row violates row-level security policy»)
-- доехал до живой приёмки с зелёным CI. Здесь тесты пишут от authenticated
-- с ролью owner/admin/teacher/parent, как и должна была первая версия.
--
-- Вызовы event_messages — от postgres при пустых claims, как звал бы их
-- bot_worker (тот же приём, что в 0034/0035).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(18);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','a0370000-0000-0000-0000-000000000001','authenticated','authenticated','owner-a-037@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0370000-0000-0000-0000-000000000002','authenticated','authenticated','owner-b-037@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0370000-0000-0000-0000-000000000003','authenticated','authenticated','teacher-037@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','a0370000-0000-0000-0000-000000000004','authenticated','authenticated','parent-037@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('c0370000-0000-0000-0000-00000000000a','Центр А 037','centr-a-037','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('c0370000-0000-0000-0000-00000000000b','Центр Б 037','centr-b-037','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('b0370000-0000-0000-0000-000000000001','c0370000-0000-0000-0000-00000000000a','Нургуль 037');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('b0370000-0000-0000-0000-000000000002','c0370000-0000-0000-0000-00000000000a','Логопед 037',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('d0370000-0000-0000-0000-000000000001','c0370000-0000-0000-0000-00000000000a','Родитель 037','+996700370001');

insert into public.students (id, center_id, full_name, payer_id) values
  ('e0370000-0000-0000-0000-000000000001','c0370000-0000-0000-0000-00000000000a','Айдана 037','d0370000-0000-0000-0000-000000000001');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('a0370000-0000-0000-0000-000000000001','c0370000-0000-0000-0000-00000000000a','owner',   null, null),
  ('a0370000-0000-0000-0000-000000000002','c0370000-0000-0000-0000-00000000000b','owner',   null, null),
  ('a0370000-0000-0000-0000-000000000003','c0370000-0000-0000-0000-00000000000a','teacher', 'b0370000-0000-0000-0000-000000000001', null),
  ('a0370000-0000-0000-0000-000000000004','c0370000-0000-0000-0000-00000000000a','parent',  null, 'd0370000-0000-0000-0000-000000000001');

-- Родитель с привязанным Telegram — иначе канал ушёл бы в whatsapp_link, а
-- проверяем именно telegram-строку, которую правим тестом.
insert into public.telegram_accounts (user_id, chat_id) values
  ('a0370000-0000-0000-0000-000000000004', 37001);

insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('b0370000-0000-0000-0000-000000000003','c0370000-0000-0000-0000-00000000000a','b0370000-0000-0000-0000-000000000001','e0370000-0000-0000-0000-000000000001','b0370000-0000-0000-0000-000000000002','planned','2027-01-10 10:00+06','2027-01-10 10:45+06');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

create temporary table t_ev (name text primary key, id bigint);

with ins as (
  insert into public.events (center_id, type, payload)
  values ('c0370000-0000-0000-0000-00000000000a', 'lesson.reminder',
          jsonb_build_object('center_id','c0370000-0000-0000-0000-00000000000a',
                             'lesson_id','b0370000-0000-0000-0000-000000000003'))
  returning id)
insert into t_ev select 'reminder', id from ins;


-- 1-2. Колонка и дефолты платформы не задеты --------------------------------------------------------

select matches(
  (select pg_get_expr(d.adbin, d.adrelid)
     from pg_catalog.pg_attrdef d
     join pg_catalog.pg_class c on c.oid = d.adrelid
     join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum = d.adnum
    where c.relname = 'message_templates' and a.attname = 'center_id'),
  'current_center',
  'center_id получил default current_center() — как у services/subscription_types (0037 Р1)'
);

select is_empty(
  $$ select t.event_type from public.notification_event_types t
      where (select coalesce(array_agg(m.channel order by m.channel), '{}'::text[])
               from public.message_templates m
              where m.center_id is null and m.deleted_at is null and m.event_type = t.event_type)
            is distinct from
            (select coalesce(array_agg(c order by c), '{}'::text[]) from unnest(t.channels) c) $$,
  'Дефолты платформы (center_id is null) не задеты алтером колонки — ровно объявленные каналы (0051)'
);


-- 3-5. Owner сохраняет шаблон без явного center_id ---------------------------------------------------

select public.tests_claims('a0370000-0000-0000-0000-000000000001', 'c0370000-0000-0000-0000-00000000000a');
set local role authenticated;

select isnt(
  public.upsert_message_template('lesson.reminder', 'telegram', '[тест 037] Завтра в {time} у {child}.', true),
  null,
  'upsert_message_template создаёт свою строку без явного center_id — раньше падало RLS (Р1)'
);

select is(
  (select count(*)::int from public.message_templates
    where center_id = 'c0370000-0000-0000-0000-00000000000a'
      and event_type = 'lesson.reminder' and channel = 'telegram' and deleted_at is null),
  1, 'Ровно одна живая строка центра на ключ после первого сохранения'
);

select public.upsert_message_template('lesson.reminder', 'telegram', '[тест 037 v2]', false);

select is(
  (select count(*)::int from public.message_templates
    where center_id = 'c0370000-0000-0000-0000-00000000000a'
      and event_type = 'lesson.reminder' and channel = 'telegram' and deleted_at is null),
  1, 'Повторный upsert обновляет ту же строку — on conflict, а не 23505 из check-then-act (Р3)'
);


-- 6. Выключенная строка центра НЕ отдаёт сообщений (Р2) ----------------------------------------------

reset role;
select public.tests_claims(null, null);

select is(
  (select count(*)::int from public.event_messages((select id from t_ev where name = 'reminder'))),
  0,
  'is_active=false у победившей строки центра — получателей нет вовсе, не побег на дефолт (Р2)'
);


-- 7. Включили обратно — уходит СВОЙ текст -----------------------------------------------------------

select public.tests_claims('a0370000-0000-0000-0000-000000000001', 'c0370000-0000-0000-0000-00000000000a');
set local role authenticated;
select public.upsert_message_template('lesson.reminder', 'telegram', '[тест 037 v2]', true);

reset role;
select public.tests_claims(null, null);

select is(
  (select message from public.event_messages((select id from t_ev where name = 'reminder')) limit 1),
  '[тест 037 v2]',
  'Активная строка центра перекрывает дефолт — уходит её текст'
);


-- 8-9. Возврат к тексту платформы ---------------------------------------------------------------------

select public.tests_claims('a0370000-0000-0000-0000-000000000001', 'c0370000-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  public.reset_message_template('lesson.reminder', 'telegram'),
  true,
  'reset_message_template гасит свою строку — true означает «была и погашена» (Р3)'
);

select is(
  public.reset_message_template('lesson.reminder', 'telegram'),
  false,
  'Повторный сброс без своей строки — честный no-op (false), а не фальшивое «Готово»'
);

reset role;
select public.tests_claims(null, null);

select ok(
  (select message from public.event_messages((select id from t_ev where name = 'reminder')) limit 1) like '%планы%',
  'После сброса снова уходит текст платформы'
);


-- 10. Чужой центр не трогает шаблон соседа -------------------------------------------------------------

select public.tests_claims('a0370000-0000-0000-0000-000000000002', 'c0370000-0000-0000-0000-00000000000b');
set local role authenticated;
select public.upsert_message_template('lesson.reminder', 'telegram', '[центр Б]', true);
reset role;

select is(
  (select center_id from public.message_templates
    where event_type = 'lesson.reminder' and channel = 'telegram' and text = '[центр Б]'),
  'c0370000-0000-0000-0000-00000000000b'::uuid,
  'upsert берёт center_id из current_center(), а не из ввода — строка легла в центр Б, не в А'
);


-- 11-12. Роль проверяется в базе, не в React ------------------------------------------------------------

select public.tests_claims('a0370000-0000-0000-0000-000000000003', 'c0370000-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $$ select public.upsert_message_template('lesson.reminder', 'telegram', 'x', true) $$,
  '42501', null, 'teacher не может писать шаблоны уведомлений'
);
reset role;

select public.tests_claims('a0370000-0000-0000-0000-000000000004', 'c0370000-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $$ select public.upsert_message_template('lesson.reminder', 'telegram', 'x', true) $$,
  '42501', null, 'parent не может писать шаблоны уведомлений'
);
reset role;


-- 13. Белый список типов событий (Р4) --------------------------------------------------------------

select public.tests_claims('a0370000-0000-0000-0000-000000000001', 'c0370000-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $$ select public.upsert_message_template('lesson.typo', 'telegram', 'x', true) $$,
  '23503', null, 'event_type вне справочника — отказ FK, а не тихая невидимая строка'
);
reset role;


-- 14-17. Границы доступа -------------------------------------------------------------------------------

select ok(
  not has_table_privilege('authenticated', 'public.message_templates', 'INSERT')
  and not has_table_privilege('authenticated', 'public.message_templates', 'UPDATE')
  and has_table_privilege('authenticated', 'public.message_templates', 'SELECT'),
  'Прямой insert/update таблицы закрыт authenticated — запись только через RPC; чтение осталось'
);

select ok(
  has_function_privilege('authenticated', 'public.upsert_message_template(text,text,text,boolean)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.reset_message_template(text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.upsert_message_template(text,text,text,boolean)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.reset_message_template(text,text)', 'EXECUTE'),
  'RPC записи открыты authenticated и закрыты anon'
);

select ok(
  not has_function_privilege('authenticated', 'public.resolve_template(uuid,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.resolve_template(uuid,text,text)', 'EXECUTE'),
  'resolve_template — внутренняя дверь, наружу не выдана никому'
);

select ok(
  not has_table_privilege('authenticated', 'public.notification_event_types', 'SELECT')
  and not has_table_privilege('anon', 'public.notification_event_types', 'SELECT'),
  'Справочник типов событий не читается из приложения — это ограничение базы, не витрина'
);

select * from finish();

rollback;
