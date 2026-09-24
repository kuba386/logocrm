# Архитектура LogoCRM

## Что это

Мультитенантный SaaS для логопедических центров Кыргызстана. Один инстанс
обслуживает много центров; данные центров изолированы на уровне базы, а не
на уровне приложения.

## Карта репозитория

```
apps/web            Next.js 15 (App Router) — единственный деплоймент
packages/db         Supabase: миграции, seed, pgTAP-тесты, сгенерированные типы
packages/core       Чистая бизнес-логика (деньги, расписание, лимиты тарифов)
packages/contracts  zod-схемы: события outbox и входные DTO
docs                Архитектура, схема БД, ADR, changelog
```

Зависимости идут в одну сторону:

```
apps/web ──▶ packages/contracts ──▶ (zod)
   │  └────▶ packages/core       (без внешних зависимостей)
   └───────▶ packages/db         (только типы)
```

`packages/core` не знает ни про Supabase, ни про Next — его можно вызвать из
воркера, из скрипта миграции данных или из теста без поднятия базы.

## Мультитенантность

Тенант — строка в `centers`. Активный центр пользователя лежит **в JWT**
(`app_metadata.center_id`), а не в теле запроса и не в куке приложения:
подделать его клиент не может, а Postgres читает его в RLS-политиках через
`current_center()`.

```
Браузер ──JWT(center_id)──▶ PostgREST ──▶ RLS: center_id = current_center()
```

Переключение центра — `rpc switch_center(uuid)`: функция проверяет membership,
пишет `center_id` в `auth.users.raw_app_meta_data`. **JWT при этом не меняется**,
поэтому клиент обязан вызвать `supabase.auth.refreshSession()` — иначе запросы
продолжат ходить в старый центр. Это сделано в
`app/onboarding/actions.ts` и `app/select-center/actions.ts`.

Подробнее — [ADR-002](Decisions/ADR-002-tenant-rls.md).

## Роли

`memberships.role` ∈ `owner | admin | teacher | parent`. Один пользователь может
состоять в нескольких центрах с разными ролями — pk по `(user_id, center_id)`.

- `owner` — владелец, единственный, кто может менять сам центр;
- `admin` — полный доступ к данным центра;
- `teacher` — свои занятия и ученики (через `my_teacher_id()`);
- `parent` — свой ребёнок и свои оплаты (через `my_payer_id()`).

Базовая процедура `apply_tenant_rls()` даёт доступ только `owner`/`admin`.
Политики для `teacher`/`parent` пишутся отдельно на каждой таблице — у них
разная логика доступа, общего шаблона не существует.

## Поток аутентификации

```
/login ──▶ email+пароль ─┐
       └─▶ magic link ───┴─▶ /auth/callback ─▶ middleware обновляет сессию
                                                     │
                          нет центров ──▶ /onboarding (create_center)
                          есть центры ──▶ /select-center (switch_center)
                          center_id в JWT ──▶ /app
```

`middleware.ts` вызывает `updateSession()` на каждом запросе: обновляет токен и
редиректит неавторизованных на `/login`. `app/app/layout.tsx` — второй рубеж:
проверяет, что в JWT есть `center_id` и что membership жив (`rpc my_role()`).

## События (outbox)

Побочные эффекты не выполняются внутри транзакции. Вместо этого пишется строка
в `events`, а воркер вычитывает `processed_at is null`. Плюсы: транзакционность,
повторяемость, аудит без внешних систем.

Контракт событий описан в `packages/contracts/src/events.ts` — SQL пишет payload,
TypeScript его валидирует. Подробнее — [ADR-003](Decisions/ADR-003-events-outbox.md).

## Аудит

`apply_audit(tbl)` вешает after-триггер, пишущий в `audit_log` полные `old_data`
и `new_data`. Персональные данные детей — юридически чувствительная категория,
поэтому история изменений включается на каждой таблице с ними.

## Наблюдаемость

Что есть в коде: `GET /api/health` (`apps/web/app/api/health/route.ts`) —
`invitation_preview` с несуществующим токеном (единственная функция,
открытая `anon`; таблиц у `anon` нет — 0024), `{"ok":true}` или `503`;
путь публичный в middleware. Остальное — внешние сервисы, порядок и чек-листы в
[OBSERVABILITY_SETUP.md](OBSERVABILITY_SETUP.md); ссылки заполнить после
настройки:

- Sentry — проект: _ещё не создан_ (ключи — стадия Prod этапа 8).
- UptimeRobot — монитор `/api/health`: _ещё не создан_.
- n8n `alerts` — вебхук в Telegram-группу владельца (`n8n/README.md`):
  _ещё не собран_.
- Лимиты расходов: Supabase Spend Cap, Vercel Spend Management —
  _не подтверждены_.

## Чего здесь намеренно нет

- очередей и брокеров — outbox + cron-воркер закрывают нагрузку MVP;
- ORM — только `@supabase/supabase-js` и SQL (см. [ADR-001](Decisions/ADR-001-monorepo.md));
- микросервисов — один деплой Next.js;
- AI-функций — они за фича-флагом `has_feature('ai_reports')` тарифа `ai`.
