'use client'

import { ErrorScreen } from '@/components/error-screen'

// Ошибка страницы внутри /app: шапка и меню остаются, человек уходит
// на другой раздел, а не упирается в экран без навигации (UX-аудит, пакет 8).
export default function AppError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <ErrorScreen error={error} reset={reset} embedded />
}
