import { expect, test } from '@playwright/test'

// Дашборд администратора после этапа 5: деньги месяца из витрин базы
// (revenue_by_month, cash_by_source) и просрочки рассрочек. Суммы здесь не
// сверяются — их держат pgTAP 0021/0018; проверяется, что карточки на месте
// и ведут в «Финансы».

test('Дашборд: карточки выручки, кассы и просрочек ведут в финансы', async ({ page }) => {
  await page.goto('/app')
  await expect(page.getByRole('heading', { name: 'Дашборд' })).toBeVisible()

  await expect(page.getByText('Выручка за месяц', { exact: false })).toBeVisible()
  await expect(page.getByText('Касса за месяц', { exact: false })).toBeVisible()
  await expect(page.getByText(/просроченных платежей по рассрочкам|просрочек по рассрочкам нет/i)).toBeVisible()

  await page.getByRole('link', { name: 'Финансы →' }).click()
  await expect(page.getByRole('heading', { name: 'Финансы' })).toBeVisible()
})
