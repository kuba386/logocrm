import { expect, test } from '@playwright/test'

import { PASSWORD } from './fixtures'

// Путь нового центра с нуля: регистрация → создание центра → плашка
// «Настройка центра» с восемью шагами. Подтверждение почты в CI выключено
// (config.toml, ADR-004) — регистрация сразу даёт сессию; шаг с кодом из
// письма здесь не проверяется, он живёт только на prod.
//
// Почта уникальна на прогон: база CI свежая, но локальный повтор на той же
// базе иначе упал бы на «уже зарегистрирован».

test.use({ storageState: { cookies: [], origins: [] } })

test('Регистрация центра: аккаунт → центр → чеклист настройки', async ({ page }) => {
  const email = `signup-${Date.now()}@logocrm.kg`

  await page.goto('/login')
  await page.locator('#email').fill(email)
  await page.locator('#password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Зарегистрироваться' }).click()

  await expect(page).toHaveURL(/\/onboarding(\?|$)/, { timeout: 20_000 })
  await page.locator('#name').fill('Центр регистрации e2e')
  await page.getByRole('button', { name: 'Создать центр' }).click()

  await expect(page).toHaveURL(/^https?:\/\/[^/]+\/app(\/|$)/, { timeout: 20_000 })
  await expect(page.getByRole('heading', { name: 'Настройка центра' })).toBeVisible()
  // Пустой центр: ни кабинета, ни услуги, ни Telegram, ни записи — все восемь шагов открыты.
  await expect(page.getByText('Готово 0 из 8')).toBeVisible()
  await expect(page.getByRole('link', { name: 'Перейти →' })).toHaveCount(8)

  // «Скрыть» — cookie на браузер и центр: после перезагрузки плашки нет.
  await page.getByRole('button', { name: 'Скрыть' }).click()
  await expect(page.getByRole('heading', { name: 'Настройка центра' })).toHaveCount(0)
  await page.reload()
  await expect(page.getByRole('heading', { name: 'Дашборд' })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Настройка центра' })).toHaveCount(0)
})
