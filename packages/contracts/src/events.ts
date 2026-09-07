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

/** Все известные события системы. */
export const appEventSchema = z.discriminatedUnion('type', [
  centerCreatedSchema,
  membershipCreatedSchema,
  membershipRevokedSchema,
  membershipRoleChangedSchema,
  invitationCreatedSchema,
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
