/**
 * Календарь серии занятий.
 *
 * ЭТОТ МОДУЛЬ СЧИТАЕТ ТОЛЬКО ДАТЫ. Занятость слотов приходит из RPC
 * (`create_lesson_series_preview`) и ниоткуда больше: два источника истины
 * про конфликты неизбежно разъедутся, и интерфейс начнёт показывать
 * «свободно» там, где база откажет.
 *
 * Зеркало функции `series_dates` из миграции 0006. Меняешь одну — меняешь
 * обе, и прогоняешь общий набор случаев в Vitest и pgTAP. Зачем зеркало
 * вообще нужно — ADR-006.
 */

/** ISO: понедельник = 1, воскресенье = 7. Не как в JS, где неделя с нуля. */
export type IsoWeekday = 1 | 2 | 3 | 4 | 5 | 6 | 7

export type SeriesInput = {
  /** Первый день серии, ГГГГ-ММ-ДД. */
  firstDate: string
  /** Последний день, ГГГГ-ММ-ДД. Включительно. */
  until: string
  /** Локальное время начала, ЧЧ:ММ. */
  time: string
  weekdays: IsoWeekday[]
  durationMin: number
  /** IANA-зона центра, например Asia/Bishkek. */
  timeZone: string
}

export type SeriesSlot = {
  /** Календарный день в зоне центра, ГГГГ-ММ-ДД. */
  day: string
  startsAt: Date
  endsAt: Date
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/
const TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/

/**
 * Смещение зоны относительно UTC в миллисекундах на конкретный момент.
 * Через Intl, без внешних зависимостей: date-fns-tz ради одной функции
 * тащить не стали.
 */
function zoneOffsetMs(instant: Date, timeZone: string): number {
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hour12: false,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })

  const parts: Record<string, string> = {}
  for (const part of formatter.formatToParts(instant)) {
    if (part.type !== 'literal') parts[part.type] = part.value
  }

  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour) % 24,
    Number(parts.minute),
    Number(parts.second),
  )

  return asUtc - instant.getTime()
}

/**
 * Локальное время в зоне → момент UTC.
 *
 * Два прохода: первое смещение берётся приблизительно, второе уточняет его
 * уже около искомого момента. Для Кыргызстана перевода часов нет и хватило бы
 * одного, но зашивать это в код нельзя — на этапе 8 появятся филиалы.
 */
export function zonedToUtc(localDate: string, localTime: string, timeZone: string): Date {
  if (!DATE_RE.test(localDate)) throw new TypeError(`Некорректная дата: ${localDate}`)
  if (!TIME_RE.test(localTime)) throw new TypeError(`Некорректное время: ${localTime}`)

  const naive = Date.parse(`${localDate}T${localTime}:00Z`)
  if (Number.isNaN(naive)) throw new TypeError(`Некорректная дата или время: ${localDate} ${localTime}`)

  let instant = new Date(naive - zoneOffsetMs(new Date(naive), timeZone))
  instant = new Date(naive - zoneOffsetMs(instant, timeZone))
  return instant
}

function addDays(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() + days)
  return d.toISOString().slice(0, 10)
}

/** ISO-номер дня недели для календарной даты. */
export function isoWeekday(date: string): IsoWeekday {
  const jsDay = new Date(`${date}T00:00:00Z`).getUTCDay()
  return (jsDay === 0 ? 7 : jsDay) as IsoWeekday
}

/**
 * Даты серии. `until` включительно.
 *
 * Повтор дня недели в списке — ошибка, а не повод создать два занятия:
 * то же правило стоит в `series_dates`, и расходиться им нельзя.
 */
export function generateSeriesDates(input: SeriesInput): SeriesSlot[] {
  const { firstDate, until, time, weekdays, durationMin, timeZone } = input

  if (!DATE_RE.test(firstDate)) throw new TypeError(`Некорректная дата начала: ${firstDate}`)
  if (!DATE_RE.test(until)) throw new TypeError(`Некорректная дата окончания: ${until}`)
  if (until < firstDate) throw new RangeError('Дата окончания раньше даты начала')

  if (weekdays.length === 0) throw new RangeError('Укажите хотя бы один день недели')
  if (weekdays.some((d) => d < 1 || d > 7)) {
    throw new RangeError('День недели вне диапазона 1–7 (понедельник — воскресенье)')
  }
  if (new Set(weekdays).size !== weekdays.length) {
    throw new RangeError('День недели указан дважды')
  }

  if (!Number.isInteger(durationMin) || durationMin <= 0) {
    throw new RangeError('Длительность занятия должна быть положительной')
  }

  const wanted = new Set<number>(weekdays)
  const slots: SeriesSlot[] = []

  for (let day = firstDate; day <= until; day = addDays(day, 1)) {
    if (!wanted.has(isoWeekday(day))) continue

    const startsAt = zonedToUtc(day, time, timeZone)
    slots.push({
      day,
      startsAt,
      endsAt: new Date(startsAt.getTime() + durationMin * 60_000),
    })
  }

  return slots
}

/**
 * Пересекаются ли интервалы.
 *
 * Касание границ пересечением не считается: занятие 10:45–11:30 идёт сразу
 * после 10:00–10:45 и накладкой не является. Ровно так же ведёт себя
 * `tstzrange` с `&&` в базе.
 */
export function overlaps(aStart: Date, aEnd: Date, bStart: Date, bEnd: Date): boolean {
  for (const [start, end] of [
    [aStart, aEnd],
    [bStart, bEnd],
  ] as const) {
    if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) {
      throw new TypeError('Некорректная дата интервала')
    }
    // Нулевая и вывернутая длительность — ошибка данных, а не «не пересекается».
    if (end.getTime() <= start.getTime()) {
      throw new RangeError('Занятие должно заканчиваться позже, чем начинается')
    }
  }

  return aStart.getTime() < bEnd.getTime() && bStart.getTime() < aEnd.getTime()
}

/** Есть ли самопересечения внутри набора слотов. */
export function findSelfOverlap(slots: SeriesSlot[]): [SeriesSlot, SeriesSlot] | null {
  const sorted = [...slots].sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime())

  for (let i = 1; i < sorted.length; i += 1) {
    const previous = sorted[i - 1]!
    const current = sorted[i]!
    if (overlaps(previous.startsAt, previous.endsAt, current.startsAt, current.endsAt)) {
      return [previous, current]
    }
  }

  return null
}
