'use client'

import { startTransition, useActionState, useEffect, useRef, useState, type FormEvent } from 'react'
import { useRouter } from 'next/navigation'
import { useFormStatus } from 'react-dom'
import { formatSom } from '@logocrm/core'
import { approveSalary, cancelSalaryRun, paySalary, recordSalaryAdjustment, type SalaryState } from './salary-actions'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'
import { usePageNotice } from '@/components/ui/page-notice'
import { useLastSource } from '@/lib/use-last-source'
import { t } from '@/lib/messages'
import { ConfirmSubmit } from '@/components/ui/confirm-submit'
import { useKeepValuesOnError } from '@/lib/use-keep-values'

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
  const keep = useKeepValuesOnError(state, Boolean(state.message))
  return (
    <form action={formAction} className="flex flex-wrap items-end gap-2" {...keep}>
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

/** Сводка для вопроса подтверждения: кто, за какой месяц, сколько. */
type RunSummary = { teacherId: string; month: string; monthLabel: string; teacherName: string; totalLabel: string }

export function ApproveForm({ teacherId, month, monthLabel, teacherName, totalLabel }: RunSummary) {
  const [state, formAction] = useActionState(approveSalary, initial)
  return (
    <form action={formAction} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="teacherId" value={teacherId} />
      <input type="hidden" name="month" value={month} />
      <ConfirmSubmit
        label={t('salary', 'approve', { month: monthLabel })}
        variant="default"
        confirmVariant="default"
        question={t('salary', 'approveConfirm', { name: teacherName, month: monthLabel, total: totalLabel })}
      />
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

export function CancelRunForm({ teacherId, month, monthLabel, teacherName, totalLabel }: RunSummary) {
  const [state, formAction] = useActionState(cancelSalaryRun, initial)
  return (
    <form action={formAction} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="teacherId" value={teacherId} />
      <input type="hidden" name="month" value={month} />
      <ConfirmSubmit
        label={t('salary', 'cancelRun')}
        variant="destructive"
        question={t('salary', 'cancelRunConfirm', { name: teacherName, month: monthLabel, total: totalLabel })}
      />
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}

type PayoutProps = {
  teacherId: string
  teacherName: string
  month: string
  monthLabel: string
  /** «К выплате» из salary_summary.due_tiyin — уходит в RPC как expected. */
  dueTiyin: number
  sources: { id: string; name: string }[]
  today: string
}

function PayoutForm({ teacherId, month, dueTiyin, sources, today, onDone, onCancel }: PayoutProps & { onDone: (state: SalaryState) => void; onCancel: () => void }) {
  const router = useRouter()
  const onDoneRef = useRef(onDone)
  onDoneRef.current = onDone
  // Успех — из обёртки до коммита: строка специалиста перерисуется с новой суммой.
  const [state, formAction, pending] = useActionState(async (prev: SalaryState, formData: FormData) => {
    const next = await paySalary(prev, formData)
    if (next.done) onDoneRef.current(next)
    return next
  }, initial)
  const [source, setSource] = useLastSource(sources)

  // «К выплате» изменилось (23514) — перечитать страницу: expected станет свежим.
  useEffect(() => {
    if (state.message) router.refresh()
  }, [state, router])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const formData = new FormData(event.currentTarget)
    startTransition(() => formAction(formData))
  }

  const dueSom = String(dueTiyin / 100)
  return (
    <form onSubmit={submit} className="space-y-4">
      <input type="hidden" name="teacherId" value={teacherId} />
      <input type="hidden" name="month" value={month} />
      <input type="hidden" name="expectedDueTiyin" value={dueTiyin} />
      <div className="grid gap-4 sm:grid-cols-3">
        <div className="space-y-2">
          <Label htmlFor={`payout-amount-${teacherId}`}>{t('salary', 'payAmount')}</Label>
          <Input
            id={`payout-amount-${teacherId}`}
            name="amountSom"
            type="number"
            min="0.01"
            step="0.01"
            max={dueSom}
            inputMode="decimal"
            defaultValue={dueSom}
            required
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor={`payout-source-${teacherId}`}>{t('salary', 'paySource')}</Label>
          <Select id={`payout-source-${teacherId}`} name="sourceId" required value={source} onChange={(e) => setSource(e.target.value)}>
            {sources.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-2">
          <Label htmlFor={`payout-date-${teacherId}`}>{t('salary', 'payDate')}</Label>
          <Input id={`payout-date-${teacherId}`} name="paidOn" type="date" min={month} max={today} defaultValue={today} required />
        </div>
      </div>
      <div className="space-y-2">
        <Label htmlFor={`payout-comment-${teacherId}`}>{t('salary', 'payComment')}</Label>
        <Input id={`payout-comment-${teacherId}`} name="comment" maxLength={500} placeholder={t('salary', 'payCommentPlaceholder')} />
      </div>
      <FormError message={state.message} />
      <div className="flex gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? 'Секунду…' : t('salary', 'paySubmit')}
        </Button>
        <Button type="button" variant="outline" onClick={onCancel}>
          Отмена
        </Button>
      </div>
    </form>
  )
}

/**
 * «Выплатить» (0101): выплата из кассы — расход по статье «Зарплата» со
 * специалистом и месяцем. Сумма по умолчанию — всё «к выплате»; больше
 * начисленного база не проведёт. Форма пересоздаётся при каждом открытии.
 */
export function PayoutAction(props: PayoutProps) {
  const [open, setOpen] = useState(false)
  const [round, setRound] = useState(0)
  const notice = usePageNotice()
  const [local, setLocal] = useState('')
  return (
    <>
      <Button
        type="button"
        size="sm"
        onClick={() => {
          notice?.(null)
          setLocal('')
          setRound((r) => r + 1)
          setOpen(true)
        }}
      >
        {t('salary', 'pay', { sum: formatSom(props.dueTiyin) })}
      </Button>
      {local ? <FormNotice message={local} /> : null}
      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title={t('salary', 'payTitle')}
        description={t('salary', 'payDescription', { name: props.teacherName, month: props.monthLabel, sum: formatSom(props.dueTiyin) })}
      >
        {open ? (
          <PayoutForm
            key={round}
            {...props}
            onCancel={() => setOpen(false)}
            onDone={(state) => {
              setOpen(false)
              const text = state.notice ?? t('salary', 'paid')
              if (notice) notice({ text })
              else setLocal(text)
            }}
          />
        ) : null}
      </Dialog>
    </>
  )
}
