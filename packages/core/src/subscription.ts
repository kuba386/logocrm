import { lessonPrice } from './money'

/**
 * Расчёты по абонементам. Зеркало SQL, не вторая реализация.
 *
 * Источник истины — база: calc_lesson_price, subscription_lessons_left,
 * refund_calc в миграции 0008. Здесь то же самое для мгновенной подсказки в
 * браузере, пока сервер не ответил. Меняешь одну сторону — меняешь обе, и
 * общий набор случаев гоняется в Vitest и в pgTAP с одинаковыми входными
 * данными.
 *
 * Деньги — целые тыйыны. Никаких дробей: 1 сом = 100 тыйынов.
 */

export type SubscriptionKind = 'lessons' | 'period' | 'unlimited'

export type SubscriptionSnapshot = {
  /** Продано занятий. null — безлимит. */
  lessonsTotal: number | null
  /** Списано посещениями. */
  lessonsUsed: number
  /** Списано без посещения: перенос, возврат. */
  lessonsWrittenOff: number
  /** Цена одного занятия, замороженная при продаже. */
  lessonPriceTiyin: number | null
  /**
   * Разрешено уйти в минус. Такой абонемент не считается исчерпанным при
   * нулевом остатке — списание продолжается в отрицательный баланс, а не в
   * долг по цене услуги. Зеркало subscription_state в 0010.
   */
  allowNegative?: boolean
}

/**
 * Остаток занятий. null — безлимит, а не «ноль»: это разные вещи, и
 * интерфейс показывает их по-разному.
 */
export function lessonsLeft(sub: SubscriptionSnapshot): number | null {
  if (sub.lessonsTotal === null) return null
  return sub.lessonsTotal - sub.lessonsUsed - sub.lessonsWrittenOff
}

/**
 * Сумма возврата: остаток × цена занятия.
 *
 * Цена берётся замороженная, а не пересчитанная от текущей цены абонемента.
 * Иначе правка цены задним числом меняла бы сумму возврата, и объяснить
 * родителю разницу было бы нечем.
 */
export function refundAmount(sub: SubscriptionSnapshot): number {
  const left = lessonsLeft(sub)
  if (left === null || left <= 0) return 0
  return left * (sub.lessonPriceTiyin ?? 0)
}

/**
 * Новая дата окончания после заморозки: срок сдвигается на её длительность.
 *
 * Считается по календарным дням в часовом поясе центра. Дата на входе и
 * выходе — строка YYYY-MM-DD, а не Date: Date в браузере живёт в поясе
 * браузера, и у администратора из поездки срок съезжал бы на день.
 */
export function freezeShift(endsAt: string, days: number): string {
  if (!Number.isInteger(days) || days < 0) {
    throw new RangeError('Длительность заморозки — целое число дней, не меньше нуля')
  }
  const [y, m, d] = endsAt.split('-').map(Number)
  if (!y || !m || !d) throw new RangeError(`Дата должна быть в формате YYYY-MM-DD, получено «${endsAt}»`)

  // UTC-конструктор намеренно: арифметика по календарным дням без
  // вмешательства локального пояса и переходов на летнее время.
  const date = new Date(Date.UTC(y, m - 1, d))
  date.setUTCDate(date.getUTCDate() + days)
  return date.toISOString().slice(0, 10)
}

/**
 * Заканчивается ли абонемент: остаток не больше порога.
 *
 * Безлимитный не заканчивается никогда — возвращает false, а не «0 ≤ 2».
 * С allow_negative порог тоже показывается: родителю полезно знать, что
 * оплаченное кончилось, даже если списание продолжится.
 */
export function isRunningOut(sub: SubscriptionSnapshot, threshold = 2): boolean {
  const left = lessonsLeft(sub)
  return left !== null && left <= threshold && left > 0
}

/**
 * Исчерпан ли абонемент. Безлимитный — никогда; с allow_negative — тоже
 * никогда: флаг означает «списывать дальше в минус», и база (subscription_state)
 * продолжает выбирать такой абонемент для списания. Иначе TypeScript показал
 * бы «исчерпан», а SQL списал бы следующее занятие — два источника истины.
 */
export function isExhausted(sub: SubscriptionSnapshot): boolean {
  if (sub.allowNegative) return false
  const left = lessonsLeft(sub)
  return left !== null && left <= 0
}

/**
 * Цена занятия при продаже. Прямой реэкспорт из money: одна формула на
 * проект, а не копия рядом.
 */
export { lessonPrice }
