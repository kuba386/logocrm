import { defineConfig, devices } from '@playwright/test'

const baseURL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:3000'

export default defineConfig({
  testDir: './e2e',

  // Тесты делят одну базу, и половина сценариев проверяет именно состояние:
  // накладку с уже существующим занятием, отмену серии с середины, отпуск.
  // Параллельный прогон превратил бы их в лотерею, поэтому один воркер.
  fullyParallel: false,
  workers: 1,

  forbidOnly: !!process.env.CI,

  // Повторов нет, и это не экономия. serial перезапускает файл с начала, но
  // базу не сбрасывает: занятие, созданное первой попыткой, остаётся, и
  // повтор падает уже на «Занятие создано» — получив вместо него конфликт.
  // Проверено первым прогоном в CI. Нестабильность лечится только сбросом
  // состояния между попытками, а его здесь нет.
  retries: 0,

  // На холодном раннере один сценарий делает до трёх заполнений диалога с
  // перезагрузкой и ждёт несколько ответов сервера — 30 секунд там мало.
  timeout: process.env.CI ? 90_000 : 30_000,
  expect: { timeout: 10_000 },

  reporter: process.env.CI
    ? [['github'], ['html', { open: 'never' }]]
    : [['list']],

  use: {
    baseURL,
    locale: 'ru-RU',

    // Часовой пояс браузера намеренно НЕ совпадает с часовым поясом центра
    // (Москва UTC+3 против Бишкека UTC+6). Правило проекта — время
    // рендерится в поясе центра, а не браузера. При обычном совпадении
    // поясов нарушение этого правила осталось бы незамеченным: занятие
    // на 11:00 показывалось бы как 11:00 в обоих случаях.
    timezoneId: 'Europe/Moscow',

    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',

    // В CI — Chromium из комплекта Playwright. На машине разработки его нет:
    // Playwright не собирает Chromium под macOS 13. Там задаётся
    // E2E_CHANNEL=chrome, и тесты идут в системном Google Chrome.
    ...(process.env.E2E_CHANNEL ? { channel: process.env.E2E_CHANNEL } : {}),
  },

  projects: [
    { name: 'setup', testMatch: /auth\.setup\.ts/ },

    {
      name: 'admin',
      testMatch: /schedule\.spec\.ts/,
      dependencies: ['setup'],
      use: { ...devices['Desktop Chrome'], storageState: 'e2e/.auth/owner.json' },
    },
    {
      name: 'teacher',
      testMatch: /teacher\.spec\.ts/,
      dependencies: ['setup', 'admin'],
      use: { ...devices['Desktop Chrome'], storageState: 'e2e/.auth/teacher.json' },
    },
    {
      name: 'parent',
      testMatch: /parent\.spec\.ts/,
      // После teacher, а не рядом с ним: оба читают одну неделю фикстуры, и
      // teacher её мутирует (отмечает занятие проведённым). Порядок соседей
      // Playwright не гарантирует — задаём явно.
      dependencies: ['setup', 'admin', 'teacher'],
      use: { ...devices['Desktop Chrome'], storageState: 'e2e/.auth/parent.json' },
    },
  ],

  webServer: {
    command: 'pnpm start',
    url: baseURL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
})
