'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'

export type DebtActionState = AppError & { notice?: string; done?: number }

const UUID = /^[0-9a-f-]{36}$/
const DAY = /^\d{4}-\d{2}-\d{2}$/

function tiyinFromSom(value: FormDataEntryValue | null): number {
  const som = Number(String(value ?? '').replace(',', '.').replace(/\s/g, ''))
  return Number.isFinite(som) ? Math.round(som * 100) : Number.NaN
}

function revalidateDebts() {
  revalidatePath('/app/debts')
  revalidatePath('/app')
  revalidatePath('/app/finance')
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
  const { error } = await supabase.rpc('accept_lesson_debt_payment', {
    p_student_id: studentId,
    p_amount_tiyin: amount,
    p_source_id: sourceId,
    p_paid_on: paidOn,
    p_expected_remaining_tiyin: expected,
    p_comment: comment || undefined,
  })
  if (error) return toAppError(error, 'Не удалось принять оплату')

  revalidateDebts()
  return { message: '', notice: amount > expected ? 'Оплата принята, переплата записана авансом' : 'Оплата принята', done: Date.now() }
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

  revalidateDebts()
  return { message: '', notice: 'Долг списан', done: Date.now() }
}
