'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { WEEKDAY_SHORT } from '@logocrm/core'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { useKeepValuesOnError } from '@/lib/use-keep-values'
import { submitWaitlist, type WaitlistState } from './actions'
import type { BookingService, BookingTeacher } from './booking-form'

const initialState: WaitlistState = {}

function SubmitButton() {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" className="w-full" disabled={pending}>
      {pending ? t('booking', 'submitting') : t('booking', 'waitlistSubmit')}
    </Button>
  )
}

/** Лист ожидания (0109): когда подходящего окна нет. */
export function WaitlistForm({
  slug,
  services,
  teachers,
  initialServiceId,
  initialTeacherId,
  onBack,
}: {
  slug: string
  services: BookingService[]
  teachers: BookingTeacher[]
  initialServiceId: string
  initialTeacherId: string
  onBack: () => void
}) {
  const [state, action] = useActionState(submitWaitlist, initialState)
  const keep = useKeepValuesOnError(state, Boolean(state.message))

  if (state.notice) {
    return (
      <div className="space-y-4">
        <FormNotice message={state.notice} />
        <Button type="button" variant="outline" className="w-full" onClick={() => window.location.reload()}>
          {t('booking', 'backToBooking')}
        </Button>
      </div>
    )
  }

  return (
    <form action={action} className="space-y-4" {...keep}>
      <input type="hidden" name="slug" value={slug} />

      <div className="space-y-1">
        <h2 className="text-lg font-semibold">{t('booking', 'waitlistTitle')}</h2>
        <p className="text-sm text-muted-foreground">{t('booking', 'waitlistDescription')}</p>
      </div>

      <div className="space-y-2">
        <Label htmlFor="wl-serviceId">{t('booking', 'serviceLabel')}</Label>
        <Select id="wl-serviceId" name="serviceId" required defaultValue={initialServiceId}>
          {services.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </Select>
      </div>

      <div className="space-y-2">
        <Label htmlFor="wl-teacherId">{t('booking', 'teacherLabel')}</Label>
        <Select id="wl-teacherId" name="teacherId" defaultValue={initialTeacherId}>
          <option value="">{t('booking', 'teacherAny')}</option>
          {teachers.map((tch) => (
            <option key={tch.id} value={tch.id}>
              {tch.full_name}
            </option>
          ))}
        </Select>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-2">
          <Label htmlFor="wl-childName">{t('booking', 'childNameLabel')}</Label>
          <Input id="wl-childName" name="childName" required />
        </div>
        <div className="space-y-2">
          <Label htmlFor="wl-childBirthDate">{t('booking', 'childBirthDateLabel')}</Label>
          <Input id="wl-childBirthDate" name="childBirthDate" type="date" required />
        </div>
      </div>

      <fieldset className="space-y-2">
        <legend className="text-sm font-medium">{t('booking', 'weekdaysLabel')}</legend>
        <div className="flex flex-wrap gap-2">
          {WEEKDAY_SHORT.map((label, i) => (
            <label key={label} className="cursor-pointer">
              <input type="checkbox" name="weekdays" value={i + 1} className="peer sr-only" />
              <span className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-md border border-border bg-background px-3 text-sm transition-colors peer-checked:border-primary peer-checked:bg-primary peer-checked:text-primary-foreground peer-focus-visible:ring-2 peer-focus-visible:ring-ring">
                {label}
              </span>
            </label>
          ))}
        </div>
        <p className="text-xs text-muted-foreground">{t('booking', 'weekdaysHint')}</p>
      </fieldset>

      <div className="grid grid-cols-2 gap-4">
        <div className="space-y-2">
          <Label htmlFor="wl-timeFrom">{t('booking', 'timeFromLabel')}</Label>
          <Input id="wl-timeFrom" name="timeFrom" type="time" />
        </div>
        <div className="space-y-2">
          <Label htmlFor="wl-timeTo">{t('booking', 'timeToLabel')}</Label>
          <Input id="wl-timeTo" name="timeTo" type="time" />
        </div>
      </div>

      <div className="space-y-2">
        <Label htmlFor="wl-parentName">{t('booking', 'parentNameLabel')}</Label>
        <Input id="wl-parentName" name="parentName" required />
      </div>

      <div className="space-y-2">
        <Label htmlFor="wl-parentPhone">{t('booking', 'phoneLabel')}</Label>
        <Input id="wl-parentPhone" name="parentPhone" type="tel" placeholder="0700 12 34 56" required />
      </div>

      <div className="space-y-2">
        <Label htmlFor="wl-comment">{t('booking', 'commentLabel')}</Label>
        <Textarea id="wl-comment" name="comment" maxLength={500} aria-describedby="wl-comment-hint" />
        <p id="wl-comment-hint" className="text-xs text-muted-foreground">{t('booking', 'commentHint')}</p>
      </div>

      <FormError message={state.message} />

      <SubmitButton />
      <Button type="button" variant="ghost" className="w-full" onClick={onBack}>
        {t('booking', 'backToBooking')}
      </Button>
    </form>
  )
}
