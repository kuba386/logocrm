'use client'

import { startTransition, useActionState, useEffect, useRef, useState, type FormEvent } from 'react'
import { useRouter } from 'next/navigation'
import { formatSom } from '@logocrm/core'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { FormError } from '@/components/ui/alert'
import { NoticeLine, usePageNotice, type Notice } from '@/components/ui/page-notice'
import { useLastSource } from '@/lib/use-last-source'
import { receiptHref } from '@/lib/receipt'
import { acceptDebtPayment, acceptLessonAdvance, refundLessonCredit, writeOffDebt, type DebtActionState } from './debt-actions'

const initial: DebtActionState = { message: '' }

type DebtAction = (prev: DebtActionState, formData: FormData) => Promise<DebtActionState>

/**
 * Действие диалога долга. Отправка — onSubmit без автосброса формы React 19
 * (при отказе введённое остаётся). Успех сообщается из обёртки действия, до
 * коммита ответа: строка должника после полной оплаты исчезает вместе с этим
 * компонентом, и эффект «после коммита» уже не выполнился бы. Отказ (долг
 * изменился — 23514) — перечитать страницу: скрытые expected станут свежими,
 * иначе повторная отправка снова ушла бы с устаревшей суммой.
 */
function useDebtAction(action: DebtAction, onDone: (state: DebtActionState) => void) {
  const router = useRouter()
  const onDoneRef = useRef(onDone)
  onDoneRef.current = onDone
  const [state, formAction, pending] = useActionState(async (prev: DebtActionState, formData: FormData) => {
    const next = await action(prev, formData)
    if (next.done) onDoneRef.current(next)
    return next
  }, initial)

  useEffect(() => {
    if (state.message) router.refresh()
  }, [state, router])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const formData = new FormData(event.currentTarget)
    startTransition(() => formAction(formData))
  }

  return { state, submit, pending }
}

/**
 * Итог действия: в провайдер страницы, если он есть, иначе — рядом с
 * кнопками. С квитанцией, если проведён платёж.
 */
function useNotice(back: string) {
  const page = usePageNotice()
  const [local, setLocal] = useState<Notice>(null)
  function show(text: string | null, paymentId?: string) {
    const notice: Notice = text
      ? { text, href: paymentId ? receiptHref(paymentId, back) : undefined, linkLabel: 'Квитанция' }
      : null
    if (page) page(notice)
    else setLocal(notice)
  }
  return { show, local }
}

function SourceSelect({ id, sources }: { id: string; sources: { id: string; name: string }[] }) {
  const [value, remember] = useLastSource(sources)
  return (
    <Select id={id} name="sourceId" required value={value} onChange={(e) => remember(e.target.value)}>
      {sources.map((s) => (
        <option key={s.id} value={s.id}>
          {s.name}
        </option>
      ))}
    </Select>
  )
}

function somToTiyin(value: string): number {
  const som = Number(value.replace(',', '.').replace(/\s/g, ''))
  return Number.isFinite(som) ? Math.round(som * 100) : 0
}

function PayDebtForm({
  studentId,
  remainingTiyin,
  overdueTiyin,
  sources,
  today,
  onDone,
  onCancel,
}: {
  studentId: string
  remainingTiyin: number
  overdueTiyin: number
  sources: { id: string; name: string }[]
  today: string
  onDone: (state: DebtActionState) => void
  onCancel: () => void
}) {
  const { state, submit, pending } = useDebtAction(acceptDebtPayment, onDone)
  const [amountSom, setAmountSom] = useState(String(remainingTiyin / 100))
  // Подсказка о переплате — разница между введённым и долгом из базы; саму
  // переплату в аванс проводит accept_lesson_debt_payment.
  const extraTiyin = somToTiyin(amountSom) - remainingTiyin

  return (
    <form onSubmit={submit} className="space-y-4">
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
            value={amountSom}
            onChange={(e) => setAmountSom(e.target.value)}
            required
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor={`pay-source-${studentId}`}>Источник</Label>
          <SourceSelect id={`pay-source-${studentId}`} sources={sources} />
        </div>
        <div className="space-y-2">
          <Label htmlFor={`pay-date-${studentId}`}>Дата оплаты</Label>
          <Input id={`pay-date-${studentId}`} name="paidOn" type="date" max={today} defaultValue={today} required />
        </div>
      </div>
      {extraTiyin > 0 ? (
        <p className="rounded-md bg-info-bg px-3 py-2 text-sm text-info">
          Сверх долга {formatSom(extraTiyin)} запишется авансом — им оплатятся следующие занятия без абонемента.
        </p>
      ) : null}
      {overdueTiyin > 0 ? (
        <p className="rounded-md bg-warning-bg px-3 py-2 text-sm text-warning">
          Просрочка по абонементу {formatSom(overdueTiyin)} этой формой не гасится — её принимают на карточке ученика,
          кнопкой «Принять оплату» у абонемента.
        </p>
      ) : null}
      <div className="space-y-2">
        <Label htmlFor={`pay-comment-${studentId}`}>Комментарий (необязательно)</Label>
        <Input id={`pay-comment-${studentId}`} name="comment" placeholder="Оплата долга за занятия" />
      </div>
      <FormError message={state.message} />
      <div className="flex gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? 'Секунду…' : 'Принять оплату'}
        </Button>
        <Button type="button" variant="outline" onClick={onCancel}>
          Отмена
        </Button>
      </div>
    </form>
  )
}

function WriteOffDebtForm({
  studentId,
  remainingTiyin,
  onDone,
  onCancel,
}: {
  studentId: string
  remainingTiyin: number
  onDone: (state: DebtActionState) => void
  onCancel: () => void
}) {
  const { state, submit, pending } = useDebtAction(writeOffDebt, onDone)
  const remainingSom = String(remainingTiyin / 100)
  return (
    <form onSubmit={submit} className="space-y-4">
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
      <FormError message={state.message} />
      <div className="flex gap-2">
        <Button type="submit" variant="destructive" disabled={pending}>
          {pending ? 'Секунду…' : 'Списать'}
        </Button>
        <Button type="button" variant="outline" onClick={onCancel}>
          Отмена
        </Button>
      </div>
    </form>
  )
}

/**
 * «Принять оплату» и «Списать» долга за занятия (0087). Остаток долга —
 * из SQL (debt + overdrawn), уходит в RPC как expected: изменился — база
 * ответит свежей суммой, форма останется открытой.
 *
 * overdueTiyin — просрочка по абонементу: эта форма её не гасит (она про
 * долг за занятия), а «5 000 вместо 1 000» молча ушли бы в аванс. Поэтому
 * предупреждаем и ведём на карточку, где оплачивается абонемент.
 *
 * Формы пересоздаются при каждом открытии диалога (key): прошлый отказ не
 * всплывает при новом открытии.
 */
export function DebtActions({
  studentId,
  studentName,
  remainingTiyin,
  overdueTiyin = 0,
  sources,
  today,
  canWriteOff,
  back = '/app/debts',
  payLabel = 'Принять оплату',
}: {
  studentId: string
  studentName: string
  remainingTiyin: number
  overdueTiyin?: number
  sources: { id: string; name: string }[]
  today: string
  canWriteOff: boolean
  /** Куда вернуться из квитанции. */
  back?: string
  payLabel?: string
}) {
  const [payOpen, setPayOpen] = useState(false)
  const [writeOffOpen, setWriteOffOpen] = useState(false)
  const [round, setRound] = useState(0)
  const { show, local } = useNotice(back)

  return (
    <>
      <Button
        type="button"
        size="sm"
        variant="outline"
        onClick={() => {
          show(null)
          setRound((r) => r + 1)
          setPayOpen(true)
        }}
      >
        {payLabel}
      </Button>
      {canWriteOff ? (
        <Button
          type="button"
          size="sm"
          variant="ghost"
          onClick={() => {
            show(null)
            setRound((r) => r + 1)
            setWriteOffOpen(true)
          }}
        >
          Списать
        </Button>
      ) : null}
      {local ? (
        <div className="w-full">
          <NoticeLine notice={local} />
        </div>
      ) : null}

      <Dialog
        open={payOpen}
        onClose={() => setPayOpen(false)}
        title="Принять оплату долга"
        description={`${studentName}: долг за занятия ${formatSom(remainingTiyin)}.`}
      >
        {payOpen ? (
          <PayDebtForm
            key={round}
            studentId={studentId}
            remainingTiyin={remainingTiyin}
            overdueTiyin={overdueTiyin}
            sources={sources}
            today={today}
            onCancel={() => setPayOpen(false)}
            onDone={(state) => {
              setPayOpen(false)
              show(state.notice ?? 'Оплата принята', state.paymentId)
            }}
          />
        ) : null}
      </Dialog>

      {canWriteOff ? (
        <Dialog
          open={writeOffOpen}
          onClose={() => setWriteOffOpen(false)}
          title="Списать долг"
          description={`${studentName}: долг ${formatSom(remainingTiyin)}. Списание без денег — касса не меняется, причина остаётся в журнале.`}
        >
          {writeOffOpen ? (
            <WriteOffDebtForm
              key={round}
              studentId={studentId}
              remainingTiyin={remainingTiyin}
              onCancel={() => setWriteOffOpen(false)}
              onDone={(state) => {
                setWriteOffOpen(false)
                show(state.notice ?? 'Долг списан')
              }}
            />
          ) : null}
        </Dialog>
      ) : null}
    </>
  )
}

function AdvanceForm({
  studentId,
  creditTiyin,
  sources,
  today,
  onDone,
  onCancel,
}: {
  studentId: string
  creditTiyin: number
  sources: { id: string; name: string }[]
  today: string
  onDone: (state: DebtActionState) => void
  onCancel: () => void
}) {
  const { state, submit, pending } = useDebtAction(acceptLessonAdvance, onDone)
  return (
    <form onSubmit={submit} className="space-y-4">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="expectedCreditTiyin" value={creditTiyin} />
      <div className="grid gap-4 sm:grid-cols-3">
        <div className="space-y-2">
          <Label htmlFor={`advance-amount-${studentId}`}>Сумма, сом</Label>
          <Input id={`advance-amount-${studentId}`} name="amountSom" type="number" min="0.01" step="0.01" inputMode="decimal" required />
        </div>
        <div className="space-y-2">
          <Label htmlFor={`advance-source-${studentId}`}>Источник</Label>
          <SourceSelect id={`advance-source-${studentId}`} sources={sources} />
        </div>
        <div className="space-y-2">
          <Label htmlFor={`advance-date-${studentId}`}>Дата оплаты</Label>
          <Input id={`advance-date-${studentId}`} name="paidOn" type="date" max={today} defaultValue={today} required />
        </div>
      </div>
      <div className="space-y-2">
        <Label htmlFor={`advance-comment-${studentId}`}>Комментарий (необязательно)</Label>
        <Input id={`advance-comment-${studentId}`} name="comment" maxLength={500} placeholder="Аванс за занятия" />
      </div>
      <FormError message={state.message} />
      <div className="flex gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? 'Секунду…' : 'Принять аванс'}
        </Button>
        <Button type="button" variant="outline" onClick={onCancel}>
          Отмена
        </Button>
      </div>
    </form>
  )
}

/**
 * «Внести аванс» (0101): деньги вперёд за занятия без абонемента, когда долга
 * нет, — как пополнение баланса клиента в топовых CRM. Аванс лежит на счёте
 * ребёнка и списывается следующими занятиями; вернуть — «Вернуть аванс».
 * creditTiyin — текущий аванс из базы, уходит в RPC как expected.
 */
export function AdvanceAction({
  studentId,
  studentName,
  creditTiyin,
  sources,
  today,
  back,
}: {
  studentId: string
  studentName: string
  creditTiyin: number
  sources: { id: string; name: string }[]
  today: string
  back: string
}) {
  const [open, setOpen] = useState(false)
  const [round, setRound] = useState(0)
  const { show, local } = useNotice(back)

  return (
    <>
      <Button
        type="button"
        size="sm"
        variant="outline"
        onClick={() => {
          show(null)
          setRound((r) => r + 1)
          setOpen(true)
        }}
      >
        Внести аванс
      </Button>
      {local ? (
        <div className="w-full">
          <NoticeLine notice={local} />
        </div>
      ) : null}
      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title="Внести аванс"
        description={`${studentName}: деньги вперёд за занятия без абонемента — спишутся следующими занятиями.${creditTiyin > 0 ? ` Сейчас аванс ${formatSom(creditTiyin)}.` : ''}`}
      >
        {open ? (
          <AdvanceForm
            key={round}
            studentId={studentId}
            creditTiyin={creditTiyin}
            sources={sources}
            today={today}
            onCancel={() => setOpen(false)}
            onDone={(state) => {
              setOpen(false)
              show(state.notice ?? 'Аванс принят', state.paymentId)
            }}
          />
        ) : null}
      </Dialog>
    </>
  )
}

function CreditRefundForm({
  studentId,
  creditTiyin,
  sources,
  today,
  onDone,
  onCancel,
}: {
  studentId: string
  creditTiyin: number
  sources: { id: string; name: string }[]
  today: string
  onDone: (state: DebtActionState) => void
  onCancel: () => void
}) {
  const { state, submit, pending } = useDebtAction(refundLessonCredit, onDone)
  const creditSom = String(creditTiyin / 100)
  return (
    <form onSubmit={submit} className="space-y-4">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="expectedCreditTiyin" value={creditTiyin} />
      <div className="grid gap-4 sm:grid-cols-3">
        <div className="space-y-2">
          <Label htmlFor={`credit-amount-${studentId}`}>Сумма, сом</Label>
          <Input
            id={`credit-amount-${studentId}`}
            name="amountSom"
            type="number"
            min="0.01"
            step="0.01"
            max={creditSom}
            inputMode="decimal"
            defaultValue={creditSom}
            required
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor={`credit-source-${studentId}`}>Откуда выдаём</Label>
          <SourceSelect id={`credit-source-${studentId}`} sources={sources} />
        </div>
        <div className="space-y-2">
          <Label htmlFor={`credit-date-${studentId}`}>Дата</Label>
          <Input id={`credit-date-${studentId}`} name="paidOn" type="date" max={today} defaultValue={today} required />
        </div>
      </div>
      <FormError message={state.message} />
      <div className="flex gap-2">
        <Button type="submit" variant="destructive" disabled={pending}>
          {pending ? 'Секунду…' : 'Вернуть деньги'}
        </Button>
        <Button type="button" variant="outline" onClick={onCancel}>
          Отмена
        </Button>
      </div>
    </form>
  )
}

/**
 * «Вернуть аванс» (0087): переплата долга лежит авансом и ждёт будущих
 * занятий; если семья просит деньги назад — только этой кнопкой, иначе
 * аванс в счёте занятий останется и оплатит следующие занятия второй раз.
 */
export function CreditRefundAction({
  studentId,
  studentName,
  creditTiyin,
  sources,
  today,
  back,
}: {
  studentId: string
  studentName: string
  creditTiyin: number
  sources: { id: string; name: string }[]
  today: string
  back: string
}) {
  const [open, setOpen] = useState(false)
  const [round, setRound] = useState(0)
  const { show, local } = useNotice(back)

  return (
    <>
      <Button
        type="button"
        size="sm"
        variant="ghost"
        onClick={() => {
          show(null)
          setRound((r) => r + 1)
          setOpen(true)
        }}
      >
        Вернуть аванс
      </Button>
      {local ? (
        <div className="w-full">
          <NoticeLine notice={local} />
        </div>
      ) : null}
      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title="Вернуть аванс"
        description={`${studentName}: аванс за занятия ${formatSom(creditTiyin)}. Деньги выдаются семье, аванс уменьшается на ту же сумму.`}
      >
        {open ? (
          <CreditRefundForm
            key={round}
            studentId={studentId}
            creditTiyin={creditTiyin}
            sources={sources}
            today={today}
            onCancel={() => setOpen(false)}
            onDone={(state) => {
              setOpen(false)
              show(state.notice ?? 'Аванс возвращён', state.paymentId)
            }}
          />
        ) : null}
      </Dialog>
    </>
  )
}
