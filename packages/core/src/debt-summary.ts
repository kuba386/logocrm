import { formatSom } from './money'

/**
 * Итоги долгов из SQL-функции student_debt_summary (0076). Считает SQL:
 * PostgREST режет ответ по max_rows, итоги по строкам в браузере усекались бы
 * молча и расходились с ботом. Здесь только разбор jsonb в типизированную
 * форму и подпись — денег не считаем.
 */
export type DebtTopRow = {
  studentId: string
  name: string
  /** Долг за занятия = долг + перерасход. */
  usageTiyin: number
  /** Просрочка по абонементу — другие деньги, с долгом не складывается. */
  overdueTiyin: number
  zeroLeft: boolean
}

export type DebtSummary = {
  /** Уникальные дети с денежной проблемой (исчерпанный остаток без долга не входит). */
  debtorsN: number
  usageN: number
  usageTiyin: number
  overdueN: number
  overdueTiyin: number
  zeroN: number
  top: DebtTopRow[]
}

// Свежий объект на каждый вызов: модуль серверного компонента живёт между запросами, общий
// объект с массивом можно было бы испортить мутацией.
function empty(): DebtSummary {
  return { debtorsN: 0, usageN: 0, usageTiyin: 0, overdueN: 0, overdueTiyin: 0, zeroN: 0, top: [] }
}

function num(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function parseDebtSummary(json: unknown): DebtSummary {
  if (!isRecord(json)) return empty()
  const top = Array.isArray(json.top) ? json.top : []
  return {
    debtorsN: num(json.debtors_n),
    usageN: num(json.usage_n),
    usageTiyin: num(json.usage_tiyin),
    overdueN: num(json.overdue_n),
    overdueTiyin: num(json.overdue_tiyin),
    zeroN: num(json.zero_n),
    top: top.flatMap((item): DebtTopRow[] => {
      if (!isRecord(item) || typeof item.student_id !== 'string') return []
      return [
        {
          studentId: item.student_id,
          name: typeof item.name === 'string' ? item.name : '—',
          usageTiyin: num(item.usage_tiyin),
          overdueTiyin: num(item.overdue_tiyin),
          zeroLeft: item.zero_left === true,
        },
      ]
    }),
  }
}

/** Подпись карточки: две суммы раздельно, а не общий итог. */
export function debtSummaryLine(summary: DebtSummary): string {
  const parts: string[] = []
  if (summary.usageN > 0) parts.push(`долг за занятия ${formatSom(summary.usageTiyin)}`)
  if (summary.overdueN > 0) parts.push(`просрочка по абонементам ${formatSom(summary.overdueTiyin)}`)
  return parts.join(' · ')
}

/** Строка топа: суммы корзин раздельно; максимум двух корзин — только ключ порядка в SQL. */
export function debtTopAmountLine(row: DebtTopRow): string {
  const parts: string[] = []
  if (row.usageTiyin > 0) parts.push(formatSom(row.usageTiyin))
  if (row.overdueTiyin > 0) parts.push(`просрочка ${formatSom(row.overdueTiyin)}`)
  return parts.join(' · ')
}
