'use server'

import { z } from 'zod'
import { formatKgPhone, localDayInZone, localTimeInZone, parseWeekdays } from '@logocrm/core'
import { createBookingClient } from '@/lib/supabase/booking'
import { toAppError } from '@/lib/errors'
import { verifyTurnstile } from '@/lib/turnstile'
import { t } from '@/lib/messages'
import { zonedDateTimeToIso } from '@/lib/timezone'

export type BookingState = {
  message?: string
  notice?: string
  /** Что именно записали — для экрана «Заявка отправлена» (UX-аудит, пакет 6). */
  summary?: { serviceId: string; teacherId: string; date: string; time: string; childName: string; parentPhone: string }
}

const baseSchema = z.object({
  slug: z.string().min(1),
  timezone: z.string().min(1),
  serviceId: z.string().uuid(),
  teacherId: z.string().uuid(),
  childName: z.string().trim().min(1),
  parentName: z.string().trim().min(1),
  parentPhone: z.string().trim().min(1),
})

// Режим hours (0109) — время выбрано из окон генератора и приходит готовым
// моментом; режим any (0057) — нативные дата и время в поясе центра.
const slotSchema = baseSchema.extend({ startsAt: z.string().datetime({ offset: true }) })
const freeSchema = baseSchema.extend({ date: z.string().min(1), time: z.string().min(1) })

export async function submitBooking(_prev: BookingState, formData: FormData): Promise<BookingState> {
  const raw = {
    slug: formData.get('slug'),
    timezone: formData.get('timezone'),
    serviceId: formData.get('serviceId'),
    teacherId: formData.get('teacherId'),
    childName: formData.get('childName'),
    parentName: formData.get('parentName'),
    parentPhone: formData.get('parentPhone'),
  }

  let startsAtIso: string
  let date: string
  let time: string
  let base: z.infer<typeof baseSchema>

  if (formData.get('mode') === 'hours') {
    const parsed = slotSchema.safeParse({ ...raw, startsAt: formData.get('startsAt') })
    if (!parsed.success) {
      return { message: formData.get('startsAt') ? t('booking', 'fillRequired') : t('booking', 'pickSlot') }
    }
    base = parsed.data
    startsAtIso = parsed.data.startsAt
    date = localDayInZone(startsAtIso, parsed.data.timezone)
    time = localTimeInZone(startsAtIso, parsed.data.timezone)
  } else {
    const parsed = freeSchema.safeParse({ ...raw, date: formData.get('date'), time: formData.get('time') })
    if (!parsed.success) {
      return { message: t('booking', 'fillRequired') }
    }
    base = parsed.data
    date = parsed.data.date
    time = parsed.data.time
    // Форма — нативные <input type=date/time>, без пояса; сервер экшена не в
    // поясе центра, поэтому дату/время переводим в UTC явно, а не через
    // new Date(`${date}T${time}`) (взял бы пояс сервера — CLAUDE.md).
    startsAtIso = zonedDateTimeToIso(date, time, parsed.data.timezone)
  }

  const { slug, serviceId, teacherId, childName, parentName, parentPhone } = base

  if (!(await verifyTurnstile(formData.get('captcha_token')))) {
    return { message: t('booking', 'captchaFailed') }
  }

  const supabase = createBookingClient()
  const { error } = await supabase.rpc('submit_booking_request', {
    p_slug: slug,
    p_service_id: serviceId,
    p_teacher_id: teacherId,
    p_starts_at: startsAtIso,
    p_child_name: childName,
    p_parent_name: parentName,
    p_parent_phone: parentPhone,
  })

  if (error) {
    return { message: toAppError(error, t('booking', 'submitFailed')).message }
  }

  return {
    notice: t('booking', 'submitSuccess'),
    summary: { serviceId, teacherId, date, time, childName, parentPhone },
  }
}

export async function getTeacherBusy(slug: string, teacherId: string, date: string) {
  const supabase = createBookingClient()
  const { data, error } = await supabase.rpc('booking_teacher_busy', {
    p_slug: slug,
    p_teacher_id: teacherId,
    p_date: date,
  })
  // Отказ — не «всё свободно»: пустой список выглядел бы как свободный день,
  // а отказ пришёл бы только после отправки заявки.
  if (error) return { busy: [], failed: true }
  return { busy: data ?? [], failed: false }
}

/** Свободные окна на весь горизонт центра (0109) — одним запросом, не по дням. */
export async function getFreeSlots(slug: string, serviceId: string, teacherId: string) {
  const supabase = createBookingClient()
  const { data, error } = await supabase.rpc('booking_free_slots', {
    p_slug: slug,
    p_service_id: serviceId,
    p_teacher_id: teacherId,
  })
  // Отказ — не «окон нет»: родитель ушёл бы в лист ожидания из-за сбоя.
  if (error) return { slots: [], failed: true }
  return { slots: (data ?? []).map((s) => ({ starts_at: s.starts_at })), failed: false }
}

export type WaitlistState = { message?: string; notice?: string }

const waitlistSchema = z.object({
  slug: z.string().min(1),
  serviceId: z.string().uuid(),
  teacherId: z.union([z.string().uuid(), z.literal('')]),
  childName: z.string().trim().min(1),
  childBirthDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  timeFrom: z.union([z.string().regex(/^\d{2}:\d{2}$/), z.literal('')]),
  timeTo: z.union([z.string().regex(/^\d{2}:\d{2}$/), z.literal('')]),
  parentName: z.string().trim().min(1),
  parentPhone: z.string().trim().min(1),
  comment: z.string().trim().max(500),
})

export async function submitWaitlist(_prev: WaitlistState, formData: FormData): Promise<WaitlistState> {
  const parsed = waitlistSchema.safeParse({
    slug: formData.get('slug'),
    serviceId: formData.get('serviceId'),
    teacherId: formData.get('teacherId') ?? '',
    childName: formData.get('childName'),
    childBirthDate: formData.get('childBirthDate'),
    timeFrom: formData.get('timeFrom') ?? '',
    timeTo: formData.get('timeTo') ?? '',
    parentName: formData.get('parentName'),
    parentPhone: formData.get('parentPhone'),
    comment: formData.get('comment') ?? '',
  })
  if (!parsed.success) {
    return { message: t('booking', 'waitlistFill') }
  }

  let weekdays: number[] | null
  try {
    weekdays = parseWeekdays(formData.getAll('weekdays').map(String))
  } catch {
    return { message: t('booking', 'waitlistFill') }
  }

  if (!(await verifyTurnstile(formData.get('captcha_token')))) {
    return { message: t('booking', 'captchaFailed') }
  }

  const v = parsed.data
  const supabase = createBookingClient()
  const { error } = await supabase.rpc('submit_waitlist_entry', {
    p_slug: v.slug,
    p_service_id: v.serviceId,
    p_teacher_id: v.teacherId === '' ? (null as unknown as string) : v.teacherId,
    p_child_name: v.childName,
    p_child_birth_date: v.childBirthDate,
    p_weekdays: weekdays as unknown as number[],
    p_time_from: v.timeFrom === '' ? (null as unknown as string) : v.timeFrom,
    p_time_to: v.timeTo === '' ? (null as unknown as string) : v.timeTo,
    p_parent_name: v.parentName,
    p_parent_phone: v.parentPhone,
    p_comment: v.comment === '' ? undefined : v.comment,
  })

  if (error) {
    return { message: toAppError(error, t('booking', 'waitlistFailed')).message }
  }

  return { notice: t('booking', 'waitlistSuccess', { phone: formatKgPhone(v.parentPhone) }) }
}
