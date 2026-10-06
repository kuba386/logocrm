'use server'

import { cookies } from 'next/headers'
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { setupHiddenCookie } from '@/lib/setup-checklist'

const COOKIE_OPTIONS = {
  path: '/app',
  httpOnly: true,
  sameSite: 'lax',
  secure: process.env.NODE_ENV === 'production',
} as const

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
  store.set(setupHiddenCookie(centerId), '1', { ...COOKIE_OPTIONS, maxAge: 60 * 60 * 24 * 365 })
  revalidatePath('/app')
}


/**
 * «Показать» в строке скрытой плашки — снять cookie, плашка возвращается целиком.
 * Перезапись с теми же атрибутами и maxAge 0 — браузер гарантированно затрёт
 * тот же cookie. Плашка проверяет значение, а не наличие: в перерисовке этого
 * же запроса снятый cookie ещё виден с пустым значением (e2e signup, #221).
 */
export async function showSetupChecklist(): Promise<void> {
  const centerId = await currentCenterId()
  if (!centerId) return

  const store = await cookies()
  store.set(setupHiddenCookie(centerId), '', { ...COOKIE_OPTIONS, maxAge: 0 })
  revalidatePath('/app')
}

async function currentCenterId(): Promise<string | undefined> {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  return (user?.app_metadata as { center_id?: string } | undefined)?.center_id
}
