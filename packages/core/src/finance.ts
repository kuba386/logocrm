/**
 * Оплата абонемента и рассрочка. Зеркало SQL, не вторая реализация.
 *
 * Источник истины — база: subscriptions.paid_tiyin (триггер
 * payments_recalc_paid, 0013), installments_view / create_installment_plan /
 * installments_notify / subscription_payment_summary (0018). Здесь то же
 * самое для мгновенной подсказки в браузере — деньги в интерфейсе не
 * считаются, суммы и статусы всегда приходят из RPC. Меняешь одну сторону —
 * меняешь обе; общий набор случаев гоняется в Vitest и в pgTAP 0018 с
 * одинаковыми входными данными.
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
 * 33 333). Платежей больше, чем тыйынов, — ошибка, а не нулевые строки:
 * SQL отвечает тем же 22023 (create_installment_plan).
 */
export function splitInstallments(totalTiyin: number, n: number): number[] {
  assertInteger(totalTiyin, 'totalTiyin')
  assertInteger(n, 'n')
  if (totalTiyin <= 0) throw new RangeError('Нечего рассрочивать: остаток должен быть больше нуля')
  if (n < 1 || n > MAX_INSTALLMENTS) {
    throw new RangeError(`Число платежей — от 1 до ${MAX_INSTALLMENTS}`)
  }
  if (n > totalTiyin) throw new RangeError('Платежей больше, чем тыйынов в остатке')
  const base = Math.trunc(totalTiyin / n)
  const extra = totalTiyin % n
  return Array.from({ length: n }, (_, i) => (i < extra ? base + 1 : base))
}

/**
 * Оплачена ли строка плана. Строка не хранит «оплачено»: она оплачена,
 * когда оплачено по абонементу всего не меньше, чем было оплачено на момент
 * плана (base) плюс сумма строк плана по эту включительно (cumulative).
 * Зеркало installments_view.state = 'paid'.
 */
export function installmentPaid(paidTiyin: number, basePaidTiyin: number, cumulativeTiyin: number): boolean {
  assertInteger(paidTiyin, 'paidTiyin')
  assertInteger(basePaidTiyin, 'basePaidTiyin')
  assertInteger(cumulativeTiyin, 'cumulativeTiyin')
  return paidTiyin >= basePaidTiyin + cumulativeTiyin
}

/**
 * Даты платежей плана: первая — как задана, каждая следующая — «+k месяцев
 * от первой», не цепочкой (31 января → 28 февраля → 31 марта, без дрейфа).
 * День сверх длины месяца прижимается к последнему дню — как date +
 * interval 'N months' в Postgres. Зеркало create_installment_plan;
 * арифметика в UTC по календарным дням, пояс браузера не участвует.
 */
export function installmentDueDates(firstDue: string, n: number, stepMonths = 1): string[] {
  assertIsoDate(firstDue, 'firstDue')
  assertInteger(n, 'n')
  assertInteger(stepMonths, 'stepMonths')
  if (n < 1 || n > MAX_INSTALLMENTS) throw new RangeError(`Число платежей — от 1 до ${MAX_INSTALLMENTS}`)
  if (stepMonths < 1) throw new RangeError('Шаг рассрочки — целое число месяцев, не меньше одного')

  const [y, m, d] = firstDue.split('-').map(Number) as [number, number, number]
  return Array.from({ length: n }, (_, i) => {
    const months = (m - 1) + i * stepMonths
    const year = y + Math.floor(months / 12)
    const month = months % 12 // 0..11
    const lastDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate()
    const day = Math.min(d, lastDay)
    return new Date(Date.UTC(year, month, day)).toISOString().slice(0, 10)
  })
}

export type InstallmentState = 'paid' | 'upcoming' | 'due' | 'overdue'

/**
 * Состояние неотменённой строки на дату центра. Зеркало installments_view:
 * due — день в день, overdue — после; оплаченная — оплаченная независимо
 * от дат. Отменённые строки сюда не попадают — у них своё состояние.
 */
export function installmentState(dueDate: string, paid: boolean, today: string): InstallmentState {
  assertIsoDate(dueDate, 'dueDate')
  assertIsoDate(today, 'today')
  if (paid) return 'paid'
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
