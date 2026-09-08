'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import type { CatalogState } from '@/app/app/settings/services/actions'

const initial: CatalogState = { message: '' }

function SaveButton({ label }: { label: string }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" disabled={pending}>
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
}: {
  action: (state: CatalogState, formData: FormData) => Promise<CatalogState>
  children: React.ReactNode
  label?: string
}) {
  const [state, formAction] = useActionState(action, initial)

  return (
    <form action={formAction} className="space-y-3">
      {children}
      <FormError message={state.message || undefined} />
      <FormNotice message={state.notice} />
      <SaveButton label={label} />
    </form>
  )
}
