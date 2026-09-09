import { expect, test } from '@playwright/test'

import { STUDENTS } from './fixtures'
import { lessonCard, openWeek } from './helpers'

// Пункт 6 чек-листа: родитель видит занятия только своих детей.
//
// Проверяются обе стороны границы. Занятие чужого ребёнка лежит в той же
// неделе у второго специалиста: без него проверка была бы пустой — нечего
// не увидеть, и она прошла бы даже при полностью открытой политике.

const PARENT_WEEK = '2027-03-08'

test('6. Родитель видит своего ребёнка и не видит чужого', async ({ page }) => {
  await openWeek(page, PARENT_WEEK)

  await expect(lessonCard(page, '11:00', STUDENTS.ailin)).toBeVisible()
  await expect(page.getByText(STUDENTS.foreign)).toHaveCount(0)
})

test('6б. Родителю недоступно создание занятий', async ({ page }) => {
  await openWeek(page, PARENT_WEEK)
  await expect(page.getByRole('button', { name: 'Добавить занятие' })).toHaveCount(0)
})
