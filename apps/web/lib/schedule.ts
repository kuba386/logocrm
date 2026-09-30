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

/**
 * Дорожки для одновременных занятий: пересекающиеся по времени блоки
 * делят ширину колонки, а не ложатся друг на друга. Группа пересечений
 * (кластер) получает столько дорожек, сколько занятий в нём идёт разом.
 */
export function overlapLanes(
  items: { id: string; startsAt: string; endsAt: string }[],
): Map<string, { lane: number; lanes: number }> {
  const sorted = items
    .map((item) => ({ id: item.id, start: Date.parse(item.startsAt), end: Date.parse(item.endsAt) }))
    .sort((a, b) => a.start - b.start || b.end - a.end)

  const result = new Map<string, { lane: number; lanes: number }>()
  let cluster: { id: string; lane: number }[] = []
  let laneEnds: number[] = []
  let clusterEnd = -Infinity

  const flush = () => {
    for (const entry of cluster) result.set(entry.id, { lane: entry.lane, lanes: laneEnds.length })
    cluster = []
    laneEnds = []
  }

  for (const item of sorted) {
    if (cluster.length > 0 && item.start >= clusterEnd) flush()
    let lane = laneEnds.findIndex((end) => end <= item.start)
    if (lane === -1) {
      lane = laneEnds.length
      laneEnds.push(item.end)
    } else {
      laneEnds[lane] = item.end
    }
    cluster.push({ id: item.id, lane })
    clusterEnd = cluster.length === 1 ? item.end : Math.max(clusterEnd, item.end)
  }
  flush()

  return result
}
