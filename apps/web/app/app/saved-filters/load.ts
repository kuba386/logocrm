import type { SavedFilterPage, SavedFilterParams } from '@logocrm/core'
import { loadErrorMessage } from '@/lib/errors'
import { t } from '@/lib/messages'
import type { createClient } from '@/lib/supabase/server'

export type SavedFilterItem = { id: string; name: string; params: SavedFilterParams }

export type SavedFiltersData = {
  /** Может ли роль сохранять наборы этой страницы — решает SQL (saved_filter_pages). */
  allowed: boolean
  items: SavedFilterItem[]
  error: string | null
}

/** Наборы текущего пользователя для страницы. Чужих не вернёт RLS (0094). */
export async function loadSavedFilters(
  supabase: Awaited<ReturnType<typeof createClient>>,
  page: SavedFilterPage,
): Promise<SavedFiltersData> {
  const [{ data: pages, error: pagesError }, { data: rows, error: rowsError }] = await Promise.all([
    supabase.rpc('saved_filter_pages'),
    supabase.from('saved_filters').select('id, name, params').eq('page', page).order('name'),
  ])
  const error = pagesError ?? rowsError
  if (error) return { allowed: false, items: [], error: loadErrorMessage(error, t('savedFilters', 'loadFailed')) }
  return {
    allowed: (pages ?? []).includes(page),
    items: (rows ?? []).map((r) => ({ id: r.id, name: r.name, params: (r.params ?? {}) as SavedFilterParams })),
    error: null,
  }
}
