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

// Выплата из кассы (0101) — после корректировки выше: «к выплате» у первого
// специалиста прошлого месяца не меньше 500. Выплачивается всё; потом владелец
// отменяет выплату в детализации — «к выплате» возвращается.
test('Зарплата: выплата из кассы и отмена ошибочной выплаты владельцем', async ({ page }) => {
  await page.goto(`/app/salary?month=${previousMonthFirst()}`)
  await expect(page.getByRole('heading', { name: 'Зарплата' })).toBeVisible()

  const firstRow = page.locator('tbody tr').first()
  await firstRow.getByRole('button', { name: /^Выплатить · / }).click()
  // Сумма по умолчанию — всё «к выплате» из salary_summary; база сверит её сама.
  await actAndAwait(page, /^Выплатить$/, 'Выплата проведена')
  await expect(page.locator('tbody tr').first().getByRole('button', { name: /^Выплатить · / })).toHaveCount(0)

  // Детализация — с нуля (goto), чтобы итог выплаты не остался вторым role=status.
  const details = await page.locator('tbody tr').first().getByRole('link', { name: 'Детализация' }).getAttribute('href')
  await page.goto(details!)
  await expect(page.getByText('Выплаты за месяц')).toBeVisible()
  await page.getByRole('button', { name: 'Отменить', exact: true }).click()
  await page.getByLabel('Причина отмены').fill('e2e: выплатили не тому')
  await page.getByRole('button', { name: 'Отменить расход' }).click()
  await actAndAwait(page, 'Подтвердить', 'Расход отменён')

  await expect(page.getByText('отменена')).toBeVisible()
  await expect(page.locator('tbody tr').first().getByRole('button', { name: /^Выплатить · / })).toBeVisible()
})
