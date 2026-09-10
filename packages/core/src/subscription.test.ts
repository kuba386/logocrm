import { describe, expect, it } from 'vitest'

import {
  canDeduct,
  freezeShift,
  isExhausted,
  isOverdrawn,
  isRunningOut,
  lessonPrice,
  lessonsLeft,
  refundAmount,
  type SubscriptionSnapshot,
} from './subscription'

const pack = (over: Partial<SubscriptionSnapshot> = {}): SubscriptionSnapshot => ({
  lessonsTotal: 8,
  lessonsUsed: 0,
  lessonsWrittenOff: 0,
  lessonPriceTiyin: 50_000,
  ...over,
})

describe('lessonPrice — общий набор случаев с pgTAP', () => {
  it('восемь занятий за 4000 сом дают 500 сом за занятие', () => {
    expect(lessonPrice(400_000, 8)).toBe(50_000)
  })

  it('округляет вниз: остаток от деления в пользу родителя', () => {
    expect(lessonPrice(100_000, 3)).toBe(33_333)
  })

  it('ноль занятий — ошибка, а не деление на ноль', () => {
    expect(() => lessonPrice(100_000, 0)).toThrow(RangeError)
  })
})

describe('lessonsLeft', () => {
  it('вычитает и посещения, и списанное без посещения', () => {
    expect(lessonsLeft(pack({ lessonsUsed: 3, lessonsWrittenOff: 2 }))).toBe(3)
  })

  it('безлимит — это null, а не ноль', () => {
    expect(lessonsLeft(pack({ lessonsTotal: null }))).toBeNull()
  })

  it('перерасход даёт отрицательный остаток, а не ноль', () => {
    expect(lessonsLeft(pack({ lessonsUsed: 10 }))).toBe(-2)
  })
})

describe('refundAmount', () => {
  it('остаток три занятия по 500 сом — 1500 сом', () => {
    expect(refundAmount(pack({ lessonsUsed: 5 }))).toBe(150_000)
  })

  it('исчерпанный абонемент возврата не даёт', () => {
    expect(refundAmount(pack({ lessonsUsed: 8 }))).toBe(0)
  })

  it('перерасход не превращается в отрицательный возврат', () => {
    expect(refundAmount(pack({ lessonsUsed: 10 }))).toBe(0)
  })

  it('безлимит возврата по занятиям не имеет', () => {
    expect(refundAmount(pack({ lessonsTotal: null }))).toBe(0)
  })
})

describe('freezeShift', () => {
  it('сдвигает дату на длительность заморозки', () => {
    expect(freezeShift('2026-10-05', 7)).toBe('2026-10-12')
  })

  it('переносит через границу месяца', () => {
    expect(freezeShift('2026-10-28', 7)).toBe('2026-11-04')
  })

  it('переносит через границу года', () => {
    expect(freezeShift('2026-12-28', 7)).toBe('2027-01-04')
  })

  it('високосный февраль считается календарём, а не 30-дневками', () => {
    expect(freezeShift('2028-02-26', 4)).toBe('2028-03-01')
  })

  it('нулевая заморозка не двигает дату', () => {
    expect(freezeShift('2026-10-05', 0)).toBe('2026-10-05')
  })

  it('отрицательная длительность — ошибка', () => {
    expect(() => freezeShift('2026-10-05', -1)).toThrow(RangeError)
  })

  it('дата не в формате YYYY-MM-DD — ошибка', () => {
    expect(() => freezeShift('05.10.2026', 7)).toThrow(RangeError)
  })
})

describe('isRunningOut и isExhausted', () => {
  it('остаток два — заканчивается', () => {
    expect(isRunningOut(pack({ lessonsUsed: 6 }))).toBe(true)
  })

  it('остаток три — ещё нет', () => {
    expect(isRunningOut(pack({ lessonsUsed: 5 }))).toBe(false)
  })

  it('исчерпанный не «заканчивается», а именно исчерпан', () => {
    const sub = pack({ lessonsUsed: 8 })
    expect(isRunningOut(sub)).toBe(false)
    expect(isExhausted(sub)).toBe(true)
  })

  it('безлимит не заканчивается никогда', () => {
    const sub = pack({ lessonsTotal: null })
    expect(isRunningOut(sub)).toBe(false)
    expect(isExhausted(sub)).toBe(false)
  })

})

// Общий набор случаев с pgTAP 0010 (пункт «те же входные данные»):
// total=8, used/allowNegative варьируются. Меняется одна сторона — меняется обе.
describe('isExhausted / canDeduct / isOverdrawn — зеркало subscription_state и селектора', () => {
  it.each([
    // used, allowNegative, exhausted, canDeduct, overdrawn
    [0, false, false, true, false],
    [6, false, false, true, false],
    [8, false, true, false, false],
    [8, true, true, true, false],
    [11, true, true, true, true],
    [11, false, true, false, true],
  ])('used=%i allowNegative=%s → exhausted=%s canDeduct=%s overdrawn=%s', (used, allowNegative, ex, cd, od) => {
    const sub = pack({ lessonsUsed: used, allowNegative })
    expect(isExhausted(sub)).toBe(ex)
    expect(canDeduct(sub)).toBe(cd)
    expect(isOverdrawn(sub)).toBe(od)
  })

  it('безлимит: не исчерпан, списывать можно, в минусе не бывает', () => {
    const sub = pack({ lessonsTotal: null, lessonsUsed: 100 })
    expect(isExhausted(sub)).toBe(false)
    expect(canDeduct(sub)).toBe(true)
    expect(isOverdrawn(sub)).toBe(false)
  })
})
