import { expect, test } from '@playwright/test'

import { PASSWORD } from './fixtures'

// Сквозные пути владельца, которые касаются второго человека: специалист
// по ссылке приглашения, родитель на витрине онлайн-записи. Второй человек —
// отдельный контекст браузера без сессии, как чужой телефон.
//
// Проект owner-flows идёт после teacher/parent: подтверждение заявки создаёт
// ученика и занятие, приглашение — карточку специалиста.

function guestContext(browser: import('@playwright/test').Browser) {
  return browser.newContext({ storageState: { cookies: [], origins: [] } })
}

function isoDayFromNow(days: number): string {
  return new Date(Date.now() + days * 86_400_000).toISOString().slice(0, 10)
}

test('Приглашение специалиста: ссылка → регистрация → он в центре', async ({ page, browser }) => {
  const stamp = Date.now()
  const name = `Приглашённая ${stamp}`
  const email = `invited-${stamp}@logocrm.kg`

  await page.goto('/app/settings/staff')
  await page.getByRole('button', { name: 'Пригласить', exact: true }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog.getByLabel('Роль')).toHaveValue('teacher')
  await dialog.locator('#fullName').fill(name)
  await dialog.getByRole('button', { name: 'Создать ссылку' }).click()

  const linkBox = dialog.locator('.break-all')
  await expect(linkBox).toContainText('/invite/')
  const inviteUrl = (await linkBox.innerText()).trim()

  // #198: после первой ссылки окно даёт пригласить следующего, а не держит старую.
  await dialog.getByRole('button', { name: 'Пригласить ещё' }).click()
  await expect(dialog.getByRole('button', { name: 'Создать ссылку' })).toBeVisible()
  await dialog.getByRole('button', { name: 'Отмена' }).click()

  const guest = await guestContext(browser)
  const invited = await guest.newPage()
  // Путь, а не полный адрес: ссылка собрана из NEXT_PUBLIC_SITE_URL, тест идёт по baseURL.
  await invited.goto(new URL(inviteUrl).pathname)
  await expect(invited.getByText(/приглашает вас как специалист/)).toBeVisible()

  await invited.locator('#email').fill(email)
  await invited.locator('#password').fill(PASSWORD)
  await invited.getByRole('button', { name: 'Зарегистрироваться и войти' }).click()

  await expect(invited).toHaveURL(/^https?:\/\/[^/]+\/app(\/|$)/, { timeout: 20_000 })
  await expect(invited.getByRole('heading', { name: 'Дашборд' })).toBeVisible()
  // Вошёл именно в центр владельца: имя центра в шапке меню.
  await expect(invited.getByText('Центр e2e').first()).toBeVisible()
  await guest.close()
})

test('Онлайн-запись: открыть запись → заявка родителя → подтверждение → ученик', async ({ page, browser }) => {
  // Витрина ходит в базу по токену роли public_booking (0057); в CI его
  // выпускает шаг «Переменные локального стека», локально — по желанию.
  test.skip(!process.env.SUPABASE_BOOKING_JWT, 'нет SUPABASE_BOOKING_JWT — витрина записи не работает')

  await page.goto('/app/settings/plan')
  const booking = page.locator('#booking')
  const open = booking.getByRole('button', { name: 'Открыть запись' })
  if (await open.isVisible()) await open.click()
  await expect(booking.getByRole('button', { name: 'Закрыть запись' })).toBeVisible()

  const child = `Запись e2e ${Date.now()}`
  const guest = await guestContext(browser)
  const parent = await guest.newPage()
  await parent.goto('/book/centr-e2e')
  // Далеко от занятий фикстуры (март 2027) и в пределах 90 дней, ранним утром —
  // специалист в это время точно свободен.
  await parent.locator('#date').fill(isoDayFromNow(40))
  await parent.locator('#time').fill('07:15')
  await parent.locator('#childName').fill(child)
  await parent.locator('#parentName').fill('Родитель записи')
  await parent.locator('#parentPhone').fill('0700 55 66 77')
  await parent.getByRole('button', { name: 'Отправить заявку' }).click()
  await expect(parent.getByText('Заявка отправлена!')).toBeVisible({ timeout: 20_000 })
  await guest.close()

  await page.goto('/app/bookings')
  const row = page.locator('tr', { hasText: child })
  await expect(row).toBeVisible()
  await row.getByRole('button', { name: 'Подтвердить' }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog).toBeVisible()
  await dialog.getByRole('button', { name: 'Подтвердить' }).click()

  // Итог, а не уведомление: строка уходит из очереди вместе с диалогом
  // (memory: форма, которая прячет себя при успехе).
  await expect(page.locator('tr', { hasText: child })).toHaveCount(0, { timeout: 20_000 })
  await page.goto('/app/students')
  await expect(page.getByRole('link', { name: child })).toBeVisible()
})

test('Долги → «Продать абонемент» открывает карточку на вкладке абонементов', async ({ page }) => {
  // Долг у Амины создаёт attendance-subscriptions.spec.ts (проект admin, раньше этого).
  await page.goto('/app/debts')
  const sell = page.getByRole('link', { name: 'Продать абонемент' }).first()
  await expect(sell).toBeVisible()
  await sell.click()

  await expect(page).toHaveURL(/\/app\/students\/[0-9a-f-]+#subscriptions$/)
  await expect(page.getByRole('tab', { name: 'Абонементы' })).toHaveAttribute('aria-selected', 'true')
  await expect(page.locator('select#typeId')).toBeVisible()
})
