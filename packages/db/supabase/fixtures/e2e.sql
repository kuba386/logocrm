-- Фикстура для Playwright. Применяется поверх миграций на эфемерной базе:
--   supabase db reset && psql "$DATABASE_URL" -f supabase/fixtures/e2e.sql
--
-- Отличается от seed.sql намеренно. seed оставляет центр несозданным, чтобы
-- первый вход проходил через /onboarding — это проверка своего сценария.
-- Здесь наоборот: всё готово, чтобы каждый тест начинался с состояния, в
-- котором центр уже работает, и не тратил шаги на подготовку.
--
-- Пароль у всех один и лежит в открытом виде и здесь, и в тестах. Это
-- допустимо: база эфемерная, живёт минуты внутри прогона CI.
--
-- Идентификаторы фиксированные — тесты ссылаются на них по имени, а не
-- ищут по порядку в списке.

-- Пользователи ----------------------------------------------------------------

-- Токен-колонки заполняются пустой строкой, а не NULL: GoTrue читает их в
-- Go-строки и на NULL отвечает 500 «Database error querying schema».
do $$
declare
  v record;
begin
  for v in
    select * from (values
      ('e0000000-0000-0000-0000-0000000000a1'::uuid, 'owner-e2e@logocrm.kg',   'Владелец Тестов'),
      ('e0000000-0000-0000-0000-0000000000a2'::uuid, 'admin-e2e@logocrm.kg',   'Администратор Тестов'),
      ('e0000000-0000-0000-0000-0000000000a3'::uuid, 'teacher-e2e@logocrm.kg', 'Нургуль Абдырахманова'),
      ('e0000000-0000-0000-0000-0000000000a4'::uuid, 'parent-e2e@logocrm.kg',  'Гульмира Иванова')
    ) as t(id, email, full_name)
  loop
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      confirmation_token, recovery_token, email_change,
      email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token,
      created_at, updated_at
    )
    values (
      '00000000-0000-0000-0000-000000000000',
      v.id, 'authenticated', 'authenticated', v.email,
      extensions.crypt('e2e-password-123', extensions.gen_salt('bf')),
      now(),
      '{"provider": "email", "providers": ["email"]}'::jsonb,
      jsonb_build_object('full_name', v.full_name),
      '', '', '', '', '', '', '', '',
      now(), now()
    )
    on conflict (id) do nothing;

    insert into auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    )
    values (
      gen_random_uuid(), v.id, v.id::text,
      jsonb_build_object('sub', v.id::text, 'email', v.email, 'email_verified', true),
      'email', now(), now(), now()
    )
    on conflict do nothing;
  end loop;
end $$;


-- Центр -----------------------------------------------------------------------

insert into public.centers (id, name, slug, settings)
values (
  'e0000000-0000-0000-0000-0000000000c1',
  'Центр e2e',
  'centr-e2e',
  '{"timezone": "Asia/Bishkek", "features": {"ai_reports": true}}'::jsonb
)
on conflict (id) do nothing;


-- Справочники -----------------------------------------------------------------

insert into public.services (id, center_id, name, duration_min, default_price_tiyin, kind, is_active)
values
  ('e0000000-0000-0000-0000-0000000000f1', 'e0000000-0000-0000-0000-0000000000c1',
   'Индивидуальное занятие', 45, 80000, 'individual', true),
  ('e0000000-0000-0000-0000-0000000000f2', 'e0000000-0000-0000-0000-0000000000c1',
   'Групповое занятие', 60, 50000, 'group', true)
on conflict (id) do nothing;

insert into public.rooms (id, center_id, name, capacity, is_active)
values ('e0000000-0000-0000-0000-0000000000c9', 'e0000000-0000-0000-0000-0000000000c1',
        'Кабинет 1', 6, true)
on conflict (id) do nothing;


-- Специалисты -----------------------------------------------------------------

-- Обе карточки активны. В приложении карточка активируется только приёмом
-- приглашения, но тесту незачем воспроизводить весь путь регистрации: ему
-- нужны два специалиста, между которыми можно сделать замену.
insert into public.teachers (id, center_id, full_name, is_active, profile_id)
values
  ('e0000000-0000-0000-0000-0000000000b1', 'e0000000-0000-0000-0000-0000000000c1',
   'Нургуль Абдырахманова', true, 'e0000000-0000-0000-0000-0000000000a3'),
  ('e0000000-0000-0000-0000-0000000000b2', 'e0000000-0000-0000-0000-0000000000c1',
   'Айгуль Кадырова', true, null)
on conflict (id) do nothing;


-- Плательщик и дети -----------------------------------------------------------

insert into public.payers (id, center_id, full_name, phone)
values ('e0000000-0000-0000-0000-0000000000d1', 'e0000000-0000-0000-0000-0000000000c1',
        'Гульмира Иванова', '+996700000001')
on conflict (id) do nothing;

-- Двое детей у одного плательщика: так проверяется, что родитель видит обоих
-- своих и не видит чужого.
insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id, birth_date)
values
  ('e0000000-0000-0000-0000-0000000000e1', 'e0000000-0000-0000-0000-0000000000c1',
   'Айлин Иванова', 'e0000000-0000-0000-0000-0000000000d1',
   'e0000000-0000-0000-0000-0000000000b1', '2019-04-11'),
  ('e0000000-0000-0000-0000-0000000000e2', 'e0000000-0000-0000-0000-0000000000c1',
   'Данияр Иванов', 'e0000000-0000-0000-0000-0000000000d1',
   'e0000000-0000-0000-0000-0000000000b1', '2018-02-03')
on conflict (id) do nothing;

-- Чужой ребёнок другого плательщика: контрольная группа для проверки границ.
insert into public.payers (id, center_id, full_name, phone)
values ('e0000000-0000-0000-0000-0000000000d2', 'e0000000-0000-0000-0000-0000000000c1',
        'Другой Плательщик', '+996700000002')
on conflict (id) do nothing;

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id)
values ('e0000000-0000-0000-0000-0000000000e3', 'e0000000-0000-0000-0000-0000000000c1',
        'Чужой Ребёнок', 'e0000000-0000-0000-0000-0000000000d2',
        'e0000000-0000-0000-0000-0000000000b2')
on conflict (id) do nothing;


-- Членства --------------------------------------------------------------------

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id)
values
  ('e0000000-0000-0000-0000-0000000000a1', 'e0000000-0000-0000-0000-0000000000c1', 'owner',   null, null),
  ('e0000000-0000-0000-0000-0000000000a2', 'e0000000-0000-0000-0000-0000000000c1', 'admin',   null, null),
  ('e0000000-0000-0000-0000-0000000000a3', 'e0000000-0000-0000-0000-0000000000c1', 'teacher',
   'e0000000-0000-0000-0000-0000000000b1', null),
  ('e0000000-0000-0000-0000-0000000000a4', 'e0000000-0000-0000-0000-0000000000c1', 'parent',
   null, 'e0000000-0000-0000-0000-0000000000d1')
on conflict (user_id, center_id) do nothing;


-- JWT несёт center_id в app_metadata: без него current_center() пуст и RLS
-- не отдаст ничего. В приложении это делает switch_center при входе.
update auth.users u
   set raw_app_meta_data = u.raw_app_meta_data
     || jsonb_build_object('center_id', 'e0000000-0000-0000-0000-0000000000c1')
 where u.id in (
   'e0000000-0000-0000-0000-0000000000a1',
   'e0000000-0000-0000-0000-0000000000a2',
   'e0000000-0000-0000-0000-0000000000a3',
   'e0000000-0000-0000-0000-0000000000a4'
 );
