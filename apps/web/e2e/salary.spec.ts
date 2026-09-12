import { expect, test } from '@playwright/test'
import { formatSom } from '@logocrm/core'

import { actAndAwait } from './helpers'

// /app/salary (этап 5, блок UI п.3). Прошедший месяц — чтобы была видна
// кнопка «Утвердить»; сама кнопка не нажимается: снимок неизменяем, а
// e2e-фикстура переиспользуется другими файлами. Утверждение и отмена
// покрыты pgTAP 0017/0027/0029; здесь — экран и корректировка.

function previousMonthFirst(): string {
  const d = new Date()
  const month = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - 1, 1))
  return month.toISOString().slice(0, 7)
}

test('Зарплата: таблица месяца, детализация и корректировка', async ({ page }) => {
  await page.goto(`/app/salary?month=${previousMonthFirst()}`)
  await expect(page.getByRole('heading', { name: 'Зарплата' })).toBeVisible()

  // Все специалисты фикстуры — по строке; месяц прошедший — есть «Утвердить».
  const firstRow = page.locator('tbody tr').first()
  await expect(firstRow).toBeVisible()
  await expect(page.getByRole('button', { name: /^Утвердить / }).first()).toBeVisible()

  await firstRow.getByRole('link', { name: 'Детализация' }).click()
  await expect(page.getByRole('link', { name: 'Скрыть' })).toBeVisible()

  // Корректировка идёт через record_salary_adjustment; строка «Корректировки»
  // пересчитывается salary_summary на сервере — сумма из ответа, не из формы.
  await page.getByLabel('Сумма, сом (минус — штраф)').fill('500')
  await page.getByLabel('Причина').fill('e2e: бонус за месяц')
  await actAndAwait(page, 'Записать', 'Корректировка записана')

  await expect(page.getByText('e2e: бонус за месяц')).toBeVisible()
  await expect(page.locator('tbody tr').first()).toContainText(formatSom(50_000))
})
