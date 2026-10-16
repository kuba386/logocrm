'use client'

import { startTransition, useActionState, useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react'
import { useRouter } from 'next/navigation'
import { formatSom, installmentDueDates, splitInstallments } from '@logocrm/core'
import {
  acceptSubscriptionPayment,
  coverLessonDebt,
  freezeSubscription,
  refundSubscription,
  sellSubscriptionPaid,
  transferRemaining,
  unfreezeSubscription,
  writeOffSubscription,
  type SubscriptionState,
} from './subscription-actions'
import { Button, type ButtonProps } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError } from '@/components/ui/alert'
import { NoticeLine, usePageNotice, type Notice } from '@/components/ui/page-notice'
import { receiptHref } from '@/lib/receipt'
import { StatusBadge, type StatusTone } from '@/components/ui/status-badge'
import { cn } from '@/lib/utils'
import { attendanceStatusClasses, SUBSCRIPTION_STATE_CLASSES, SUBSCRIPTION_STATE_LABELS } from '@/lib/attendance'
import { dayInZone, formatInTimeZone, timeInZone } from '@/lib/timezone'
import { useLastSource } from '@/lib/use-last-source'
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
  /** Остаток строки (installments_view.row_remaining_tiyin, 0100): после частичной оплаты меньше плановой. */
  remainingTiyin: number
  /** upcoming | due | overdue | paid — из installments_view, не считается на клиенте. */
  state: string
}

export type SubscriptionView = {
  id: string
  typeName: string
  /** Плательщик абонемента — перенос остатка только его детям (0091). */
  payerId?: string | null
  priceTiyin: number
  startsAt: string
  endsAt: string | null
  /** Сколько занятий в пакете (subscriptions.lessons_total); null — срок или безлимит. */
  lessonsTotal?: number | null
  lessonsLeft: number | null
  state: string
  freezeDays: number
  refundTiyin: number
  /** Текущая заморозка: с какого дня и по какой включительно. null в freezeTo — открытая, «пока не разморозят». */
  freezeFrom: string | null
  freezeTo: string | null
  /** Из subscription_payment_summary: внесено и состояние оплаты (unpaid | partial | paid | overpaid | closed). */
  paidTiyin: number
  paymentState: string
  /** Из subscription_summary (0090): деньги к выплате при отмене и недоплата за отработанное. */
  payoutTiyin: number
  shortfallTiyin: number
  /** Остаток к оплате (subscription_summary.due_tiyin, 0090) — у закрытого 0. */
  dueTiyin: number
  /** Живой план рассрочки (installments_view), пустой массив — рассрочки нет. */
  installments: InstallmentRow[]
  /** Предпросмотр покрытия долга этим абонементом (0088) — только если есть что покрыть. */
  cover?: { canCover: number; amountTiyin: number; remainingTiyin: number; creditAfterTiyin: number } | null
}

export type SourceOption = { id: string; name: string }

const INSTALLMENT_STATE_CLASSES: Record<string, string> = {
  overdue: 'text-destructive font-medium',
  due: 'font-medium',
  paid: 'text-muted-foreground line-through',
}

const PAYMENT_STATE_TONES: Record<string, StatusTone> = {
  unpaid: 'danger',
  partial: 'warning',
  paid: 'success',
  overpaid: 'info',
  closed: 'neutral',
}

export type BalanceView = {
  /** null здесь двусмыслен: и «безлимит», и «нет активного абонемента» — различает только activeSubscriptionId. */
  lessonsLeft: number | null
  activeSubscriptionId: string | null
  endsAt: string | null
  debtTiyin: number
  overdrawnTiyin: number
  /** Аванс за занятия (student_balance.lesson_credit_tiyin, 0087): переплата долга, ждёт будущих занятий. */
  creditTiyin?: number
}

export type SiblingOption = { id: string; fullName: string; payerId?: string | null }

export type AttendanceHistoryRow = {
  id: string
  startsAt: string
  statusName: string
  statusColor: string
  comment: string | null
}

/** Итог действия: текст и, если проведён платёж, его id — для ссылки «Квитанция». */
type Done = (notice: string, paymentId?: string) => void

/**
 * Формы панели отправляются через onSubmit, а не <form action>. React 19
 * после action-формы сбрасывает её, и при отказе сервера (оплата больше цены,
 * кривая дата) поля молча возвращались к значениям по умолчанию: источник
 * оплаты — на первый в списке, дата начала и «по» заморозки — на пустые,
 * select типа — на «Выберите тип» при цене от прежнего типа. Повторная
 * отправка провела бы деньги не через ту кассу и не с той даты. Теперь при
 * отказе введённое остаётся как есть.
 *
 * Итог (onDone) зовётся прямо из обёртки действия, до коммита ответа, а не из
 * эффекта после него: ответ сервера и перерисовка по revalidatePath приходят
 * одним коммитом, и если успех убирает хозяина формы (оплачено целиком —
 * кнопки «Принять оплату» больше нет, заморозили — нет «Заморозить»), эффект
 * уже не выполнится и итог с квитанцией пропал бы. Форма живёт в диалоге и
 * пересоздаётся при каждом открытии — второй клик начинает с чистого листа.
 */
function useFormAction(
  action: (prev: SubscriptionState, formData: FormData) => Promise<SubscriptionState>,
  onDone?: Done,
) {
  const onDoneRef = useRef(onDone)
  onDoneRef.current = onDone
  const [state, formAction, pending] = useActionState(async (prev: SubscriptionState, formData: FormData) => {
    const next = await action(prev, formData)
    if (next.notice) onDoneRef.current?.(next.notice, next.paymentId)
    return next
  }, initial)

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const formData = new FormData(event.currentTarget)
    startTransition(() => formAction(formData))
  }

  return { state, submit, pending }
}

/** pending — из useActionState: useFormStatus без <form action> всегда false. */
function SubmitButton({
  children,
  pending,
  variant,
}: {
  children: ReactNode
  pending: boolean
  variant?: 'outline' | 'destructive'
}) {
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {pending ? 'Секунду…' : children}
    </Button>
  )
}

/**
 * Кнопка действия и диалог с его формой. Форма пересоздаётся на каждое
 * открытие (key): прошлый отказ и прошлая сумма не всплывают при новом
 * открытии, а сумма по умолчанию берётся из свежих данных карточки.
 */
function ActionDialog({
  label: buttonLabel,
  title,
  description,
  variant = 'outline',
  onOpen,
  children,
}: {
  label: ReactNode
  title: string
  description?: string
  variant?: ButtonProps['variant']
  onOpen?: () => void
  children: (close: () => void) => ReactNode
}) {
  const [open, setOpen] = useState(false)
  const [round, setRound] = useState(0)
  return (
    <>
      {/* На телефоне — во всю ширину: длинные подписи («Покрыть неоплаченные занятия (1)») не вылезают за карточку. */}
      <Button
        type="button"
        size="sm"
        variant={variant}
        className="max-sm:h-auto max-sm:min-h-9 max-sm:w-full max-sm:whitespace-normal"
        onClick={() => {
          onOpen?.()
          setRound((r) => r + 1)
          setOpen(true)
        }}
      >
        {buttonLabel}
      </Button>
      <Dialog open={open} onClose={() => setOpen(false)} title={title} description={description}>
        <div key={round}>{open ? children(() => setOpen(false)) : null}</div>
      </Dialog>
    </>
  )
}

/** Источник оплаты: по умолчанию — последний выбранный на этом устройстве (useLastSource). */
function SourceSelect({
  id,
  sources,
  disabled,
}: {
  id: string
  sources: SourceOption[]
  disabled?: boolean
}) {
  const [value, remember] = useLastSource(sources)
  return (
    <Select id={id} name="sourceId" value={value} onChange={(e) => remember(e.target.value)} disabled={disabled}>
      {sources.length === 0 ? <option value="">{t('sale', 'noSources')}</option> : null}
      {sources.map((source) => (
        <option key={source.id} value={source.id}>
          {source.name}
        </option>
      ))}
    </Select>
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
        {balance.creditTiyin ? <dd className="text-xs text-success">аванс {formatSom(balance.creditTiyin)}</dd> : null}
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
  const value = Number(som.replace(',', '.'))
  return Number.isFinite(value) ? Math.round(value * 100) : 0
}

/**
 * Продажа с оплатой и рассрочкой (промт этапа 5: «Продать абонемент → сразу
 * форма оплаты»). Внесённая сумма по умолчанию — полная цена; источник —
 * последний выбранный. Предпросмотр графика — из core (splitInstallments /
 * installmentDueDates, зеркало SQL), а фактические строки создаёт RPC —
 * карточка перерисовывается по ним, не по предпросмотру.
 * saleKey — ключ идемпотентности: живёт с открытия формы до ответа сервера,
 * двойной клик со старым ключом сервер отбивает.
 */
function SellForm({
  studentId,
  types,
  sources,
  today,
  timeZone,
  onDone,
}: {
  studentId: string
  types: SubscriptionTypeOption[]
  sources: SourceOption[]
  today: string
  timeZone: string
  onDone: Done
}) {
  const { state, submit, pending } = useFormAction(sellSubscriptionPaid, onDone)
  const [typeId, setTypeId] = useState('')
  const [priceSom, setPriceSom] = useState('')
  const [paidSom, setPaidSom] = useState('')
  const [withInstallments, setWithInstallments] = useState(false)
  const [installments, setInstallments] = useState(2)
  // Первый платёж рассрочки — через месяц от сегодня, а не сегодня: в день
  // продажи семья уже внесла первую часть, и платёж «сегодня» назавтра
  // становился просрочкой (аудит финансов 5.10.2026). Форма создаётся заново
  // при каждом открытии диалога — раньше после продажи сюда подставлялось
  // «сегодня», и вторая продажа без перезагрузки снова давала просрочку.
  const [firstDue, setFirstDue] = useState(() => installmentDueDates(today, 2, 1)[1] ?? today)
  const [stepMonths, setStepMonths] = useState(1)
  // Не при инициализации: случайный uuid на сервере и клиенте разошёлся бы
  // в гидратации. Новый ключ — на каждый ответ сервера: после отказа продажа
  // откатилась, новый ключ ничего не ломает.
  const [saleKey, setSaleKey] = useState('')
  useEffect(() => {
    setSaleKey(crypto.randomUUID())
  }, [state])

  const selected = types.find((type) => type.id === typeId)
  const priceTiyin = somToTiyin(priceSom)
  const paidTiyin = somToTiyin(paidSom)
  const remainingTiyin = Math.max(priceTiyin - paidTiyin, 0)
  const discountTiyin = selected && priceSom !== '' ? selected.priceTiyin - priceTiyin : 0
  const previewAmounts =
    withInstallments && remainingTiyin > 0 && installments >= 1 && installments <= Math.min(24, remainingTiyin)
      ? splitInstallments(remainingTiyin, installments)
      : []
  const previewDates = previewAmounts.length ? installmentDueDates(firstDue || today, installments, stepMonths) : []

  function onTypeChange(id: string) {
    setTypeId(id)
    const type = types.find((item) => item.id === id)
    const som = type ? String(type.priceTiyin / 100) : ''
    setPriceSom(som)
    setPaidSom(som)
  }

  // Правка цены (скидка) тянет за собой «Внесено», пока его не трогали
  // руками: раньше цена становилась 3 500, а внесено оставалось 4 000 — и
  // сервер отказывал «переплата» на ровном месте.
  function onPriceChange(value: string) {
    if (paidSom === priceSom) setPaidSom(value)
    setPriceSom(value)
  }

  return (
    <form onSubmit={submit} className="space-y-4">
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
          {types.length === 0 ? (
            <p className="text-xs text-muted-foreground">
              Типов абонементов пока нет — их заводят в «Настройки → Типы абонементов».
            </p>
          ) : null}
        </div>
        <div className="space-y-1">
          <Label htmlFor="priceSom">Цена, сом</Label>
          <Input
            id="priceSom"
            name="priceSom"
            type="number"
            inputMode="decimal"
            min={0}
            step="0.01"
            value={priceSom}
            onChange={(e) => onPriceChange(e.target.value)}
            placeholder={selected ? String(selected.priceTiyin / 100) : ''}
          />
          {discountTiyin > 0 ? (
            <p className="text-xs text-muted-foreground">
              Скидка {formatSom(discountTiyin)} от цены типа {selected ? formatSom(selected.priceTiyin) : ''}
            </p>
          ) : null}
        </div>
      </div>
      <div className="space-y-1">
        <Label htmlFor="startsAt">Дата начала</Label>
        <Input id="startsAt" name="startsAt" type="date" defaultValue={today} className="max-w-[200px]" />
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
              inputMode="decimal"
              min={0}
              step="0.01"
              value={paidSom}
              onChange={(e) => setPaidSom(e.target.value)}
            />
            {priceTiyin > 0 ? (
              <div className="flex flex-wrap gap-x-3 text-xs">
                <button type="button" className="text-primary underline-offset-4 hover:underline" onClick={() => setPaidSom(priceSom)}>
                  Вся сумма
                </button>
                <button type="button" className="text-primary underline-offset-4 hover:underline" onClick={() => setPaidSom('0')}>
                  Без оплаты
                </button>
              </div>
            ) : null}
          </div>
          <div className="space-y-1">
            <Label htmlFor="sourceId">{t('sale', 'source')}</Label>
            <SourceSelect id="sourceId" sources={sources} disabled={paidTiyin === 0} />
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
      <SubmitButton pending={pending}>
        {paidTiyin > 0 ? t('sale', 'submitPaid', { sum: formatSom(paidTiyin) }) : t('sale', 'submitUnpaid')}
      </SubmitButton>
    </form>
  )
}

function FreezeForm({ studentId, subscriptionId, today, onDone }: { studentId: string; subscriptionId: string; today: string; onDone: Done }) {
  const { state, submit, pending } = useFormAction(freezeSubscription, onDone)
  return (
    <form onSubmit={submit} className="space-y-3">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor={`freeze-from-${subscriptionId}`}>С</Label>
          <Input id={`freeze-from-${subscriptionId}`} name="from" type="date" defaultValue={today} required />
        </div>
        <div className="space-y-1">
          <Label htmlFor={`freeze-to-${subscriptionId}`}>По (пусто — пока не разморозят)</Label>
          <Input id={`freeze-to-${subscriptionId}`} name="to" type="date" />
        </div>
      </div>
      <p className="text-xs text-muted-foreground">
        У абонемента на срок дата окончания сдвинется на дни заморозки. Отметить посещение в эти дни будет нельзя.
      </p>
      <FormError message={state.message} />
      <SubmitButton pending={pending}>Заморозить</SubmitButton>
    </form>
  )
}

function UnfreezeForm({ studentId, subscriptionId, onDone }: { studentId: string; subscriptionId: string; onDone: Done }) {
  const { state, submit, pending } = useFormAction(unfreezeSubscription, onDone)
  return (
    <form onSubmit={submit} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <SubmitButton pending={pending} variant="outline">
        Разморозить
      </SubmitButton>
      <FormError message={state.message} />
    </form>
  )
}

/**
 * refundTiyin (subscription_summary.refund_tiyin = refund_calc) — стоимость
 * НЕОТРАБОТАННЫХ занятий (lessons) или оставшегося срока (period, 0054), не
 * деньги. Деньгами возвращается внесённое сверх отработанного (0090 Р4,
 * payout_tiyin с сервера): форма показывает это явно, а не только «к
 * возврату» из одной цифры.
 *
 * refundTiyin === 0 — законный случай (истёкший срок, исчерпанный пакет), не
 * повод прятать кнопку: «Отменить» доступно всегда, «вернуть деньги» —
 * только когда есть что возвращать (0054, решение владельца, Р0б). Источник
 * оплаты в форме появляется только при moneyBack > 0.
 */
function RefundForm({
  studentId,
  subscriptionId,
  refundTiyin,
  payoutTiyin,
  isPeriod,
  sources,
  onDone,
  onCancel,
}: {
  studentId: string
  subscriptionId: string
  refundTiyin: number
  /** subscription_summary.payout_tiyin (0090): внесённое сверх отработанного — считает база. */
  payoutTiyin: number
  /** ends_at абонемента задан — возврат посчитан по оставшимся дням, не по занятиям (0054). */
  isPeriod: boolean
  sources: SourceOption[]
  onDone: Done
  onCancel: () => void
}) {
  const { state, submit, pending } = useFormAction(refundSubscription, onDone)
  const moneyBack = payoutTiyin

  return (
    <form onSubmit={submit} className="space-y-3">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <input type="hidden" name="expectedTiyin" value={refundTiyin} />
      <input type="hidden" name="expectedPayoutTiyin" value={payoutTiyin} />
      {/* Текст — по выплате (payout), а не по «стоимости неотработанного»: у
          безлимита без срока refund_calc = 0, а внесённое возвращается целиком
          — раньше форма писала «возврат не положен» и проводила −8 000 молча
          (аудит финансов 16.10.2026). */}
      <div className="space-y-1 text-sm">
        {moneyBack > 0 ? (
          <p className="font-medium">{t('sale', 'payoutLine', { sum: formatSom(moneyBack) })}</p>
        ) : (
          <p>{t('sale', 'cancelNoRefund')}</p>
        )}
        {refundTiyin > 0 ? (
          <p className="text-muted-foreground">
            {t('sale', isPeriod ? 'unworkedPeriodCost' : 'unworkedCost', { sum: formatSom(refundTiyin) })}
            {moneyBack < refundTiyin ? ` ${t('sale', 'paidLess')}` : ''}.
          </p>
        ) : null}
        <p className="text-xs text-muted-foreground">{t('sale', 'refundHint')}</p>
      </div>
      {moneyBack > 0 ? (
        <div className="space-y-1">
          <Label htmlFor={`refund-source-${subscriptionId}`}>{t('sale', 'refundSource')}</Label>
          <SourceSelect id={`refund-source-${subscriptionId}`} sources={sources} />
        </div>
      ) : null}
      <FormError message={state.message} />
      <div className="flex flex-wrap gap-2">
        <SubmitButton pending={pending} variant="destructive">
          {moneyBack > 0 ? t('sale', 'confirmRefundSum', { sum: formatSom(moneyBack) }) : t('sale', 'confirmCancel')}
        </SubmitButton>
        <Button type="button" size="sm" variant="outline" onClick={onCancel}>
          {t('sale', 'cancel')}
        </Button>
      </div>
    </form>
  )
}

/**
 * «Принять оплату» по существующему абонементу (0090 Р7): куда ведёт отказ
 * «сначала примите оплату». Остаток к оплате — с сервера
 * (subscription_summary.due_tiyin), сервер же сверяет его и не примет больше.
 * Раньше после частичной оплаты форма оставалась открытой со старой суммой и
 * без подтверждения — повторный клик отправлял прежнюю сумму в уже
 * уменьшившийся остаток. Теперь успех закрывает диалог, итог — над списком.
 */
function PayForm({
  studentId,
  subscriptionId,
  dueTiyin,
  sources,
  today,
  onDone,
}: {
  studentId: string
  subscriptionId: string
  dueTiyin: number
  sources: SourceOption[]
  today: string
  onDone: Done
}) {
  const router = useRouter()
  const { state, submit, pending } = useFormAction(acceptSubscriptionPayment, onDone)

  // Отказ (остаток изменился — 23514) — перечитать страницу, чтобы скрытый
  // expectedDueTiyin стал свежим, а не уходил повторно устаревшим.
  useEffect(() => {
    if (state.message) router.refresh()
  }, [state, router])

  return (
    <form onSubmit={submit} className="space-y-3 text-sm">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <input type="hidden" name="expectedDueTiyin" value={dueTiyin} />
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="space-y-1">
          <Label htmlFor={`pay-amount-${subscriptionId}`}>Сумма, сом</Label>
          <Input
            id={`pay-amount-${subscriptionId}`}
            name="amountSom"
            type="number"
            inputMode="decimal"
            min="0.01"
            step="0.01"
            max={dueTiyin / 100}
            required
            defaultValue={String(dueTiyin / 100)}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor={`pay-source-${subscriptionId}`}>{t('sale', 'source')}</Label>
          <SourceSelect id={`pay-source-${subscriptionId}`} sources={sources} />
        </div>
        <div className="space-y-1">
          <Label htmlFor={`pay-date-${subscriptionId}`}>Дата</Label>
          <Input id={`pay-date-${subscriptionId}`} name="paidOn" type="date" defaultValue={today} max={today} />
        </div>
      </div>
      <FormError message={state.message} />
      <SubmitButton pending={pending}>Принять</SubmitButton>
    </form>
  )
}

/**
 * Недоплата за отработанное (0090): отмена недоступна, пока не оплачено.
 * Владельцу — «Списать недоплату и закрыть» с обязательной причиной; сумму
 * считает база, касса не меняется.
 */
function WriteOffForm({
  studentId,
  subscriptionId,
  shortfallTiyin,
  onDone,
}: {
  studentId: string
  subscriptionId: string
  shortfallTiyin: number
  onDone: Done
}) {
  const router = useRouter()
  const { state, submit, pending } = useFormAction(writeOffSubscription, onDone)

  useEffect(() => {
    if (state.message) router.refresh()
  }, [state, router])

  return (
    <form onSubmit={submit} className="space-y-3 text-sm">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <input type="hidden" name="expectedShortfallTiyin" value={shortfallTiyin} />
      <div className="space-y-1">
        <Label htmlFor={`writeoff-reason-${subscriptionId}`}>Причина</Label>
        <Input id={`writeoff-reason-${subscriptionId}`} name="reason" required maxLength={500} />
      </div>
      <FormError message={state.message} />
      <SubmitButton pending={pending} variant="destructive">
        Списать и закрыть
      </SubmitButton>
    </form>
  )
}

function TransferForm({
  studentId,
  subscriptionId,
  siblings,
  onDone,
}: {
  studentId: string
  subscriptionId: string
  siblings: SiblingOption[]
  onDone: Done
}) {
  const { state, submit, pending } = useFormAction(transferRemaining, onDone)

  return (
    <form onSubmit={submit} className="space-y-3">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <div className="space-y-1">
        <Label htmlFor={`transfer-to-${subscriptionId}`}>Кому</Label>
        <Select id={`transfer-to-${subscriptionId}`} name="toStudentId" required defaultValue="">
          <option value="">Выберите ребёнка</option>
          {siblings.map((sibling) => (
            <option key={sibling.id} value={sibling.id}>
              {sibling.fullName}
            </option>
          ))}
        </Select>
      </div>
      <p className="text-xs text-muted-foreground">
        Внесённые сверх отработанного деньги перейдут вместе с занятиями (только детям того же плательщика).
      </p>
      <FormError message={state.message} />
      <SubmitButton pending={pending}>Перенести</SubmitButton>
    </form>
  )
}

/**
 * «Покрыть неоплаченные занятия (N)» (0088): занятия списываются с этого
 * абонемента, долг снимается. Подтверждение с суммой — действие тратит
 * занятия абонемента. Отказ (23514 «долг изменился») — перечитать страницу,
 * чтобы предпросмотр и expected стали свежими.
 */
function CoverDebtForm({
  studentId,
  subscriptionId,
  cover,
  onDone,
}: {
  studentId: string
  subscriptionId: string
  cover: NonNullable<SubscriptionView['cover']>
  onDone: Done
}) {
  const router = useRouter()
  const { state, submit, pending } = useFormAction(coverLessonDebt, onDone)

  useEffect(() => {
    if (state.message) router.refresh()
  }, [state, router])

  return (
    <form onSubmit={submit} className="space-y-3 text-sm">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="subscriptionId" value={subscriptionId} />
      <input type="hidden" name="count" value={cover.canCover} />
      <input type="hidden" name="expectedRemainingTiyin" value={cover.remainingTiyin} />
      <p>
        Списать с абонемента {cover.canCover} {cover.canCover === 1 ? 'занятие' : 'занятия'} в счёт долга на{' '}
        {formatSom(cover.amountTiyin)}. Долг сейчас — {formatSom(cover.remainingTiyin)}.
        {cover.creditAfterTiyin > 0 ? ` После покрытия ${formatSom(cover.creditAfterTiyin)} уже внесённых денег станут авансом.` : ''}
      </p>
      <FormError message={state.message} />
      <SubmitButton pending={pending}>Покрыть</SubmitButton>
    </form>
  )
}

/** «Осталось 5 из 8» с полосой — только у пакета занятий; у срока и безлимита считать нечего. */
function LessonsProgress({ left, total }: { left: number | null; total: number | null | undefined }) {
  if (left == null) return <span className="text-sm">без лимита</span>
  if (!total) return <span className="text-sm">{left} зан.</span>
  const share = Math.min(Math.max(left / total, 0), 1)
  return (
    <div className="min-w-[8rem] space-y-1">
      <p className={cn('text-sm', left <= 0 && 'text-destructive')}>
        Осталось {left} из {total}
      </p>
      <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted" aria-hidden="true">
        <div
          className={cn('h-full rounded-full', left <= 2 ? 'bg-warning' : 'bg-primary', left <= 0 && 'bg-destructive')}
          style={{ width: `${share * 100}%` }}
        />
      </div>
    </div>
  )
}

/** Завершённый абонемент: отменён, либо истёк/исчерпан и по деньгам закрыт — свёрнут под «Завершённые». */
function isFinished(subscription: SubscriptionView): boolean {
  if (subscription.state === 'cancelled') return true
  const done = subscription.state === 'expired' || subscription.state === 'exhausted'
  return done && subscription.dueTiyin === 0 && subscription.shortfallTiyin === 0 && !(subscription.cover && subscription.cover.canCover > 0)
}

function SubscriptionCard({
  studentId,
  subscription,
  siblings,
  sources,
  timeZone,
  canManage,
  isOwner,
  today,
  onDone,
  onOpen,
}: {
  studentId: string
  subscription: SubscriptionView
  siblings: SiblingOption[]
  sources: SourceOption[]
  timeZone: string
  /** Родитель видит те же цифры, что администратор, но без продажи/заморозки/возврата/переноса (Backlog.md, 23.09.2026). */
  canManage: boolean
  /** Владелец центра — может списать недоплату (0090). Подсказка интерфейса; право проверяет база. */
  isOwner: boolean
  today: string
  onDone: Done
  onOpen: () => void
}) {
  const transferTo = siblings.filter((sibling) => sibling.payerId === subscription.payerId)
  const canFreeze = (subscription.state === 'active' || subscription.state === 'exhausted') && !subscription.freezeFrom

  return (
    <div className="space-y-3 rounded-md border border-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium">{subscription.typeName}</p>
          <p className="text-sm text-muted-foreground">
            {formatSom(subscription.priceTiyin)} · с {calendarDate(subscription.startsAt, timeZone)}
            {subscription.endsAt ? ` по ${calendarDate(subscription.endsAt, timeZone)}` : ''}
          </p>
        </div>
        <div className="flex items-start gap-3">
          <LessonsProgress left={subscription.lessonsLeft} total={subscription.lessonsTotal} />
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

      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
        <span>
          {t('subscriptionCard', 'paidOf', {
            paid: formatSom(subscription.paidTiyin),
            price: formatSom(subscription.priceTiyin),
          })}
        </span>
        {subscription.paymentState ? (
          <StatusBadge tone={PAYMENT_STATE_TONES[subscription.paymentState] ?? 'neutral'}>
            {label('paymentState', subscription.paymentState)}
          </StatusBadge>
        ) : null}
        {subscription.dueTiyin > 0 ? (
          <span className="text-muted-foreground">{t('subscriptionCard', 'due', { sum: formatSom(subscription.dueTiyin) })}</span>
        ) : null}
      </div>
      {subscription.installments.length ? (
        <ol className="space-y-1 text-sm">
          {subscription.installments.map((row) => (
            <li key={row.seq} className={cn('flex justify-between gap-3', INSTALLMENT_STATE_CLASSES[row.state])}>
              <span>
                {row.seq}. {calendarDate(row.dueDate, timeZone)} · {label('installmentState', row.state)}
              </span>
              <span className="whitespace-nowrap tabular-nums">
                {row.state !== 'paid' && row.remainingTiyin < row.amountTiyin
                  ? `${formatSom(row.remainingTiyin)} из ${formatSom(row.amountTiyin)}`
                  : formatSom(row.amountTiyin)}
              </span>
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

      {canManage && subscription.shortfallTiyin > 0 && subscription.state !== 'cancelled' ? (
        <p className="text-sm text-muted-foreground">
          Закрыть абонемент нельзя: за отработанные занятия не заплачено {formatSom(subscription.shortfallTiyin)}. Сначала примите
          оплату{isOwner ? ' или спишите недоплату' : ''}.
        </p>
      ) : null}

      {/* canManage: родитель видит те же цифры выше, но без единой кнопки —
          продать/заморозить/вернуть/перенести остаются стойке и владельцу
          (Backlog.md, 23.09.2026). */}
      {canManage && subscription.state !== 'cancelled' ? (
        <div className="flex flex-wrap items-start gap-2 border-t border-border pt-3">
          {subscription.dueTiyin > 0 ? (
            <ActionDialog
              variant="default"
              label={t('subscriptionCard', 'payButton', { sum: formatSom(subscription.dueTiyin) })}
              title="Принять оплату"
              description={`${subscription.typeName}: осталось оплатить ${formatSom(subscription.dueTiyin)}. Больше остатка сервер не примет.`}
              onOpen={onOpen}
            >
              {(close) => (
                <PayForm
                  studentId={studentId}
                  subscriptionId={subscription.id}
                  dueTiyin={subscription.dueTiyin}
                  sources={sources}
                  today={today}
                  onDone={(notice, paymentId) => {
                    close()
                    onDone(notice, paymentId)
                  }}
                />
              )}
            </ActionDialog>
          ) : null}

          {subscription.cover && subscription.cover.canCover > 0 ? (
            <ActionDialog
              label={`Покрыть неоплаченные занятия (${subscription.cover.canCover})`}
              title="Покрыть долг абонементом"
              onOpen={onOpen}
            >
              {(close) => (
                <CoverDebtForm
                  studentId={studentId}
                  subscriptionId={subscription.id}
                  cover={subscription.cover!}
                  onDone={(notice, paymentId) => {
                    close()
                    onDone(notice, paymentId)
                  }}
                />
              )}
            </ActionDialog>
          ) : null}

          {/* !freezeFrom: пока есть незакрытая заморозка (текущая или ещё не
              начавшаяся), freeze_subscription всё равно откажет «уже есть
              незакрытая заморозка» — кнопка не должна предлагать заведомо
              проигрышное действие. */}
          {canFreeze ? (
            <ActionDialog label="Заморозить" title="Заморозить абонемент" onOpen={onOpen}>
              {(close) => (
                <FreezeForm
                  studentId={studentId}
                  subscriptionId={subscription.id}
                  today={today}
                  onDone={(notice, paymentId) => {
                    close()
                    onDone(notice, paymentId)
                  }}
                />
              )}
            </ActionDialog>
          ) : null}
          {/* Разморозить можно любую текущую или будущую заморозку: бессрочную
              и датированную, уже идущую, unfreeze_subscription заканчивает
              сегодня (0092 — решение 2 из 0015 отменено владельцем 6.10.2026),
              ещё не начавшуюся отменяет целиком. */}
          {subscription.freezeFrom ? <UnfreezeForm studentId={studentId} subscriptionId={subscription.id} onDone={onDone} /> : null}

          {/* Перенос остатка — про lessons_left, а не про деньги: на period/
              unlimited/исчерпанном абонементе transfer_remaining откажет
              «переносить нечего» (Architect-ревью 0054, Р7). */}
          {subscription.lessonsLeft != null && subscription.lessonsLeft > 0 && transferTo.length > 0 ? (
            <ActionDialog
              label="Перенести остаток"
              title="Перенести остаток"
              description={`Осталось ${subscription.lessonsLeft} зан. — перейдут другому ребёнку этого плательщика.`}
              onOpen={onOpen}
            >
              {(close) => (
                <TransferForm
                  studentId={studentId}
                  subscriptionId={subscription.id}
                  siblings={transferTo}
                  onDone={(notice, paymentId) => {
                    close()
                    onDone(notice, paymentId)
                  }}
                />
              )}
            </ActionDialog>
          ) : null}

          {/* Отменить доступно всегда (даже при возврате 0 — истёкший срок,
              исчерпанный пакет, 0054), пока за отработанное заплачено. При
              недоплате — только владельцу списание (0090). */}
          {subscription.shortfallTiyin > 0 ? (
            isOwner ? (
              <ActionDialog
                label="Списать недоплату и закрыть"
                title="Списать недоплату"
                description={`Списать ${formatSom(subscription.shortfallTiyin)} без денег и закрыть абонемент. В кассе ничего не изменится, отменить списание нельзя.`}
                onOpen={onOpen}
              >
                {(close) => (
                  <WriteOffForm
                    studentId={studentId}
                    subscriptionId={subscription.id}
                    shortfallTiyin={subscription.shortfallTiyin}
                    onDone={(notice) => {
                      close()
                      onDone(notice)
                    }}
                  />
                )}
              </ActionDialog>
            ) : null
          ) : (
            <ActionDialog
              variant="ghost"
              label={subscription.payoutTiyin > 0 ? t('sale', 'refund') : t('sale', 'cancelOnly')}
              title={subscription.payoutTiyin > 0 ? 'Вернуть деньги и отменить абонемент' : 'Отменить абонемент'}
              onOpen={onOpen}
            >
              {(close) => (
                <RefundForm
                  studentId={studentId}
                  subscriptionId={subscription.id}
                  refundTiyin={subscription.refundTiyin}
                  payoutTiyin={subscription.payoutTiyin}
                  isPeriod={subscription.endsAt != null}
                  sources={sources}
                  onCancel={close}
                  onDone={(notice, paymentId) => {
                    close()
                    onDone(notice, paymentId)
                  }}
                />
              )}
            </ActionDialog>
          )}
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
  canManage,
  isOwner = false,
  hideBalance = false,
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
  /**
   * owner/admin/registrar — продажа, оплата, заморозка, возврат, перенос;
   * родитель — те же цифры (оплачено/график рассрочки), но без единой кнопки
   * и без вкладки «Посещения» (attendance закрыта родителю целиком, 0044).
   */
  canManage: boolean
  /** Владелец центра — кнопка «Списать недоплату» (0090); право проверяет база. */
  isOwner?: boolean
  /** Остаток и долг уже показаны в шапке карточки (StudentSummary) — второй раз не рисуем. */
  hideBalance?: boolean
}) {
  const [tab, setTab] = useState<'subscriptions' | 'attendance'>('subscriptions')
  // Итог последнего действия — над списком: диалог после успеха закрывается,
  // а карточка перерисовывается по ответу сервера (revalidatePath).
  // Итог — в провайдер страницы (внизу экрана, один на страницу: e2e ждут
  // ровно один role=status), без провайдера — над списком.
  const pageNotice = usePageNotice()
  const [localNotice, setLocalNotice] = useState<Notice>(null)
  const setNotice = pageNotice ?? setLocalNotice
  const done: Done = (text, paymentId) =>
    setNotice({
      text,
      href: paymentId ? receiptHref(paymentId, `/app/students/${studentId}`) : undefined,
      linkLabel: 'Квитанция',
    })
  const [sellOpen, setSellOpen] = useState(false)
  const [sellRound, setSellRound] = useState(0)

  const live = subscriptions.filter((s) => !isFinished(s))
  const finished = subscriptions.filter((s) => isFinished(s))

  const card = (subscription: SubscriptionView) => (
    <SubscriptionCard
      key={subscription.id}
      studentId={studentId}
      subscription={subscription}
      siblings={siblings}
      sources={sources}
      timeZone={timeZone}
      canManage={canManage}
      isOwner={isOwner}
      today={today}
      onDone={done}
      onOpen={() => setNotice(null)}
    />
  )

  const subscriptionsList = (
    <div className="space-y-4">
      {hideBalance ? null : <BalanceStrip balance={balance} timeZone={timeZone} />}
      {canManage ? (
        <div className="flex flex-wrap items-center gap-2">
          <Button
            type="button"
            size="sm"
            onClick={() => {
              setNotice(null)
              setSellRound((r) => r + 1)
              setSellOpen(true)
            }}
          >
            {t('sale', 'open')}
          </Button>
          <Dialog
            open={sellOpen}
            onClose={() => setSellOpen(false)}
            title={t('sale', 'dialogTitle')}
            description={t('sale', 'dialogHint')}
          >
            <div key={sellRound}>
              {sellOpen ? (
                <SellForm
                  studentId={studentId}
                  types={types}
                  sources={sources}
                  today={today}
                  timeZone={timeZone}
                  onDone={(text, paymentId) => {
                    setSellOpen(false)
                    done(text, paymentId)
                  }}
                />
              ) : null}
            </div>
          </Dialog>
        </div>
      ) : null}
      {pageNotice ? null : <NoticeLine notice={localNotice} />}
      {subscriptions.length === 0 ? (
        <p className="text-sm text-muted-foreground">Абонементов пока нет.</p>
      ) : (
        <div className="space-y-3">
          {live.map(card)}
          {live.length === 0 ? <p className="text-sm text-muted-foreground">Действующих абонементов нет.</p> : null}
          {finished.length > 0 ? (
            <details className="group rounded-md border border-border">
              <summary className="cursor-pointer select-none px-3 py-2 text-sm font-medium text-muted-foreground">
                Завершённые абонементы ({finished.length})
              </summary>
              <div className="space-y-3 p-3 pt-0">{finished.map(card)}</div>
            </details>
          ) : null}
        </div>
      )}
    </div>
  )

  if (!canManage) {
    return subscriptionsList
  }

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

      {tab === 'subscriptions' ? subscriptionsList : <AttendanceHistoryTable rows={attendanceHistory} timeZone={timeZone} />}
    </div>
  )
}
