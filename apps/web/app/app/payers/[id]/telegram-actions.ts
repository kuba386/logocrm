'use server'

import QRCode from 'qrcode'
import { revalidatePath } from 'next/cache'
import { z } from 'zod'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'

export type PayerTelegramState = {
  message?: string
  notice?: string
  link?: { url: string; expiresAt: string; qrSvg: string }
}

const uuid = z.string().uuid()

/**
 * Личная ссылка на бота для родителя (0098). Код приходит из базы один раз —
 * в таблице только его хеш, поэтому ссылка и QR собираются здесь и больше
 * нигде не показываются. Имя бота — настройка окружения, не данные центра.
 */
export async function createPayerTelegramLink(payerId: string): Promise<PayerTelegramState> {
  const parsed = uuid.safeParse(payerId)
  if (!parsed.success) return { message: t('payerTelegram', 'createFailed') }

  const botName = process.env.NEXT_PUBLIC_TELEGRAM_BOT
  if (!botName) return { message: t('payerTelegram', 'botMissing') }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('create_payer_telegram_link', { p_payer_id: parsed.data })
  if (error) return toAppError(error, t('payerTelegram', 'createFailed'))

  const row = data?.[0]
  if (!row) return { message: t('payerTelegram', 'createFailed') }

  const url = `https://t.me/${botName}?start=p_${row.code}`
  const qrSvg = await QRCode.toString(url, { type: 'svg', margin: 1, errorCorrectionLevel: 'M' })

  revalidatePath(`/app/payers/${parsed.data}`)
  return { link: { url, expiresAt: row.expires_at, qrSvg } }
}

/** Отключить родителя от центра — то же действие, что в «Сотрудниках» (revoke_membership). */
export async function disconnectParent(payerId: string, userId: string): Promise<PayerTelegramState> {
  const parsedPayer = uuid.safeParse(payerId)
  const parsedUser = uuid.safeParse(userId)
  if (!parsedPayer.success || !parsedUser.success) return { message: t('payerTelegram', 'disconnectFailed') }

  const supabase = await createClient()
  const { error } = await supabase.rpc('revoke_membership', { p_user_id: parsedUser.data })
  if (error) return toAppError(error, t('payerTelegram', 'disconnectFailed'))

  revalidatePath(`/app/payers/${parsedPayer.data}`)
  return { notice: t('payerTelegram', 'disconnected') }
}
