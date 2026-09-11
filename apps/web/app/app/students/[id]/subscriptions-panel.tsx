'use client'

import { useActionState, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { formatSom } from '@logocrm/core'
import {
  freezeSubscription,
  refundSubscription,
  sellSubscription,
  transferRemaining,
  unfreezeSubscription,
  type SubscriptionState,
} from './subscription-actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'
import { cn } from '@/lib/utils'
import { attendanceStatusClasses, SUBSCRIPTION_STATE_CLASSES, SUBSCRIPTION_STATE_LABELS } from '@/lib/attendance'
import { dayInZone, formatInTimeZone, timeInZone } from '@/lib/timezone'

const initial: SubscriptionState = { message: '' }

/**
 * Календарная дата абонемента (date, без времени) — «10.09.2026».
 * Полдень UTC, чтобы сдвиг пояса центра не перекинул дату на соседнюю:
 * тот же приём, что в schedule/page.tsx для подписей дней недели.
 */
function calendarDate(day: string, timeZone: string): string {
  return formatInTimeZone(`${day}T12:00:00Z`, timeZone, {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  })
}

export type SubscriptionTypeOption = {
  id: string
  name: string
  kind: string
  priceTiyin: number
  lessonsCount: number | null
  periodDays: number | null
}

export type SubscriptionView = {
  id: string
  typeName: string
  priceTiyin: number
  startsAt: string
  endsAt: string | null
  lessonsLeft: number | null
  state: string
  freezeDays: number
  refundTiyin: number
  /** Текущая заморозка: с какого дня и по какой включительно. null в freezeTo — открытая, «пока не разморозят». */
  freezeFrom: string | null
  freezeTo: string | null
}

export type BalanceView = {
  /** null здесь двусмыслен: и «безлимит», и «нет активного абонемента» — различает только activeSubscriptionId. */
  lessonsLeft: number | null
  activeSubscriptionId: string | null
  endsAt: string | null
  debtTiyin: number
  overdrawnTiyin: number
}

export type SiblingOption = { id: string; fullName: string }

export type AttendanceHistoryRow = {
  id: string
  startsAt: string
  statusName: string
  statusColor: string
  comment: string | null
}

function SubmitButton({ children, variant }: { children: React.ReactNode; variant?: 'outline' | 'destructive' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {pending ? 'Секунду…' : children}
    </Button>
  )
}

function BalanceStrip({ balance, timeZone }: { balance: BalanceView; timeZone: string }) {
  return (
    <dl className="grid grid-cols-2 gap-3 rounded-md border border-border bg-muted/50 p-3 text-sm sm:grid-cols-4">
      <div>
        <dt className="text-xs text-muted-foreground">Остаток</dt>
        <dd className="font-medium">
          {!balance.activeSubscriptionId
            ? 'нет активного'
            : balance.lessonsLeft == null
              ? 'без лимита'
              : `${balance.lessonsLeft} зан.`}
        </dd>
      </div>
      <div>
        <dt className="text-xs text-muted-foreground">Срок</dt>
        <dd className="font-medium">{balance.endsAt ? calendarDate(balance.endsAt, timeZone) : '—'}</dd>
      </div>
      <div>
        <dt className="text-xs text-muted-foreground">Долг</dt>
        <dd className={cn('font-medium', balance.debtTiyin > 0 && 'text-destructive')}>
          {balance.debtTiyin > 0 ? formatSom(balance.debtTiyin) : '—'}
        </dd>
      </div>
      <div>
        <dt className="text-xs text-muted-foreground">Перерасход</dt>
        <dd className={cn('font-medium', balance.overdrawnTiyin > 0 && 'text-destructive')}>
          {balance.overdrawnTiyin > 0 ? formatSom(balance.overdrawnTiyin) : '—'}
        </dd>
      </div>
    </dl>
  )
}

function SellForm({ studentId, types }: { studentId: string; types: SubscriptionTypeOption[] }) {
  const [state, formAction] = useActionState(sellSubscription, initial)
  const [typeId, setTypeId] = useState('')
  const selected = types.find((t) => t.id === typeId)

  return (
    <form action={formAction} className="space-y-3 rounded-md border border-border p-3">
      <input type="hidden" name="studentId" value={studentId} />
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="space-y-1 sm:col-span-2">
          <Label htmlFor="typeId">Тип абонемента</Label>
          <Select id="typeId" name="typeId" required value={typeId} onChange={(e) => setTypeId(e.target.value)}>
            <option value="">Выберите тип</option>
            {types.map((type) => (
              <option key={type.id} value={type.id}>
                {type.name}
                {type.kind === 'lessons' && type.lessonsCount ? ` · ${type.lessonsCount} занятий` : ''}
                {type.kind === 'period' && type.periodDays ? ` · ${type.periodDays} дней` : ''}
                {type.kind === 'unlimited' ? ' · безлимит' : ''}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="priceSom">Цена, сом</Label>
          <Input
            id="priceSom"
            name="priceSom"
            type="number"
            min={0}
            step="0.01"
            defaultValue={selected ? selected.priceTiyin / 100 : undefined}
            key={typeId}
            placeholder={selected ? String(selected.priceTiyin / 100) : ''}
          />
        </div>
      </div>
      <div className="space-y-1">
        <Label htmlFor="startsAt">Дата начала</Label>
        <Input id="startsAt" name="startsAt" type="date" className="max-w-[200px]" />
      </div>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
      <SubmitButton>Продать абонемент</SubmitButton>
    </form>
  )
}

function FreezeForm({ studentId, subscriptionId }: { studentId: string; subscriptionId: string }) {
  const [state, formAction] = useActionState(freezeSubscription, initial)
  return (
    <form action={formAction} className="flex flex-wrap items-end gap-2">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <div className="space-y-1">
        <Label htmlFor={`freeze-from-${subscriptionId}`}>С</Label>
        <Input id={`freeze-from-${subscriptionId}`} name="from" type="date" required />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`freeze-to-${subscriptionId}`}>По (пусто — пока не разморозят)</Label>
        <Input id={`freeze-to-${subscriptionId}`} name="to" type="date" />
      </div>
      <SubmitButton variant="outline">Заморозить</SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

function UnfreezeForm({ studentId, subscriptionId }: { studentId: string; subscriptionId: string }) {
  const [state, formAction] = useActionState(unfreezeSubscription, initial)
  return (
    <form action={formAction} className="flex items-center gap-2">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <SubmitButton variant="outline">Разморозить</SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

function RefundForm({
  studentId,
  subscriptionId,
  refundTiyin,
}: {
  studentId: string
  subscriptionId: string
  refundTiyin: number
}) {
  const [state, formAction] = useActionState(refundSubscription, initial)
  const [confirming, setConfirming] = useState(false)

  if (!confirming) {
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setConfirming(true)}>
        Вернуть
      </Button>
    )
  }

  return (
    <form action={formAction} className="space-y-2 rounded-md border border-border p-3">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <input type="hidden" name="expectedTiyin" value={refundTiyin} />
      <p className="text-sm">
        К возврату: <strong>{formatSom(refundTiyin)}</strong>. Если остаток изменился, пока считали, сервер
        откажет — пересчитайте и повторите.
      </p>
      <div className="flex gap-2">
        <SubmitButton variant="destructive">Подтвердить возврат</SubmitButton>
        <Button type="button" size="sm" variant="outline" onClick={() => setConfirming(false)}>
          Отмена
        </Button>
      </div>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

function TransferForm({
  studentId,
  subscriptionId,
  siblings,
}: {
  studentId: string
  subscriptionId: string
  siblings: SiblingOption[]
}) {
  const [state, formAction] = useActionState(transferRemaining, initial)
  if (siblings.length === 0) return null

  return (
    <form action={formAction} className="flex flex-wrap items-end gap-2">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <div className="space-y-1">
        <Label htmlFor={`transfer-to-${subscriptionId}`}>Перенести остаток</Label>
        <Select id={`transfer-to-${subscriptionId}`} name="toStudentId" required defaultValue="">
          <option value="">Выберите ребёнка</option>
          {siblings.map((sibling) => (
            <option key={sibling.id} value={sibling.id}>
              {sibling.fullName}
            </option>
          ))}
        </Select>
      </div>
      <SubmitButton variant="outline">Перенести</SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

function SubscriptionCard({
  studentId,
  subscription,
  siblings,
  timeZone,
}: {
  studentId: string
  subscription: SubscriptionView
  siblings: SiblingOption[]
  timeZone: string
}) {
  return (
    <div className="space-y-3 rounded-md border border-border p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p className="font-medium">{subscription.typeName}</p>
          <p className="text-sm text-muted-foreground">
            {formatSom(subscription.priceTiyin)} · с {calendarDate(subscription.startsAt, timeZone)}
            {subscription.endsAt ? ` по ${calendarDate(subscription.endsAt, timeZone)}` : ''}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <span className="text-sm">
            {subscription.lessonsLeft == null ? 'без лимита' : `${subscription.lessonsLeft} зан.`}
          </span>
          <span
            className={cn(
              'rounded px-2 py-0.5 text-xs font-medium',
              SUBSCRIPTION_STATE_CLASSES[subscription.state] ?? 'bg-muted text-muted-foreground',
            )}
          >
            {SUBSCRIPTION_STATE_LABELS[subscription.state] ?? subscription.state}
          </span>
        </div>
      </div>

      {/* freezeFrom, не state === 'frozen': subscription_summary отдаёт
          диапазон и для заморозки, идущей сейчас, и для ещё не начавшейся
          (state тогда 'active' — period не покрывает сегодня), и для
          исчерпанного/expired-под-заморозкой (state там не 'frozen', но
          пауза реальна) — карточка не должна выглядеть пустой в этих
          случаях. */}
      {subscription.freezeFrom ? (
        <p className="text-sm text-muted-foreground">
          {subscription.state === 'frozen' ? 'Заморожен с ' : 'Будет заморожен с '}
          {calendarDate(subscription.freezeFrom, timeZone)}
          {subscription.freezeTo ? ` по ${calendarDate(subscription.freezeTo, timeZone)}` : ', пока не разморозят'}
          {subscription.freezeDays > 0 ? ` · ${subscription.freezeDays} дн.` : ''}
        </p>
      ) : null}

      {/* !freezeFrom: пока есть незакрытая заморозка (текущая или ещё не
          начавшаяся), freeze_subscription всё равно откажет «уже есть
          незакрытая заморозка» — кнопка не должна предлагать заведомо
          проигрышное действие. */}
      {(subscription.state === 'active' || subscription.state === 'exhausted') && !subscription.freezeFrom ? (
        <div className="flex flex-wrap gap-2 border-t border-border pt-3">
          <FreezeForm studentId={studentId} subscriptionId={subscription.id} />
        </div>
      ) : null}
      {/* Разморозить можно открытую (без даты конца) заморозку и любую ещё
          не начавшуюся (freezeFrom в будущем, state ещё не 'frozen') — обе
          unfreeze_subscription закрывает или отменяет целиком. Закрытую
          датированную, уже идущую (freezeTo есть И state === 'frozen'),
          снять раньше срока нельзя — RPC откажет «У абонемента нет
          открытой заморозки», и кнопка обещала бы несбыточное
          (продуктовое решение 2, см. заголовок миграции 0015). */}
      {subscription.freezeFrom && !(subscription.freezeTo && subscription.state === 'frozen') ? (
        <div className="border-t border-border pt-3">
          <UnfreezeForm studentId={studentId} subscriptionId={subscription.id} />
        </div>
      ) : null}

      {subscription.state !== 'cancelled' && subscription.refundTiyin > 0 ? (
        <div className="flex flex-wrap items-start gap-2 border-t border-border pt-3">
          <RefundForm studentId={studentId} subscriptionId={subscription.id} refundTiyin={subscription.refundTiyin} />
          <TransferForm studentId={studentId} subscriptionId={subscription.id} siblings={siblings} />
        </div>
      ) : null}
    </div>
  )
}

function AttendanceHistoryTable({ rows, timeZone }: { rows: AttendanceHistoryRow[]; timeZone: string }) {
  if (rows.length === 0) {
    return <p className="text-sm text-muted-foreground">Посещений пока нет.</p>
  }

  return (
    <ul className="space-y-2">
      {rows.map((row) => (
        <li key={row.id} className="flex items-center justify-between gap-3 rounded-md border border-border p-3 text-sm">
          <span className="text-muted-foreground">
            {row.startsAt
              ? `${dayInZone(row.startsAt, timeZone)}, ${timeInZone(row.startsAt, timeZone)}`
              : '—'}
          </span>
          <span className={cn('rounded px-2 py-0.5 text-xs font-medium', attendanceStatusClasses(row.statusColor).badge)}>
            {row.statusName}
          </span>
          <span className="flex-1 truncate text-muted-foreground">{row.comment ?? ''}</span>
        </li>
      ))}
    </ul>
  )
}

export function SubscriptionsPanel({
  studentId,
  balance,
  subscriptions,
  types,
  siblings,
  attendanceHistory,
  timeZone,
}: {
  studentId: string
  balance: BalanceView
  subscriptions: SubscriptionView[]
  types: SubscriptionTypeOption[]
  siblings: SiblingOption[]
  attendanceHistory: AttendanceHistoryRow[]
  timeZone: string
}) {
  const [tab, setTab] = useState<'subscriptions' | 'attendance'>('subscriptions')

  return (
    <div className="space-y-4">
      <div className="flex gap-2 border-b border-border">
        <button
          type="button"
          onClick={() => setTab('subscriptions')}
          className={cn(
            'border-b-2 px-1 pb-2 text-sm font-medium',
            tab === 'subscriptions' ? 'border-primary text-foreground' : 'border-transparent text-muted-foreground',
          )}
        >
          Абонементы
        </button>
        <button
          type="button"
          onClick={() => setTab('attendance')}
          className={cn(
            'border-b-2 px-1 pb-2 text-sm font-medium',
            tab === 'attendance' ? 'border-primary text-foreground' : 'border-transparent text-muted-foreground',
          )}
        >
          Посещения
        </button>
      </div>

      {tab === 'subscriptions' ? (
        <div className="space-y-4">
          <BalanceStrip balance={balance} timeZone={timeZone} />
          {subscriptions.length === 0 ? (
            <p className="text-sm text-muted-foreground">Абонементов пока нет.</p>
          ) : (
            <div className="space-y-3">
              {subscriptions.map((subscription) => (
                <SubscriptionCard
                  key={subscription.id}
                  studentId={studentId}
                  subscription={subscription}
                  siblings={siblings}
                  timeZone={timeZone}
                />
              ))}
            </div>
          )}
          <SellForm studentId={studentId} types={types} />
        </div>
      ) : (
        <AttendanceHistoryTable rows={attendanceHistory} timeZone={timeZone} />
      )}
    </div>
  )
}
