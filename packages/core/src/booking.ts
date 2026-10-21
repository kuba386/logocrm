import { isoWeekday, type IsoWeekday } from './schedule'

/**
 * Свободные окна онлайн-записи (0109) — показ и форма листа ожидания.
 *
 * Окна считает SQL (`booking_slots_unchecked`), здесь только раскладка по
 * дням и подписи. День недели — ISO, как `extract(isodow …)` в базе: 1 —
 * понедельник, 7 — воскресенье. Общие случаи с pgTAP 0109 — в booking.test.ts.
 */

/** Подписи дней недели по ISO-номеру: WEEKDAY_SHORT[isodow - 1]. */
export const WEEKDAY_SHORT = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'] as const

const MONTH_SHORT = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'] as const

/** Календарный день ГГГГ-ММ-ДД момента в поясе центра. */
export function localDayInZone(iso: string | Date, timeZone: string): string {
  const date = iso instanceof Date ? iso : new Date(iso)
  return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(date)
}

/** Время ЧЧ:ММ момента в поясе центра. */
export function localTimeInZone(iso: string | Date, timeZone: string): string {
  const date = iso instanceof Date ? iso : new Date(iso)
  return new Intl.DateTimeFormat('en-GB', { timeZone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(date)
}

/** ISO-день недели момента в поясе центра — не в поясе браузера и не UTC. */
export function isoWeekdayInZone(iso: string | Date, timeZone: string): IsoWeekday {
  return isoWeekday(localDayInZone(iso, timeZone))
}

/** Подпись дня окна: «Пн 26 окт». */
export function slotDayLabel(day: string): string {
  const month = Number(day.slice(5, 7))
  const date = Number(day.slice(8, 10))
  return `${WEEKDAY_SHORT[isoWeekday(day) - 1]} ${date} ${MONTH_SHORT[month - 1]}`
}

/** Подпись окна в поясе центра: «Пн 26 окт · 09:00». */
export function slotLabel(iso: string, timeZone: string): string {
  return `${slotDayLabel(localDayInZone(iso, timeZone))} · ${localTimeInZone(iso, timeZone)}`
}

export type SlotDay = {
  day: string
  label: string
  slots: { startsAt: string; time: string }[]
}

/** Окна по дням центра в порядке времени. День — местный, не UTC. */
export function groupSlotsByDay(slots: { starts_at: string }[], timeZone: string): SlotDay[] {
  const sorted = [...slots].sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at))
  const days: SlotDay[] = []
  for (const slot of sorted) {
    const day = localDayInZone(slot.starts_at, timeZone)
    let bucket = days[days.length - 1]
    if (!bucket || bucket.day !== day) {
      bucket = { day, label: slotDayLabel(day), slots: [] }
      days.push(bucket)
    }
    bucket.slots.push({ startsAt: slot.starts_at, time: localTimeInZone(slot.starts_at, timeZone) })
  }
  return days
}

/**
 * Удобные дни из формы листа ожидания — как `submit_waitlist_entry`:
 * повторы схлопываются, порядок по возрастанию, пустой выбор — null («любой
 * день»). Значение вне 1..7 — ошибка, а не тихий пропуск.
 */
export function parseWeekdays(values: (string | number)[]): IsoWeekday[] | null {
  const days = new Set<IsoWeekday>()
  for (const value of values) {
    const n = Number(value)
    if (!Number.isInteger(n) || n < 1 || n > 7) {
      throw new RangeError(`День недели вне 1..7: ${String(value)}`)
    }
    days.add(n as IsoWeekday)
  }
  return days.size === 0 ? null : [...days].sort((a, b) => a - b)
}

/**
 * Рабочие часы одной строкой: «Пн–Пт 09:00–13:00, 14:00–18:00; Сб 10:00–14:00».
 * Подряд идущие дни с одинаковыми интервалами склеиваются; выходные пропускаются.
 */
export function workHoursSummary(intervals: { weekday: number; starts_at: string; ends_at: string }[]): string {
  const byDay = new Map<number, string>()
  const sorted = [...intervals].sort((a, b) => a.weekday - b.weekday || a.starts_at.localeCompare(b.starts_at))
  for (const i of sorted) {
    const range = `${i.starts_at.slice(0, 5)}–${i.ends_at.slice(0, 5)}`
    const prev = byDay.get(i.weekday)
    byDay.set(i.weekday, prev ? `${prev}, ${range}` : range)
  }
  const parts: string[] = []
  let day = 1
  while (day <= 7) {
    const value = byDay.get(day)
    if (value === undefined) {
      day++
      continue
    }
    let end = day
    while (end < 7 && byDay.get(end + 1) === value) end++
    const label = end === day ? WEEKDAY_SHORT[day - 1] : `${WEEKDAY_SHORT[day - 1]}–${WEEKDAY_SHORT[end - 1]}`
    parts.push(`${label} ${value}`)
    day = end + 1
  }
  return parts.join('; ')
}
