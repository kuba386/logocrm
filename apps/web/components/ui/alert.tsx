import * as React from 'react'
import { cn } from '@/lib/utils'

/** Сообщение об ошибке формы. Текст всегда на русском. */
export function FormError({ message }: { message?: string | null }) {
  if (!message) return null
  return (
    <p role="alert" className={cn('rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive')}>
      {message}
    </p>
  )
}

/** Информационное сообщение (например «письмо отправлено»). */
export function FormNotice({ message }: { message?: string | null }) {
  if (!message) return null
  return (
    <p role="status" className="rounded-md bg-accent px-3 py-2 text-sm text-accent-foreground">
      {message}
    </p>
  )
}
