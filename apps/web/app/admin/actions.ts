'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'

export type AdminState = { message?: string; notice?: string }

/**
 * Подтверждение — extend_subscription (0051): тариф, месяцы и сумма —
 * параметры действия администратора, не поля заявки (заявка на 12 месяцев
 * за месячную цену не должна продлевать год). План и срок центра меняются
 * одним update; повтор по той же заявке — отказ без изменений.
 */
export async function confirmPayment(_prev: AdminState, formData: FormData): Promise<AdminState> {
  const paymentId = String(formData.get('paymentId') ?? '').trim()
  const plan = String(formData.get('plan') ?? '').trim()
  const months = Number(formData.get('months') ?? 0)
  const amountSom = Number(String(formData.get('amountSom') ?? '').replace(',', '.'))
  const receiptReceived = formData.get('receiptReceived') === 'on'

  if (!paymentId || !plan || !Number.isInteger(months) || months < 1 || !Number.isFinite(amountSom) || amountSom <= 0) {
    return { message: t('admin', 'confirmFailed') }
  }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('extend_subscription', {
    p_payment_id: paymentId,
    p_plan: plan,
    p_months: months,
    p_amount_tiyin: Math.round(amountSom * 100),
    p_receipt_received: receiptReceived,
  })
  if (error) return toAppError(error, t('admin', 'confirmFailed'))

  revalidatePath('/admin')
  const until = (data as { subscription_until?: string } | null)?.subscription_until
  return { notice: t('admin', 'confirmed', { until: until ? until.slice(0, 10) : '—' }) }
}

/**
 * Второй центр владельцу — platform_create_center (0052 Р9): владелец по
 * подтверждённому email, платформа членства не получает, trial-лимит из
 * платформенной сессии не действует.
 */
export async function createCenterForOwner(_prev: AdminState, formData: FormData): Promise<AdminState> {
  const name = String(formData.get('name') ?? '').trim()
  const ownerEmail = String(formData.get('ownerEmail') ?? '').trim()
  const city = String(formData.get('city') ?? '').trim()
  if (!name || !ownerEmail) return { message: t('admin', 'createCenterFailed') }

  const supabase = await createClient()
  const { error } = await supabase.rpc('platform_create_center', {
    p_name: name,
    p_owner_email: ownerEmail,
    p_city: city || undefined,
  })
  if (error) return toAppError(error, t('admin', 'createCenterFailed'))

  revalidatePath('/admin')
  return { notice: t('admin', 'centerCreated', { name }) }
}

/** Отклонение с причиной — reject_platform_payment (0051 Р3). Центр видит причину в истории заявок. */
export async function rejectPayment(_prev: AdminState, formData: FormData): Promise<AdminState> {
  const paymentId = String(formData.get('paymentId') ?? '').trim()
  const reason = String(formData.get('reason') ?? '').trim()
  if (!paymentId || !reason) return { message: t('admin', 'rejectNeedsReason') }

  const supabase = await createClient()
  const { error } = await supabase.rpc('reject_platform_payment', { p_payment_id: paymentId, p_reason: reason })
  if (error) return toAppError(error, t('admin', 'rejectFailed'))

  revalidatePath('/admin')
  return { notice: t('admin', 'rejected') }
}
