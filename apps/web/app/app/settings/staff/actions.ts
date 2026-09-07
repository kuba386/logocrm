'use server'

import { revalidatePath } from 'next/cache'
import {
  changeMemberRoleSchema,
  createInvitationSchema,
  revokeMembershipSchema,
} from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
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
  })

  if (error) {
    return { error: error.message || 'Не удалось создать приглашение' }
  }

  const token = data?.[0]?.token
  if (!token) {
    return { error: 'Приглашение создано, но ссылку получить не удалось. Обновите страницу.' }
  }

  revalidatePath('/app/settings/staff')
  return { notice: 'Приглашение создано', inviteUrl: `${siteUrl()}/invite/${token}` }
}

export async function revokeMembership(_prev: StaffState, formData: FormData): Promise<StaffState> {
  const parsed = revokeMembershipSchema.safeParse({ userId: String(formData.get('userId') ?? '') })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Некорректный пользователь' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('revoke_membership', { p_user_id: parsed.data.userId })

  if (error) {
    return { error: error.message || 'Не удалось отключить доступ' }
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
    return { error: error.message || 'Не удалось изменить роль' }
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
    return { error: error.message || 'Не удалось отменить приглашение' }
  }

  revalidatePath('/app/settings/staff')
  return { notice: 'Приглашение отменено' }
}
