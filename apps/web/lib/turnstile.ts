import 'server-only'

/**
 * Проверка капчи Cloudflare Turnstile для публичной витрины записи (ревью SQL
 * этапа 19: лимит центра 20 заявок в час с выдуманных номеров давал отказ в
 * обслуживании всем родителям центра). Вход и регистрация проверяют капчу в
 * Supabase Auth; витрина ходит ролью public_booking мимо Auth, поэтому
 * проверяет сама.
 *
 * Включается, только когда заданы оба ключа: NEXT_PUBLIC_TURNSTILE_SITE_KEY
 * (виджет, TurnstileField) и TURNSTILE_SECRET_KEY (только сервер, Vercel). Нет
 * любого — проверка пропускается (staging, локально, e2e). Сбой сети до
 * Cloudflare — отказ, а не пропуск: иначе капчу обходили бы, роняя проверку.
 */
export async function verifyTurnstile(token: FormDataEntryValue | null): Promise<boolean> {
  const secret = process.env.TURNSTILE_SECRET_KEY
  if (!secret || !process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY) return true
  if (typeof token !== 'string' || token === '') return false

  try {
    const res = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST',
      body: new URLSearchParams({ secret, response: token }),
      cache: 'no-store',
    })
    const data = (await res.json()) as { success?: boolean }
    return data.success === true
  } catch {
    return false
  }
}
