import * as Sentry from '@sentry/nextjs'
import { sentryOptions } from '@/lib/sentry'

// Браузер: необработанные исключения и падения клиентских компонентов.
Sentry.init(sentryOptions())

export const onRouterTransitionStart = Sentry.captureRouterTransitionStart
