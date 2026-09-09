# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версии — [SemVer](https://semver.org/lang/ru/).

## [Unreleased]

### Исправлено

- `apps/web/app/app/schedule/page.tsx` — ученики и группы запрашивались только
  для owner и admin. Специалист и родитель видели карточку занятия без имени
  ребёнка: «11:00 Занятие». Запрос сделан безусловным, границы держит RLS —
  `students_teacher_read_own` отдаёт специалисту его учеников,
  `students_parent_read_own` родителю его детей.
- `apps/web/app/app/schedule/lesson-panel.tsx` — селект замены имел `id`,
  совпадающий с селектом «Специалист» в диалоге создания. Дубль `id` на одной
  странице ломает связь подписи с полем: туда уходит и скринридер, и
  автотест. Переименован в `substituteTeacherId`, `name` сохранён.

### Конвейер

- Деплой в staging стал переиспользуемым workflow, а CI вызывает его джобом
  с `needs: [db]`. Гарантия «деплой не может опередить pgTAP» теперь держится
  зависимостью между джобами. Раньше деплой гейтился успехом всего прогона
  CI — после появления приёмочных тестов красный Playwright останавливал бы
  выкладку корректной схемы.
- `cancel-in-progress` отключён на `main`: деплой переехал внутрь прогона CI,
  и второй пуш подряд убил бы `supabase db push` посреди применения.
- **Секретом стал пароль, а не вся строка подключения.** Достаточно положить
  `SUPABASE_DB_PASSWORD` в Environments → staging — ref проекта, имя
  пользователя пулера и хост workflow подставляет сам, пароль кодирует сам.
  Это закрывает все четыре ошибки, на которых деплой уже спотыкался: чужой
  проект, имя пользователя без ref, Direct connection вместо пулера и
  непроцентованный пароль. `SUPABASE_DB_URL` продолжает работать как запасной
  путь, с проверкой, что строка ведёт в нужный проект.
- По итогам аудита конвейера: ручной `workflow_dispatch` разрешён только с
  `main` (иначе он обходил `needs`), деплой ждёт и `app` — там Vitest-зеркала
  SQL-логики, — гейт по проекту сравнивает разобранный ref, а не подстроку
  всей строки, `supabase/setup-cli` ставится до появления строки подключения
  в окружении джоба, шаг «Что будет применено» показывает `db push --dry-run`,
  состояние после применения печатается и при падении, у всех джобов
  `timeout-minutes`. В Playwright в CI один повтор и таймаут 90 с; `parent`
  идёт строго после `teacher`, потому что оба читают одну неделю фикстуры.
- README описывал снятый механизм `workflow_run` и вёл к секрету
  `SUPABASE_DB_URL` через Direct connection — ровно тому, что ломало деплой.
  Раздел переписан под текущий конвейер. `.env.example` и README называли
  ключ Supabase по-разному; теперь оба имени, приложение читает любое.
  У обоих workflow `permissions: contents: read`.

### Безопасность

- `0007_lock_down_participant_functions.sql` — сняты гранты у `public`, `anon`
  и `authenticated` с четырёх служебных функций: `rebuild_lesson_participants`,
  двух триггерных функций состава и `lesson_slot_conflicts`. В `0006` строка
  `revoke ... from public, anon` не сняла грант с `authenticated`, а Supabase
  выдаёт его по умолчанию — функции остались доступны любому залогиненному
  пользователю через `/rest/v1/rpc/`. Опаснее прочих было
  `rebuild_lesson_participants`: `security definer` без проверок, принимает
  произвольный `lesson_id` и в тексте исключения возвращает ФИО ребёнка —
  оракул по именам между тенантами. Нашёл линтер Supabase после применения
  `0006`. Там же — guard по `pg_trigger_depth()` внутри функции, чтобы
  неосторожный `grant` в будущем не открыл её снова.
- `tests/0007_function_grants.test.sql` — «забор» по `has_function_privilege`:
  для каждой из трёх ролей зафиксирован белый список исполняемых функций.
  Любая новая функция ломает тест, пока автор явно не решит, кому она видна.
- `tests/rls_smoke.test.sql` — под каждой ролью простой `select` из каждой
  таблицы с RLS. Список таблиц берётся из `pg_tables`, поэтому таблица из
  будущей миграции попадает под проверку сама. Ловит рекурсию политик,
  вызов функции, объявленной ниже по файлу, и таблицу без RLS.


### Этап 3 — расписание

- `0006_schedule.sql`: `rooms`, `services`, `groups`, `group_students`,
  `lessons` с `effective_teacher_id` и двумя EXCLUDE, `lesson_participants`
  с триггерами и EXCLUDE по ребёнку; функции серий, отмены, замены, переноса,
  отпуска и смены статуса.
- Накладки ловит база: специалист (включая замену), кабинет, ребёнок —
  в том числе пара «групповое + индивидуальное», которую `EXCLUDE` на
  `lessons` не видел вовсе. [ADR-006](Decisions/ADR-006-lesson-participants.md).
- `@logocrm/core/schedule`: `generateSeriesDates`, `overlaps`,
  `findSelfOverlap`, работа с часовым поясом через `Intl` без новых
  зависимостей.
- `apps/web`: `/app/schedule` (неделя, фильтры, диалог с предпросмотром
  занятости, панель занятия), `/app/settings/services`, `/app/settings/rooms`,
  `/app/groups`, отпуск в карточке сотрудника.
- `lib/errors.ts` — единственное место разбора ошибок Postgres.

Найдено в CI: политики `students`, `lessons` и `lesson_participants`
замкнулись в круг и дали `infinite recursion detected in policy`. Ломался
и этап 2 — специалист переставал видеть учеников. Разорвано
`security definer`-функциями, правило записано в ADR-006.

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
