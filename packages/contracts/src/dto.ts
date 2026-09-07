import { z } from 'zod'

/** Входные DTO для server actions и RPC. Все сообщения об ошибках — по-русски. */

export const roleSchema = z.enum(['owner', 'admin', 'teacher', 'parent'])
export type Role = z.infer<typeof roleSchema>

export const planSchema = z.enum(['trial', 'solo', 'studio', 'ai'])
export type Plan = z.infer<typeof planSchema>

export const signInSchema = z.object({
  email: z.string().min(1, 'Укажите email').email('Некорректный email'),
  password: z.string().min(6, 'Пароль не короче 6 символов'),
})
export type SignInInput = z.infer<typeof signInSchema>

export const magicLinkSchema = z.object({
  email: z.string().min(1, 'Укажите email').email('Некорректный email'),
})
export type MagicLinkInput = z.infer<typeof magicLinkSchema>

export const createCenterSchema = z.object({
  name: z.string().trim().min(2, 'Название не короче 2 символов').max(120, 'Слишком длинное название'),
  city: z.string().trim().min(2, 'Укажите город').max(80, 'Слишком длинное название города'),
})
export type CreateCenterInput = z.infer<typeof createCenterSchema>

export const switchCenterSchema = z.object({
  centerId: z.string().uuid('Некорректный идентификатор центра'),
})
export type SwitchCenterInput = z.infer<typeof switchCenterSchema>

/** Роли, которые можно выдать через приглашение. Владельца пригласить нельзя. */
export const invitableRoleSchema = z.enum(['admin', 'teacher', 'parent'])
export type InvitableRole = z.infer<typeof invitableRoleSchema>

export const createInvitationSchema = z
  .object({
    role: invitableRoleSchema,
    fullName: z.string().trim().max(120, 'Слишком длинное ФИО').optional(),
    phone: z
      .string()
      .trim()
      .regex(/^\+?[0-9\s()-]{9,20}$/, 'Некорректный номер телефона')
      .optional()
      .or(z.literal('')),
    email: z.string().trim().email('Некорректный email').optional().or(z.literal('')),
    teacherId: z.string().uuid('Некорректная карточка специалиста').optional(),
  })
  .refine(
    (input) => input.role !== 'teacher' || Boolean(input.teacherId) || Boolean(input.fullName),
    { message: 'Для специалиста укажите ФИО или выберите существующую карточку', path: ['fullName'] },
  )
export type CreateInvitationInput = z.infer<typeof createInvitationSchema>

export const revokeMembershipSchema = z.object({
  userId: z.string().uuid('Некорректный пользователь'),
})
export type RevokeMembershipInput = z.infer<typeof revokeMembershipSchema>

export const changeMemberRoleSchema = z.object({
  userId: z.string().uuid('Некорректный пользователь'),
  role: roleSchema,
})
export type ChangeMemberRoleInput = z.infer<typeof changeMemberRoleSchema>

export const acceptInvitationSchema = z.object({
  token: z.string().trim().min(16, 'Некорректная ссылка приглашения'),
})
export type AcceptInvitationInput = z.infer<typeof acceptInvitationSchema>
