import { z } from 'zod'

/** Входные DTO для server actions и RPC. Все сообщения об ошибках — по-русски. */

/** Совпадает с memberships_role_check (0001, расширен в 0026: registrar, finance). */
export const roleSchema = z.enum(['owner', 'admin', 'teacher', 'parent', 'registrar', 'finance'])
export type Role = z.infer<typeof roleSchema>

// Коды тарифов — зеркало справочника public.plans (0049); 'ai' заменён на 'center'.
export const planSchema = z.enum(['trial', 'solo', 'studio', 'center'])
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

/** Роли, которые можно выдать через приглашение (invitations_role_check, 0026/0028). Владельца пригласить нельзя. */
export const invitableRoleSchema = z.enum(['admin', 'teacher', 'parent', 'registrar', 'finance'])
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

export const studentStatusSchema = z.enum(['active', 'paused', 'archived'])
export type StudentStatus = z.infer<typeof studentStatusSchema>

/** Семь шагов воронки (0055) — совпадает с funnel_stages.code в базе. */
export const funnelStageSchema = z.enum([
  'lead', 'contacted', 'consultation', 'assessment', 'trial', 'active', 'completed',
])
export type FunnelStage = z.infer<typeof funnelStageSchema>

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

// --- Этап 5: продажа абонемента с оплатой и рассрочкой ---------------------------

const isoDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Дата в формате ГГГГ-ММ-ДД')

/**
 * Вход sell_subscription_paid (0023/0029). Суммы — integer в тыйынах, как в
 * базе. Форма считает только ожидаемый остаток (цена − внесено) для сверки
 * с сервером — деньги в браузере не считаются, график строит RPC.
 */
export const sellSubscriptionPaidSchema = z
  .object({
    studentId: z.string().uuid('Некорректный ученик'),
    typeId: z.string().uuid('Выберите тип абонемента'),
    /** Ключ идемпотентности: форма генерирует при открытии, повтор с тем же ключом сервер отбивает. */
    saleKey: z.string().uuid('Обновите страницу и повторите продажу'),
    priceTiyin: z.number().int().min(0, 'Цена не может быть отрицательной').optional(),
    startsAt: isoDateSchema.optional(),
    paidTiyin: z.number().int('Сумма — в сомах, до тыйына').min(0, 'Внесённая сумма не может быть отрицательной'),
    sourceId: z.string().uuid('Укажите источник оплаты').optional(),
    paidOn: isoDateSchema.optional(),
    installments: z
      .number()
      .int('Число платежей — целое')
      .min(1, 'Число платежей — от 1')
      .max(24, 'Число платежей — не больше 24')
      .optional(),
    firstDue: isoDateSchema.optional(),
    stepMonths: z.number().int().min(1, 'Шаг рассрочки — от одного месяца').max(12, 'Шаг рассрочки — не больше года').default(1),
    expectedRemainingTiyin: z.number().int().min(0, 'Остаток не может быть отрицательным'),
  })
  .refine((input) => input.paidTiyin === 0 || Boolean(input.sourceId), {
    message: 'Укажите источник оплаты',
    path: ['sourceId'],
  })
  .refine((input) => input.installments === undefined || input.expectedRemainingTiyin > 0, {
    message: 'Абонемент оплачен целиком — рассрочка не нужна',
    path: ['installments'],
  })
  .refine((input) => input.installments === undefined || input.installments <= input.expectedRemainingTiyin, {
    message: 'Платежей больше, чем тыйынов в остатке',
    path: ['installments'],
  })
export type SellSubscriptionPaidInput = z.infer<typeof sellSubscriptionPaidSchema>

// --- Этап 5: /app/finance ------------------------------------------------------------

/** Совпадает с payments_kind_known (0014). Знак — payments_sign_matches_kind: payment > 0, refund < 0. */
export const paymentKindSchema = z.enum(['payment', 'refund', 'correction'])
export type PaymentKind = z.infer<typeof paymentKindSchema>

/** Совпадает с expenses_kind_known (0016): expense > 0, refund < 0 («вернули из расхода»). */
export const expenseKindSchema = z.enum(['expense', 'refund', 'correction'])
export type ExpenseKind = z.infer<typeof expenseKindSchema>

const commentSchema = z.string().trim().max(500, 'Комментарий — не длиннее 500 символов').optional().or(z.literal(''))

/**
 * record_payment без привязки к абонементу (0029): платёж к абонементу
 * проводится с карточки ученика (продажа, рассрочка). amountTiyin — уже со
 * знаком: форма вводит модуль, server action ставит знак по виду.
 */
export const recordPaymentSchema = z
  .object({
    payerId: z.string().uuid('Выберите плательщика'),
    studentId: z.string().uuid('Некорректный ученик').optional(),
    kind: paymentKindSchema,
    amountTiyin: z.number().int('Сумма — в сомах, до тыйына').refine((v) => v !== 0, 'Сумма не может быть нулём'),
    sourceId: z.string().uuid('Укажите источник оплаты').optional(),
    paidOn: isoDateSchema,
    comment: commentSchema,
  })
  .refine((i) => i.kind !== 'payment' || i.amountTiyin > 0, { message: 'Платёж — положительная сумма', path: ['amountTiyin'] })
  .refine((i) => i.kind !== 'refund' || i.amountTiyin < 0, { message: 'Возврат — отрицательная сумма', path: ['amountTiyin'] })
  .refine((i) => i.kind === 'correction' || Boolean(i.sourceId), { message: 'Укажите источник оплаты', path: ['sourceId'] })
export type RecordPaymentInput = z.infer<typeof recordPaymentSchema>

export const recordExpenseSchema = z
  .object({
    categoryId: z.string().uuid('Выберите статью расхода'),
    kind: expenseKindSchema,
    amountTiyin: z.number().int('Сумма — в сомах, до тыйына').refine((v) => v !== 0, 'Сумма не может быть нулём'),
    sourceId: z.string().uuid('Некорректный источник').optional(),
    paidOn: isoDateSchema,
    comment: commentSchema,
  })
  .refine((i) => i.kind !== 'expense' || i.amountTiyin > 0, { message: 'Расход — положительная сумма', path: ['amountTiyin'] })
  .refine((i) => i.kind !== 'refund' || i.amountTiyin < 0, { message: 'Возврат из расхода — отрицательная сумма', path: ['amountTiyin'] })
export type RecordExpenseInput = z.infer<typeof recordExpenseSchema>

export const payInstallmentSchema = z.object({
  installmentId: z.string().uuid('Некорректный платёж рассрочки'),
  sourceId: z.string().uuid('Укажите источник оплаты'),
  comment: commentSchema,
})
export type PayInstallmentInput = z.infer<typeof payInstallmentSchema>

/** Первое число месяца — как salary_runs_month_is_first_of_month и close_month. */
export const monthSchema = z.object({
  month: z.string().regex(/^\d{4}-\d{2}-01$/, 'Месяц — первое число, ГГГГ-ММ-01'),
})
export type MonthInput = z.infer<typeof monthSchema>

// --- Этап 5: /app/salary --------------------------------------------------------------

export const teacherMonthSchema = monthSchema.extend({
  teacherId: z.string().uuid('Некорректный специалист'),
})
export type TeacherMonthInput = z.infer<typeof teacherMonthSchema>

/** record_salary_adjustment: бонус (+) или штраф (−), ноль запрещён констрейнтом. */
export const salaryAdjustmentSchema = teacherMonthSchema.extend({
  amountTiyin: z.number().int('Сумма — в сомах, до тыйына').refine((v) => v !== 0, 'Сумма не может быть нулём'),
  reason: z.string().trim().min(2, 'Укажите причину').max(200, 'Причина — не длиннее 200 символов'),
})
export type SalaryAdjustmentInput = z.infer<typeof salaryAdjustmentSchema>

/** Совпадает с teacher_rates_model_known (0017). */
export const rateModelSchema = z.enum(['per_lesson', 'per_hour', 'percent_payment', 'per_student'])
export type RateModel = z.infer<typeof rateModelSchema>

/**
 * Прямой insert в teacher_rates (RPC нет, 0017): value — тыйыны для
 * per_lesson/per_hour/per_student, проценты × 100 для percent_payment
 * (3000 = 30.00%, teacher_rates_percent_bounded ≤ 10000).
 */
export const teacherRateSchema = z
  .object({
    teacherId: z.string().uuid('Выберите специалиста'),
    serviceId: z.string().uuid('Некорректная услуга').optional(),
    model: rateModelSchema,
    value: z.number().int('Значение — целое в тыйынах или сотых процента').min(0, 'Ставка не может быть отрицательной'),
    validFrom: isoDateSchema,
  })
  .refine((i) => i.model !== 'percent_payment' || i.value <= 10000, {
    message: 'Процент — не больше 100',
    path: ['value'],
  })
export type TeacherRateInput = z.infer<typeof teacherRateSchema>
