'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'

export type MakeupPolicyState = { message?: string; notice?: string }

/** Политика отработок — set_makeup_policy (0105): owner/admin; пустой срок — выключить. */
export async function saveMakeupPolicy(_prev: MakeupPolicyState, formData: FormData): Promise<MakeupPolicyState> {
  const days = Number(String(formData.get('validDays') ?? '').trim())
  const limitRaw = String(formData.get('limit') ?? '').trim()
  const limit = limitRaw === '' ? null : Number(limitRaw)

  if (!Number.isInteger(days) || days < 1 || days > 365) return { message: 'Срок отработки — от 1 до 365 дней' }
  if (limit !== null && (!Number.isInteger(limit) || limit < 1 || limit > 100)) {
    return { message: 'Лимит на абонемент — от 1 до 100 или пусто' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('set_makeup_policy', { p_valid_days: days, p_limit: limit ?? undefined })
  if (error) return toAppError(error, 'Не удалось сохранить настройки отработок')

  revalidatePath('/app/settings/makeups')
  return { notice: 'Отработки включены' }
}

export async function disableMakeups(_prev: MakeupPolicyState): Promise<MakeupPolicyState> {
  const supabase = await createClient()
  // null — «выключить» (set_makeup_policy, 0105). Генератор типов не знает, что
  // аргумент функции допускает null, поэтому приведение явное.
  const { error } = await supabase.rpc('set_makeup_policy', { p_valid_days: null as unknown as number })
  if (error) return toAppError(error, 'Не удалось выключить отработки')

  revalidatePath('/app/settings/makeups')
  return { notice: 'Отработки выключены. Выданные права действуют до своего срока.' }
}
