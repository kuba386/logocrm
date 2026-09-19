'use client'

import { useActionState, useMemo, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { FormError, FormNotice } from '@/components/ui/alert'
import { archiveHomework, assignHomeworkStandalone, reviewHomework, type ClinicalState } from './clinical-actions'

export type ExerciseOption = { id: string; title: string; sound: string | null }

export type HomeworkEntry = {
  id: string
  status: string
  freeText: string | null
  dueOn: string | null
  parentNote: string | null
  teacherFeedback: string | null
  exerciseTitles: string[]
}

const STATUS_LABELS: Record<string, string> = {
  assigned: 'Выдано',
  submitted: 'Сдано',
  reviewed: 'Проверено',
}

const initial: ClinicalState = { message: '' }

function HomeworkCard({
  studentId,
  homework,
  canWrite,
}: {
  studentId: string
  homework: HomeworkEntry
  canWrite: boolean
}) {
  const router = useRouter()
  const [feedbackOpen, setFeedbackOpen] = useState(false)
  const [feedback, setFeedback] = useState('')
  const [pending, startTransition] = useTransition()
  const [result, setResult] = useState<ClinicalState>(initial)

  function run(action: () => Promise<ClinicalState>, onSuccess?: () => void) {
    startTransition(async () => {
      const outcome = await action()
      setResult(outcome)
      if (outcome.notice) {
        router.refresh()
        onSuccess?.()
      }
    })
  }

  return (
    <div className="space-y-2 rounded-md border border-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <p>{homework.freeText || (homework.exerciseTitles.length > 0 ? homework.exerciseTitles.join(', ') : 'Задание')}</p>
          {homework.exerciseTitles.length > 0 && homework.freeText ? (
            <p className="text-xs text-muted-foreground">{homework.exerciseTitles.join(', ')}</p>
          ) : null}
        </div>
        <span className="whitespace-nowrap rounded bg-muted px-2 py-0.5 text-xs">
          {STATUS_LABELS[homework.status] ?? homework.status}
        </span>
      </div>
      {homework.dueOn ? (
        <p className="text-xs text-muted-foreground">До {new Date(homework.dueOn).toLocaleDateString('ru-RU')}</p>
      ) : null}
      {homework.parentNote ? <p className="text-sm">Родитель: {homework.parentNote}</p> : null}
      {homework.teacherFeedback ? <p className="text-sm">Фидбек: {homework.teacherFeedback}</p> : null}

      {canWrite ? (
        <div className="space-y-2 pt-1">
          <div className="flex flex-wrap gap-2">
            {homework.status === 'submitted' ? (
              feedbackOpen ? null : (
                <Button type="button" size="sm" onClick={() => setFeedbackOpen(true)}>
                  Проверить
                </Button>
              )
            ) : null}
            {homework.status !== 'reviewed' ? (
              <Button
                type="button"
                size="sm"
                variant="ghost"
                disabled={pending}
                onClick={() => run(() => archiveHomework(studentId, homework.id))}
              >
                Убрать
              </Button>
            ) : null}
          </div>
          {feedbackOpen ? (
            <div className="space-y-2">
              <Textarea
                placeholder="Фидбек родителю"
                value={feedback}
                onChange={(e) => setFeedback(e.target.value)}
              />
              <div className="flex gap-2">
                <Button
                  type="button"
                  size="sm"
                  disabled={pending}
                  onClick={() => run(() => reviewHomework(studentId, homework.id, feedback), () => setFeedbackOpen(false))}
                >
                  Сохранить
                </Button>
                <Button type="button" size="sm" variant="outline" onClick={() => setFeedbackOpen(false)}>
                  Отмена
                </Button>
              </div>
            </div>
          ) : null}
        </div>
      ) : null}

      <FormNotice message={result.notice} />
      <FormError message={result.message} />
    </div>
  )
}

export function HomeworkPanel({
  studentId,
  homework,
  exercises,
  canWrite,
}: {
  studentId: string
  homework: HomeworkEntry[]
  exercises: ExerciseOption[]
  canWrite: boolean
}) {
  const [formOpen, setFormOpen] = useState(false)
  const [state, action] = useActionState(assignHomeworkStandalone, initial)
  const [selected, setSelected] = useState<string[]>([])
  const [query, setQuery] = useState('')

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return exercises
    return exercises.filter((e) => e.title.toLowerCase().includes(q) || (e.sound ?? '').toLowerCase().includes(q))
  }, [exercises, query])

  function toggle(id: string) {
    setSelected((current) => (current.includes(id) ? current.filter((x) => x !== id) : [...current, id]))
  }

  return (
    <div className="space-y-4">
      {homework.length > 0 ? (
        <div className="space-y-3">
          {homework.map((h) => (
            <HomeworkCard key={h.id} studentId={studentId} homework={h} canWrite={canWrite} />
          ))}
        </div>
      ) : (
        <p className="text-sm text-muted-foreground">Заданий пока нет.</p>
      )}

      {canWrite ? (
        formOpen ? (
          <form action={action} className="space-y-3 border-t border-border pt-4">
            <input type="hidden" name="studentId" value={studentId} />
            {selected.map((id) => (
              <input key={id} type="hidden" name="exerciseIds" value={id} />
            ))}
            <div className="space-y-1">
              <Label htmlFor="freeText">Свободный текст</Label>
              <Textarea id="freeText" name="freeText" />
            </div>
            <div className="flex items-center gap-2">
              <Label htmlFor="dueInDays" className="whitespace-nowrap text-xs">
                Срок, дней от сегодня
              </Label>
              <Input id="dueInDays" name="dueInDays" type="number" min={1} className="w-20" />
            </div>
            <Input placeholder="Поиск упражнения" value={query} onChange={(e) => setQuery(e.target.value)} />
            <div className="max-h-40 space-y-1 overflow-y-auto rounded-md border border-border p-2">
              {filtered.map((exercise) => (
                <label key={exercise.id} className="flex items-center gap-2 text-sm">
                  <input type="checkbox" checked={selected.includes(exercise.id)} onChange={() => toggle(exercise.id)} />
                  <span>
                    {exercise.title}
                    {exercise.sound ? ` · «${exercise.sound}»` : ''}
                  </span>
                </label>
              ))}
              {filtered.length === 0 ? <p className="text-xs text-muted-foreground">Ничего не найдено</p> : null}
            </div>
            <FormError message={state.message} />
            <FormNotice message={state.notice} />
            <div className="flex gap-2">
              <Button type="submit" size="sm">
                Выдать
              </Button>
              <Button type="button" size="sm" variant="outline" onClick={() => setFormOpen(false)}>
                Отмена
              </Button>
            </div>
          </form>
        ) : (
          <Button type="button" size="sm" onClick={() => setFormOpen(true)}>
            Выдать ДЗ
          </Button>
        )
      ) : null}
    </div>
  )
}
