# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версии — [SemVer](https://semver.org/lang/ru/).

## [Unreleased]

### Этап 2 — ученики и плательщики

- `0005_students.sql`: таблицы `payers` и `students`; витрины
  `students_teacher_view` и `payers_with_stats`; функции `normalize_kg_phone`,
  `age_years`, `payer_display_name`, `find_payer_by_phone`,
  `create_student_with_payer`, `archive_student`, `restore_student`,
  `was_access_revoked`.
- Колоночная приватность: телефоны родителей вынесены в `payers`, специалисту
  таблица закрыта RLS, а в его витрине контактных колонок нет физически —
  [ADR-005](Decisions/ADR-005-column-privacy.md).
- Уникальный индекс на нормализованный телефон плательщика внутри центра.
- `@logocrm/core`: `phone.ts` (`normalizeKgPhone`, `formatKgPhone`,
  `whatsappNumber`) и `age.ts` (`ageYears`, `ageParts`, `ageLabel` со склонением).
- `apps/web`: `/app/students` (список с ролевым набором колонок), карточка
  ученика, `/app/payers` и карточка плательщика, диалог добавления ученика в два
  шага с поиском плательщика по телефону, экран `/access-revoked`.
- Корневые скрипты `pnpm db:link` и `pnpm db:push`.

Найдено на прогоне: витрина специалиста с `join payers` отдавала ноль строк —
`security_invoker` выполняет соединение правами вызывающего, а `payers` ему
закрыта. Заменено на `payer_display_name()`.

### Этап 1 — сотрудники и приглашения

- `0004_staff.sql`: таблицы `teachers` и `invitations`; функции
  `invitation_preview`, `accept_invitation`, `create_invitation`,
  `revoke_membership`, `change_member_role`, `user_email`; витрины
  `staff_view` и `pending_invitations_view` (обе `security_invoker`).
- `apply_tenant_rls` получил параметр `p_soft_delete` — для таблиц без
  `deleted_at`. Старая одноаргументная версия удалена, иначе вызов стал бы
  неоднозначным.
- pgTAP `0004_staff.test.sql`: 14 проверок (изоляция специалиста, просроченный
  и повторный токен, ограничения администратора, последний владелец).
- `@logocrm/contracts`: события `membership.revoked`, `membership.role_changed`,
  `invitation.created`; DTO приглашений и смены роли.
- `apps/web`: экран `/app/settings/staff`, публичная страница `/invite/[token]`,
  приём приглашения после magic link через httpOnly-куку, ссылка «Сотрудники»
  в шапке для владельца и администратора.

Нумерация миграции — 0004, а не 0002: номера 0002 и 0003 заняты миграциями
безопасности этапа 0.

## [0.1.0] — 2026-09-07

Скелет мультитенантного SaaS. Функциональности CRM ещё нет — есть фундамент.

### Добавлено

- pnpm-монорепа: `apps/web`, `packages/db`, `packages/core`, `packages/contracts`.
- Миграция `0001_foundation.sql`:
  - `centers` — тенант с тарифами `trial | solo | studio | ai` и триальным
    периодом 14 дней;
  - `memberships` — роли `owner | admin | teacher | parent`;
  - `current_center()`, `my_role()`, `my_teacher_id()`, `my_payer_id()`,
    `has_feature()`, `switch_center()`, `create_center()`;
  - `apply_tenant_rls(tbl)` — единая политика тенанта для будущих таблиц;
  - `audit_log` + `apply_audit(tbl)` — полная история изменений;
  - `events` + `emit_event()` — transactional outbox;
  - RLS на `centers`, `memberships`, `audit_log`, `events`.
- pgTAP-тесты изоляции тенантов и outbox (`0001_foundation.test.sql`).
- `@logocrm/core`: работа с деньгами в тыйынах (`toTiyin`, `toSom`, `lessonPrice`).
- `@logocrm/contracts`: zod-схемы событий (`center.created`, `membership.created`,
  тип `AppEvent`) и входных DTO.
- `apps/web`: вход по паролю и magic link, онбординг с созданием центра,
  переключение центров, оболочка `/app` с проверкой роли. Интерфейс на русском.
- CI: lint / typecheck / vitest + отдельный job с `supabase db reset` и pgTAP.
- Документация: `Architecture.md`, `Database.md`, ADR-001…003.

### Исправлено

- `0002_lock_down_functions.sql` — `emit_event` требует авторизации и членства
  в центре. До этого функция была доступна анониму и принимала произвольный
  `center_id`: любой мог писать события в outbox чужого центра. Там же —
  `set search_path` у `apply_tenant_rls` и `apply_audit`.
- `0003_revoke_public_execute.sql` — снят дефолтный `GRANT EXECUTE TO PUBLIC`.
  Без него revoke от роли `anon` не давал ничего: `anon` входит в `PUBLIC`.
- `seed.sql` — токен-колонки `auth.users` заполняются пустой строкой. При NULL
  GoTrue отвечает 500 «Database error querying schema», и вход не работает.

### Известные ограничения

- pgTAP-тесты локально не прогонялись: на машине разработки нет Docker
  (macOS 13 не тянет Docker Desktop, Colima собирается из исходников).
  Вместо них те же проверки выполнены напрямую на облачной базе — все прошли.
  Первый запуск `pnpm db:test` на машине с Docker всё равно обязателен.
- ESLint зафиксирован на 8.x (`.eslintrc.json`), потому что `eslint-config-next`
  здесь используется в eslintrc-режиме. Переход на ESLint 9 + flat config —
  отдельная задача.
