'use client'

import Link from 'next/link'
import { startTransition, useActionState, useEffect, useRef, useState, type FormEvent } from 'react'
import { useRouter } from 'next/navigation'
import { useFormStatus } from 'react-dom'
import { ConfirmSubmit } from '@/components/ui/confirm-submit'
import { formatSom } from '@logocrm/core'
import { closeMonth, payInstallment, recordExpense, recordPayment, reopenMonth, voidPayment, type FinanceState } from './finance-actions'
import { acceptDebtPayment, type DebtActionState } from '../debts/debt-actions'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'
import { usePageNotice } from '@/components/ui/page-notice'
import { useLastSource } from '@/lib/use-last-source'
import { receiptHref } from '@/lib/receipt'
import { label, t } from '@/lib/messages'

const initial: FinanceState = { message: '' }
const initialDebt: DebtActionState = { message: '' }

export type Option = { id: string; name: string }

/** Ученик в форме платежа: чей он (плательщик) и что по деньгам — из student_balance, не из браузера. */
export type StudentOption = Option & {
  payerId: string | null
  /** Долг за занятия + перерасход (0087) — то, что гасит «Оплата долга». */
  lessonDebtTiyin: number
  /** Аванс за занятия (lesson_credit_tiyin). */
  creditTiyin: number
  /** Просрочка по абонементу (0070) — оплачивается у абонемента на карточке. */
  overdueTiyin: number
}

function SubmitButton({
  children,
  variant,
  size = 'sm',
}: {
  children: React.ReactNode
  variant?: 'outline' | 'destructive'
  size?: 'sm' | 'default'
}) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size={size} variant={variant} disabled={pending}>
      {pending ? 'Секунду…' : children}
    </Button>
  )
}

/** pending из useActionState — для форм с onSubmit (useFormStatus там всегда false). */
function PendingButton({ pending, children }: { pending: boolean; children: React.ReactNode }) {
  return (
    <Button type="submit" size="sm" disabled={pending}>
      {pending ? 'Секунду…' : children}
    </Button>
  )
}

function SourceSelect({ id, sources, allowEmpty }: { id: string; sources: Option[]; allowEmpty?: boolean }) {
  const [value, remember] = useLastSource(sources)
  // «Без источника» не запоминается и не остаётся выбранным, когда пустой
  // вариант пропал (переключились на оплату долга — там источник обязателен).
  const [empty, setEmpty] = useState(false)
  const current = allowEmpty && empty ? '' : value
  return (
    <Select
      id={id}
      name="sourceId"
      value={current}
      onChange={(e) => {
        const next = e.target.value
        setEmpty(next === '')
        if (next) remember(next)
      }}
    >
      {allowEmpty ? <option value="">{t('finance', 'noSourceOption')}</option> : null}
      {sources.map((s) => (
        <option key={s.id} value={s.id}>
          {s.name}
        </option>
      ))}
    </Select>
  )
}

/**
 * Действие формы с итогом из обёртки — до коммита ответа (тот же приём, что
 * в панели абонементов): если успех убирает форму (строка рассрочки оплачена
 * и пропала из списка), эффект после коммита уже не выполнился бы, и итог с
 * квитанцией пропал бы.
 */
function useResultAction<S extends { done?: number; message?: string }>(
  action: (prev: S, formData: FormData) => Promise<S>,
  initialState: S,
  onDone: (state: S) => void,
) {
  const onDoneRef = useRef(onDone)
  onDoneRef.current = onDone
  // Awaited<S> у объектного S — тот же S; TypeScript не сводит это в дженерике сам.
  return useActionState<S, FormData>(async (prev, formData) => {
    const next = await action(prev as S, formData)
    if (next.done) onDoneRef.current(next)
    return next
  }, initialState as Awaited<S>)
}

function somToTiyin(value: string): number {
  const som = Number(value.replace(',', '.').replace(/\s/g, ''))
  return Number.isFinite(som) ? Math.round(som * 100) : 0
}

/**
 * «Принять оплату» в шапке «Финансов» — диалог вместо формы, которая раньше
 * всегда висела внизу страницы.
 *
 * Главная ловушка, которую он закрывает: оплата разового занятия «вне
 * абонемента» записывалась обычным платежом и долг за занятия НЕ гасила
 * (гасит только платёж с covers_lesson_debt, 0087) — касса росла, долг
 * оставался, родителю шло напоминание. Теперь, если у выбранного ребёнка
 * есть долг за занятия, поступление по умолчанию проводится как оплата
 * долга (accept_lesson_debt_payment); «прочее поступление» — осознанный выбор.
 * Возврат при авансе — предупреждение: аванс возвращается с карточки, иначе
 * он остаётся в счёте занятий и оплачивает их второй раз.
 */
export function PaymentDialog({
  payers,
  students,
  sources,
  today,
}: {
  payers: Option[]
  students: StudentOption[]
  sources: Option[]
  today: string
}) {
  const [open, setOpen] = useState(false)
  const [round, setRound] = useState(0)
  const notice = usePageNotice()
  return (
    <>
      <Button
        type="button"
        onClick={() => {
          notice?.(null)
          setRound((r) => r + 1)
          setOpen(true)
        }}
      >
        {t('finance', 'acceptPayment')}
      </Button>
      <Dialog open={open} onClose={() => setOpen(false)} title={t('finance', 'acceptPayment')} description={t('finance', 'newPaymentHint')}>
        {open ? (
          <PaymentForm
            key={round}
            payers={payers}
            students={students}
            sources={sources}
            today={today}
            onDone={(text, paymentId) => {
              setOpen(false)
              notice?.({ text, href: paymentId ? receiptHref(paymentId, '/app/finance') : undefined, linkLabel: 'Квитанция' })
            }}
          />
        ) : null}
      </Dialog>
    </>
  )
}

function PaymentForm({
  payers,
  students,
  sources,
  today,
  onDone,
}: {
  payers: Option[]
  students: StudentOption[]
  sources: Option[]
  today: string
  onDone: (text: string, paymentId?: string) => void
}) {
  const router = useRouter()
  const [state, formAction, pending] = useResultAction(recordPayment, initial, (next) =>
    onDone(next.notice ?? t('finance', 'paymentRecorded'), next.paymentId),
  )
  const [debtState, debtAction, debtPending] = useResultAction(acceptDebtPayment, initialDebt, (next) =>
    onDone(next.notice ?? 'Оплата принята', next.paymentId),
  )
  const [payerId, setPayerId] = useState('')
  const [studentId, setStudentId] = useState('')
  const [kind, setKind] = useState<'payment' | 'refund' | 'correction'>('payment')
  const [purpose, setPurpose] = useState<'debt' | 'other'>('debt')
  const [amountSom, setAmountSom] = useState('')

  const ownStudents = payerId ? students.filter((s) => s.payerId === payerId) : students
  const student = students.find((s) => s.id === studentId)
  const debtMode = kind === 'payment' && Boolean(student && student.lessonDebtTiyin > 0) && purpose === 'debt'

  // Долг изменился, пока открывали форму (23514), — свежие суммы с сервера.
  useEffect(() => {
    if (debtState.message) router.refresh()
  }, [debtState, router])

  function onPayer(id: string) {
    setPayerId(id)
    if (studentId && !students.some((s) => s.id === studentId && s.payerId === id)) setStudentId('')
  }

  function onStudent(id: string) {
    setStudentId(id)
    const picked = students.find((s) => s.id === id)
    if (picked?.payerId && !payerId) setPayerId(picked.payerId)
    if (picked && picked.lessonDebtTiyin > 0 && kind === 'payment') {
      setPurpose('debt')
      setAmountSom(String(picked.lessonDebtTiyin / 100))
    }
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const formData = new FormData(event.currentTarget)
    startTransition(() => (debtMode ? debtAction(formData) : formAction(formData)))
  }

  const extraTiyin = debtMode && student ? somToTiyin(amountSom) - student.lessonDebtTiyin : 0

  return (
    <form onSubmit={submit} className="space-y-4">
      {debtMode && student ? <input type="hidden" name="expectedTiyin" value={student.lessonDebtTiyin} /> : null}
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor="payment-payer">{t('finance', 'payer')}</Label>
          <Select id="payment-payer" name="payerId" required value={payerId} onChange={(e) => onPayer(e.target.value)}>
            <option value="">{t('finance', 'choosePayer')}</option>
            {payers.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="payment-student">{t('finance', 'student')}</Label>
          <Select id="payment-student" name="studentId" value={studentId} onChange={(e) => onStudent(e.target.value)} required={debtMode}>
            <option value="">{t('finance', 'noStudent')}</option>
            {ownStudents.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="payment-kind">{t('finance', 'kind')}</Label>
          <Select
            id="payment-kind"
            name="kind"
            value={kind}
            onChange={(e) => setKind(e.target.value as 'payment' | 'refund' | 'correction')}
          >
            {(['payment', 'refund', 'correction'] as const).map((value) => (
              <option key={value} value={value}>
                {label('paymentKind', value)}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="payment-amount">{t('finance', 'amountSom')}</Label>
          <Input
            id="payment-amount"
            name="amountSom"
            type="number"
            inputMode="decimal"
            min={0}
            step="0.01"
            required
            value={amountSom}
            onChange={(e) => setAmountSom(e.target.value)}
          />
        </div>
      </div>

      {kind === 'payment' && student && student.lessonDebtTiyin > 0 ? (
        <fieldset className="space-y-2 rounded-md border border-border p-3 text-sm">
          <legend className="px-1 font-medium">{t('finance', 'purposeTitle')}</legend>
          <label className="flex items-start gap-2">
            <input type="radio" name="purpose" value="debt" checked={purpose === 'debt'} onChange={() => setPurpose('debt')} className="mt-1" />
            <span>{t('finance', 'purposeDebt', { sum: formatSom(student.lessonDebtTiyin) })}</span>
          </label>
          <label className="flex items-start gap-2">
            <input type="radio" name="purpose" value="other" checked={purpose === 'other'} onChange={() => setPurpose('other')} className="mt-1" />
            <span>{t('finance', 'purposeOther')}</span>
          </label>
          {extraTiyin > 0 ? <p className="text-info">{t('finance', 'purposeExtra', { sum: formatSom(extraTiyin) })}</p> : null}
        </fieldset>
      ) : null}
      {kind === 'payment' && student && student.overdueTiyin > 0 ? (
        <p className="rounded-md bg-warning-bg px-3 py-2 text-sm text-warning">
          {t('finance', 'overdueHint', { sum: formatSom(student.overdueTiyin) })}{' '}
          <Link href={`/app/students/${student.id}#subscriptions`} className="font-medium underline underline-offset-4">
            {t('finance', 'openCard')}
          </Link>
        </p>
      ) : null}
      {kind === 'refund' && student && student.creditTiyin > 0 ? (
        <p className="rounded-md bg-warning-bg px-3 py-2 text-sm text-warning">
          {t('finance', 'creditRefundHint', { sum: formatSom(student.creditTiyin) })}{' '}
          <Link href={`/app/students/${student.id}`} className="font-medium underline underline-offset-4">
            {t('finance', 'openCard')}
          </Link>
        </p>
      ) : null}

      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor="payment-source">{t('finance', 'source')}</Label>
          {/* Оплате долга источник обязателен (0087); прочему платежу — по желанию, как раньше. */}
          <SourceSelect id="payment-source" sources={sources} allowEmpty={!debtMode} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="payment-date">{t('finance', 'date')}</Label>
          <Input id="payment-date" name="paidOn" type="date" defaultValue={today} max={today} required />
        </div>
        <div className="space-y-1 sm:col-span-2">
          <Label htmlFor="payment-comment">{t('finance', 'comment')}</Label>
          <Input id="payment-comment" name="comment" maxLength={500} placeholder={debtMode ? 'Оплата долга за занятия' : undefined} />
        </div>
      </div>
      <FormError message={debtMode ? debtState.message : state.message} />
      <PendingButton pending={debtMode ? debtPending : pending}>
        {debtMode ? t('finance', 'submitDebtPayment') : t('finance', 'submitPayment')}
      </PendingButton>
    </form>
  )
}

/** «Добавить расход» в шапке — диалог; итог и квитанции у расхода нет, только строка в списке. */
export function ExpenseDialog({ categories, sources, today }: { categories: Option[]; sources: Option[]; today: string }) {
  const [open, setOpen] = useState(false)
  const [round, setRound] = useState(0)
  const notice = usePageNotice()
  return (
    <>
      <Button
        type="button"
        variant="outline"
        onClick={() => {
          notice?.(null)
          setRound((r) => r + 1)
          setOpen(true)
        }}
      >
        {t('finance', 'addExpense')}
      </Button>
      <Dialog open={open} onClose={() => setOpen(false)} title={t('finance', 'newExpense')}>
        {open ? (
          <ExpenseForm
            key={round}
            categories={categories}
            sources={sources}
            today={today}
            onDone={(text) => {
              setOpen(false)
              notice?.({ text })
            }}
          />
        ) : null}
      </Dialog>
    </>
  )
}

function ExpenseForm({
  categories,
  sources,
  today,
  onDone,
}: {
  categories: Option[]
  sources: Option[]
  today: string
  onDone: (text: string) => void
}) {
  const [state, formAction, pending] = useResultAction(recordExpense, initial, (next) =>
    onDone(next.notice ?? t('finance', 'expenseRecorded')),
  )

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const formData = new FormData(event.currentTarget)
    startTransition(() => formAction(formData))
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor="expense-category">{t('finance', 'category')}</Label>
          <Select id="expense-category" name="categoryId" required defaultValue="">
            <option value="">{t('finance', 'chooseCategory')}</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="expense-kind">{t('finance', 'kind')}</Label>
          <Select id="expense-kind" name="kind" defaultValue="expense">
            {(['expense', 'refund', 'correction'] as const).map((kind) => (
              <option key={kind} value={kind}>
                {label('expenseKind', kind)}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="expense-amount">{t('finance', 'amountSom')}</Label>
          <Input id="expense-amount" name="amountSom" type="number" inputMode="decimal" min={0} step="0.01" required />
        </div>
        <div className="space-y-1">
          <Label htmlFor="expense-source">{t('finance', 'source')}</Label>
          <SourceSelect id="expense-source" sources={sources} allowEmpty />
        </div>
        <div className="space-y-1">
          <Label htmlFor="expense-date">{t('finance', 'date')}</Label>
          <Input id="expense-date" name="paidOn" type="date" defaultValue={today} max={today} required />
        </div>
        <div className="space-y-1 sm:col-span-2">
          <Label htmlFor="expense-comment">{t('finance', 'comment')}</Label>
          <Input id="expense-comment" name="comment" maxLength={500} />
        </div>
      </div>
      <p className="text-xs text-muted-foreground">
        {t('finance', 'categoriesHint')}{' '}
        <Link href="/app/settings/expense-categories" className="underline underline-offset-4">
          {t('finance', 'categoriesLink')}
        </Link>
      </p>
      <FormError message={state.message} />
      <PendingButton pending={pending}>{t('finance', 'submitExpense')}</PendingButton>
    </form>
  )
}

export function PayInstallmentForm({
  installmentId,
  dueThroughTiyin,
  rowRemainingTiyin,
  sources,
  defaultSourceId,
}: {
  installmentId: string
  /** Сколько проведёт pay_installment — всё по эту строку включительно (installments_view, 0100). */
  dueThroughTiyin: number
  /** Остаток самой строки — для подсказки «вместе с предыдущими». */
  rowRemainingTiyin: number
  sources: Option[]
  /** Источник последнего платежа по этому абонементу — если он ещё активен. */
  defaultSourceId?: string
}) {
  const notice = usePageNotice()
  const router = useRouter()
  const [state, formAction] = useResultAction(payInstallment, initial, (next) =>
    notice?.({
      text: next.notice ?? t('finance', 'installmentPaid'),
      href: next.paymentId ? receiptHref(next.paymentId, '/app/finance?tab=installments') : undefined,
      linkLabel: 'Квитанция',
    }),
  )
  const [source, setSource] = useLastSource(sources, defaultSourceId)
  // Сумма изменилась (23514) — перечитать страницу: на кнопке станет свежая.
  useEffect(() => {
    if (state.message) router.refresh()
  }, [state, router])

  return (
    <form action={formAction} className="flex flex-wrap items-center justify-end gap-2">
      <input type="hidden" name="installmentId" value={installmentId} />
      <input type="hidden" name="expectedAmountTiyin" value={dueThroughTiyin} />
      <Select name="sourceId" aria-label={t('finance', 'source')} value={source} onChange={(e) => setSource(e.target.value)} className="w-auto">
        {sources.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name}
          </option>
        ))}
      </Select>
      <SubmitButton variant="outline">
        {t('finance', 'markPaid')} · {formatSom(dueThroughTiyin)}
      </SubmitButton>
      {dueThroughTiyin > rowRemainingTiyin ? (
        <span className="w-full text-right text-xs text-muted-foreground">{t('finance', 'withPrevious')}</span>
      ) : null}
      <FormError message={state.message} />
      {notice ? null : <FormNotice message={state.notice} />}
    </form>
  )
}

export function ClosePeriodForm({
  month,
  monthLabel,
  openCount,
}: {
  month: string
  monthLabel: string
  openCount: number | null
}) {
  const [state, formAction] = useActionState(closeMonth, initial)
  return (
    <form action={formAction} className="space-y-2">
      <input type="hidden" name="month" value={month} />
      <p className="text-sm text-muted-foreground">
        {openCount === null
          ? t('finance', 'closeMonthHintUnknown')
          : t('finance', 'closeMonthHint', { count: openCount })}
      </p>
      <ConfirmSubmit
        size="default"
        variant="default"
        confirmVariant="default"
        label={t('finance', 'closeMonth', { month: monthLabel })}
        question={t('finance', 'closeMonthConfirm', { month: monthLabel })}
      />
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

export function ReopenPeriodForm({ month }: { month: string }) {
  const [state, formAction] = useActionState(reopenMonth, initial)
  return (
    <form action={formAction} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="month" value={month} />
      <SubmitButton variant="outline">{t('finance', 'reopenMonth')}</SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

/**
 * «Отменить» у ошибочного поступления (0093) — только владелец. Причина
 * обязательна; подтверждение называет сумму. Отмена — корректировка с
 * минусом той же датой, исходная строка не стирается.
 */
export function VoidPaymentForm({ paymentId, amountTiyin }: { paymentId: string; amountTiyin: number }) {
  const [state, formAction] = useActionState(voidPayment, initial)
  const [open, setOpen] = useState(false)
  // Управляемое поле: <form action> React 19 сбрасывает форму и при отказе — причина не должна пропадать.
  const [reason, setReason] = useState('')

  if (!open) {
    return (
      <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(true)}>
        Отменить
      </Button>
    )
  }

  return (
    <form action={formAction} className="space-y-2">
      <input type="hidden" name="paymentId" value={paymentId} />
      <Input
        name="reason"
        required
        maxLength={500}
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        placeholder="Причина, например «дубль перевода»"
        aria-label="Причина отмены"
      />
      <div className="flex gap-2">
        <ConfirmSubmit
          label="Отменить платёж"
          question={`Отменить платёж ${formatSom(amountTiyin)}? Рядом появится отмена на ту же сумму, в кассе станет на ${formatSom(amountTiyin)} меньше.`}
        />
        <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>
          Не отменять
        </Button>
      </div>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}
