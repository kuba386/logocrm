'use client'

import { useActionState, useEffect, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { WEEKDAY_SHORT } from '@logocrm/core'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'
import { saveBookingSettings, saveTeacherBooking, type BookingSettingsState } from './actions'

const initialState: BookingSettingsState = {}

export type BookingMode = 'any' | 'hours' | 'closed'
export type WorkInterval = { weekday: number; starts_at: string; ends_at: string }

export const MODE_LABELS: Record<BookingMode, string> = {
  any: 'Любое время',
  hours: 'По рабочим часам',
  closed: 'Запись закрыта',
}

const MODE_HINTS: Record<BookingMode, string> = {
  hours: 'Родитель выбирает из свободных окон в рабочие часы — занятия и чужие заявки уже вычтены.',
  any: 'Родитель вводит дату и время сам, стойка подтверждает или предлагает другое.',
  closed: 'Специалиста нет на сайте. Рабочие часы сохраняются.',
}

function Submit({ children, variant = 'default' }: { children: React.ReactNode; variant?: 'default' | 'outline' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" variant={variant} disabled={pending}>
      {children}
    </Button>
  )
}

export function BookingSettingsForm({ horizon, step }: { horizon: number; step: number }) {
  const [state, action] = useActionState(saveBookingSettings, initialState)
  return (
    <form action={action} className="space-y-4">
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor="horizon">Сколько дней вперёд показывать</Label>
          <Input id="horizon" name="horizon" type="number" min={7} max={31} defaultValue={horizon} required />
          <p className="text-xs text-muted-foreground">От 7 до 31 дня.</p>
        </div>
        <div className="space-y-1">
          <Label htmlFor="step">Шаг сетки</Label>
          <Select id="step" name="step" defaultValue={String(step)}>
            <option value="15">15 минут</option>
            <option value="30">30 минут</option>
            <option value="60">1 час</option>
          </Select>
          <p className="text-xs text-muted-foreground">Окна начинаются с начала рабочего интервала.</p>
        </div>
      </div>
      <div className="flex flex-wrap items-center gap-3">
        <Submit>Сохранить</Submit>
        <FormError message={state.message} />
        <FormNotice message={state.notice} />
      </div>
    </form>
  )
}

type DayRows = Record<number, { starts_at: string; ends_at: string }[]>

function toDayRows(intervals: WorkInterval[]): DayRows {
  const rows: DayRows = { 1: [], 2: [], 3: [], 4: [], 5: [], 6: [], 7: [] }
  for (const i of intervals) rows[i.weekday]?.push({ starts_at: i.starts_at.slice(0, 5), ends_at: i.ends_at.slice(0, 5) })
  return rows
}

/** Режим записи и рабочие часы специалиста (0109): полная неделя. */
export function TeacherBookingDialog({
  teacherId,
  teacherName,
  mode,
  intervals,
}: {
  teacherId: string
  teacherName: string
  mode: BookingMode
  intervals: WorkInterval[]
}) {
  const [open, setOpen] = useState(false)
  const [selected, setSelected] = useState<BookingMode>(mode)
  const [days, setDays] = useState<DayRows>(() => toDayRows(intervals))
  const [state, action] = useActionState(saveTeacherBooking.bind(null, teacherId), initialState)

  // Новое состояние с сервера — после сохранения диалог открывается с ним.
  useEffect(() => {
    setSelected(mode)
    setDays(toDayRows(intervals))
  }, [mode, intervals])

  const flat: WorkInterval[] = Object.entries(days).flatMap(([weekday, list]) =>
    list.map((i) => ({ weekday: Number(weekday), ...i })),
  )

  function update(weekday: number, index: number, field: 'starts_at' | 'ends_at', value: string) {
    setDays((prev) => ({ ...prev, [weekday]: prev[weekday]!.map((i, n) => (n === index ? { ...i, [field]: value } : i)) }))
  }
  function add(weekday: number) {
    setDays((prev) => {
      const list = prev[weekday]!
      const last = list[list.length - 1]
      return { ...prev, [weekday]: [...list, last ? { starts_at: last.ends_at, ends_at: last.ends_at } : { starts_at: '09:00', ends_at: '18:00' }] }
    })
  }
  function remove(weekday: number, index: number) {
    setDays((prev) => ({ ...prev, [weekday]: prev[weekday]!.filter((_, n) => n !== index) }))
  }
  function copyMondayToWeekdays() {
    setDays((prev) => ({ ...prev, 2: [...prev[1]!], 3: [...prev[1]!], 4: [...prev[1]!], 5: [...prev[1]!] }))
  }

  return (
    <>
      <Button type="button" size="sm" variant="outline" onClick={() => setOpen(true)}>
        Настроить
      </Button>
      <Dialog open={open} onClose={() => setOpen(false)} title={`Онлайн-запись: ${teacherName}`} className="max-w-xl">
        <form action={action} className="space-y-4">
          <input type="hidden" name="intervals" value={JSON.stringify(flat)} />
          <fieldset className="space-y-2">
            <legend className="text-sm font-medium">Режим записи</legend>
            {(['hours', 'any', 'closed'] as BookingMode[]).map((m) => (
              <label key={m} className="flex min-h-11 items-start gap-2 text-sm">
                <input
                  type="radio"
                  name="mode"
                  value={m}
                  checked={selected === m}
                  onChange={() => setSelected(m)}
                  className="mt-1 size-4"
                />
                <span>
                  <span className="font-medium">{MODE_LABELS[m]}</span>
                  <span className="block text-xs text-muted-foreground">{MODE_HINTS[m]}</span>
                </span>
              </label>
            ))}
          </fieldset>

          {selected === 'hours' ? (
            <fieldset className="space-y-3">
              <legend className="text-sm font-medium">Рабочие часы</legend>
              <Button type="button" size="sm" variant="ghost" onClick={copyMondayToWeekdays}>
                Как понедельник — на Вт–Пт
              </Button>
              {[1, 2, 3, 4, 5, 6, 7].map((weekday) => (
                <div key={weekday} className="flex flex-wrap items-start gap-2 border-t border-border pt-3 first-of-type:border-t-0">
                  <span className="w-8 pt-3 text-sm font-medium">{WEEKDAY_SHORT[weekday - 1]}</span>
                  <div className="flex flex-1 flex-col gap-2">
                    {days[weekday]!.length === 0 ? (
                      <span className="pt-3 text-sm text-muted-foreground">выходной</span>
                    ) : (
                      days[weekday]!.map((interval, index) => (
                        <div key={index} className="flex items-center gap-2">
                          <Input
                            type="time"
                            step={300}
                            aria-label={`${WEEKDAY_SHORT[weekday - 1]}, начало интервала ${index + 1}`}
                            value={interval.starts_at}
                            onChange={(e) => update(weekday, index, 'starts_at', e.target.value)}
                            className="w-28"
                            required
                          />
                          <span aria-hidden="true">–</span>
                          <Input
                            type="time"
                            step={300}
                            aria-label={`${WEEKDAY_SHORT[weekday - 1]}, конец интервала ${index + 1}`}
                            value={interval.ends_at}
                            onChange={(e) => update(weekday, index, 'ends_at', e.target.value)}
                            className="w-28"
                            required
                          />
                          <Button
                            type="button"
                            size="icon"
                            variant="ghost"
                            aria-label={`Убрать интервал ${index + 1} (${WEEKDAY_SHORT[weekday - 1]})`}
                            onClick={() => remove(weekday, index)}
                          >
                            ×
                          </Button>
                        </div>
                      ))
                    )}
                  </div>
                  <Button type="button" size="sm" variant="ghost" onClick={() => add(weekday)}>
                    + интервал
                  </Button>
                </div>
              ))}
            </fieldset>
          ) : null}

          <FormError message={state.message} />
          <FormNotice message={state.notice} />
          <Submit>Сохранить</Submit>
        </form>
      </Dialog>
    </>
  )
}
