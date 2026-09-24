import { z } from 'zod'

// Роли — из dto: там они уже перечислены для форм, и второй список
// разошёлся бы с первым ровно так же, как appEventTypes разошёлся с union.
import { invitableRoleSchema, roleSchema } from './dto'

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
    role: roleSchema,
  }),
})
export type MembershipCreated = z.infer<typeof membershipCreatedSchema>

export const membershipRevokedSchema = z.object({
  type: z.literal('membership.revoked'),
  payload: z.object({
    center_id: z.string().uuid(),
    user_id: z.string().uuid(),
    role: roleSchema,
  }),
})
export type MembershipRevoked = z.infer<typeof membershipRevokedSchema>

export const membershipRoleChangedSchema = z.object({
  type: z.literal('membership.role_changed'),
  payload: z.object({
    center_id: z.string().uuid(),
    user_id: z.string().uuid(),
    role: roleSchema,
    previous_role: roleSchema,
  }),
})
export type MembershipRoleChanged = z.infer<typeof membershipRoleChangedSchema>

export const invitationCreatedSchema = z.object({
  type: z.literal('invitation.created'),
  payload: z.object({
    center_id: z.string().uuid(),
    invitation_id: z.string().uuid(),
    role: invitableRoleSchema,
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
    // Стоимость неотработанных занятий (refund_calc), не деньги — по
    // частично оплаченному абонементу больше реально возвращённого
    // (0030). Деньги — refund_tiyin.
    amount_tiyin: z.number().int().nonnegative(),
    // Optional: поле появилось в 0030. События, записанные раньше (в т.ч.
    // в staging), его не содержат — события не переписываются
    // (deleted_at-правило распространяется и на форму payload), а схема
    // читает и старую, и новую историю.
    refund_tiyin: z.number().int().nonnegative().optional(),
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


// --- Справочники центра: архив и восстановление -------------------------------

// Payload у всех один по форме: центр и идентификатор строки. Схемы всё равно
// перечислены поимённо — discriminatedUnion строится по литералу type, и
// «общая схема на пять типов» превратила бы неизвестный тип в известный.

const centerRef = z.object({ center_id: z.string().uuid() })

export const attendanceStatusArchivedSchema = z.object({
  type: z.literal('attendance_status.archived'),
  payload: centerRef.extend({ status_id: z.string().uuid() }),
})
export const attendanceStatusRestoredSchema = z.object({
  type: z.literal('attendance_status.restored'),
  payload: centerRef.extend({ status_id: z.string().uuid() }),
})
export const attendanceStatusDefaultChangedSchema = z.object({
  type: z.literal('attendance_status.default_changed'),
  payload: centerRef.extend({ status_id: z.string().uuid() }),
})
export const subscriptionTypeArchivedSchema = z.object({
  type: z.literal('subscription_type.archived'),
  payload: centerRef.extend({ subscription_type_id: z.string().uuid() }),
})
export const subscriptionTypeRestoredSchema = z.object({
  type: z.literal('subscription_type.restored'),
  payload: centerRef.extend({ subscription_type_id: z.string().uuid() }),
})
export const paymentSourceArchivedSchema = z.object({
  type: z.literal('payment_source.archived'),
  payload: centerRef.extend({ source_id: z.string().uuid() }),
})
export const paymentSourceRestoredSchema = z.object({
  type: z.literal('payment_source.restored'),
  payload: centerRef.extend({ source_id: z.string().uuid() }),
})
export const expenseCategoryArchivedSchema = z.object({
  type: z.literal('expense_category.archived'),
  payload: centerRef.extend({ category_id: z.string().uuid() }),
})
export const expenseCategoryRestoredSchema = z.object({
  type: z.literal('expense_category.restored'),
  payload: centerRef.extend({ category_id: z.string().uuid() }),
})

export const expenseRecordedSchema = z.object({
  type: z.literal('expense.recorded'),
  payload: centerRef.extend({
    expense_id: z.string().uuid(),
    category_id: z.string().uuid().nullable(),
    amount_tiyin: z.number().int(),
    kind: z.string(),
  }),
})

// --- Этап 6: уведомления ------------------------------------------------------

/**
 * Занятие начнётся не позже чем через 18 часов. Шлётся один раз на занятие
 * (lesson_reminders_sent, 0032), поэтому обработчик может не дедуплицировать.
 */
export const lessonReminderSchema = z.object({
  type: z.literal('lesson.reminder'),
  payload: centerRef.extend({
    lesson_id: z.string().uuid(),
    starts_at: z.string(),
    /** null у группового занятия — состав берётся из lesson_participants. */
    student_id: z.string().uuid().nullable(),
    group_id: z.string().uuid().nullable(),
    teacher_id: z.string().uuid().nullable(),
  }),
})

/** Родитель нажал «Подтвердить приход» в боте (0033). */
export const lessonConfirmedSchema = z.object({
  type: z.literal('lesson.confirmed'),
  payload: centerRef.extend({
    lesson_id: z.string().uuid(),
    student_id: z.string().uuid(),
  }),
})

/** Сводка за день владельцу и администраторам (0032, daily_digest). */
export const digestDailySchema = z.object({
  type: z.literal('digest.daily'),
  payload: centerRef.extend({
    date: z.string(),
    lessons_today: z.number().int().nonnegative(),
    low_balance: z.number().int().nonnegative(),
    debt_tiyin: z.number().int(),
    installments_overdue: z.number().int().nonnegative(),
  }),
})

/**
 * Событие не удалось обработать три раза подряд и ушло в терминал (0032).
 * Само по себе оно event.failed не порождает — иначе очередь росла бы из себя.
 */
export const eventFailedSchema = z.object({
  type: z.literal('event.failed'),
  payload: centerRef.extend({
    event_id: z.number().int().positive(),
    event_type: z.string(),
    attempts: z.number().int().positive(),
  }),
})

// --- Клиническое ядро: точечные RPC записи (0038) -----------------------------

export const diagnosticCreatedSchema = z.object({
  type: z.literal('diagnostic.created'),
  payload: centerRef.extend({
    diagnostic_id: z.string().uuid(),
    student_id: z.string().uuid(),
  }),
})

export const goalAchievedSchema = z.object({
  type: z.literal('goal.achieved'),
  payload: centerRef.extend({
    goal_id: z.string().uuid(),
    student_id: z.string().uuid(),
  }),
})

export const homeworkAssignedSchema = z.object({
  type: z.literal('homework.assigned'),
  payload: centerRef.extend({
    homework_id: z.string().uuid(),
    student_id: z.string().uuid(),
  }),
})

export const homeworkSubmittedSchema = z.object({
  type: z.literal('homework.submitted'),
  payload: centerRef.extend({
    homework_id: z.string().uuid(),
    student_id: z.string().uuid(),
  }),
})

/** Специалист проверил задание и оставил отзыв (0045). */
export const homeworkReviewedSchema = z.object({
  type: z.literal('homework.reviewed'),
  payload: centerRef.extend({
    homework_id: z.string().uuid(),
    student_id: z.string().uuid(),
  }),
})

export const lessonNoteApprovedSchema = z.object({
  type: z.literal('lesson.note_approved'),
  payload: centerRef.extend({
    lesson_note_id: z.string().uuid(),
    student_id: z.string().uuid(),
    lesson_id: z.string().uuid(),
  }),
})

/**
 * Занятие проведено через complete_lesson (0039) — один факт на занятие,
 * даже если внутри легло несколько attendance.marked/homework.assigned.
 */
export const lessonCompletedSchema = z.object({
  type: z.literal('lesson.completed'),
  payload: lessonRef,
})

/**
 * Специалист надиктовал занятие в бот (0041). Тело нарочно узкое: занятие,
 * ребёнок и заказчик читаются из lesson_voice_requests по voice_request_id,
 * а не передаются здесь — подменить их тогда нечем, и chat_id специалиста
 * не оседает в events.payload, который читают все owner/admin центра.
 * file_id вычищается из payload после обработки (ai_job_finish).
 */
export const lessonVoiceReceivedSchema = z.object({
  type: z.literal('lesson.voice_received'),
  payload: z.object({
    center_id: z.string().uuid(),
    voice_request_id: z.string().uuid(),
    file_id: z.string().optional(),
    duration: z.number().int().nullable().optional(),
  }),
})

/**
 * Обработка голосового не удалась (0041). Без этого события провал не видит
 * никто: очередь работ закрыта грантами, а до штатного event.failed дело не
 * доходит — работа становится терминальной сразу. Доставку в чат
 * специалиста делает n8n тем же путём, что и успех.
 */
export const lessonVoiceFailedSchema = z.object({
  type: z.literal('lesson.voice_failed'),
  payload: z.object({
    center_id: z.string().uuid(),
    voice_request_id: z.string().uuid().nullable().optional(),
    reason: z.string().nullable().optional(),
  }),
})

/**
 * Месячный отчёт родителю поставлен в очередь (0043). Текст заморожен в
 * событии намеренно: доставка через минуту после правки заметки иначе
 * дала бы третий вариант чисел, и кто прав — не сказал бы никто.
 */
export const reportMonthlyReadySchema = z.object({
  type: z.literal('report.monthly_ready'),
  payload: z.object({
    student_id: z.string().uuid(),
    period_month: z.string(),
    summary: z.string(),
  }),
})

/**
 * Центр подал заявку на оплату (0051). Адресат — администраторы платформы;
 * сумма посчитана в SQL из прайса, не в браузере.
 */
export const platformPaymentSubmittedSchema = z.object({
  type: z.literal('platform.payment_submitted'),
  payload: z.object({
    center_id: z.string().uuid(),
    payment_id: z.string().uuid(),
    plan: z.string(),
    months: z.number().int(),
    amount_tiyin: z.number().int(),
    source: z.string(),
  }),
})

/** Платформа подтвердила заявку и продлила центр (0051) — owner/admin центра. */
export const subscriptionExtendedSchema = z.object({
  type: z.literal('subscription.extended'),
  payload: z.object({
    center_id: z.string().uuid(),
    payment_id: z.string().uuid(),
    plan: z.string(),
    months: z.number().int(),
    until: z.string(),
  }),
})

/**
 * Подписка истекла между диктовкой и обработкой (0051): ai_job_begin отдал
 * null до платных вызовов, специалист узнаёт один раз на диктовку.
 */
export const subscriptionVoiceBlockedSchema = z.object({
  type: z.literal('subscription.voice_blocked'),
  payload: z.object({
    center_id: z.string().uuid(),
    voice_request_id: z.string().uuid(),
    reason_code: z.literal('subscription_expired'),
  }),
})

/**
 * Срок подписки или пробного периода заканчивается через 0–3 дня (0052).
 * Планировщик subscription_reminders, один раз на (центр, срок).
 */
export const subscriptionEndingSchema = z.object({
  type: z.literal('subscription.ending'),
  payload: z.object({
    center_id: z.string().uuid(),
    plan: z.string(),
    is_trial: z.boolean(),
    until: z.string(),
    days_left: z.number().int(),
  }),
})

/** Срок истёк — центр в режиме только чтения (0052). */
export const subscriptionExpiredSchema = z.object({
  type: z.literal('subscription.expired'),
  payload: z.object({
    center_id: z.string().uuid(),
    plan: z.string(),
    is_trial: z.boolean(),
    until: z.string(),
    days_left: z.number().int(),
  }),
})

/**
 * Лимит голосовых резюме по тарифу исчерпан (0053): ai_job_begin отдал null
 * до платных вызовов, один раз на диктовку; заказчику и owner/admin центра.
 */
export const aiQuotaExceededSchema = z.object({
  type: z.literal('ai.quota_exceeded'),
  payload: z.object({
    center_id: z.string().uuid(),
    voice_request_id: z.string().uuid(),
    used: z.number().int(),
    limit: z.number().int(),
  }),
})

/**
 * «Вынос базы клиентов» обязан оставить след (0056 Р11) — веб зовёт
 * record_center_export() одним вызовом после сборки файла; число строк по
 * каждой таблице (allow-list export_center_tables()) считает сама
 * функция, не принимает от вызывающего.
 */
export const centerExportedSchema = z.object({
  type: z.literal('center.exported'),
  payload: z.object({
    tables: z.record(z.number().int()),
  }),
})

/** Заявка на удаление центра (0056 Р8) — owner, mandatory (не выключить). */
export const centerDeletionRequestedSchema = z.object({
  type: z.literal('center.deletion_requested'),
  payload: z.object({
    center_id: z.string().uuid(),
    by: z.string().uuid(),
  }),
})

/** Отмена заявки на удаление (0056 Р9) — owner. */
export const centerDeletionCancelledSchema = z.object({
  type: z.literal('center.deletion_cancelled'),
  payload: z.object({
    center_id: z.string().uuid(),
    by: z.string().uuid(),
  }),
})

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
  attendanceStatusArchivedSchema,
  attendanceStatusRestoredSchema,
  attendanceStatusDefaultChangedSchema,
  subscriptionTypeArchivedSchema,
  subscriptionTypeRestoredSchema,
  paymentSourceArchivedSchema,
  paymentSourceRestoredSchema,
  expenseCategoryArchivedSchema,
  expenseCategoryRestoredSchema,
  expenseRecordedSchema,
  lessonReminderSchema,
  lessonConfirmedSchema,
  digestDailySchema,
  eventFailedSchema,
  diagnosticCreatedSchema,
  goalAchievedSchema,
  homeworkAssignedSchema,
  homeworkSubmittedSchema,
  homeworkReviewedSchema,
  lessonNoteApprovedSchema,
  lessonCompletedSchema,
  lessonVoiceReceivedSchema,
  lessonVoiceFailedSchema,
  reportMonthlyReadySchema,
  platformPaymentSubmittedSchema,
  subscriptionExtendedSchema,
  subscriptionVoiceBlockedSchema,
  subscriptionEndingSchema,
  subscriptionExpiredSchema,
  aiQuotaExceededSchema,
  centerExportedSchema,
  centerDeletionRequestedSchema,
  centerDeletionCancelledSchema,
])
export type AppEvent = z.infer<typeof appEventSchema>

/** Тип события вместе с полями, проставленными БД. */
export const storedEventSchema = z.intersection(appEventSchema, eventEnvelopeSchema)
export type StoredEvent = z.infer<typeof storedEventSchema>

/**
 * Список типов выводится из самого union, а не пишется рядом руками: до 0034
 * они разошлись — в массиве не было ни одного события этапа 4.
 */
export const appEventTypes = appEventSchema.options.map(
  (option) => option.shape.type.value,
) as AppEvent['type'][]

export type AppEventType = AppEvent['type']

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
