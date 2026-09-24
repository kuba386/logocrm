# Observability & FinOps Setup

Наблюдаемость и лимиты расходов для LogoCRM. Стек: Next.js 15 (App Router,
`apps/web`) + Supabase (облачный проект `logocrm`) + Vercel (`logocrm-web`)
+ n8n (сценарии в `n8n/README.md`). Время: ~2 часа. Стоимость: $0/мес.

Цели:
- деньги не утекут без ведома (Spend Cap Supabase, Spend Management Vercel);
- любая ошибка в проде приходит в Telegram;
- падение сайта или базы ловится за 5 минут.

Что уже сделано в коде (этим же PR): `GET /api/health`, путь открыт в
middleware, `.env.sentry-build-plugin` в `.gitignore`. Всё остальное —
ключи и тумблеры дашбордов, которые по CLAUDE.md делает только владелец;
план относит их к стадии Prod этапа 8 (`docs/Roadmap/stages.md`: «Sentry
DSN», «Sentry ловит тестовую ошибку», «Требует пользователя: … ключи
Sentry»).

Чек-лист сверен с репозиторием 24.09.2026: пути, имена файлов, команды и
таблица тенанта (`centers`, не `tenants`) — по факту кода.

---

## Шаг 1. Supabase — Spend Cap (5 мин, владелец)

Проект `logocrm` (`hiwstqrnxrlfuanvfggq`, регион `ap-south-1`).

1. supabase.com/dashboard → слева внизу иконка организации → **Organization settings**.
2. Вкладка **Billing** → блок **Cost Control** (или **Spend Cap**).
3. **Spend cap: ON** → Save.
   На Free-плане включён по умолчанию — убедиться, что проект не на Pro без капа.
4. **Usage** → запомнить лимиты Free: 500 МБ БД, 5 ГБ egress, 50 000 MAU.

Чеклист: [ ] Spend cap включён.

---

## Шаг 2. Vercel — лимит расходов (5 мин, владелец)

Проект `logocrm-web`.

1. vercel.com → команда/аккаунт → **Settings** (верхнее меню).
2. **Billing** → **Spend Management** → **Enable**.
3. Лимит `10` USD → галочка **Pause projects when limit is reached** → Save.
4. Там же включить уведомления на 50 % и 100 %.

Чеклист: [ ] Spend Management включён, лимит $10.

---

## Шаг 3. Sentry — ошибки фронта и сервера (20 мин, владелец)

1. sentry.io → **Create project** → платформа **Next.js** → имя `logocrm` → Create.
2. Мастер запускается **в `apps/web`**, не в корне монорепо — иначе он не
   найдёт `next.config.mjs` и положит файлы не туда:
   ```bash
   cd apps/web && npx @sentry/wizard@latest -i nextjs
   ```
   Ответы мастера:
   - Tracing → Yes
   - Session Replay → No (экономия квоты)
   - Create example page → Yes
3. Мастер создаст (набор зависит от версии мастера):
   - `instrumentation-client.ts` (или `sentry.client.config.ts` в старых версиях)
   - `sentry.server.config.ts`, `sentry.edge.config.ts`, `instrumentation.ts`
   - `app/global-error.tsx` — в проекте его сейчас нет, мастер добавит
   - обновит `next.config.mjs` (у нас `.mjs`, не `.js`)
   - `.env.sentry-build-plugin` с `SENTRY_AUTH_TOKEN` — **не коммитить**;
     уже в `.gitignore` (под `.env*.local` он не попадал, добавлен явно).
4. Vercel → Project `logocrm-web` → **Settings** → **Environment Variables**:
   - `SENTRY_AUTH_TOKEN` (из `.env.sentry-build-plugin`)
   - `NEXT_PUBLIC_SENTRY_DSN` (Sentry → Project Settings → Client Keys)
5. Проверка: `pnpm dev` → открыть `http://127.0.0.1:3000/sentry-example-page`
   (LogoCRM живёт на `127.0.0.1`, не `localhost` — CLAUDE.md) → нажать
   кнопку → в Sentry → Issues появилась ошибка.
6. Удалить `apps/web/app/sentry-example-page/` и `apps/web/app/api/sentry-example-api/`.
7. Коммит: `feat(web): подключён Sentry`. `pnpm typecheck` и `pnpm lint`
   должны остаться зелёными — мастер иногда оставляет неиспользуемые
   импорты.

Чеклист: [ ] Тестовая ошибка видна в Sentry. [ ] Example page удалена.
[ ] `typecheck`/`lint` зелёные.

---

## Шаг 4. Health-эндпоинт + UptimeRobot (10 мин)

### 4.1. Эндпоинт — уже в коде

`apps/web/app/api/health/route.ts`. Отличия от типового примера — по делу:

- **Публичный ключ, не `service_role`.** `SUPABASE_SERVICE_ROLE_KEY` в
  приложении нет и не будет: у этой роли остаются все таблицы, её утечка
  открыла бы карточки детей всех центров (ADR-008, `n8n/README.md`).
  Ключ берётся из `supabaseEnv()` — тот же `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
  / `NEXT_PUBLIC_SUPABASE_ANON_KEY`, что у всего приложения; новых
  переменных в Vercel не нужно.
- **Не `select` по таблице, а `invitation_preview` с заведомо
  несуществующим токеном.** Типовой пример `sb.from('tenants')` здесь не
  работает дважды: тенант называется `centers`, а главное — у `anon` нет
  ни одного права ни на одну таблицу (`0024`, проверено живым запросом:
  `permission denied for table centers`). Единственное, что `anon` вправе
  вызвать до входа, — `invitation_preview` (`0004`), и pgTAP `0007`
  держит этот список ровно из одной функции. На неизвестный токен она
  отвечает строкой `(null, null, false)` без исключения — это реальный
  запрос `invitations ⋈ centers` через Postgres, ничего не раскрывает и не
  требует ни новых грантов, ни миграции. Эндпоинт считает базу живой,
  только если пришла ровно одна строка с `valid=false`.
- **Путь открыт в middleware** (`PUBLIC_PATHS` в
  `apps/web/lib/supabase/middleware.ts`). Без этого запрос без сессии
  получал бы `307` на `/login`, и keyword-проверка монитора не прошла бы
  никогда.
- Таймаут 5 с: зависший Postgres даёт `503` с текстом, а не бесконечное
  ожидание монитора.

Проверка после деплоя:
```bash
curl -s https://<домен>/api/health
# {"ok":true,"ts":...}
```
Ответ `{"ok":false,"error":"..."}` со статусом 503 — база не отвечает.

### 4.2. UptimeRobot (владелец)

1. uptimerobot.com → **+ New monitor**.
2. Тип **HTTP(s)** → URL = `https://<домен>/api/health` → интервал **5 min**.
3. Advanced → **Keyword monitoring**: keyword `"ok":true`, условие **exists**.
4. Create.
5. Уведомления: **Integrations & API** → **Add integration** → **Telegram**
   → следовать инструкции бота → привязать к монитору.
   Если Telegram окажется только на платном тарифе — alert contact типа
   **Webhook** на Production URL сценария `alerts` (шаг 5.2), тело
   `{"source":"uptimerobot","monitor":"*monitorFriendlyName*","status":"*alertTypeFriendlyName*"}`
   — сообщение соберёт та же нода Code.

Чеклист: [ ] `/api/health` возвращает ok. [ ] Монитор зелёный.
[ ] Уведомление приходит.

---

## Шаг 5. n8n — единый канал алертов в Telegram (30 мин, владелец)

Форма сценария зафиксирована в `n8n/README.md` (раздел «Сценарий
`alerts`»), как и остальные сценарии — описанием, не JSON-экспортом
(ADR-008). Здесь — порядок настройки.

### 5.1. Бот и группа

Второй бот не нужен: у проекта уже есть бот (`TELEGRAM_BOT_TOKEN` в
`apps/tg-bot` и в n8n) — тот же токен шлёт и родителям, и в группу
алертов. Разделяет их не бот, а чат.

1. Создать приватную группу **LogoCRM Alerts** → добавить бота →
   написать любое сообщение.
2. Получить `chat_id`: открыть в браузере
   `https://api.telegram.org/bot<TOKEN>/getUpdates` → найти
   `"chat":{"id":-100...}` (у групп он отрицательный).

Если всё же хочется отдельный бот (например, чтобы у родительского не было
доступа к служебной группе) — @BotFather → `/newbot`, и тогда у n8n
появляется второй Telegram-креденшел.

### 5.2. Воркфлоу `alerts`

1. n8n → **New workflow** → имя `alerts`.
2. Нода **Webhook**:
   - HTTP Method: `POST`
   - Path: `alerts`
   - Respond: `Immediately`
   - Скопировать **Production URL**.
3. Нода **Code** (после Webhook):
   ```js
   const b = $json.body;
   const text = b.event?.title
     ? `🔴 Sentry: ${b.event.title}\n${b.url}`
     : `⚠️ ${b.source ?? 'alert'}: ${JSON.stringify(b).slice(0, 500)}`;
   return [{ json: { text } }];
   ```
4. Нода **Telegram** → операция **Send Message**:
   - Credentials: токен бота из 5.1
   - Chat ID: из 5.1
   - Text: `{{ $json.text }}`
5. **Activate** workflow.

### 5.3. Sentry → n8n

1. Sentry → **Settings** → **Integrations** → **Webhooks** → Install →
   Callback URL = Production URL из 5.2 → Save.
2. Sentry → **Alerts** → **Create Alert** → **Issues**:
   - When: `A new issue is created`
   - Then: `Send a notification via Webhooks`
   - Save.
3. Проверка: вызвать тестовую ошибку → сообщение в группе.

### 5.4. Ошибки остальных сценариев n8n

У `poll`, `schedule` и `watchdog` (все три описаны в `n8n/README.md`):
**Workflow Settings** → **Error workflow** = `alerts`. Один раз на каждый
сценарий — и любой упавший прогон (не поднялся PostgREST, отвалился
Telegram API, сломался промт) приходит в ту же группу.

Либо явно: нода **Error Trigger** → **HTTP Request** POST на Production URL
с телом:
```json
{
  "source": "n8n {{ $workflow.name }}",
  "error": "{{ $json.execution.error.message }}"
}
```

Чеклист: [ ] Тест из Sentry пришёл в Telegram. [ ] Error workflow назначен
трём сценариям.

---

## Шаг 6. Зафиксировать (10 мин)

- `docs/Architecture.md` (именно так, с одной заглавной — файл
  чувствителен к регистру в CI) → раздел **Наблюдаемость** уже есть с
  плейсхолдерами: вписать ссылки на проект Sentry, монитор UptimeRobot,
  сценарий `alerts`, и подтвердить лимиты расходов.
- `docs/CHANGELOG.md` → запись «Подключены Sentry, UptimeRobot, n8n
  alerts, включены лимиты Supabase/Vercel» — когда всё реально подключено;
  запись об эндпоинте и чек-листе уже есть.
- Стоимость — таблица ниже. Отдельного `costs.xlsx` в репозитории нет и
  заводить не стоит: бинарник не диффится; если нужна таблица вне репо —
  копия этой.

| Сервис | План | Факт/мес | Лимит | Примечание |
|---|---|---|---|---|
| Supabase | Free (уточнить) | 0 | Spend cap ON | проект `logocrm`, ap-south-1 |
| Vercel | Hobby (уточнить) | 0 | $10 | Spend Management, проект `logocrm-web` |
| Sentry | Developer | 0 | 5k ошибок/мес | |
| UptimeRobot | Free | 0 | 50 мониторов | |
| n8n хостинг | | | | |
| Домен | | | | |

---

## Что дальше (не сейчас)

Ничего из этого в `docs/Roadmap/stages.md` нет — решает владелец, агент
сам не берёт.

- PostHog + 5 событий — добавлять вместе с каждой фичей.
- `support_tickets` + кнопка «Сообщить о проблеме» — `/admin` уже есть
  (этап 8a), место для кнопки появилось.
- `v_center_metrics`, SLA в оферте, `/changelog`, лимит AI-токенов на
  тенанта — после первого платящего центра. Лимит голосовых резюме по
  тарифу уже есть (0053, `ai_notes_month`) — это про число резюме, не про
  токены.
