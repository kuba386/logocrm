import { expect, test } from '@playwright/test'
import { formatSom } from '@logocrm/core'

import { actAndAwait, openSaleDialog, SELL_SUBMIT } from './helpers'
import { STUDENTS } from './fixtures'

// /app/finance (этап 5, блок UI п.2). Независим от других spec-файлов:
// расход и корректировка — свои строки текущего месяца по поясу центра,
// список фильтруется тем же месяцем, что и дата по умолчанию в форме.
// Рассрочки и замок месяца здесь не проверяются: рассрочка — в
// attendance-subscriptions.spec.ts (продажа с 2 × 1 000), а close_month
// упирается в занятия фикстуры без отметок — это pgTAP 0027/0029.

test('Финансы: расход записан и виден в списке месяца', async ({ page }) => {
  await page.goto('/app/finance?tab=expenses')
  await expect(page.getByRole('heading', { name: 'Финансы' })).toBeVisible()

  // Форма — в диалоге «Добавить расход»; на вкладке есть ещё фильтр «Статья»,
  // поэтому поля ищем внутри открытого диалога.
  await page.getByRole('button', { name: 'Добавить расход' }).click()
  const dialog = page.locator('dialog[open]')
  await dialog.getByLabel('Статья').selectOption({ label: 'Прочее' })
  await dialog.getByLabel('Сумма, сом').fill('150')
  await dialog.getByLabel('Комментарий').fill('e2e: бумага для принтера')
  await actAndAwait(page, 'Записать расход', 'Расход записан')

  // Строка списка — по ответу сервера (revalidatePath), не по локальному
  // состоянию формы; итог «Расходы: …» тоже пересчитан базой (cash_by_source).
  const row = page.locator('tr', { hasText: 'e2e: бумага для принтера' })
  await expect(row).toBeVisible()
  await expect(row).toContainText('Прочее')
  await expect(row).toContainText(formatSom(15_000))
})

test('Финансы: корректировка без абонемента попадает в платежи', async ({ page }) => {
  await page.goto('/app/finance?tab=payments')
  await expect(page.getByRole('heading', { name: 'Финансы' })).toBeVisible()

  await page.getByRole('button', { name: 'Принять оплату', exact: true }).click()
  const dialog = page.locator('dialog[open]')
  await dialog.getByLabel('Плательщик').selectOption({ index: 1 })
  await dialog.getByLabel('Вид').selectOption({ label: 'Корректировка' })
  await dialog.getByLabel('Сумма, сом').fill('50')
  await dialog.getByLabel('Комментарий').fill('e2e: корректировка кассы')
  await actAndAwait(page, 'Записать платёж', 'Корректировка записана')

  const row = page.locator('tr', { hasText: 'e2e: корректировка кассы' })
  await expect(row).toBeVisible()
  await expect(row).toContainText('Корректировка')
  await expect(row).toContainText(formatSom(5_000))
})

// Цепочка денег сквозь экраны: продажа с частичной оплатой и рассрочкой →
// график в «Рассрочках» → приём первого платежа → итог в «Платежах» и на
// карточке. Проверяет не суммы базы (их держит pgTAP 0013/0018/0021), а что
// экраны показывают одно и то же и полоска сумм сходится в «Итого в кассе».
// Тип абонемента «Восемь занятий · e2e» (4 000 сом) заводит
// attendance-subscriptions.spec.ts — проект admin идёт раньше owner-money.

function inDays(days: number): string {
  return new Date(Date.now() + days * 86_400_000).toISOString().slice(0, 10)
}

/** «5 500 сом», «−500 сом» → тыйыны. */
function somText(text: string): number {
  const digits = text.replace(/[−–]/g, '-').replace(/[^\d-]/g, '')
  return Number(digits) * 100
}

test('Финансы: продажа с рассрочкой сходится на всех экранах, полоска сумм — в итог', async ({ page }) => {
  await page.goto('/app/students')
  await page.getByRole('link', { name: STUDENTS.timur }).click()
  await expect(page.getByRole('heading', { name: STUDENTS.timur })).toBeVisible()

  // Тип «Восемь занятий · e2e» создаёт attendance-subscriptions.spec.ts (проект admin раньше).
  const sale = await openSaleDialog(page, 'Восемь занятий · e2e')
  await expect(sale.locator('#priceSom')).toHaveValue('4000')

  await sale.locator('#paidSom').fill('1000')
  await expect(sale.getByText(`Остаток к оплате: ${formatSom(300_000)}`)).toBeVisible()
  await sale.getByLabel('Рассрочка на остаток').check()
  await sale.locator('#installments').fill('2')
  await sale.locator('#firstDue').fill(inDays(30))
  await sale.getByRole('button', { name: SELL_SUBMIT }).click()

  // Итог, а не уведомление формы: карточка абонемента с частичной оплатой.
  await expect(page.getByText(`Оплачено ${formatSom(100_000)} из ${formatSom(400_000)}`)).toBeVisible({ timeout: 20_000 })

  // «Рассрочки»: два платежа Тимура по 1 500.
  await page.goto('/app/finance?tab=installments')
  const timurRows = page.locator('tr', { hasText: STUDENTS.timur })
  await expect(timurRows).toHaveCount(2)
  await expect(timurRows.first()).toContainText(formatSom(150_000))

  await timurRows.first().getByRole('button', { name: /^Принять/ }).click()
  await expect(page.locator('tr', { hasText: STUDENTS.timur })).toHaveCount(1, { timeout: 20_000 })

  // «Платежи»: обе оплаты Тимура есть, и строки полоски складываются в итог.
  await page.goto('/app/finance?tab=payments')
  const payments = page.locator('tr', { hasText: STUDENTS.timur })
  await expect(payments.filter({ hasText: formatSom(100_000) })).not.toHaveCount(0)
  await expect(payments.filter({ hasText: formatSom(150_000) })).not.toHaveCount(0)

  const totals = page.getByTestId('cash-totals')
  const value = async (label: string) =>
    somText(await totals.locator('div', { has: page.locator('dt', { hasText: label }) }).locator('dd').innerText())
  const received = await value('Получено')
  const refunded = await value('Возвращено')
  const corrections = await value('Корректировки')
  const spent = await value('Расходы')
  const total = await value('Итого в кассе')
  expect(received + refunded + corrections + spent, 'строки полоски сходятся в «Итого в кассе»').toBe(total)

  // Карточка: оплачено уже 2 500 из 4 000.
  await page.goto('/app/students')
  await page.getByRole('link', { name: STUDENTS.timur }).click()
  await expect(page.getByText(`Оплачено ${formatSom(250_000)} из ${formatSom(400_000)}`)).toBeVisible()
})

test('Финансы: отказ сервера не стирает введённое в форме платежа', async ({ page }) => {
  // React 19 сбрасывает <form action> и при ошибке. Раньше после «Сумма не
  // может быть нулём» плательщик, вид и комментарий пропадали
  // (useKeepValuesOnError, UX-аудит 6.10.2026).
  await page.goto('/app/finance?tab=payments')
  await expect(page.getByRole('heading', { name: 'Финансы' })).toBeVisible()

  await page.getByRole('button', { name: 'Принять оплату', exact: true }).click()
  const dialog = page.locator('dialog[open]')
  await dialog.getByLabel('Плательщик').selectOption({ index: 1 })
  const payer = await dialog.getByLabel('Плательщик').inputValue()
  await dialog.getByLabel('Вид').selectOption({ label: 'Корректировка' })
  await dialog.getByLabel('Сумма, сом').fill('0')
  await dialog.getByLabel('Комментарий').fill('e2e: не должно пропасть')
  await dialog.getByRole('button', { name: 'Записать платёж' }).click()

  await expect(dialog.getByText('Сумма не может быть нулём')).toBeVisible()
  await expect(dialog.getByLabel('Плательщик')).toHaveValue(payer)
  await expect(dialog.getByLabel('Вид')).toHaveValue('correction')
  await expect(dialog.getByLabel('Комментарий')).toHaveValue('e2e: не должно пропасть')
})

// Ловушка до 16.10.2026: оплата разового занятия «вне абонемента» в
// «Финансах» записывалась обычным платежом и долг за занятия не гасила
// (гасит только covers_lesson_debt, 0087) — касса росла, долг оставался.
// Теперь при долге у ребёнка «Принять оплату» по умолчанию проводит оплату
// долга. Долг Амины 800 сом создаёт attendance-subscriptions.spec.ts (п.4);
// платим часть — строку в «Долгах» читает owner-flows.spec.ts, она остаётся.
test('Финансы: «Принять оплату» при долге за занятия гасит долг', async ({ page }) => {
  await page.goto('/app/finance?tab=payments')
  await expect(page.getByRole('heading', { name: 'Финансы' })).toBeVisible()

  await page.getByRole('button', { name: 'Принять оплату', exact: true }).click()
  const dialog = page.locator('dialog[open]')
  await dialog.getByLabel('Ученик').selectOption({ label: STUDENTS.amina })
  await expect(dialog.getByLabel(/Долг за занятия — /)).toBeChecked()
  await expect(dialog.getByLabel('Сумма, сом')).toHaveValue('800')
  await dialog.getByLabel('Сумма, сом').fill('300')
  await actAndAwait(page, 'Принять оплату долга', 'Оплата принята')
  await expect(page.getByRole('status').getByRole('link', { name: 'Квитанция' })).toBeVisible()

  await page.goto('/app/debts')
  const debtRow = page.locator('div').filter({ hasText: STUDENTS.amina }).filter({ hasText: 'Долг' }).last()
  await expect(debtRow).toContainText(formatSom(50_000))
})

// Деньги центра (0101). Эмир — без занятий и абонементов (e2e.sql), его счёт
// другие файлы не читают: аванс 1 000 → «аванс 1 000» и «Вернуть аванс».
test('Аванс без долга: «Внести аванс» на карточке — аванс виден, вернуть можно той же карточкой', async ({ page }) => {
  await page.goto('/app/students')
  await page.getByRole('link', { name: STUDENTS.emir }).click()
  await expect(page.getByRole('heading', { name: STUDENTS.emir })).toBeVisible()

  // Кнопку показывает база (lesson_advance_preview): долга нет, абонемента нет.
  await page.getByRole('button', { name: 'Внести аванс' }).click()
  const dialog = page.locator('dialog[open]')
  await dialog.getByLabel('Сумма, сом').fill('1000')
  await actAndAwait(page, 'Принять аванс', 'Аванс принят')
  await expect(page.getByRole('status').getByRole('link', { name: 'Квитанция' })).toBeVisible()

  // Аванс — из счёта занятий в базе (student_balance.lesson_credit_tiyin), не из формы.
  // exact: в закрытом <dialog> «Внести аванс» тот же текст внутри описания.
  await expect(page.getByText(`аванс ${formatSom(100_000)}`, { exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Вернуть аванс' })).toBeVisible()
})

// Перевод между кассами (0101): итог центра не меняется, перевод — в списке
// месяца с «Обратным переводом». Сумма маленькая: касса фикстуры не важна,
// отрицательный итог одной кассы допустим (остатков касс нет — 0101 Р10).
test('Перевод между кассами: проведён и виден в списке месяца', async ({ page }) => {
  await page.goto('/app/finance?tab=payments')
  await expect(page.getByRole('heading', { name: 'Финансы' })).toBeVisible()

  await page.getByRole('button', { name: 'Перевод между кассами' }).click()
  const dialog = page.locator('dialog[open]')
  // Откуда и куда по умолчанию — две первые кассы, разные.
  await dialog.getByLabel('Сумма, сом').fill('50')
  await dialog.getByLabel('Комментарий').fill('e2e: инкассация')
  await actAndAwait(page, 'Перевести', 'Перевод проведён')

  await page.getByText(/^Переводы между кассами за месяц \(\d+\)$/).click()
  const transfer = page.locator('li', { hasText: 'e2e: инкассация' }).first()
  await expect(transfer).toContainText(formatSom(5_000))
  await expect(transfer.getByRole('button', { name: 'Обратный перевод' })).toBeVisible()
})
