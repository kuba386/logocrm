'use client'

import { useActionState, useEffect, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { timeInZone } from '@/lib/timezone'
import { getTeacherBusy, submitBooking, type BookingState } from './actions'

type BookingService = { id: string; name: string; duration_min: number }
type BookingTeacher = { id: string; full_name: string }

const initialState: BookingState = {}

function SubmitButton() {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" className="w-full" disabled={pending}>
      {pending ? t('booking', 'submitting') : t('booking', 'submitButton')}
    </Button>
  )
}

export function BookingForm({
  slug,
  services,
  teachers,
  minDate,
  timezone,
}: {
  slug: string
  services: BookingService[]
  teachers: BookingTeacher[]
  minDate: string
  timezone: string
}) {
  const [state, action] = useActionState(submitBooking, initialState)
  const [teacherId, setTeacherId] = useState(teachers[0]?.id ?? '')
  const [date, setDate] = useState('')
  const [busy, setBusy] = useState<{ starts_at: string; ends_at: string }[]>([])

  useEffect(() => {
    if (!teacherId || !date) {
      setBusy([])
      return
    }
    let cancelled = false
    void getTeacherBusy(slug, teacherId, date).then((rows) => {
      if (!cancelled) setBusy(rows)
    })
    return () => {
      cancelled = true
    }
  }, [slug, teacherId, date])

  if (state.notice) {
    return <FormNotice message={state.notice} />
  }

  return (
    <form action={action} className="space-y-4">
      <input type="hidden" name="slug" value={slug} />
      <input type="hidden" name="timezone" value={timezone} />

      <div className="space-y-2">
        <Label htmlFor="serviceId">{t('booking', 'serviceLabel')}</Label>
        <Select id="serviceId" name="serviceId" required defaultValue={services[0]?.id}>
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

      {busy.length > 0 ? (
        <p className="text-xs text-muted-foreground">
          {t('booking', 'busyNote')}{' '}
          {busy.map((b) => `${timeInZone(b.starts_at, timezone)}–${timeInZone(b.ends_at, timezone)}`).join(', ')}
        </p>
      ) : null}

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
  )
}
