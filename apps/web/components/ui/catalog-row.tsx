'use client'

import { useState, type ReactNode } from 'react'
import { Button } from '@/components/ui/button'

/**
 * Строка справочника: сводка и «Изменить», форма раскрывается по запросу.
 * Раньше каждая строка была открытой формой — список из десяти кабинетов
 * превращался в десять форм, а подписи полей повторялись на странице.
 */
export function CatalogRow({
  title,
  meta,
  badge,
  children,
}: {
  title: ReactNode
  meta?: ReactNode
  badge?: ReactNode
  children: ReactNode
}) {
  const [open, setOpen] = useState(false)

  return (
    <li className="py-3">
      <div className="flex items-center gap-3">
        <div className="min-w-0 flex-1">
          <p className="truncate font-medium">{title}</p>
          {meta ? <p className="text-sm text-muted-foreground">{meta}</p> : null}
        </div>
        {badge}
        <Button type="button" variant="ghost" size="sm" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
          {open ? 'Свернуть' : 'Изменить'}
        </Button>
      </div>
      {open ? <div className="mt-3 rounded-md border border-border bg-muted/40 p-3">{children}</div> : null}
    </li>
  )
}
