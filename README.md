# LogoCRM

Мультитенантный SaaS для логопедических центров Кыргызстана.
Next.js 15 · TypeScript · Supabase (Postgres + Auth + RLS) · pnpm monorepo.

> Каталог `logoped-crm/` — предыдущий одно-тенантный MVP, отдельный
> репозиторий. Новый код живёт в `apps/` и `packages/`.

## Где сейчас работает

Локальный стек (`supabase start`) требует Docker. Если его нет, проект уже
подключён к облачной базе:

| | |
|---|---|
| Проект | `logocrm`, регион ap-south-1 |
| Дашборд | https://supabase.com/dashboard/project/hiwstqrnxrlfuanvfggq |
| Миграции | 0001, 0002, 0003 применены |
| Тестовый вход | `owner@logocrm.kg` / `password123` |

Значения для `apps/web/.env.local` уже прописаны. В этом режиме работают
`pnpm dev` и все проверки приложения; недоступен только `pnpm db:test` —
pgTAP запускается лишь на локальном стеке.

Новые миграции в облако катятся так:

```bash
cd packages/db && supabase link --project-ref hiwstqrnxrlfuanvfggq && supabase db push
```

**Тестовый пользователь с известным паролем живёт в базе, открытой в интернет.**
Перед первыми реальными данными его нужно удалить, а тариф проекта и политику
паролей — пересмотреть.

## Требования

- Node.js 20+
- pnpm 9+ (`corepack enable && corepack prepare pnpm@9 --activate`)
- Docker (для локального Supabase)
- Supabase CLI (`brew install supabase/tap/supabase`)

## Первый запуск

```bash
pnpm install
```

```bash
cd packages/db && supabase start
```

`supabase start` напечатает `API URL` и `anon key`. Перенесите их в конфиг веба:

```bash
cp apps/web/.env.example apps/web/.env.local
```

Заполните `NEXT_PUBLIC_SUPABASE_URL` и `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
(для старых проектов — `NEXT_PUBLIC_SUPABASE_ANON_KEY`, читаются оба), затем:

```bash
pnpm db:reset
```

```bash
pnpm dev
```

Приложение — http://127.0.0.1:3000, Supabase Studio — http://127.0.0.1:54323,
почта локально (magic link) — http://127.0.0.1:54324.

Тестовый пользователь из seed: `owner@logocrm.kg` / `password123`.

## Команды

| Команда           | Что делает                                              |
|-------------------|---------------------------------------------------------|
| `pnpm dev`        | Next.js в режиме разработки                              |
| `pnpm build`      | production-сборка                                        |
| `pnpm lint`       | ESLint                                                   |
| `pnpm typecheck`  | `tsc --noEmit` по всем пакетам                           |
| `pnpm test`       | Vitest в `core` и `contracts`                            |
| `pnpm db:start`   | поднять локальный Supabase                               |
| `pnpm db:stop`    | остановить его                                           |
| `pnpm db:reset`   | прогнать миграции с нуля и применить seed                |
| `pnpm db:test`    | pgTAP-тесты                                              |
| `pnpm db:types`   | перегенерировать `packages/db/src/database.types.ts`     |
| `pnpm db:link <ref>` | связать репозиторий с облачным проектом               |
| `pnpm db:push`    | накатить новые миграции в облако                         |

## Как добавить миграцию

```bash
cd packages/db
supabase migration new add_students
```

Правьте созданный файл в `supabase/migrations/`, затем:

```bash
pnpm db:reset && pnpm db:test && pnpm db:types
```

После этого обязательно проверьте линтер Supabase — вкладка **Advisors** в
дашборде проекта. Он ловит то, чего не видят pgTAP-тесты: таблицы без RLS и
`security definer`-функции, открытые роли `anon`. Именно так были найдены
дыры, закрытые миграциями 0002 и 0003.

Миграции неизменяемы после мержа в `main`: ошибку исправляет следующая
миграция, а не редактирование старой.

## Как добавить таблицу

Шаблон обязателен для всех таблиц с данными центра — подробности и объяснения
в [docs/Database.md](docs/Database.md).

```sql
create table public.students (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null default public.current_center()
                  references public.centers (id) on delete cascade,
  full_name     text not null,
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

call public.apply_tenant_rls('students');   -- RLS: owner/admin своего центра
call public.apply_audit('students');        -- история изменений
```

Коротко о правилах: `id` — uuid; деньги — `integer` в тыйынах; статусы —
lookup-таблицы, не `enum`; удаление — только `deleted_at`; произвольные поля —
`custom_fields jsonb`.

После миграции добавьте pgTAP-тест «чужой центр не видит строку» и
перегенерируйте типы (`pnpm db:types`).

## Как добавить событие

1. Схема payload и запись в union — `packages/contracts/src/events.ts`:

```ts
export const lessonCompletedSchema = z.object({
  type: z.literal('lesson.completed'),
  payload: z.object({
    center_id: z.string().uuid(),
    lesson_id: z.string().uuid(),
  }),
})

export const appEventSchema = z.discriminatedUnion('type', [
  centerCreatedSchema,
  membershipCreatedSchema,
  lessonCompletedSchema,   // ← добавить
])
```

2. Публикация из SQL:

```sql
perform public.emit_event(
  'lesson.completed',
  jsonb_build_object('center_id', new.center_id, 'lesson_id', new.id)
);
```

3. Обработчик в воркере читает `events where processed_at is null`, валидирует
   строку через `parseAppEvent()` и проставляет `processed_at`.

Имя события — `сущность.действие` в прошедшем времени. Доставка at-least-once:
обработчики обязаны быть идемпотентными ([ADR-003](docs/Decisions/ADR-003-events-outbox.md)).

## Как катятся миграции

Схема меняется **только файлами** в `packages/db/supabase/migrations` и только
через CI:

```
PR → CI (app + db с pgTAP + e2e) → merge в main → CI на main → джоб «Схема» → db push
```

Джоб «Схема» в `ci.yml` вызывает `deploy-staging.yml` с `needs: [db, app]`.
Это не дисциплина, а зависимость между джобами: деплой физически не может
опередить ни pgTAP, ни Vitest-зеркала SQL-логики. Приёмка Playwright в гейт
деплоя не входит — она про интерфейс, а не про схему, — но обязательна для
мержа через required status checks на `main`.

Checkout в джобе деплоя берёт тот же коммит, что проверял pgTAP. Прежняя
связка через `workflow_run` брала верхушку `main`, и между зелёным прогоном и
деплоем мог проскочить непроверенный пуш.

Ручной запуск `Deploy staging` возможен только с `main`: с ветки он обошёл бы
pgTAP.

Prod (этап 8) автоматического деплоя не получит — туда руками и осознанно.

### Что нужно настроить один раз

В Settings → Environments → **staging** нужен один секрет:

| Секрет | Где взять |
|---|---|
| `SUPABASE_DB_PASSWORD` | Project Settings → Database → Database password (Reset, если не сохранён). Только пароль, без строки |

Строку подключения собирает сам workflow: ref проекта, имя пользователя
пулера и хост зашиты в `deploy-staging.yml`, пароль кодируется. Так не бывает
четырёх ошибок, на которых деплой уже спотыкался: чужой проект, имя
пользователя без ref, Direct connection вместо пулера, непроцентованный
пароль.

`SUPABASE_DB_URL` остался запасным путём. Если пользоваться им — только
Session pooler (`aws-0-ap-south-1.pooler.supabase.com:5432`), не Direct
connection: тот отвечает по IPv6, а раннеры GitHub ходят по IPv4. Workflow
проверит, что строка ведёт в нужный проект.

Токен аккаунта не нужен: `supabase db push --db-url` обходится без `link`.
Это сознательный выбор — токен Supabase даёт власть над всей организацией,
включая боевой проект `logoped-crm`, а пароль ограничен одной базой.

## Документация

- [docs/Architecture.md](docs/Architecture.md) — как устроена система
- [docs/Database.md](docs/Database.md) — схема и конвенции таблиц
- [docs/Decisions/](docs/Decisions/) — ADR: монорепа, RLS, outbox, среды, колоночная приватность
- [docs/CHANGELOG.md](docs/CHANGELOG.md)
- [docs/Roadmap/stages.md](docs/Roadmap/stages.md) — план этапов
- [docs/Backlog.md](docs/Backlog.md) — пожелания от логопедов
- [reports/](reports/) — отчёт по каждому этапу
