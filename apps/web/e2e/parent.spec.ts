import { expect, test } from '@playwright/test'

import { MONDAY, STUDENTS } from './fixtures'
import { openWeek } from './helpers'

// Пункт 6 чек-листа: родитель видит занятия только своих детей.
//
// Оба своих ребёнка привязаны к одному плательщику, чужой — к другому.
// Проверяем обе стороны границы: своих видно, чужого нет. Тест только на
// «своих видно» прошёл бы и при полностью открытой политике.

test('6. Родитель видит своих детей и не видит чужого', async ({ page }) => {
  await openWeek(page, MONDAY)

  await expect(page.getByText(STUDENTS.ailin).first()).toBeVisible()
  await expect(page.getByText(STUDENTS.foreign)).toHaveCount(0)
})

test('6б. Родителю недоступно создание занятий', async ({ page }) => {
  await openWeek(page, MONDAY)
  await expect(page.getByRole('button', { name: 'Добавить занятие' })).toHaveCount(0)
})
