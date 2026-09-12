'use server'

import { revalidatePath } from 'next/cache'
import { monthSchema, payInstallmentSchema, recordExpenseSchema, recordPaymentSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'
import { t } from '@/lib/messages'

export type FinanceState = AppError & { notice?: string }

function optional(formData: FormData, key: string): string | undefined {
  const value = String(formData.get(key) ?? '').trim()
  return value === '' ? undefined : value
}

/** Сумма из формы — модуль в сомах; знак ставится по виду операции (payments_sign_matches_kind). */
function signedTiyin(formData: FormData, key: string, negative: boolean): number {
  const som = Number(String(formData.get(key) ?? '').replace(',', '.'))
  if (!Number.isFinite(som)) return Number.NaN
  const tiyin = Math.round(Math.abs(som) * 100)
  return negative ? -tiyin : tiyin
}

function firstIssue(error: { issues: { message: string }[] }, fallback: string): FinanceState {
  return { message: error.issues[0]?.message ?? fallback }
}

/**
 * Платёж без привязки к абонементу: возврат, корректировка, оплата вне
 * абонемента. Платёж за абонемент — sell_subscription_paid и pay_installment
 * с карточки ученика: только они двигают paid_tiyin осмысленно.
 */
export async function recordPayment(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const kind = String(formData.get('kind') ?? 'payment')
  const parsed = recordPaymentSchema.safeParse({
    payerId: String(formData.get('payerId') ?? ''),
    studentId: optional(formData, 'studentId'),
    kind,
    amountTiyin: signedTiyin(formData, 'amountSom', kind === 'refund'),
    sourceId: optional(formData, 'sourceId'),
    paidOn: String(formData.get('paidOn') ?? ''),
    comment: optional(formData, 'comment') ?? '',
  })
  if (!parsed.success) return firstIssue(parsed.error, t('finance', 'checkForm'))
  const input = parsed.data

  const supabase = await createClient()
  const { error } = await supabase.rpc('record_payment', {
    p_payer_id: input.payerId,
    p_amount_tiyin: input.amountTiyin,
    p_kind: input.kind,
    p_student_id: input.studentId,
    p_source_id: input.sourceId,
    p_paid_on: input.paidOn,
    p_comment: input.comment || undefined,
  })
  if (error) return toAppError(error, t('finance', 'paymentFailed'))

  revalidatePath('/app/finance')
  const notice =
    input.kind === 'refund'
      ? t('finance', 'refundRecorded')
      : input.kind === 'correction'
        ? t('finance', 'correctionRecorded')
        : t('finance', 'paymentRecorded')
  return { message: '', notice }
}

export async function recordExpense(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const kind = String(formData.get('kind') ?? 'expense')
  const parsed = recordExpenseSchema.safeParse({
    categoryId: String(formData.get('categoryId') ?? ''),
    kind,
    amountTiyin: signedTiyin(formData, 'amountSom', kind === 'refund'),
    sourceId: optional(formData, 'sourceId'),
    paidOn: String(formData.get('paidOn') ?? ''),
    comment: optional(formData, 'comment') ?? '',
  })
  if (!parsed.success) return firstIssue(parsed.error, t('finance', 'checkForm'))
  const input = parsed.data

  const supabase = await createClient()
  const { error } = await supabase.rpc('record_expense', {
    p_category_id: input.categoryId,
    p_amount_tiyin: input.amountTiyin,
    p_kind: input.kind,
    p_source_id: input.sourceId,
    p_paid_on: input.paidOn,
    p_comment: input.comment || undefined,
  })
  if (error) return toAppError(error, t('finance', 'expenseFailed'))

  revalidatePath('/app/finance')
  return { message: '', notice: t('finance', 'expenseRecorded') }
}

/** Сумма строки рассрочки считается в pay_installment — форма её не передаёт. */
export async function payInstallment(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const parsed = payInstallmentSchema.safeParse({
    installmentId: String(formData.get('installmentId') ?? ''),
    sourceId: String(formData.get('sourceId') ?? ''),
    comment: optional(formData, 'comment') ?? '',
  })
  if (!parsed.success) return firstIssue(parsed.error, t('finance', 'checkForm'))
  const input = parsed.data

  const supabase = await createClient()
  const { error } = await supabase.rpc('pay_installment', {
    p_installment_id: input.installmentId,
    p_source_id: input.sourceId,
    p_comment: input.comment || undefined,
  })
  if (error) return toAppError(error, t('finance', 'installmentFailed'))

  revalidatePath('/app/finance')
  return { message: '', notice: t('finance', 'installmentPaid') }
}

export async function closeMonth(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const parsed = monthSchema.safeParse({ month: String(formData.get('month') ?? '') })
  if (!parsed.success) return firstIssue(parsed.error, t('finance', 'checkForm'))

  const supabase = await createClient()
  const { error } = await supabase.rpc('close_month', { p_month: parsed.data.month })
  if (error) return toAppError(error, t('finance', 'closeFailed'))

  revalidatePath('/app/finance')
  return { message: '', notice: t('finance', 'monthClosed') }
}

export async function reopenMonth(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const parsed = monthSchema.safeParse({ month: String(formData.get('month') ?? '') })
  if (!parsed.success) return firstIssue(parsed.error, t('finance', 'checkForm'))

  const supabase = await createClient()
  const { error } = await supabase.rpc('reopen_month', { p_month: parsed.data.month })
  if (error) return toAppError(error, t('finance', 'reopenFailed'))

  revalidatePath('/app/finance')
  return { message: '', notice: t('finance', 'monthReopened') }
}
