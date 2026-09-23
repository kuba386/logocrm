'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { archiveStudent, restoreStudent, updateStudent, type StudentState } from '../actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'

const initialState: StudentState = {}

export type StudentFormValues = {
  id: string
  fullName: string
  birthDate: string | null
  gender: string | null
  status: string
  primaryTeacherId: string | null
  source: string | null
  notes: string | null
}

function SaveButton() {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" disabled={pending}>
      {pending ? 'Сохраняем…' : 'Сохранить'}
    </Button>
  )
}

export function StudentForm({
  student,
  teachers,
  canEdit,
}: {
  student: StudentFormValues
  teachers: { id: string; fullName: string }[]
  canEdit: boolean
}) {
  const [state, formAction] = useActionState(updateStudent, initialState)
  const [archiveState, archiveAction] = useActionState(archiveStudent, initialState)
  const [restoreState, restoreAction] = useActionState(restoreStudent, initialState)

  if (!canEdit) {
    return (
      <dl className="grid gap-3 sm:grid-cols-2">
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Дата рождения</dt>
          <dd>{student.birthDate ?? '—'}</dd>
        </div>
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Пол</dt>
          <dd>{student.gender === 'м' ? 'Мальчик' : student.gender === 'ж' ? 'Девочка' : '—'}</dd>
        </div>
        <div className="sm:col-span-2">
          <dt className="text-xs uppercase text-muted-foreground">Заметка</dt>
          <dd className="whitespace-pre-line">{student.notes ?? '—'}</dd>
        </div>
      </dl>
    )
  }

  return (
    <div className="space-y-4">
      <form action={formAction} className="space-y-4">
        <input type="hidden" name="id" value={student.id} />

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2 sm:col-span-2">
            <Label htmlFor="fullName">ФИО</Label>
            <Input id="fullName" name="fullName" defaultValue={student.fullName} required minLength={2} />
          </div>

          <div className="space-y-2">
            <Label htmlFor="birthDate">Дата рождения</Label>
            <Input id="birthDate" name="birthDate" type="date" defaultValue={student.birthDate ?? ''} />
          </div>

          <div className="space-y-2">
            <Label htmlFor="gender">Пол</Label>
            <Select id="gender" name="gender" defaultValue={student.gender ?? ''}>
              <option value="">Не указан</option>
              <option value="м">Мальчик</option>
              <option value="ж">Девочка</option>
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor="primaryTeacherId">Специалист</Label>
            <Select
              id="primaryTeacherId"
              name="primaryTeacherId"
              defaultValue={student.primaryTeacherId ?? ''}
            >
              <option value="">Не назначен</option>
              {teachers.map((teacher) => (
                <option key={teacher.id} value={teacher.id}>
                  {teacher.fullName}
                </option>
              ))}
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor="status">Статус</Label>
            <Select id="status" name="status" defaultValue={student.status}>
              <option value="active">Занимается</option>
              <option value="paused">Пауза</option>
              <option value="archived">В архиве</option>
            </Select>
          </div>

          <div className="space-y-2 sm:col-span-2">
            <Label htmlFor="source">Откуда пришли</Label>
            <Input id="source" name="source" defaultValue={student.source ?? ''} />
          </div>

          <div className="space-y-2 sm:col-span-2">
            <Label htmlFor="notes">Заметка</Label>
            <Input id="notes" name="notes" defaultValue={student.notes ?? ''} />
          </div>
        </div>

        <FormError message={state.error} />
        <FormNotice message={state.notice} />

        <SaveButton />
      </form>

      <div className="border-t border-border pt-4">
        <FormError message={archiveState.error ?? restoreState.error} />
        {student.status === 'archived' ? (
          <form action={restoreAction}>
            <input type="hidden" name="id" value={student.id} />
            <Button type="submit" variant="outline">
              Восстановить из архива
            </Button>
          </form>
        ) : (
          <form action={archiveAction}>
            <input type="hidden" name="id" value={student.id} />
            <Button type="submit" variant="outline">
              В архив
            </Button>
          </form>
        )}
      </div>
    </div>
  )
}
