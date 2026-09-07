-- Локальные данные для разработки. Выполняется после миграций при supabase db reset.
-- Пароль тестового пользователя: password123
--
-- ВАЖНО: токен-колонки заполняются пустой строкой, а не остаются NULL.
-- GoTrue читает их в Go-строки и на NULL отвечает 500 «Database error querying
-- schema» — вход молча ломается. Это единственная неочевидная деталь ручной
-- вставки пользователя.

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
  '00000000-0000-0000-0000-0000000000a1',
  'authenticated', 'authenticated',
  'owner@logocrm.kg',
  extensions.crypt('password123', extensions.gen_salt('bf')),
  now(),
  '{"provider": "email", "providers": ["email"]}'::jsonb,
  '{"full_name": "Айгуль Осмонова"}'::jsonb,
  '', '', '', '', '', '', '', '',
  now(), now()
)
on conflict (id) do nothing;

insert into auth.identities (
  id, user_id, provider_id, identity_data, provider,
  last_sign_in_at, created_at, updated_at
)
values (
  gen_random_uuid(),
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000a1',
  '{"sub": "00000000-0000-0000-0000-0000000000a1", "email": "owner@logocrm.kg", "email_verified": true}'::jsonb,
  'email', now(), now(), now()
)
on conflict do nothing;

-- Центр намеренно не создаётся: первый вход должен пройти через /onboarding
-- и вызвать create_center — это проверяет весь путь целиком.
