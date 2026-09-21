/**
 * Тренд по цели за последние 3 занятия — public.student_goals_brief (0046).
 * Общее место для complete-lesson-form.tsx и students/[id]/goals-panel.tsx:
 * оба красят один и тот же trend, раздельные копии карты разошлись бы при
 * следующей правке цвета (тот же приём, что ATTENDANCE_STATUS_CLASSES).
 */
export type GoalTrend = 'regress' | 'stagnant' | 'growth' | 'stable'

export const GOAL_TREND_LABELS: Record<GoalTrend, string> = {
  regress: 'регресс',
  stagnant: 'застой',
  growth: 'рост',
  stable: 'стабильно',
}

export const GOAL_TREND_CLASSES: Record<GoalTrend, string> = {
  regress: 'bg-danger-bg text-danger',
  stagnant: 'bg-warning-bg text-warning',
  growth: 'bg-success-bg text-success',
  stable: 'bg-status-neutral-bg text-status-neutral',
}
