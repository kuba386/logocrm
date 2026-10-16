'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'

/** paymentId — проведённый платёж (ссылка «Квитанция» в итоге); done — метка успеха для закрытия диалога. */
export type DebtActionState = AppError & { notice?: string; done?: number; paymentId?: string }

const UUID = /^[0-9a-f-]{36}$/
const DAY = /^\d{4}-\d{2}-\d{2}$/

function tiyinFromSom(value: FormDataEntryValue | null): number {
  const som = Number(String(value ?? '').replace(',', '.').replace(/\s/g, ''))
  return Number.isFinite(som) ? Math.round(som * 100) : Number.NaN
}

function revalidateDebts(studentId?: string) {
  revalidatePath('/app/debts')
  revalidatePath('/app')
  revalidatePath('/app/finance')
  if (studentId) revalidatePath(`/app/students/${studentId}`)
}

/**
 * Оплата долга за занятия и перерасхода (0087). Сумму долга не считаем: RPC
 * сверяет expected с пересчётом под блокировкой и при расхождении отвечает
 * 23514 со свежей суммой — две вкладки не оплатят один долг дважды.
 */
export async function acceptDebtPayment(_prev: DebtActionState, formData: FormData): Promise<DebtActionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const sourceId = String(formData.get('sourceId') ?? '')
  const paidOn = String(formData.get('paidOn') ?? '')
  const amount = tiyinFromSom(formData.get('amountSom'))
  const expected = Number(formData.get('expectedTiyin'))
  const comment = String(formData.get('comment') ?? '').trim()

  if (!UUID.test(studentId) || !Number.isInteger(expected)) return { message: 'Обновите страницу и попробуйте снова' }
  if (!Number.isFinite(amount) || amount <= 0) return { message: 'Укажите сумму больше нуля' }
  if (!UUID.test(sourceId)) return { message: 'Укажите источник оплаты' }
  if (!DAY.test(paidOn)) return { message: 'Укажите дату оплаты' }

  const supabase = await createClient()
  const { data: paymentId, error } = await supabase.rpc('accept_lesson_debt_payment', {
    p_student_id: studentId,
    p_amount_tiyin: amount,
    p_source_id: sourceId,
    p_paid_on: paidOn,
    p_expected_remaining_tiyin: expected,
    p_comment: comment || undefined,
  })
  if (error) return toAppError(error, 'Не удалось принять оплату')

  revalidateDebts(studentId)
  return {
    message: '',
    notice: amount > expected ? 'Оплата принята, переплата записана авансом' : 'Оплата принята',
    done: Date.now(),
    paymentId: paymentId ?? undefined,
  }
}

/** Списание без денег — только владелец (проверяет SQL), причина обязательна. */
export async function writeOffDebt(_prev: DebtActionState, formData: FormData): Promise<DebtActionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const amount = tiyinFromSom(formData.get('amountSom'))
  const expected = Number(formData.get('expectedTiyin'))
  const reason = String(formData.get('reason') ?? '').trim()

  if (!UUID.test(studentId) || !Number.isInteger(expected)) return { message: 'Обновите страницу и попробуйте снова' }
  if (!Number.isFinite(amount) || amount <= 0) return { message: 'Укажите сумму больше нуля' }
  if (!reason) return { message: 'Укажите причину списания' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('write_off_lesson_debt', {
    p_student_id: studentId,
    p_amount_tiyin: amount,
    p_reason: reason,
    p_expected_remaining_tiyin: expected,
  })
  if (error) return toAppError(error, 'Не удалось списать долг')

  revalidateDebts(studentId)
  return { message: '', notice: 'Долг списан', done: Date.now() }
}

/**
 * Вернуть аванс за занятия деньгами (refund_lesson_debt_credit, 0087).
 * Раньше в интерфейсе этого не было: возврат через «Финансы» уменьшал кассу,
 * но аванс оставался в счёте занятий и молча оплачивал следующие занятия —
 * одни и те же деньги считались дважды (аудит финансов 16.10.2026).
 * expected — аванс, который показали в форме: изменился — 23514.
 */
export async function refundLessonCredit(_prev: DebtActionState, formData: FormData): Promise<DebtActionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const sourceId = String(formData.get('sourceId') ?? '')
  const paidOn = String(formData.get('paidOn') ?? '')
  const amount = tiyinFromSom(formData.get('amountSom'))
  const expected = Number(formData.get('expectedCreditTiyin'))

  if (!UUID.test(studentId) || !Number.isInteger(expected)) return { message: 'Обновите страницу и попробуйте снова' }
  if (!Number.isFinite(amount) || amount <= 0) return { message: 'Укажите сумму больше нуля' }
  if (amount > expected) return { message: 'Вернуть можно не больше аванса' }
  if (!UUID.test(sourceId)) return { message: 'Укажите, откуда выдаёте деньги' }
  if (!DAY.test(paidOn)) return { message: 'Укажите дату возврата' }

  const supabase = await createClient()
  const { data: paymentId, error } = await supabase.rpc('refund_lesson_debt_credit', {
    p_student_id: studentId,
    p_amount_tiyin: amount,
    p_source_id: sourceId,
    p_paid_on: paidOn,
    p_expected_credit_tiyin: expected,
  })
  if (error) return toAppError(error, 'Не удалось вернуть аванс')

  revalidateDebts(studentId)
  return { message: '', notice: 'Аванс возвращён', done: Date.now(), paymentId: paymentId ?? undefined }
}
