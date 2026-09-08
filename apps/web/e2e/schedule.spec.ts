import { expect, test } from '@playwright/test'

import { MONDAY, MONTH_END, ROOM, SERVICES, STUDENTS, TEACHERS, WEDNESDAY } from './fixtures'
import { fillLessonDialog, lessonCard, lessonsThisWeek, openWeek, selectWithOption } from './helpers'

// Пункты 1–4 чек-листа приёмки этапа 3 (docs/Roadmap/stages.md).
//
// Сценарии идут по порядку и опираются на состояние друг друга: серия
// создаётся поверх занятия из первого теста, отпуск отменяет то, что
// осталось. Так проверяется не только каждое действие по отдельности, но и
// то, что они не мешают друг другу. Поэтому здесь test.describe.serial.

test.describe.configure({ mode: 'serial' })

test('1. Накладка по специалисту не даёт сохранить', async ({ page }) => {
  await openWeek(page, MONDAY)

  // Первое занятие — понедельник 10:00, с кабинетом.
  await fillLessonDialog(page, {
    service: SERVICES.individual,
    student: STUDENTS.ailin,
    room: ROOM,
    firstDay: MONDAY,
    time: '10:00',
    weekdays: ['Пн'],
  })
  await page.getByRole('button', { name: 'Создать' }).click()

  await expect(lessonCard(page, '10:00', STUDENTS.ailin)).toBeVisible()
  expect(await lessonsThisWeek(page)).toBe(1)

  // Второе — тому же специалисту на 10:30, другому ученику и БЕЗ кабинета.
  // Кабинет убран намеренно: иначе непонятно, что именно поймал констрейнт —
  // занятость специалиста или занятость комнаты.
  await fillLessonDialog(page, {
    service: SERVICES.individual,
    student: STUDENTS.daniyar,
    firstDay: MONDAY,
    time: '10:30',
    weekdays: ['Пн'],
  })

  await page.getByRole('button', { name: 'Проверить занятость' }).click()
  await expect(page.getByText(/специалист уже занят/i)).toBeVisible()

  // Предупреждение — половина дела. Проверяем, что сохранить всё равно нельзя:
  // защита обязана быть в базе, а не в подсказке интерфейса.
  await page.getByRole('button', { name: 'Создать' }).click()
  await expect(page.getByText(/специалист уже занят|пересекается/i)).toBeVisible()

  await openWeek(page, MONDAY)
  expect(await lessonsThisWeek(page)).toBe(1)
})

test('2. Серия создаётся целиком, отменяется с середины', async ({ page }) => {
  await openWeek(page, MONDAY)

  await fillLessonDialog(page, {
    service: SERVICES.individual,
    student: STUDENTS.ailin,
    firstDay: WEDNESDAY,
    until: MONTH_END,
    time: '11:00',
    weekdays: ['Ср', 'Пт'],
  })
  await page.getByRole('button', { name: 'Создать' }).click()

  // Первая неделя серии: среда и пятница, плюс понедельничное занятие
  // из предыдущего теста.
  await openWeek(page, MONDAY)
  expect(await lessonsThisWeek(page)).toBe(3)

  // Третья неделя месяца — только серия.
  await openWeek(page, '2027-03-15')
  expect(await lessonsThisWeek(page)).toBe(2)

  await lessonCard(page, '11:00', STUDENTS.ailin).click()
  await page.getByRole('button', { name: 'Отменить', exact: true }).click()

  await page.getByPlaceholder('Причина отмены серии').fill('Переезд семьи')
  await page.getByRole('button', { name: 'Отменить серию с этого дня' }).click()

  // Прошедшие занятия серии остаются: отмена «с этого дня», а не всей серии.
  await openWeek(page, MONDAY)
  await expect(lessonCard(page, '11:00', STUDENTS.ailin)).toBeVisible()
})

test('3. Замена специалиста передаёт занятие другому', async ({ page }) => {
  await openWeek(page, MONDAY)

  await lessonCard(page, '10:00', STUDENTS.ailin).click()
  await expect(page.getByText(TEACHERS.nurgul)).toBeVisible()

  await page.getByRole('button', { name: 'Заменить специалиста' }).click()
  await selectWithOption(page, TEACHERS.aigul).selectOption({ label: TEACHERS.aigul })
  await page.getByRole('button', { name: /Заменить|Сохранить/ }).last().click()

  await openWeek(page, MONDAY)
  await expect(page.getByText(TEACHERS.aigul)).toBeVisible()
})

test('4. Отпуск отменяет занятия и показывает предпросмотр', async ({ page }) => {
  await page.goto('/app/settings/staff')

  const row = page.getByRole('row', { name: new RegExp(TEACHERS.nurgul) })
  await row.getByRole('button', { name: 'Отпуск' }).click()

  await page.getByLabel('С').fill(MONDAY)
  await page.getByLabel('По').fill('2027-03-07')

  // Предпросмотр обязателен по спеке: администратор должен увидеть список
  // до того, как что-то отменится.
  await page.getByRole('button', { name: 'Показать, что отменится' }).click()
  await expect(page.getByText(/Будет отменено занятий: [1-9]/)).toBeVisible()

  await page.getByRole('button', { name: 'Оформить отпуск' }).click()

  await openWeek(page, MONDAY)
  await expect(page.getByText(/Отменено|отменено/)).toBeVisible()
})
