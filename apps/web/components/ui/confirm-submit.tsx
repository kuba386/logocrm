'use client'

import { useEffect, useRef, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { t } from '@/lib/messages'

type Variant = 'default' | 'outline' | 'destructive' | 'ghost'

/**
 * Кнопка необратимого действия внутри <form>: первое нажатие не отправляет,
 * а показывает вопрос с итогом («Отменить снимок зарплаты Нургуль за
 * сентябрь — 48 500 сом?») и две кнопки. Фокус встаёт на «Отмена»: случайный
 * двойной тап на телефоне ничего не меняет. Отправка — обычный submit формы,
 * поэтому FormData, name/value кнопки и useActionState работают как раньше.
 *
 * Для действий, где ошибка стоит денег или доступа: зарплата, закрытие
 * месяца, роль, архив, отмена занятий. Аудит UX (правило UX35) от 6.10.2026.
 */
export function ConfirmSubmit({
  label,
  question,
  confirmLabel = t('common', 'confirm'),
  variant = 'outline',
  confirmVariant = 'destructive',
  size = 'sm',
  disabled = false,
  name,
  value,
  formAction,
  onCancel,
}: {
  label: React.ReactNode
  question: React.ReactNode
  confirmLabel?: string
  variant?: Variant
  confirmVariant?: Variant
  size?: 'sm' | 'default'
  disabled?: boolean
  name?: string
  value?: string
  /** Второе действие той же формы (кнопка с formAction), как «Вернуть текст платформы». */
  formAction?: (formData: FormData) => void
  /** Для форм, где вопрос открывается не кнопкой (смена роли в списке): вернуть исходное значение. */
  onCancel?: () => void
}) {
  const [asking, setAsking] = useState(false)
  const { pending } = useFormStatus()
  const wasPending = useRef(false)
  const cancelRef = useRef<HTMLButtonElement>(null)

  // Ответ сервера пришёл — вопрос закрывается; результат покажет форма.
  useEffect(() => {
    if (wasPending.current && !pending) setAsking(false)
    wasPending.current = pending
  }, [pending])

  useEffect(() => {
    if (asking) cancelRef.current?.focus()
  }, [asking])

  if (!asking) {
    return (
      <Button type="button" variant={variant} size={size} disabled={disabled || pending} onClick={() => setAsking(true)}>
        {label}
      </Button>
    )
  }

  return (
    <div role="group" aria-label={typeof label === 'string' ? label : undefined} className="w-full space-y-2 rounded-md border border-destructive/40 bg-destructive/5 p-3">
      <p className="text-sm">{question}</p>
      <div className="flex flex-wrap gap-2">
        <Button type="submit" variant={confirmVariant} size={size} name={name} value={value} formAction={formAction} disabled={pending}>
          {pending ? t('common', 'pending') : confirmLabel}
        </Button>
        <Button
          ref={cancelRef}
          type="button"
          variant="outline"
          size={size}
          disabled={pending}
          onClick={() => {
            setAsking(false)
            onCancel?.()
          }}
        >
          {t('common', 'cancel')}
        </Button>
      </div>
    </div>
  )
}

/**
 * То же для кнопки без формы (onClick → server action через startTransition):
 * «Убрать» цель, ДЗ, оценку; «Отвязать» Telegram. Подтверждение — тем же
 * блоком, фокус на «Отмена».
 */
export function ConfirmAction({
  label,
  question,
  onConfirm,
  pending = false,
  variant = 'ghost',
  size = 'sm',
}: {
  label: React.ReactNode
  question: React.ReactNode
  onConfirm: () => void
  pending?: boolean
  variant?: Variant
  size?: 'sm' | 'default'
}) {
  const [asking, setAsking] = useState(false)
  const cancelRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    if (asking) cancelRef.current?.focus()
  }, [asking])

  if (!asking) {
    return (
      <Button type="button" variant={variant} size={size} disabled={pending} onClick={() => setAsking(true)}>
        {label}
      </Button>
    )
  }

  return (
    <div className="w-full space-y-2 rounded-md border border-destructive/40 bg-destructive/5 p-3">
      <p className="text-sm">{question}</p>
      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          variant="destructive"
          size={size}
          disabled={pending}
          onClick={() => {
            setAsking(false)
            onConfirm()
          }}
        >
          {t('common', 'confirm')}
        </Button>
        <Button ref={cancelRef} type="button" variant="outline" size={size} onClick={() => setAsking(false)}>
          {t('common', 'cancel')}
        </Button>
      </div>
    </div>
  )
}
