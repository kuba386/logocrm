import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@logocrm/db'

/**
 * Куда отправить пользователя без активного центра.
 *
 * Отличаем «никогда не состоял» от «доступ отозвали»: во втором случае вести
 * человека на «Создайте свой центр» — издевательство. Признак отзыва берём из
 * outbox: события membership.revoked видны только владельцу центра, поэтому
 * читаем их security definer-функцией was_access_revoked.
 */
export async function noCenterRedirectPath(
  supabase: SupabaseClient<Database>,
): Promise<'/onboarding' | '/access-revoked'> {
  const { data } = await supabase.rpc('was_access_revoked')
  return data ? '/access-revoked' : '/onboarding'
}
