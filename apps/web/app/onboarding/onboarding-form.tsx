'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { createCenter, type OnboardingState } from './actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError } from '@/components/ui/alert'

const initialState: OnboardingState = {}

function SubmitButton() {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" className="w-full" disabled={pending}>
      {pending ? 'Создаём…' : 'Создать центр'}
    </Button>
  )
}

export function OnboardingForm() {
  const [state, formAction] = useActionState(createCenter, initialState)

  return (
    <form action={formAction} className="space-y-4">
      <div className="space-y-2">
        <Label htmlFor="name">Название центра</Label>
        <Input id="name" name="name" placeholder="Логопед Плюс" required minLength={2} />
      </div>

      <div className="space-y-2">
        <Label htmlFor="city">Город</Label>
        <Input id="city" name="city" placeholder="Бишкек" required minLength={2} defaultValue="Бишкек" />
      </div>

      <FormError message={state.error} />

      <SubmitButton />
    </form>
  )
}
