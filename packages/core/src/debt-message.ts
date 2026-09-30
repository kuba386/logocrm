import { formatSom } from './money'

/**
 * Выбор текста WhatsApp для карточки /app/debts. Денег не считает: все суммы и
 * признак zeroLeft — поля RPC student_debt_page (0078; строки — из
 * student_debt_problems, 0076), здесь только выбор фразы. Вынесено из
 * страницы, чтобы покрыть Vitest.
 */
export type DebtMessageRow = {
  studentName: string
  /** Текущий плательщик ребёнка — тот, чей WhatsApp на карточке. */
  payerId: string | null
  debtTiyin: number
  overdrawnTiyin: number
  subscriptionOverdueTiyin: number
  /**
   * Плательщик просроченного абонемента (0070). NULL — просрочки нет либо
   * просрочены абонементы разных плательщиков: тогда адресата нет.
   */
  subscriptionOverduePayerId: string | null
  /** Исчерпанный остаток без денежных проблем — из SQL (0076). */
  zeroLeft: boolean
}

/**
 * Просрочку абонемента упоминаем, только если платить по нему должен ТОТ ЖЕ
 * человек, чей это WhatsApp — иначе требование денег уйдёт не тому плательщику
 * (архитектор-ревью 0070, находка №6). Два NULL — не совпадение.
 */
export function subscriptionOverdueAddressable(row: DebtMessageRow): boolean {
  return (
    row.subscriptionOverdueTiyin > 0 &&
    row.payerId !== null &&
    row.subscriptionOverduePayerId === row.payerId
  )
}

/**
 * Текст сообщения текущему плательщику или null — «кнопку не показывать».
 * null, когда единственная проблема — просрочка чужого абонемента: сказать
 * этому человеку нечего, а «закончился абонемент» было бы неправдой.
 */
export function debtWhatsappMessage(row: DebtMessageRow): string | null {
  const parts: string[] = []
  if (row.debtTiyin > 0) parts.push(`долг за занятия ${formatSom(row.debtTiyin)}`)
  if (row.overdrawnTiyin > 0) parts.push(`перерасход по абонементу ${formatSom(row.overdrawnTiyin)}`)
  if (subscriptionOverdueAddressable(row)) {
    parts.push(`просроченный платёж за абонемент ${formatSom(row.subscriptionOverdueTiyin)}`)
  }

  if (parts.length > 0) {
    return `Здравствуйте! У ${row.studentName} ${parts.join(' и ')} в LogoCRM. Пожалуйста, оплатите при возможности.`
  }
  if (row.zeroLeft) return `Здравствуйте! У ${row.studentName} закончился абонемент. Хотите продлить?`
  return null
}
