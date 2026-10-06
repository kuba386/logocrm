import { expect, test, type Page } from '@playwright/test'

// Обход всех страниц под каждой ролью. Сценарии проверяют логику, а этот
// файл — что ни одна страница не падает: ни у роли, которой она нужна, ни у
// той, которую она должна молча увести (redirect), а не показать ей ошибку.
//
// Только чтение: ни одной формы не отправляет, поэтому порядок относительно
// других проектов не важен.
//
// Падение — это:
//   - ответ 5xx (упал серверный компонент);
//   - 404 на статическом маршруте (страницу удалили или переименовали);
//   - экран «Что-то пошло не так» (app/error.tsx) или «Application error»;
//   - ошибка в консоли браузера или необработанное исключение на странице.

const STATIC_ROUTES = [
  '/app',
  '/app/schedule',
  '/app/students',
  '/app/groups',
  '/app/bookings',
  '/app/library',
  '/app/payers',
  '/app/debts',
  '/app/finance',
  '/app/finance?tab=expenses',
  '/app/finance?tab=payments',
  '/app/finance?tab=installments',
  '/app/salary',
  '/app/my-salary',
  '/app/reports',
  '/app/assistant',
  '/app/notifications',
  '/app/funnel',
  '/app/telegram',
  '/app/settings/staff',
  '/app/settings/rooms',
  '/app/settings/services',
  '/app/settings/attendance-statuses',
  '/app/settings/subscription-types',
  '/app/settings/teacher-rates',
  '/app/settings/notifications',
  '/app/settings/plan',
  '/admin',
  '/select-center',
  '/onboarding',
]

// Не обходятся здесь:
//   /app/schedule/lessons/[id]/complete — открывается из teacher.spec.ts
//     со своими данными;
//   /error — сама и есть экран «Что-то пошло не так» (ссылка из письма не
//     сработала), проверка ошибки на ней падала бы всегда.
// /book/centr-e2e — витрина e2e-центра: SUPABASE_BOOKING_JWT в CI выпускает
// шаг «Переменные локального стека». Запись закрыта, пока owner-flows её не
// откроет, — страница «запись недоступна» тоже должна открываться без ошибок.
const GUEST_ROUTES = [
  '/',
  '/login',
  '/reset-password',
  '/access-revoked',
  '/invite/nonexistent-token',
  '/app',
  ...(process.env.SUPABASE_BOOKING_JWT ? ['/book/centr-e2e'] : []),
]

const ROLES = [
  { name: 'владелец', state: 'e2e/.auth/owner.json' },
  { name: 'администратор', state: 'e2e/.auth/admin.json' },
  { name: 'специалист', state: 'e2e/.auth/teacher.json' },
  { name: 'родитель', state: 'e2e/.auth/parent.json' },
] as const

// Шум, не относящийся к приложению. Каждая строка — с причиной.
const IGNORED_CONSOLE = [
  // Браузер сам пишет в консоль 404 favicon и т.п. — сами ответы проверяются статусом.
  /Failed to load resource/,
]

async function expectPageHealthy(page: Page, path: string, { allow404 = false } = {}) {
  const problems: string[] = []
  const onConsole = (message: { type(): string; text(): string }) => {
    if (message.type() === 'error' && !IGNORED_CONSOLE.some((re) => re.test(message.text()))) {
      problems.push(`консоль: ${message.text()}`)
    }
  }
  const onPageError = (error: Error) => problems.push(`исключение: ${error.message}`)
  page.on('console', onConsole)
  page.on('pageerror', onPageError)

  try {
    const response = await page.goto(path)
    const status = response?.status() ?? 0
    expect(status, `${path}: ответ сервера`).toBeLessThan(500)
    if (!allow404) expect(status, `${path}: страница не найдена`).not.toBe(404)

    await expect(page.locator('body')).not.toBeEmpty()
    await expect(page.getByRole('heading', { name: 'Что-то пошло не так' }), `${path}: экран ошибки`).toHaveCount(0)
    await expect(page.getByText('Application error', { exact: false }), `${path}: Application error`).toHaveCount(0)

    // Дать клиентским компонентам гидратироваться и отработать эффекты — ошибки
    // гидратации и эффектов приходят в консоль уже после load.
    await page.waitForLoadState('networkidle', { timeout: 5_000 }).catch(() => {})
    expect(problems, `${path}: ошибки в браузере`).toEqual([])
  } finally {
    page.off('console', onConsole)
    page.off('pageerror', onPageError)
  }
}

test.describe('гость', () => {
  test.use({ storageState: { cookies: [], origins: [] } })

  for (const path of GUEST_ROUTES) {
    test(`гость: ${path}`, async ({ page }) => {
      await expectPageHealthy(page, path)
    })
  }
})

for (const role of ROLES) {
  test.describe(role.name, () => {
    test.use({ storageState: role.state })

    for (const path of STATIC_ROUTES) {
      test(`${role.name}: ${path}`, async ({ page }) => {
        await expectPageHealthy(page, path)
      })
    }

    // Карточки ученика и плательщика — по первой ссылке из того, что роль
    // видит сама: id в тесте не зашиты, а роль без доступа к списку просто
    // не найдёт ссылок, и проверять нечего.
    test(`${role.name}: карточки из списков`, async ({ page }) => {
      // Три списка и до двух карточек в одном тесте — больше переходов, чем у остальных.
      test.setTimeout(180_000)
      const found = new Set<string>()
      for (const list of ['/app', '/app/students', '/app/payers']) {
        await page.goto(list)
        const hrefs = await page
          .locator('a[href^="/app/students/"], a[href^="/app/payers/"]')
          .evaluateAll((links) => links.map((a) => a.getAttribute('href') ?? ''))
        for (const prefix of ['/app/students/', '/app/payers/']) {
          const first = hrefs.find((h) => h.startsWith(prefix) && !h.includes('#') && !h.includes('?'))
          if (first) found.add(first)
        }
      }
      for (const path of found) {
        await expectPageHealthy(page, path, { allow404: false })
      }
    })
  })
}
