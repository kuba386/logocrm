import { describe, expect, it } from 'vitest'
import { formatSom } from './money'
import { debtSummaryLine, debtTopAmountLine, parseDebtSummary } from './debt-summary'

const sample = {
  debtors_n: 4,
  usage_n: 2,
  usage_tiyin: 140000,
  overdue_n: 2,
  overdue_tiyin: 100000,
  zero_n: 1,
  top: [
    { student_id: 'a', name: 'Аня', usage_tiyin: 50000, overdue_tiyin: 0, zero_left: false },
    { student_id: 'b', name: 'Боря', usage_tiyin: 0, overdue_tiyin: 55000, zero_left: false },
    { student_id: 'c', name: 'Вера', usage_tiyin: 0, overdue_tiyin: 0, zero_left: true },
  ],
}

describe('parseDebtSummary', () => {
  it('разбирает ответ student_debt_summary (случай совпадает с pgTAP 0076)', () => {
    const s = parseDebtSummary(sample)
    expect(s.debtorsN).toBe(4)
    expect(s.usageTiyin).toBe(140000)
    expect(s.overdueTiyin).toBe(100000)
    expect(s.zeroN).toBe(1)
    expect(s.top.map((r) => r.studentId)).toEqual(['a', 'b', 'c'])
    expect(s.top[2]?.zeroLeft).toBe(true)
  })

  it.each([null, undefined, 5, 'x', [], {}])('мусор %j даёт пустые итоги, а не исключение', (value) => {
    expect(parseDebtSummary(value).debtorsN).toBe(0)
    expect(parseDebtSummary(value).top).toEqual([])
  })

  it('строки топа без student_id отбрасываются, нечисловые суммы — нули', () => {
    const s = parseDebtSummary({ top: [{ name: 'без id' }, { student_id: 'z', usage_tiyin: 'много' }] })
    expect(s.top).toEqual([{ studentId: 'z', name: '—', usageTiyin: 0, overdueTiyin: 0, zeroLeft: false }])
  })
})

describe('подписи', () => {
  it('две суммы раздельно, не общий итог', () => {
    const line = debtSummaryLine(parseDebtSummary(sample))
    expect(line).toContain(`долг за занятия ${formatSom(140000)}`)
    expect(line).toContain(`просрочка по абонементам ${formatSom(100000)}`)
    expect(line).not.toContain(formatSom(240000))
  })

  it('пусто, когда нет ни одной денежной корзины', () => {
    expect(debtSummaryLine(parseDebtSummary({ zero_n: 3 }))).toBe('')
  })

  it('строка топа: долг и просрочка раздельно', () => {
    const [a, b] = parseDebtSummary(sample).top
    expect(debtTopAmountLine(a!)).toBe(formatSom(50000))
    expect(debtTopAmountLine(b!)).toBe(`просрочка ${formatSom(55000)}`)
  })
})
