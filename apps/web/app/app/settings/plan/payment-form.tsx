'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { label, t } from '@/lib/messages'
import { submitPayment, withdrawPayment, type PlanState } from './actions'

const initial: PlanState = {}

const SOURCES = ['mbank', 'elcart', 'cash', 'other'] as const

function SubmitButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" disabled={pending}>
      {children}
    </Button>
  )
}

/**
 * Форма заявки: тариф, месяцы, способ. Сумму не считает и не показывает —
 * её считает submit_platform_payment из прайса (0051 Р11); центр видит
 * итог в карточке открытой заявки, которую вернул сервер.
 */
export function PaymentForm({
  plans,
  currentPlan,
}: {
  plans: { code: string; name: string; priceTiyin: number }[]
  currentPlan: string
}) {
  const [state, action] = useActionState(submitPayment, initial)
  const defaultPlan = plans.some((p) => p.code === currentPlan) ? currentPlan : (plans[0]?.code ?? '')

  return (
    <form action={action} className="space-y-3">
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="space-y-1 text-sm">
          <span className="font-medium">{t('plan', 'planField')}</span>
          <select
            name="plan"
            defaultValue={defaultPlan}
            className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            {plans.map((p) => (
              <option key={p.code} value={p.code}>
                {p.name}
              </option>
            ))}
          </select>
        </label>

        <label className="space-y-1 text-sm">
          <span className="font-medium">{t('plan', 'monthsField')}</span>
          <input
            type="number"
            name="months"
            min={1}
            max={24}
            defaultValue={1}
            required
            className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          />
        </label>

        <label className="space-y-1 text-sm">
          <span className="font-medium">{t('plan', 'sourceField')}</span>
          <select
            name="source"
            defaultValue="mbank"
            className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            {SOURCES.map((s) => (
              <option key={s} value={s}>
                {label('platformPaymentSource', s)}
              </option>
            ))}
          </select>
        </label>
      </div>

      <label className="block space-y-1 text-sm">
        <span className="font-medium">{t('plan', 'noteField')}</span>
        <input
          type="text"
          name="note"
          maxLength={200}
          placeholder={t('plan', 'notePlaceholder')}
          className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        />
      </label>

      <p className="text-xs text-muted-foreground">{t('plan', 'amountHint')}</p>

      <SubmitButton>{t('plan', 'submit')}</SubmitButton>

      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

/** Отзыв открытой заявки — одна кнопка, состояние с сервера. */
export function WithdrawForm({ paymentId }: { paymentId: string }) {
  const [state, action] = useActionState(withdrawPayment, initial)
  return (
    <form action={action} className="space-y-2">
      <input type="hidden" name="paymentId" value={paymentId} />
      <Button type="submit" size="sm" variant="outline">
        {t('plan', 'withdraw')}
      </Button>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}
