# Codespace: проверка базы за минуты

На машине разработки нет Docker, поэтому pgTAP раньше гонял только CI
(10–12 минут на прогон). В Codespace Docker есть.

```bash
pnpm db:check
```

Делает то же, что джоб `db` в CI: проверка номеров миграций, `supabase start`
(первый раз — несколько минут на образы), `supabase db reset` с нуля и
`supabase test db`. Повторный запуск базу заново не поднимает — только reset
и тесты.

Один файл тестов: `pnpm db:check supabase/tests/0084_platform_prepay_discount.test.sql`.

Codespace тратит бесплатную квоту GitHub (машина на 2 ядра — около 60 часов в
месяц). Останавливайте его, когда не нужен: github.com/codespaces.
