import { expect, test } from '@playwright/test'

// Дашборд администратора после этапа 5: деньги месяца из витрин базы
// (revenue_by_month, cash_by_source) и просрочки рассрочек — плитками
// показателей. Суммы здесь не сверяются — их держат pgTAP 0021/0018;
// проверяется, что плитки на месте и ведут в «Финансы».

test('Дашборд: плитки выручки, кассы и просрочек ведут в финансы', async ({ page }) => {
  await page.goto('/app')
  await expect(page.getByRole('heading', { name: 'Дашборд' })).toBeVisible()

  await expect(page.getByRole('link', { name: /Выручка за месяц/ })).toBeVisible()
  await expect(page.getByRole('link', { name: /Просроченных платежей по рассрочкам/ })).toBeVisible()

  await page.getByRole('link', { name: /Касса за месяц/ }).click()
  await expect(page.getByRole('heading', { name: 'Финансы' })).toBeVisible()
})
