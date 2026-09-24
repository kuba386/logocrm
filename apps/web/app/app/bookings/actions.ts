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
  const { error } = await supabase.rpc('decline_booking_request', { p_request_id: requestId, p_reason: reason ?? undefined })
  if (error) return { message: toAppError(error, t('bookingQueue', 'actionFailed')).message }

  revalidatePath('/app/bookings')
  return { notice: t('bookingQueue', 'declineSuccess') }
}
