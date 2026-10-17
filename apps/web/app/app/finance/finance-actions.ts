'use server'

import { revalidatePath } from 'next/cache'
import { formatSom } from '@logocrm/core'
import {
  cashCountSchema,
  cashTransferSchema,
  monthSchema,
  payInstallmentSchema,
  recordExpenseSchema,
  recordPaymentSchema,
  voidExpenseSchema,
} from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'
import { t } from '@/lib/messages'

/** paymentId — проведённый платёж (ссылка «Квитанция»); done — метка успеха, чтобы закрыть диалог. */
export type FinanceState = AppError & { notice?: string; paymentId?: string; done?: number }

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
  const { data: paymentId, error } = await supabase.rpc('record_payment', {
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
  if (input.studentId) revalidatePath(`/app/students/${input.studentId}`)
  revalidatePath(`/app/payers/${input.payerId}`)
  const notice =
    input.kind === 'refund'
      ? t('finance', 'refundRecorded')
      : input.kind === 'correction'
        ? t('finance', 'correctionRecorded')
        : t('finance', 'paymentRecorded')
  return { message: '', notice, paymentId: paymentId ?? undefined, done: Date.now() }
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
  revalidatePath('/app/reports')
  return { message: '', notice: t('finance', 'expenseRecorded'), done: Date.now() }
}

/**
 * Платёж по строке рассрочки (0100): проводится накопительно — всё по эту
 * строку включительно. expected — сумма, которую показали на кнопке
 * (installments_view.due_through_tiyin); изменилась — база ответит 23514 со
 * свежей суммой, и ничего не запишет.
 */
export async function payInstallment(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const parsed = payInstallmentSchema.safeParse({
    installmentId: String(formData.get('installmentId') ?? ''),
    expectedAmountTiyin: Number(formData.get('expectedAmountTiyin') ?? ''),
    sourceId: String(formData.get('sourceId') ?? ''),
    comment: optional(formData, 'comment') ?? '',
  })
  if (!parsed.success) return firstIssue(parsed.error, t('finance', 'checkForm'))
  const input = parsed.data

  const supabase = await createClient()
  const { data: paymentId, error } = await supabase.rpc('pay_installment', {
    p_installment_id: input.installmentId,
    p_expected_amount_tiyin: input.expectedAmountTiyin,
    p_source_id: input.sourceId,
    p_comment: input.comment || undefined,
  })
  if (error) return toAppError(error, t('finance', 'installmentFailed'))

  revalidatePath('/app/finance')
  revalidatePath('/app/debts')
  return { message: '', notice: t('finance', 'installmentPaid'), paymentId: paymentId ?? undefined, done: Date.now() }
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

/**
 * Отменить ошибочное поступление без абонемента (void_payment, 0093) —
 * только владелец, с причиной. База пишет корректировку на ту же сумму с
 * минусом той же датой; исходная строка остаётся в истории.
 */
export async function voidPayment(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const paymentId = String(formData.get('paymentId') ?? '')
  const reason = String(formData.get('reason') ?? '').trim()
  if (!paymentId) return { message: 'Обновите страницу и попробуйте снова' }
  if (!reason) return { message: 'Укажите причину отмены' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('void_payment', { p_payment_id: paymentId, p_reason: reason })
  if (error) return toAppError(error, 'Не удалось отменить платёж')

  revalidatePath('/app/finance')
  revalidatePath('/app/payers')
  return { message: '', notice: 'Платёж отменён' }
}

/**
 * Отменить ошибочный расход (void_expense, 0101) — только владелец, с причиной.
 * Как у платежей (0093): база пишет корректировку на ту же сумму с минусом той
 * же датой, исходная строка остаётся. Выплата зарплаты отменяется так же —
 * «Выплачено» у специалиста уменьшится.
 */
export async function voidExpense(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const parsed = voidExpenseSchema.safeParse({
    expenseId: String(formData.get('expenseId') ?? ''),
    reason: String(formData.get('reason') ?? ''),
  })
  if (!parsed.success) return firstIssue(parsed.error, t('finance', 'checkForm'))

  const supabase = await createClient()
  const { error } = await supabase.rpc('void_expense', { p_expense_id: parsed.data.expenseId, p_reason: parsed.data.reason })
  if (error) return toAppError(error, 'Не удалось отменить расход')

  revalidatePath('/app/finance')
  revalidatePath('/app/salary')
  revalidatePath('/app/reports')
  return { message: '', notice: 'Расход отменён', done: Date.now() }
}

/**
 * Перевод между кассами (record_cash_transfer, 0101): наличные сдали в банк,
 * терминал перечислил на счёт. Итог центра не меняется, меняются итоги касс.
 * Ошибочный перевод исправляется обратным переводом.
 */
export async function recordCashTransfer(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const parsed = cashTransferSchema.safeParse({
    fromSourceId: String(formData.get('fromSourceId') ?? ''),
    toSourceId: String(formData.get('toSourceId') ?? ''),
    amountTiyin: signedTiyin(formData, 'amountSom', false),
    transferredOn: String(formData.get('transferredOn') ?? ''),
    comment: optional(formData, 'comment') ?? '',
    transferKey: String(formData.get('transferKey') ?? ''),
  })
  if (!parsed.success) return firstIssue(parsed.error, t('finance', 'checkForm'))
  const input = parsed.data

  const supabase = await createClient()
  const { error } = await supabase.rpc('record_cash_transfer', {
    p_from_source_id: input.fromSourceId,
    p_to_source_id: input.toSourceId,
    p_amount_tiyin: input.amountTiyin,
    p_transfer_key: input.transferKey,
    p_transferred_on: input.transferredOn,
    p_comment: input.comment || undefined,
  })
  if (error) return toAppError(error, 'Не удалось провести перевод')

  revalidatePath('/app/finance')
  revalidatePath('/app/reports')
  return { message: '', notice: t('finance', 'transferRecorded'), done: Date.now() }
}

/** Остаток кассы по учёту для формы сверки (cash_count_preview, 0102): на конец дня, сегодня — на сейчас. */
export async function previewCashCount(
  sourceId: string,
  day: string,
): Promise<{ expectedTiyin: number; today: string; lastCountOn: string | null } | { message: string }> {
  if (!/^[0-9a-f-]{36}$/.test(sourceId) || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return { message: 'Обновите страницу и попробуйте снова' }
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('cash_count_preview', { p_source_id: sourceId, p_day: day })
  if (error) return toAppError(error, 'Не удалось посчитать остаток по учёту')
  const row = data?.[0]
  if (!row) return { message: 'Не удалось посчитать остаток по учёту' }
  return { expectedTiyin: row.expected_tiyin, today: row.today, lastCountOn: row.last_count_on }
}

/**
 * Сверка кассы (record_cash_count, 0102): посчитанное становится якорем остатка.
 * Расхождение считает база; текст итога — отсюда, из её ответа.
 */
export async function recordCashCount(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const parsed = cashCountSchema.safeParse({
    sourceId: String(formData.get('sourceId') ?? ''),
    countedOn: String(formData.get('countedOn') ?? ''),
    countedTiyin: signedTiyin(formData, 'countedSom', false),
    expectedTiyin: Number(formData.get('expectedTiyin') ?? 'x'),
    countKey: String(formData.get('countKey') ?? ''),
    comment: optional(formData, 'comment') ?? '',
  })
  if (!parsed.success) return firstIssue(parsed.error, t('finance', 'checkForm'))
  const input = parsed.data

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('record_cash_count', {
    p_source_id: input.sourceId,
    p_counted_on: input.countedOn,
    p_counted_tiyin: input.countedTiyin,
    p_expected_tiyin: input.expectedTiyin,
    p_count_key: input.countKey,
    p_comment: input.comment || undefined,
  })
  if (error) return toAppError(error, 'Не удалось сохранить сверку')

  const row = data?.[0]
  const diff = row?.difference_tiyin ?? 0
  const notice = row?.is_opening
    ? t('finance', 'cashCountOpening')
    : diff === 0
      ? t('finance', 'cashCountMatched')
      : diff < 0
        ? t('finance', 'cashCountShortage', { sum: formatSom(-diff) })
        : t('finance', 'cashCountSurplus', { sum: formatSom(diff) })
  revalidatePath('/app/finance')
  return { message: '', notice, done: Date.now() }
}

/** Отмена ошибочной сверки (cancel_cash_count, 0102) — только владелец, с причиной. */
export async function cancelCashCount(_prev: FinanceState, formData: FormData): Promise<FinanceState> {
  const countId = String(formData.get('countId') ?? '')
  const reason = String(formData.get('reason') ?? '').trim()
  if (!countId) return { message: 'Обновите страницу и попробуйте снова' }
  if (!reason) return { message: 'Укажите причину отмены' }
  const supabase = await createClient()
  const { error } = await supabase.rpc('cancel_cash_count', { p_count_id: countId, p_reason: reason })
  if (error) return toAppError(error, 'Не удалось отменить сверку')
  revalidatePath('/app/finance')
  return { message: '', notice: 'Сверка отменена', done: Date.now() }
}
