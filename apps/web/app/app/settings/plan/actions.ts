'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'

export type PlanState = { message?: string; notice?: string }

/**
 * Заявка «я оплатил» — submit_platform_payment (0051): сумма считается в
 * SQL из прайса, вторая открытая заявка отбивается частичным unique,
 * право (owner/admin) и центр — внутри функции. Работает и в режиме только
 * чтения: таблица заявок в списке исключений guard.
 */
export async function submitPayment(_prev: PlanState, formData: FormData): Promise<PlanState> {
  const plan = String(formData.get('plan') ?? '').trim()
  const months = Number(formData.get('months') ?? 0)
  const source = String(formData.get('source') ?? '').trim()
  const note = String(formData.get('note') ?? '').trim()

  if (!plan || !source || !Number.isInteger(months) || months < 1) {
    return { message: t('plan', 'submitFailed') }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('submit_platform_payment', {
    p_plan: plan,
    p_months: months,
    p_source: source,
    p_note: note || undefined,
  })
  if (error) return toAppError(error, t('plan', 'submitFailed'))

  revalidatePath('/app/settings/plan')
  revalidatePath('/app', 'layout')
  return { notice: t('plan', 'submitted') }
}

/** Отзыв своей открытой заявки — withdraw_platform_payment (0051 Р3). */
export async function withdrawPayment(_prev: PlanState, formData: FormData): Promise<PlanState> {
  const paymentId = String(formData.get('paymentId') ?? '').trim()
  if (!paymentId) return { message: t('plan', 'withdrawFailed') }

  const supabase = await createClient()
  const { error } = await supabase.rpc('withdraw_platform_payment', { p_payment_id: paymentId })
  if (error) return toAppError(error, t('plan', 'withdrawFailed'))

  revalidatePath('/app/settings/plan')
  return { notice: t('plan', 'withdrawn') }
}
