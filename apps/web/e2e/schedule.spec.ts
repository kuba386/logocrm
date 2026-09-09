import { expect, test } from '@playwright/test'

import { MONDAY, MONTH_END, ROOM, SERVICES, STUDENTS, TEACHERS, WEDNESDAY } from './fixtures'
import { actAndAwait, fillLessonDialog, lessonCard, lessonsThisWeek, openWeek, submitLessonDialog } from './helpers'

// Пункты 1–4 чек-листа приёмки этапа 3 (docs/Roadmap/stages.md).
//
// Сценарии идут по порядку и опираются на состояние друг друга: серия
// создаётся поверх занятия из первого теста, отпуск отменяет то, что
// осталось. Так проверяется не только каждое действие, но и то, что они не
// мешают друг другу. Отсюда serial.

test.describe.configure({ mode: 'serial' })

test('1. Накладку не пускают оба слоя: интерфейс и база', async ({ page }) => {
  await openWeek(page, MONDAY)

  await fillLessonDialog(page, {
    service: SERVICES.individual,
    teacher: TEACHERS.nurgul,
    student: STUDENTS.ailin,
    room: ROOM,
    firstDay: MONDAY,
    time: '10:00',
    weekdays: ['Пн'],
  })
  await submitLessonDialog(page, 'Занятие создано')

  await openWeek(page, MONDAY)
  await expect(lessonCard(page, '10:00', STUDENTS.ailin)).toBeVisible()
  expect(await lessonsThisWeek(page)).toBe(1)

  // Слой 1 — интерфейс. После предпросмотра с занятыми днями кнопка
  // «Создать» блокируется: create-dialog.tsx, SubmitButton disabled.
  //
  // Кабинет у второго занятия не указан намеренно: иначе непонятно, что
  // именно поймано — занятость специалиста или занятость комнаты.
  await fillLessonDialog(page, {
    service: SERVICES.individual,
    teacher: TEACHERS.nurgul,
    student: STUDENTS.daniyar,
    firstDay: MONDAY,
    time: '10:30',
    weekdays: ['Пн'],
  })
  await page.getByRole('button', { name: 'Проверить занятость' }).click()
  await expect(page.getByText(/специалист уже занят/i)).toBeVisible()
  await expect(page.getByRole('button', { name: 'Создать' })).toBeDisabled()

  // Слой 2 — база. Предпросмотр можно не нажимать, и тогда форма уходит на
  // сервер. Отказать обязан констрейнт, а не подсказка интерфейса: ровно это
  // и есть обещание этапа. fillLessonDialog перезагружает страницу, так что
  // предпросмотр сбрасывается и кнопка снова активна.
  await fillLessonDialog(page, {
    service: SERVICES.individual,
    teacher: TEACHERS.nurgul,
    student: STUDENTS.daniyar,
    firstDay: MONDAY,
    time: '10:30',
    weekdays: ['Пн'],
  })
  await page.getByRole('button', { name: 'Создать' }).click()

  await expect(page.getByRole('alert')).toContainText(/специалист уже занят/i)

  await openWeek(page, MONDAY)
  expect(await lessonsThisWeek(page)).toBe(1)
})

test('2. Серия создаётся целиком, отменяется с середины', async ({ page }) => {
  await openWeek(page, MONDAY)

  await fillLessonDialog(page, {
    service: SERVICES.individual,
    teacher: TEACHERS.nurgul,
    student: STUDENTS.ailin,
    firstDay: WEDNESDAY,
    until: MONTH_END,
    time: '11:00',
    weekdays: ['Ср', 'Пт'],
  })
  await submitLessonDialog(page, 'Создано занятий: 9')

  // Первая неделя: понедельничное занятие из теста 1 плюс среда и пятница.
  await openWeek(page, MONDAY)
  expect(await lessonsThisWeek(page)).toBe(3)

  // Отменяем с третьей недели месяца.
  await openWeek(page, '2027-03-15')
  expect(await lessonsThisWeek(page)).toBe(2)

  await lessonCard(page, '11:00', STUDENTS.ailin).click()
  await page.getByRole('button', { name: 'Отменить', exact: true }).click()
  await page.getByPlaceholder('Причина отмены серии').fill('Переезд семьи')
  await actAndAwait(page, 'Отменить серию с этого дня', 'Отменено занятий: 5')

  await openWeek(page, '2027-03-15')
  await lessonCard(page, '11:00', STUDENTS.ailin).click()
  await expect(page.getByText('Отменено')).toBeVisible()

  // Прошедшие занятия серии остаются: отмена «с этого дня», а не всей серии.
  // Отменённые из сетки не исчезают, поэтому проверяем именно статус —
  // проверка «карточка на месте» прошла бы в обоих случаях.
  await openWeek(page, MONDAY)
  await lessonCard(page, '11:00', STUDENTS.ailin).click()
  await expect(page.getByText('Запланировано')).toBeVisible()
})

test('3. Замена специалиста передаёт занятие другому', async ({ page }) => {
  await openWeek(page, MONDAY)

  await lessonCard(page, '10:00', STUDENTS.ailin).click()
  await page.getByRole('button', { name: 'Заменить специалиста' }).click()

  await page.getByLabel('Кто проведёт вместо').selectOption({ label: TEACHERS.aigul })
  await actAndAwait(page, 'Назначить', 'Замена назначена')

  // Проверяем карточку, а не первый попавшийся текст на странице: getByText
  // нашёл бы <option> с тем же именем в фильтре. Пометка «(замена)» отличает
  // замену от простой переустановки специалиста.
  await openWeek(page, MONDAY)
  await expect(lessonCard(page, '10:00', STUDENTS.ailin)).toContainText(`${TEACHERS.aigul} (замена)`)
})

test('4. Отпуск отменяет занятия и показывает предпросмотр', async ({ page }) => {
  await page.goto('/app/settings/staff')

  // Кнопка «Отпуск» одна: из участников центра специалист только Нургуль,
  // у владельца и администратора карточки специалиста нет.
  await page.getByRole('button', { name: 'Отпуск' }).first().click()

  await page.getByLabel('С', { exact: true }).fill(MONDAY)
  await page.getByLabel('По', { exact: true }).fill('2027-03-07')

  // Предпросмотр обязателен по спеке: администратор видит список до того,
  // как что-то отменится.
  await page.getByRole('button', { name: 'Показать, что отменится' }).click()
  await expect(page.getByText(/Будет отменено занятий: 3/)).toBeVisible()

  await actAndAwait(page, 'Оформить отпуск', 'Отменено занятий: 3')

  // Занятие с заменой тоже отменяется: отпускник остаётся в нём основным
  // специалистом, и teacher_vacation смотрит на обе колонки.
  await openWeek(page, MONDAY)
  await lessonCard(page, '10:00', STUDENTS.ailin).click()
  await expect(page.getByText('Отменено')).toBeVisible()
})
