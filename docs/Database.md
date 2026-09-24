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
- **`center_id` nullable — только когда строка бывает платформенной**
  (пример: `message_templates`, где `center_id is null` значит «текст по
  умолчанию для всех центров»). Такая таблица не проходит целиком под
  `apply_tenant_rls`, а `default current_center()` из шаблона выше ей не
  положен, потому что явный `null` в insert должен доходить до колонки, а не
  подменяться дефолтом. Следствие: запись из приложения — **только через
  RPC** (`security definer`, `center_id := current_center()` внутри
  функции), никогда не прямой `insert`/`update` формы. 0034 сделал таблицу
  nullable, но не завёл RPC — первое же сохранение через форму падало RLS
  (`center_id` уходил `NULL`, не подставлялся ничем); нашлось на живой
  приёмке этапа 6, починено 0037.

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

**Номер берётся по факту каталога в момент начала работы**, а не из промта
этапа в `docs/Roadmap/stages.md`: промты писались заранее и успели устареть.
Номер — первичный ключ в `supabase_migrations.schema_migrations`, поэтому два
файла с одним префиксом дают `duplicate key value violates unique constraint
"schema_migrations_pkey"` и роняют `db reset`, а за ним Playwright и деплой.

Git об этом молчит: имена файлов разные (`0021_revenue_views.sql` и
`0021_center_scoped_fks.sql`), конфликта при мерже нет, PR выглядит
mergeable. Поэтому есть проверка `pnpm --filter @logocrm/db check:versions` —
она же первым шагом джоба `db` в CI, до подъёма Supabase.

Проверка ловит ветку, отставшую от занятого номера (на `pull_request` CI
видит merge-коммит с `main`). Чего она не ловит: два PR, влитых почти
одновременно, — у каждого на момент прогона номер был свободен. Так уже
падал `main` 11.09.2026. От этого защищает только настройка ветки в GitHub
**Require branches to be up to date before merging**, и это тумблер
владельца, а не код.

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
| `create_invitation(..., p_payer_id)` | owner/admin | карточка и приглашение одной транзакцией; родитель — только к живой карточке плательщика или к новой по ФИО + телефону (0060), возвращает `payer_id`/`payer_created` |
| `revoke_membership(user)` | owner/admin | снимает доступ, гасит карточку |
| `change_member_role(user, role)` | owner/admin | смена роли; в `parent` — нельзя (0060), из `parent` — снимает `payer_id` |
| `link_parent_payer(user, payer)` | owner/admin | привязать / перепривязать / отвязать (`null`) родителя к карточке плательщика; событие `membership.payer_linked` (0060) |
| `user_email(user)` | authenticated | email участника своего центра — для витрин |

Родитель без карточки (0060). До 0060 `create_invitation` вообще не
заполняла `invitations.payer_id` — каждый приглашённый родитель приходил в
центр «ничьим» и видел пустой кабинет, а чинилось это запросом в базу.
Теперь инвариант держит CHECK `invitations_parent_payer_check`
(`role <> 'parent' or payer_id is not null`, объявлен `NOT VALID`:
исторические строки нарушают его и править их нельзя, но новые insert/update
проверяются в полную силу — `NOT VALID` отключает только разовое
сканирование истории). Прямого `insert` в `invitations` у `authenticated`
нет с 0024; констрейнт держит `service_role`, миграции и любой будущий
грант. Висящие parent-приглашения без карточки миграция протушила —
владелец перевыпускает ссылку уже с плательщиком. Новая карточка из
приглашения — тот же нормализованный номер и то же событие `payer.created`,
что у `create_student_with_payer`; телефон, который уже есть у живой
карточки, — отказ `22023` «выберите из списка» (не `23505`: общий разбор
ошибок для `23505` ищет имя констрейнта в тексте, у собственного `raise` его
нет), гонка на `payers_center_phone_uniq` ловится `exception
when unique_violation` с тем же текстом.

`invitation_preview` — единственная функция проекта, доступная анониму. По
неизвестному токену она возвращает NULL-ы, чтобы перебором нельзя было узнать
названия центров.

Администратор ограничен жёстче владельца: не может приглашать администраторов,
назначать роли кроме `teacher` и трогать владельцев. Иначе он повышает себя до
владельца через подставного пользователя.

### Витрины

`staff_view` и `pending_invitations_view` объявлены с
`security_invoker = true`. Без этого вью выполнялась бы от владельца и обходила
RLS нижележащих таблиц — то есть стала бы дырой в изоляции тенантов. С 0060 у
обеих есть `payer_id`/`payer_name` (карточка родителя); `full_name` остаётся
«ФИО специалиста». Пересоздание через `drop view` теряет `revoke` из 0024 —
после каждого `create view` блок `revoke all … from public, anon,
authenticated` + `grant select … to authenticated` обязателен: на витрине
лежит `invitations.token`.

`auth.users` роли `authenticated` целиком не выдаётся (там хеши паролей всех
пользователей сервиса), поэтому email приходит через `user_email()` со своей
проверкой прав.

## Ученики и плательщики (0005)

### `payers`

Плательщик — родитель или опекун. **Отдельная сущность, а не поля на ребёнке**:
один родитель платит за нескольких детей, и деньги, долги и рассылки живут на
нём. Слить дубли задним числом почти невозможно, поэтому на телефон стоит
уникальный индекс по нормализованному номеру:

```sql
create unique index payers_center_phone_uniq
  on public.payers (center_id, public.normalize_kg_phone(phone))
  where deleted_at is null;
```

`+996 700 12-34-56`, `0700123456` и `700123456` — один и тот же номер, и второго
плательщика с ним завести нельзя. В разных центрах — можно.

### `students`

Ребёнок. Контактов здесь нет намеренно — см. [ADR-005](Decisions/ADR-005-column-privacy.md).
`payer_id` обязателен: ребёнок без плательщика в системе бессмыслен.
`on delete restrict` не даёт удалить плательщика, за которым числятся дети.

Политики сверх `tenant_admin`:

- `students_teacher_read_own` — специалист видит детей, где он `primary_teacher_id`;
- `students_parent_read_own` — родитель видит детей своего `payer_id`.

### Витрины

| Витрина | Для кого | Что даёт |
|---|---|---|
| `students_teacher_view` | специалист, родитель | ученик без контактов; колонок phone/email/payer_id нет физически |
| `payers_with_stats` | владелец, администратор | плательщик + число детей |

### Функции

| Функция | Что делает |
|---|---|
| `normalize_kg_phone(text)` | `0700123456` → `+996700123456`, мусор → NULL |
| `age_years(date)` | полных лет |
| `payer_display_name(uuid)` | имя плательщика тем, кому таблица закрыта |
| `find_payer_by_phone(text)` | «эта мама уже есть, у неё двое детей» |
| `create_student_with_payer(...)` | ребёнок и плательщик одной транзакцией |
| `archive_student` / `restore_student` | смена статуса + событие |
| `was_access_revoked()` | был ли у текущего пользователя отозван доступ |

`normalize_kg_phone` продублирована в TypeScript (`@logocrm/core/phone`), потому
что нужна и в браузере. Наборы примеров в обоих тестах совпадают намеренно:
разойдутся реализации — появятся дубли плательщиков.

## Расписание (0006)

### Занятость проверяет база

| Констрейнт | Что не даёт сделать |
|---|---|
| `lessons_teacher_no_overlap` | поставить специалиста на два занятия сразу — по `effective_teacher_id`, поэтому ловит и замену |
| `lessons_room_no_overlap` | занять кабинет дважды |
| `lesson_participants_no_overlap` | посадить ребёнка на два занятия, включая пару «группа + индивидуальное» |

Все три — частичные: `where (deleted_at is null and status <> 'cancelled')`,
поэтому отменённое занятие освобождает слот.

Касание границ пересечением не считается: `tstzrange` с `&&` разрешает
занятие 10:45–11:30 сразу после 10:00–10:45.

### `lesson_participants`

Служебная таблица: кто на занятии. Заполняется **только триггерами**, политик
на запись нет ни у кого, грант — `select` по видимости самого занятия.
Зачем она нужна и почему нельзя проверять в функции — [ADR-006](Decisions/ADR-006-lesson-participants.md).

### Функции

| Функция | Кто может | Что делает |
|---|---|---|
| `create_lesson_series(p jsonb)` | owner/admin | серия целиком или ничего; при конфликте — список дат в `detail` |
| `create_lesson_series_preview(p)` | owner/admin | что занято, для диалога |
| `series_dates(p)` | authenticated | только календарь, без занятости |
| `cancel_lesson`, `cancel_series_from` | owner/admin | отмена одного или хвоста серии |
| `substitute_teacher` | owner/admin | замена; занятость нового ловит EXCLUDE |
| `reschedule_lesson` | owner/admin | перенос; ошибка тем же форматом |
| `teacher_vacation` / `_preview` | owner/admin | отмена за период, включая замены |
| `mark_lesson_status` | teacher своих, admin любых | специалисту только `planned → done` и `planned → cancelled` |

Специалисту **не выдана** политика на `update lessons`: статус меняется только
через `mark_lesson_status`, где проверяются и право, и допустимость перехода.

### Часовой пояс

Время серии считается в поясе центра (`centers.settings->>'timezone'`,
по умолчанию `Asia/Bishkek`), а не в `TimeZone` сервера. Та же логика
продублирована в `@logocrm/core/schedule` — правила синхронизации в ADR-006.

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

## Абонементы и посещения (0008–0010)

### Таблицы

| Таблица | Что хранит | Записывают |
|---|---|---|
| `attendance_statuses` | статусы посещения центра: списывает / пропуск / уведомлять | owner, admin |
| `subscription_types` | прайс: занятия, период, безлимит | owner, admin |
| `subscriptions` | проданный абонемент; `lessons_used` **пересчитывается**, не инкрементируется | только `sell_subscription` / `transfer_remaining`; update — `notes`, `allow_negative`, `deleted_at` |
| `subscription_freezes` | заморозки как `daterange` с `EXCLUDE` | только `freeze_subscription` / `unfreeze_subscription` |
| `attendance` | отметка; `deducted`, `counts_absence`, `price_tiyin`, `subscription_id` заморожены триггером | insert — owner/admin/`mark_attendance`; update — только `status_id`, `comment` |

Все таблицы связаны составными FK `(id, center_id)`: обычный FK по `id`
пропускает ссылку в чужой центр — RLS режет чтение, а не ссылку.

### Инварианты, которые держит база

- **Остаток — производная величина.** `recalc_subscription_usage` считает
  `lessons_used` из строк `attendance` под `for update`. Инкремент в функции
  обходили прямой insert, смена статуса задним числом и отмена занятия.
- **Переполнение** — `CHECK subscriptions_not_overdrawn`, снимается только
  `allow_negative`. **Согласование цены** — `CHECK subscriptions_lesson_price_consistent`:
  `lesson_price_tiyin = price_tiyin / lessons_total`.
- **Абонемент выбирается по дате занятия**, не по «сегодня», и привязывается к
  отметке один раз — при первом списании. Круг «пришёл → болел → пришёл»
  остаётся на том же абонементе.
- **Заморозка** — только через RPC: `EXCLUDE` держит пересечение, но «уже
  заморожен» и сдвиг `ends_at` живут в функции. Открытый конец — неограниченная
  граница (`daterange(from, null)`), не дата `'infinity'`: для неё `upper_inf()`
  ложен, и разморозка не находила открытую заморозку (0008 → 0010).
- **Архив абонемента с остатком запрещён** триггером — сначала возврат или перенос.

### Функции

| Функция | Кому | Что делает |
|---|---|---|
| `sell_subscription` / `freeze_subscription` / `unfreeze_subscription` / `transfer_remaining` | owner, admin | все пути записи в абонементы |
| `refund_subscription(p_id, p_expected_tiyin, p_source_id)` | owner, admin, registrar (`can_front_desk`, 0026) | отмена с возвратом — платёжной строкой на `least(refund_calc, paid_tiyin)`, источник обязателен только если реально возвращаются деньги; повторный возврат держит `payments_refund_once_key` (0030) |
| `mark_attendance` / `mark_attendance_bulk` | owner, admin, teacher (своё занятие) | единственный прикладной путь отметки; статус занятия не трогает |
| `subscription_summary(uuid)` | owner, admin | остаток, состояние, дни заморозки, сумма возврата; чужой — исключение |
| `student_subscription_badge(uuid)` | все роли своего центра | «нет / заканчивается / есть», без сумм |
| `subscription_lessons_left` / `subscription_state` | внутренние | `security invoker`: чужой абонемент даёт **NULL**, а NULL у остатка значит и «безлимит». Из приложения не вызывать — только `subscription_summary` |
| `subscription_freeze_days` / `refund_calc` | внутренние | `security definer` + explicit-гейт `subscription_visible_to_caller` (не голый invoker+RLS: расчёту нужны `subscription_types`/`subscription_freezes`, закрытые напрямую для родителя/registrar/finance, 0054) — невидимый/чужой абонемент так же даёт **NULL**. Из приложения не вызывать — только `subscription_summary` |

`student_balance` — `security_invoker`, но строки берёт из `students_brief()`
(definer: owner/admin/registrar/finance — весь центр, parent — свои дети,
специалисту пуста), а `debt_tiyin` — из `student_debts()` (definer, явный
центр в теле, `left join` один раз на запрос). Так бухгалтер видит баланс без
доступа к `students` и `attendance` (0031); `student_balance_pick` остаётся
invoker.

### События

`subscription.created/frozen/unfrozen/refunded/transferred`, `attendance.marked`,
`attendance.no_subscription`, `subscription.low_balance` (ровно на остатке 2),
`subscription.exhausted` (на нуле), `subscription.overdrawn` (первый уход в
минус при `allow_negative`), `student.absent_streak` (два пропуска подряд по
времени занятий). Все с дедупликацией по данным в `events`, не по памяти:
остаток пересчитываемый, и без неё правка статуса слала бы событие второй раз.

### Проверка роли в definer-функциях

```sql
if coalesce(public.my_role(), '') not in ('owner', 'admin') then
  raise exception 'Недостаточно прав' using errcode = '42501';
end if;
```

`coalesce` обязателен. `NULL not in (...)` — это `NULL`, и `if` молча не
срабатывает: пользователь с живым JWT и уже отозванным членством проходил любую
такую проверку (0010 закрыла это в шести RPC этапа 4 и четырёх читающих
функциях этапов 0–3; остальные RPC этапов 0–3 держит второй рубеж в
`emit_event`, их черёд — 0011). В RLS-политиках `my_role() in (...)` при NULL
безопасно: строка просто не видна.

## Финансы (0013–0021)

### Два слова, два определения

Одно и то же слово в двух витринах с разными определениями — и отчёты
разъезжаются молча. Поэтому определения здесь, а не в шапках миграций.

| Понятие | Что считается | Где |
|---|---|---|
| **Выручка** (начисление) | `attendance.price_tiyin` по отметкам `deducted = true` занятий в статусе `done`; месяц — по `lessons.starts_at` в поясе центра | `revenue_by_month` / `revenue_by_teacher` / `revenue_by_service` (0021) |
| **Зарплата** | те же отметки: `done` и `pays_teacher`, атрибуция по `attendance.paid_teacher_id` | `calc_salary` (0017) |
| **Касса** | `payments` **и** `expenses` по `paid_at` в поясе центра; расход входит с инвертированным знаком | `cash_by_source` (0021) |
| **Долг** по занятиям | отметки `deducted` без абонемента | `student_balance.debt_tiyin` (0015) |
| **Долг** по оплате абонемента | `price_tiyin − paid_tiyin`, рассрочка | `subscription_payment_summary`, `installments_view` (0018–0020) |

Выручка и зарплата — **разные множества**: выручка идёт по `deducted`
(списано с ребёнка), зарплата — по `pays_teacher` (обязательство перед
специалистом). Это две галочки статуса посещения, администратор правит их
независимо («Прогул»: списывает, но не оплачивается). «Маржа = выручка −
зарплата» — не разность по одному множеству; тест 0021 фиксирует
расхождение как ожидаемое. `planned` (отметили, но не нажали «Проведено») и
`cancelled` (отменили после отметок) не входят ни туда, ни туда.

### Правила витрин

- `security_invoker = true`, `revoke all … from anon, authenticated`,
  `grant select … to authenticated`. Только select: автообновляемая вью с
  грантом на запись — путь мимо `record_payment`.
- Ролевой фильтр в теле (`my_role() in ('owner','admin')` и свой центр): у
  `attendance` есть политика специалиста, у `payments` — родителя, а
  агрегаты центра — не для них. Договорённость держит тест 0021: он
  перебирает **все** вью `public` из каталога — `security_invoker` у
  каждой, а у всех вне белого списка (четыре вью 0004/0005 без `revoke`)
  ещё и «`anon` не читает, `authenticated` не пишет»; новая вью без
  решения в белом списке роняет CI. Пустоту под teacher/parent тест
  проверяет по маскам `revenue_%`/`cash_%`.
- Пояс — центра, один раз на запрос (CTE), не на строку. Месяц витрины
  совпадает с месяцем замка `financial_period_guard` по построению.
- Join только к `lessons`; к `teachers`/`services`/`payers` — нет: под
  `security_invoker` их RLS (`deleted_at is null`) молча уносит строки
  архивного специалиста. Имена резолвит интерфейс. С 0031 сам join живёт в
  `revenue_facts()` (definer, `can_finance`, явный центр): бухгалтер без
  политики на `lessons`/`attendance` видит ту же выручку, что владелец, а
  teacher/parent — по-прежнему ноль строк, не ошибку. Цена — definer
  set-returning не инлайнится, фильтр по месяцу до `attendance` не доходит;
  на объёмах центра принято сознательно (шапка 0031, Р6).
- Ноль в `price_tiyin` — два случая, две колонки: `unlimited_visits`
  (безлимит) и `unpriced_visits` (без абонемента, у услуги нет цены —
  деньги не начислены). Безлимиты в выручку не входят ни одной суммой —
  смотреть кассу. `visits` (на ребёнка) ≠ `lessons` (на занятие).
- Агрегаты — `bigint` с `coalesce(…, 0)`; неизвестный `payments.kind` — в
  `other_tiyin`, чтобы был громким, а не терялся из именованных колонок.
- Месяц без строки — не ноль: отсутствие строки трактует клиент, в одном
  месте.

### Бухгалтер и свободный текст (0031)

Роль `finance` не читает `students`, `payers`, `lessons`, `attendance`
целиком — там свободный текст о семье и занятии (`notes`, `custom_fields`,
`cancel_reason`, `comment`). Колоночных прав по роли нет (ADR-005), поэтому
то, что бухгалтеру нужно, отдают definer-функции без этих колонок; полный
список политик `tenant_registrar_*`/`tenant_finance_*` держит `tests/0031`.

| Функция | Кому | Что |
|---|---|---|
| `students_brief()` | owner, admin, registrar, finance — центр; parent — свои дети; остальным пусто | ученики без `notes`/`custom_fields`/`source`/`gender`; источник строк `student_balance` и экранов бухгалтера. Зеркало RLS `students` для этих ролей: меняешь политику — меняешь здесь |
| `payers_brief()` | owner, admin, registrar, finance; остальным пусто | плательщики с контактами, без `notes`/`custom_fields` |
| `student_debts()` | те же и parent — свои дети; остальным пусто | долг по отметкам без абонемента, строка на ребёнка; `left join` в `student_balance`. Намеренно не скаляр по uuid: у скалярной формы проверка прав строилась на `not (…)`, а у родителя без `membership.payer_id` сравнение давало NULL — и функция отдавала долг любого ребёнка (найдено ревью написанного кода) |
| `revenue_facts()` | owner, admin, finance; остальным пусто | списанные отметки проведённых занятий — источник `revenue_by_*` |
| `month_open_lessons_count(date)` | owner, admin, finance; иначе `42501` | тот же запрос, что в `close_month`: planned, без состава или с неотмеченным участником. `close_month` вызывает её — одна копия условия |

Отказ у источников строк — пусто, и без прав, и без `auth.uid()`: их читают
вью, а вью обязана вести себя как раньше — ноль строк, не исключение (так же
устроен `cash_by_source`, чей ролевой фильтр остался предикатом в теле).
`42501` — только у скалярного `month_open_lessons_count`: там «0» значит
«можно закрывать», и молчать нельзя.

Обе функции, читающие `attendance` по центру (`revenue_facts`,
`student_debts`), не инлайнятся планировщиком — под них заведён частичный
индекс `attendance (center_id) where deducted`.

### Инварианты `payments` (0013, 0030)

- **Знак — часть суммы**, не отдельный флаг: `payments_sign_matches_kind`
  (`kind = 'payment'` → `amount_tiyin > 0`; `'refund'` → `< 0`;
  `'correction'` — любой). `sum(amount_tiyin)` в любой витрине без `filter`
  по `kind` уже даёт правильную кассу.
- **Переплата** — инвариант только для `kind = 'payment'` с
  `subscription_id`: триггер `payments_recalc_paid_overpay_guard`
  (`payments_no_overpay()`), **AFTER**, по алфавиту после
  `payments_recalc_paid` — значит видит уже пересчитанный `paid_tiyin`, не
  считает прогноз сам. `kind = 'correction'` инвариант сознательно не
  проверяет: единственный путь провести переплату намеренно
  (`docs/Roadmap/stages.md:352-356`). Без списка колонок в `update of` —
  `kind` тоже должен попадать под проверку, отдельный список однажды уже
  давал обойти инвариант правкой не той колонки.
- **Повторный возврат** — частичный unique `payments_refund_once_key on
  payments (subscription_id) where kind = 'refund'`: `refund_subscription`
  сам это тоже проверяет (ради текста ошибки), но гарантия — в индексе,
  переживает прямой insert.

### Что не построено (этап 5)

«План» выручки (таблицы плана нет), pg_cron для `installments_notify`
(этап 6), UI платежей и рассрочек. Дата платежа в `record_payment` приходит
моментом из браузера, у `record_expense` — днём по поясу центра; перед UI
платежей привести к одному виду.


## Уведомления (0032–0034)

Первый этап, на котором `events` кто-то читает. Читает n8n: ходит в
PostgREST ролью `bot_worker` и забирает пачку. Почему не наоборот —
[ADR-008](Decisions/ADR-008-event-delivery.md).

### Роль `bot_worker`

Ни одного табличного гранта — только `execute` на функции очереди,
планировщиков и бота. Не `service_role`: у того остаются **все** таблицы
(`0024` снимал гранты только у `public`/`anon`/`authenticated`), и ключ
n8n открывал бы карточки детей всех центров мимо узких функций 0031.

### Роль `public_booking`

Та же схема, что у `bot_worker`, для публичной витрины записи `/book/[slug]`
(0057): ни одного табличного гранта, только `execute` на три функции
(`booking_center_info`, `booking_teacher_busy`, `submit_booking_request`).
Не `anon` — анонимный ключ Supabase лежит в браузерном бандле, а параметры
RPC были бы под контролем атакующего (rate limit по count(*) не устоял бы);
не `service_role` — тот же довод, что у `bot_worker`. JWT без `sub` заводит
владелец, используется только в `apps/web/lib/supabase/booking.ts` на
сервере (`SUPABASE_BOOKING_JWT`, не `NEXT_PUBLIC_*`).

Анонимный путь пишет только `booking_requests` — заявку на подтверждение,
не `students`/`lessons` напрямую (иначе публичный `EXCLUDE`-конфликт
`lessons_teacher_no_overlap` даёт отказ в обслуживании на расписание
специалиста). Подтверждает и превращает в ученика+занятие уже стойка
(owner/admin/registrar) через `confirm_booking_request` — обычная
`authenticated`-сессия, `can_front_desk()`.

`emit_event` (0002) требует `auth.uid() is not null` — у `public_booking`
его нет, поэтому заявка идёт через `emit_event_unchecked` (0018), как у
`bot_worker`.

### Очередь

| Функция | Что делает |
|---|---|
| `claim_events(limit)` | Забирает пачку: `for update skip locked` против двух прогонов, `order by id` на результате — иначе «абонемент закончился» обгонит «осталось 2» |
| `ack_events(ids)` | Закрывает — только то, что помечено `claimed_at` |
| `fail_events(ids, error)` | `attempts + 1`, возврат в очередь; на третьем провале терминал и `event.failed` (но не для самого `event.failed`) |
| `release_stale_claims(interval)` | Воркер умер между claim и ack: возвращает через `fail_events`, то есть с ростом `attempts` |

Колонки `events`: `claimed_at`, `attempts`, `last_error`. Все функции с
обратной проверкой `auth.uid() is not null` → 42501: очередь исполняется
только вне пользовательской сессии.

### Планировщики

`lesson_reminders()` — занятия в ближайшие 18 часов, по одному событию на
занятие; отметка в `lesson_reminders_sent` (первичный ключ и есть
инвариант, таблица закрыта на запись всем — колонку в `lessons` можно было
бы переписать `PATCH`-ом).

`daily_digest()` — сводка центру с местных 08:00, один раз в день
(`center_digest_runs`). Считает `subscription_state_unchecked`, а не
гейтованную версию: без пользователя та возвращает NULL, и счётчик молча
был бы нулевым.

`installments_notify()` (0020) — грант переехал с `service_role` на
`bot_worker`.

### Telegram

`telegram_accounts` — единственная не центровая таблица проекта: чат
принадлежит человеку, а членств у него может быть несколько. Уникальность
— частичными индексами `where unlinked_at is null`, поэтому отвязка и
повторная привязка проходят, а история остаётся.

`bot_today`, `bot_balance`, `confirm_lesson` ходят **мимо RLS** и потому
выписывают видимость заново: специалисту — его занятия, родителю — его
дети (через `lesson_participants`, иначе групповые занятия не видны),
бухгалтеру — ничего. Непривязанный чат получает отказ, а не пустой ответ.

### Шаблоны и журнал

Дефолты платформы — строки `message_templates` с `center_id is null`;
строка центра перекрывает их (`order by center_id nulls last`). Копий при
создании центра нет: копия заморозила бы формулировку на дату создания.

`event_messages(event_id)` собирает «кому и какой текст»: получатели,
подстановка `{child}` и формат денег — всё в SQL, чтобы предпросмотр на
экране и отправка не разошлись. С 0035 отдаёт ещё две колонки: `subject_id`
— о ком сообщение, и `action` — готовые подпись и `callback_data` кнопки,
которые n8n кладёт в `reply_markup` как есть.

Две вещи, которые повторяются при каждой новой ветке `event_messages` и
забываются (0032, 0035, 0047): **шов** — события нового типа, накопленные
до миграции, закрываются `processed_at = now()` в той же миграции, иначе
первый `claim_events` после деплоя разошлёт историю; и **переменные по
каналу** — если текст не должен покидать telegram (`{summary}`, имя
ребёнка в сообщении специалисту), в другой канал переменная приходит
пустой строкой, а не отсутствует: `render_template` оставляет неизвестный
плейсхолдер в тексте буквально.

Формат `callback_data` — `c:<event_id>:<student_id>`, а не пара uuid:
Telegram ограничивает поле 64 байтами, а два uuid с префиксом дают 81, и
кнопка просто не отправилась бы. Занятие по событию находит
`confirm_lesson_by_event`, она же не даёт подтвердить приход на занятие,
которое уже прошло или отменено — кнопка в переписке живёт дольше занятия.

`notification_log` — машина состояний: `pending` при захвате, дальше
`sent`/`failed`/`no_channel`/`skipped`, и `failed → pending` только пока
`attempts < 3`. Переходы держит триггер. Уникальность —
`unique nulls not distinct (event_id, recipient_user_id, channel,
subject_id)`: строка «получателей нет» имеет пустого получателя и не должна
копиться, а ребёнок в ключе появился в 0035 — без него у родителя двоих
детей в одном групповом занятии второе сообщение попадало на ту же строку
и молча не уходило. Обязательность `subject_id` для сообщений о ребёнке
держит отдельный триггер: список исключений обратный (`digest.daily`,
`event.failed`), чтобы новый тип события был защищён по умолчанию.
Политики `tenant_finance_*` у журнала нет — в тексте имя ребёнка и
остаток (0031).


## Клиническое ядро (0036)

Восемь таблиц: `goal_stages`, `diagnostics`, `goals`, `goal_progress`,
`exercise_library`, `homework`, `homework_exercises`, `lesson_notes`.

**Видимость строже, чем у всего остального.** Регистратор и бухгалтер не
получают ни одной строки — включая справочник этапов и библиотеку
упражнений: через них видно, над чем центр работает. Специалист видит
клинику ребёнка, с которым у него есть **неотменённое** занятие
(`clinical_teacher_sees`); архивный ребёнок не виден. Отменённое занятие
доступа не даёт: иначе ошибочная запись, отменённая через минуту,
открывала бы диагнозы навсегда.

**Родителю таблицы закрыты целиком.** Он ходит через
`student_diagnostics_brief`, `student_goals_brief`, `student_notes_brief`
— функции, в возвращаемом типе которых колонок `sounds`, `speech_areas`,
`raw_transcript`, `soap` и `goal_progress.note` нет физически (ADR-005,
третье применение приёма). Черновик заметки не отдаётся ни при каких
условиях. Состав заданий родитель видит через
`clinical_homework_visible` — иначе ДЗ приходит без названий упражнений.

### Заключение как справочник (0059)

`diagnostics.conclusion_code` → `speech_conclusions` (по Левиной: норма,
ФНР, ФФНР, ОНР I–IV, ЗРР); клинические формы и направления — junction
`diagnostic_clinical_forms` / `diagnostic_referrals` (форма
`homework_exercises`: `deleted_at` + частичный unique — снятая форма
остаётся историей). Три справочника **глобальные**, как `funnel_stages`,
но с `is_active`: вывести код из оборота, не трогая строки, на которые он
ссылается. Запись — только `record_diagnostic`/`update_diagnostic`
(новые параметры в конце сигнатуры), `update_diagnostic` берёт `for
update` по строке `diagnostics` до правки связок: без замка две сессии
складывают два заключения в одно. `null` = «не передано», `'{}'`/`'[]'`
= «очистить».

Видимость связок — `clinical_diagnostic_visible(uuid)`: круг самой
`diagnostics` (owner/admin, teacher через `clinical_teacher_sees`), **без
родителя** — `clinical_visible_to_caller` его включает, и родитель
прочитал бы «направлена к психиатру» прямым запросом. Родителю через
`student_diagnostics_brief` уходит только `conclusion_name`.
`archive_diagnostic` гасит связки каскадом: `tenant_admin` на junction
фильтрует по своему `deleted_at`, не по диагностике.

Фильтр «все с ОНР III» в списке учеников — `student_conclusions()`
(роль внутри): `diagnostics` закрыта стойке и бухгалтеру, а embed отдал
бы им пустой массив без ошибки. `export_center_lookups()` — справочники
в выгрузку центра: коды в junction без них нечитаемы (0056, находка 11).
`null` в `conclusion_code` — и «до 0059», и «не определено» (Р11).
Подсказка из `speech_areas` — фаза 2, `suggest_speech_conclusion` (0061),
без своей таблицы.

### Подсказка заключения из speech_areas (0061)

`suggest_speech_conclusion(speech_areas jsonb) returns text` — чистая
функция (`language sql immutable`, ни одной таблицы), вычисляется на
чтении, не хранится. Первый план — денормализованная таблица-кеш с
AFTER-триггером — архитектор развернул: каст jsonb внутри триггера ронял
бы сохранение диагностики на любом кривом значении (свободный `jsonb` без
констрейнта, `record_diagnostic` открыт `authenticated`), а кеш протухал
бы без бэкфилла и пересчёта при смене эвристики. Вычисление на чтении
убирает разом таблицу, RLS, триггер, экспорт и `is_active`-проверку.

«Нарушено» — значение ≤ 2 на шкале `[1,5]` (порог владельца, 24.09.2026);
вне диапазона или нечисловое — как отсутствующий ключ. Нужны все пять
канонических ключей (`звукопроизношение`/`фонематика`/`лексика`/
`грамматика`/`связная речь`, зашиты литералами в обеих реализациях) —
иначе `null` («недостаточно данных», не догадка). Уровень ОНР **не**
угадывается: любое нарушение в лексике/грамматике/связной речи даёт общий
флаг `onr_suspected` (не код справочника — коллизия с `speech_conclusions`
проверена в pgTAP), а не `onr_1..onr_4` — уровень из среднего трёх шкал
перепутал бы тяжесть местами и не мог бы отличить ОНР I от ЗРР без
возраста ребёнка на входе. `zrr` не предлагается никогда — возрастная
категория, не выводится из баллов по областям. `norm` тоже не
предлагается никогда (находка ревью написанного SQL): функция не видит
`diagnostics.sounds` — карту звуков той же формы; пять шкал в норме при
искажённых звуках дали бы кнопку «Применить: Речь в норме», хотя дислалия
налицо. `null`, таким образом, означает и «недостаточно данных», и
«нарушений по шкалам не найдено» — для подсказки-намёка это не критично
(в отличие от `diagnostics.conclusion_code`, где два смысла `null`
разбираются отдельно, Р11 0059).

Источник истины — эта функция; `packages/core/src/nosology.ts` — зеркало
для мгновенной подсказки в форме, пока специалист печатает баллы (без
похода в базу на каждое изменение поля); один и тот же пронумерованный
список случаев — и в pgTAP, и в Vitest. Сегодня функцию вызывает только
pgTAP — приложение считает подсказку в браузере через TS-зеркало;
единственное, что удерживает реализации от расхождения, — совпадение
тестовых случаев, а не общий вызывающий код. Подсказка никогда не
проставляется в `conclusionCode` сама —
только кнопка «Применить» в `diagnostics-panel.tsx`.

**Исключение из «нет физически» — `student_goals_brief.trend` (0046).**
Тренд по цели за 3 последних занятия (`regress`/`stagnant`/`growth`/
`stable`, `null` только при <3 записей) закрыт от родителя не отсутствием
колонки, а веткой внутри функции (`coalesce(my_role(),'')='parent'` →
`null`): в отличие от `last_score`, который родитель видит и так, `trend`
раскрывает отношение между тремя оценками — решили, что это больше
истории, чем одно число, плюс родителю отдельно уже показывается своя
динамика за период в `student_goal_dynamics_brief` (0043, месячный
отчёт) — два разных окна на одном экране путали бы. `last_score` и
`trend` считаются одним `lateral`-подзапросом, чтобы не разъехаться
между собой при разной сортировке.

**Запись — только RPC (0037).** У `teacher` и `parent` здесь лишь
`select`. Политика на запись стала бы обходом функции: «утвердить
заметку» превратилось бы в прямой `update status`.

**Три инварианта держат констрейнты и триггеры, а не функции:**

- статус и его метка времени — одно целое. `lesson_notes.approved_at` и
  `goals.achieved_at` выставляет триггер, `check` держит согласованность.
  Обратный переход `approved → draft` запрещён: резюме уже ушло родителю.
  Цель, наоборот, можно открыть заново — звук откатывается;
- заметка, прогресс и ДЗ проверяют **состав занятия**
  (`clinical_check_lesson_participant`): на групповом занятии иначе
  запишется SOAP не того ребёнка. FK на `lesson_participants` невозможен
  — `rebuild_lesson_participants` перекладывает строки;
- упражнение чужого центра в ДЗ отбивает триггер, а не составной FK: у
  библиотеки платформы `center_id` пуст, и FK с NULL не проверяется.

`goals_touched jsonb` из промта не заведён: какие цели затронуло занятие,
уже записано в `goal_progress` парой `(goal_id, lesson_id)` — с FK и
проверкой центра.

## Голосовое резюме занятия (0041, 0042)

Контур, который пишет клинические данные **без сессии специалиста**: n8n
действует от роли `bot_worker`, у которой нет ни одной таблицы — только
несколько узких функций. Каждая из них начинается с обратной проверки
«если сессия есть — отказ», как `confirm_lesson_by_event` (0035).

**Токен диктовки.** `lesson_voice_requests` — одноразовая запись «жду
голосовое по этому ребёнку», живёт минуты. Политик и грантов нет вовсе,
токен возвращается один раз из `request_voice_note` и уходит в ссылку на
бота (приём `telegram_link_codes`, 0033). Аудита на таблице **нет
сознательно**: он унёс бы токен и личный чат специалиста в `audit_log`,
который читают владелец и администратор центра.

Три состояния вместо двух: погашен голосовым (`consumed_at`), отменён
выдачей нового (`cancelled_at`), живой. Разделены, чтобы `armed_at` не
приходилось подделывать у записей, которых бот не видел, — иначе вопрос
«сколько диктовок доходит до бота» получал бы завышенный ответ.

**Гашение и событие — одна транзакция** (`report_voice_note`). Две
функции дали бы окно: бот погасил токен, упал, событие не создал — и
голосовое исчезло, а на экране вечное ожидание.

**Очередь работ.** `ai_jobs` + `ai_job_begin/finish/fail` — тот же приём,
что `notification_begin` (0034): дорогое необратимое действие прикрыто
отметкой **до** него. Очередь доставляет at-least-once, поэтому без этого
рестарт n8n или отказ записи означали бы повторную оплату расшифровки и
модели. `ai_job_begin` отвечает «не работай», если событие чужое,
устаревшее, уже сделанное, терминальное — **или если запись всё равно
упадёт**: утверждённая заметка, архивный ребёнок, отменённое занятие,
готовый черновик проверяются здесь, до траты. Сюда же встанет лимит по
тарифу в этапе 8.

**Оценки целей ждут человека.** Модель пишет не в `goal_progress`, а в
`lesson_note_goal_scores`; в витрину прогресса они переезжают только из
`approve_lesson_note`. Причина: `student_goals_brief` (0036) отдаёт
родителю последнюю оценку без всякой проверки на утверждение — запись
напрямую означала бы, что родитель видит оценку, которую поставила модель
и не смотрел ни один человек. Отдельной таблицей, а не полем-массивом: от
`goals_touched jsonb` уже отказались в 0036 ровно потому, что массив
идентификаторов ничем не проверяется и однажды покажет цель другого
ребёнка. Здесь связь держат составные внешние ключи и триггер «цель того
же ребёнка, что и заметка».

**Перенос идёт без `conduct_key`** и пропускает цели, по которым за
занятие оценка уже есть. Занять этот ключ нельзя: им гасит повторы
`complete_lesson` (0039), и ручная оценка, поставленная после диктовки,
молча не записалась бы — при том что экран показал бы успех.

**Кривой ответ модели — пропущенная цель, а не потерянная заметка.**
Дробная оценка или выдуманный идентификатор не роняют уже оплаченную
расшифровку; вызывающий получает список пропущенного, чтобы сказать
специалисту. Отказом остаётся только цель чужого ребёнка: там речь о
смешении карт детей.

**Реестр расхода** `ai_usage` — источник истины по деньгам, по строке на
каждый вызов внешнего сервиса. Пишется отдельной функцией сразу после
вызова, независимо от исхода записи заметки: иначе при отказе деньги
потрачены, а учёта нет — ровно там, где расход аномальный. Хранит токены,
модель и курс, потому что курс живёт в переменных n8n и устаревает:
пересчитать историю можно только по токенам. Закрыт на запись, читают
владелец и администратор через политику и `ai_usage_summary` (границы
периода — в поясе центра, не сервера).

`check_ai_quota` **не заведена** и не должна появиться до тарифов этапа
8: функция с таким именем, которая всегда пропускает, — ловушка.

## Посещения: закрыт свободный текст от родителя (0044)

`attendance.comment` — та же пометка стойки/специалиста, что
`students.notes`/`payers.notes`/`lessons.notes` для бухгалтера (0031):
внутренний текст, не для семьи. Была случайным исключением — политика
`attendance_parent_read` (0009) отдавала родителю всю строку, включая
`comment`, `price_tiyin`, `subscription_id`.

`0044` снимает политику целиком тем же приёмом, что снятие
`tenant_finance_select`: роли доступна не колонка, а узкая функция.
Родителю остаётся `student_attendance_brief` (0043) — дата, статус,
признак пропуска, без остальных колонок физически. Отклонённая
альтернатива — вынести `comment` в отдельную таблицу (уровень 1 из
ADR-005): не выбрана, потому что переписывает `mark_attendance`,
`mark_attendance_bulk` и `complete_lesson` ради одной колонки, тогда как
узкая функция уже написана и покрывает единственный существующий
сценарий (месячный отчёт).

## Тарифы, роль платформы и только чтение (0049, 0050)

`plans` — справочник платформы: `code`, `price_tiyin`, `limits` jsonb
(`teachers`, `students`, `ai_notes_month`; `-1` — без ограничения),
seed строками миграции. `centers.plan` — FK на `plans.code`, литерального
списка больше нет. Отсутствие тарифа или ключа лимита — отказ, не
безлимит.

Тариф, сроки и `settings->'features'` центр не пишет: триггер
`centers_protect_plan` пропускает только `is_platform_admin()`.
Администратор платформы — по email в `platform_admins`, предикат идёт
через `auth.users` текущего `uid` и требует подтверждённый email; роль вне
`memberships`, поэтому `/admin`-RPC начинаются с этого предиката, а не с
`current_center()`.

Лимиты держат AFTER-триггеры `teachers_check_limit` и
`students_check_limit` (BEFORE не видит строк своего оператора — пакетная
вставка обходила бы лимит), с `pg_advisory_xact_lock` по
`center_limit:<center_id>` до счёта. Лицензия специалиста — живая
карточка `teachers`; место ученика — карточка не в архиве. Проверка
только на входе в считаемое состояние: превысивший центр правит и
архивирует, но не растёт. Фикстуры с >5 специалистов или >200 учеников в
одном центре — `plan = 'center'` и `subscription_until`.

Только чтение при просрочке — `a00_readonly_guard`, BEFORE-триггер на
каждой базовой таблице `public`, навешен циклом по каталогу через
`apply_readonly_guard(tbl, insert_only)`; исключения — в
`readonly_guard_exempt_tables()` с причиной, забор pgTAP 0050 сверяет
каталог с ними с обеих сторон (таблицы без `center_id` — тоже в списке).
Срабатывает только при `auth.uid() is not null`; порядок —
`center_writable` (PK), потом `is_platform_admin()`; `memberships`/
`invitations` — только insert; карточку `teachers` гасит
`revoke_membership` под транзакционным флагом `logocrm.revoke_membership`.
`center_writable(center)` — живой trial или подписка до конца дня
истечения в поясе центра, пустая дата — нет; `center_limits()` отдаёт
`writable` из неё же. Код отказа `PT402` (PostgREST → HTTP 402), ветка в
`errors.ts`. Механизм и границы — [ADR-011](Decisions/ADR-011-center-readonly.md).

Новая таблица центра в миграции — три вызова подряд:

```sql
call public.apply_tenant_rls('tbl');
call public.apply_audit('tbl');
call public.apply_readonly_guard('tbl');
```

Два правила, без которых guard обходится: `center_id` заполняется только
`default public.current_center()` — ни один BEFORE-триггер его не
присваивает (guard увидел бы `null`, а следующий триггер подставил бы
центр); таблица с nullable `center_id` (строки платформы) обязана иметь
собственный рубеж записи, работающий и внутри definer — триггер по роли
(0040) или `if` в единственной пишущей RPC (0037): строку с пустым
`center_id` guard не судит, забор 0050 лишь напоминает о решении.
`center_writable(uuid)` без гранта `authenticated`: экрану хватает
`center_limits().writable`, а прямой RPC был бы оракулом по чужим центрам.

### Заявки на оплату и продление (0051)

`platform_payments` — заявка центра и решение платформы в одной строке,
но разными колонками: центр пишет `claimed_plan`, `claimed_months`,
`claimed_amount_tiyin` (= `plans.price_tiyin × months`, посчитано в SQL),
`source`, `note` через `submit_platform_payment(plan, months, source,
note)` (owner/admin, работает и в read-only — таблица в списке
исключений guard); платформа — `confirmed_*`/`plan`/`months`/`amount_tiyin`
через `extend_subscription(payment_id, plan, months, amount_tiyin,
receipt_received)` или `rejected_*` через `reject_platform_payment`;
центр отзывает свою открытую заявку `withdraw_platform_payment`. Одна
открытая заявка на центр — частичный unique
`platform_payments_one_open_per_center` по трём исходам. Инварианты
подтверждения — констрейнты на колонках (`num_nonnulls(...) in (0, 4)`,
`months 1..24`, `amount > 0`, `plan <> 'trial'`), функция повторяет их
ради русского текста. Политика — только `select` (owner/admin своего
центра, `is_platform_admin()` последним); `apply_tenant_rls` намеренно
не применена — её `with check` дал бы центру дописать подтверждение.
Чек не хранится: фото уходит платформе в Telegram с номером заявки.

Список открытых заявок — `platform_open_payments()` для `/admin`;
Telegram-уведомление платформе (`platform.payment_submitted` →
`notification_platform_targets`, только telegram, только дефолтный
шаблон) — дополнение. Условие выката: аккаунт владельца платформы
зарегистрирован, email подтверждён, Telegram привязан.

`notification_event_types` получил `audience` (`center`/`platform`) и
`subject_required`: триггер `notification_log_subject_required` читает
признак из справочника (тип вне справочника защищён по умолчанию), а
триггер `message_templates_platform_audience` не даёт центру завести
строку для платформенного типа. Событие `subscription.extended` идёт
owner/admin центра с `{until}` в поясе центра;
`subscription.voice_blocked` — заказчику диктовки, один раз на диктовку
(дедупликация по `events` в `ai_job_begin`).

### Напоминания о сроке и пульт платформы (0052)

`subscription_reminders()` — четвёртый шаг сценария `schedule` n8n
(`bot_worker`): центрам с местным часом ≥ 8 за 0–3 дня до срока —
`subscription.ending` тремя ступенями (`ending_3` за 2–3 дня, `ending_1`,
`ending_0`), после — `subscription.expired`; отметка
`subscription_reminders_sent (center_id, until, kind)` — по самому сроку
из `centers`, не по дате в поясе (пояс правит владелец). Пока у центра
открыта заявка — «заканчивается» молчит без отметки, «истёк» идёт всегда.
Тело одного центра в блоке исключений, число пропусков — `skipped_count`
в ответе (нода n8n роняет прогон при > 0). `center_timezone()` с 0052
отдаёт `Asia/Bishkek` для имени вне `pg_timezone_names`: поле правит
владелец, один мусорный пояс не должен ронять читателей всех центров.
`{when}` собирает SQL («сегодня»/«завтра»/«через N дн.»), только для
«заканчивается». `notification_event_types.mandatory` + триггер
`message_templates_mandatory_active`: центр правит текст, но не выключает
рассылку (soft-delete строки — возврат к дефолту, проходит).

Один trial-центр на владельца — `assert_one_trial_center(user, self)` из
триггера на `memberships` (insert или смена роли на owner); trial-центры,
закрытые меньше 90 дней назад, считаются; без сессии и для платформы
триггер молчит; текст отказа различает «у вас» и «у этого участника».
Возврат в trial и снятие архива достижимы только платформе — триггера на
`centers` нет намеренно. Правило для фикстур: два центра — два разных
владельца либо второму `plan <> 'trial'`. Второй центр владельцу —
`platform_create_center(name, owner_email)` из платформенной сессии.

`platform_centers()` (живые центры, срок и дни в поясе центра, `no_date`
первыми), `platform_summary()` (счётчики, `mrr_tiyin` = прайс живых платных
центров, выручка по месяцам подтверждения за 12 месяцев в поясе
платформы) — деньги для `/admin` считает SQL, экран рисует.
`platform_open_payments` фильтрует закрытые центры так же, как
`platform_centers`.

### Квота голосовых резюме (0053)

Квота — гейт в горловине, не инвариант на реестре: единственный путь к
платному вызову — `ai_job_begin` (`bot_worker`), единственный писатель
`ai_usage` — `ai_usage_record`; триггер на `ai_usage` отбивал бы уже
потраченные деньги. Счёт: `center_ai_notes_used(center)` — оплаченные
`summary` за месяц от `center_month_start(center)` (timestamptz в поясе
центра, ложится на индекс) — его видят экран (`center_limits`) и текст
отказа; в `ai_job_begin` к нему добавляется резерв `ai_notes_reserved` —
работы `running` не старше 8 минут без строки `summary`, своя работа при
перезахвате исключается — под `pg_advisory_xact_lock('center_limit:…')`
до `insert ai_jobs`. В `ai_job_begin` квота — булев исход (`null` +
`ai.quota_exceeded` один раз на диктовку, unique `events_quota_exceeded_once`;
тарифа нет — `null` без события), исключение живёт только в
`assert_ai_quota` для `request_voice_note` — до гашения прежнего токена,
текст по роли, имя тарифа через `center_plan_name`. Событие идёт заказчику
диктовки (`{child}` только telegram, с предлогом) и owner/admin центра
(`subject_required = false`); тип обязательный (`mandatory`) — единственный
сигнал о пропавшей диктовке, дефолтный текст не называет `{used}/{limit}`,
потому что решение о блокировке видит ещё и резерв, которого экран не
показывает.

## Воронка учеников (0055)

`funnel_stage` — отдельная колонка на `students` (не `status`): семь
шагов (`funnel_stages`, глобальный справочник без `center_id`, как
`plans`) — `lead → contacted → consultation → assessment → trial →
active → completed`. `status` (`active/paused/archived`) остался про
состояние ученика, `funnel_stage` — про этап продажи; `'lead'` снят из
`students.status` тем же 0055 — он был мёртвым значением (ни одной строки
на проде, `create_student_with_payer` его никогда не ставил).

Путь записи — три контура, различаемых транзакционными GUC-флагами
(`logocrm.funnel_write`/`logocrm.funnel_auto`, ставит и снимает сам
вызывающий — приём `logocrm.revoke_membership` из 0050):

- **ручной** — только через `set_funnel_stage(student, to_stage, cause,
  is_service)`; прямой `PATCH students.funnel_stage` (доступен
  owner/admin через `apply_tenant_rls` и registrar через `apply_role_rls`)
  отбивает `42501` — «переходы в функции» не защищают, пока есть прямой
  путь;
- **автоматический** — продажа абонемента (`AFTER INSERT` на
  `subscriptions`) и первое присутствие (`AFTER INSERT OR UPDATE OF
  status_id` на `attendance`, по `attendance.is_present`, не по
  `deducted` — у статуса «Прогул» `deducts_lesson = true`) переводят в
  `active` из любого этапа до него или из `completed` (реактивация
  вернувшегося клиента), если `status` не `paused`/`archived`;
- **без сессии** — миграции, backfill, RI-каскады (`auth.uid() is
  null`), проходят целиком.

Граф переходов — `BEFORE UPDATE OF funnel_stage` на `students`
(`students_funnel_stage_guard`), инвариант, а не проверка в RPC: ручной
путь — вперёд на один шаг или назад на любой более ранний; автопуть —
прямой скачок в `active`; `INSERT` с `funnel_stage = 'completed'`
запрещён всегда. `AFTER`-триггер `students_funnel_events` пишет историю в
`funnel_events` (id, student_id, center_id, from_stage, to_stage, at, by,
cause, is_service) — только чтение для `owner`/`admin`/`registrar`
(`can_front_desk()`, без `apply_tenant_rls`); `teacher`/`parent`/`finance`
не видят ни строки — коммерческая история. `is_service = true` — правка
ошибки оператора, не реальное движение: `funnel_summary` её не считает.

`archive_student`/`restore_student` **не трогают** `funnel_stage` и не
пишут `funnel_events` — цикл архив→восстановление возвращает этап туда,
где он был.

`funnel_summary(from, to)` — owner/admin, `jsonb`: срез «сейчас» по
`students` (не по `funnel_events` — архивные и удалённые не искажают),
переходы и конверсия за период по `funnel_events` (`is_service = false`);
конверсия считается **по ученикам** (вошёл в период → достиг `active`
когда-либо после), не по рёбрам графа — ребра `lead → active` в графе
физически не существует, счёт по рёбрам всегда дал бы 0. Среднее время
на этапе — открытые интервалы (`coalesce(next.at, now())`), иначе
застрявшие незаметно улучшают метрику. `funnel_stuck(days)` —
`can_front_desk()`, список без движения дольше `days` для кнопки
WhatsApp.

`attendance_statuses.is_present`/`attendance.is_present` — новый явный
признак присутствия, заморожен на строку в `attendance_fill_and_check`
при каждой смене статуса (как `pays_teacher`, не как `subscription_id`):
не обратен `counts_absence` и не то же самое, что `deducted`.


## Экспорт данных центра и заявка на удаление (0056)

Экспорт — **явный allow-list** (`export_center_tables()`), не «каталог
минус deny-list»: динамический список сделал бы забор pgTAP бессмысленным
— новая таблица с `center_id` попадала бы в выгрузку молча, тест был бы
зелёным тривиально. `export_center_excluded_tables()` — причины
исключения (секреты `invitations`/`lesson_voice_requests`, служебные
таблицы воркеров, `audit_log` — своя функция). Забор: `allow ∪ deny` =
все базовые таблицы `public` с `center_id`, без пересечения.

`export_center_table(p_table)` — по одной таблице за вызов, не
`jsonb_object_agg` по всему центру разом (упёрлось бы в
`statement_timeout` у центра с историей за пару лет); веб собирает файл,
обходя `export_center_tables()`. `export_center_audit(from, to)` —
`audit_log` отдельно, за диапазон дат, с вычеркнутыми строками по
`invitations`/`lesson_voice_requests` (их `old_data`/`new_data` несут те
же секреты, что и сами таблицы). Ни у одной функции нет параметра
`p_center_id` — всегда `current_center()`; проверка роли по `my_role()`
при свободном центре открыла бы межцентровую выгрузку одним вызовом из
консоли браузера. `record_center_export()` — одна строка события
`center.exported` на весь экспорт, зовёт веб после сборки файла.

Заявка на удаление (`request_center_deletion(p_confirm_name)`) — owner
(не admin: admin в проекте нанимаемая роль), имя центра аргументом как
подтверждение, идемпотентна (`where deleted_at is null`). До этой
миграции у `centers_update_owner` (0001) не было ограничения по
колонкам, а `centers_protect_plan` (0049) не знает про `deleted_at` —
owner мог выставить `deleted_at` прямым `PATCH` в обход RPC; политика
переиздана с `deleted_at is null` в `with check` (RLS не судит
`security definer`-функции, владеющие таблицей, — флаг не нужен).
`cancel_center_deletion()` возвращает `deleted_at` в `null`.
`center_deletion_state()` — глазок в обход RLS: после удаления обычный
`select .from('centers')` не отдаёт строку даже owner/admin, а окно
отсрочки нечем нарисовать без отдельной функции. Физическая очистка
через 30 дней — вне этого этапа, ADR-012 ещё не написан.

`center_write_state(uuid)` — `'ok'|'expired'|'deleted'|'missing'`,
единственный источник причины read-only; `center_writable()` — тонкая
обёртка (`state = 'ok'`), чтобы не переписывать вызывающих 0050/0053.
`center_readonly_guard()` и `center_limits().state` берут текст/значение
из неё же: «удалён» — не то же самое, что «истекла подписка», и
требование «оплатите» сразу после «Удалить центр» читалось бы как
издёвка.

Написанный SQL ловит ещё три взаимодействия с уже существующим кодом,
которые до 0056 были невозможны, потому что `deleted_at` было некому
выставлять: `submit_platform_payment` (0051) отказывает `PT402`, если
центр удалён — иначе платёж уходит в никуда (заявка выпадает из очереди
платформы, `platform_open_payments`/`platform_centers` фильтруют
`deleted_at is null`, 0052). `my_memberships()` — список центров
пользователя в обход RLS, `/select-center` строится отсюда: обычный
`join` на `memberships → centers` прятал бы удалённый центр от его же
владельца, и вернуться отменить удаление было бы неоткуда.
`notification_event_types.center.deletion_requested` — `mandatory = true`
(0052 Р1): второй владелец не может выключить это уведомление тем же
путём, каким выключил бы напоминание о сроке. `record_center_export()`
пересчитывает число строк по каждой таблице сама, не принимает от
вызывающего — иначе браузер мог бы записать в постоянный журнал
произвольные числа.


## Выгрузка отчётов в CSV (0058)

Пять функций `returns table`, не `jsonb`: набор колонок — часть контракта,
и pgTAP проверяет его по `jsonb_object_keys(to_jsonb(row))` — новая
колонка с заметкой или телефоном не проскочит в файл молча.

| Функция | Кому | Что |
|---|---|---|
| `export_payments(p_from, p_to)` | `can_finance()` | платежи за период по `paid_at` в поясе центра; `left join` на плательщика/ученика/абонемент — архивная карточка не прячет платёж |
| `export_salary_summary(p_month)` | `can_finance()` | `salary_summary()` + имя специалиста, флаг `approved` |
| `export_salary_details(p_month)` | `can_finance()` | строки расчёта: утверждённый месяц — из снимка `salary_runs.lines`, иначе `calc_salary`; флаг `approved` в каждой строке |
| `export_attendance(p_from, p_to)` | только `owner`/`admin` | отметки за период: специалист занятия (`effective_teacher_id`) и кому оплачено (`paid_teacher_id`) — две колонки, без `attendance.comment` (0044) |
| `export_debts()` | `can_finance()` | срез на сегодня: `lessons_debt_tiyin` из `student_debts()` и `subscriptions_unpaid_tiyin` = `price − paid` по живым абонементам, двумя колонками |

`report_period_check(p_from, p_to)` — общий хелпер границ (`22023` на
`null`, `from > to`, больше года), исполнять могут только функции выше —
у `authenticated` гранта нет. Границы периода — полуоткрытые
`timestamptz`, посчитанные один раз от `center_timezone()`, не
`(paid_at at time zone tz)::date between …` в `where` — второе не
использует индекс и ошибается на границе суток. Отказ по роли — всегда
исключение `42501`: пустой файл при отказе читался бы как «данных нет».

Два долга не складываются: долг по занятиям — обязательство за уже
оказанную услугу без абонемента, недоплата по абонементу — за услугу,
которая ещё оказывается (и её можно отменить с возвратом, 0054). Сумма
двух чисел не соответствует ни одному действию в интерфейсе.

След: `emit_event('report.exported', {report, from, to, rows, by, role})`
из каждой функции после `return query` — `rows` считает сама функция через
`get diagnostics`, актор — `auth.uid()` (события в `events` без
`created_by`). Одна выгрузка — одно событие; отказ по роли или периоду
события не пишет.


## Глобальный поиск (0062)

`global_search(p_query, p_limit)` — единственная в проекте прикладная
функция с **`SECURITY INVOKER`**, и это её суть, а не упущение: она читает
`students`/`payers`/`lessons`/`lesson_participants`/`teachers` под
RLS вызывающего, поэтому «поиск не шире списка» держится политиками, а не
вторым набором предикатов, который разъехался бы через этап. pgTAP держит
`prosecdef = false`: одно слово `definer` в будущей миграции («чтобы не
тормозило») открыло бы всех детей всем ролям.

Что из этого следует и записано в шапке миграции:

- **finance** — пусто: у роли нет политик на `students`/`payers`/`lessons`
  (0031 сняла), её списки рисуют definer-RPC `students_brief`/`payers_brief`.
  Поле поиска бухгалтеру не показывается; чинить definer-ом нельзя.
- Имя плательщика в предикате — для ролей с `payers` (owner/admin/
  registrar; родитель — своя карточка) множество из `payers` под RLS, а
  `payer_display_name()` (0026) построчно — только специалисту, у которого
  `payers` не читаемы, а видимых учеников единицы: он находит ребёнка по
  имени мамы ровно там, где `students_teacher_view` показывает ему это
  имя, и не получает телефон. В выдаче имя считается `lateral` после
  `limit`, не для всех совпавших.
- Порядок задаёт база одним ключом `rank` (телефон 0 → префикс 1 →
  вхождение 2, архивные +3); клиент ничего не пересортировывает. Группы в
  выдаче нет — у `/app/groups` нет карточки по id.
- Порядок построения: сначала CTE найденных учеников с `limit`, потом
  занятия nested loop по `lesson_participants_student_idx` — иначе
  `parent_of_lesson()`/`teacher_teaches_student()` из RLS считались бы на
  каждой строке `lessons` центра на каждое нажатие клавиши. Занятие
  якорится на `lessons` (там `deleted_at`, `status`, время);
  `lesson_participants` — только связка с `deleted_at is null`, копия
  времени в ней не читается (ADR-006).
- Телефон: полный — `normalize_kg_phone` в любом формате; частичный (≥ 4
  цифр, без ведущих `996`/`0`) — вхождение в 9 местных цифр номера, и
  начало «07001234», и хвост «3456»; `phone_alt` тоже. Уникального
  индекса по `phone_alt` нет — поиск найдёт дубль, который база не
  запрещает (отдельный пункт).
- Край входа без исключений: `null`/пусто/1 символ → пусто; `p_limit`
  clamp 1..20 (`null` из PostgREST обходит default); `%`/`_`/`\`
  экранируются с явным `escape`, «ё»→«е» — после экранирования.
- Неделя для ссылки на расписание (`week_start`) считается здесь в поясе
  центра — браузер администратора из другого пояса открыл бы соседнюю.
- Клиентский фильтр в списке учеников — сужение уже загруженной страницы;
  глобальный поиск — SQL. Зеркала в TS нет: суффикс телефона в браузере —
  это расчёт видимости контактов в браузере.
- Событий нет: поиск — чтение экрана, не выгрузка.


## AI-ассистент администратора (0064)

Второй контур с провайдером после голосовых (0041): синхронный вызов из
веба по `OPENAI_API_KEY`, без n8n. Наружу — только текст вопроса и дата
(решение владельца, ADR-009 дополнен); модель выбирает намерение, данные
собирает база под сессией спросившего.

**Попытка и расход — разные сущности.** `assistant_requests` — попытка:
`created_by`, `intent`, `status running/done/failed`, `usage_id` → `ai_usage`
только у `done` (CHECK). Текст вопроса не хранится; select-гранта нет ни у
кого — журнал «кто что спрашивал» не заказан. `ai_usage` получает третий
`kind = 'question'` и пишется **после** ответа провайдера
(`assistant_finish`), как `ai_usage_record`; резерв в реестре денег с
`tokens = 0` дал бы колонке два смысла. Актор — на попытке, не в реестре.

**Горловина `assistant_begin()`** — гейт роли (owner/admin/registrar/
finance/teacher), `center_writable` → `PT402` (ai_usage в списке исключений
readonly-guard как «учёт уже потраченного», на него надежды нет), квота
под `pg_advisory_xact_lock('center_limit:…')`: `center_ai_questions_used`
(оплаченные `question` за месяц от `center_month_start`) +
`assistant_questions_reserved` (running-попытки ≤ 5 мин) против
`plan_limit(center, 'ai_questions_month')`. Ключ добавлен **всем** строкам
`plans` (дефолт 100 неизвестным кодам) — иначе пятый тариф получал бы «не
задан тариф». Возвращает `request_id`, `today`/`timezone` из базы
(`new Date()` на Vercel в 02:00 по Бишкеку — вчерашнее число) и список
намерений роли.

**Карта «намерение × роль»** — `assistant_intents_for(role)`: ровно те
намерения, чей источник данных роли читаем (`lessons` — не finance;
`student_debts()` — can_payments; `cash_by_source` — owner/admin;
`global_search` — не finance). Из неё собирается список инструментов для
модели И повторно проверяется намерение при закрытии — пустой ответ RLS
нельзя выдавать за «данных нет» (0058: исключение вместо пустого файла).

**Цену считает SQL, и ответ провайдера всегда закрывает попытку.**
`assistant_finish(request, status, intent, model, tokens_in, tokens_out,
error)` берёт ставку из `ai_model_rates()` (VALUES, тыйыны за 1M токенов —
смена курса следующей миграцией); параметр «стоимость» от сессии
пользователя в реестр не принимается. После ответа провайдера в функции
нет ни одного `raise` (ревью написанного SQL): деньги уже уплачены, а
исключение откатило бы строку расхода и оставило попытку `running`
навсегда — бесплатный и невидимый трафик. Поэтому: известная модель →
`done` + строка расхода (токены — clamp, не отказ); незнакомая модель →
`failed` с причиной («расход не учтён» — потеря признана явно); намерение
вне карты роли → `done`, расход записан, вердикт `allowed = false`
значением. Веб шлёт в `p_model` константу запроса, расхождение с ответом
провайдера — в текст ошибки. `failed` — без расхода, попытка не удаляется
(удаление резерва = бесплатный обход квоты «сорви вызов — лимит цел»).
Один вопрос — ровно один вызов провайдера (Vitest на
`buildClassifyRequest`).

`assistant_quota()` — `used/limit/intents` всем сотрудникам, имя тарифа —
только owner/admin (как `center_limits`, куда добавлен
`usage.ai_questions_month`).
