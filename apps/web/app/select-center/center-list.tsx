'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { switchCenter, type SelectCenterState } from './actions'
import { Button } from '@/components/ui/button'
import { FormError } from '@/components/ui/alert'

const initialState: SelectCenterState = {}

const ROLE_LABELS: Record<string, string> = {
  owner: 'Владелец',
  admin: 'Администратор',
  teacher: 'Логопед',
  parent: 'Родитель',
}

export type CenterOption = {
  centerId: string
  name: string
  role: string
  isCurrent: boolean
  deleted: boolean
}

function SubmitButton({ isCurrent }: { isCurrent: boolean }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" variant={isCurrent ? 'outline' : 'default'} size="sm" disabled={pending}>
      {pending ? 'Переключаем…' : isCurrent ? 'Продолжить' : 'Выбрать'}
    </Button>
  )
}

export function CenterList({ centers }: { centers: CenterOption[] }) {
  const [state, formAction] = useActionState(switchCenter, initialState)

  return (
    <div className="space-y-3">
      <FormError message={state.error} />

      <ul className="space-y-2">
        {centers.map((center) => (
          <li
            key={center.centerId}
            className="flex items-center justify-between gap-4 rounded-md border border-border p-4"
          >
            <div>
              <p className="font-medium">{center.name}</p>
              <p className="text-sm text-muted-foreground">
                {ROLE_LABELS[center.role] ?? center.role}
                {center.isCurrent ? ' · текущий' : ''}
                {center.deleted ? ' · помечен на удаление' : ''}
              </p>
            </div>
            <form action={formAction}>
              <input type="hidden" name="centerId" value={center.centerId} />
              <SubmitButton isCurrent={center.isCurrent} />
            </form>
          </li>
        ))}
      </ul>
    </div>
  )
}
