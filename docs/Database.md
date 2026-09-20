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
| `subscription_lessons_left` / `subscription_state` / `subscription_freeze_days` / `refund_calc` | внутренние | `security invoker`: чужой абонемент даёт **NULL**, а NULL у остатка значит и «безлимит». Из приложения не вызывать — только `subscription_summary` |

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
экране и отправка не разошлись.

`notification_log` — машина состояний: `pending` при захвате, дальше
`sent`/`failed`/`no_channel`/`skipped`, и `failed → pending` только пока
`attempts < 3`. Переходы держит триггер. Уникальность —
`unique nulls not distinct (event_id, recipient_user_id, channel)`:
строка «получателей нет» имеет пустого получателя и не должна копиться.
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
