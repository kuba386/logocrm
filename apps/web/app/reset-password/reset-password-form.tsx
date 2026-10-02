'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { updatePassword, type AuthState } from '@/app/login/actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError } from '@/components/ui/alert'

const initialState: AuthState = {}

function SubmitButton() {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" className="w-full" disabled={pending}>
      {pending ? 'Сохраняем…' : 'Сохранить пароль'}
    </Button>
  )
}

export function ResetPasswordForm() {
  const [state, action] = useActionState(updatePassword, initialState)

  return (
    <form action={action} className="space-y-4">
      <div className="space-y-2">
        <Label htmlFor="password">Новый пароль</Label>
        <Input id="password" name="password" type="password" autoComplete="new-password" minLength={6} required />
      </div>
      <div className="space-y-2">
        <Label htmlFor="confirm">Повторите пароль</Label>
        <Input id="confirm" name="confirm" type="password" autoComplete="new-password" minLength={6} required />
      </div>
      <FormError message={state.error} />
      <SubmitButton />
    </form>
  )
}
