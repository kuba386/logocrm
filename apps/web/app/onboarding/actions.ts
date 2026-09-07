'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { createCenterSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'

export type OnboardingState = { error?: string }

/**
 * Создаёт центр через rpc create_center и переключает на него сессию.
 *
 * create_center пишет center_id в app_metadata пользователя, но в текущем JWT
 * его ещё нет — поэтому обязателен refreshSession(), иначе RLS не увидит центр.
 */
export async function createCenter(
  _prev: OnboardingState,
  formData: FormData,
): Promise<OnboardingState> {
  const parsed = createCenterSchema.safeParse({
    name: String(formData.get('name') ?? ''),
    city: String(formData.get('city') ?? ''),
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте введённые данные' }
  }

  const supabase = await createClient()

  const { error } = await supabase.rpc('create_center', {
    p_name: parsed.data.name,
    p_city: parsed.data.city,
  })

  if (error) {
    return { error: 'Не удалось создать центр. Попробуйте ещё раз.' }
  }

  const { error: refreshError } = await supabase.auth.refreshSession()
  if (refreshError) {
    return { error: 'Центр создан, но сессию не удалось обновить. Войдите заново.' }
  }

  revalidatePath('/', 'layout')
  redirect('/app')
}
