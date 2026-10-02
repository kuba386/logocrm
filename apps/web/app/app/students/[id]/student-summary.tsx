import { formatSom } from '@logocrm/core'
import { cn } from '@/lib/utils'
import { formatInTimeZone, isoDayInZone } from '@/lib/timezone'
import type { BalanceView } from './subscriptions-panel'

/**
 * Шапка карточки для администратора: главное о ребёнке одной строкой —
 * остаток, долг, когда был и когда придёт. Все цифры уже посчитаны базой
 * (student_balance, attendance, lesson_participants), здесь только подписи.
 *
 * Подписи «Остаток» и «Долг» — те же, что были в полосе баланса над
 * абонементами: полоса для администратора переехала сюда, а не задвоилась.
 */
export function StudentSummary({
  balance,
  lastMark,
  nextLessonAt,
  timeZone,
}: {
  balance: BalanceView
  /** Самая поздняя отметка посещения из уже прошедших занятий. */
  lastMark: { startsAt: string; statusName: string } | null
  nextLessonAt: string | null
  timeZone: string
}) {
  const debt = balance.debtTiyin > 0 || balance.overdrawnTiyin > 0

  return (
    <dl className="grid grid-cols-2 gap-x-4 gap-y-3 rounded-xl border border-border bg-card p-4 text-sm lg:grid-cols-4">
      <div>
        <dt className="text-xs text-muted-foreground">Остаток</dt>
        <dd className="font-display text-base font-medium sm:text-lg">
          {!balance.activeSubscriptionId
            ? '—'
            : balance.lessonsLeft == null
              ? 'без лимита'
              : `${balance.lessonsLeft} зан.`}
        </dd>
        {!balance.activeSubscriptionId ? (
          <dd className="text-xs text-muted-foreground">нет активного абонемента</dd>
        ) : balance.endsAt ? (
          <dd className="text-xs text-muted-foreground">до {calendarDate(balance.endsAt, timeZone)}</dd>
        ) : null}
      </div>
      <div>
        <dt className="text-xs text-muted-foreground">Долг</dt>
        <dd className={cn('font-display text-base font-medium sm:text-lg', debt && 'text-destructive')}>
          {balance.debtTiyin > 0 ? formatSom(balance.debtTiyin) : debt ? '—' : 'нет'}
        </dd>
        {balance.overdrawnTiyin > 0 ? (
          <dd className="text-xs text-destructive">перерасход {formatSom(balance.overdrawnTiyin)}</dd>
        ) : null}
      </div>
      <div>
        <dt className="text-xs text-muted-foreground">Последнее занятие</dt>
        <dd className="font-display text-base font-medium sm:text-lg">{lastMark ? daysAgo(lastMark.startsAt, timeZone) : 'ещё не было'}</dd>
        {lastMark ? (
          <dd className="text-xs text-muted-foreground">
            {shortDay(lastMark.startsAt, timeZone)}, {lastMark.statusName.toLowerCase()}
          </dd>
        ) : null}
      </div>
      <div>
        <dt className="text-xs text-muted-foreground">Следующее занятие</dt>
        <dd className="font-display text-base font-medium sm:text-lg">{nextLessonAt ? shortDay(nextLessonAt, timeZone) : 'не назначено'}</dd>
        {nextLessonAt ? (
          <dd className="text-xs text-muted-foreground">
            {formatInTimeZone(nextLessonAt, timeZone, { weekday: 'long', hour: '2-digit', minute: '2-digit' })}
          </dd>
        ) : null}
      </div>
    </dl>
  )
}

/** Календарная дата абонемента (date без времени): полдень UTC, чтобы пояс не сдвинул день. */
function calendarDate(day: string, timeZone: string): string {
  return formatInTimeZone(`${day}T12:00:00Z`, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' })
}

function shortDay(iso: string, timeZone: string): string {
  return formatInTimeZone(iso, timeZone, { day: 'numeric', month: 'short' })
}

/** «сегодня», «вчера», «12 дн. назад» — по календарным дням в поясе центра. */
function daysAgo(iso: string, timeZone: string): string {
  const days = Math.round(
    (Date.parse(isoDayInZone(new Date(), timeZone)) - Date.parse(isoDayInZone(iso, timeZone))) / 86_400_000,
  )
  if (days <= 0) return 'сегодня'
  if (days === 1) return 'вчера'
  return `${days} дн. назад`
}
