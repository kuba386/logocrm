import { expect, test } from '@playwright/test'
import { formatSom } from '@logocrm/core'

import { actAndAwait } from './helpers'

// /app/settings/teacher-rates (этап 5, блок UI п.4). Ставка — прямой insert
// в teacher_rates под гвардами 0017 (закрытый месяц, утверждённый снимок):
// в фикстуре ни того, ни другого, дата — сегодня.

test('Ставки: новая ставка за занятие появляется в списке', async ({ page }) => {
  await page.goto('/app/settings/teacher-rates')
  await expect(page.getByRole('heading', { name: 'Ставки специалистов' })).toBeVisible()

  await page.getByLabel('Специалист').selectOption({ index: 1 })
  await page.getByLabel('Модель').selectOption({ label: 'за занятие' })
  await page.getByLabel('Значение').fill('500')
  await actAndAwait(page, 'Добавить ставку', 'Ставка добавлена')

  // Строка — по ответу сервера (revalidatePath): модель словом, сумма в
  // сомах из тыйынов, «Все услуги» для ставки без услуги.
  const row = page.locator('tbody tr').filter({ hasText: formatSom(50_000) }).first()
  await expect(row).toBeVisible()
  await expect(row).toContainText('за занятие')
  await expect(row).toContainText('Все услуги')
})
