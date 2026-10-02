import 'server-only'
import { emailCodeSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { siteUrl } from '@/lib/env'
import { captchaOptions } from '@/lib/captcha'
import { authErrorMessage } from '@/lib/errors'

/**
 * Подтверждение почты кодом из письма вместо ссылки.
 *
 * Ссылка из письма работает только в том браузере, где начали вход (PKCE):
 * человек открывает приглашение в WhatsApp, а письмо — в приложении Gmail,
 * и ссылка «не срабатывает». Код вводится на той же странице, где начали,
 * поэтому неважно, где открыто письмо. Ссылка в письме остаётся запасным
 * путём для тех, кто открыл его в том же браузере.
 *
 * Код приходит, только если шаблоны писем Supabase («Confirm signup»,
 * «Magic link») содержат {{ .Token }} — docs/Decisions, ADR-004.
 */
export type CodePurpose = 'signup' | 'magic'

/** Поля состояния формы, по которым она переключается на шаг «Введите код». */
export type CodeStep = { codeSentTo?: string; codePurpose?: CodePurpose }

export function codePurpose(value: FormDataEntryValue | null): CodePurpose {
  return value === 'magic' ? 'magic' : 'signup'
}

/** Проверяет код; при успехе сессия уже в cookie (серверный клиент их пишет). */
export async function verifyEmailCode(formData: FormData): Promise<{ error?: string }> {
  const parsed = emailCodeSchema.safeParse({
    email: String(formData.get('email') ?? ''),
    code: String(formData.get('code') ?? ''),
  })
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте код' }
  }

  const supabase = await createClient()
  // type 'email' — и для подтверждения регистрации, и для входа по коду:
  // 'signup' и 'magiclink' в supabase-js помечены устаревшими.
  const { error } = await supabase.auth.verifyOtp({
    email: parsed.data.email,
    token: parsed.data.code,
    type: 'email',
  })
  if (error) {
    return { error: authErrorMessage(error, 'Код не подошёл. Проверьте цифры или запросите новый код.') }
  }
  return {}
}

/** Новое письмо с кодом: регистрации — повтор подтверждения, входу — новый код. */
export async function resendEmailCode(formData: FormData): Promise<{ error?: string; email?: string }> {
  const email = String(formData.get('email') ?? '').trim()
  if (!email) return { error: 'Укажите email' }

  const supabase = await createClient()
  const options = { emailRedirectTo: `${siteUrl()}/auth/callback`, ...captchaOptions(formData) }
  const { error } =
    codePurpose(formData.get('purpose')) === 'signup'
      ? await supabase.auth.resend({ type: 'signup', email, options })
      : await supabase.auth.signInWithOtp({ email, options })

  if (error) {
    return { error: authErrorMessage(error, 'Не удалось отправить код. Попробуйте через минуту.') }
  }
  return { email }
}
