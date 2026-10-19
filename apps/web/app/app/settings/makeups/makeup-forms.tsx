'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'
import { disableMakeups, saveMakeupPolicy, type MakeupPolicyState } from './actions'

const initialState: MakeupPolicyState = {}

function Submit({ children, variant = 'default' }: { children: React.ReactNode; variant?: 'default' | 'outline' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" variant={variant} disabled={pending}>
      {children}
    </Button>
  )
}

export function MakeupPolicyForm({ validDays, limit }: { validDays: number | null; limit: number | null }) {
  const [state, action] = useActionState(saveMakeupPolicy, initialState)
  return (
    <form action={action} className="space-y-4">
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor="validDays">Срок отработки, дней</Label>
          <Input id="validDays" name="validDays" type="number" min={1} max={365} defaultValue={validDays ?? 30} required />
          <p className="text-xs text-muted-foreground">Считается с даты пропуска.</p>
        </div>
        <div className="space-y-1">
          <Label htmlFor="limit">Лимит на один абонемент</Label>
          <Input id="limit" name="limit" type="number" min={1} max={100} defaultValue={limit ?? ''} placeholder="без лимита" />
          <p className="text-xs text-muted-foreground">Сверх лимита пропуск остаётся просто списанным.</p>
        </div>
      </div>
      <div className="flex flex-wrap items-center gap-3">
        <Submit>{validDays ? 'Сохранить' : 'Включить отработки'}</Submit>
        <FormError message={state.message} />
        <FormNotice message={state.notice} />
      </div>
    </form>
  )
}

export function DisableMakeupsForm() {
  const [state, action] = useActionState(disableMakeups, initialState)
  return (
    <form action={action} className="flex flex-wrap items-center gap-3">
      <Submit variant="outline">Выключить отработки</Submit>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}
