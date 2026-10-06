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

  // С лендинга «Попробовать бесплатно» ведёт на режим регистрации — свой
  // заголовок и главная кнопка, а не вторая кнопка под «Войти».
  await page.goto('/')
  await page.getByRole('link', { name: 'Попробовать бесплатно' }).first().click()
  await expect(page.getByRole('heading', { name: 'Регистрация центра' })).toBeVisible()
  await page.locator('#email').fill(email)
  await page.locator('#password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Зарегистрировать центр' }).click()

  await expect(page).toHaveURL(/\/onboarding(\?|$)/, { timeout: 20_000 })
  await page.locator('#name').fill('Центр регистрации e2e')
  await page.getByRole('button', { name: 'Создать центр' }).click()

  await expect(page).toHaveURL(/^https?:\/\/[^/]+\/app(\/|$)/, { timeout: 20_000 })
  await expect(page.getByRole('heading', { name: 'Настройка центра' })).toBeVisible()
  // Пустой центр: ни кабинета, ни услуги, ни Telegram, ни записи — все восемь шагов открыты.
  await expect(page.getByText('Готово 0 из 8')).toBeVisible()
  await expect(page.getByRole('link', { name: 'Перейти →' })).toHaveCount(8)

  // «Скрыть» — cookie на браузер и центр: после перезагрузки плашка свёрнута
  // в строку с «Показать», а не пропала насовсем.
  await page.getByRole('button', { name: 'Скрыть' }).click()
  await expect(page.getByRole('heading', { name: 'Настройка центра' })).toHaveCount(0)
  await page.reload()
  await expect(page.getByRole('heading', { name: 'Дашборд' })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Настройка центра' })).toHaveCount(0)
  await expect(page.getByText('Настройка центра скрыта — готово 0 из 8')).toBeVisible()

  await page.getByRole('button', { name: 'Показать', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Настройка центра' })).toBeVisible()
})
