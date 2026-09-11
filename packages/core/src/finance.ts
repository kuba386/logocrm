/**
 * Оплата абонемента и рассрочка. Зеркало SQL, не вторая реализация.
 *
 * Источник истины — база: subscriptions.paid_tiyin (триггер
 * payments_recalc_paid, 0013), create_installment_plan / installments_notify /
 * subscription_payment_summary (0018). Здесь то же самое для мгновенной
 * подсказки в браузере — деньги в интерфейсе не считаются, суммы и статусы
 * всегда приходят из RPC. Меняешь одну сторону — меняешь обе; общий набор
 * случаев гоняется в Vitest и в pgTAP 0018 с одинаковыми входными данными.
 *
 * Деньги — целые тыйыны. Даты — строки YYYY-MM-DD в поясе центра.
 */

export type PaymentState = 'unpaid' | 'partial' | 'paid' | 'overpaid'

/**
 * Оплачен ли абонемент: сравнение paid_tiyin с ценой. Бесплатный
 * (price 0) считается оплаченным — платить нечего, это не долг.
 * Зеркало subscription_payment_summary.payment_state.
 */
export function paymentState(priceTiyin: number, paidTiyin: number): PaymentState {
  assertInteger(priceTiyin, 'priceTiyin')
  assertInteger(paidTiyin, 'paidTiyin')
  if (priceTiyin < 0) throw new RangeError('Цена абонемента не может быть отрицательной')
  if (paidTiyin < 0) throw new RangeError('Оплачено не может быть отрицательным')
  if (paidTiyin > priceTiyin) return 'overpaid'
  if (paidTiyin === priceTiyin) return 'paid'
  if (paidTiyin === 0) return 'unpaid'
  return 'partial'
}

/** Сколько осталось доплатить. Переплата — ноль, не отрицательный долг. */
export function remainingTiyin(priceTiyin: number, paidTiyin: number): number {
  assertInteger(priceTiyin, 'priceTiyin')
  assertInteger(paidTiyin, 'paidTiyin')
  return Math.max(0, priceTiyin - paidTiyin)
}

export const MAX_INSTALLMENTS = 24

/**
 * Разбивка остатка на n платежей: целочисленно, сумма строго равна остатку,
 * остаток от деления уходит ПЕРВЫМ платежам (100 000 / 3 → 33 334, 33 333,
 * 33 333). Зеркало арифметики create_installment_plan.
 */
export function splitInstallments(totalTiyin: number, n: number): number[] {
  assertInteger(totalTiyin, 'totalTiyin')
  assertInteger(n, 'n')
  if (totalTiyin <= 0) throw new RangeError('Нечего рассрочивать: остаток должен быть больше нуля')
  if (n < 1 || n > MAX_INSTALLMENTS) {
    throw new RangeError(`Число платежей — от 1 до ${MAX_INSTALLMENTS}`)
  }
  const base = Math.trunc(totalTiyin / n)
  const extra = totalTiyin % n
  return Array.from({ length: n }, (_, i) => (i < extra ? base + 1 : base))
}

export type InstallmentState = 'paid' | 'upcoming' | 'due' | 'overdue'

/**
 * Состояние одного платежа рассрочки на дату центра. Зеркало правил
 * installments_notify: due — день в день, overdue — после. Оплаченный —
 * оплаченный независимо от дат.
 */
export function installmentState(dueDate: string, paidAt: string | null, today: string): InstallmentState {
  assertIsoDate(dueDate, 'dueDate')
  assertIsoDate(today, 'today')
  if (paidAt !== null) return 'paid'
  if (dueDate > today) return 'upcoming'
  if (dueDate === today) return 'due'
  return 'overdue'
}

function assertInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value)) {
    throw new TypeError(`${name}: ожидалось целое число, получено ${value}`)
  }
}

function assertIsoDate(value: string, name: string): void {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new RangeError(`${name}: ожидалась дата YYYY-MM-DD, получено «${value}»`)
  }
}
