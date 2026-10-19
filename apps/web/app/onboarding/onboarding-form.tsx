'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { createCenter, type OnboardingState } from './actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError } from '@/components/ui/alert'
import { useKeepValuesOnError } from '@/lib/use-keep-values'

const initialState: OnboardingState = {}

// 0104: тип центра задаёт стартовые модули и слова интерфейса (ADR-013).
const CENTER_KINDS = [
  {
    value: 'speech',
    title: 'Логопедический центр',
    hint: 'Логопеды и дефектологи: обследование, речевые цели, заключения.',
  },
  {
    value: 'education',
    title: 'Учебный центр',
    hint: 'Языковые школы, подготовка к школе, кружки: группы и уроки.',
  },
] as const

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
  const keep = useKeepValuesOnError(state, Boolean(state.error))

  return (
    <form action={formAction} className="space-y-4" {...keep}>
      <div className="space-y-2">
        <Label htmlFor="name">Название центра</Label>
        <Input id="name" name="name" placeholder="Логопед Плюс" required minLength={2} />
      </div>

      <fieldset className="space-y-2">
        <legend className="text-sm font-medium">Тип центра</legend>
        <div className="grid gap-2 sm:grid-cols-2">
          {CENTER_KINDS.map((kind) => (
            <label
              key={kind.value}
              className="flex cursor-pointer flex-col gap-1 rounded-md border border-border p-3 text-sm has-[:checked]:border-primary has-[:checked]:bg-primary/5 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring"
            >
              <span className="flex items-center gap-2 font-medium">
                <input type="radio" name="kind" value={kind.value} defaultChecked={kind.value === 'speech'} className="size-4" />
                {kind.title}
              </span>
              <span className="text-muted-foreground">{kind.hint}</span>
            </label>
          ))}
        </div>
        <p className="text-xs text-muted-foreground">Тип можно сменить позже в настройках, данные не пропадут.</p>
      </fieldset>

      <div className="space-y-2">
        <Label htmlFor="city">Город</Label>
        <Input id="city" name="city" placeholder="Бишкек" required minLength={2} defaultValue="Бишкек" />
      </div>

      <FormError message={state.error} />

      <SubmitButton />
    </form>
  )
}
