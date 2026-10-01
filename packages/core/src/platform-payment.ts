/**
 * Скидка за предоплату тарифа платформы (0084): от 6 месяцев — 10 %, от 12 —
 * 20 %. Источник истины — platform_prepay_discount_pct / platform_payment_amount
 * в SQL (сумму заявки считает submit_platform_payment); это зеркало только
 * для подсказки на странице тарифа. Общие случаи — в тесте рядом и в
 * tests/0084.
 */
export function prepayDiscountPercent(months: number): number {
  if (months >= 12) return 20
  if (months >= 6) return 10
  return 0
}

/** Сумма заявки в тыйынах: цена × месяцы со скидкой, округление до тыйына вверх от половины. */
export function platformPaymentAmountTiyin(priceTiyin: number, months: number): number {
  const discount = prepayDiscountPercent(months)
  return Math.trunc((priceTiyin * months * (100 - discount) + 50) / 100)
}
