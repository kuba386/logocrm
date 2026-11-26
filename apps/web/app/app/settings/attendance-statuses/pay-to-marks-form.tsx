'use client'

import { useActionState, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'
import { applyStatusPayToMarks, type PayToMarksState } from './actions'

const initial: PayToMarksState = { message: '' }

function Submit({ mode, label, variant }: { mode: 'preview' | 'apply'; label: string; variant: 'default' | 'outline' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" name="mode" value={mode} size="sm" variant={variant} disabled={pending}>
      {pending ? 'Секунду…' : label}
    </Button>
  )
}

/**
 * 0112: перевести прошлые отметки статуса на текущую галочку «Оплачивается
 * специалисту». Сначала счёт без изменений, кнопка «Применить» — только
 * после него и только для той же даты.
 */
export function PayToMarksForm({ statusId, defaultFrom, paysTeacher }: { statusId: string; defaultFrom: string; paysTeacher: boolean }) {
  const [state, action] = useActionState(applyStatusPayToMarks, initial)
  const [from, setFrom] = useState(defaultFrom)
  const [previewedFrom, setPreviewedFrom] = useState<string | null>(null)
  const canApply = Boolean(state.preview) && previewedFrom === from

  return (
    <form
      action={action}
      onSubmit={(event) => {
        const submitter = (event.nativeEvent as SubmitEvent).submitter as HTMLButtonElement | null
        setPreviewedFrom(submitter?.value === 'preview' ? from : null)
      }}
      className="space-y-2 rounded-md border border-border p-3"
    >
      <input type="hidden" name="id" value={statusId} />
      <p className="text-sm font-medium">Прошлые отметки</p>
      <p className="text-xs text-muted-foreground">
        Сейчас у статуса {paysTeacher ? 'включена' : 'выключена'} оплата специалисту. Уже поставленные отметки
        помнят галочку на момент отметки — их можно привести к текущей с выбранной даты.
      </p>
      <div className="flex flex-wrap items-end gap-2">
        <div className="space-y-1">
          <Label htmlFor={`pay-from-${statusId}`}>С даты занятия</Label>
          <Input
            id={`pay-from-${statusId}`}
            name="from"
            type="date"
            value={from}
            onChange={(e) => setFrom(e.target.value)}
            required
            className="w-44"
          />
        </div>
        <Submit mode="preview" label="Посчитать" variant="outline" />
        {canApply ? <Submit mode="apply" label="Применить" variant="default" /> : null}
      </div>
      <FormError message={state.message || undefined} />
      <FormNotice message={state.notice} />
    </form>
  )
}
