import { expect, test, type Page } from '@playwright/test'

import { PASSWORD, USERS } from './fixtures'

// Ручные действия платформы над центрами (0099): продлить и сменить тариф
// вручную → удалить → восстановить. Свой центр фикстуры («Центр платформы
// e2e», c9) — сценарии центра e2e не задевает. Права, даты и причины решает
// база (pgTAP 0099); здесь — что интерфейс пульта доводит действие до базы и
// показывает результат.

test.use({ storageState: { cookies: [], origins: [] } })

const CENTER = 'Центр платформы e2e'

/** ГГГГ-ММ-ДД через n дней в поясе центра (Asia/Bishkek). */
function dayInBishkek(addDays: number): string {
  const d = new Date(Date.now() + addDays * 86_400_000)
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Bishkek' }).format(d)
}

async function signInAsPlatform(page: Page) {
  await page.goto('/login')
  await page.locator('#email').fill(USERS.platform)
  await page.locator('#password').fill(PASSWORD)
  await page.getByRole('button', { name: 'Войти', exact: true }).click()
  // Без центра вход уводит на онбординг или выбор центра — нам нужен пульт.
  await expect(page).not.toHaveURL(/\/login(\?|$)/, { timeout: 20_000 })
  await page.goto('/admin')
  await expect(page.getByRole('heading', { name: 'Центры', exact: true })).toBeVisible({ timeout: 20_000 })
}

test('Пульт: продлить вручную, удалить и восстановить центр', async ({ page }) => {
  await signInAsPlatform(page)

  // Строка центра — с кнопкой «Действия»: название центра есть и в строках журнала.
  const centerRow = () =>
    page.getByRole('row').filter({ hasText: CENTER }).filter({ has: page.getByRole('button', { name: 'Действия' }) })
  const row = centerRow()
  await expect(row).toBeVisible()

  // 1. Продлить и сменить тариф вручную.
  await row.getByRole('button', { name: 'Действия' }).click()
  const dialog = page.locator('dialog[open]')
  const grant = dialog.locator('form').filter({ hasText: 'Продлить или сменить тариф вручную' })
  await grant.getByLabel('Тариф').selectOption({ label: 'Studio' })
  const until = dayInBishkek(45)
  await grant.getByLabel('Действует до').fill(until)
  await grant.getByLabel('Причина').fill('Подарок e2e за отзыв')
  await grant.getByRole('button', { name: 'Сохранить срок' }).click()
  await expect(grant.getByText('Срок обновлён')).toBeVisible({ timeout: 20_000 })
  await page.keyboard.press('Escape')

  const [y, m, d] = until.split('-')
  await expect(row).toContainText('Studio')
  await expect(row).toContainText(`${d}.${m}.${y}`)
  await expect(page.getByRole('row', { name: /Подарок e2e за отзыв/ })).toBeVisible()

  // 2. Удалить: подтверждение названием, причина, вопрос «Удалить центр?».
  await row.getByRole('button', { name: 'Действия' }).click()
  const del = page.locator('dialog[open]').locator('form').filter({ hasText: 'Удалить центр' })
  await del.getByLabel('Название центра для подтверждения').fill(CENTER)
  await del.getByLabel('Причина').fill('Спам e2e')
  await del.getByRole('button', { name: 'Удалить центр' }).click()
  await del.getByRole('button', { name: 'Подтвердить' }).click()

  // Центр уходит из живых в «Удалённые центры» с отметкой, кто удалил.
  const deleted = page.locator('li').filter({ hasText: CENTER })
  await expect(deleted).toContainText('удалила платформа', { timeout: 20_000 })
  await expect(centerRow()).toHaveCount(0)

  // 3. Восстановить.
  await deleted.getByPlaceholder('Причина').fill('Ошиблись, центр живой')
  await deleted.getByRole('button', { name: 'Восстановить' }).click()
  await expect(centerRow()).toBeVisible({ timeout: 20_000 })
  await expect(page.getByRole('row', { name: /Ошиблись, центр живой/ })).toBeVisible()
})
