'use client'

import Link from 'next/link'
import { useActionState, useState } from 'react'
import {
  cancelLesson,
  cancelSeriesFrom,
  markLessonStatus,
  rescheduleLesson,
  substituteTeacher,
  type ScheduleState,
} from './actions'
import { AttendancePanel } from './attendance-panel'
import { Button, buttonVariants } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormNotice } from '@/components/ui/alert'
import { ConflictList } from './conflict-list'
import { dayInZone, isoDayInZone, timeInZone } from '@/lib/timezone'
import { ConfirmSubmit } from '@/components/ui/confirm-submit'
import { t } from '@/lib/messages'
import { lessonStatusLabel } from '@/lib/schedule'
import type { TeacherOption } from './create-dialog'
import { SubmitButton } from '@/components/ui/submit-button'

const initial: ScheduleState = { message: '' }

export type LessonView = {
  id: string
  day: string
  startsAt: string
  endsAt: string
  status: string
  title: string
  teacherName: string
  roomName: string | null
  seriesId: string | null
  notes: string | null
  isMine: boolean
  /** Сколько родителей нажали «Подтвердить приход» в боте (0033). */
  confirmedCount: number
}

function Result({ state }: { state: ScheduleState }) {
  return (
    <>
      {state.message ? <ConflictList error={state} /> : null}
      <FormNotice message={state.notice} />
    </>
  )
}

export function LessonPanel({
  lesson,
  timeZone,
  canManage,
  teachers,
  onClose,
}: {
  lesson: LessonView | null
  timeZone: string
  canManage: boolean
  teachers: TeacherOption[]
  onClose: () => void
}) {
  const [statusState, statusAction] = useActionState(markLessonStatus, initial)
  const [cancelState, cancelAction] = useActionState(cancelLesson, initial)
  const [seriesState, seriesAction] = useActionState(cancelSeriesFrom, initial)
  const [substituteState, substituteAction] = useActionState(substituteTeacher, initial)
  const [moveState, moveAction] = useActionState(rescheduleLesson, initial)
  const [mode, setMode] = useState<'view' | 'move' | 'substitute' | 'cancel' | 'attendance'>('view')

  if (!lesson) return null

  // Отметка посещения — не переход статуса занятия (mark_attendance его не
  // трогает), поэтому доступна и на «done», и на «planned» — но только пока
  // занятие не отменено и уже началось: до начала отмечать нечего, RPC
  // всё равно откажет с «Занятие ещё не началось».
  const canMarkAttendance =
    (lesson.isMine || canManage) && lesson.status !== 'cancelled' && new Date(lesson.startsAt) <= new Date()

  const close = () => {
    setMode('view')
    onClose()
  }

  return (
    <Dialog
      open={Boolean(lesson)}
      onClose={close}
      title={lesson.title}
      description={`${dayInZone(lesson.startsAt, timeZone)}, ${timeInZone(lesson.startsAt, timeZone)}–${timeInZone(lesson.endsAt, timeZone)} · ${lessonStatusLabel(lesson.status)}`}
    >
      <div className="space-y-4">
        <dl className="grid gap-2 text-sm">
          <div className="flex justify-between gap-4">
            <dt className="text-muted-foreground">Специалист</dt>
            <dd>{lesson.teacherName}</dd>
          </div>
          {lesson.roomName ? (
            <div className="flex justify-between gap-4">
              <dt className="text-muted-foreground">Кабинет</dt>
              <dd>{lesson.roomName}</dd>
            </div>
          ) : null}
          {lesson.confirmedCount > 0 ? (
            <div className="flex justify-between gap-4">
              <dt className="text-muted-foreground">Подтвердили приход</dt>
              <dd>{lesson.confirmedCount}</dd>
            </div>
          ) : null}
          {lesson.notes ? (
            <div>
              <dt className="text-muted-foreground">Заметка</dt>
              <dd className="whitespace-pre-line">{lesson.notes}</dd>
            </div>
          ) : null}
        </dl>

        {/* Специалисту доступны только два перехода, и то на своём занятии.
            «Провёл» ведёт на экран «Провести занятие» (0039) — посещение,
            прогресс, заметка и ДЗ одним вызовом, а не голый переход статуса. */}
        {lesson.isMine && lesson.status === 'planned' ? (
          <div className="flex flex-wrap gap-2 border-t border-border pt-4">
            <Link href={`/app/schedule/lessons/${lesson.id}/complete`} className={buttonVariants({ size: 'sm' })}>
              Провёл
            </Link>
            <form action={statusAction}>
              <input type="hidden" name="lessonId" value={lesson.id} />
              <input type="hidden" name="status" value="cancelled" />
              <ConfirmSubmit label={t('lessonStatus', 'markCancelled')} question={t('lessonStatus', 'markCancelledConfirm')} />
            </form>
          </div>
        ) : null}

        <Result state={statusState} />

        {canMarkAttendance && mode !== 'attendance' ? (
          <div className="border-t border-border pt-4">
            <Button type="button" size="sm" onClick={() => setMode('attendance')}>
              Отметить посещение
            </Button>
          </div>
        ) : null}

        {mode === 'attendance' ? (
          <div className="space-y-3 border-t border-border pt-4">
            <AttendancePanel lessonId={lesson.id} />
            <Button type="button" size="sm" variant="outline" onClick={() => setMode('view')}>
              Назад
            </Button>
          </div>
        ) : null}

        {canManage ? (
          <div className="space-y-3 border-t border-border pt-4">
            {mode === 'view' ? (
              <div className="flex flex-wrap gap-2">
                <Button type="button" size="sm" variant="outline" onClick={() => setMode('move')}>
                  Перенести
                </Button>
                <Button type="button" size="sm" variant="outline" onClick={() => setMode('substitute')}>
                  Заменить специалиста
                </Button>
                <Button type="button" size="sm" variant="ghost" onClick={() => setMode('cancel')}>
                  Отменить
                </Button>
              </div>
            ) : null}

            {mode === 'move' ? (
              <form action={moveAction} className="space-y-3">
                <input type="hidden" name="lessonId" value={lesson.id} />
                <div className="grid grid-cols-2 gap-2">
                  <div className="space-y-1">
                    <Label htmlFor="startsAt">Начало</Label>
                    <Input
                      id="startsAt"
                      name="startsAt"
                      type="datetime-local"
                      defaultValue={localDateTimeValue(lesson.startsAt, timeZone)}
                      required
                    />
                  </div>
                  <div className="space-y-1">
                    <Label htmlFor="endsAt">Конец</Label>
                    <Input
                      id="endsAt"
                      name="endsAt"
                      type="datetime-local"
                      defaultValue={localDateTimeValue(lesson.endsAt, timeZone)}
                      required
                    />
                  </div>
                </div>
                <Result state={moveState} />
                <div className="flex gap-2">
                  <SubmitButton size="sm">
                    Перенести
                  </SubmitButton>
                  <Button type="button" size="sm" variant="outline" onClick={() => setMode('view')}>
                    Назад
                  </Button>
                </div>
              </form>
            ) : null}

            {mode === 'substitute' ? (
              <form action={substituteAction} className="space-y-3">
                <input type="hidden" name="lessonId" value={lesson.id} />
                <div className="space-y-1">
                  {/* id отличается от teacherId в диалоге создания: оба
                      живут на одной странице, а дубль id ломает связь label
                      с полем — getByLabel и скринридер уходят в чужой селект. */}
                  <Label htmlFor="substituteTeacherId">Кто проведёт вместо</Label>
                  <Select id="substituteTeacherId" name="teacherId" required defaultValue="">
                    {/* Пустой пункт обязателен. Без него браузер выбирает
                        первый вариант — первого специалиста по алфавиту, — и
                        один клик по «Назначить» ставит заменяющим человека,
                        которого администратор не выбирал. Действие проверяет
                        пустое значение и отвечает «Выберите специалиста». */}
                    <option value="">Выберите специалиста</option>
                    {teachers.map((teacher) => (
                      <option key={teacher.id} value={teacher.id}>
                        {teacher.fullName}
                      </option>
                    ))}
                  </Select>
                </div>
                <Result state={substituteState} />
                <div className="flex gap-2">
                  <SubmitButton size="sm">
                    Назначить
                  </SubmitButton>
                  <Button type="button" size="sm" variant="outline" onClick={() => setMode('view')}>
                    Назад
                  </Button>
                </div>
              </form>
            ) : null}

            {mode === 'cancel' ? (
              <div className="space-y-3">
                <form action={cancelAction} className="space-y-3">
                  <input type="hidden" name="lessonId" value={lesson.id} />
                  <div className="space-y-1">
                    <Label htmlFor="reason">Причина</Label>
                    <Input id="reason" name="reason" placeholder="Заболел, отпуск, перенос" />
                  </div>
                  <Result state={cancelState} />
                  <div className="flex gap-2">
                    <SubmitButton size="sm" variant="destructive">
                      Отменить занятие
                    </SubmitButton>
                    <Button type="button" size="sm" variant="outline" onClick={() => setMode('view')}>
                      Назад
                    </Button>
                  </div>
                </form>

                {lesson.seriesId ? (
                  <form action={seriesAction} className="space-y-2 border-t border-border pt-3">
                    <input type="hidden" name="seriesId" value={lesson.seriesId} />
                    <input type="hidden" name="from" value={lesson.day} />
                    <p className="text-xs text-muted-foreground">
                      Занятие входит в серию. Можно отменить его и все следующие — прошедшие
                      останутся.
                    </p>
                    <Input name="reason" placeholder="Причина отмены серии" aria-label="Причина отмены серии" />
                    <Result state={seriesState} />
                    <ConfirmSubmit
                      label="Отменить серию с этого дня"
                      question={t('lessonStatus', 'cancelSeriesConfirm', { day: dayInZone(lesson.startsAt, timeZone) })}
                    />
                  </form>
                ) : null}
              </div>
            ) : null}
          </div>
        ) : null}

        <div className="border-t border-border pt-4">
          <Button type="button" variant="ghost" size="sm" onClick={close}>
            Закрыть
          </Button>
        </div>
      </div>
    </Dialog>
  )
}

/**
 * Значение для <input type="datetime-local"> в поясе центра. Раньше сюда
 * шёл срез ISO из базы — это UTC: занятие на 11:00 по Бишкеку показывалось
 * как 05:00, а введённое «11:00» сохранялось как 17:00 по местному.
 */
function localDateTimeValue(iso: string, timeZone: string): string {
  return `${isoDayInZone(iso, timeZone)}T${timeInZone(iso, timeZone)}`
}
