/**
 * Цвета статусов посещения — из attendance_statuses.color (0008_subscriptions.sql):
 * green/amber/sky/rose. «Болел» (sky) — временная заглушка --status-info, не из
 * макета Stitch, см. docs/Design/DESIGN.md, «Пробелы».
 *
 * Общее место для schedule/attendance-panel.tsx (кнопки отметки) и
 * students/[id] (история посещений) — оба красят один и тот же статус
 * одинаково, раздельные копии этой таблицы разошлись бы при следующей
 * генерации цвета для «Болел».
 */
export const ATTENDANCE_STATUS_CLASSES: Record<string, { active: string; inactive: string; badge: string }> = {
  green: {
    active: 'border-success bg-success text-white',
    inactive: 'border-success/40 text-success hover:bg-success-bg',
    badge: 'bg-success-bg text-success',
  },
  amber: {
    active: 'border-warning bg-warning text-white',
    inactive: 'border-warning/40 text-warning hover:bg-warning-bg',
    badge: 'bg-warning-bg text-warning',
  },
  sky: {
    active: 'border-info bg-info text-white',
    inactive: 'border-info/40 text-info hover:bg-info-bg',
    badge: 'bg-info-bg text-info',
  },
  rose: {
    active: 'border-danger bg-danger text-white',
    inactive: 'border-danger/40 text-danger hover:bg-danger-bg',
    badge: 'bg-danger-bg text-danger',
  },
  // Дефолт колонки color в attendance_statuses — статус, заведённый без
  // выбора цвета, должен быть серым, а не притворяться «Пришёл».
  slate: {
    active: 'border-status-neutral bg-status-neutral text-white',
    inactive: 'border-status-neutral/40 text-status-neutral hover:bg-status-neutral-bg',
    badge: 'bg-status-neutral-bg text-status-neutral',
  },
}

/** Что можно выбрать в справочнике статусов. Значение — то, что ляжет в attendance_statuses.color. */
export const ATTENDANCE_COLORS = [
  { value: 'green', label: 'Зелёный' },
  { value: 'amber', label: 'Янтарный' },
  { value: 'sky', label: 'Голубой' },
  { value: 'rose', label: 'Красный' },
  { value: 'slate', label: 'Серый' },
] as const

export function attendanceStatusClasses(color: string) {
  return ATTENDANCE_STATUS_CLASSES[color] ?? ATTENDANCE_STATUS_CLASSES.slate!
}

/** Состояния абонемента (subscription_state) — свои цвета, не связаны с посещением. */
export const SUBSCRIPTION_STATE_LABELS: Record<string, string> = {
  active: 'Действует',
  frozen: 'Заморожен',
  exhausted: 'Исчерпан',
  expired: 'Истёк',
  cancelled: 'Отменён',
}

export const SUBSCRIPTION_STATE_CLASSES: Record<string, string> = {
  active: 'bg-success-bg text-success',
  frozen: 'bg-info-bg text-info',
  exhausted: 'bg-warning-bg text-warning',
  expired: 'bg-status-neutral-bg text-status-neutral',
  cancelled: 'bg-danger-bg text-danger',
}
