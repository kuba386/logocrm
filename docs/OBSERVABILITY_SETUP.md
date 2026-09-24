# Observability & FinOps Setup

Фундамент, который ставится до первой строки бизнес-кода.
Стек: Next.js (App Router) + Supabase + Vercel + n8n.
Время: ~2 часа. Стоимость: $0/мес.

Цели:
- деньги не утекут без ведома (Spend Cap, лимит Vercel);
- любая ошибка в проде приходит в Telegram;
- падение сайта или БД ловится за 5 минут.

---

## Шаг 1. Supabase — Spend Cap (5 мин)

1. supabase.com/dashboard → слева внизу иконка организации → **Organization settings**.
2. Вкладка **Billing** → блок **Cost Control** (или **Spend Cap**).
3. **Spend cap: ON** → Save.
   На Free-плане включён по умолчанию — просто убедиться, что проект не на Pro без капа.
4. **Usage** → запомнить лимиты Free: 500 МБ БД, 5 ГБ egress, 50 000 MAU.

Чеклист: [ ] Spend cap включён.

---

## Шаг 2. Vercel — лимит расходов (5 мин)

1. vercel.com → выбрать команду/аккаунт → **Settings** (верхнее меню).
2. **Billing** → секция **Spend Management** → **Enable**.
3. Лимит `10` USD → галочка **Pause projects when limit is reached** → Save.
4. Там же включить уведомления на 50 % и 100 %.

Чеклист: [ ] Spend Management включён, лимит $10.

---

## Шаг 3. Sentry — ошибки фронта и сервера (20 мин)

1. sentry.io → **Create project** → платформа **Next.js** → имя `logoped-crm` → Create.
2. В корне репо:
   ```bash
   npx @sentry/wizard@latest -i nextjs
   ```
   Ответы мастера:
   - Tracing → Yes
   - Session Replay → No (экономия квоты)
   - Create example page → Yes
3. Мастер создаст:
   - `sentry.client.config.ts`
   - `sentry.server.config.ts`
   - `sentry.edge.config.ts`
   - обновит `next.config.js`
   - `.env.sentry-build-plugin` с `SENTRY_AUTH_TOKEN` — **не коммитить**, он в `.gitignore`.
4. Vercel → Project → **Settings** → **Environment Variables** → добавить:
   - `SENTRY_AUTH_TOKEN` (из `.env.sentry-build-plugin`)
   - `NEXT_PUBLIC_SENTRY_DSN` (из Sentry → Project Settings → Client Keys)
5. Проверка: `npm run dev` → открыть `/sentry-example-page` → нажать кнопку → в Sentry → Issues появилась ошибка.
6. Удалить `app/sentry-example-page/` и `app/api/sentry-example-api/`.
7. Коммит: `feat: подключён Sentry`.

Чеклист: [ ] Тестовая ошибка видна в Sentry. [ ] Example page удалена.

---

## Шаг 4. Health-эндпоинт + UptimeRobot (20 мин)

### 4.1. Эндпоинт

Файл `app/api/health/route.ts`:

```ts
import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'

export const dynamic = 'force-dynamic'

export async function GET() {
  const sb = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!
  )
  // заменить 'tenants' на любую существующую таблицу
  const { error } = await sb.from('tenants').select('id').limit(1)
  if (error) {
    return NextResponse.json({ ok: false, error: error.message }, { status: 503 })
  }
  return NextResponse.json({ ok: true, ts: Date.now() })
}
```

Убедиться, что `SUPABASE_SERVICE_ROLE_KEY` есть в Vercel Environment Variables (только server-side, без `NEXT_PUBLIC_`).

Деплой → открыть `https://<домен>/api/health` → ответ `{"ok":true,...}`.

### 4.2. UptimeRobot

1. uptimerobot.com → **+ New monitor**.
2. Тип **HTTP(s)** → URL = `https://<домен>/api/health` → интервал **5 min**.
3. Advanced → **Keyword monitoring**: keyword `"ok":true`, условие **exists**.
4. Create.
5. Уведомления: **Integrations & API** → **Add integration** → **Telegram** → следовать инструкции бота → привязать к монитору.
   Если Telegram окажется только на платном тарифе — оставить e-mail, Telegram придёт через n8n (шаг 5, п. 6 — webhook от UptimeRobot).

Чеклист: [ ] `/api/health` возвращает ok. [ ] Монитор зелёный. [ ] Уведомление приходит.

---

## Шаг 5. n8n — единый канал алертов в Telegram (30 мин)

### 5.1. Бот и группа

1. Telegram → @BotFather → `/newbot` → сохранить токен.
2. Создать приватную группу **CRM Alerts** → добавить бота → написать любое сообщение.
3. Получить `chat_id`: открыть в браузере
   `https://api.telegram.org/bot<TOKEN>/getUpdates` → найти `"chat":{"id":-100...}`.

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

1. Sentry → **Settings** → **Integrations** → **Webhooks** → Install → Callback URL = Production URL из 5.2 → Save.
2. Sentry → **Alerts** → **Create Alert** → **Issues**:
   - When: `A new issue is created`
   - Then: `Send a notification via Webhooks`
   - Save.
3. Проверка: вызвать тестовую ошибку → сообщение в группе CRM Alerts.

### 5.4. Ошибки других n8n-воркфлоу

Один раз: в каждом будущем воркфлоу → **Workflow Settings** → **Error workflow** = `alerts`.

Либо явно: нода **Error Trigger** → **HTTP Request** POST на Production URL с телом:
```json
{
  "source": "n8n {{ $workflow.name }}",
  "error": "{{ $json.execution.error.message }}"
}
```

Чеклист: [ ] Тест из Sentry пришёл в Telegram. [ ] Error workflow назначен.

---

## Шаг 6. Зафиксировать (10 мин)

- `docs/ARCHITECTURE.md` → раздел **Observability**: Sentry (ссылка на проект), UptimeRobot (ссылка на монитор), n8n `alerts` (ссылка), лимиты расходов.
- `docs/CHANGELOG.md` → запись за сегодня: «Подключены Sentry, UptimeRobot, n8n alerts, включены лимиты Supabase/Vercel».
- `costs.xlsx` → первые строки:

| Сервис | План | Факт/мес | Лимит | Примечание |
|---|---|---|---|---|
| Supabase | Free | 0 | Spend cap ON | |
| Vercel | Hobby | 0 | $10 | Spend Management |
| Sentry | Developer | 0 | 5k ошибок/мес | |
| UptimeRobot | Free | 0 | 50 мониторов | |
| n8n хостинг | | | | |
| Домен | | | | |

---

## Что дальше (не сейчас)

- PostHog + 5 событий — добавлять вместе с каждой фичей.
- `support_tickets` + кнопка «Сообщить о проблеме» — когда появится админка.
- `v_center_metrics`, SLA в оферте, `/changelog`, лимит AI-токенов на тенанта — после первого платящего центра.
