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
 *
 * Исключение — ячейка, которая целиком число («-500,00»: возврат, штраф):
 * минус сам по себе формулу не образует, а с префиксом возвраты стали бы
 * текстом и выпали из СУММ у бухгалтера — итог не сошёлся бы с
 * cash_by_source ровно на сумму возвратов.
 */
export type CsvCell = string | number | boolean | null | undefined

const FORMULA_PREFIX = /^[=+\-@\t\r]/
const PLAIN_NUMBER = /^-?\d+([.,]\d+)?$/

export function csvEscape(value: CsvCell): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'boolean') return value ? 'да' : 'нет'
  let text = typeof value === 'number' ? String(value) : value
  if (FORMULA_PREFIX.test(text) && !PLAIN_NUMBER.test(text)) text = `'${text}`
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
