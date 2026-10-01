'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { magicLinkSchema, signInSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { siteUrl } from '@/lib/env'
import { captchaOptions } from '@/lib/captcha'
import { authErrorMessage } from '@/lib/errors'

export type AuthState = { error?: string; notice?: string }

/** Вход по email и паролю. */
export async function signIn(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const parsed = signInSchema.safeParse({
    email: String(formData.get('email') ?? ''),
    password: String(formData.get('password') ?? ''),
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте введённые данные' }
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithPassword({
    ...parsed.data,
    options: captchaOptions(formData),
  })

  if (error) {
    return { error: authErrorMessage(error, 'Неверный email или пароль') }
  }

  revalidatePath('/', 'layout')
  redirect(String(formData.get('next') || '/app'))
}

/** Регистрация по email и паролю. */
export async function signUp(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const parsed = signInSchema.safeParse({
    email: String(formData.get('email') ?? ''),
    password: String(formData.get('password') ?? ''),
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте введённые данные' }
  }

  const supabase = await createClient()
  const { data, error } = await supabase.auth.signUp({
    ...parsed.data,
    options: { emailRedirectTo: `${siteUrl()}/auth/callback`, ...captchaOptions(formData) },
  })

  if (error) {
    return { error: authErrorMessage(error, 'Не удалось зарегистрироваться. Возможно, такой email уже занят.') }
  }

  // На prod почта подтверждается (ADR-004): сессии ещё нет, и редирект в
  // /onboarding молча возвращал человека на вход без слова о письме.
  if (!data.session) {
    return {
      notice: `Мы отправили письмо на ${parsed.data.email}. Откройте его и нажмите ссылку — после этого центр можно будет создать. Письма нет 5 минут — проверьте «Спам». Если запросите письмо ещё раз, открывайте только последнее.`,
    }
  }

  revalidatePath('/', 'layout')
  redirect('/onboarding')
}

/** Вход по одноразовой ссылке (magic link). */
export async function sendMagicLink(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const parsed = magicLinkSchema.safeParse({ email: String(formData.get('email') ?? '') })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте email' }
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithOtp({
    email: parsed.data.email,
    options: { emailRedirectTo: `${siteUrl()}/auth/callback`, ...captchaOptions(formData) },
  })

  if (error) {
    return { error: authErrorMessage(error, 'Не удалось отправить ссылку. Попробуйте позже.') }
  }

  return { notice: `Ссылка для входа отправлена на ${parsed.data.email}. Проверьте почту.` }
}

/** Выход из аккаунта. */
export async function signOut(): Promise<void> {
  const supabase = await createClient()
  await supabase.auth.signOut()
  revalidatePath('/', 'layout')
  redirect('/login')
}
