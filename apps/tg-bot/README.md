# @logocrm/tg-bot

Вебхук Telegram: привязка аккаунта, `/today`, `/balance` и кнопка
«Подтвердить приход». Отдельный деплой — Railway, Fly или VPS.

## Переменные окружения

| Переменная | Что это |
|---|---|
| `TELEGRAM_BOT_TOKEN` | токен от @BotFather |
| `TELEGRAM_WEBHOOK_SECRET` | произвольная строка; Telegram шлёт её заголовком, без неё вебхук открыт всем |
| `SUPABASE_URL` | URL проекта |
| `SUPABASE_PUBLISHABLE_KEY` | публичный ключ `sb_publishable_…` (Project Settings → API Keys) — идёт в заголовок `apikey`; шлюз принимает там только штатные ключи проекта, самоподписанный JWT отбивает «Invalid API key» |
| `SUPABASE_BOT_JWT` | JWT с claim `role: bot_worker` — **не** `service_role`; идёт только в `Authorization: Bearer` |
| `PORT` | по умолчанию 8080 |

**Почему не `service_role`.** У него остаются все таблицы: `0024` снимал
гранты только у `public`, `anon` и `authenticated`. Утёкший ключ открыл бы
карточки детей всех центров мимо узких функций 0031. Роль `bot_worker`
(`0032`) не имеет ни одного табличного гранта — только `execute` на пять
функций бота. Подробности — [ADR-008](../../docs/Decisions/ADR-008-event-delivery.md).

## Регистрация вебхука

```bash
curl -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" \
  -H 'Content-Type: application/json' \
  -d "{\"url\":\"https://<хост>/\",\"secret_token\":\"$TELEGRAM_WEBHOOK_SECRET\"}"
```

## Чего здесь нет

Библиотеки бота (промт этапа предполагал grammY): команд три и одна
кнопка, а лишняя зависимость в отдельно деплоимом сервисе — лишний повод
его чинить. Рассылку бот не делает вовсе: сообщения шлёт n8n, забирая
события из очереди.
