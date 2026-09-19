import { expect, test } from '@playwright/test'

import { STUDENTS } from './fixtures'
import { lessonCard, lessonsThisWeek, openBishkekYesterdayWeek, openWeek, studentCards } from './helpers'

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

// serial: тесты файла читают одно состояние, и порядок между ними важен.
test.describe.configure({ mode: 'serial' })

const TEACHER_WEEK = '2027-03-08'

test('5. Специалист не может создавать занятия и не видит чужих учеников', async ({ page }) => {
  await openWeek(page, TEACHER_WEEK)

  await expect(page.getByRole('button', { name: 'Добавить занятие' })).toHaveCount(0)

  // Своё видно, и с именем ребёнка: иначе тест прошёл бы и при полностью
  // закрытом доступе, а без имени специалист не знает, к кому идёт.
  await expect(lessonCard(page, '11:00', STUDENTS.ailin)).toBeVisible()

  // Занятие чужого ребёнка (09:00 у второго специалиста) в расписании
  // Нургуль отсутствует как карточка. Проверка по имени здесь не годится:
  // имя чужого ребёнка скрыто политикой students и не появилось бы на
  // карточке, даже если бы политика lessons пропустила само занятие.
  await expect(page.locator('button', { hasText: '09:00' })).toHaveCount(0)
  expect(await lessonsThisWeek(page)).toBe(2)
})

test('5б. Специалист отмечает занятие проведённым', async ({ page }) => {
  // complete_lesson (0039) проверяет starts_at <= now() по-настоящему —
  // TEACHER_WEEK датирована 2027 годом нарочно (не зависеть от реальных
  // часов) и никогда не окажется в прошлом по факту. Отдельное, взаправду
  // прошедшее занятие Айлин — «вчера по Бишкеку» (e2e.sql), тот же приём,
  // что у чек-листа этапа 4.
  await openBishkekYesterdayWeek(page)

  await lessonCard(page, '09:00', STUDENTS.ailin).click()
  // «Провёл» (0039) — ссылка на экран «Провести занятие», не кнопка формы:
  // getByRole('button', ...) её не найдёт.
  await page.getByRole('link', { name: 'Провёл' }).click()
  await expect(page.getByRole('heading', { name: 'Провести занятие' })).toBeVisible()
  // Форма уже пришла с отметкой посещения по умолчанию — «Завершить» без
  // правок сохраняет её и переводит занятие в «Проведено» одним вызовом.
  //
  // Не actAndAwait: та же причина, что у FreezeForm в
  // attendance-subscriptions.spec.ts — успешный completeLesson делает
  // revalidatePath на этот же путь, RSC-страница
  // тут же меняет status на 'done' и подменяет CompleteLessonForm (с её
  // <p role="status">) на статичный renderDone — уведомление формы
  // размонтируется раньше, чем toContainText успевает его прочитать.
  // Ждём напрямую итоговый экран.
  await page.getByRole('button', { name: 'Завершить' }).click()
  await expect(page.getByRole('heading', { name: 'Занятие проведено' })).toBeVisible({ timeout: 20_000 })
})

// Этап 4, п.5 чек-листа (docs/Roadmap/stages.md): специалист отмечает
// посещение своего занятия и видит остаток абонемента словом, а не числом.
// Пятое (последнее, ещё не отмеченное) занятие Данияра из фикстуры — те же
// четыре из них уже отметил admin в attendance-subscriptions.spec.ts,
// оставшийся остаток — 5 занятий из проданных восьми. Занятия датированы
// вчера по Бишкеку (e2e.sql) — openBishkekYesterdayWeek, не openTodayWeek:
// на границе недели (если прогон CI стартовал в понедельник) «сегодня» и
// «вчера» могут попасть в разные недели расписания.
test('5в. Специалист отмечает посещение и не видит остаток числом', async ({ page }) => {
  await openBishkekYesterdayWeek(page)
  await studentCards(page, STUDENTS.daniyar).nth(4).click()
  await page.getByRole('button', { name: 'Отметить посещение' }).click()

  const row = page.locator('li').filter({ hasText: STUDENTS.daniyar })

  // Остаток 5 из 8 — не «заканчивается» (порог ≤2) и не «нет» (порог ≤0),
  // значит student_subscription_badge отдаёт «есть». Числа вида «5 зан.»
  // (как видит admin) здесь быть не должно вовсе.
  await expect(row.getByText('есть', { exact: true })).toBeVisible()
  await expect(row.getByText(/^\d+\s*зан\.$/)).toHaveCount(0)

  await row.getByRole('button', { name: 'Пришёл', exact: true }).click()
  await expect(row.getByRole('button', { name: 'Пришёл', exact: true })).toHaveClass(/text-white/)
})
