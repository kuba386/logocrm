'use client'

import { useActionState, useState, useTransition } from 'react'
import { teacherVacation, vacationPreview, type ScheduleState } from '@/app/app/schedule/actions'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'
import { timeInZone, dayInZone } from '@/lib/timezone'

const initial: ScheduleState = { message: '' }

type PreviewLesson = { id: string; startsAt: string; asSubstitute: boolean }

/**
 * Отпуск отменяет занятия пачкой, поэтому сначала показываем список — что
 * именно исчезнет из расписания. Без предпросмотра это действие вслепую.
 */
export function VacationDialog({
  teacherId,
  teacherName,
  timeZone,
}: {
  teacherId: string
  teacherName: string
  timeZone: string
}) {
  const [open, setOpen] = useState(false)
  const [state, formAction] = useActionState(teacherVacation, initial)
  const [range, setRange] = useState({ from: '', to: '' })
  const [preview, setPreview] = useState<PreviewLesson[] | null>(null)
  const [previewError, setPreviewError] = useState<string | null>(null)
  const [pending, startTransition] = useTransition()

  function refresh() {
    if (!range.from || !range.to) {
      setPreviewError('Укажите период')
      return
    }
    setPreviewError(null)
    startTransition(async () => {
      const result = await vacationPreview(teacherId, range.from, range.to)
      if (result.lessons) setPreview(result.lessons)
      else setPreviewError(result.message ?? 'Не удалось получить список')
    })
  }

  return (
    <>
      <Button variant="outline" size="sm" onClick={() => setOpen(true)}>
        Отпуск
      </Button>

      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title={`Отпуск: ${teacherName}`}
        description="Занятия за период будут отменены с причиной «vacation», включая те, где специалист стоит заменой."
      >
        <form action={formAction} className="space-y-4">
          <input type="hidden" name="teacherId" value={teacherId} />

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1">
              <Label htmlFor="from">С</Label>
              <Input
                id="from"
                name="from"
                type="date"
                value={range.from}
                onChange={(e) => {
                  setRange((r) => ({ ...r, from: e.target.value }))
                  setPreview(null)
                }}
                required
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="to">По</Label>
              <Input
                id="to"
                name="to"
                type="date"
                value={range.to}
                onChange={(e) => {
                  setRange((r) => ({ ...r, to: e.target.value }))
                  setPreview(null)
                }}
                required
              />
            </div>
          </div>

          <Button type="button" variant="outline" size="sm" onClick={refresh} disabled={pending}>
            {pending ? 'Считаем…' : 'Показать, что отменится'}
          </Button>

          {previewError ? <p className="text-sm text-destructive">{previewError}</p> : null}

          {preview ? (
            <div className="rounded-md border border-border p-3 text-sm">
              <p className="font-medium">Будет отменено занятий: {preview.length}</p>
              {preview.length > 0 ? (
                <ul className="mt-2 space-y-1 text-xs text-muted-foreground">
                  {preview.map((lesson) => (
                    <li key={lesson.id}>
                      {dayInZone(lesson.startsAt, timeZone)}, {timeInZone(lesson.startsAt, timeZone)}
                      {lesson.asSubstitute ? ' — как замена' : ''}
                    </li>
                  ))}
                </ul>
              ) : null}
            </div>
          ) : null}

          <FormError message={state.message || undefined} />
          <FormNotice message={state.notice} />

          <div className="flex gap-2">
            <Button type="submit" variant="destructive" size="sm" disabled={preview === null}>
              Оформить отпуск
            </Button>
            <Button type="button" variant="outline" size="sm" onClick={() => setOpen(false)}>
              Отмена
            </Button>
          </div>
        </form>
      </Dialog>
    </>
  )
}
