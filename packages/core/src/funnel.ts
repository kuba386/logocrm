/**
 * Семь шагов воронки (0055) — источник истины — funnel_stages в базе и
 * граф переходов в BEFORE-триггере students_funnel_stage_guard. Порядок
 * здесь совпадает с sort в SQL.
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

/**
 * Разрешённые ручные переходы для кнопок интерфейса — зеркало графа в
 * students_funnel_stage_guard (0055 Р4): вперёд — только на непосредственно
 * следующий шаг, назад — на любой более ранний. SQL — источник истины: если
 * RPC set_funnel_stage откажет, компонент показывает её текст, не свой.
 */
export function allowedFunnelTransitions(current: FunnelStage): FunnelStage[] {
  const i = FUNNEL_STAGES.indexOf(current)
  if (i < 0) return []
  const next = FUNNEL_STAGES[i + 1]
  const forward = next ? [next] : []
  const backward = FUNNEL_STAGES.slice(0, i)
  return [...forward, ...backward]
}
