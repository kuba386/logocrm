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

// Этап 4, п.6 чек-листа (docs/Roadmap/stages.md): /app показывает остаток
// своего ребёнка и не показывает чужого. Дашборд ветвится по роли на той же
// /app — отдельного /app/my нет (dashboard-parent.tsx, «Одна страница на
// все роли», CLAUDE.md — отступление от самого брифа, см. reports/stage-4.md).
//
// К этому месту абонемент Данияра тронут дважды после продажи (8): admin
// в attendance-subscriptions.spec.ts довёл до 5, teacher в teacher.spec.ts —
// до 4. Файлы этого проекта идут строго по цепочке зависимостей admin →
// teacher → parent (playwright.config.ts), так что здесь остаток уже 4 из 8.
test('6в. Родитель видит остаток своего ребёнка числом, чужого — не видит вовсе', async ({ page }) => {
  await page.goto('/app')
  await expect(page.getByRole('heading', { name: 'Мои дети' })).toBeVisible()

  // Два фильтра разом: карточка ребёнка — единственный div, где встречаются
  // оба текста сразу (имя — в CardHeader, «Осталось занятий» — в
  // CardContent, они соседи, а не вложены друг в друга). .last() берёт
  // самый вложенный подходящий div — саму карточку, а не общий контейнер
  // сетки, в котором тоже «есть» оба текста где-то внутри.
  const daniyarCard = page
    .locator('div')
    .filter({ hasText: STUDENTS.daniyar })
    .filter({ hasText: 'Осталось занятий' })
    .last()
  await expect(daniyarCard.getByText('4 из 8')).toBeVisible()

  await expect(page.getByText(STUDENTS.foreign)).toHaveCount(0)
})
