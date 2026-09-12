'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { approveSalary, cancelSalaryRun, recordSalaryAdjustment, type SalaryState } from './salary-actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'

const initial: SalaryState = { message: '' }

function SubmitButton({ children, variant }: { children: React.ReactNode; variant?: 'outline' | 'destructive' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {pending ? 'Секунду…' : children}
    </Button>
  )
}

export function AdjustmentForm({ teacherId, month }: { teacherId: string; month: string }) {
  const [state, formAction] = useActionState(recordSalaryAdjustment, initial)
  return (
    <form action={formAction} className="flex flex-wrap items-end gap-2">
      <input type="hidden" name="teacherId" value={teacherId} />
      <input type="hidden" name="month" value={month} />
      <div className="space-y-1">
        <Label htmlFor={`adj-amount-${teacherId}`}>{t('salary', 'adjustmentAmount')}</Label>
        <Input id={`adj-amount-${teacherId}`} name="amountSom" type="number" step="0.01" required className="w-40" />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`adj-reason-${teacherId}`}>{t('salary', 'adjustmentReason')}</Label>
        <Input id={`adj-reason-${teacherId}`} name="reason" required minLength={2} maxLength={200} className="w-64" />
      </div>
      <SubmitButton variant="outline">{t('salary', 'submitAdjustment')}</SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

export function ApproveForm({ teacherId, month, monthLabel }: { teacherId: string; month: string; monthLabel: string }) {
  const [state, formAction] = useActionState(approveSalary, initial)
  return (
    <form action={formAction} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="teacherId" value={teacherId} />
      <input type="hidden" name="month" value={month} />
      <SubmitButton>{t('salary', 'approve', { month: monthLabel })}</SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

export function CancelRunForm({ teacherId, month }: { teacherId: string; month: string }) {
  const [state, formAction] = useActionState(cancelSalaryRun, initial)
  return (
    <form action={formAction} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="teacherId" value={teacherId} />
      <input type="hidden" name="month" value={month} />
      <SubmitButton variant="destructive">{t('salary', 'cancelRun')}</SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}
