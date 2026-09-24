'use server'

import { z } from 'zod'
import { createBookingClient } from '@/lib/supabase/booking'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'
import { zonedDateTimeToIso } from '@/lib/timezone'

export type BookingState = {
  message?: string
  notice?: string
}

const submitSchema = z.object({
  slug: z.string().min(1),
  timezone: z.string().min(1),
  serviceId: z.string().uuid(),
  teacherId: z.string().uuid(),
  date: z.string().min(1),
  time: z.string().min(1),
  childName: z.string().trim().min(1),
  parentName: z.string().trim().min(1),
  parentPhone: z.string().trim().min(1),
})

export async function submitBooking(_prev: BookingState, formData: FormData): Promise<BookingState> {
  const parsed = submitSchema.safeParse({
    slug: formData.get('slug'),
    timezone: formData.get('timezone'),
    serviceId: formData.get('serviceId'),
    teacherId: formData.get('teacherId'),
    date: formData.get('date'),
    time: formData.get('time'),
    childName: formData.get('childName'),
    parentName: formData.get('parentName'),
    parentPhone: formData.get('parentPhone'),
  })

  if (!parsed.success) {
    return { message: t('booking', 'fillRequired') }
  }

  const { slug, timezone, serviceId, teacherId, date, time, childName, parentName, parentPhone } = parsed.data
  // Форма — нативные <input type=date/time>, без пояса; сервер экшена не в
  // поясе центра, поэтому дату/время переводим в UTC явно, а не через
  // new Date(`${date}T${time}`) (взял бы пояс сервера — CLAUDE.md).
  const startsAtIso = zonedDateTimeToIso(date, time, timezone)

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

  return { notice: t('booking', 'submitSuccess') }
}

export async function getTeacherBusy(slug: string, teacherId: string, date: string) {
  const supabase = createBookingClient()
  const { data, error } = await supabase.rpc('booking_teacher_busy', {
    p_slug: slug,
    p_teacher_id: teacherId,
    p_date: date,
  })
  if (error) return []
  return data ?? []
}
