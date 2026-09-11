import { describe, expect, it } from 'vitest'

import {
  MAX_INSTALLMENTS,
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
    expect(paymentState(400_000, 400_001)).toBe('overpaid')
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

  it('платежей больше, чем тыйынов: часть платежей — нулевые', () => {
    // Граница арифметики, не продукта: SQL отбивает такое ещё раньше
    // (amount_tiyin > 0), здесь важно, что сумма всё равно сходится.
    expect(splitInstallments(2, 3)).toEqual([1, 1, 0])
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

describe('installmentState — зеркало installments_notify', () => {
  it('оплаченный — paid независимо от дат', () => {
    expect(installmentState('2026-08-01', '2026-08-15T10:00:00+06:00', '2026-09-11')).toBe('paid')
  })

  it('срок в будущем — upcoming', () => {
    expect(installmentState('2026-09-12', null, '2026-09-11')).toBe('upcoming')
  })

  it('срок сегодня — due (событие installment.due)', () => {
    expect(installmentState('2026-09-11', null, '2026-09-11')).toBe('due')
  })

  it('срок вчера — overdue (чек-лист п.5, событие installment.overdue)', () => {
    expect(installmentState('2026-09-10', null, '2026-09-11')).toBe('overdue')
  })

  it('дата не в формате YYYY-MM-DD — ошибка', () => {
    expect(() => installmentState('10.09.2026', null, '2026-09-11')).toThrow(RangeError)
  })
})
