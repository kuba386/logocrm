'use server'

import { revalidatePath } from 'next/cache'
import {
  changeMemberRoleSchema,
  createInvitationSchema,
  linkParentPayerSchema,
  revokeMembershipSchema,
} from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { siteUrl } from '@/lib/env'

export type StaffState = { error?: string; notice?: string; inviteUrl?: string }

/** Пустая строка из формы — это «не заполнено», а не значение. */
function optional(formData: FormData, key: string): string | undefined {
  const value = String(formData.get(key) ?? '').trim()
  return value === '' ? undefined : value
}

export async function createInvitation(_prev: StaffState, formData: FormData): Promise<StaffState> {
  const parsed = createInvitationSchema.safeParse({
    role: String(formData.get('role') ?? ''),
    fullName: optional(formData, 'fullName'),
    phone: optional(formData, 'phone'),
    email: optional(formData, 'email'),
    teacherId: optional(formData, 'teacherId'),
    payerId: optional(formData, 'payerId'),
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте введённые данные' }
  }

  const supabase = await createClient()

  const { data, error } = await supabase.rpc('create_invitation', {
    p_role: parsed.data.role,
    p_full_name: parsed.data.fullName,
    p_phone: parsed.data.phone,
    p_email: parsed.data.email,
    p_teacher_id: parsed.data.teacherId,
    p_payer_id: parsed.data.payerId,
  })

  // Ошибки — через общий разбор (CLAUDE.md): «телефон уже есть», «карточка
  // не найдена» и гонка на уникальном индексе приходят одним русским текстом.
  if (error) {
    return { error: toAppError(error, 'Не удалось создать приглашение').message }
  }

  const row = data?.[0]
  if (!row?.token) {
    return { error: 'Приглашение создано, но ссылку получить не удалось. Обновите страницу.' }
  }

  revalidatePath('/app/settings/staff')
  // Текст — по ответу базы, не по тому, что было в селекте: карточку могли
  // архивировать, пока форма была открыта.
  const notice = row.payer_created
    ? 'Приглашение создано. Заведена новая карточка плательщика без детей — привяжите к ней ребёнка на карточке ученика, иначе родитель ничего не увидит.'
    : 'Приглашение создано'
  return { notice, inviteUrl: `${siteUrl()}/invite/${row.token}` }
}

/** 0060: привязать «ничьего» родителя к карточке или исправить привязку; пустой payerId — отвязать. */
export async function linkParentPayer(_prev: StaffState, formData: FormData): Promise<StaffState> {
  const parsed = linkParentPayerSchema.safeParse({
    userId: String(formData.get('userId') ?? ''),
    payerId: optional(formData, 'payerId') ?? null,
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте введённые данные' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('link_parent_payer', {
    p_user_id: parsed.data.userId,
    p_payer_id: parsed.data.payerId ?? undefined,
  })

  if (error) {
    return { error: toAppError(error, 'Не удалось привязать плательщика').message }
  }

  revalidatePath('/app/settings/staff')
  return { notice: parsed.data.payerId ? 'Плательщик привязан' : 'Плательщик отвязан' }
}

export async function revokeMembership(_prev: StaffState, formData: FormData): Promise<StaffState> {
  const parsed = revokeMembershipSchema.safeParse({ userId: String(formData.get('userId') ?? '') })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Некорректный пользователь' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('revoke_membership', { p_user_id: parsed.data.userId })

  if (error) {
    return { error: toAppError(error, 'Не удалось отключить доступ').message }
  }

  revalidatePath('/app/settings/staff')
  return { notice: 'Доступ отключён' }
}

export async function changeMemberRole(_prev: StaffState, formData: FormData): Promise<StaffState> {
  const parsed = changeMemberRoleSchema.safeParse({
    userId: String(formData.get('userId') ?? ''),
    role: String(formData.get('role') ?? ''),
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Некорректная роль' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('change_member_role', {
    p_user_id: parsed.data.userId,
    p_role: parsed.data.role,
  })

  if (error) {
    return { error: toAppError(error, 'Не удалось изменить роль').message }
  }

  revalidatePath('/app/settings/staff')
  return { notice: 'Роль изменена' }
}

/**
 * Отмена приглашения — это истечение срока, а не удаление: строка остаётся
 * в аудите, а из pending_invitations_view пропадает.
 */
export async function cancelInvitation(_prev: StaffState, formData: FormData): Promise<StaffState> {
  const id = String(formData.get('invitationId') ?? '')
  if (!id) return { error: 'Приглашение не найдено' }

  const supabase = await createClient()
  const { error } = await supabase
    .from('invitations')
    .update({ expires_at: new Date().toISOString() })
    .eq('id', id)

  if (error) {
    return { error: toAppError(error, 'Не удалось отменить приглашение').message }
  }

  revalidatePath('/app/settings/staff')
  return { notice: 'Приглашение отменено' }
}
