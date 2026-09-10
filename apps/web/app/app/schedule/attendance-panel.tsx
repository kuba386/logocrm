'use client'

import { useActionState, useCallback, useEffect, useState, useTransition } from 'react'
import { useFormStatus } from 'react-dom'
import {
  getAttendancePanelData,
  markAttendance,
  markAttendanceAllPresent,
  type AttendanceParticipant,
  type AttendancePanelData,
  type AttendanceStatusOption,
  type ScheduleState,
} from './actions'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { cn } from '@/lib/utils'

const initial: ScheduleState = { message: '' }

/**
 * Цвета статусов — из seed-данных attendance_statuses (0008_subscriptions.sql):
 * green/amber/sky/rose. «Болел» (sky) — временная заглушка, не из Stitch,
 * см. docs/Design/DESIGN.md, «Пробелы».
 */
const STATUS_COLOR_CLASSES: Record<string, { active: string; inactive: string }> = {
  green: { active: 'border-success bg-success text-white', inactive: 'border-success/40 text-success hover:bg-success-bg' },
  amber: { active: 'border-warning bg-warning text-white', inactive: 'border-warning/40 text-warning hover:bg-warning-bg' },
  sky: { active: 'border-info bg-info text-white', inactive: 'border-info/40 text-info hover:bg-info-bg' },
  rose: { active: 'border-danger bg-danger text-white', inactive: 'border-danger/40 text-danger hover:bg-danger-bg' },
}

function statusClass(color: string, active: boolean): string {
  const entry = STATUS_COLOR_CLASSES[color] ?? STATUS_COLOR_CLASSES.green!
  return active ? entry.active : entry.inactive
}

/** Только состояние «в пути» — какая кнопка нажата, не какой статус станет активным. Без угадывания ответа сервера. */
function StatusButton({ statusCode, color, active, name }: { statusCode: string; color: string; active: boolean; name: string }) {
  const { pending, data } = useFormStatus()
  const isThisPending = pending && data?.get('statusCode') === statusCode

  return (
    <button
      type="submit"
      disabled={pending}
      className={cn(
        'rounded-md border px-2.5 py-1 text-xs font-medium transition-colors disabled:cursor-wait',
        statusClass(color, active),
        isThisPending && 'opacity-60',
      )}
    >
      {name}
    </button>
  )
}

function AttendanceRow({
  lessonId,
  participant,
  statuses,
  onMarked,
}: {
  lessonId: string
  participant: AttendanceParticipant
  statuses: AttendanceStatusOption[]
  onMarked: () => void
}) {
  const [state, formAction] = useActionState(markAttendance, initial)

  useEffect(() => {
    // Успешный ответ — перечитать список участников с сервера, а не
    // подкрашивать кнопку заранее: «Оптимистичного UI нет», CLAUDE.md.
    if (state.notice) onMarked()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state])

  return (
    <li className="flex flex-col gap-2 rounded-md border border-border p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="font-medium">{participant.fullName}</span>
        <span
          className={cn(
            'text-xs',
            // Тизерное слово у teacher/parent — «нет»; число у admin/owner —
            // «нет абонемента». Оба варианта значат одно и то же для глаза.
            participant.balance === 'нет' || participant.balance === 'нет абонемента'
              ? 'font-medium text-destructive'
              : 'text-muted-foreground',
          )}
        >
          {participant.balance}
        </span>
      </div>
      <div className="flex flex-wrap gap-2">
        {statuses.map((status) => (
          <form key={status.id} action={formAction}>
            <input type="hidden" name="lessonId" value={lessonId} />
            <input type="hidden" name="studentId" value={participant.studentId} />
            <input type="hidden" name="statusCode" value={status.code} />
            <StatusButton
              statusCode={status.code}
              color={status.color}
              name={status.name}
              active={participant.statusCode === status.code}
            />
          </form>
        ))}
      </div>
      {state.message ? <FormError message={state.message} /> : null}
    </li>
  )
}

export function AttendancePanel({ lessonId }: { lessonId: string }) {
  const [data, setData] = useState<AttendancePanelData | null>(null)
  const [isPending, startTransition] = useTransition()
  const [bulkState, bulkAction] = useActionState(markAttendanceAllPresent, initial)

  const refresh = useCallback(() => {
    startTransition(async () => {
      const result = await getAttendancePanelData(lessonId)
      setData(result)
    })
  }, [lessonId])

  useEffect(() => {
    setData(null)
    refresh()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lessonId])

  useEffect(() => {
    if (bulkState.notice) refresh()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [bulkState])

  if (!data && isPending) {
    return <p className="text-sm text-muted-foreground">Загрузка участников…</p>
  }

  if (!data) return null

  if (data.message) {
    return <FormError message={data.message} />
  }

  if (data.participants.length === 0) {
    return <p className="text-sm text-muted-foreground">На занятии нет участников.</p>
  }

  return (
    <div className="space-y-3">
      {data.participants.length > 1 ? (
        <form action={bulkAction}>
          <input type="hidden" name="lessonId" value={lessonId} />
          {data.participants.map((p) => (
            <input key={p.studentId} type="hidden" name="studentId" value={p.studentId} />
          ))}
          <Button type="submit" size="sm" variant="outline">
            Все пришли
          </Button>
        </form>
      ) : null}
      <FormNotice message={bulkState.notice} />

      <ul className="space-y-2">
        {data.participants.map((participant) => (
          <AttendanceRow
            key={participant.studentId}
            lessonId={lessonId}
            participant={participant}
            statuses={data.statuses}
            onMarked={refresh}
          />
        ))}
      </ul>
    </div>
  )
}
