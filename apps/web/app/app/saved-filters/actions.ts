'use server'

import { revalidatePath } from 'next/cache'
import { savedFilterParamsOk, type SavedFilterPage } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'

export type SavedFilterState = { message?: string; notice?: string }

const PATHS: Record<SavedFilterPage, string> = { schedule: '/app/schedule', debts: '/app/debts' }

function pageOf(formData: FormData): SavedFilterPage | null {
  const page = String(formData.get('page') ?? '')
  return page === 'schedule' || page === 'debts' ? page : null
}

/**
 * Сохранить текущий набор под именем. Права и допустимость значений решает
 * save_filter (0094); здесь — только разбор формы. Повтор имени перезаписывает.
 */
export async function saveFilter(_prev: SavedFilterState, formData: FormData): Promise<SavedFilterState> {
  const page = pageOf(formData)
  if (!page) return { message: t('savedFilters', 'saveFailed') }

  let params: unknown
  try {
    params = JSON.parse(String(formData.get('params') ?? '{}'))
  } catch {
    return { message: t('savedFilters', 'saveFailed') }
  }
  // Зеркало CHECK: не гоняем в базу то, что она отвергнет, — и не шлём мусор.
  if (!savedFilterParamsOk(page, params)) return { message: t('savedFilters', 'saveFailed') }

  const supabase = await createClient()
  const { error } = await supabase.rpc('save_filter', {
    p_page: page,
    p_name: String(formData.get('name') ?? ''),
    p_params: params as Record<string, string>,
  })
  if (error) return { message: toAppError(error, t('savedFilters', 'saveFailed')).message }

  revalidatePath(PATHS[page])
  return { notice: t('savedFilters', 'saved') }
}

export async function archiveSavedFilter(_prev: SavedFilterState, formData: FormData): Promise<SavedFilterState> {
  const page = pageOf(formData)
  const id = String(formData.get('id') ?? '')
  if (!page || !id) return { message: t('savedFilters', 'removeFailed') }

  const supabase = await createClient()
  const { error } = await supabase.rpc('archive_saved_filter', { p_id: id })
  if (error) return { message: toAppError(error, t('savedFilters', 'removeFailed')).message }

  revalidatePath(PATHS[page])
  return {}
}
