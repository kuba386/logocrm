/**
 * Возраст ребёнка. Для логопеда это рабочая величина, а не украшение:
 * нормы речевого развития расписаны по годам и месяцам, поэтому «4 года 3 мес»
 * информативнее, чем «4».
 */

export type Age = { years: number; months: number }

function toDate(value: Date | string): Date {
  return value instanceof Date ? value : new Date(`${value}T00:00:00`)
}

/** Полных лет на указанную дату (по умолчанию — сегодня). */
export function ageYears(birthDate: Date | string, today: Date | string = new Date()): number {
  return ageParts(birthDate, today).years
}

/** Полных лет и месяцев сверх них. */
export function ageParts(birthDate: Date | string, today: Date | string = new Date()): Age {
  const birth = toDate(birthDate)
  const now = toDate(today)

  if (Number.isNaN(birth.getTime()) || Number.isNaN(now.getTime())) {
    throw new TypeError('Некорректная дата')
  }

  let years = now.getFullYear() - birth.getFullYear()
  let months = now.getMonth() - birth.getMonth()

  if (now.getDate() < birth.getDate()) {
    months -= 1
  }

  if (months < 0) {
    years -= 1
    months += 12
  }

  return { years, months }
}

function plural(value: number, one: string, few: string, many: string): string {
  const mod100 = value % 100
  if (mod100 >= 11 && mod100 <= 14) return many

  switch (value % 10) {
    case 1:
      return one
    case 2:
    case 3:
    case 4:
      return few
    default:
      return many
  }
}

/** «4 года 3 мес», «11 месяцев», «1 год». */
export function ageLabel(
  birthDate: Date | string | null | undefined,
  today: Date | string = new Date(),
): string {
  if (!birthDate) return '—'

  const { years, months } = ageParts(birthDate, today)

  if (years < 0) return '—'

  if (years === 0) {
    if (months === 0) return 'меньше месяца'
    return `${months} ${plural(months, 'месяц', 'месяца', 'месяцев')}`
  }

  const yearsPart = `${years} ${plural(years, 'год', 'года', 'лет')}`
  return months === 0 ? yearsPart : `${yearsPart} ${months} мес`
}
