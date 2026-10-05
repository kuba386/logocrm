import type { BrowserOptions } from '@sentry/nextjs'

/**
 * Общие настройки Sentry для браузера, сервера и edge (middleware).
 *
 * Включается только DSN-ом: NEXT_PUBLIC_SENTRY_DSN задан лишь в Vercel-проекте
 * logocrm-prod. На staging, локально и в e2e его нет — ошибки туда не уходят
 * и не тратят бесплатный лимит (5 000 ошибок в месяц).
 *
 * Данные детей. По умолчанию Sentry 11 собирает тела запросов (а в них —
 * поля форм: ФИО, заметки, диагнозы), cookie, заголовки, значения локальных
 * переменных в стеке, параметры запросов к базе и тексты для ИИ. Всё это
 * выключено ниже. Session Replay не подключён — запись экрана унесла бы
 * речевые карты к стороннему сервису. Уходит только ошибка, стек кода и адрес
 * страницы (в адресах — только uuid, без имён).
 */
export function sentryOptions(): BrowserOptions {
  const dsn = process.env.NEXT_PUBLIC_SENTRY_DSN
  return {
    dsn,
    enabled: Boolean(dsn),
    environment: process.env.NEXT_PUBLIC_VERCEL_ENV ?? process.env.NODE_ENV,
    dataCollection: {
      userInfo: false,
      cookies: false,
      httpHeaders: false,
      httpBodies: [],
      urlQueryParams: false,
      databaseQueryData: false,
      stackFrameVariables: false,
      genAI: { inputs: false, outputs: false },
      graphQL: { document: false, variables: false },
      queues: false,
    },
    // Производительность — выборочно: лимит бесплатного плана на трассы мал.
    tracesSampleRate: 0.1,
  }
}
