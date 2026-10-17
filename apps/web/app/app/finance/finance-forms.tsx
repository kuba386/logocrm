'use client'

import Link from 'next/link'
import { startTransition, useActionState, useEffect, useRef, useState, type FormEvent } from 'react'
import { useRouter } from 'next/navigation'
import { useFormStatus } from 'react-dom'
import { ConfirmSubmit } from '@/components/ui/confirm-submit'
import { formatSom } from '@logocrm/core'
import {
  cancelCashCount,
  closeMonth,
  previewCashCount,
  recordCashCount,
  payInstallment,
  recordCashTransfer,
  recordExpense,
  recordPayment,
  reopenMonth,
  voidExpense,
  voidPayment,
  type FinanceState,
} from './finance-actions'
import { acceptDebtPayment, acceptLessonAdvance, type DebtActionState } from '../debts/debt-actions'
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
  const [advanceState, advanceAction, advancePending] = useResultAction(acceptLessonAdvance, initialDebt, (next) =>
    onDone(next.notice ?? 'Аванс принят', next.paymentId),
  )
  const [payerId, setPayerId] = useState('')
  const [studentId, setStudentId] = useState('')
  const [kind, setKind] = useState<'payment' | 'refund' | 'correction'>('payment')
  // У ребёнка без долга назначение не выбрано заранее: «аванс» и «прочее» по-разному
  // ложатся в счёт (0087 Р1 — флаг долга ставит только явное действие).
  const [purpose, setPurpose] = useState<'debt' | 'advance' | 'other' | ''>('debt')
  const [amountSom, setAmountSom] = useState('')

  const ownStudents = payerId ? students.filter((s) => s.payerId === payerId) : students
  const student = students.find((s) => s.id === studentId)
  const debtMode = kind === 'payment' && Boolean(student && student.lessonDebtTiyin > 0) && purpose === 'debt'
  const advanceMode = kind === 'payment' && Boolean(student && student.lessonDebtTiyin === 0) && purpose === 'advance'
  const accountMode = debtMode || advanceMode

  // Долг или аванс изменились, пока открывали форму (23514), — свежие суммы с сервера.
  useEffect(() => {
    if (debtState.message || advanceState.message) router.refresh()
  }, [debtState, advanceState, router])

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
    } else if (picked) {
      setPurpose('')
    }
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const formData = new FormData(event.currentTarget)
    startTransition(() => (debtMode ? debtAction(formData) : advanceMode ? advanceAction(formData) : formAction(formData)))
  }

  const extraTiyin = debtMode && student ? somToTiyin(amountSom) - student.lessonDebtTiyin : 0

  return (
    <form onSubmit={submit} className="space-y-4">
      {debtMode && student ? <input type="hidden" name="expectedTiyin" value={student.lessonDebtTiyin} /> : null}
      {advanceMode && student ? <input type="hidden" name="expectedCreditTiyin" value={student.creditTiyin} /> : null}
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
          <Select id="payment-student" name="studentId" value={studentId} onChange={(e) => onStudent(e.target.value)} required={accountMode}>
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
      {kind === 'payment' && student && student.lessonDebtTiyin === 0 ? (
        <fieldset className="space-y-2 rounded-md border border-border p-3 text-sm">
          <legend className="px-1 font-medium">{t('finance', 'purposeTitle')}</legend>
          <label className="flex items-start gap-2">
            <input
              type="radio"
              name="purpose"
              value="advance"
              required
              checked={purpose === 'advance'}
              onChange={() => setPurpose('advance')}
              className="mt-1"
            />
            <span>
              {t('finance', 'purposeAdvance', {
                credit: student.creditTiyin > 0 ? t('finance', 'purposeAdvanceCredit', { sum: formatSom(student.creditTiyin) }) : '',
              })}
            </span>
          </label>
          <label className="flex items-start gap-2">
            <input type="radio" name="purpose" value="other" required checked={purpose === 'other'} onChange={() => setPurpose('other')} className="mt-1" />
            <span>{t('finance', 'purposeOtherNoDebt')}</span>
          </label>
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
          {/* Живым деньгам касса обязательна (0102: иначе они мимо остатка); без кассы — только корректировка. */}
          <SourceSelect id="payment-source" sources={sources} allowEmpty={kind === 'correction'} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="payment-date">{t('finance', 'date')}</Label>
          <Input id="payment-date" name="paidOn" type="date" defaultValue={today} max={today} required />
        </div>
        <div className="space-y-1 sm:col-span-2">
          <Label htmlFor="payment-comment">{t('finance', 'comment')}</Label>
          <Input
            id="payment-comment"
            name="comment"
            maxLength={500}
            placeholder={debtMode ? 'Оплата долга за занятия' : advanceMode ? 'Аванс за занятия' : undefined}
          />
        </div>
      </div>
      <FormError message={debtMode ? debtState.message : advanceMode ? advanceState.message : state.message} />
      <PendingButton pending={debtMode ? debtPending : advanceMode ? advancePending : pending}>
        {debtMode ? t('finance', 'submitDebtPayment') : advanceMode ? t('finance', 'submitAdvance') : t('finance', 'submitPayment')}
      </PendingButton>
    </form>
  )
}

/** «Добавить расход» в шапке — диалог; итог и квитанции у расхода нет, только строка в списке. */
export function ExpenseDialog({
  categories,
  sources,
  today,
  salaryCategoryId,
}: {
  categories: Option[]
  sources: Option[]
  today: string
  /** Статья «Зарплата» (код salary) — при её выборе подсказка про выплату в «Зарплате» (0101). */
  salaryCategoryId?: string
}) {
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
            salaryCategoryId={salaryCategoryId}
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
  salaryCategoryId,
  onDone,
}: {
  categories: Option[]
  sources: Option[]
  today: string
  salaryCategoryId?: string
  onDone: (text: string) => void
}) {
  const [state, formAction, pending] = useResultAction(recordExpense, initial, (next) =>
    onDone(next.notice ?? t('finance', 'expenseRecorded')),
  )
  const [categoryId, setCategoryId] = useState('')
  const [expenseKind, setExpenseKind] = useState<'expense' | 'refund' | 'correction'>('expense')

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
          <Select id="expense-category" name="categoryId" required value={categoryId} onChange={(e) => setCategoryId(e.target.value)}>
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
          <Select id="expense-kind" name="kind" value={expenseKind} onChange={(e) => setExpenseKind(e.target.value as 'expense' | 'refund' | 'correction')}>
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
          {/* Живые деньги — с кассой (0102): иначе они не попадут в остаток, и сверка покажет недостачу. */}
          <SourceSelect id="expense-source" sources={sources} allowEmpty={expenseKind === 'correction'} />
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
      {/* Выплата специалисту из «Расходов» не попала бы в «Выплачено» на странице зарплаты (0101).
          Не запрет: зарплату сотрудникам без карточки специалиста проводят здесь. */}
      {salaryCategoryId && categoryId === salaryCategoryId ? (
        <p className="rounded-md bg-info-bg px-3 py-2 text-sm text-info">
          {t('finance', 'salaryCategoryHint')}{' '}
          <Link href="/app/salary" className="font-medium underline underline-offset-4">
            {t('finance', 'salaryCategoryLink')}
          </Link>
        </p>
      ) : null}
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

type TransferPrefill = { fromSourceId: string; toSourceId: string; amountSom: string }

function TransferForm({
  sources,
  today,
  prefill,
  onDone,
}: {
  sources: Option[]
  today: string
  prefill?: TransferPrefill
  onDone: (text: string) => void
}) {
  const [state, formAction, pending] = useResultAction(recordCashTransfer, initial, (next) =>
    onDone(next.notice ?? t('finance', 'transferRecorded')),
  )
  const [from, setFrom] = useState(prefill?.fromSourceId ?? sources[0]?.id ?? '')
  const [to, setTo] = useState(prefill?.toSourceId ?? sources.find((s) => s.id !== (prefill?.fromSourceId ?? sources[0]?.id))?.id ?? '')
  // Ключ идемпотентности (0101 А11): не при инициализации — случайный uuid на
  // сервере и клиенте разошёлся бы в гидратации. Новый — на каждый ответ сервера.
  const [transferKey, setTransferKey] = useState('')
  useEffect(() => {
    setTransferKey(crypto.randomUUID())
  }, [state])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const formData = new FormData(event.currentTarget)
    startTransition(() => formAction(formData))
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <input type="hidden" name="transferKey" value={transferKey} />
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor="transfer-from">{t('finance', 'transferFrom')}</Label>
          <Select id="transfer-from" name="fromSourceId" required value={from} onChange={(e) => setFrom(e.target.value)}>
            {sources.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="transfer-to">{t('finance', 'transferTo')}</Label>
          <Select id="transfer-to" name="toSourceId" required value={to} onChange={(e) => setTo(e.target.value)}>
            {sources.map((s) => (
              <option key={s.id} value={s.id} disabled={s.id === from}>
                {s.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="transfer-amount">{t('finance', 'amountSom')}</Label>
          <Input
            id="transfer-amount"
            name="amountSom"
            type="number"
            inputMode="decimal"
            min="0.01"
            step="0.01"
            required
            defaultValue={prefill?.amountSom}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="transfer-date">{t('finance', 'date')}</Label>
          <Input id="transfer-date" name="transferredOn" type="date" defaultValue={today} max={today} required />
        </div>
        <div className="space-y-1 sm:col-span-2">
          <Label htmlFor="transfer-comment">{t('finance', 'comment')}</Label>
          <Input id="transfer-comment" name="comment" maxLength={500} placeholder={t('finance', 'transferCommentPlaceholder')} />
        </div>
      </div>
      {from && from === to ? <p className="text-sm text-destructive">{t('finance', 'transferSameSource')}</p> : null}
      <FormError message={state.message} />
      <PendingButton pending={pending || !transferKey}>{t('finance', 'transferSubmit')}</PendingButton>
    </form>
  )
}

/**
 * «Перевод между кассами» (0101): наличные сдали в банк, терминал перечислил
 * на расчётный счёт. Итог центра за месяц не меняется — меняются итоги касс.
 * prefill — «Обратный перевод» у строки списка: исправить ошибочный перевод.
 */
export function TransferDialog({
  sources,
  today,
  prefill,
  label: buttonLabel,
}: {
  sources: Option[]
  today: string
  prefill?: TransferPrefill
  label?: string
}) {
  const [open, setOpen] = useState(false)
  const [round, setRound] = useState(0)
  const notice = usePageNotice()
  if (sources.length < 2) return null
  return (
    <>
      <Button
        type="button"
        variant={prefill ? 'ghost' : 'outline'}
        size={prefill ? 'sm' : 'default'}
        onClick={() => {
          notice?.(null)
          setRound((r) => r + 1)
          setOpen(true)
        }}
      >
        {buttonLabel ?? t('finance', 'transfer')}
      </Button>
      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title={prefill ? t('finance', 'transferReverseTitle') : t('finance', 'transfer')}
        description={t('finance', 'transferHint')}
      >
        {open ? (
          <TransferForm
            key={round}
            sources={sources}
            today={today}
            prefill={prefill}
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

/**
 * «Отменить» у ошибочного расхода (0101) — только владелец, причина обязательна.
 * Отмена — корректировка с минусом той же датой; у выплаты зарплаты уменьшится
 * «Выплачено» специалиста. Итог — в уведомление страницы из обёртки действия:
 * после отмены строка перерисовывается без этой формы, и её собственное
 * уведомление пропало бы вместе с ней.
 */
export function VoidExpenseForm({ expenseId, amountTiyin }: { expenseId: string; amountTiyin: number }) {
  const notice = usePageNotice()
  const [local, setLocal] = useState<string | undefined>(undefined)
  const [state, formAction] = useResultAction(voidExpense, initial, (next) => {
    const text = next.notice ?? 'Расход отменён'
    if (notice) notice({ text })
    else setLocal(text)
  })
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
      <input type="hidden" name="expenseId" value={expenseId} />
      <Input
        name="reason"
        required
        maxLength={500}
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        placeholder="Причина, например «внесли дважды»"
        aria-label="Причина отмены"
      />
      <div className="flex gap-2">
        <ConfirmSubmit
          label="Отменить расход"
          question={`Отменить расход ${formatSom(amountTiyin)}? Рядом появится отмена на ту же сумму, в кассе станет на ${formatSom(amountTiyin)} больше.`}
        />
        <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>
          Не отменять
        </Button>
      </div>
      <FormError message={state.message} />
      <FormNotice message={local} />
    </form>
  )
}

function CashCountForm({
  sourceId,
  today,
  onDone,
}: {
  sourceId: string
  today: string
  onDone: (text: string) => void
}) {
  const [state, formAction, pending] = useResultAction(recordCashCount, initial, (next) => onDone(next.notice ?? t('finance', 'cashCountSaved')))
  const [day, setDay] = useState(today)
  const [preview, setPreview] = useState<{ expectedTiyin: number; lastCountOn: string | null } | null>(null)
  const [previewError, setPreviewError] = useState('')
  const [countKey, setCountKey] = useState('')
  useEffect(() => {
    setCountKey(crypto.randomUUID())
  }, [state])
  // Остаток по учёту — из базы (cash_count_preview), заново на каждую дату и после отказа 23514.
  useEffect(() => {
    let alive = true
    setPreview(null)
    setPreviewError('')
    previewCashCount(sourceId, day).then((res) => {
      if (!alive) return
      if ('expectedTiyin' in res) setPreview({ expectedTiyin: res.expectedTiyin, lastCountOn: res.lastCountOn })
      else setPreviewError(res.message)
    })
    return () => {
      alive = false
    }
  }, [sourceId, day, state])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const formData = new FormData(event.currentTarget)
    startTransition(() => formAction(formData))
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <input type="hidden" name="sourceId" value={sourceId} />
      <input type="hidden" name="countKey" value={countKey} />
      {preview ? <input type="hidden" name="expectedTiyin" value={preview.expectedTiyin} /> : null}
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor="count-day">{t('finance', 'cashCountDay')}</Label>
          <Input id="count-day" name="countedOn" type="date" max={today} value={day} onChange={(e) => setDay(e.target.value)} required />
        </div>
        <div className="space-y-1">
          <Label htmlFor="count-sum">{t('finance', 'cashCountCounted')}</Label>
          <Input id="count-sum" name="countedSom" type="number" inputMode="decimal" min="0" step="0.01" required />
        </div>
      </div>
      <p className="rounded-md bg-muted/60 px-3 py-2 text-sm">
        {previewError
          ? previewError
          : preview
            ? t('finance', day === today ? 'cashCountExpectedNow' : 'cashCountExpectedDay', { sum: formatSom(preview.expectedTiyin) })
            : t('finance', 'cashCountLoading')}
        {preview && !preview.lastCountOn ? <span className="block text-xs text-muted-foreground">{t('finance', 'cashCountFirstHint')}</span> : null}
      </p>
      <div className="space-y-1">
        <Label htmlFor="count-comment">{t('finance', 'comment')}</Label>
        <Input id="count-comment" name="comment" maxLength={500} placeholder={t('finance', 'cashCountCommentPlaceholder')} />
      </div>
      <FormError message={state.message} />
      <PendingButton pending={pending || !preview || !countKey}>{t('finance', 'cashCountSubmit')}</PendingButton>
    </form>
  )
}

/**
 * «Сверить кассу» (0102): посчитали наличные или посмотрели выписку — вносим
 * факт. Первая сверка становится начальным остатком, следующие показывают
 * недостачу или излишек. Остаток по учёту и расхождение считает база.
 */
export function CashCountDialog({ sourceId, sourceName, today }: { sourceId: string; sourceName: string; today: string }) {
  const [open, setOpen] = useState(false)
  const [round, setRound] = useState(0)
  const notice = usePageNotice()
  return (
    <>
      <Button
        type="button"
        size="sm"
        variant="outline"
        className="max-sm:w-full"
        onClick={() => {
          notice?.(null)
          setRound((r) => r + 1)
          setOpen(true)
        }}
      >
        {t('finance', 'cashCount')}
      </Button>
      <Dialog open={open} onClose={() => setOpen(false)} title={t('finance', 'cashCountTitle', { name: sourceName })} description={t('finance', 'cashCountHint')}>
        {open ? (
          <CashCountForm
            key={round}
            sourceId={sourceId}
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

/** «Отменить» ошибочную сверку (0102) — только владелец, с причиной; итог — в уведомление страницы. */
export function CancelCashCountForm({ countId }: { countId: string }) {
  const notice = usePageNotice()
  const [local, setLocal] = useState<string | undefined>(undefined)
  const [state, formAction] = useResultAction(cancelCashCount, initial, (next) => {
    const text = next.notice ?? 'Сверка отменена'
    if (notice) notice({ text })
    else setLocal(text)
  })
  const [open, setOpen] = useState(false)
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
      <input type="hidden" name="countId" value={countId} />
      <Input name="reason" required maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Причина, например «не та касса»" aria-label="Причина отмены сверки" />
      <div className="flex gap-2">
        <ConfirmSubmit label="Отменить сверку" question="Отменить сверку? Остаток кассы снова будет считаться от предыдущей сверки." />
        <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>
          Не отменять
        </Button>
      </div>
      <FormError message={state.message} />
      <FormNotice message={local} />
    </form>
  )
}
