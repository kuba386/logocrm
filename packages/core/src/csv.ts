import { toSom } from './money'

/**
 * CSV для Excel в русской локали: разделитель «;», строки через CRLF,
 * UTF-8 с BOM (без него Excel читает кириллицу как мусор), суммы с
 * десятичной запятой (с «;» русский Excel иначе примет «1234.50» как текст).
 *
 * Ячейка, начинающаяся с =, +, -, @, табуляции или CR, — формула для
 * Excel/LibreOffice: плательщик, записанный как «=HYPERLINK(...)», уведёт
 * контакты семей с машины бухгалтера мимо всей RLS. Такие ячейки получают
 * префикс «'» (0058 Р8) — читаемо и безопасно.
 */
export type CsvCell = string | number | boolean | null | undefined

const FORMULA_PREFIX = /^[=+\-@\t\r]/

export function csvEscape(value: CsvCell): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'boolean') return value ? 'да' : 'нет'
  let text = typeof value === 'number' ? String(value) : value
  if (FORMULA_PREFIX.test(text)) text = `'${text}`
  if (/[";\r\n]/.test(text)) text = `"${text.replace(/"/g, '""')}"`
  return text
}

export function toCsv(headers: string[], rows: CsvCell[][]): string {
  const lines = [headers, ...rows].map((row) => row.map(csvEscape).join(';'))
  return `﻿${lines.join('\r\n')}\r\n`
}

/** Тыйыны → «1234,50»: число для русского Excel, не строка. */
export function csvMoney(tiyin: number | null | undefined): string {
  if (tiyin === null || tiyin === undefined) return ''
  const som = toSom(tiyin)
  return som.toFixed(2).replace('.', ',')
}

/** ISO-дата (YYYY-MM-DD) → «ДД.ММ.ГГГГ»; дата приходит из SQL уже в поясе центра. */
export function csvDate(isoDate: string | null | undefined): string {
  if (!isoDate) return ''
  const [y, m, d] = isoDate.slice(0, 10).split('-')
  if (!y || !m || !d) return isoDate
  return `${d}.${m}.${y}`
}
