import { describe, expect, it } from 'vitest'
import { planSwitchDays, platformPaymentAmountTiyin, prepayDiscountPercent } from './platform-payment'

// Те же случаи — в packages/db/supabase/tests/0084_platform_prepay_discount.test.sql.
const CASES: Array<[price: number, months: number, discount: number, amount: number]> = [
  [99000, 1, 0, 99000],
  [99000, 5, 0, 495000],
  [99000, 6, 10, 534600],
  [390000, 11, 10, 3861000],
  [390000, 12, 20, 3744000],
  [790000, 24, 20, 15168000],
  [12345, 6, 10, 66663],
  // 86415 × 0,9 = 77773,5 тыйына — половина округляется вверх.
  [12345, 7, 10, 77774],
]

describe('скидка за предоплату тарифа (0084)', () => {
  it.each(CASES)('цена %i × %i мес. — скидка %i %%, сумма %i', (price, months, discount, amount) => {
    expect(prepayDiscountPercent(months)).toBe(discount)
    expect(platformPaymentAmountTiyin(price, months)).toBe(amount)
  })
})

// Те же случаи — в packages/db/supabase/tests/0096_plan_switch_proration.test.sql.
const SWITCH_CASES: Array<[days: number, oldPrice: number, newPrice: number, result: number]> = [
  [30, 390000, 790000, 15], // Studio → Center: 30 × 3900 / 7900 = 14,81 → 15
  [30, 790000, 390000, 61], // Center → Studio: 60,77 → 61
  [10, 390000, 99000, 39], // Studio → Solo: 39,39 → 39
  [0, 390000, 790000, 0],
  [12, 0, 790000, 0], // бесплатный старый тариф — остаток сгорает
  [1, 1, 2, 1], // ровно половина — вверх
  [3, 1, 2, 2], // 1,5 → 2
]

describe('planSwitchDays — зеркало plan_switch_days (0096)', () => {
  it.each(SWITCH_CASES)('%i дн. по %i → по %i = %i дн.', (days, oldPrice, newPrice, result) => {
    expect(planSwitchDays(days, oldPrice, newPrice)).toBe(result)
  })
})
