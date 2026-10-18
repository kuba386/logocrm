import { formatSom } from './money'

/**
 * Вид метки панели отметки — из lesson_attendance_balances (0103). Абонемент
 * подбирает база с учётом услуги и даты занятия; здесь только текст.
 */
export type AttendanceBalanceKind =
  | 'subscription'
  | 'subscription_low'
  | 'subscription_empty'
  | 'charged'
  | 'frozen'
  | 'no_subscription'
  | 'no_service'
  | 'free'
  | 'debt'
  | 'covered'

export type AttendanceBalanceRow = {
  kind: string | null
  lessonsLeft: number | null
  priceTiyin: number | null
}

export type AttendanceBalanceLabel = {
  text: string
  tone: 'muted' | 'warn' | 'danger'
}

/**
 * Текст метки. numbers — колонка из базы (стойке числа открыты): null у
 * стойки — «безлимит», у специалиста — «скрыто». Поэтому ветвление по
 * numbers, а не по наличию числа.
 */
export function attendanceBalanceLabel(row: AttendanceBalanceRow, numbers: boolean): AttendanceBalanceLabel {
  const left = row.lessonsLeft
  switch (row.kind) {
    case 'subscription':
      if (!numbers) return { text: 'есть', tone: 'muted' }
      return { text: left == null ? 'без лимита' : `${left} зан.`, tone: 'muted' }
    case 'subscription_low':
      return { text: numbers && left != null ? `${left} зан.` : 'заканчивается', tone: 'warn' }
    case 'subscription_empty':
      return {
        text: numbers && left != null ? `${left} зан. — в минус` : 'нет оплаченных занятий',
        tone: 'danger',
      }
    case 'charged':
      if (!numbers) return { text: 'списано с абонемента', tone: 'muted' }
      return {
        text: left == null ? 'списано · без лимита' : `списано · сейчас осталось ${left} зан.`,
        tone: 'muted',
      }
    case 'frozen':
      return { text: 'абонемент заморожен', tone: 'warn' }
    case 'no_subscription':
      return {
        text:
          numbers && row.priceTiyin != null
            ? `нет абонемента на эту услугу — в долг ${formatSom(row.priceTiyin)}`
            : 'нет абонемента на эту услугу — уйдёт в долг',
        tone: 'danger',
      }
    case 'no_service':
      return { text: 'у занятия не указана услуга — абонемент не спишется', tone: 'warn' }
    case 'free':
      return { text: 'без абонемента — бесплатно', tone: 'muted' }
    case 'debt':
      // Без суммы и без «в долг»: долг гасится деньгами и списанием (0087),
      // по отметке этого не видно. Сколько должны — на карточке ребёнка.
      return { text: 'отмечено без абонемента', tone: 'danger' }
    case 'covered':
      return { text: 'долг покрыт абонементом', tone: 'muted' }
    default:
      return { text: '—', tone: 'muted' }
  }
}
