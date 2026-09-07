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

// --- Этап 2: ученики и плательщики -------------------------------------------

/** Кем плательщик приходится ребёнку. Список совпадает с check-constraint. */
export const payerRelationSchema = z.enum(['мама', 'папа', 'бабушка', 'дедушка', 'опекун', 'другое'])
export type PayerRelation = z.infer<typeof payerRelationSchema>

export const studentStatusSchema = z.enum(['lead', 'active', 'paused', 'archived'])
export type StudentStatus = z.infer<typeof studentStatusSchema>

export const genderSchema = z.enum(['м', 'ж'])

/**
 * Телефон проверяем той же логикой, что и БД (normalize_kg_phone).
 * Схема лежит в contracts, а не в core, чтобы не тянуть зависимость —
 * поэтому регулярка здесь дублирует нормализацию из @logocrm/core.
 */
const kgPhoneSchema = z
  .string()
  .trim()
  .refine(
    (value) => {
      const digits = value.replace(/\D/g, '')
      return (
        (digits.length === 12 && digits.startsWith('996')) ||
        (digits.length === 10 && digits.startsWith('0')) ||
        digits.length === 9
      )
    },
    { message: 'Номер должен быть кыргызским: +996 и девять цифр' },
  )

export const createPayerSchema = z.object({
  fullName: z.string().trim().min(2, 'Укажите ФИО плательщика').max(120, 'Слишком длинное ФИО'),
  phone: kgPhoneSchema,
  phoneAlt: kgPhoneSchema.optional().or(z.literal('')),
  email: z.string().trim().email('Некорректный email').optional().or(z.literal('')),
  relation: payerRelationSchema.optional(),
  notes: z.string().trim().max(2000).optional().or(z.literal('')),
})
export type CreatePayerInput = z.infer<typeof createPayerSchema>

/** Плательщик у ребёнка либо уже существует, либо создаётся вместе с ним. */
export const studentPayerSchema = z.union([
  z.object({ existingId: z.string().uuid('Некорректный плательщик') }),
  z.object({
    fullName: z.string().trim().min(2, 'Укажите ФИО плательщика'),
    phone: kgPhoneSchema,
    relation: payerRelationSchema.optional(),
  }),
])
export type StudentPayerInput = z.infer<typeof studentPayerSchema>

export const createStudentSchema = z.object({
  fullName: z.string().trim().min(2, 'Укажите ФИО ребёнка').max(120, 'Слишком длинное ФИО'),
  birthDate: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/, 'Дата в формате ГГГГ-ММ-ДД')
    .refine((value) => new Date(value) <= new Date(), 'Дата рождения в будущем')
    .optional()
    .or(z.literal('')),
  gender: genderSchema.optional(),
  payer: studentPayerSchema,
  primaryTeacherId: z.string().uuid('Некорректный специалист').optional(),
  source: z.string().trim().max(120).optional().or(z.literal('')),
  notes: z.string().trim().max(2000).optional().or(z.literal('')),
})
export type CreateStudentInput = z.infer<typeof createStudentSchema>

export const updateStudentSchema = z.object({
  id: z.string().uuid(),
  fullName: z.string().trim().min(2, 'Укажите ФИО ребёнка').max(120).optional(),
  birthDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Дата в формате ГГГГ-ММ-ДД').optional().or(z.literal('')),
  gender: genderSchema.optional(),
  primaryTeacherId: z.string().uuid().optional().or(z.literal('')),
  status: studentStatusSchema.optional(),
  source: z.string().trim().max(120).optional().or(z.literal('')),
  notes: z.string().trim().max(2000).optional().or(z.literal('')),
})
export type UpdateStudentInput = z.infer<typeof updateStudentSchema>

export const findPayerByPhoneSchema = z.object({ phone: kgPhoneSchema })
export type FindPayerByPhoneInput = z.infer<typeof findPayerByPhoneSchema>
