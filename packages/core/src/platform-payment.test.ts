import { describe, expect, it } from 'vitest'
import { platformPaymentAmountTiyin, prepayDiscountPercent } from './platform-payment'

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
