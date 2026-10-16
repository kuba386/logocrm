'use server'

import { revalidatePath } from 'next/cache'
import { paySalarySchema, salaryAdjustmentSchema, teacherMonthSchema } from '@logocrm/contracts'
import { toTiyin } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'
import { t } from '@/lib/messages'

/** done — метка успеха, чтобы закрыть диалог выплаты. */
export type SalaryState = AppError & { notice?: string; done?: number }

function firstIssue(error: { issues: { message: string }[] }): SalaryState {
  return { message: error.issues[0]?.message ?? t('salary', 'checkForm') }
}

export async function recordSalaryAdjustment(_prev: SalaryState, formData: FormData): Promise<SalaryState> {
  const som = Number(String(formData.get('amountSom') ?? '').replace(',', '.'))
  const parsed = salaryAdjustmentSchema.safeParse({
    teacherId: String(formData.get('teacherId') ?? ''),
    month: String(formData.get('month') ?? ''),
    amountTiyin: Number.isFinite(som) ? Math.round(som * 100) : Number.NaN,
    reason: String(formData.get('reason') ?? ''),
  })
  if (!parsed.success) return firstIssue(parsed.error)
  const input = parsed.data

  const supabase = await createClient()
  const { error } = await supabase.rpc('record_salary_adjustment', {
    p_teacher_id: input.teacherId,
    p_month: input.month,
    p_amount_tiyin: input.amountTiyin,
    p_reason: input.reason,
  })
  if (error) return toAppError(error, t('salary', 'adjustmentFailed'))

  revalidatePath('/app/salary')
  return { message: '', notice: t('salary', 'adjustmentRecorded') }
}

export async function approveSalary(_prev: SalaryState, formData: FormData): Promise<SalaryState> {
  const parsed = teacherMonthSchema.safeParse({
    teacherId: String(formData.get('teacherId') ?? ''),
    month: String(formData.get('month') ?? ''),
  })
  if (!parsed.success) return firstIssue(parsed.error)

  const supabase = await createClient()
  const { error } = await supabase.rpc('approve_salary', {
    p_teacher_id: parsed.data.teacherId,
    p_month: parsed.data.month,
  })
  if (error) return toAppError(error, t('salary', 'approveFailed'))

  revalidatePath('/app/salary')
  return { message: '', notice: t('salary', 'approved') }
}

/** Только владелец (cancel_salary_run, 0029); отказ приходит из базы. */
export async function cancelSalaryRun(_prev: SalaryState, formData: FormData): Promise<SalaryState> {
  const parsed = teacherMonthSchema.safeParse({
    teacherId: String(formData.get('teacherId') ?? ''),
    month: String(formData.get('month') ?? ''),
  })
  if (!parsed.success) return firstIssue(parsed.error)

  const supabase = await createClient()
  const { error } = await supabase.rpc('cancel_salary_run', {
    p_teacher_id: parsed.data.teacherId,
    p_month: parsed.data.month,
  })
  if (error) return toAppError(error, t('salary', 'cancelFailed'))

  revalidatePath('/app/salary')
  return { message: '', notice: t('salary', 'runCancelled') }
}

/**
 * Выплата зарплаты из кассы (pay_salary, 0101): расход по статье «Зарплата»,
 * привязанный к специалисту и месяцу. Сколько осталось выплатить — из
 * salary_summary; expected уходит в RPC, и вторая вкладка с той же суммой
 * получит отказ со свежей, а не вторую выплату.
 */
export async function paySalary(_prev: SalaryState, formData: FormData): Promise<SalaryState> {
  const som = Number(String(formData.get('amountSom') ?? '').replace(',', '.').replace(/\s/g, ''))
  const parsed = paySalarySchema.safeParse({
    teacherId: String(formData.get('teacherId') ?? ''),
    month: String(formData.get('month') ?? ''),
    amountTiyin: Number.isFinite(som) ? toTiyin(som) : Number.NaN,
    sourceId: String(formData.get('sourceId') ?? ''),
    paidOn: String(formData.get('paidOn') ?? ''),
    expectedDueTiyin: Number(formData.get('expectedDueTiyin')),
    comment: String(formData.get('comment') ?? ''),
  })
  if (!parsed.success) return firstIssue(parsed.error)
  const input = parsed.data

  const supabase = await createClient()
  const { error } = await supabase.rpc('pay_salary', {
    p_teacher_id: input.teacherId,
    p_month: input.month,
    p_amount_tiyin: input.amountTiyin,
    p_source_id: input.sourceId,
    p_paid_on: input.paidOn,
    p_expected_due_tiyin: input.expectedDueTiyin,
    p_comment: input.comment || undefined,
  })
  if (error) return toAppError(error, t('salary', 'payFailed'))

  revalidatePath('/app/salary')
  revalidatePath('/app/finance')
  revalidatePath('/app/reports')
  return { message: '', notice: t('salary', 'paid'), done: Date.now() }
}
