'use client'

import { startTransition, useActionState, useEffect, useState, type FormEvent } from 'react'
import { formatSom } from '@logocrm/core'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { FormError } from '@/components/ui/alert'
import { acceptDebtPayment, writeOffDebt, type DebtActionState } from './debt-actions'

const initial: DebtActionState = { message: '' }

/** Отправка без автосброса формы React 19 (см. invite-dialog, #198): при отказе введённое остаётся. */
function useSubmit(action: (formData: FormData) => void) {
  return (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const formData = new FormData(event.currentTarget)
    startTransition(() => action(formData))
  }
}

/**
 * «Принять оплату» и «Списать» на карточке долга (0087). Остаток долга —
 * из SQL (debt + overdrawn строки страницы), уходит в RPC как expected:
 * изменился — база ответит свежей суммой, форма останется открытой.
 */
export function DebtActions({
  studentId,
  studentName,
  remainingTiyin,
  sources,
  today,
  canWriteOff,
}: {
  studentId: string
  studentName: string
  remainingTiyin: number
  sources: { id: string; name: string }[]
  today: string
  canWriteOff: boolean
}) {
  const [payOpen, setPayOpen] = useState(false)
  const [writeOffOpen, setWriteOffOpen] = useState(false)
  const [payState, payAction, payPending] = useActionState(acceptDebtPayment, initial)
  const [writeOffState, writeOffAction, writeOffPending] = useActionState(writeOffDebt, initial)
  const onPay = useSubmit(payAction)
  const onWriteOff = useSubmit(writeOffAction)

  useEffect(() => {
    if (payState.done) setPayOpen(false)
  }, [payState.done])
  useEffect(() => {
    if (writeOffState.done) setWriteOffOpen(false)
  }, [writeOffState.done])

  const remainingSom = String(remainingTiyin / 100)

  return (
    <>
      <Button type="button" size="sm" variant="outline" onClick={() => setPayOpen(true)}>
        Принять оплату
      </Button>
      {canWriteOff ? (
        <Button type="button" size="sm" variant="ghost" onClick={() => setWriteOffOpen(true)}>
          Списать
        </Button>
      ) : null}

      <Dialog
        open={payOpen}
        onClose={() => setPayOpen(false)}
        title="Принять оплату долга"
        description={`${studentName}: долг ${formatSom(remainingTiyin)}. Больше долга — остаток запишется авансом на будущие занятия.`}
      >
        <form onSubmit={onPay} className="space-y-4">
          <input type="hidden" name="studentId" value={studentId} />
          <input type="hidden" name="expectedTiyin" value={remainingTiyin} />
          <div className="grid gap-4 sm:grid-cols-3">
            <div className="space-y-2">
              <Label htmlFor={`pay-amount-${studentId}`}>Сумма, сом</Label>
              <Input
                id={`pay-amount-${studentId}`}
                name="amountSom"
                type="number"
                min="0.01"
                step="0.01"
                inputMode="decimal"
                defaultValue={remainingSom}
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor={`pay-source-${studentId}`}>Источник</Label>
              <Select id={`pay-source-${studentId}`} name="sourceId" required defaultValue={sources[0]?.id}>
                {sources.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </Select>
            </div>
            <div className="space-y-2">
              <Label htmlFor={`pay-date-${studentId}`}>Дата оплаты</Label>
              <Input id={`pay-date-${studentId}`} name="paidOn" type="date" max={today} defaultValue={today} required />
            </div>
          </div>
          <div className="space-y-2">
            <Label htmlFor={`pay-comment-${studentId}`}>Комментарий (необязательно)</Label>
            <Input id={`pay-comment-${studentId}`} name="comment" placeholder="Оплата долга за занятия" />
          </div>
          <FormError message={payState.message} />
          <div className="flex gap-2">
            <Button type="submit" disabled={payPending}>
              {payPending ? 'Секунду…' : 'Принять оплату'}
            </Button>
            <Button type="button" variant="outline" onClick={() => setPayOpen(false)}>
              Отмена
            </Button>
          </div>
        </form>
      </Dialog>

      {canWriteOff ? (
        <Dialog
          open={writeOffOpen}
          onClose={() => setWriteOffOpen(false)}
          title="Списать долг"
          description={`${studentName}: долг ${formatSom(remainingTiyin)}. Списание без денег — касса не меняется, причина остаётся в журнале.`}
        >
          <form onSubmit={onWriteOff} className="space-y-4">
            <input type="hidden" name="studentId" value={studentId} />
            <input type="hidden" name="expectedTiyin" value={remainingTiyin} />
            <div className="space-y-2">
              <Label htmlFor={`wo-amount-${studentId}`}>Сумма, сом</Label>
              <Input
                id={`wo-amount-${studentId}`}
                name="amountSom"
                type="number"
                min="0.01"
                step="0.01"
                max={remainingSom}
                inputMode="decimal"
                defaultValue={remainingSom}
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor={`wo-reason-${studentId}`}>Причина</Label>
              <Textarea id={`wo-reason-${studentId}`} name="reason" required maxLength={500} placeholder="Например: семья в трудной ситуации" />
            </div>
            <FormError message={writeOffState.message} />
            <div className="flex gap-2">
              <Button type="submit" variant="destructive" disabled={writeOffPending}>
                {writeOffPending ? 'Секунду…' : 'Списать'}
              </Button>
              <Button type="button" variant="outline" onClick={() => setWriteOffOpen(false)}>
                Отмена
              </Button>
            </div>
          </form>
        </Dialog>
      ) : null}
    </>
  )
}
