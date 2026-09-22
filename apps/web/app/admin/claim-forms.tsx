'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { confirmPayment, rejectPayment, type AdminState } from './actions'

const initial: AdminState = {}

function SubmitButton({ children, variant }: { children: React.ReactNode; variant?: 'outline' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {children}
    </Button>
  )
}

const field = 'w-full rounded-md border border-input bg-background px-3 py-2 text-sm'

/**
 * Две формы на заявку: подтвердить (тариф, месяцы, сумма — предзаполнены из
 * заявки, но правятся: это параметры действия платформы) и отклонить с
 * причиной. Ответ — только с сервера, без оптимистичного состояния.
 */
export function ConfirmForm({
  paymentId,
  plans,
  claimedPlan,
  claimedMonths,
  claimedAmountSom,
}: {
  paymentId: string
  plans: { code: string; name: string }[]
  claimedPlan: string
  claimedMonths: number
  claimedAmountSom: number
}) {
  const [state, action] = useActionState(confirmPayment, initial)
  return (
    <form action={action} className="space-y-2">
      <input type="hidden" name="paymentId" value={paymentId} />
      <div className="grid gap-2 sm:grid-cols-3">
        <label className="space-y-1 text-xs">
          <span className="font-medium">{t('admin', 'planField')}</span>
          <select name="plan" defaultValue={claimedPlan} className={field}>
            {plans.map((p) => (
              <option key={p.code} value={p.code}>
                {p.name}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1 text-xs">
          <span className="font-medium">{t('admin', 'monthsField')}</span>
          <input type="number" name="months" min={1} max={24} defaultValue={claimedMonths} required className={field} />
        </label>
        <label className="space-y-1 text-xs">
          <span className="font-medium">{t('admin', 'amountField')}</span>
          <input
            type="number"
            name="amountSom"
            min={1}
            step="0.01"
            defaultValue={claimedAmountSom}
            required
            className={field}
          />
        </label>
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" name="receiptReceived" defaultChecked className="h-4 w-4" />
        {t('admin', 'receiptReceived')}
      </label>
      <SubmitButton>{t('admin', 'confirm')}</SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

export function RejectForm({ paymentId }: { paymentId: string }) {
  const [state, action] = useActionState(rejectPayment, initial)
  return (
    <form action={action} className="space-y-2">
      <input type="hidden" name="paymentId" value={paymentId} />
      <input
        type="text"
        name="reason"
        required
        maxLength={200}
        placeholder={t('admin', 'reasonPlaceholder')}
        className={field}
      />
      <SubmitButton variant="outline">{t('admin', 'reject')}</SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}
