'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { formatSom } from '@logocrm/core'
import { closeMonth, payInstallment, recordExpense, recordPayment, reopenMonth, type FinanceState } from './finance-actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'
import { label, t } from '@/lib/messages'

const initial: FinanceState = { message: '' }

export type Option = { id: string; name: string }

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

export function PaymentForm({
  payers,
  students,
  sources,
  today,
}: {
  payers: Option[]
  students: Option[]
  sources: Option[]
  today: string
}) {
  const [state, formAction] = useActionState(recordPayment, initial)
  return (
    <form action={formAction} className="space-y-3 rounded-md border border-border p-3">
      <div>
        <p className="font-medium">{t('finance', 'newPayment')}</p>
        <p className="text-sm text-muted-foreground">{t('finance', 'newPaymentHint')}</p>
      </div>
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="space-y-1">
          <Label htmlFor="payment-payer">{t('finance', 'payer')}</Label>
          <Select id="payment-payer" name="payerId" required defaultValue="">
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
          <Select id="payment-student" name="studentId" defaultValue="">
            <option value="">{t('finance', 'noStudent')}</option>
            {students.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="payment-kind">{t('finance', 'kind')}</Label>
          <Select id="payment-kind" name="kind" defaultValue="payment">
            {(['payment', 'refund', 'correction'] as const).map((kind) => (
              <option key={kind} value={kind}>
                {label('paymentKind', kind)}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="payment-amount">{t('finance', 'amountSom')}</Label>
          <Input id="payment-amount" name="amountSom" type="number" min={0} step="0.01" required />
        </div>
        <div className="space-y-1">
          <Label htmlFor="payment-source">{t('finance', 'source')}</Label>
          <Select id="payment-source" name="sourceId" defaultValue={sources[0]?.id ?? ''}>
            <option value="">{t('finance', 'noSourceOption')}</option>
            {sources.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="payment-date">{t('finance', 'date')}</Label>
          <Input id="payment-date" name="paidOn" type="date" defaultValue={today} max={today} required />
        </div>
        <div className="space-y-1 sm:col-span-3">
          <Label htmlFor="payment-comment">{t('finance', 'comment')}</Label>
          <Input id="payment-comment" name="comment" maxLength={500} />
        </div>
      </div>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
      <SubmitButton>{t('finance', 'submitPayment')}</SubmitButton>
    </form>
  )
}

export function ExpenseForm({
  categories,
  sources,
  today,
}: {
  categories: Option[]
  sources: Option[]
  today: string
}) {
  const [state, formAction] = useActionState(recordExpense, initial)
  return (
    <form action={formAction} className="space-y-3 rounded-md border border-border p-3">
      <p className="font-medium">{t('finance', 'newExpense')}</p>
      <div className="grid gap-3 sm:grid-cols-3">
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
          <Input id="expense-amount" name="amountSom" type="number" min={0} step="0.01" required />
        </div>
        <div className="space-y-1">
          <Label htmlFor="expense-source">{t('finance', 'source')}</Label>
          <Select id="expense-source" name="sourceId" defaultValue={sources[0]?.id ?? ''}>
            <option value="">{t('finance', 'noSourceOption')}</option>
            {sources.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="expense-date">{t('finance', 'date')}</Label>
          <Input id="expense-date" name="paidOn" type="date" defaultValue={today} max={today} required />
        </div>
        <div className="space-y-1 sm:col-span-3">
          <Label htmlFor="expense-comment">{t('finance', 'comment')}</Label>
          <Input id="expense-comment" name="comment" maxLength={500} />
        </div>
      </div>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
      <SubmitButton>{t('finance', 'submitExpense')}</SubmitButton>
    </form>
  )
}

export function PayInstallmentForm({
  installmentId,
  amountTiyin,
  sources,
}: {
  installmentId: string
  amountTiyin: number
  sources: Option[]
}) {
  const [state, formAction] = useActionState(payInstallment, initial)
  return (
    <form action={formAction} className="flex flex-wrap items-center justify-end gap-2">
      <input type="hidden" name="installmentId" value={installmentId} />
      <Select name="sourceId" aria-label={t('finance', 'source')} defaultValue={sources[0]?.id ?? ''} className="w-auto">
        {sources.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name}
          </option>
        ))}
      </Select>
      <SubmitButton variant="outline">
        {t('finance', 'markPaid')} · {formatSom(amountTiyin)}
      </SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

export function ClosePeriodForm({ month, monthLabel, plannedCount }: { month: string; monthLabel: string; plannedCount: number }) {
  const [state, formAction] = useActionState(closeMonth, initial)
  return (
    <form action={formAction} className="space-y-2">
      <input type="hidden" name="month" value={month} />
      <p className="text-sm text-muted-foreground">{t('finance', 'closeMonthHint', { count: plannedCount })}</p>
      <SubmitButton size="default">{t('finance', 'closeMonth', { month: monthLabel })}</SubmitButton>
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
