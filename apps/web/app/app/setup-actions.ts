'use server'

import { cookies } from 'next/headers'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { setupHiddenCookie } from '@/lib/setup-checklist'

/**
 * «Скрыть» на плашке настройки центра. Это предпочтение одного человека в
 * одном браузере, а не состояние центра, — поэтому cookie, а не запись в
 * базу: второй администратор плашку по-прежнему видит, пока шаги не готовы.
 * Имя cookie несёт center_id — скрытие в одном центре не прячет плашку в
 * другом, куда тот же человек переключится.
 */
export async function hideSetupChecklist(): Promise<void> {
  const centerId = await currentCenterId()
  if (!centerId) return

  const store = await cookies()
  store.set(setupHiddenCookie(centerId), '1', {
    path: '/app',
    httpOnly: true,
    sameSite: 'lax',
    secure: process.env.NODE_ENV === 'production',
    maxAge: 60 * 60 * 24 * 365,
  })
  revalidatePath('/app')
}


/** «Показать» в строке скрытой плашки — снять cookie, плашка возвращается целиком. */
export async function showSetupChecklist(): Promise<void> {
  const centerId = await currentCenterId()
  if (!centerId) return

  const store = await cookies()
  store.delete({ name: setupHiddenCookie(centerId), path: '/app' })
  revalidatePath('/app')
}

async function currentCenterId(): Promise<string | undefined> {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  return (user?.app_metadata as { center_id?: string } | undefined)?.center_id
}
