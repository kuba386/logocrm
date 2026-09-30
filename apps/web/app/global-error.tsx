'use client'

import './globals.css'
import { ErrorScreen } from '@/components/error-screen'

export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <html lang="ru">
      <body>
        <ErrorScreen error={error} reset={reset} />
      </body>
    </html>
  )
}
