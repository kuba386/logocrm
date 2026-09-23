'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'

export type FunnelState = { error?: string; notice?: string }

/**
 * Ручной переход по воронке — только через set_funnel_stage (0055 Р3):
 * права, статус и граф переходов проверяет база, компонент не решает,
 * какие кнопки нажимаемы «по-настоящему» — только какие предлагать.
 */
export async function moveFunnelStage(_prev: FunnelState, formData: FormData): Promise<FunnelState> {
  const studentId = String(formData.get('studentId') ?? '').trim()
  const toStage = String(formData.get('toStage') ?? '').trim()
  if (!studentId || !toStage) return { error: 'Не выбран этап' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('set_funnel_stage', {
    p_student_id: studentId,
    p_to_stage: toStage,
  })
  if (error) return { error: toAppError(error, 'Не удалось сменить этап воронки').message }

  revalidatePath(`/app/students/${studentId}`)
  revalidatePath('/app/funnel')
  return { notice: 'Этап изменён' }
}
