# Этап 8 — SaaS: тарифы, лимиты, онбординг, prod

Дата: 2026-09-22 (Plan; код не начат)
PR: —
Миграции: —

## Plan

Раздел написан до кода, по правилу «Перед этапом» (`docs/Roadmap/stages.md`).
Черновик до ревью `architect`; правки после ревью вносятся сюда же.

### 0. Режем на две части, как этап 7

Промт этапа 8 — два разных продукта в одном списке: **то, что делает
LogoCRM продаваемым** (тарифы, лимиты, trial, воронка, публичная запись,
панель платформы) и **то, что делает его безопасно выкатываемым** (второй
Supabase-проект, GitHub Environment `production`, Vercel prod, Sentry,
prod-экземпляры n8n и бота). Первое — код и миграции, проверяемые pgTAP и
кликом на staging. Второе — почти целиком ручные шаги владельца и один
workflow, и его нельзя проверить нигде, кроме самого prod.

| Часть | Что внутри | Что даёт само по себе |
|---|---|---|
| **8a — продукт для продажи** | `plans`, лимиты триггерами, trial и read-only, `platform_payments` + `extend_subscription`, `/app/settings/plan`, баннеры, онбординг-чеклист, воронка (`students.status` ×7 + `funnel_events` + дашборд), `/admin` платформы, экспорт и удаление центра | Второй центр можно завести, ограничить тарифом и продлить по чеку — вручную, но без правок в базе |
| **8b — prod-контур** | `logocrm-prod`, `production` environment, `deploy-prod.yml` по кнопке, Vercel prod и домен, Sentry, n8n/бот prod, ADR-009 production checklist, публичная витрина `/book/[slug]` (последней: она первая смотрит наружу) | Реальный центр работает не на staging |

Порядок: 8a целиком, потом 8b. Довод тот же, что для 7a: 8a не требует
ни одного нового сервиса и ни одного секрета, а 8b упирается в владельца
на каждом шаге (проект Supabase, домен, цены, ручной deploy). Витрина
`/book/[slug]` ушла в 8b сознательно: это первый экран без сессии, его
rate limit и защита от спама — вопросы того же ряда, что prod-firewall,
а не тарифов.

Мультифилиал (`branches`, п. 5 промта) — **не в этом этапе**. Ни у одного
из известных центров второго адреса нет; таблица без потребителя — тот же
класс, что `exercise_library` до `/app/library` (0038 Р10). Записано в
Backlog как кандидат на этап 9+.

### 1. Что меняю (8a)

#### Таблицы

- **`plans`** — справочник платформы, не центра: `code text primary key`
  (`trial`, `solo`, `studio`, `ai`), `name`, `price_som_month integer`
  (сомы, не тыйыны — это цена прайса, а не проводка; в `platform_payments`
  — тыйыны), `limits jsonb not null` (`teachers`, `students`,
  `ai_notes_month`), `features text[]`, `sort`. Без `center_id`, без RLS
  центра: читать может любой авторизованный (нужно на экране «Сменить
  план»), писать — только `platform_admin`. Seed: solo 2000, studio 5000,
  ai 10000 — **цены уточнить у владельца до мержа**.
- **`centers`** — колонки уже есть с 0001: `plan`, `trial_ends_at`,
  `subscription_until`. Добавляется `billing_email text`. Колонка
  `invoices jsonb` из промта **не заводится**: история платежей — это
  `platform_payments`, jsonb-массив рядом с ней разошёлся бы (тот же
  довод, что против `goals_touched` в 0036).
- **`platform_payments`** — `center_id`, `amount_tiyin`, `source text`
  (`mbank`, `elcart`, `cash`, `other`), `receipt_path text` (чек —
  файл в Storage платформы, не центра; первый Storage в проекте — см.
  риски), `months integer check (months between 1 and 12)`, `paid_at`,
  `confirmed_by uuid` (platform_admin), `confirmed_at`, `note`, конвенции.
  Центр видит свои строки (owner/admin), пишет — только
  `submit_platform_payment` (загрузка чека), подтверждает — только
  `extend_subscription` от `platform_admin`.
- **`platform_admins`** — `user_id primary key references auth.users`,
  `created_at`. Роль платформы вне `memberships`: владелец платформы не
  член каждого центра. Предикат `is_platform_admin()` — `security
  definer`, по этой таблице.
- **`funnel_events`** — `student_id`, `center_id`, `from_status`,
  `to_status`, `at`, `by uuid`, `source text`, `reason text`. Пишется
  триггером на `students.status` (и на insert — `from_status null`).
  Денормализованная история: грант только `select`, политик на запись
  нет ни у кого (правило CLAUDE.md про закрытые на запись таблицы).
  Видят owner/admin/registrar; teacher/parent/finance — ни строки
  (коммерческие данные центра).
- **`students.status`** — check расширяется до
  `lead, contacted, consultation, assessment, trial, active, completed,
  paused, archived`. Существующие строки не трогаются. Переход
  `lead → active` при продаже абонемента и при первом посещении — в
  триггерах на `subscriptions` и `attendance`, не в RPC (иначе воронка
  разойдётся с фактом, как расходился `status='frozen'`, 0015).

#### Лимиты и trial — инварианты, не проверки

- **Лимит специалистов** — триггер `before insert or update` на
  `memberships` (role = teacher) и на `teachers` (живая карточка):
  считает живых по центру, сравнивает с `plans.limits->>'teachers'`
  текущего плана, отказ `23514` с русским текстом «Тариф Solo: 1
  специалист. Перейдите на Studio». `null` в лимите = без ограничения.
- **Лимит учеников** — тот же триггер на `students` (status not in
  archived/completed, deleted_at null).
- **Лимит AI-заметок в месяц** — `check_ai_quota(center_id)` из промта
  этапа 7, отложенная в 0042 (там прямо сказано «место — в
  `ai_job_begin`, до траты»). Считает `ai_usage` за календарный месяц
  центра; при превышении `ai_job_begin` возвращает `null` **с причиной**
  — новый ключ ответа `refused: 'quota'`, чтобы воркер сказал
  специалисту «лимит ИИ-заметок на этом тарифе исчерпан», а не молчал
  (урок 0047: тишина неотличима от «всё доставлено»).
- **Trial и просрочка** — предикат `center_writable()` (security
  definer): `plan = 'trial' and trial_ends_at > now()` или `plan <>
  'trial' and coalesce(subscription_until, 'infinity') > now()`. Он
  добавляется в `with check` политик записи через переиздание
  `apply_tenant_rls`/`apply_role_rls` — **не** в каждую RPC по одной
  (это как раз «проверка в функции», которую обходят). owner при
  просрочке сохраняет право на `submit_platform_payment` и на чтение;
  все остальные роли — только чтение. Событие `trial.ending` — за 3 дня,
  из `schedule`-сценария n8n (уже есть, раз в час), доставка owner через
  `notification_admin_targets` и шаблон по умолчанию.
- Переход `trial → paid` и продление — только `extend_subscription(center,
  months)` от `platform_admin`: `subscription_until = greatest(now(),
  subscription_until) + months`, `plan` из платежа, строка
  `platform_payments.confirmed_*`, событие `subscription.extended`.

#### Функции

`is_platform_admin()`, `center_writable()`, `check_ai_quota(uuid)`,
`submit_platform_payment(amount_tiyin, source, months, receipt_path)`,
`extend_subscription(center_id, payment_id)`, `set_center_plan_request`
(заявка на смену плана — строка в `platform_payments` без чека),
`export_center()` → jsonb всех таблиц центра (owner; каждая таблица —
через её же RLS, не через `security definer` без фильтра: экспорт — это
вынос базы клиентов, Backlog про это уже спрашивал),
`request_center_deletion()` → `deleted_at` + событие; физическая очистка
через 30 дней — cron-сценарий n8n, не в этом этапе (первый cron с
`delete` в проекте, ему нужен свой ADR).
`funnel_summary(from, to)` → шаги, переходы, конверсия, среднее время на
шаге, застрявшие — одним запросом по `funnel_events`, не по `students`.

#### Экраны

- `/app/settings/plan` — план, лимиты с прогрессом (число/лимит),
  «Сменить план», история `platform_payments`, «Оплатить»: реквизиты
  Mbank/Elcart QR из настроек платформы + загрузка чека → владельцу
  платформы в Telegram (событие `platform.payment_submitted`, адресат —
  `platform_admins` с привязкой) → он продлевает в `/admin`.
- Баннеры trial/expired в `app/layout.tsx` — по `center_writable()` и
  дате, один компонент, три состояния (осталось N дней / истёк, только
  чтение / продлено до).
- Онбординг-чеклист на дашборде owner/admin: специалист → услуга →
  ученик → занятие → посещение. Галочки — по `count(*)` живых строк, без
  отдельной таблицы «прогресса онбординга»: она разошлась бы с фактом.
- `/app/funnel` (owner/admin/registrar): дашборд конверсии из
  `funnel_summary`, застрявшие отдельным списком с кнопкой WhatsApp.
- `/admin` (`platform_admin`, отдельный layout без выбора центра): список
  центров, план, срок, заявки на оплату с чеком, «Продлить», MRR по
  `platform_payments`.
- Лендинг — перенос из старого репо в `apps/landing`, CTA → регистрация.
  Отдельный PR, без базы.

### 2. Риски

1. **`center_writable()` в `with check` всех политик записи.** Самая
   широкая правка RLS с 0028: переиздаются `apply_tenant_rls` и
   `apply_role_rls` и все таблицы прогоняются заново. Ошибка здесь —
   либо просроченный центр продолжает писать, либо живой центр перестаёт.
   Забор pgTAP 0031 по `pg_policies` обязан пройти без правок списка;
   отдельный тест — центр с `trial_ends_at` в прошлом под каждой ролью.
2. **Лимиты триггерами и гонка.** Два параллельных `insert` специалиста
   при лимите 1 оба видят «0 живых» — тот же класс, что 0012 unique
   violation. Закрывать не `count(*)`, а `advisory lock` по центру
   внутри триггера либо `serializable`; выбор — на ревью.
3. **Первый Storage в проекте** (чеки). 7c его избежал (видео через
   WhatsApp). Здесь избежать нельзя: чек — доказательство платежа.
   Bucket платформы, путь `center_id/…`, политика чтения только
   `platform_admin` и owner своего центра. Отдельный шаг с отдельной
   приёмкой, до экрана оплаты.
4. **Роль вне `memberships`.** `is_platform_admin()` — первая проверка,
   не привязанная к центру; каждая RPC `/admin` начинается с неё, а не с
   `current_center()`. Легко забыть `revoke` — 0003 существует ровно
   поэтому; `0007_function_grants` пополняется всеми новыми функциями.
5. **Расширение `students.status`.** Семь шагов вместо четырёх задевают
   каждый экран, где статус рендерится словом и цветом
   (`STUDENT_STATUS_CLASSES`, `statusLabel`, фильтры списков,
   `students_teacher_view`, дашборд родителя после #104). Экраны этапов
   2–5 не покрыты Playwright целиком — риск тихого «undefined» в бейдже.
6. **Лимит AI в `ai_job_begin`** — функция переиздаётся третий раз за
   неделю (0042, 0048). Каждое переиздание — риск потерять условие; тест
   0048 держит состав ключей, добавить ассерт на `refused`.

### 3. Что может задеть

- `apply_tenant_rls` / `apply_role_rls` — все таблицы центра (риск 1).
- `ai_job_begin` (0048) — квота.
- `students` — check по статусу; триггеры на `subscriptions` и
  `attendance` для автоперехода `lead → active`.
- `app/layout.tsx` — баннер и онбординг; `students/*` — статусы.
- `n8n` `schedule` — `trial.ending`; `event_messages` — три новых типа
  (`trial.ending`, `subscription.extended`, `platform.payment_submitted`)
  с шаблонами, швом и переменными по каналу (0047 Р1/Р7 — правило
  записано в `docs/Database.md`).
- **teacher и parent:** при просрочке центра теряют запись целиком —
  это ожидаемо, но `complete_lesson` и `submit_homework` должны отдавать
  русский текст «Подписка центра истекла — обратитесь к администратору»,
  а не голый 42501; ошибка разбирается в `apps/web/lib/errors.ts`, не в
  компонентах. Специалист не видит ни планов, ни платежей, ни воронки.

### 4. Критерии готовности

Чек-лист этапа из `stages.md`, пункты 1–3 и 5 (4 и 6 — в 8b), плюс
pgTAP:

- лимит: второй специалист на solo — `23514` с русским текстом; после
  `extend_subscription` на studio — проходит; гонка двух вставок даёт
  ровно одну;
- trial: `trial_ends_at` в прошлом — teacher не отмечает посещение,
  registrar не создаёт ученика, owner читает и подаёт чек; после
  продления всё возвращается; чужой центр не задет;
- воронка: продажа абонемента переводит `lead → active` и пишет
  `funnel_events` с обоими статусами; teacher/parent/finance не видят
  `funnel_events` вовсе; `funnel_summary` считает конверсию по истории,
  а не по текущему `students.status`;
- квота ИИ: `ai_job_begin` возвращает `refused: 'quota'` при исчерпании и
  не заводит `ai_jobs`;
- `platform_admin`: `extend_subscription` от owner центра — `42501`;
  `export_center` от admin — все таблицы центра и ни одной строки чужого;
- гранты всех новых функций закреплены в `0007_function_grants`.

### Требует пользователя

- Цены тарифов (seed `plans`) и лимиты по каждому — до мержа первой
  миграции 8a.
- Реквизиты Mbank/Elcart для экрана оплаты и Telegram владельца платформы
  (кто получает чеки).
- Решение по мультифилиалу: подтвердить перенос в этап 9+.
- Для 8b — всё из «Требует пользователя» промта этапа: prod-проект
  Supabase, секреты `production`, домен, Vercel, Sentry, ручной
  deploy-prod.
