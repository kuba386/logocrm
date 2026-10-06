'use client'

import { useEffect, useState } from 'react'
import * as Sentry from '@sentry/nextjs'
import Link from 'next/link'
import { Button, buttonVariants } from '@/components/ui/button'

// Ошибка уходит в Sentry (на prod, lib/sentry.ts). Технические детали всё
// равно видны пользователю: снимок экрана с digest помогает найти событие
// в Sentry, а на staging Sentry нет вовсе.
//
// embedded — ошибка страницы внутри /app: шапка и меню остаются (их рисует
// layout), поэтому здесь не <main> во весь экран, а блок с выходом «На дашборд».
export function ErrorScreen({
  error,
  reset,
  embedded = false,
}: {
  error: Error & { digest?: string }
  reset: () => void
  embedded?: boolean
}) {
  const [userAgent, setUserAgent] = useState('')

  useEffect(() => {
    setUserAgent(navigator.userAgent)
    console.error(error)
    Sentry.captureException(error)
  }, [error])

  const Wrapper = embedded ? 'div' : 'main'

  return (
    <Wrapper className={embedded ? 'flex justify-center py-10' : 'flex min-h-screen items-center justify-center p-6'}>
      <div role={embedded ? 'alert' : undefined} className="w-full max-w-md space-y-4 text-center">
        <h1 className="page-title">Что-то пошло не так</h1>
        <p className="text-sm text-muted-foreground">
          Страница не загрузилась. Попробуйте обновить её. Если ошибка повторяется — пришлите
          снимок этого экрана в поддержку.
        </p>
        <div className="flex flex-col gap-2">
          <Button onClick={() => reset()}>Попробовать ещё раз</Button>
          <Button variant="outline" onClick={() => window.location.reload()}>
            Обновить страницу
          </Button>
          {embedded ? (
            <Link href="/app" className={buttonVariants({ variant: 'ghost' })}>
              На дашборд
            </Link>
          ) : null}
        </div>
        <div className="break-words rounded-md border bg-muted/40 p-3 text-left font-mono text-xs text-muted-foreground">
          <div>{error.message || error.name}</div>
          {error.digest && <div>digest: {error.digest}</div>}
          {userAgent && <div className="mt-2">{userAgent}</div>}
        </div>
      </div>
    </Wrapper>
  )
}
