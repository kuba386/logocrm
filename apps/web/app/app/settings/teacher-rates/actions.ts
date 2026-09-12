'use server'

import { revalidatePath } from 'next/cache'
import { teacherRateSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'
import type { CatalogState } from '@/app/app/settings/services/actions'

function text(formData: FormData, key: string): string {
  return String(formData.get(key) ?? '').trim()
}

/**
 * Ставка — прямой insert (0017: append-only, RPC нет; гварды
 * approved_salary_guard и financial_period_guard — триггеры). Единицы
 * задаёт модель: сомы → тыйыны, проценты → сотые процента.
 */
export async function addTeacherRate(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const model = text(formData, 'model')
  const raw = Number(text(formData, 'value').replace(',', '.'))
  const value = Number.isFinite(raw) ? Math.round(raw * 100) : Number.NaN

  const parsed = teacherRateSchema.safeParse({
    teacherId: text(formData, 'teacherId'),
    serviceId: text(formData, 'serviceId') || undefined,
    model,
    value,
    validFrom: text(formData, 'validFrom'),
  })
  if (!parsed.success) return { message: parsed.error.issues[0]?.message ?? t('teacherRates', 'checkForm') }
  const input = parsed.data

  const supabase = await createClient()
  const { error } = await supabase.from('teacher_rates').insert({
    teacher_id: input.teacherId,
    service_id: input.serviceId ?? null,
    model: input.model,
    value: input.value,
    valid_from: input.validFrom,
  })
  if (error) return toAppError(error, t('teacherRates', 'failed'))

  revalidatePath('/app/settings/teacher-rates')
  return { message: '', notice: t('teacherRates', 'saved') }
}
