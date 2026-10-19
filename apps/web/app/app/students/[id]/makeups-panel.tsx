'use client'

import { useActionState, useState, useTransition } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { FormError, FormNotice } from '@/components/ui/alert'
import { StatusBadge, type StatusTone } from '@/components/ui/status-badge'
import { calendarDay, dayInZone, timeInZone } from '@/lib/timezone'
import {
  bookMakeup,
  cancelMakeupBooking,
  listMakeupOptions,
  type MakeupActionState,
  type MakeupOption,
} from './makeup-actions'

export type MakeupRow = {
  creditId: string
  status: 'available' | 'booked' | 'used' | 'expired' | 'cancelled' | string
  missedOn: string
  expiresOn: string
  serviceName: string | null
  bookingId: string | null
  bookedStartsAt: string | null
  usedOn: string | null
}

const STATUS: Record<string, { label: string; tone: StatusTone }> = {
  available: { label: 'Доступна', tone: 'success' },
  booked: { label: 'Записан', tone: 'info' },
  used: { label: 'Использована', tone: 'neutral' },
  expired: { label: 'Сгорела', tone: 'warning' },
  cancelled: { label: 'Отменена', tone: 'neutral' },
}

const initial: MakeupActionState = {}

function Submit({ children, variant = 'default' }: { children: React.ReactNode; variant?: 'default' | 'outline' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {children}
    </Button>
  )
}

function BookDialog({ studentId, row, timeZone }: { studentId: string; row: MakeupRow; timeZone: string }) {
  const [open, setOpen] = useState(false)
  const [options, setOptions] = useState<MakeupOption[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [loading, startLoading] = useTransition()
  const [state, action] = useActionState(bookMakeup.bind(null, studentId), initial)

  function openDialog() {
    setOpen(true)
    setOptions(null)
    setLoadError(null)
    startLoading(async () => {
      const result = await listMakeupOptions(row.creditId)
      setOptions(result.options)
      setLoadError(result.message ?? null)
    })
  }

  return (
    <>
      <Button type="button" size="sm" onClick={openDialog}>
        Записать на отработку
      </Button>
      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title="Запись на отработку"
        description={`Занятия той же услуги до ${calendarDay(row.expiresOn)} — урок другой группы со свободным местом или индивидуальное.`}
      >
        {loading || options === null ? (
          <p className="text-sm text-muted-foreground">Ищем занятия…</p>
        ) : options.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {loadError ?? 'Подходящих занятий в срок нет. Создайте индивидуальное занятие в расписании и откройте эту форму снова.'}
          </p>
        ) : (
          <form action={action} className="space-y-3">
            <input type="hidden" name="creditId" value={row.creditId} />
            <fieldset className="space-y-2">
              <legend className="sr-only">Занятие</legend>
              {options.map((option, index) => (
                <label
                  key={option.lessonId}
                  className="flex cursor-pointer items-start gap-2 rounded-md border border-border p-3 text-sm has-[:checked]:border-primary has-[:checked]:bg-primary/5"
                >
                  <input type="radio" name="lessonId" value={option.lessonId} defaultChecked={index === 0} className="mt-0.5 size-4" />
                  <span className="space-y-0.5">
                    <span className="block font-medium">
                      {dayInZone(option.startsAt, timeZone)}, {timeInZone(option.startsAt, timeZone)}–{timeInZone(option.endsAt, timeZone)}
                    </span>
                    <span className="block text-muted-foreground">
                      {option.title}
                      {option.teacherName ? ` · ${option.teacherName}` : ''}
                      {option.freePlaces !== null ? ` · свободно мест: ${option.freePlaces}` : ''}
                    </span>
                  </span>
                </label>
              ))}
            </fieldset>
            <div className="flex flex-wrap items-center gap-3">
              <Submit>Записать</Submit>
              <FormError message={state.message} />
              <FormNotice message={state.notice} />
            </div>
          </form>
        )}
      </Dialog>
    </>
  )
}

function CancelBookingForm({ studentId, bookingId }: { studentId: string; bookingId: string }) {
  const [state, action] = useActionState(cancelMakeupBooking.bind(null, studentId), initial)
  return (
    <form action={action} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="bookingId" value={bookingId} />
      <Submit variant="outline">Отменить запись</Submit>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

/** Отработки ученика (0105): статус и сроки считает база (student_makeups). */
export function MakeupsPanel({ studentId, rows, timeZone }: { studentId: string; rows: MakeupRow[]; timeZone: string }) {
  if (rows.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        Отработок нет. Право появляется после отметки статусом с отработкой, если отработки включены в настройках.
      </p>
    )
  }
  return (
    <ul className="space-y-3">
      {rows.map((row) => {
        const status = STATUS[row.status] ?? { label: row.status, tone: 'neutral' as StatusTone }
        return (
          <li key={row.creditId} className="flex flex-col gap-2 rounded-md border border-border p-3 text-sm">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="font-medium">
                Пропуск {calendarDay(row.missedOn)}
                {row.serviceName ? ` · ${row.serviceName}` : ''}
              </span>
              <StatusBadge tone={status.tone}>{status.label}</StatusBadge>
            </div>
            <p className="text-muted-foreground">
              {row.status === 'booked' && row.bookedStartsAt
                ? `Отработка ${dayInZone(row.bookedStartsAt, timeZone)} в ${timeInZone(row.bookedStartsAt, timeZone)}`
                : row.status === 'used' && row.usedOn
                  ? `Отработал ${calendarDay(row.usedOn)}`
                  : `Отработать до ${calendarDay(row.expiresOn)}`}
            </p>
            {row.status === 'available' ? <BookDialog studentId={studentId} row={row} timeZone={timeZone} /> : null}
            {row.status === 'booked' && row.bookingId ? <CancelBookingForm studentId={studentId} bookingId={row.bookingId} /> : null}
          </li>
        )
      })}
    </ul>
  )
}
