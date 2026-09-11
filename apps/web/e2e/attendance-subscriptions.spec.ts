import { expect, test, type Page } from '@playwright/test'
import { formatSom } from '@logocrm/core'

import { STUDENTS } from './fixtures'
import { actAndAwait, bishkekYesterdayIso, openBishkekYesterdayWeek, studentCards } from './helpers'

// Пункты 1 и 2 чек-листа приёмки этапа 4 (docs/Roadmap/stages.md). Пункты 5
// и 6 (специалист и родитель) — в teacher.spec.ts/parent.spec.ts, они читают
// состояние, оставленное этим файлом. Пункты 3-4 (заморозка, долг/исчерпание)
// — отдельная задача: заморозка не бросает исключение при отметке, вопреки
// тексту чек-листа, а молча уводит занятие в долг — нужен отдельный разбор,
// не механическое повторение формулировки.
//
// Пять занятий Данияра в фикстуре (packages/db/supabase/fixtures/e2e.sql)
// датированы вчера по Бишкеку, а не фиксированной будущей датой, как у
// остальной фикстуры: «Отметить посещение» доступно только для уже
// начавшихся занятий (lesson-panel.tsx, canMarkAttendance). «Дата начала»
// абонемента ниже проставлена тем же вчера явно, не через пустое поле —
// sell_subscription без явной даты берёт center_today() (0010:256), и
// абонемент датировался бы СЕГОДНЯ, позже вчерашних занятий; составной
// кандидат на списание требует s.starts_at <= v_lesson_date (0010:861) —
// молчаливо переставало бы находиться. Обе даты — из одной и той же
// bishkekYesterdayIso(), а не вычисляются порознь.

test.describe.configure({ mode: 'serial' })

const TYPE_NAME = 'Восемь занятий · e2e'

/**
 * Открывает index-е по счёту занятие Данияра и отмечает статусом statusName.
 * Индекс, а не время: отметка не меняет lesson.status (mark_attendance его
 * не трогает), карточка выглядит так же и до, и после — «первое
 * неотмеченное» не найти, но хронологический порядок рендера стабилен.
 */
async function markDaniyar(page: Page, index: number, statusName: string) {
  await openBishkekYesterdayWeek(page)
  await studentCards(page, STUDENTS.daniyar).nth(index).click()
  await page.getByRole('button', { name: 'Отметить посещение' }).click()

  const row = page.locator('li').filter({ hasText: STUDENTS.daniyar })
  await row.getByRole('button', { name: statusName, exact: true }).click()

  // Оптимистичного UI нет — ждём, пока панель перечитает участников с
  // сервера и подсветит нажатую кнопку активной. text-white — только у
  // active-варианта (apps/web/lib/attendance.ts), у inactive его нет ни
  // для одного цвета. Раньше этого остаток ещё старый.
  await expect(row.getByRole('button', { name: statusName, exact: true })).toHaveClass(/text-white/)
}

async function daniyarRemaining(page: Page): Promise<number> {
  await page.goto('/app/students')
  await page.getByRole('link', { name: STUDENTS.daniyar }).click()
  await expect(page.getByRole('heading', { name: STUDENTS.daniyar })).toBeVisible()

  const dt = page.locator('dt', { hasText: 'Остаток' }).locator('xpath=following-sibling::dd[1]')
  const text = await dt.innerText()
  const match = /(\d+)\s*зан\./.exec(text)
  if (!match) throw new Error(`Не удалось прочитать остаток из «${text}»`)
  return Number(match[1])
}

test('Этап 4, п.1: продать абонемент 8 занятий за 4 000 сом', async ({ page }) => {
  // Тип абонемента — своей записью, не из фикстуры: заодно покрывает форму
  // «Добавить тип» в /app/settings/subscription-types, у которой до сих пор
  // не было ни одного e2e-сценария.
  await page.goto('/app/settings/subscription-types')
  await page.getByLabel('Название').fill(TYPE_NAME)
  await page.getByLabel('Вид').selectOption({ label: 'Пакет занятий' })
  await page.getByLabel('Занятий').fill('8')
  await page.getByLabel('Цена, сом').fill('4000')
  await actAndAwait(page, 'Добавить', 'Сохранено')

  await page.goto('/app/students')
  await page.getByRole('link', { name: STUDENTS.daniyar }).click()
  await expect(page.getByRole('heading', { name: STUDENTS.daniyar })).toBeVisible()

  const typeSelect = page.locator('select#typeId')
  const optionValue = await typeSelect.locator('option', { hasText: TYPE_NAME }).getAttribute('value')
  if (!optionValue) throw new Error('Тип абонемента не появился в форме продажи')
  await typeSelect.selectOption(optionValue)

  // Цена подставляется из типа (400000 тыйын = 4000 сом) и не трогается —
  // проверяем именно то, что подстановка сработала, а не переписываем её.
  await expect(page.locator('#priceSom')).toHaveValue('4000')

  // Явно вчера по Бишкеку — та же дата, что у занятий фикстуры (см.
  // комментарий вверху файла). Пустое поле взяло бы center_today() и
  // разошлось бы с занятиями на день.
  await page.locator('#startsAt').fill(bishkekYesterdayIso())

  await actAndAwait(page, 'Продать абонемент', 'Абонемент продан')

  await expect(page.locator('dt', { hasText: 'Остаток' }).locator('xpath=following-sibling::dd[1]')).toContainText(
    '8 зан.',
  )
  // lesson_price_tiyin (500 сом = 4000/8) нигде не показывается в
  // интерфейсе напрямую — карточка абонемента выводит только полную цену
  // (subscriptions-panel.tsx:297). Проверено на уровне SQL: pgTAP уже
  // покрывает «8 занятий за 400000 → lesson_price 50000» (0008 test, п.4).
  //
  // exact: true — форма продажи остаётся на странице с тем же типом всё
  // ещё выбранным в <select>, а его <option> содержит TYPE_NAME как
  // подстроку («Восемь занятий · e2e · 8 занятий») — без exact запрос
  // находит оба элемента разом и падает на strict mode violation.
  await expect(page.getByText(TYPE_NAME, { exact: true })).toBeVisible()
  // formatSom разделяет тысячи неразрывным пробелом (U+00A0), не обычным —
  // сверяемся с самим форматтером, а не гадаем пробел в литерале.
  await expect(page.getByText(formatSom(400_000), { exact: false })).toBeVisible()
})

test('Этап 4, п.2: отметки посещения списывают, «болел» — нет, два «прогул» подряд не ломают отметку', async ({
  page,
}) => {
  await markDaniyar(page, 0, 'Пришёл')
  expect(await daniyarRemaining(page)).toBe(7)

  await markDaniyar(page, 1, 'Болел')
  expect(await daniyarRemaining(page)).toBe(7)

  await markDaniyar(page, 2, 'Прогул')
  expect(await daniyarRemaining(page)).toBe(6)

  await markDaniyar(page, 3, 'Прогул')
  expect(await daniyarRemaining(page)).toBe(5)
})
