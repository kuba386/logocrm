'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { magicLinkSchema, signInSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { siteUrl } from '@/lib/env'

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
  const { error } = await supabase.auth.signInWithPassword(parsed.data)

  if (error) {
    return { error: 'Неверный email или пароль' }
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
  const { error } = await supabase.auth.signUp({
    ...parsed.data,
    options: { emailRedirectTo: `${siteUrl()}/auth/callback` },
  })

  if (error) {
    return { error: 'Не удалось зарегистрироваться. Возможно, такой email уже занят.' }
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
    options: { emailRedirectTo: `${siteUrl()}/auth/callback` },
  })

  if (error) {
    return { error: 'Не удалось отправить ссылку. Попробуйте позже.' }
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
