'use client'

import { useActionState, useEffect, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { formatSom, installmentDueDates, refundPayout, splitInstallments } from '@logocrm/core'
import {
  freezeSubscription,
  refundSubscription,
  sellSubscriptionPaid,
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
import { label, t } from '@/lib/messages'

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

export type InstallmentRow = {
  seq: number
  dueDate: string
  amountTiyin: number
  /** upcoming | due | overdue | paid — из installments_view, не считается на клиенте. */
  state: string
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
  /** Из subscription_payment_summary: внесено и состояние оплаты (unpaid | partial | paid | overpaid). */
  paidTiyin: number
  paymentState: string
  /** Живой план рассрочки (installments_view), пустой массив — рассрочки нет. */
  installments: InstallmentRow[]
}

export type SourceOption = { id: string; name: string }

const INSTALLMENT_STATE_CLASSES: Record<string, string> = {
  overdue: 'text-destructive font-medium',
  due: 'font-medium',
  paid: 'text-muted-foreground line-through',
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

function somToTiyin(som: string): number {
  const value = Number(som)
  return Number.isFinite(value) ? Math.round(value * 100) : 0
}

/**
 * Продажа с оплатой и рассрочкой (промт этапа 5: «Продать абонемент → сразу
 * форма оплаты»). Внесённая сумма по умолчанию — полная цена; источник —
 * первый в списке центра. Предпросмотр графика — из core (splitInstallments
 * / installmentDueDates, зеркало SQL), а фактические строки создаёт RPC и
 * отдаёт в ответе — панель перерисовывается по ним, не по предпросмотру.
 * saleKey — ключ идемпотентности: живёт с открытия формы до успешного
 * ответа, потом меняется; двойной клик со старым ключом сервер отбивает.
 */
function SellForm({
  studentId,
  types,
  sources,
  today,
  timeZone,
}: {
  studentId: string
  types: SubscriptionTypeOption[]
  sources: SourceOption[]
  today: string
  timeZone: string
}) {
  const [state, formAction] = useActionState(sellSubscriptionPaid, initial)
  const [typeId, setTypeId] = useState('')
  const [priceSom, setPriceSom] = useState('')
  const [paidSom, setPaidSom] = useState('')
  const [withInstallments, setWithInstallments] = useState(false)
  const [installments, setInstallments] = useState(2)
  const [firstDue, setFirstDue] = useState(today)
  const [stepMonths, setStepMonths] = useState(1)
  // Не при инициализации: случайный uuid на сервере и клиенте разошёлся бы
  // в гидратации. После успешной продажи — новый ключ для следующей.
  const [saleKey, setSaleKey] = useState('')
  useEffect(() => {
    setSaleKey(crypto.randomUUID())
  }, [state.notice])

  const selected = types.find((t) => t.id === typeId)
  const priceTiyin = somToTiyin(priceSom)
  const paidTiyin = somToTiyin(paidSom)
  const remainingTiyin = Math.max(priceTiyin - paidTiyin, 0)
  const previewAmounts =
    withInstallments && remainingTiyin > 0 && installments >= 1 && installments <= Math.min(24, remainingTiyin)
      ? splitInstallments(remainingTiyin, installments)
      : []
  const previewDates = previewAmounts.length ? installmentDueDates(firstDue || today, installments, stepMonths) : []

  function onTypeChange(id: string) {
    setTypeId(id)
    const type = types.find((t) => t.id === id)
    const som = type ? String(type.priceTiyin / 100) : ''
    setPriceSom(som)
    setPaidSom(som)
  }

  return (
    <form action={formAction} className="space-y-3 rounded-md border border-border p-3">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="saleKey" value={saleKey} />
      <input type="hidden" name="expectedRemainingTiyin" value={remainingTiyin} />
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="space-y-1 sm:col-span-2">
          <Label htmlFor="typeId">Тип абонемента</Label>
          <Select id="typeId" name="typeId" required value={typeId} onChange={(e) => onTypeChange(e.target.value)}>
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
            value={priceSom}
            onChange={(e) => setPriceSom(e.target.value)}
            placeholder={selected ? String(selected.priceTiyin / 100) : ''}
          />
        </div>
      </div>
      <div className="space-y-1">
        <Label htmlFor="startsAt">Дата начала</Label>
        <Input id="startsAt" name="startsAt" type="date" className="max-w-[200px]" />
      </div>

      <fieldset className="space-y-3 rounded-md border border-border p-3">
        <legend className="px-1 text-sm font-medium">{t('sale', 'payment')}</legend>
        <div className="grid gap-3 sm:grid-cols-3">
          <div className="space-y-1">
            <Label htmlFor="paidSom">{t('sale', 'paidSom')}</Label>
            <Input
              id="paidSom"
              name="paidSom"
              type="number"
              min={0}
              step="0.01"
              value={paidSom}
              onChange={(e) => setPaidSom(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <Label htmlFor="sourceId">{t('sale', 'source')}</Label>
            <Select id="sourceId" name="sourceId" defaultValue={sources[0]?.id ?? ''} disabled={paidTiyin === 0}>
              {sources.length === 0 ? <option value="">{t('sale', 'noSources')}</option> : null}
              {sources.map((source) => (
                <option key={source.id} value={source.id}>
                  {source.name}
                </option>
              ))}
            </Select>
          </div>
          <div className="space-y-1">
            <Label htmlFor="paidOn">{t('sale', 'paidOn')}</Label>
            <Input id="paidOn" name="paidOn" type="date" defaultValue={today} max={today} disabled={paidTiyin === 0} />
          </div>
        </div>
        <p className="text-sm text-muted-foreground">
          {priceTiyin > 0
            ? remainingTiyin > 0
              ? t('sale', 'remaining', { sum: formatSom(remainingTiyin) })
              : paidTiyin > priceTiyin
                ? t('sale', 'overpaid')
                : t('sale', 'paidInFull')
            : t('sale', 'chooseType')}
        </p>
      </fieldset>

      {remainingTiyin > 0 ? (
        <fieldset className="space-y-3 rounded-md border border-border p-3">
          <legend className="px-1 text-sm font-medium">
            <label className="flex items-center gap-2">
              <input
                type="checkbox"
                name="withInstallments"
                checked={withInstallments}
                onChange={(e) => setWithInstallments(e.target.checked)}
              />
              {t('sale', 'installments')}
            </label>
          </legend>
          {withInstallments ? (
            <>
              <div className="grid gap-3 sm:grid-cols-3">
                <div className="space-y-1">
                  <Label htmlFor="installments">{t('sale', 'installmentsCount')}</Label>
                  <Input
                    id="installments"
                    name="installments"
                    type="number"
                    min={1}
                    max={24}
                    value={installments}
                    onChange={(e) => setInstallments(Number(e.target.value))}
                  />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="firstDue">{t('sale', 'firstDue')}</Label>
                  <Input
                    id="firstDue"
                    name="firstDue"
                    type="date"
                    min={today}
                    value={firstDue}
                    onChange={(e) => setFirstDue(e.target.value)}
                  />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="stepMonths">{t('sale', 'stepMonths')}</Label>
                  <Input
                    id="stepMonths"
                    name="stepMonths"
                    type="number"
                    min={1}
                    max={12}
                    value={stepMonths}
                    onChange={(e) => setStepMonths(Number(e.target.value))}
                  />
                </div>
              </div>
              {previewAmounts.length ? (
                <ol className="space-y-1 text-sm">
                  {previewAmounts.map((amount, index) => (
                    <li key={index} className="flex justify-between">
                      <span className="text-muted-foreground">
                        {index + 1}. {previewDates[index] ? calendarDate(previewDates[index], timeZone) : '—'}
                      </span>
                      <span>{formatSom(amount)}</span>
                    </li>
                  ))}
                </ol>
              ) : (
                <p className="text-sm text-destructive">{t('sale', 'installmentsInvalid')}</p>
              )}
            </>
          ) : null}
        </fieldset>
      ) : null}

      <FormError message={state.message} />
      <FormNotice message={state.notice} />
      <SubmitButton>{t('sale', 'submit')}</SubmitButton>
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

/**
 * refundTiyin (subscription_summary.refund_tiyin = refund_calc) — стоимость
 * НЕОТРАБОТАННЫХ занятий (lessons) или оставшегося срока (period, 0054), не
 * деньги. Реально вернуть можно не больше внесённого (0030, Р1): по
 * абонементу, оплаченному частично, сервер капнет сумму сам — форма
 * показывает это явно, а не только «к возврату» из одной цифры, которая по
 * частичной оплате её же не покроет.
 *
 * refundTiyin === 0 — законный случай (истёкший срок, исчерпанный пакет), не
 * повод прятать кнопку: «Отменить» доступно всегда, «вернуть деньги» —
 * только когда есть что возвращать (0054, решение владельца, Р0б). Источник
 * оплаты в форме и так появляется только при moneyBack > 0 (не менялось).
 */
function RefundForm({
  studentId,
  subscriptionId,
  refundTiyin,
  paidTiyin,
  isPeriod,
  sources,
}: {
  studentId: string
  subscriptionId: string
  refundTiyin: number
  paidTiyin: number
  /** ends_at абонемента задан — возврат посчитан по оставшимся дням, не по занятиям (0054). */
  isPeriod: boolean
  sources: SourceOption[]
}) {
  const [state, formAction] = useActionState(refundSubscription, initial)
  const [confirming, setConfirming] = useState(false)
  const moneyBack = refundPayout(refundTiyin, paidTiyin)

  if (!confirming) {
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setConfirming(true)}>
        {refundTiyin > 0 ? t('sale', 'refund') : t('sale', 'cancelOnly')}
      </Button>
    )
  }

  return (
    <form action={formAction} className="space-y-2 rounded-md border border-border p-3">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <input type="hidden" name="expectedTiyin" value={refundTiyin} />
      <p className="text-sm">
        {refundTiyin > 0 ? (
          <>
            {t('sale', isPeriod ? 'unworkedPeriodCost' : 'unworkedCost', { sum: formatSom(refundTiyin) })}
            {moneyBack < refundTiyin ? (
              <>
                {' '}
                {t('sale', 'moneyBack', { sum: formatSom(moneyBack) })}
              </>
            ) : null}
            {'. '}
            {t('sale', 'refundHint')}
          </>
        ) : (
          t('sale', 'cancelNoRefund')
        )}
      </p>
      {moneyBack > 0 ? (
        <div className="space-y-1">
          <Label htmlFor={`refund-source-${subscriptionId}`}>{t('sale', 'source')}</Label>
          <Select id={`refund-source-${subscriptionId}`} name="sourceId" defaultValue={sources[0]?.id ?? ''}>
            {sources.length === 0 ? <option value="">{t('sale', 'noSources')}</option> : null}
            {sources.map((source) => (
              <option key={source.id} value={source.id}>
                {source.name}
              </option>
            ))}
          </Select>
        </div>
      ) : null}
      <div className="flex gap-2">
        <SubmitButton variant="destructive">{t('sale', moneyBack > 0 ? 'confirmRefund' : 'confirmCancel')}</SubmitButton>
        <Button type="button" size="sm" variant="outline" onClick={() => setConfirming(false)}>
          {t('sale', 'cancel')}
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
  sources,
  timeZone,
}: {
  studentId: string
  subscription: SubscriptionView
  siblings: SiblingOption[]
  sources: SourceOption[]
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

      <p className="text-sm">
        {t('subscriptionCard', 'paidOf', {
          paid: formatSom(subscription.paidTiyin),
          price: formatSom(subscription.priceTiyin),
        })}
        <span className="text-muted-foreground"> · {label('paymentState', subscription.paymentState)}</span>
      </p>
      {subscription.installments.length ? (
        <ol className="space-y-1 text-sm">
          {subscription.installments.map((row) => (
            <li key={row.seq} className={cn('flex justify-between', INSTALLMENT_STATE_CLASSES[row.state])}>
              <span>
                {row.seq}. {calendarDate(row.dueDate, timeZone)} · {label('installmentState', row.state)}
              </span>
              <span>{formatSom(row.amountTiyin)}</span>
            </li>
          ))}
        </ol>
      ) : null}

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

      {/* Отменить доступно всегда (даже при возврате 0 — истёкший срок,
          исчерпанный пакет, 0054): RefundForm сама решает, показывать ли
          источник оплаты. Перенос остатка — отдельное условие: он про
          lessons_left, а не про деньги, и на period/unlimited/исчерпанном
          абонементе transfer_remaining откажет «переносить нечего»
          (Architect-ревью 0054, Р7 — было слито в одно условие с возвратом). */}
      {subscription.state !== 'cancelled' ? (
        <div className="flex flex-wrap items-start gap-2 border-t border-border pt-3">
          <RefundForm
            studentId={studentId}
            subscriptionId={subscription.id}
            refundTiyin={subscription.refundTiyin}
            paidTiyin={subscription.paidTiyin}
            isPeriod={subscription.endsAt != null}
            sources={sources}
          />
          {subscription.lessonsLeft != null && subscription.lessonsLeft > 0 ? (
            <TransferForm studentId={studentId} subscriptionId={subscription.id} siblings={siblings} />
          ) : null}
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
  sources,
  today,
  siblings,
  attendanceHistory,
  timeZone,
}: {
  studentId: string
  balance: BalanceView
  subscriptions: SubscriptionView[]
  types: SubscriptionTypeOption[]
  sources: SourceOption[]
  /** Сегодня по поясу центра (ISO-дата) — дефолт даты оплаты и первого платежа. */
  today: string
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
                  sources={sources}
                  timeZone={timeZone}
                />
              ))}
            </div>
          )}
          <SellForm studentId={studentId} types={types} sources={sources} today={today} timeZone={timeZone} />
        </div>
      ) : (
        <AttendanceHistoryTable rows={attendanceHistory} timeZone={timeZone} />
      )}
    </div>
  )
}
