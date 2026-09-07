'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { switchCenterSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'

export type SelectCenterState = { error?: string }

/**
 * Переключает активный центр: rpc switch_center пишет center_id в app_metadata,
 * refreshSession() подтягивает новый JWT — без него RLS продолжит работать
 * со старым center_id.
 */
export async function switchCenter(
  _prev: SelectCenterState,
  formData: FormData,
): Promise<SelectCenterState> {
  const parsed = switchCenterSchema.safeParse({ centerId: String(formData.get('centerId') ?? '') })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Выберите центр' }
  }

  const supabase = await createClient()

  const { error } = await supabase.rpc('switch_center', { p_center_id: parsed.data.centerId })
  if (error) {
    return { error: 'Нет доступа к этому центру.' }
  }

  const { error: refreshError } = await supabase.auth.refreshSession()
  if (refreshError) {
    return { error: 'Не удалось обновить сессию. Войдите заново.' }
  }

  revalidatePath('/', 'layout')
  redirect('/app')
}
