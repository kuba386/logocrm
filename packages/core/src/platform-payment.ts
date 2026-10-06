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

/**
 * Оставшиеся оплаченные дни старого тарифа в днях нового (0096): дни × цена
 * месяца старого / нового, округление до дня (половина вверх, как round в
 * Postgres для numeric); бесплатный старый — 0 (остаток сгорает). Зеркало
 * plan_switch_days — только для подсказки в форме; срок считает база.
 */
export function planSwitchDays(remainingDays: number, oldPriceTiyin: number, newPriceTiyin: number): number {
  if (remainingDays <= 0) return 0
  if (oldPriceTiyin <= 0) return 0
  if (newPriceTiyin <= 0) return remainingDays
  return Math.floor((remainingDays * oldPriceTiyin) / newPriceTiyin + 0.5)
}
