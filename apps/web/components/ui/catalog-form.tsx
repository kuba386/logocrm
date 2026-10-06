'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import type { CatalogState } from '@/app/app/settings/services/actions'
import { useKeepValuesOnError } from '@/lib/use-keep-values'

const initial: CatalogState = { message: '' }

function SaveButton({ label, variant }: { label: string; variant: 'default' | 'outline' | 'ghost' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {pending ? 'Сохраняем…' : label}
    </Button>
  )
}

/**
 * Общая обвязка для справочников: услуги, кабинеты, группы. Отличаются они
 * только полями, поэтому форма одна, а поля приходят детьми.
 */
export function CatalogForm({
  action,
  children,
  label = 'Сохранить',
  variant = 'default',
  confirm,
}: {
  action: (state: CatalogState, formData: FormData) => Promise<CatalogState>
  children: React.ReactNode
  label?: string
  variant?: 'default' | 'outline' | 'ghost'
  /** Вопрос перед необратимым для пользователя действием («Вывести из группы?»). */
  confirm?: string
}) {
  const [state, formAction] = useActionState(action, initial)
  // Отказ сервера не откатывает правку строки справочника к сохранённой.
  const keep = useKeepValuesOnError(state, Boolean(state.message), (event) => {
    if (confirm && !window.confirm(confirm)) event.preventDefault()
  })

  return (
    <form action={formAction} className="space-y-3" {...keep}>
      {children}
      <FormError message={state.message || undefined} />
      <FormNotice message={state.notice} />
      <SaveButton label={label} variant={variant} />
    </form>
  )
}
