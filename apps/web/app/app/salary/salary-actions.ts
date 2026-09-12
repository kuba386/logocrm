'use server'

import { revalidatePath } from 'next/cache'
import { salaryAdjustmentSchema, teacherMonthSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'
import { t } from '@/lib/messages'

export type SalaryState = AppError & { notice?: string }

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
