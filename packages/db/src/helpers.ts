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

/** Статусы ученика. 'lead' снят в 0055 — этот статус его никогда не ставил, понятие «лид» несёт students.funnel_stage. */
export type StudentStatus = 'active' | 'paused' | 'archived'

/** Семь шагов воронки (0055) — funnel_stages в базе, students.funnel_stage. */
export type FunnelStage = 'lead' | 'contacted' | 'consultation' | 'assessment' | 'trial' | 'active' | 'completed'
