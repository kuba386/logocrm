import { expect, test } from '@playwright/test'
import { formatSom } from '@logocrm/core'

import { actAndAwait } from './helpers'

// /app/finance (этап 5, блок UI п.2). Независим от других spec-файлов:
// расход и корректировка — свои строки текущего месяца по поясу центра,
// список фильтруется тем же месяцем, что и дата по умолчанию в форме.
// Рассрочки и замок месяца здесь не проверяются: рассрочка — в
// attendance-subscriptions.spec.ts (продажа с 2 × 1 000), а close_month
// упирается в занятия фикстуры без отметок — это pgTAP 0027/0029.

test('Финансы: расход записан и виден в списке месяца', async ({ page }) => {
  await page.goto('/app/finance?tab=expenses')
  await expect(page.getByRole('heading', { name: 'Финансы' })).toBeVisible()

  await page.getByLabel('Статья').selectOption({ label: 'Прочее' })
  await page.getByLabel('Сумма, сом').fill('150')
  await page.getByLabel('Комментарий').fill('e2e: бумага для принтера')
  await actAndAwait(page, 'Записать расход', 'Расход записан')

  // Строка списка — по ответу сервера (revalidatePath), не по локальному
  // состоянию формы; итог «Расходы: …» тоже пересчитан базой (cash_by_source).
  const row = page.locator('tr', { hasText: 'e2e: бумага для принтера' })
  await expect(row).toBeVisible()
  await expect(row).toContainText('Прочее')
  await expect(row).toContainText(formatSom(15_000))
})

test('Финансы: корректировка без абонемента попадает в платежи', async ({ page }) => {
  await page.goto('/app/finance?tab=payments')
  await expect(page.getByRole('heading', { name: 'Финансы' })).toBeVisible()

  await page.getByLabel('Плательщик').selectOption({ index: 1 })
  await page.getByLabel('Вид').selectOption({ label: 'Корректировка' })
  await page.getByLabel('Сумма, сом').fill('50')
  await page.getByLabel('Комментарий').fill('e2e: корректировка кассы')
  await actAndAwait(page, 'Записать платёж', 'Корректировка записана')

  const row = page.locator('tr', { hasText: 'e2e: корректировка кассы' })
  await expect(row).toBeVisible()
  await expect(row).toContainText('Корректировка')
  await expect(row).toContainText(formatSom(5_000))
})
