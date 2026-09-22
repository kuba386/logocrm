-- pgTAP: изоляция тенантов, роли и outbox.
-- Запуск: pnpm db:test   (supabase test db)

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(13);

-- Фикстуры (от суперпользователя, RLS не применяется) -------------------------

insert into auth.users (instance_id, id, aud, role, email)
values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated', 'owner-a@test.kg'),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated', 'owner-b@test.kg'),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated', 'teacher-a@test.kg'),
  ('00000000-0000-0000-0000-000000000000', '44444444-4444-4444-4444-444444444444', 'authenticated', 'authenticated', 'nobody@test.kg');

insert into public.centers (id, name, slug, settings)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Центр А', 'centr-a', '{"city": "Бишкек", "features": {"ai_reports": true}}'::jsonb),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Центр Б', 'centr-b', '{"city": "Ош", "features": []}'::jsonb);

insert into public.memberships (user_id, center_id, role)
values
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'owner'),
  ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'owner'),
  ('33333333-3333-3333-3333-333333333333', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'teacher');

-- Подмена JWT: sub + app_metadata.center_id, как их отдаёт GoTrue.
-- Смену роли делаем отдельным SET LOCAL ROLE на верхнем уровне скрипта.
create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', p_user,
      'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end
    )::text,
    true
  );
end;
$$;


-- 1. Пользователь без membership не видит ни одного центра --------------------

select public.tests_claims('44444444-4444-4444-4444-444444444444', null);
set local role authenticated;

select is(
  (select count(*) from public.centers)::int,
  0,
  'Пользователь без membership не видит ни одного центра'
);

reset role;


-- 2. Owner центра А не видит центр Б -----------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
set local role authenticated;

select results_eq(
  'select name from public.centers order by name',
  array['Центр А'],
  'Owner центра А видит только свой центр'
);

select is(public.my_role(), 'owner', 'my_role() возвращает роль в текущем центре');
select ok(public.has_feature('ai_reports'), 'has_feature() истинна для включённой фичи');
select ok(not public.has_feature('whatsapp'), 'has_feature() ложна для выключенной фичи');

reset role;


-- 3. Teacher не может изменить центр -----------------------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
set local role authenticated;

update public.centers set name = 'Взлом' where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

reset role;

select is(
  (select name from public.centers where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  'Центр А',
  'Teacher не может выполнить update на centers'
);


-- 4. emit_event пишет строку в outbox ----------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
set local role authenticated;

select ok(
  public.emit_event('center.created', '{"hello": "мир"}'::jsonb) > 0,
  'emit_event возвращает id новой строки'
);

reset role;

select results_eq(
  $q$ select type, center_id, processed_at is null
        from public.events
       where payload ->> 'hello' = 'мир' $q$,
  $q$ values ('center.created'::text, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, true) $q$,
  'emit_event пишет строку с center_id из JWT и processed_at is null'
);


-- 5. Аудит пишется автоматически ---------------------------------------------

-- С 0049 тариф меняет только администратор платформы: владелец A становится
-- им на время этого блока (email подтверждён, адрес в platform_admins).
update auth.users set email_confirmed_at = now() where id = '11111111-1111-1111-1111-111111111111';
insert into public.platform_admins (email)
select lower(email) from auth.users where id = '11111111-1111-1111-1111-111111111111';

update public.centers set plan = 'solo' where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

select is(
  (select count(*)::int from public.audit_log
    where table_name = 'centers'
      and row_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
      and action = 'UPDATE'),
  1,
  'apply_audit пишет строку UPDATE в audit_log'
);


-- 6. Аноним не может ничего ---------------------------------------------------
-- Регрессия на 0002/0003: Supabase выдаёт EXECUTE ролям anon и PUBLIC на каждую
-- функцию в public. Пока эти гранты не сняты, security definer-функции доступны
-- без авторизации, и emit_event позволяет писать в outbox любого центра.

select public.tests_claims(null, null);
set local role anon;

select throws_ok(
  $q$ select public.emit_event('center.created', '{}'::jsonb, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $q$,
  '42501',
  null,
  'Аноним не может вызвать emit_event'
);

select throws_ok(
  $q$ select public.create_center('Взлом', 'Бишкек') $q$,
  '42501',
  null,
  'Аноним не может вызвать create_center'
);

-- До 0024 anon имел SELECT по default privileges и получал 0 строк от RLS;
-- теперь гранта нет вовсе — отказ раньше политики.
select throws_ok(
  $q$ select count(*) from public.centers $q$,
  '42501',
  null,
  'Аноним не читает centers вовсе — ни гранта, ни строк'
);

reset role;


-- 7. Межтенантная запись в outbox закрыта -------------------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
set local role authenticated;

select throws_ok(
  $q$ select public.emit_event('center.created', '{}'::jsonb, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') $q$,
  '42501',
  null,
  'Owner центра А не может писать события в центр Б'
);

reset role;

select * from finish();

rollback;
