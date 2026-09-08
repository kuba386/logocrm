import { expect, test } from '@playwright/test'

import { MONDAY, STUDENTS } from './fixtures'
import { lessonCard, openWeek } from './helpers'

// Пункт 5 чек-листа: специалист видит только своё, может отметить занятие
// проведённым, создавать занятия не может.
//
// Границы прав на уровне SQL проверяет pgTAP — он ходит от роли
// authenticated и бьёт по функциям напрямую. Здесь проверяется путь через
// интерфейс: что кнопки нет и что разрешённое действие работает.

test('5. Специалист не может создавать занятия и не видит чужих учеников', async ({ page }) => {
  await openWeek(page, MONDAY)

  await expect(page.getByRole('button', { name: 'Добавить занятие' })).toHaveCount(0)
  await expect(page.getByText(STUDENTS.foreign)).toHaveCount(0)
})

test('5б. Специалист отмечает занятие проведённым', async ({ page }) => {
  await openWeek(page, MONDAY)

  const card = lessonCard(page, '11:00', STUDENTS.ailin)
  await expect(card).toBeVisible()
  await card.click()

  await page.getByRole('button', { name: /Провёл|Проведено/ }).click()

  await expect(page.getByText(/Проведено/)).toBeVisible()
})
