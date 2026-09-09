import { test as setup, expect } from '@playwright/test'

import { PASSWORD, USERS } from './fixtures'

// Вход делается через форму, а не подкладыванием токена. Причина: приложение
// хранит сессию в cookie через @supabase/ssr, и формат этих cookie —
// внутреннее дело библиотеки. Тест, который собирает их сам, ломается на
// следующем обновлении зависимости и при этом выглядит как поломка функции.

const ROLES = [
  { name: 'owner', email: USERS.owner },
  { name: 'teacher', email: USERS.teacher },
  { name: 'parent', email: USERS.parent },
] as const

for (const role of ROLES) {
  setup(`вход под ролью ${role.name}`, async ({ page }) => {
    await page.goto('/login')

    await page.locator('#email').fill(role.email)
    await page.locator('#password').fill(PASSWORD)
    await page.getByRole('button', { name: 'Войти', exact: true }).click()

    // Ждём именно ухода с /login: успешный вход перекидывает внутрь /app.
    // Проверка «нет сообщения об ошибке» здесь не годится — она проходит и
    // на странице, которая просто ещё не ответила.
    //
    // Путь заякорен сразу после хоста. Незаякоренная регулярка совпадала и
    // с /login?next=/app — туда middleware возвращает при несохранившейся
    // сессии, и setup «проходил», записывая пустой storageState. Падение
    // тогда уезжало в другие тесты с невнятным «heading не найден».
    await expect(page).toHaveURL(/^https?:\/\/[^/]+\/app(\/|$)/, { timeout: 20_000 })

    await page.context().storageState({ path: `e2e/.auth/${role.name}.json` })
  })
}
