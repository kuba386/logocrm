'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import type { CenterKind } from '@logocrm/core'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { setCenterKind, setCenterModule, type ModulesState } from './actions'

const initialState: ModulesState = {}

const KINDS: { value: CenterKind; title: string; hint: string }[] = [
  { value: 'speech', title: 'Логопедический центр', hint: 'Специалисты, кабинеты, занятия.' },
  { value: 'education', title: 'Учебный центр', hint: 'Преподаватели, аудитории, уроки.' },
]

function Submit({ children, variant = 'default' }: { children: React.ReactNode; variant?: 'default' | 'outline' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" variant={variant} disabled={pending}>
      {children}
    </Button>
  )
}

export function CenterKindForm({ kind }: { kind: CenterKind }) {
  const [state, action] = useActionState(setCenterKind, initialState)
  return (
    <form action={action} className="space-y-3">
      <fieldset className="grid gap-2 sm:grid-cols-2">
        <legend className="sr-only">Тип центра</legend>
        {KINDS.map((item) => (
          <label
            key={item.value}
            className="flex cursor-pointer flex-col gap-1 rounded-md border border-border p-3 text-sm has-[:checked]:border-primary has-[:checked]:bg-primary/5 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring"
          >
            <span className="flex items-center gap-2 font-medium">
              <input type="radio" name="kind" value={item.value} defaultChecked={item.value === kind} className="size-4" />
              {item.title}
            </span>
            <span className="text-muted-foreground">{item.hint}</span>
          </label>
        ))}
      </fieldset>
      <div className="flex flex-wrap items-center gap-3">
        <Submit>Сохранить тип</Submit>
        <FormError message={state.message} />
        <FormNotice message={state.notice} />
      </div>
    </form>
  )
}

export function ModuleToggleForm({ code, enabled }: { code: string; enabled: boolean }) {
  const [state, action] = useActionState(setCenterModule.bind(null, code, !enabled), initialState)
  return (
    <form action={action} className="flex flex-wrap items-center gap-3">
      <Submit variant={enabled ? 'outline' : 'default'}>{enabled ? 'Выключить' : 'Включить'}</Submit>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}
