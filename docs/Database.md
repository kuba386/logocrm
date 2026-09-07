# База данных

Postgres 15 (Supabase). Все изменения схемы — только через миграции в
`packages/db/supabase/migrations`. Ручных правок в Studio быть не должно:
`supabase db reset` их сотрёт.

## Конвенции для всех таблиц

Каждая новая таблица с данными центра обязана соответствовать шаблону:

| Колонка      | Тип           | Правило                                                     |
|--------------|---------------|-------------------------------------------------------------|
| `id`         | `uuid`        | `primary key default gen_random_uuid()` — никаких serial     |
| `center_id`  | `uuid`        | `not null default current_center() references centers(id)`   |
| `created_at` | `timestamptz` | `not null default now()`                                     |
| `updated_at` | `timestamptz` | `not null default now()` + триггер `moddatetime`             |
| `created_by` | `uuid`        | `default auth.uid()`                                         |
| `deleted_at` | `timestamptz` | soft delete; **`DELETE` не выполняется никогда**             |

Дополнительно:

- **Деньги — `integer` в тыйынах.** 1 сом = 100 тыйынов. Никаких `numeric`,
  `float` и «сомов с копейками». Конвертация — `toTiyin` / `toSom` из
  `@logocrm/core`. Причина: округление денег должно быть одинаковым в БД,
  на сервере и в браузере.
- **Статусы — lookup-таблицы, не `enum`.** Postgres-энам нельзя изменить в
  транзакции миграции без боли, а центры хотят свои статусы. Шаблон:
  `lesson_statuses(code text primary key, title text not null, sort int)`,
  ссылка `status_code text not null references lesson_statuses(code)`.
- **Расширяемые поля — `custom_fields jsonb not null default '{}'`.** Всё, что
  нужно одному центру и не нужно остальным, живёт там, а не в новой колонке.
- Названия таблиц — во множественном числе, snake_case: `students`, `lessons`,
  `lesson_attendances`.
- Индекс на `center_id` обязателен: он ведущий во всех запросах из-за RLS.

## Как добавить таблицу

```sql
-- packages/db/supabase/migrations/00NN_students.sql

create table public.students (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  full_name     text not null,
  birth_date    date,
  custom_fields jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  deleted_at    timestamptz
);

create index students_center_idx on public.students (center_id) where deleted_at is null;

create trigger students_set_updated_at
  before update on public.students
  for each row execute function extensions.moddatetime(updated_at);

call public.apply_tenant_rls('students');
call public.apply_audit('students');
```

`apply_tenant_rls` даёт доступ `owner`/`admin`. Роли `teacher` и `parent`
добавляются отдельными политиками:

```sql
create policy students_select_teacher on public.students
  for select to authenticated
  using (
    center_id = public.current_center()
    and public.my_role() = 'teacher'
    and deleted_at is null
    and exists (
      select 1 from public.lessons l
       where l.student_id = students.id
         and l.teacher_id = public.my_teacher_id()
    )
  );
```

## Служебные объекты

### `centers`

Тенант. `settings` jsonb хранит `city` и `features`. `plan` ∈
`trial | solo | studio | ai`. Записи не удаляются — `deleted_at`.

Прямой `INSERT` запрещён политиками: центр создаётся только через
`create_center(p_name, p_city)`.

### `memberships`

`(user_id, center_id)` — составной primary key, `role`, плюс `teacher_id` и
`payer_id` — ссылки на строки пользователя в таблицах центра (заполняются, когда
эти таблицы появятся).

### Функции

| Функция                        | Что делает                                              |
|--------------------------------|---------------------------------------------------------|
| `current_center()`             | `center_id` из JWT `app_metadata`                        |
| `my_role()`                    | роль в текущем центре                                    |
| `my_teacher_id()`              | `teacher_id` из membership                               |
| `my_payer_id()`                | `payer_id` из membership                                 |
| `role_in(uuid)`                | роль в произвольном центре (security definer)            |
| `is_member(uuid)`              | состоит ли пользователь в центре                         |
| `has_feature(text)`            | включена ли фича в `settings->'features'`                |
| `switch_center(uuid)`          | смена активного центра (нужен `refreshSession()` после)  |
| `create_center(text, text)`    | создать центр + membership owner + переключиться на него |
| `emit_event(text, jsonb)`      | записать событие в outbox                                |
| `slugify(text)`                | slug с транслитерацией кириллицы                         |

`role_in`, `is_member`, `my_*` объявлены `security definer` не ради привилегий,
а чтобы политики на `memberships` не уходили в рекурсию: политика читает
`memberships`, что снова запускает политику.

### `apply_tenant_rls(tbl)`

```sql
using       (center_id = current_center() and my_role() in ('owner','admin') and deleted_at is null)
with check  (center_id = current_center() and my_role() in ('owner','admin'))
```

`deleted_at is null` намеренно отсутствует в `WITH CHECK`: soft delete — это
`update ... set deleted_at = now()`, и при наличии условия в `WITH CHECK`
политика запретила бы собственный механизм удаления.

### `audit_log` + `apply_audit(tbl)`

After-триггер на insert/update/delete пишет `old_data`/`new_data` целиком плюс
`user_id` (`auth.uid()`). Читать может только `owner`/`admin` своего центра.

### `events` + `emit_event(...)`

Transactional outbox. `emit_event` — единственный способ записи; прямой INSERT
недоступен ролям приложения. Индекс `events_unprocessed_idx` частичный
(`where processed_at is null`), поэтому очередь читается дёшево независимо от
общего размера таблицы.

У `emit_event` есть третий параметр `p_center_id` — он нужен только вызовам
изнутри `security definer`-функций (например `create_center`), когда нового
`center_id` в JWT ещё нет. Из приложения вызывается с двумя аргументами.

## Как добавить миграцию

```bash
cd packages/db
supabase migration new add_students   # создаст 2026...._add_students.sql
# правим файл
supabase db reset                     # прогон всех миграций с нуля + seed
supabase test db                      # pgTAP
pnpm db:types                         # перегенерировать src/database.types.ts
```

Правило: миграции неизменяемы после мержа в `main`. Ошибку исправляет
следующая миграция, а не редактирование старой.

## Сотрудники и приглашения (0004)

### `teachers`

Карточка специалиста. Живёт **отдельно от аккаунта**: её заводят до того, как
человек зарегистрировался, и она переживает отзыв доступа. `profile_id`
связывает карточку с `auth.users` и заполняется в `accept_invitation`.

Кроме политики `tenant_admin` есть `teachers_read_self`: специалист видит
ровно одну строку — ту, на которую указывает `my_teacher_id()`.

### `invitations`

Приглашение по ссылке. Единственный секрет — `token` (48 hex-символов из
`gen_random_bytes(24)`). У таблицы **нет** `deleted_at`, поэтому RLS ставится
как `call apply_tenant_rls('invitations', false)`.

Отмена приглашения — это `expires_at = now()`, а не `DELETE`: строка остаётся
в аудите, а из `pending_invitations_view` пропадает.

### Функции

| Функция | Кто может | Что делает |
|---|---|---|
| `invitation_preview(token)` | **anon** | название центра, роль, признак валидности — и ничего больше |
| `accept_invitation(token)` | authenticated | membership + активация карточки + событие + `switch_center` |
| `create_invitation(...)` | owner/admin | карточка и приглашение одной транзакцией |
| `revoke_membership(user)` | owner/admin | снимает доступ, гасит карточку |
| `change_member_role(user, role)` | owner/admin | смена роли |
| `user_email(user)` | authenticated | email участника своего центра — для витрин |

`invitation_preview` — единственная функция проекта, доступная анониму. По
неизвестному токену она возвращает NULL-ы, чтобы перебором нельзя было узнать
названия центров.

Администратор ограничен жёстче владельца: не может приглашать администраторов,
назначать роли кроме `teacher` и трогать владельцев. Иначе он повышает себя до
владельца через подставного пользователя.

### Витрины

`staff_view` и `pending_invitations_view` объявлены с
`security_invoker = true`. Без этого вью выполнялась бы от владельца и обходила
RLS нижележащих таблиц — то есть стала бы дырой в изоляции тенантов.

`auth.users` роли `authenticated` целиком не выдаётся (там хеши паролей всех
пользователей сервиса), поэтому email приходит через `user_email()` со своей
проверкой прав.

## Права на функции — отдельная от RLS история

RLS не распространяется на функции. Любая функция в схеме `public`
автоматически:

- получает `EXECUTE` от роли `PUBLIC` (правило Postgres);
- получает `EXECUTE` от ролей `anon` и `authenticated` (default privileges
  Supabase);
- публикуется как эндпоинт `/rest/v1/rpc/<имя>`.

Поэтому каждая новая функция обязана заканчиваться явными правами:

```sql
revoke execute on function public.my_new_rpc(uuid) from public, anon;
grant  execute on function public.my_new_rpc(uuid) to authenticated;
```

А каждая `security definer`-функция — начинаться с проверок:

```sql
if auth.uid() is null then
  raise exception 'Требуется авторизация' using errcode = '42501';
end if;

if public.role_in(p_center_id) is null then
  raise exception 'Нет доступа к центру %', p_center_id using errcode = '42501';
end if;
```

Без второй проверки функция становится обходом RLS: она пишет от имени
владельца и не спрашивает, чей это центр. Подробности — [ADR-002](Decisions/ADR-002-tenant-rls.md).

## Тесты

`packages/db/supabase/tests/*.test.sql` — pgTAP. Каждая новая таблица с RLS
обязана получить тест «пользователь чужого центра не видит строку» — это
единственное, что защищает персональные данные детей.

Подмена пользователя в тесте:

```sql
select set_config('request.jwt.claims',
  '{"sub":"...","role":"authenticated","app_metadata":{"center_id":"..."}}', true);
set local role authenticated;
-- запросы
reset role;
```
