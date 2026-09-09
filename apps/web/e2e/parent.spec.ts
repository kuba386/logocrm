import { expect, test } from '@playwright/test'

import { STUDENTS } from './fixtures'
import { lessonCard, lessonsThisWeek, openWeek } from './helpers'

// Пункт 6 чек-листа: родитель видит занятия только своих детей.
//
// Проверяются обе стороны границы. Занятие чужого ребёнка лежит в той же
// неделе у второго специалиста: без него проверка была бы пустой — нечего
// не увидеть, и она прошла бы даже при полностью открытой политике.

// serial: тесты файла читают одно состояние, и порядок между ними важен.
test.describe.configure({ mode: 'serial' })

const PARENT_WEEK = '2027-03-08'

test('6. Родитель видит своего ребёнка и не видит чужого', async ({ page }) => {
  await openWeek(page, PARENT_WEEK)

  // Свой ребёнок виден по имени.
  await expect(lessonCard(page, '11:00', STUDENTS.ailin)).toBeVisible()

  // Чужое занятие (09:00 у второго специалиста) отсутствует как карточка.
  // Проверка по имени была бы пустой: имя чужого ребёнка скрыто политикой
  // students и не появилось бы на карточке, даже если бы политика lessons
  // пропустила само занятие.
  await expect(page.locator('button', { hasText: '09:00' })).toHaveCount(0)
  expect(await lessonsThisWeek(page)).toBe(2)
})

test('6б. Родителю недоступно создание занятий', async ({ page }) => {
  await openWeek(page, PARENT_WEEK)
  await expect(page.getByRole('button', { name: 'Добавить занятие' })).toHaveCount(0)
})
