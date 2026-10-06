'use client'

import * as React from 'react'
import { X } from 'lucide-react'
import { cn } from '@/lib/utils'

/**
 * Диалог на нативном <dialog>: showModal() даёт фокус-трап, Esc и backdrop
 * из коробки. Радикс сюда не тянем — лишняя зависимость ради одного окна.
 */
export function Dialog({
  open,
  onClose,
  title,
  description,
  children,
  className,
}: {
  open: boolean
  onClose: () => void
  title: string
  description?: string
  children: React.ReactNode
  className?: string
}) {
  const ref = React.useRef<HTMLDialogElement>(null)
  const titleId = React.useId()
  const descriptionId = React.useId()

  React.useEffect(() => {
    const dialog = ref.current
    if (!dialog) return

    if (open && !dialog.open) {
      dialog.showModal()
      // showModal() ставит фокус на первый фокусируемый элемент — это был
      // крестик «Закрыть». Человек открыл окно, чтобы заполнить его: фокус —
      // в первое поле, если оно есть (UX-аудит, пакет 7).
      const field = dialog.querySelector<HTMLElement>('input:not([type=hidden]):not([disabled]), select:not([disabled]), textarea:not([disabled])')
      field?.focus()
    }
    if (!open && dialog.open) dialog.close()
  }, [open])

  return (
    <dialog
      ref={ref}
      aria-labelledby={titleId}
      aria-describedby={description ? descriptionId : undefined}
      onClose={onClose}
      onCancel={onClose}
      className={cn(
        'w-full max-w-lg rounded-lg border border-border bg-card p-0 text-card-foreground shadow-lg backdrop:bg-black/40',
        className,
      )}
    >
      <div className="space-y-4 p-6">
        <div className="flex items-start justify-between gap-4">
          <div className="space-y-1">
            <h2 id={titleId} className="font-display text-lg font-medium tracking-tight">{title}</h2>
            {description ? <p id={descriptionId} className="text-sm text-muted-foreground">{description}</p> : null}
          </div>
          <button
            type="button"
            aria-label="Закрыть окно"
            onClick={onClose}
            className="-mr-2 -mt-1 rounded-md p-3 text-muted-foreground sm:p-1.5 hover:bg-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            <X className="size-4" aria-hidden="true" />
          </button>
        </div>
        {children}
      </div>
    </dialog>
  )
}
