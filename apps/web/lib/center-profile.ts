import { cache } from 'react'
import { isCenterKind, type CenterKind } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'

export type CenterProfile = {
  kind: CenterKind
  /** Включённые модули центра (0104): clinic — «Клиника», academic — «Учёба». */
  modules: ReadonlySet<string>
}

/**
 * Тип и модули текущего центра (0104, ADR-013) — один запрос на рендер:
 * cache() делит результат между layout и страницами. Это косметика
 * видимости: запись в выключенный модуль запрещает база (a01_module_guard),
 * чтение специалистом и родителем — restrictive-политики.
 */
export const getCenterProfile = cache(async (): Promise<CenterProfile> => {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  const centerId = (user?.app_metadata as { center_id?: string } | undefined)?.center_id ?? null
  if (!centerId) return { kind: 'speech', modules: new Set() }

  const [{ data: center }, { data: modules }] = await Promise.all([
    supabase.from('centers').select('kind').eq('id', centerId).maybeSingle(),
    // Без eq по center_id: политика сама сужает до current_center() из JWT —
    // после switch_center до обновления токена app_metadata и JWT расходятся.
    supabase.from('center_modules').select('module_code').is('disabled_at', null),
  ])

  return {
    kind: isCenterKind(center?.kind) ? center.kind : 'speech',
    modules: new Set((modules ?? []).map((row) => row.module_code)),
  }
})

export function hasClinic(profile: CenterProfile): boolean {
  return profile.modules.has('clinic')
}
