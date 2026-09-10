'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError } from '@/components/ui/alert'
import type { CatalogState } from '@/app/app/settings/services/actions'

const initial: CatalogState = { message: '' }

function ToggleButton({ label }: { label: string }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant="outline" disabled={pending}>
      {pending ? '…' : label}
    </Button>
  )
}

/**
 * Кнопка-действие для справочников (архив, восстановление, «сделать
 * по умолчанию»): та же обвязка useActionState, что CatalogForm, но без
 * полей формы — только id и однозначный RPC-эффект.
 */
export function CatalogAction({
  id,
  action,
  label,
}: {
  id: string
  action: (state: CatalogState, formData: FormData) => Promise<CatalogState>
  label: string
}) {
  const [state, formAction] = useActionState(action, initial)

  return (
    <form action={formAction} className="flex items-center gap-2">
      <input type="hidden" name="id" value={id} />
      <ToggleButton label={label} />
      <FormError message={state.message || undefined} />
    </form>
  )
}
