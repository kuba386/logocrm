import { formatInTimeZone } from '@/lib/timezone'

export const LESSON_STATUS_LABELS: Record<string, string> = {
  planned: 'Запланировано',
  done: 'Проведено',
  cancelled: 'Отменено',
}

export const WEEKDAY_LABELS = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'] as const

/** Сетка дня: с какого часа рисуем и по какой. */
export const DAY_START_HOUR = 8
export const DAY_END_HOUR = 21
/** Высота одного часа в пикселях. Блоки позиционируются по минутам. */
export const HOUR_HEIGHT = 56

export function lessonStatusLabel(status: string | null | undefined): string {
  if (!status) return '—'
  return LESSON_STATUS_LABELS[status] ?? status
}

/**
 * Смещение и высота блока занятия в пикселях.
 *
 * Считаем от начала дня в минутах, а не по строкам сетки: сетка получасовая,
 * а занятия по 45 минут, и в строки они не укладываются.
 */
export function blockGeometry(
  startsAt: string,
  endsAt: string,
  timeZone: string,
): { top: number; height: number } {
  const startMinutes = minutesFromDayStart(startsAt, timeZone)
  const endMinutes = minutesFromDayStart(endsAt, timeZone)

  return {
    top: (startMinutes / 60) * HOUR_HEIGHT,
    height: Math.max(((endMinutes - startMinutes) / 60) * HOUR_HEIGHT, 18),
  }
}

function minutesFromDayStart(iso: string, timeZone: string): number {
  const hhmm = formatInTimeZone(iso, timeZone, { hour: '2-digit', minute: '2-digit' })
  const [hours, minutes] = hhmm.split(':').map(Number)
  return (hours! - DAY_START_HOUR) * 60 + minutes!
}
