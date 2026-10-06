import * as Sentry from '@sentry/nextjs'
import { sentryOptions } from '@/lib/sentry'

// Сервер (серверные компоненты, server actions, route handlers) и edge
// (middleware). Ошибки рендера на сервере ловит onRequestError.
export function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs' || process.env.NEXT_RUNTIME === 'edge') {
    Sentry.init(sentryOptions())
  }
}

export const onRequestError = Sentry.captureRequestError
