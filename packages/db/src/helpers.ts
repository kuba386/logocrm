import type { Tables } from './database.types'

export type CenterRow = Tables<'centers'>
export type MembershipRow = Tables<'memberships'>
export type EventRow = Tables<'events'>
export type AuditLogRow = Tables<'audit_log'>

/** Роли в центре. Хранятся как text + check-constraint, не как pg enum (ADR-002). */
export type Role = 'owner' | 'admin' | 'teacher' | 'parent'

/** Тарифные планы. */
export type Plan = 'trial' | 'solo' | 'studio' | 'ai'
