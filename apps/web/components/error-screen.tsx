'use client'

import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'

// Технические детали видны пользователю: Sentry в приложении нет, и
// скриншот этого экрана — единственный способ узнать причину сбоя на
// чужом устройстве (встроенный браузер Telegram, старый iOS).
export function ErrorScreen({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  const [userAgent, setUserAgent] = useState('')

  useEffect(() => {
    setUserAgent(navigator.userAgent)
    console.error(error)
  }, [error])

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <div className="w-full max-w-md space-y-4 text-center">
        <h1 className="text-2xl font-semibold">Что-то пошло не так</h1>
        <p className="text-sm text-muted-foreground">
          Страница не загрузилась. Попробуйте обновить её. Если ошибка повторяется — пришлите
          снимок этого экрана в поддержку.
        </p>
        <div className="flex flex-col gap-2">
          <Button onClick={() => reset()}>Попробовать ещё раз</Button>
          <Button variant="outline" onClick={() => window.location.reload()}>
            Обновить страницу
          </Button>
        </div>
        <div className="break-words rounded-md border bg-muted/40 p-3 text-left font-mono text-xs text-muted-foreground">
          <div>{error.message || error.name}</div>
          {error.digest && <div>digest: {error.digest}</div>}
          {userAgent && <div className="mt-2">{userAgent}</div>}
        </div>
      </div>
    </main>
  )
}
