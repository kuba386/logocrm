'use server'

import { cookies } from 'next/headers'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { acceptInvitationSchema, magicLinkSchema, signInSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { siteUrl } from '@/lib/env'
import { INVITE_COOKIE } from '@/lib/invite'
import { invitationErrorMessage } from '@/lib/errors'
import { captchaOptions } from '@/lib/captcha'
import { authErrorMessage } from '@/lib/errors'

export type InviteState = { error?: string; notice?: string }

/**
 * Токен кладём в httpOnly-куку: после magic link пользователь возвращается на
 * /auth/callback уже без исходного URL, и взять токен больше неоткуда.
 */
async function rememberToken(token: string): Promise<void> {
  const store = await cookies()
  store.set(INVITE_COOKIE, token, {
    httpOnly: true,
    sameSite: 'lax',
    secure: process.env.NODE_ENV === 'production',
    maxAge: 60 * 60,
    path: '/',
  })
}

/** Принимает приглашение и переключает сессию на центр. */
export async function acceptInvitation(token: string): Promise<{ error?: string }> {
  const parsed = acceptInvitationSchema.safeParse({ token })
  if (!parsed.success) {
    return { error: 'Некорректная ссылка приглашения' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('accept_invitation', { p_token: parsed.data.token })

  if (error) {
    return { error: invitationErrorMessage(error) }
  }

  // accept_invitation вызвал switch_center — в текущем JWT центра ещё нет.
  const { error: refreshError } = await supabase.auth.refreshSession()
  if (refreshError) {
    return { error: 'Приглашение принято, но сессию не удалось обновить. Войдите заново.' }
  }

  const store = await cookies()
  store.delete(INVITE_COOKIE)

  return {}
}

/**
 * Уже вошедший пользователь принимает приглашение одной кнопкой. Нужен,
 * когда подтверждение почты открылось в другом браузере (кука с токеном и
 * ключ PKCE остались в первом): человек входит паролем и возвращается по
 * ссылке приглашения — без этого страница снова просила зарегистрироваться.
 */
export async function acceptSignedIn(_prev: InviteState, formData: FormData): Promise<InviteState> {
  const token = String(formData.get('token') ?? '')
  const accepted = await acceptInvitation(token)
  if (accepted.error) {
    return { error: accepted.error }
  }
  revalidatePath('/', 'layout')
  redirect('/app')
}

export async function signInAndAccept(_prev: InviteState, formData: FormData): Promise<InviteState> {
  const token = String(formData.get('token') ?? '')
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

  const accepted = await acceptInvitation(token)
  if (accepted.error) {
    return { error: accepted.error }
  }

  revalidatePath('/', 'layout')
  redirect('/app')
}

export async function signUpAndAccept(_prev: InviteState, formData: FormData): Promise<InviteState> {
  const token = String(formData.get('token') ?? '')
  const parsed = signInSchema.safeParse({
    email: String(formData.get('email') ?? ''),
    password: String(formData.get('password') ?? ''),
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте введённые данные' }
  }

  await rememberToken(token)

  const supabase = await createClient()
  const { data, error } = await supabase.auth.signUp({
    ...parsed.data,
    options: { emailRedirectTo: `${siteUrl()}/auth/callback`, ...captchaOptions(formData) },
  })

  if (error) {
    return { error: authErrorMessage(error, 'Не удалось зарегистрироваться. Возможно, такой email уже занят.') }
  }

  // Почта уже есть — Supabase молчит и письма не шлёт; ведём к входу, где
  // для вошедшего есть «Принять приглашение».
  if (data.user && data.user.identities?.length === 0) {
    return {
      error:
        'Этот email уже зарегистрирован. Выберите «Войти» ниже — после входа приглашение примется сразу. Не помните пароль — «Войти по ссылке из письма».',
    }
  }

  // Если подтверждение почты выключено, сессия появляется сразу —
  // тогда принимаем приглашение здесь же.
  if (data.session) {
    const accepted = await acceptInvitation(token)
    if (accepted.error) {
      return { error: accepted.error }
    }
    revalidatePath('/', 'layout')
    redirect('/app')
  }

  return {
    notice:
      'Мы отправили письмо для подтверждения. Откройте его на этом же устройстве и в этом же браузере. Если ссылка открылась в другом — войдите с паролем и снова откройте ссылку приглашения: там будет кнопка «Принять».',
  }
}

export async function magicLinkAndAccept(_prev: InviteState, formData: FormData): Promise<InviteState> {
  const token = String(formData.get('token') ?? '')
  const parsed = magicLinkSchema.safeParse({ email: String(formData.get('email') ?? '') })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте email' }
  }

  await rememberToken(token)

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
