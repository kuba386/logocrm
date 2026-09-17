'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'

export type TelegramState = { message?: string; notice?: string; code?: string }

/** Код одноразовый и живёт 15 минут; выдача нового гасит предыдущий (0033). */
export async function issueLinkCode(): Promise<TelegramState> {
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('create_telegram_link_code')
  if (error) return toAppError(error, t('integrations', 'codeFailed'))

  revalidatePath('/app/telegram')
  return { code: data ?? undefined }
}

export async function unlinkTelegram(): Promise<TelegramState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('unlink_telegram')
  if (error) return toAppError(error, t('integrations', 'unlinkFailed'))

  revalidatePath('/app/telegram')
  return { notice: t('integrations', 'unlinked') }
}
