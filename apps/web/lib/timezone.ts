/**
 * Время всегда показываем в поясе центра, а не браузера.
 *
 * Администратор из поездки должен видеть расписание своей студии: иначе он
 * позвонит родителю на два часа раньше или позже, чем нужно.
 */
export const DEFAULT_TIME_ZONE = 'Asia/Bishkek'

export function centerTimeZone(settings: unknown): string {
  if (settings && typeof settings === 'object' && 'timezone' in settings) {
    const value = (settings as { timezone?: unknown }).timezone
    if (typeof value === 'string' && value.length > 0) return value
  }
  return DEFAULT_TIME_ZONE
}

export function formatInTimeZone(
  iso: string | Date,
  timeZone: string,
  options: Intl.DateTimeFormatOptions,
): string {
  const date = iso instanceof Date ? iso : new Date(iso)
  return new Intl.DateTimeFormat('ru-RU', { timeZone, ...options }).format(date)
}

/** «10:00» в поясе центра. */
export function timeInZone(iso: string | Date, timeZone: string): string {
  return formatInTimeZone(iso, timeZone, { hour: '2-digit', minute: '2-digit' })
}

/** «5 октября» в поясе центра. */
export function dayInZone(iso: string | Date, timeZone: string): string {
  return formatInTimeZone(iso, timeZone, { day: 'numeric', month: 'long' })
}

/** Календарный день ГГГГ-ММ-ДД в поясе центра. */
export function isoDayInZone(iso: string | Date, timeZone: string): string {
  const date = iso instanceof Date ? iso : new Date(iso)
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date)
  return parts
}

/** Понедельник недели, в которую попадает день. */
export function startOfWeek(day: string): string {
  const date = new Date(`${day}T00:00:00Z`)
  const iso = date.getUTCDay() === 0 ? 7 : date.getUTCDay()
  date.setUTCDate(date.getUTCDate() - (iso - 1))
  return date.toISOString().slice(0, 10)
}

export function addDays(day: string, days: number): string {
  const date = new Date(`${day}T00:00:00Z`)
  date.setUTCDate(date.getUTCDate() + days)
  return date.toISOString().slice(0, 10)
}
