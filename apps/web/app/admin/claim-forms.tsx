'use client'

import { useActionState, useEffect, useState } from 'react'
import { FormError, FormNotice } from '@/components/ui/alert'
import { formatSom, platformPaymentAmountTiyin } from '@logocrm/core'
import { label, t } from '@/lib/messages'
import { formatInTimeZone } from '@/lib/timezone'
import { ConfirmSubmit } from '@/components/ui/confirm-submit'
import { confirmPayment, previewConfirm, rejectPayment, type AdminState, type ConfirmPreview } from './actions'

const initial: AdminState = {}


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
  timeZone,
}: {
  paymentId: string
  plans: { code: string; name: string; priceTiyin: number }[]
  claimedPlan: string
  claimedMonths: number
  claimedAmountSom: number
  /** Пояс центра — даты срока в предпросмотре. */
  timeZone: string
}) {
  const [state, action] = useActionState(confirmPayment, initial)
  const [planCode, setPlanCode] = useState(claimedPlan)
  const [months, setMonths] = useState(claimedMonths)
  const [amountSom, setAmountSom] = useState(claimedAmountSom)
  // 0096 Р6: предпросмотр для значений формы; «Подтвердить» — только когда он
  // посчитан именно для них (иначе опечатка в сумме незаметно сдвинет срок).
  const valuesKey = `${planCode}|${months}|${amountSom}`
  const [preview, setPreview] = useState<{ key: string; data?: ConfirmPreview; message?: string } | null>(null)
  useEffect(() => {
    let alive = true
    const timer = setTimeout(() => {
      previewConfirm(paymentId, planCode, months, amountSom).then((r) => {
        if (alive) setPreview({ key: valuesKey, data: r.preview, message: r.message })
      })
    }, 300)
    return () => {
      alive = false
      clearTimeout(timer)
    }
  }, [paymentId, planCode, months, amountSom, valuesKey])
  const previewReady = preview?.key === valuesKey && Boolean(preview.data)
  const day = (iso: string | null | undefined) =>
    iso ? formatInTimeZone(iso, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' }) : '—'
  // Подсказка, не значение: сумму подтверждения решает платформа (0051), но
  // при смене месяцев легко забыть про скидку за предоплату (0084).
  const price = plans.find((p) => p.code === planCode)?.priceTiyin
  const priceHint =
    price !== undefined && Number.isInteger(months) && months >= 1 && months <= 24
      ? formatSom(platformPaymentAmountTiyin(price, months))
      : null
  return (
    <form action={action} className="space-y-2">
      <input type="hidden" name="paymentId" value={paymentId} />
      <div className="grid gap-2 sm:grid-cols-3">
        <label className="space-y-1 text-xs">
          <span className="font-medium">{t('admin', 'planField')}</span>
          <select name="plan" value={planCode} onChange={(event) => setPlanCode(event.target.value)} className={field}>
            {plans.map((p) => (
              <option key={p.code} value={p.code}>
                {p.name}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1 text-xs">
          <span className="font-medium">{t('admin', 'monthsField')}</span>
          <input
            type="number"
            name="months"
            min={1}
            max={24}
            value={Number.isNaN(months) ? '' : months}
            onChange={(event) => setMonths(event.target.valueAsNumber)}
            required
            className={field}
          />
        </label>
        <label className="space-y-1 text-xs">
          <span className="font-medium">{t('admin', 'amountField')}</span>
          <input
            type="number"
            name="amountSom"
            min={1}
            step="0.01"
            value={Number.isNaN(amountSom) ? '' : amountSom}
            onChange={(event) => setAmountSom(event.target.valueAsNumber)}
            required
            className={field}
          />
        </label>
      </div>
      {priceHint ? <p className="text-xs text-muted-foreground">{t('admin', 'priceHint', { amount: priceHint })}</p> : null}
      {price !== undefined && Number.isInteger(months) && months >= 1 && months <= 24 && amountSom > 0 &&
      Math.abs(Math.round(amountSom * 100) - platformPaymentAmountTiyin(price, months)) > platformPaymentAmountTiyin(price, months) / 100 ? (
        <p className="text-xs text-destructive">Сумма отличается от цены тарифа со скидкой — она станет ценой месяца для пересчёта. Проверьте.</p>
      ) : null}
      <div className="space-y-1 rounded-md border border-border bg-muted/40 p-2 text-sm" aria-live="polite">
        {!previewReady ? (
          <p className="text-muted-foreground">{preview?.key === valuesKey && preview.message ? preview.message : 'Считаем новый срок…'}</p>
        ) : preview?.data ? (
          <>
            <p>
              Сейчас: {label('plan_names', preview.data.currentPlan ?? '')} до {day(preview.data.currentUntil)}. После
              подтверждения — до <span className="font-medium">{day(preview.data.newUntil)}</span>.
            </p>
            {preview.data.switching ? (
              <p className="text-muted-foreground">
                Смена тарифа: остаток {preview.data.remainingDays} дн. пересчитан в {preview.data.convertedDays} дн. по
                уплаченной цене.
              </p>
            ) : null}
            {preview.data.currentUntil && preview.data.newUntil && preview.data.newUntil < preview.data.currentUntil ? (
              <p className="text-destructive">Новый срок раньше нынешнего.</p>
            ) : null}
            {preview.data.excessDays > 0 ? (
              <p className="text-destructive">
                Потолок 24 мес.: сверх — {preview.data.excessDays} дн., к возврату ≈ {formatSom(preview.data.excessTiyin)}.
              </p>
            ) : null}
          </>
        ) : null}
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" name="receiptReceived" defaultChecked className="h-4 w-4" />
        {t('admin', 'receiptReceived')}
      </label>
      <ConfirmSubmit
        variant="default"
        confirmVariant="default"
        disabled={!previewReady}
        label={t('admin', 'confirm')}
        question={t('admin', 'confirmQuestion', {
          plan: plans.find((p) => p.code === planCode)?.name ?? planCode,
          months: Number.isNaN(months) ? '?' : months,
        })}
      />
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
      <ConfirmSubmit label={t('admin', 'reject')} question={t('admin', 'rejectQuestion')} />
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}
