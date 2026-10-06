'use client'

import { useLinkStatus } from 'next/link'
import { cn } from '@/lib/utils'

/**
 * Точка у пункта меню, пока сервер собирает страницу после клика: клик
 * отзывается сразу (UX-аудит, пакет 8). Не loading.tsx: Suspense-граница над
 * всеми страницами /app превращала redirect() в клиентский переход (200 вместо
 * 307) и ломала завершение серверных действий — e2e #221. Задержка 150 мс —
 * быстрый переход не мигает точкой. Ставится только внутри <Link>.
 */
export function LinkPending({ className }: { className?: string }) {
  const { pending } = useLinkStatus()
  return (
    <span
      aria-hidden="true"
      className={cn(
        'size-1.5 shrink-0 rounded-full bg-primary transition-opacity motion-safe:animate-pulse',
        pending ? 'opacity-100 delay-150' : 'opacity-0',
        className,
      )}
    />
  )
}
