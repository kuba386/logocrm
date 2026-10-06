'use client'

import { useFormStatus } from 'react-dom'
import { Button, type ButtonProps } from '@/components/ui/button'

/**
 * Кнопка отправки, которая не нажимается второй раз, пока форма ждёт ответа.
 * Двойной тап по «Завести» или «Выдать» на медленной сети создавал две цели
 * или два ДЗ (UX-аудит 6.10.2026, пакет 5, правило UX32). Работает только
 * внутри <form action> — useFormStatus знает о своей форме.
 */
export function SubmitButton({
  pendingLabel,
  children,
  disabled,
  ...props
}: ButtonProps & { pendingLabel?: React.ReactNode }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" disabled={disabled || pending} aria-busy={pending || undefined} {...props}>
      {pending && pendingLabel ? pendingLabel : children}
    </Button>
  )
}
