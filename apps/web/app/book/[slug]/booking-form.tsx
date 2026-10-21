'use client'

import { useActionState, useEffect, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { calendarDay, timeInZone } from '@/lib/timezone'
import { formatKgPhone, groupSlotsByDay, type SlotDay } from '@logocrm/core'
import { useKeepValuesOnError } from '@/lib/use-keep-values'
import { getFreeSlots, getTeacherBusy, submitBooking, type BookingState } from './actions'
import { WaitlistForm } from './waitlist-form'

export type BookingService = { id: string; name: string; duration_min: number }
export type BookingTeacher = { id: string; full_name: string; booking_mode: 'any' | 'hours' }

const initialState: BookingState = {}

function SubmitButton() {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" className="w-full" disabled={pending}>
      {pending ? t('booking', 'submitting') : t('booking', 'submitButton')}
    </Button>
  )
}

/** Окна специалиста в режиме «по рабочим часам» (0109): кнопки по дням. */
function SlotPicker({
  slug,
  serviceId,
  teacherId,
  timezone,
  horizonDays,
}: {
  slug: string
  serviceId: string
  teacherId: string
  timezone: string
  horizonDays: number
}) {
  const [slots, setSlots] = useState<{ starts_at: string }[]>([])
  const [status, setStatus] = useState<'loading' | 'ok' | 'failed'>('loading')

  useEffect(() => {
    let cancelled = false
    setStatus('loading')
    void getFreeSlots(slug, serviceId, teacherId).then((result) => {
      if (cancelled) return
      setSlots(result.slots)
      setStatus(result.failed ? 'failed' : 'ok')
    })
    return () => {
      cancelled = true
    }
  }, [slug, serviceId, teacherId])

  if (status === 'loading') {
    return (
      <p className="text-sm text-muted-foreground" role="status">
        {t('booking', 'slotsLoading')}
      </p>
    )
  }
  if (status === 'failed') {
    return (
      <p className="text-sm text-warning" role="status">
        {t('booking', 'slotsFailed')}
      </p>
    )
  }
  if (slots.length === 0) {
    return (
      <p className="text-sm text-muted-foreground" role="status">
        {t('booking', 'slotsEmpty', { days: horizonDays })}
      </p>
    )
  }

  return <SlotGrid days={groupSlotsByDay(slots, timezone)} />
}

/** Сетка окон по дням: радиокнопки под видом кнопок — выбор держит сама форма. */
export function SlotGrid({ days }: { days: SlotDay[] }) {
  return (
    <fieldset className="space-y-3">
      <legend className="text-sm font-medium">{t('booking', 'slotsLabel')}</legend>
      <div className="max-h-80 space-y-3 overflow-y-auto pr-1">
        {days.map((day) => (
          <div key={day.day} className="space-y-1.5">
            <p className="text-xs font-medium text-muted-foreground">{day.label}</p>
            <div className="flex flex-wrap gap-2">
              {day.slots.map((slot) => (
                <label key={slot.startsAt} className="cursor-pointer">
                  <input type="radio" name="startsAt" value={slot.startsAt} required className="peer sr-only" />
                  <span className="inline-flex min-h-11 min-w-16 items-center justify-center rounded-md border border-border bg-background px-3 text-sm tabular-nums transition-colors peer-checked:border-primary peer-checked:bg-primary peer-checked:text-primary-foreground peer-focus-visible:ring-2 peer-focus-visible:ring-ring">
                    {slot.time}
                  </span>
                </label>
              ))}
            </div>
          </div>
        ))}
      </div>
    </fieldset>
  )
}

export function BookingForm({
  slug,
  services,
  teachers,
  minDate,
  timezone,
  horizonDays,
}: {
  slug: string
  services: BookingService[]
  teachers: BookingTeacher[]
  minDate: string
  timezone: string
  horizonDays: number
}) {
  const [state, action] = useActionState(submitBooking, initialState)
  const [serviceId, setServiceId] = useState(services[0]?.id ?? '')
  const [teacherId, setTeacherId] = useState(teachers[0]?.id ?? '')
  const [date, setDate] = useState('')
  const [busy, setBusy] = useState<{ starts_at: string; ends_at: string }[]>([])
  // null — ещё не проверяли; 'loading' — идёт запрос; 'failed' — проверить не удалось.
  const [busyState, setBusyState] = useState<null | 'loading' | 'ok' | 'failed'>(null)
  const [waitlist, setWaitlist] = useState(false)

  const mode = teachers.find((x) => x.id === teacherId)?.booking_mode ?? 'any'

  useEffect(() => {
    if (mode !== 'any' || !teacherId || !date) {
      setBusy([])
      setBusyState(null)
      return
    }
    let cancelled = false
    setBusyState('loading')
    void getTeacherBusy(slug, teacherId, date).then((result) => {
      if (cancelled) return
      setBusy(result.busy)
      setBusyState(result.failed ? 'failed' : 'ok')
    })
    return () => {
      cancelled = true
    }
  }, [slug, teacherId, date, mode])

  // Отказ («время занято») не стирает имя, телефон и выбранную услугу.
  const keep = useKeepValuesOnError(state, Boolean(state.message))

  if (waitlist) {
    return (
      <WaitlistForm
        slug={slug}
        services={services}
        teachers={teachers}
        initialServiceId={serviceId}
        initialTeacherId={mode === 'hours' ? teacherId : ''}
        onBack={() => setWaitlist(false)}
      />
    )
  }

  if (state.notice) {
    const summary = state.summary
    const service = summary ? services.find((x) => x.id === summary.serviceId) : undefined
    const teacher = summary ? teachers.find((x) => x.id === summary.teacherId) : undefined
    return (
      <div className="space-y-4">
        <FormNotice message={state.notice} />
        {summary ? (
          <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 rounded-md border border-border p-4 text-sm">
            <dt className="text-muted-foreground">{t('booking', 'childNameLabel')}</dt>
            <dd className="font-medium">{summary.childName}</dd>
            <dt className="text-muted-foreground">{t('booking', 'serviceLabel')}</dt>
            <dd className="font-medium">{service?.name ?? '—'}</dd>
            <dt className="text-muted-foreground">{t('booking', 'teacherLabel')}</dt>
            <dd className="font-medium">{teacher?.full_name ?? '—'}</dd>
            <dt className="text-muted-foreground">{t('booking', 'whenLabel')}</dt>
            <dd className="font-medium">
              {calendarDay(summary.date, { day: 'numeric', month: 'long', weekday: 'long' })}, {summary.time}
            </dd>
          </dl>
        ) : null}
        {summary ? (
          <p className="text-sm text-muted-foreground">{t('booking', 'willCall', { phone: formatKgPhone(summary.parentPhone) })}</p>
        ) : null}
        <Button type="button" variant="outline" className="w-full" onClick={() => window.location.reload()}>
          {t('booking', 'bookAnother')}
        </Button>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <form action={action} className="space-y-4" {...keep}>
        <input type="hidden" name="slug" value={slug} />
        <input type="hidden" name="timezone" value={timezone} />
        <input type="hidden" name="mode" value={mode} />

        <div className="space-y-2">
          <Label htmlFor="serviceId">{t('booking', 'serviceLabel')}</Label>
          <Select id="serviceId" name="serviceId" required value={serviceId} onChange={(e) => setServiceId(e.target.value)}>
            {services.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} ({s.duration_min} {t('booking', 'minutesShort')})
              </option>
            ))}
          </Select>
        </div>

        <div className="space-y-2">
          <Label htmlFor="teacherId">{t('booking', 'teacherLabel')}</Label>
          <Select
            id="teacherId"
            name="teacherId"
            required
            value={teacherId}
            onChange={(e) => setTeacherId(e.target.value)}
          >
            {teachers.map((tch) => (
              <option key={tch.id} value={tch.id}>
                {tch.full_name}
              </option>
            ))}
          </Select>
        </div>

        {mode === 'hours' ? (
          <SlotPicker
            key={`${serviceId}:${teacherId}`}
            slug={slug}
            serviceId={serviceId}
            teacherId={teacherId}
            timezone={timezone}
            horizonDays={horizonDays}
          />
        ) : (
          <>
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label htmlFor="date">{t('booking', 'dateLabel')}</Label>
                <Input
                  id="date"
                  name="date"
                  type="date"
                  required
                  min={minDate}
                  value={date}
                  onChange={(e) => setDate(e.target.value)}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="time">{t('booking', 'timeLabel')}</Label>
                <Input id="time" name="time" type="time" required />
              </div>
            </div>

            {busyState === 'loading' ? (
              <p className="text-xs text-muted-foreground" role="status">{t('booking', 'busyLoading')}</p>
            ) : null}
            {busyState === 'failed' ? (
              <p className="text-xs text-warning" role="status">{t('booking', 'busyFailed')}</p>
            ) : null}
            {busyState === 'ok' && busy.length > 0 ? (
              <p className="text-xs text-muted-foreground">
                {t('booking', 'busyNote')}{' '}
                {busy.map((b) => `${timeInZone(b.starts_at, timezone)}–${timeInZone(b.ends_at, timezone)}`).join(', ')}
              </p>
            ) : null}
          </>
        )}

        <div className="space-y-2">
          <Label htmlFor="childName">{t('booking', 'childNameLabel')}</Label>
          <Input id="childName" name="childName" required />
        </div>

        <div className="space-y-2">
          <Label htmlFor="parentName">{t('booking', 'parentNameLabel')}</Label>
          <Input id="parentName" name="parentName" required />
        </div>

        <div className="space-y-2">
          <Label htmlFor="parentPhone">{t('booking', 'phoneLabel')}</Label>
          <Input id="parentPhone" name="parentPhone" type="tel" placeholder="0700 12 34 56" required />
        </div>

        <FormError message={state.message} />

        <SubmitButton />
      </form>

      <Button type="button" variant="outline" className="h-auto min-h-11 w-full whitespace-normal py-2 sm:h-auto" onClick={() => setWaitlist(true)}>
        {t('booking', 'waitlistOffer')}
      </Button>
    </div>
  )
}
