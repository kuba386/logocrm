import { describe, expect, it } from 'vitest'

import {
  MAX_INSTALLMENTS,
  installmentDueDates,
  installmentPaid,
  installmentState,
  paymentState,
  remainingTiyin,
  splitInstallments,
} from './finance'

// Общий набор случаев с pgTAP 0018: чек-лист этапа — абонемент 4 000 сом,
// оплата 2 000, рассрочка 2 × 1 000. Меняется одна сторона — меняется обе.

describe('paymentState — зеркало subscription_payment_summary', () => {
  it('4 000 сом продано, 2 000 оплачено — частичная оплата (чек-лист п.1)', () => {
    expect(paymentState(400_000, 200_000)).toBe('partial')
  })

  it('ничего не оплачено — unpaid', () => {
    expect(paymentState(400_000, 0)).toBe('unpaid')
  })

  it('оплачено ровно — paid', () => {
    expect(paymentState(400_000, 400_000)).toBe('paid')
  })

  it('переплата — overpaid, не paid', () => {
    expect(paymentState(400_000, 450_000)).toBe('overpaid')
  })

  it('бесплатный абонемент — оплачен, а не «не оплачен»', () => {
    expect(paymentState(0, 0)).toBe('paid')
  })

  it('дробные и отрицательные значения — ошибка', () => {
    expect(() => paymentState(400_000.5, 0)).toThrow(TypeError)
    expect(() => paymentState(-1, 0)).toThrow(RangeError)
    expect(() => paymentState(400_000, -1)).toThrow(RangeError)
  })
})

describe('remainingTiyin', () => {
  it('остаток к доплате', () => {
    expect(remainingTiyin(400_000, 200_000)).toBe(200_000)
  })

  it('переплата — ноль, не отрицательный долг', () => {
    expect(remainingTiyin(400_000, 500_000)).toBe(0)
  })
})

describe('splitInstallments — зеркало create_installment_plan', () => {
  it('остаток 2 000 сом на 2 платежа — по 1 000 (чек-лист п.1)', () => {
    expect(splitInstallments(200_000, 2)).toEqual([100_000, 100_000])
  })

  it('остаток от деления уходит первым платежам: 100 000 / 3', () => {
    expect(splitInstallments(100_000, 3)).toEqual([33_334, 33_333, 33_333])
  })

  it('сумма платежей всегда равна остатку', () => {
    for (const [total, n] of [
      [100_000, 3],
      [123_457, 7],
      [1, 1],
      [25, 24],
    ] as const) {
      const parts = splitInstallments(total, n)
      expect(parts).toHaveLength(n)
      expect(parts.reduce((s, p) => s + p, 0)).toBe(total)
    }
  })

  it('один платёж — весь остаток', () => {
    expect(splitInstallments(150_000, 1)).toEqual([150_000])
  })

  it('платежей больше, чем тыйынов в остатке — ошибка, как 22023 в SQL (тест 7 pgTAP)', () => {
    expect(() => splitInstallments(2, 3)).toThrow(RangeError)
  })

  it('нулевой или отрицательный остаток — ошибка, а не пустой план', () => {
    expect(() => splitInstallments(0, 2)).toThrow(RangeError)
    expect(() => splitInstallments(-100, 2)).toThrow(RangeError)
  })

  it(`число платежей вне 1..${MAX_INSTALLMENTS} — ошибка`, () => {
    expect(() => splitInstallments(100_000, 0)).toThrow(RangeError)
    expect(() => splitInstallments(100_000, MAX_INSTALLMENTS + 1)).toThrow(RangeError)
    expect(() => splitInstallments(100_000, 1.5)).toThrow(TypeError)
  })
})

describe('installmentPaid — зеркало installments_view.state = paid', () => {
  // Чек-лист: аванс 200 000 до плана (base), план 2 × 100 000.
  it('аванс до плана не закрывает первую строку: 200 000 < 200 000 + 100 000', () => {
    expect(installmentPaid(200_000, 200_000, 100_000)).toBe(false)
  })

  it('после платежа по первой строке она оплачена, вторая — нет (тесты 15-17 pgTAP)', () => {
    expect(installmentPaid(300_000, 200_000, 100_000)).toBe(true)
    expect(installmentPaid(300_000, 200_000, 200_000)).toBe(false)
  })

  it('свободный платёж мимо плана закрывает вторую строку (тест 24 pgTAP)', () => {
    expect(installmentPaid(400_000, 200_000, 200_000)).toBe(true)
  })

  it('план без аванса: base 0', () => {
    expect(installmentPaid(0, 0, 100_000)).toBe(false)
    expect(installmentPaid(100_000, 0, 100_000)).toBe(true)
  })
})

describe('installmentDueDates — зеркало календаря create_installment_plan', () => {
  it('31 января: февраль прижимается к 28-му, март снова 31-е — без дрейфа цепочкой', () => {
    expect(installmentDueDates('2026-01-31', 3)).toEqual(['2026-01-31', '2026-02-28', '2026-03-31'])
  })

  it('високосный февраль — 29-е', () => {
    expect(installmentDueDates('2028-01-31', 2)).toEqual(['2028-01-31', '2028-02-29'])
  })

  it('те же входные данные, что pgTAP 0018 (sub7): 2030-01-31 на 3', () => {
    expect(installmentDueDates('2030-01-31', 3)).toEqual(['2030-01-31', '2030-02-28', '2030-03-31'])
  })

  it('шаг два месяца и переход через год', () => {
    expect(installmentDueDates('2026-11-15', 3, 2)).toEqual(['2026-11-15', '2027-01-15', '2027-03-15'])
  })

  it('один платёж — одна дата', () => {
    expect(installmentDueDates('2026-09-11', 1)).toEqual(['2026-09-11'])
  })

  it('границы: n вне 1..24, шаг 0, дата не в формате — ошибка', () => {
    expect(() => installmentDueDates('2026-09-11', 0)).toThrow(RangeError)
    expect(() => installmentDueDates('2026-09-11', 25)).toThrow(RangeError)
    expect(() => installmentDueDates('2026-09-11', 2, 0)).toThrow(RangeError)
    expect(() => installmentDueDates('11.09.2026', 2)).toThrow(RangeError)
  })
})

describe('installmentState — зеркало installments_view', () => {
  it('оплаченная — paid независимо от дат', () => {
    expect(installmentState('2026-08-01', true, '2026-09-11')).toBe('paid')
  })

  it('срок в будущем — upcoming', () => {
    expect(installmentState('2026-09-12', false, '2026-09-11')).toBe('upcoming')
  })

  it('срок сегодня — due (событие installment.due)', () => {
    expect(installmentState('2026-09-11', false, '2026-09-11')).toBe('due')
  })

  it('срок вчера — overdue (чек-лист п.5, событие installment.overdue)', () => {
    expect(installmentState('2026-09-10', false, '2026-09-11')).toBe('overdue')
  })

  it('дата не в формате YYYY-MM-DD — ошибка', () => {
    expect(() => installmentState('10.09.2026', false, '2026-09-11')).toThrow(RangeError)
  })
})
