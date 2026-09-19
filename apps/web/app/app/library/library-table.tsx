'use client'

import { useActionState, useMemo, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Dialog } from '@/components/ui/dialog'
import { FormError, FormNotice } from '@/components/ui/alert'
import { assignExerciseToStudent, type LibraryState } from './actions'

export type ExerciseRow = {
  id: string
  title: string
  area: string | null
  sound: string | null
  stageCode: string | null
  stageTitle: string | null
  instructions: string | null
  mediaUrl: string | null
  ageFrom: number | null
  ageTo: number | null
  tags: string[]
  isActive: boolean
  isPlatform: boolean
}

export type StageOption = { code: string; title: string }
export type StudentOption = { id: string; fullName: string }

const initial: LibraryState = { message: '' }

function SubmitButton() {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" disabled={pending}>
      {pending ? 'Добавляем…' : 'Добавить'}
    </Button>
  )
}

function AssignDialog({
  exercise,
  students,
  open,
  onClose,
}: {
  exercise: ExerciseRow
  students: StudentOption[]
  open: boolean
  onClose: () => void
}) {
  const [state, formAction] = useActionState(assignExerciseToStudent, initial)
  // Один ключ на диалог: повторный клик «Добавить» на этом же открытии не
  // должен выдать упражнение дважды (см. actions.ts).
  const [conductKey] = useState(() => crypto.randomUUID())

  return (
    <Dialog open={open} onClose={onClose} title="Добавить в домашнее задание" description={exercise.title}>
      <form action={formAction} className="space-y-3">
        <input type="hidden" name="exerciseId" value={exercise.id} />
        <input type="hidden" name="conductKey" value={conductKey} />
        <div className="space-y-1">
          <Label htmlFor={`student-${exercise.id}`}>Ученик</Label>
          <Select id={`student-${exercise.id}`} name="studentId" defaultValue="" required>
            <option value="" disabled>
              Выберите ученика
            </option>
            {students.map((student) => (
              <option key={student.id} value={student.id}>
                {student.fullName}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor={`due-${exercise.id}`}>Срок, дней от сегодня</Label>
          <Input id={`due-${exercise.id}`} name="dueInDays" type="number" min="0" placeholder="7" />
        </div>
        <FormError message={state.message || undefined} />
        <FormNotice message={state.notice} />
        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" size="sm" onClick={onClose}>
            Отмена
          </Button>
          <SubmitButton />
        </div>
      </form>
    </Dialog>
  )
}

function ExerciseCard({
  exercise,
  students,
  canAssign,
}: {
  exercise: ExerciseRow
  students: StudentOption[]
  canAssign: boolean
}) {
  const [dialogOpen, setDialogOpen] = useState(false)

  return (
    <div className="space-y-2 rounded-md border border-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <p className="font-medium">{exercise.title}</p>
          <p className="text-xs text-muted-foreground">
            {[
              exercise.area,
              exercise.sound ? `звук «${exercise.sound}»` : null,
              exercise.stageTitle,
              exercise.ageFrom || exercise.ageTo ? `возраст ${exercise.ageFrom ?? '0'}–${exercise.ageTo ?? '∞'}` : null,
              exercise.isPlatform ? 'библиотека платформы' : 'своё упражнение',
            ]
              .filter(Boolean)
              .join(' · ')}
          </p>
        </div>
        {canAssign ? (
          <>
            <Button type="button" size="sm" variant="outline" onClick={() => setDialogOpen(true)}>
              Добавить в ДЗ
            </Button>
            <AssignDialog
              exercise={exercise}
              students={students}
              open={dialogOpen}
              onClose={() => setDialogOpen(false)}
            />
          </>
        ) : null}
      </div>

      {exercise.instructions ? <p className="text-sm">{exercise.instructions}</p> : null}
      {exercise.mediaUrl ? (
        <a
          href={exercise.mediaUrl}
          target="_blank"
          rel="noreferrer"
          className="text-sm text-primary underline underline-offset-2"
        >
          Материал
        </a>
      ) : null}
      {exercise.tags.length > 0 ? (
        <p className="text-xs text-muted-foreground">Теги: {exercise.tags.join(', ')}</p>
      ) : null}
    </div>
  )
}

export function LibraryTable({
  exercises,
  stages,
  students,
  isAdmin,
}: {
  exercises: ExerciseRow[]
  stages: StageOption[]
  students: StudentOption[]
  isAdmin: boolean
}) {
  const [query, setQuery] = useState('')
  const [area, setArea] = useState('')
  const [sound, setSound] = useState('')
  const [stageCode, setStageCode] = useState('')

  const areas = useMemo(
    () => [...new Set(exercises.map((e) => e.area).filter((v): v is string => Boolean(v)))].sort(),
    [exercises],
  )
  const sounds = useMemo(
    () => [...new Set(exercises.map((e) => e.sound).filter((v): v is string => Boolean(v)))].sort(),
    [exercises],
  )

  const filtered = useMemo(() => {
    const trimmed = query.trim().toLowerCase()
    return exercises.filter((exercise) => {
      if (!isAdmin && !exercise.isActive) return false
      if (area && exercise.area !== area) return false
      if (sound && exercise.sound !== sound) return false
      if (stageCode && exercise.stageCode !== stageCode) return false
      if (!trimmed) return true
      return (
        exercise.title.toLowerCase().includes(trimmed) ||
        (exercise.instructions ?? '').toLowerCase().includes(trimmed) ||
        exercise.tags.some((tag) => tag.toLowerCase().includes(trimmed))
      )
    })
  }, [exercises, query, area, sound, stageCode, isAdmin])

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-3">
        <Input
          placeholder="Поиск по названию, тегам, инструкции"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          className="max-w-xs"
        />
        <Select value={area} onChange={(event) => setArea(event.target.value)} className="max-w-[190px]">
          <option value="">Все области</option>
          {areas.map((value) => (
            <option key={value} value={value}>
              {value}
            </option>
          ))}
        </Select>
        <Select value={sound} onChange={(event) => setSound(event.target.value)} className="max-w-[140px]">
          <option value="">Все звуки</option>
          {sounds.map((value) => (
            <option key={value} value={value}>
              {value}
            </option>
          ))}
        </Select>
        <Select value={stageCode} onChange={(event) => setStageCode(event.target.value)} className="max-w-[190px]">
          <option value="">Все этапы</option>
          {stages.map((stage) => (
            <option key={stage.code} value={stage.code}>
              {stage.title}
            </option>
          ))}
        </Select>
      </div>

      <div className="space-y-3">
        {filtered.map((exercise) => (
          <ExerciseCard key={exercise.id} exercise={exercise} students={students} canAssign />
        ))}
        {filtered.length === 0 ? (
          <p className="text-sm text-muted-foreground">Ничего не найдено по этим фильтрам.</p>
        ) : null}
      </div>
    </div>
  )
}
