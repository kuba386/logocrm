/**
 * Пояс центра из centers.settings->>'timezone' — зеркало SQL-функции
 * public.center_timezone() (0086). SQL — источник истины, это зеркало для
 * браузера и сервера Next: одно правило в обоих местах, иначе база считает в
 * одном поясе, а экран показывает в другом (или падает на RangeError).
 *
 * Правило: принимаем только имена IANA вида «Область/Место» и «UTC», которые
 * среда действительно знает (в SQL — `at time zone`, здесь — Intl). Всё
 * прочее — Asia/Bishkek. Аббревиатуры (MSK), смещения (+6, UTC+6, +06:00) и
 * POSIX-строки отсекаются до проверки: Postgres читает их по POSIX со знаком
 * наоборот («+6» — это UTC−6), а Intl — по ISO, и база с экраном разошлись
 * бы на 12 часов.
 */
export const DEFAULT_CENTER_TIME_ZONE = 'Asia/Bishkek'

/** То же выражение — в 0086_center_timezone_fast.sql. */
export const CENTER_TIME_ZONE_PATTERN = /^(UTC|[A-Z][A-Za-z_]+(\/[A-Za-z0-9_+-]+)+)$/

export const CENTER_TIME_ZONE_MAX_LENGTH = 64

export function centerTimeZoneName(value: unknown): string {
  if (typeof value !== 'string') return DEFAULT_CENTER_TIME_ZONE
  if (value.length > CENTER_TIME_ZONE_MAX_LENGTH || !CENTER_TIME_ZONE_PATTERN.test(value)) {
    return DEFAULT_CENTER_TIME_ZONE
  }
  try {
    new Intl.DateTimeFormat('ru-RU', { timeZone: value })
    return value
  } catch {
    return DEFAULT_CENTER_TIME_ZONE
  }
}

/**
 * Общий набор случаев: те же входы в Vitest (timezone.test.ts) и в pgTAP
 * (0086_center_timezone_fast.test.sql). Меняешь правило — меняешь обе стороны.
 */
export const CENTER_TIME_ZONE_CASES: ReadonlyArray<readonly [input: unknown, expected: string]> = [
  ['Asia/Bishkek', 'Asia/Bishkek'],
  ['Europe/Moscow', 'Europe/Moscow'],
  ['America/Argentina/Buenos_Aires', 'America/Argentina/Buenos_Aires'],
  ['Etc/GMT+6', 'Etc/GMT+6'],
  ['UTC', 'UTC'],
  ['', DEFAULT_CENTER_TIME_ZONE],
  [6, DEFAULT_CENTER_TIME_ZONE],
  [null, DEFAULT_CENTER_TIME_ZONE],
  ['Mars/Olympus', DEFAULT_CENTER_TIME_ZONE],
  ['MSK', DEFAULT_CENTER_TIME_ZONE],
  ['Z', DEFAULT_CENTER_TIME_ZONE],
  ['UTC+6', DEFAULT_CENTER_TIME_ZONE],
  ['+6', DEFAULT_CENTER_TIME_ZONE],
  ['+06:00', DEFAULT_CENTER_TIME_ZONE],
  ['Factory', DEFAULT_CENTER_TIME_ZONE],
  ['EST5EDT', DEFAULT_CENTER_TIME_ZONE],
  ['asia/bishkek', DEFAULT_CENTER_TIME_ZONE],
  ['posix/Asia/Bishkek', DEFAULT_CENTER_TIME_ZONE],
  ['Asia/../Bishkek', DEFAULT_CENTER_TIME_ZONE],
  [`Asia/${'X'.repeat(300)}`, DEFAULT_CENTER_TIME_ZONE],
]
