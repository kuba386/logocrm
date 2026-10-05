import { expect, test } from '@playwright/test'
import { formatSom } from '@logocrm/core'

import { actAndAwait } from './helpers'
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

  await page.getByLabel('Статья').selectOption({ label: 'Прочее' })
  await page.getByLabel('Сумма, сом').fill('150')
  await page.getByLabel('Комментарий').fill('e2e: бумага для принтера')
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

  await page.getByLabel('Плательщик').selectOption({ index: 1 })
  await page.getByLabel('Вид').selectOption({ label: 'Корректировка' })
  await page.getByLabel('Сумма, сом').fill('50')
  await page.getByLabel('Комментарий').fill('e2e: корректировка кассы')
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

  const typeSelect = page.locator('select#typeId')
  const optionValue = await typeSelect.locator('option', { hasText: 'Восемь занятий · e2e' }).getAttribute('value')
  if (!optionValue) throw new Error('Нет типа «Восемь занятий · e2e» — его создаёт attendance-subscriptions.spec.ts')
  await typeSelect.selectOption(optionValue)
  await expect(page.locator('#priceSom')).toHaveValue('4000')

  await page.locator('#paidSom').fill('1000')
  await expect(page.getByText(`Остаток к оплате: ${formatSom(300_000)}`)).toBeVisible()
  await page.getByLabel('Рассрочка на остаток').check()
  await page.locator('#installments').fill('2')
  await page.locator('#firstDue').fill(inDays(30))
  await page.getByRole('button', { name: 'Продать абонемент' }).click()

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

  await page.getByLabel('Плательщик').selectOption({ index: 1 })
  const payer = await page.getByLabel('Плательщик').inputValue()
  await page.getByLabel('Вид').selectOption({ label: 'Корректировка' })
  await page.getByLabel('Сумма, сом').fill('0')
  await page.getByLabel('Комментарий').fill('e2e: не должно пропасть')
  await page.getByRole('button', { name: 'Записать платёж' }).click()

  await expect(page.getByText('Сумма не может быть нулём')).toBeVisible()
  await expect(page.getByLabel('Плательщик')).toHaveValue(payer)
  await expect(page.getByLabel('Вид')).toHaveValue('correction')
  await expect(page.getByLabel('Комментарий')).toHaveValue('e2e: не должно пропасть')
})
