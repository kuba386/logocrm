'use client'

import { useActionState, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { formatSom, planSwitchDays, platformPaymentAmountTiyin, prepayDiscountPercent } from '@logocrm/core'
import { label, t } from '@/lib/messages'
import { submitPayment, withdrawPayment, type PlanState } from './actions'
import { SubmitButton as PendingSubmit } from '@/components/ui/submit-button'

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
 * Форма заявки: тариф, месяцы, способ. Сумма в заявке — из
 * submit_platform_payment (0051 Р11, скидка 0084); здесь только подсказка
 * зеркалом из packages/core, чтобы центр видел скидку до отправки.
 */
export function PaymentForm({
  plans,
  currentPlan,
  current,
}: {
  /** teachers/students — лимиты тарифа, -1 — без ограничения. */
  plans: { code: string; name: string; priceTiyin: number; teachers: number; students: number }[]
  currentPlan: string
  /** Текущий тариф центра: остаток дней и наполнение — из center_limits. */
  current: {
    name: string
    priceTiyin: number
    isTrial: boolean
    daysLeft: number | null
    teachers: number
    students: number
  }
}) {
  const [state, action] = useActionState(submitPayment, initial)
  const defaultPlan = plans.some((p) => p.code === currentPlan) ? currentPlan : (plans[0]?.code ?? '')
  const [planCode, setPlanCode] = useState(defaultPlan)
  const [months, setMonths] = useState(1)
  const price = plans.find((p) => p.code === planCode)?.priceTiyin ?? 0
  const validMonths = Number.isInteger(months) && months >= 1 && months <= 24
  const discount = validMonths ? prepayDiscountPercent(months) : 0
  const amount = validMonths ? platformPaymentAmountTiyin(price, months) : 0
  const saving = validMonths ? price * months - amount : 0
  const target = plans.find((p) => p.code === planCode)
  // Подсказка зеркалом plan_switch_days (0096); срок считает база при подтверждении.
  const switching = !current.isTrial && planCode !== currentPlan && (current.daysLeft ?? 0) > 0
  const switchDays = switching ? planSwitchDays(current.daysLeft ?? 0, current.priceTiyin, price) : 0
  const overTeachers = target && target.teachers >= 0 && current.teachers > target.teachers
  const overStudents = target && target.students >= 0 && current.students > target.students

  return (
    <form action={action} className="space-y-3">
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="space-y-1 text-sm">
          <span className="font-medium">{t('plan', 'planField')}</span>
          <select
            name="plan"
            value={planCode}
            onChange={(event) => setPlanCode(event.target.value)}
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
            value={Number.isNaN(months) ? '' : months}
            onChange={(event) => setMonths(event.target.valueAsNumber)}
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

      {validMonths && price > 0 ? (
        <p className="text-sm">
          {t('plan', 'amountToPay')} <span className="font-semibold tabular-nums">{formatSom(amount)}</span>
          {discount > 0 ? (
            <span className="text-muted-foreground">
              {' '}
              {t('plan', 'discountNote', { percent: discount, saving: formatSom(saving) })}
            </span>
          ) : null}
        </p>
      ) : null}
      <p className="text-xs text-muted-foreground">{t('plan', 'amountHint')}</p>
      {switching && target ? (
        <p className="text-sm">
          Оставшиеся {current.daysLeft} дн. тарифа {current.name} пересчитаются в {switchDays} дн. тарифа {target.name}.
          Новый срок — {switchDays} дн. + {validMonths ? months : '…'} мес. с момента подтверждения оплаты.
        </p>
      ) : null}
      {overTeachers || overStudents ? (
        <p className="rounded-md border border-amber-300 bg-amber-50 p-2 text-sm text-amber-900 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-200">
          В тарифе {target?.name} меньше места:
          {overTeachers ? ` специалистов ${current.teachers}, а в тарифе ${target?.teachers}` : ''}
          {overTeachers && overStudents ? ';' : ''}
          {overStudents ? ` учеников ${current.students}, а в тарифе ${target?.students}` : ''}. Работающие останутся, но
          добавить новых нельзя, пока не освободите место в архиве.
        </p>
      ) : null}

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
      <PendingSubmit size="sm" variant="outline">
        {t('plan', 'withdraw')}
      </PendingSubmit>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}
