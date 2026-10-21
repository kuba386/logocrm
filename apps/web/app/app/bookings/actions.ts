'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'

export type QueueState = { message?: string; notice?: string }

export async function payerMatch(requestId: string): Promise<{ id: string; name: string } | null> {
  const supabase = await createClient()
  const { data } = await supabase.rpc('booking_request_payer_match', { p_request_id: requestId })
  const row = data?.[0]
  return row ? { id: row.payer_id, name: row.payer_name } : null
}

export async function confirmBooking(
  requestId: string,
  payerId: string | null,
  _prev: QueueState,
): Promise<QueueState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('confirm_booking_request', {
    p_request_id: requestId,
    p_payer_id: payerId ?? undefined,
  })
  if (error) return { message: toAppError(error, t('bookingQueue', 'actionFailed')).message }

  revalidatePath('/app/bookings')
  return { notice: t('bookingQueue', 'confirmSuccess') }
}

export async function declineBooking(_prev: QueueState, formData: FormData): Promise<QueueState> {
  const requestId = String(formData.get('requestId') ?? '')
  const reason = String(formData.get('reason') ?? '') || null

  const supabase = await createClient()

  // 0109 Р11: «всё с этого номера» — живая заявка и лист ожидания одним действием.
  if (formData.get('allFromPhone') === 'on') {
    const { data, error } = await supabase.rpc('decline_booking_phone', { p_request_id: requestId, p_reason: reason ?? undefined })
    if (error) return { message: toAppError(error, t('bookingQueue', 'actionFailed')).message }
    revalidatePath('/app/bookings')
    return { notice: t('bookingQueue', 'declineAllSuccess', { count: data ?? 0 }) }
  }

  const { error } = await supabase.rpc('decline_booking_request', { p_request_id: requestId, p_reason: reason ?? undefined })
  if (error) return { message: toAppError(error, t('bookingQueue', 'actionFailed')).message }

  revalidatePath('/app/bookings')
  return { notice: t('bookingQueue', 'declineSuccess') }
}

// Лист ожидания (0109) -----------------------------------------------------------------------

export type WaitlistActionState = QueueState & { studentId?: string }

export async function waitlistPayerMatch(entryId: string): Promise<{ id: string; name: string } | null> {
  const supabase = await createClient()
  const { data } = await supabase.rpc('waitlist_entry_payer_match', { p_entry_id: entryId })
  const row = data?.[0]
  return row ? { id: row.payer_id, name: row.payer_name } : null
}

export async function offerWaitlist(entryId: string, _prev: QueueState): Promise<QueueState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('offer_waitlist_entry', { p_entry_id: entryId })
  if (error) return { message: toAppError(error, t('bookingQueue', 'actionFailed')).message }

  revalidatePath('/app/bookings')
  return { notice: t('bookingQueue', 'offerSuccess') }
}

export async function withdrawWaitlist(entryId: string, _prev: QueueState, formData: FormData): Promise<QueueState> {
  const reason = String(formData.get('reason') ?? '').trim()

  const supabase = await createClient()
  const { error } = await supabase.rpc('withdraw_waitlist_entry', { p_entry_id: entryId, p_reason: reason || undefined })
  if (error) return { message: toAppError(error, t('bookingQueue', 'actionFailed')).message }

  revalidatePath('/app/bookings')
  return { notice: t('bookingQueue', 'withdrawSuccess') }
}

export async function enrollWaitlist(
  entryId: string,
  payerId: string | null,
  _prev: WaitlistActionState,
): Promise<WaitlistActionState> {
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('enroll_waitlist_entry', {
    p_entry_id: entryId,
    p_payer_id: payerId ?? undefined,
  })
  if (error) return { message: toAppError(error, t('bookingQueue', 'actionFailed')).message }

  revalidatePath('/app/bookings')
  revalidatePath('/app/students')
  return { notice: t('bookingQueue', 'enrollSuccess'), studentId: data ?? undefined }
}
