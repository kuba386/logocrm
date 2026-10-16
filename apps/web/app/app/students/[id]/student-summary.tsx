import { formatSom } from '@logocrm/core'
import { cn } from '@/lib/utils'
import { formatInTimeZone, isoDayInZone } from '@/lib/timezone'
import type { BalanceView } from './subscriptions-panel'
import { AdvanceAction, CreditRefundAction, DebtActions } from '../../debts/debt-dialogs'

/**
 * Шапка карточки для администратора: главное о ребёнке одной строкой —
 * остаток, долг, когда был и когда придёт. Все цифры уже посчитаны базой
 * (student_balance, attendance, lesson_participants), здесь только подписи.
 *
 * Подписи «Остаток» и «Долг» — те же, что были в полосе баланса над
 * абонементами: полоса для администратора переехала сюда, а не задвоилась.
 *
 * Оплата долга — прямо здесь, где его видно (как в топовых CRM: клик по
 * долгу открывает доплату), а не только на странице «Долги». Аванс — тоже
 * здесь: раньше его не было видно нигде, и вернуть его было нечем.
 */
export function StudentSummary({
  balance,
  lastMark,
  nextLessonAt,
  timeZone,
  money,
}: {
  balance: BalanceView
  /** Самая поздняя отметка посещения из уже прошедших занятий. */
  lastMark: { startsAt: string; statusName: string } | null
  nextLessonAt: string | null
  timeZone: string
  /** Кнопки денег — стойке и владельцу (can_payments); права всё равно проверяет база. */
  money?: {
    studentId: string
    studentName: string
    sources: { id: string; name: string }[]
    today: string
    isOwner: boolean
    /**
     * Причина, по которой аванс не принять (lesson_advance_preview, 0101): null —
     * можно, undefined — база не спрашивалась (долг или идёт абонемент).
     */
    advanceBlock?: string | null
  }
}) {
  const debt = balance.debtTiyin > 0 || balance.overdrawnTiyin > 0
  const lessonDebt = balance.debtTiyin + balance.overdrawnTiyin
  const credit = balance.creditTiyin ?? 0
  const back = money ? `/app/students/${money.studentId}` : '/app'
  // «Внести аванс» — когда база разрешила (0101 Р2). Если нельзя — короткое
  // объяснение вместо кнопки: иначе форма открывалась бы ради отказа.
  const advance = money?.advanceBlock === null
  const advanceHint = money?.advanceBlock ? ADVANCE_BLOCK_HINTS[money.advanceBlock] : undefined

  return (
    <div className="space-y-3 rounded-xl border border-border bg-card p-4">
      <dl className="grid grid-cols-2 gap-x-4 gap-y-3 text-sm lg:grid-cols-4">
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
          {credit > 0 ? <dd className="text-xs text-success">аванс {formatSom(credit)}</dd> : null}
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
      {/* Кнопки денег — отдельной строкой на всю ширину: в узкой колонке «Долг» на телефоне они не помещались. */}
      {money && (lessonDebt > 0 || credit > 0 || advance || advanceHint) ? (
        <div className="flex flex-wrap items-center gap-2 border-t border-border pt-3">
          {lessonDebt > 0 ? (
            <DebtActions
              studentId={money.studentId}
              studentName={money.studentName}
              remainingTiyin={lessonDebt}
              sources={money.sources}
              today={money.today}
              canWriteOff={money.isOwner}
              back={back}
              payLabel={`Принять оплату долга · ${formatSom(lessonDebt)}`}
            />
          ) : null}
          {advance ? (
            <AdvanceAction
              studentId={money.studentId}
              studentName={money.studentName}
              creditTiyin={credit}
              sources={money.sources}
              today={money.today}
              back={back}
            />
          ) : null}
          {advanceHint ? <p className="text-xs text-muted-foreground">{advanceHint}</p> : null}
          {credit > 0 ? (
            <CreditRefundAction
              studentId={money.studentId}
              studentName={money.studentName}
              creditTiyin={credit}
              sources={money.sources}
              today={money.today}
              back={back}
            />
          ) : null}
        </div>
      ) : null}
    </div>
  )
}

/**
 * Почему аванс не принять — коды lesson_advance_block_unchecked (0101). «Долг» тут
 * не встречается (при долге база не спрашивается), архив молчит — у архивного
 * ученика подсказка про аванс была бы шумом.
 */
const ADVANCE_BLOCK_HINTS: Record<string, string> = {
  no_payer: 'Аванс не принимается: у ученика нет плательщика.',
  writeoff: 'Аванс не отразится: у ученика списан долг за занятия. Предложите абонемент.',
  unpaid_subscription: 'Аванс не принимается, пока не доплачен абонемент — примите оплату абонемента.',
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
