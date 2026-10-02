'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { magicLinkSchema, signInSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { siteUrl } from '@/lib/env'
import { captchaOptions } from '@/lib/captcha'
import { authErrorMessage } from '@/lib/errors'
import { codePurpose, resendEmailCode, verifyEmailCode, type CodeStep } from '@/lib/email-code'

export type AuthState = { error?: string; notice?: string } & CodeStep

const ALREADY_REGISTERED =
  'Этот email уже зарегистрирован. Войдите с паролем или по коду из письма, а если не помните пароль — нажмите «Забыли пароль?».'

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

  // Почта уже зарегистрирована: Supabase не сообщает об этом ошибкой (иначе
  // по форме можно перебирать адреса), а возвращает пользователя без
  // identities и письма не шлёт. Без этой проверки форма обещала письмо,
  // которое не придёт.
  if (data.user && data.user.identities?.length === 0) {
    return { error: ALREADY_REGISTERED }
  }

  // На prod почта подтверждается (ADR-004): сессии ещё нет — форма
  // переключается на ввод кода из письма (verifyCode ниже).
  if (!data.session) {
    return { codeSentTo: parsed.data.email, codePurpose: 'signup' }
  }

  revalidatePath('/', 'layout')
  redirect('/onboarding')
}

/** Вход по коду из письма (то же письмо содержит и запасную ссылку). */
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
    return { error: authErrorMessage(error, 'Не удалось отправить код. Попробуйте позже.') }
  }

  return { codeSentTo: parsed.data.email, codePurpose: 'magic' }
}

/**
 * Код из письма: регистрация ведёт в /onboarding (центра ещё нет), вход — в
 * next. Отказ возвращает тот же шаг, чтобы форма осталась на вводе кода.
 */
export async function verifyCode(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const purpose = codePurpose(formData.get('purpose'))
  const email = String(formData.get('email') ?? '')
  const { error } = await verifyEmailCode(formData)
  if (error) {
    return { error, codeSentTo: email, codePurpose: purpose }
  }

  revalidatePath('/', 'layout')
  redirect(purpose === 'signup' ? '/onboarding' : String(formData.get('next') || '/app'))
}

/** Повторное письмо с кодом. */
export async function resendCode(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const purpose = codePurpose(formData.get('purpose'))
  const email = String(formData.get('email') ?? '')
  const result = await resendEmailCode(formData)
  if (result.error) {
    return { error: result.error, codeSentTo: email, codePurpose: purpose }
  }
  return { notice: `Отправили новый код на ${email}. Вводите код из последнего письма.`, codeSentTo: email, codePurpose: purpose }
}

/** Письмо со ссылкой на смену пароля. Ссылка ведёт через /auth/callback на /reset-password. */
export async function sendPasswordReset(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const parsed = magicLinkSchema.safeParse({ email: String(formData.get('email') ?? '') })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте email' }
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.resetPasswordForEmail(parsed.data.email, {
    redirectTo: `${siteUrl()}/auth/callback?next=/reset-password`,
    ...captchaOptions(formData),
  })

  if (error) {
    return { error: authErrorMessage(error, 'Не удалось отправить письмо. Попробуйте позже.') }
  }

  // Одинаковый ответ для любого адреса — форма не подсказывает, кто зарегистрирован.
  return {
    notice: `Если ${parsed.data.email} зарегистрирован, мы отправили письмо со ссылкой для смены пароля. Откройте его в этом же браузере.`,
  }
}

/** Новый пароль после перехода по ссылке из письма (сессия уже есть). */
export async function updatePassword(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const password = String(formData.get('password') ?? '')
  const confirm = String(formData.get('confirm') ?? '')
  const parsed = signInSchema.shape.password.safeParse(password)

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте пароль' }
  }
  if (password !== confirm) {
    return { error: 'Пароли не совпадают' }
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.updateUser({ password })

  if (error) {
    return { error: authErrorMessage(error, 'Не удалось сменить пароль. Запросите новую ссылку.') }
  }

  revalidatePath('/', 'layout')
  redirect('/app')
}

/** Выход из аккаунта. */
export async function signOut(): Promise<void> {
  const supabase = await createClient()
  await supabase.auth.signOut()
  revalidatePath('/', 'layout')
  redirect('/login')
}
