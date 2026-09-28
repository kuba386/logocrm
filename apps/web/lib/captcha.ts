/**
 * Токен капчи из формы (поле `captcha_token`, его кладёт TurnstileField) в
 * виде, который принимает Supabase Auth. Пустой токен — не передаём вовсе:
 * там, где капча выключена (staging, локально), поле отсутствует.
 */
export function captchaOptions(formData: FormData): { captchaToken?: string } {
  const token = String(formData.get('captcha_token') ?? '').trim()
  return token ? { captchaToken: token } : {}
}
