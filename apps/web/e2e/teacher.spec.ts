import { expect, test } from '@playwright/test'

import { STUDENTS } from './fixtures'
import { lessonCard, openWeek } from './helpers'

// Пункт 5 чек-листа: специалист видит только своё, отмечает занятие
// проведённым, создавать не может.
//
// Неделя 8–14 марта выбрана не случайно: в ней остались запланированные
// занятия Нургуль (серия из теста 2 отменена только с 17-го, а отпуск
// закрыл 1–7 марта). Там же лежит занятие чужого ребёнка у второго
// специалиста — на нём проверяется граница видимости.
//
// Границы прав на уровне SQL проверяет pgTAP: он ходит от роли authenticated
// и бьёт по функциям напрямую. Здесь — путь через интерфейс.

const TEACHER_WEEK = '2027-03-08'

test('5. Специалист не может создавать занятия и не видит чужих учеников', async ({ page }) => {
  await openWeek(page, TEACHER_WEEK)

  await expect(page.getByRole('button', { name: 'Добавить занятие' })).toHaveCount(0)

  // Занятие ведёт второй специалист — в расписании Нургуль его быть не должно.
  await expect(page.getByText(STUDENTS.foreign)).toHaveCount(0)

  // Своё при этом видно: иначе тест прошёл бы и при полностью закрытом доступе.
  await expect(lessonCard(page, '11:00', STUDENTS.ailin)).toBeVisible()
})

test('5б. Специалист отмечает занятие проведённым', async ({ page }) => {
  await openWeek(page, TEACHER_WEEK)

  await lessonCard(page, '11:00', STUDENTS.ailin).click()
  await page.getByRole('button', { name: 'Провёл' }).click()

  await expect(page.getByText('Проведено')).toBeVisible()
})
