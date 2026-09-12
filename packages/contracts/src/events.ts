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

/**
 * Остаток ушёл в минус — только у абонементов с allow_negative. Шлётся один
 * раз на первом переходе через ноль: без него такой абонемент списывал бы
 * молча (no_subscription не шлётся, debt_tiyin не растёт).
 */
export const subscriptionOverdrawnSchema = z.object({
  type: z.literal('subscription.overdrawn'),
  payload: z.object({
    center_id: z.string().uuid(),
    subscription_id: z.string().uuid(),
    student_id: z.string().uuid(),
    lessons_left: z.number().int().negative(),
  }),
})
export type SubscriptionOverdrawn = z.infer<typeof subscriptionOverdrawnSchema>

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

/**
 * Снимок начисленной зарплаты специалиста за месяц (0017) — эмитится вместе
 * со строкой salary_runs, не самим calc_salary: тот читает живые данные
 * (ставка, статус отметки, замена специалиста могут поменяться позже),
 * снимок — единственный источник "сколько заплатили в этом месяце".
 */
export const salaryCalculatedSchema = z.object({
  type: z.literal('salary.calculated'),
  payload: z.object({
    center_id: z.string().uuid(),
    salary_run_id: z.string().uuid(),
    teacher_id: z.string().uuid(),
    month: z.string(),
    total_tiyin: z.number().int(),
  }),
})
export type SalaryCalculated = z.infer<typeof salaryCalculatedSchema>

/** Бонус или штраф к зарплате за месяц (0017, record_salary_adjustment). */
export const salaryAdjustmentRecordedSchema = z.object({
  type: z.literal('salary.adjustment_recorded'),
  payload: z.object({
    center_id: z.string().uuid(),
    adjustment_id: z.string().uuid(),
    teacher_id: z.string().uuid(),
    month: z.string(),
    /** Отрицательное — штраф. Ноль запрещён констрейнтом. */
    amount_tiyin: z.number().int(),
  }),
})
export type SalaryAdjustmentRecorded = z.infer<typeof salaryAdjustmentRecordedSchema>

/**
 * Снимок зарплаты отменён владельцем (0029, cancel_salary_run) — одно
 * событие на снимок. После отмены approve_salary за тот же месяц создаёт
 * новый снимок; отменённый остаётся историей (salary_summary.cancelled_runs).
 */
export const salaryRunCancelledSchema = z.object({
  type: z.literal('salary.run_cancelled'),
  payload: z.object({
    center_id: z.string().uuid(),
    salary_run_id: z.string().uuid(),
    teacher_id: z.string().uuid(),
    month: z.string(),
  }),
})
export type SalaryRunCancelled = z.infer<typeof salaryRunCancelledSchema>

export const teacherArchivedSchema = z.object({
  type: z.literal('teacher.archived'),
  payload: z.object({
    center_id: z.string().uuid(),
    teacher_id: z.string().uuid(),
  }),
})
export type TeacherArchived = z.infer<typeof teacherArchivedSchema>

export const teacherRestoredSchema = z.object({
  type: z.literal('teacher.restored'),
  payload: z.object({
    center_id: z.string().uuid(),
    teacher_id: z.string().uuid(),
  }),
})
export type TeacherRestored = z.infer<typeof teacherRestoredSchema>

// --- Этап 5: платежи, периоды, рассрочка ------------------------------------

/**
 * Платёж записан (record_payment, 0013). Один payload на received/refunded:
 * различаются type и знаком amount_tiyin (refund — отрицательный).
 */
const paymentPayload = z.object({
  center_id: z.string().uuid(),
  payment_id: z.string().uuid(),
  payer_id: z.string().uuid(),
  student_id: z.string().uuid().nullable(),
  subscription_id: z.string().uuid().nullable(),
  amount_tiyin: z.number().int(),
  kind: z.enum(['payment', 'refund', 'correction']),
})

export const paymentReceivedSchema = z.object({
  type: z.literal('payment.received'),
  payload: paymentPayload,
})
export type PaymentReceived = z.infer<typeof paymentReceivedSchema>

export const paymentRefundedSchema = z.object({
  type: z.literal('payment.refunded'),
  payload: paymentPayload,
})
export type PaymentRefunded = z.infer<typeof paymentRefundedSchema>

/** Замок месяца (close_month / reopen_month, 0013-0014). month — первое число. */
const periodPayload = z.object({
  center_id: z.string().uuid(),
  month: z.string(),
})

export const periodClosedSchema = z.object({
  type: z.literal('period.closed'),
  payload: periodPayload,
})
export type PeriodClosed = z.infer<typeof periodClosedSchema>

export const periodReopenedSchema = z.object({
  type: z.literal('period.reopened'),
  payload: periodPayload,
})
export type PeriodReopened = z.infer<typeof periodReopenedSchema>

/**
 * Платёж рассрочки (0018): due — день в день, overdue — после срока. Шлётся
 * installments_notify по одному разу на каждый переход (*_notified_at).
 */
const installmentPayload = z.object({
  center_id: z.string().uuid(),
  installment_id: z.string().uuid(),
  subscription_id: z.string().uuid(),
  student_id: z.string().uuid(),
  payer_id: z.string().uuid(),
  seq: z.number().int().positive(),
  due_date: z.string(),
  amount_tiyin: z.number().int().positive(),
})

export const installmentDueSchema = z.object({
  type: z.literal('installment.due'),
  payload: installmentPayload,
})
export type InstallmentDue = z.infer<typeof installmentDueSchema>

export const installmentOverdueSchema = z.object({
  type: z.literal('installment.overdue'),
  payload: installmentPayload,
})
export type InstallmentOverdue = z.infer<typeof installmentOverdueSchema>

/** План рассрочки оформлен (create_installment_plan, 0020). */
export const installmentPlanCreatedSchema = z.object({
  type: z.literal('installment_plan.created'),
  payload: z.object({
    center_id: z.string().uuid(),
    plan_id: z.string().uuid(),
    subscription_id: z.string().uuid(),
    student_id: z.string().uuid(),
    payer_id: z.string().uuid(),
    installments: z.number().int().positive(),
    total_tiyin: z.number().int().positive(),
    first_due: z.string(),
  }),
})
export type InstallmentPlanCreated = z.infer<typeof installmentPlanCreatedSchema>

/** План отменён администратором (cancel_installment_plan). Отмена при
 * возврате/переносе абонемента события не пишет — у тех путей свои. */
export const installmentPlanCancelledSchema = z.object({
  type: z.literal('installment_plan.cancelled'),
  payload: z.object({
    center_id: z.string().uuid(),
    plan_id: z.string().uuid(),
    subscription_id: z.string().uuid(),
    student_id: z.string().uuid(),
    payer_id: z.string().uuid(),
  }),
})
export type InstallmentPlanCancelled = z.infer<typeof installmentPlanCancelledSchema>

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
  subscriptionOverdrawnSchema,
  attendanceMarkedSchema,
  attendanceNoSubscriptionSchema,
  studentAbsentStreakSchema,
  salaryCalculatedSchema,
  salaryAdjustmentRecordedSchema,
  salaryRunCancelledSchema,
  teacherArchivedSchema,
  teacherRestoredSchema,
  paymentReceivedSchema,
  paymentRefundedSchema,
  periodClosedSchema,
  periodReopenedSchema,
  installmentDueSchema,
  installmentOverdueSchema,
  installmentPlanCreatedSchema,
  installmentPlanCancelledSchema,
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
  'teacher.archived',
  'teacher.restored',
  'salary.calculated',
  'salary.adjustment_recorded',
  'salary.run_cancelled',
  'payment.received',
  'payment.refunded',
  'period.closed',
  'period.reopened',
  'installment.due',
  'installment.overdue',
  'installment_plan.created',
  'installment_plan.cancelled',
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
