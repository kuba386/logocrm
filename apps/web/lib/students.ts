import { ageLabel } from '@logocrm/core'

/**
 * Статусы ученика для интерфейса. 'lead' убран с 0055: он был мёртвым
 * значением (create_student_with_payer никогда его не ставил, дефолт
 * колонки — 'active') — понятие «лид» теперь несёт отдельная колонка
 * funnel_stage (FUNNEL_STAGE_LABELS ниже), не путать с этим status.
 */
export const STUDENT_STATUS_LABELS: Record<string, string> = {
  active: 'Занимается',
  paused: 'Пауза',
  archived: 'В архиве',
}

export const STUDENT_STATUS_CLASSES: Record<string, string> = {
  active: 'bg-primary/10 text-primary',
  paused: 'bg-muted text-muted-foreground',
  archived: 'bg-muted text-muted-foreground line-through',
}

export function statusLabel(status: string | null | undefined): string {
  if (!status) return '—'
  return STUDENT_STATUS_LABELS[status] ?? status
}

/**
 * Семь шагов воронки (0055) — подсказка для интерфейса, источник истины —
 * funnel_stages в базе и граф переходов в BEFORE-триггере
 * students_funnel_stage_guard. Порядок здесь совпадает с sort в SQL.
 */
export const FUNNEL_STAGES = [
  'lead',
  'contacted',
  'consultation',
  'assessment',
  'trial',
  'active',
  'completed',
] as const
export type FunnelStage = (typeof FUNNEL_STAGES)[number]

export const FUNNEL_STAGE_LABELS: Record<FunnelStage, string> = {
  lead: 'Лид',
  contacted: 'Связались',
  consultation: 'Консультация',
  assessment: 'Диагностика',
  trial: 'Пробное занятие',
  active: 'Занимается',
  completed: 'Курс окончен',
}

export const FUNNEL_STAGE_CLASSES: Record<FunnelStage, string> = {
  lead: 'bg-accent text-accent-foreground',
  contacted: 'bg-accent text-accent-foreground',
  consultation: 'bg-sky-100 text-sky-700',
  assessment: 'bg-sky-100 text-sky-700',
  trial: 'bg-amber-100 text-amber-700',
  active: 'bg-primary/10 text-primary',
  completed: 'bg-muted text-muted-foreground',
}

export function funnelStageLabel(stage: string | null | undefined): string {
  if (!stage) return '—'
  return FUNNEL_STAGE_LABELS[stage as FunnelStage] ?? stage
}

/**
 * Разрешённые ручные переходы для кнопок интерфейса — зеркало графа в
 * students_funnel_stage_guard (0055 Р4). SQL — источник истины: если
 * RPC set_funnel_stage откажет, компонент покажет её текст, не свой.
 */
export function allowedFunnelTransitions(current: FunnelStage): FunnelStage[] {
  const i = FUNNEL_STAGES.indexOf(current)
  if (i < 0) return []
  const next = FUNNEL_STAGES[i + 1]
  const forward = next ? [next] : []
  const backward = FUNNEL_STAGES.slice(0, i)
  return [...forward, ...backward]
}

export const PAYER_RELATIONS = ['мама', 'папа', 'бабушка', 'дедушка', 'опекун', 'другое'] as const

/** Общая для списка и карточки строка возраста. */
export function studentAge(birthDate: string | null | undefined): string {
  return ageLabel(birthDate ?? null)
}
