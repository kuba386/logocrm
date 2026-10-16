import { expect, test } from '@playwright/test'
import { formatSom } from '@logocrm/core'

import { STUDENTS } from './fixtures'
import { actAndAwait, openSaleDialog, SELL_SUBMIT } from './helpers'

// Стойка (registrar) — по матрице прав продаёт абонементы и принимает оплату
// (can_front_desk / can_payments, 0026), но до 16.10.2026 карточка ученика
// строила панель абонементов только владельцу и администратору: регистратору
// не доставалось ни абонементов, ни долга, ни контактов семьи. Здесь — что
// стойка доводит продажу и оплату до базы и получает квитанцию, а в
// «Финансах» не видит итогов кассы (cash_by_source — только can_finance).
//
// Ребёнок — «Чужой Ребёнок»: его деньги другие файлы не читают. Тип
// «Восемь занятий · e2e» (4 000 сом) создаёт attendance-subscriptions.spec.ts.

test.describe.configure({ mode: 'serial' })

test('Стойка: продажа с частичной оплатой, доплата и квитанция', async ({ page }) => {
  await page.goto('/app/students')
  await expect(page.getByRole('heading', { name: 'Ученики' })).toBeVisible()
  await page.getByRole('link', { name: STUDENTS.foreign }).click()
  await expect(page.getByRole('heading', { name: STUDENTS.foreign })).toBeVisible()
  await expect(page.getByRole('tab', { name: 'Абонементы' })).toHaveAttribute('aria-selected', 'true')

  const sale = await openSaleDialog(page, 'Восемь занятий · e2e')
  await sale.locator('#paidSom').fill('1000')
  await expect(sale.getByText(`Остаток к оплате: ${formatSom(300_000)}`)).toBeVisible()
  await actAndAwait(page, SELL_SUBMIT, 'Абонемент продан')
  await expect(page.getByText(`Оплачено ${formatSom(100_000)} из ${formatSom(400_000)}`)).toBeVisible()

  // Доплата остатка: сумма по умолчанию — весь остаток (subscription_summary.due_tiyin).
  await page.getByRole('button', { name: `Принять оплату · ${formatSom(300_000)}` }).click()
  const pay = page.locator('dialog[open]')
  await expect(pay.getByLabel('Сумма, сом')).toHaveValue('3000')
  await actAndAwait(page, /^Принять$/, 'Оплата принята')
  await expect(page.getByText(`Оплачено ${formatSom(400_000)} из ${formatSom(400_000)}`)).toBeVisible()

  // Квитанция из итога оплаты: сумма цифрами и прописью, ребёнок.
  await page.getByRole('status').getByRole('link', { name: 'Квитанция' }).click()
  await expect(page.getByRole('heading', { name: /Квитанция об оплате № [0-9A-F]{8}/ })).toBeVisible()
  await expect(page.getByText(formatSom(300_000), { exact: true })).toBeVisible()
  await expect(page.getByText('Три тысячи сом 00 тыйын')).toBeVisible()
  await expect(page.getByText(STUDENTS.foreign)).toBeVisible()
})

test('Стойка: в «Финансах» нет итогов кассы, но есть свои платежи и «Плательщики» в меню', async ({ page }) => {
  await page.goto('/app/finance')
  await expect(page.getByRole('heading', { name: 'Финансы' })).toBeVisible()

  // cash_by_source регистратору пуст без ошибки — нули выглядели бы как касса.
  await expect(page.getByTestId('cash-totals')).toHaveCount(0)
  await expect(page.getByText('Итоги кассы за месяц видят владелец, администратор и бухгалтер.')).toBeVisible()

  const row = page.locator('tr', { hasText: STUDENTS.foreign })
  await expect(row.filter({ hasText: formatSom(300_000) })).not.toHaveCount(0)

  // Расходов и периодов у стойки нет (матрица, сноска 21) — ни вкладок, ни кнопки.
  await expect(page.getByRole('link', { name: 'Расходы' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Добавить расход' })).toHaveCount(0)

  // «Поступления за день» стойке видны (0100, решение владельца — сдать кассу вечером).
  // Итог дня здесь не сверяем: сегодня платят и другие проекты e2e — сумма плавает;
  // сверку с ботом держит pgTAP 0100. Достаточно, что блок есть и не пустой.
  await expect(page.getByText('Поступления за день', { exact: true })).toBeVisible()
  await expect(page.getByText(/операций: \d+/)).toBeVisible()

  await expect(page.getByRole('link', { name: 'Плательщики' }).first()).toBeVisible()
})
