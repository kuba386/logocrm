import { z } from 'zod'

/**
 * Контракт outbox-событий (таблица public.events).
 *
 * Как добавить событие:
 *   1. добавь схему payload ниже;
 *   2. добавь её в appEventSchema (discriminatedUnion по `type`);
 *   3. вызывай emit_event('<type>', payload) в SQL/RPC;
 *   4. допиши обработчик в воркере.
 * Событие — свершившийся факт в прошедшем времени: `<сущность>.<действие>`.
 */

/** Поля, которые к событию добавляет БД. Не заполняются вручную. */
export const eventEnvelopeSchema = z.object({
  id: z.number().int().positive(),
  centerId: z.string().uuid(),
  createdAt: z.string().datetime({ offset: true }),
  processedAt: z.string().datetime({ offset: true }).nullable().default(null),
})
export type EventEnvelope = z.infer<typeof eventEnvelopeSchema>

/** Базовое событие: тип + произвольный payload. */
export const baseEventSchema = z.object({
  type: z.string().min(1).regex(/^[a-z_]+\.[a-z_]+$/, 'Формат типа: сущность.действие'),
  payload: z.record(z.unknown()).default({}),
})
export type BaseEvent = z.infer<typeof baseEventSchema>

export const centerCreatedSchema = z.object({
  type: z.literal('center.created'),
  payload: z.object({
    center_id: z.string().uuid(),
    name: z.string().min(1),
    slug: z.string().min(1),
    city: z.string().min(1).nullable().default(null),
  }),
})
export type CenterCreated = z.infer<typeof centerCreatedSchema>

export const membershipCreatedSchema = z.object({
  type: z.literal('membership.created'),
  payload: z.object({
    center_id: z.string().uuid(),
    user_id: z.string().uuid(),
    role: z.enum(['owner', 'admin', 'teacher', 'parent']),
  }),
})
export type MembershipCreated = z.infer<typeof membershipCreatedSchema>

export const membershipRevokedSchema = z.object({
  type: z.literal('membership.revoked'),
  payload: z.object({
    center_id: z.string().uuid(),
    user_id: z.string().uuid(),
    role: z.enum(['owner', 'admin', 'teacher', 'parent']),
  }),
})
export type MembershipRevoked = z.infer<typeof membershipRevokedSchema>

export const membershipRoleChangedSchema = z.object({
  type: z.literal('membership.role_changed'),
  payload: z.object({
    center_id: z.string().uuid(),
    user_id: z.string().uuid(),
    role: z.enum(['owner', 'admin', 'teacher', 'parent']),
    previous_role: z.enum(['owner', 'admin', 'teacher', 'parent']),
  }),
})
export type MembershipRoleChanged = z.infer<typeof membershipRoleChangedSchema>

export const invitationCreatedSchema = z.object({
  type: z.literal('invitation.created'),
  payload: z.object({
    center_id: z.string().uuid(),
    invitation_id: z.string().uuid(),
    role: z.enum(['admin', 'teacher', 'parent']),
    teacher_id: z.string().uuid().nullable().default(null),
  }),
})
export type InvitationCreated = z.infer<typeof invitationCreatedSchema>

export const payerCreatedSchema = z.object({
  type: z.literal('payer.created'),
  payload: z.object({
    center_id: z.string().uuid(),
    payer_id: z.string().uuid(),
    full_name: z.string().min(1),
  }),
})
export type PayerCreated = z.infer<typeof payerCreatedSchema>

export const studentCreatedSchema = z.object({
  type: z.literal('student.created'),
  payload: z.object({
    center_id: z.string().uuid(),
    student_id: z.string().uuid(),
    payer_id: z.string().uuid(),
    primary_teacher_id: z.string().uuid().nullable().default(null),
  }),
})
export type StudentCreated = z.infer<typeof studentCreatedSchema>

export const studentArchivedSchema = z.object({
  type: z.literal('student.archived'),
  payload: z.object({
    center_id: z.string().uuid(),
    student_id: z.string().uuid(),
  }),
})
export type StudentArchived = z.infer<typeof studentArchivedSchema>

export const studentRestoredSchema = z.object({
  type: z.literal('student.restored'),
  payload: z.object({
    center_id: z.string().uuid(),
    student_id: z.string().uuid(),
  }),
})
export type StudentRestored = z.infer<typeof studentRestoredSchema>

const lessonRef = z.object({
  center_id: z.string().uuid(),
  lesson_id: z.string().uuid(),
})

export const lessonCreatedSchema = z.object({
  type: z.literal('lesson.created'),
  payload: lessonRef.extend({
    series_id: z.string().uuid().nullable().default(null),
    starts_at: z.string(),
  }),
})

export const lessonCancelledSchema = z.object({
  type: z.literal('lesson.cancelled'),
  // Отменить можно и одно занятие, и хвост серии — отсюда необязательные поля.
  payload: z.object({
    center_id: z.string().uuid(),
    lesson_id: z.string().uuid().optional(),
    series_id: z.string().uuid().optional(),
    reason: z.string().nullable().default(null),
    count: z.number().int().optional(),
  }),
})

export const lessonSubstitutedSchema = z.object({
  type: z.literal('lesson.substituted'),
  payload: lessonRef.extend({ teacher_id: z.string().uuid() }),
})

export const lessonRescheduledSchema = z.object({
  type: z.literal('lesson.rescheduled'),
  payload: lessonRef.extend({ from: z.string(), to: z.string() }),
})

export const teacherVacationSchema = z.object({
  type: z.literal('teacher.vacation'),
  payload: z.object({
    center_id: z.string().uuid(),
    teacher_id: z.string().uuid(),
    from: z.string(),
    to: z.string(),
    cancelled: z.number().int(),
  }),
})

// --- Этап 4: посещения и абонементы -----------------------------------------

export const subscriptionCreatedSchema = z.object({
  type: z.literal('subscription.created'),
  payload: z.object({
    center_id: z.string().uuid(),
    subscription_id: z.string().uuid(),
    student_id: z.string().uuid(),
    /** Деньги — целые тыйыны, никаких дробей. */
    price_tiyin: z.number().int().nonnegative(),
    /** null — безлимитный абонемент, а не «ноль занятий». */
    lessons_total: z.number().int().positive().nullable(),
  }),
})
export type SubscriptionCreated = z.infer<typeof subscriptionCreatedSchema>

export const subscriptionFrozenSchema = z.object({
  type: z.literal('subscription.frozen'),
  payload: z.object({
    center_id: z.string().uuid(),
    subscription_id: z.string().uuid(),
    from: z.string(),
    /** null — заморозка с открытым концом. */
    to: z.string().nullable(),
  }),
})
export type SubscriptionFrozen = z.infer<typeof subscriptionFrozenSchema>

export const subscriptionUnfrozenSchema = z.object({
  type: z.literal('subscription.unfrozen'),
  payload: z.object({
    center_id: z.string().uuid(),
    subscription_id: z.string().uuid(),
    to: z.string(),
  }),
})
export type SubscriptionUnfrozen = z.infer<typeof subscriptionUnfrozenSchema>

export const subscriptionRefundedSchema = z.object({
  type: z.literal('subscription.refunded'),
  payload: z.object({
    center_id: z.string().uuid(),
    subscription_id: z.string().uuid(),
    lessons: z.number().int().nonnegative(),
    amount_tiyin: z.number().int().nonnegative(),
  }),
})
export type SubscriptionRefunded = z.infer<typeof subscriptionRefundedSchema>

export const subscriptionTransferredSchema = z.object({
  type: z.literal('subscription.transferred'),
  payload: z.object({
    center_id: z.string().uuid(),
    from_subscription_id: z.string().uuid(),
    to_subscription_id: z.string().uuid(),
    lessons: z.number().int().positive(),
  }),
})
export type SubscriptionTransferred = z.infer<typeof subscriptionTransferredSchema>

/** Остаток дошёл ровно до порога. Шлётся один раз, не на каждой отметке. */
export const subscriptionLowBalanceSchema = z.object({
  type: z.literal('subscription.low_balance'),
  payload: z.object({
    center_id: z.string().uuid(),
    subscription_id: z.string().uuid(),
    student_id: z.string().uuid(),
    lessons_left: z.number().int().nonnegative(),
  }),
})
export type SubscriptionLowBalance = z.infer<typeof subscriptionLowBalanceSchema>

export const subscriptionExhaustedSchema = z.object({
  type: z.literal('subscription.exhausted'),
  payload: z.object({
    center_id: z.string().uuid(),
    subscription_id: z.string().uuid(),
    student_id: z.string().uuid(),
  }),
})
export type SubscriptionExhausted = z.infer<typeof subscriptionExhaustedSchema>

export const attendanceMarkedSchema = z.object({
  type: z.literal('attendance.marked'),
  payload: z.object({
    center_id: z.string().uuid(),
    attendance_id: z.string().uuid(),
    lesson_id: z.string().uuid(),
    student_id: z.string().uuid(),
    /** null — отметка в долг: действующего абонемента не нашлось. */
    subscription_id: z.string().uuid().nullable(),
    deducted: z.boolean(),
  }),
})
export type AttendanceMarked = z.infer<typeof attendanceMarkedSchema>

/**
 * Занятие состоялось, а списывать было не с чего. Отметка при этом не
 * отклоняется: факт важнее денег, иначе специалист поставит ложный статус.
 */
export const attendanceNoSubscriptionSchema = z.object({
  type: z.literal('attendance.no_subscription'),
  payload: z.object({
    center_id: z.string().uuid(),
    attendance_id: z.string().uuid(),
    lesson_id: z.string().uuid(),
    student_id: z.string().uuid(),
    debt_tiyin: z.number().int().nonnegative(),
  }),
})
export type AttendanceNoSubscription = z.infer<typeof attendanceNoSubscriptionSchema>

/**
 * Два пропуска подряд по времени занятий. Длина фиксируется в payload, а
 * `streak_start_lesson_id` служит ключом дедупликации: повторный пересчёт
 * не должен слать второе сообщение о том же факте.
 */
export const studentAbsentStreakSchema = z.object({
  type: z.literal('student.absent_streak'),
  payload: z.object({
    center_id: z.string().uuid(),
    student_id: z.string().uuid(),
    streak_start_lesson_id: z.string().uuid(),
    lesson_id: z.string().uuid(),
    length: z.number().int().min(2),
  }),
})
export type StudentAbsentStreak = z.infer<typeof studentAbsentStreakSchema>

/** Все известные события системы. */
export const appEventSchema = z.discriminatedUnion('type', [
  centerCreatedSchema,
  membershipCreatedSchema,
  membershipRevokedSchema,
  membershipRoleChangedSchema,
  invitationCreatedSchema,
  payerCreatedSchema,
  studentCreatedSchema,
  studentArchivedSchema,
  studentRestoredSchema,
  lessonCreatedSchema,
  lessonCancelledSchema,
  lessonSubstitutedSchema,
  lessonRescheduledSchema,
  teacherVacationSchema,
  subscriptionCreatedSchema,
  subscriptionFrozenSchema,
  subscriptionUnfrozenSchema,
  subscriptionRefundedSchema,
  subscriptionTransferredSchema,
  subscriptionLowBalanceSchema,
  subscriptionExhaustedSchema,
  attendanceMarkedSchema,
  attendanceNoSubscriptionSchema,
  studentAbsentStreakSchema,
])
export type AppEvent = z.infer<typeof appEventSchema>

/** Тип события вместе с полями, проставленными БД. */
export const storedEventSchema = z.intersection(appEventSchema, eventEnvelopeSchema)
export type StoredEvent = z.infer<typeof storedEventSchema>

export const appEventTypes = [
  'center.created',
  'membership.created',
  'membership.revoked',
  'membership.role_changed',
  'invitation.created',
  'payer.created',
  'student.created',
  'student.archived',
  'student.restored',
  'lesson.created',
  'lesson.cancelled',
  'lesson.substituted',
  'lesson.rescheduled',
  'teacher.vacation',
] as const
export type AppEventType = (typeof appEventTypes)[number]

/**
 * Разбирает строку из public.events. Неизвестный тип — не ошибка приложения:
 * воркер должен пропустить событие, а не упасть.
 */
export function parseAppEvent(row: { type: string; payload: unknown }):
  | { ok: true; event: AppEvent }
  | { ok: false; error: string } {
  const result = appEventSchema.safeParse(row)
  return result.success
    ? { ok: true, event: result.data }
    : { ok: false, error: result.error.issues.map((i) => i.message).join('; ') }
}
