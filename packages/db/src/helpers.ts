import type { Tables } from './database.types'

export type CenterRow = Tables<'centers'>
export type MembershipRow = Tables<'memberships'>
export type EventRow = Tables<'events'>
export type AuditLogRow = Tables<'audit_log'>
export type TeacherRow = Tables<'teachers'>
export type PayerRow = Tables<'payers'>
export type StudentRow = Tables<'students'>

/** Роли в центре. Хранятся как text + check-constraint, не как pg enum (ADR-002). */
export type Role = 'owner' | 'admin' | 'teacher' | 'parent'

/** Тарифные планы. */
export type Plan = 'trial' | 'solo' | 'studio' | 'ai'

/** Статусы ученика. Lookup-таблицей станут, когда центры попросят свои. */
export type StudentStatus = 'lead' | 'active' | 'paused' | 'archived'
