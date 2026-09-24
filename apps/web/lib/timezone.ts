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

/** Смещение пояса от UTC в минутах на момент date («360» для Asia/Bishkek, UTC+6). */
function tzOffsetMinutes(date: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(date)
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? 0)
  const asUtc = Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second'))
  return Math.round((asUtc - date.getTime()) / 60000)
}

/**
 * Начало календарного дня (ГГГГ-ММ-ДД) в поясе центра — как UTC-момент,
 * пригодный для `.gte('starts_at', ...)`.
 *
 * `dayInZone`/`isoDayInZone` — для показа человеку, где сдвиг на пару часов
 * не страшен. Здесь сдвиг ломает границу «сегодня»: для Bishkek (UTC+6)
 * `${day}T00:00:00Z` — это 06:00 по местному, а не полночь, и дашборд
 * потерял бы первые шесть часов дня и прихватил бы утро следующего.
 */
export function startOfDayInZone(day: string, timeZone: string): string {
  // Смещение берём на полдень того же дня — не на полночь, где при переходе
  // на летнее время (не наш случай, но пояс настраиваемый) сам момент
  // неоднозначен.
  const offsetMin = tzOffsetMinutes(new Date(`${day}T12:00:00Z`), timeZone)
  return new Date(new Date(`${day}T00:00:00Z`).getTime() - offsetMin * 60000).toISOString()
}

/**
 * «2026-10-05» + «14:30» в поясе центра → ISO в UTC. Нужна там, где
 * дату/время выбирает форма без пояса (нативные <input type=date/time>) —
 * витрина записи (0057): сервер, где выполняется action, не в поясе
 * центра, и new Date(`${day}T${time}`) взял бы часовой пояс СЕРВЕРА, не
 * центра — та же ошибка класса «T00:00:00Z вместо местной полуночи», что
 * startOfDayInZone уже закрывает для дат.
 */
export function zonedDateTimeToIso(day: string, time: string, timeZone: string): string {
  const naiveUtc = new Date(`${day}T${time}:00Z`)
  const offsetMin = tzOffsetMinutes(naiveUtc, timeZone)
  return new Date(naiveUtc.getTime() - offsetMin * 60000).toISOString()
}
