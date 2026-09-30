import Link from 'next/link'
import type { ReactNode } from 'react'
import { ChevronLeft } from 'lucide-react'

/**
 * Шапка страницы: «назад», заголовок, описание, действия справа (на телефоне —
 * под заголовком). Одна на все разделы, чтобы кнопка «Добавить…» и ссылка
 * назад всегда были на одном месте.
 */
export function PageHeader({
  title,
  description,
  actions,
  back,
  aside,
}: {
  title: ReactNode
  description?: ReactNode
  actions?: ReactNode
  back?: { href: string; label: string }
  aside?: ReactNode
}) {
  return (
    <div className="space-y-2">
      {back ? (
        <Link
          href={back.href}
          className="-ml-1 inline-flex items-center gap-0.5 rounded-md text-sm text-muted-foreground hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
        >
          <ChevronLeft className="size-4" />
          {back.label}
        </Link>
      ) : null}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 space-y-1">
          <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
            <h1 className="page-title">{title}</h1>
            {aside}
          </div>
          {description ? <p className="max-w-prose text-sm text-muted-foreground">{description}</p> : null}
        </div>
        {actions ? <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div> : null}
      </div>
    </div>
  )
}
