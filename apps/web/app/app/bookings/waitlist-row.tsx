'use client'

import Link from 'next/link'
import { useActionState, useId, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import {
  enrollWaitlist,
  offerWaitlist,
  waitlistPayerMatch,
  withdrawWaitlist,
  type QueueState,
  type WaitlistActionState,
} from './actions'

const initialState: QueueState = {}
const initialEnroll: WaitlistActionState = {}

function SubmitButton({ children, variant }: { children: React.ReactNode; variant?: 'default' | 'outline' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {children}
    </Button>
  )
}

/** Действия стойки над записью листа ожидания (0109): предложить, записать, закрыть. */
export function WaitlistRow({ entryId }: { entryId: string }) {
  const [enrollOpen, setEnrollOpen] = useState(false)
  const [withdrawOpen, setWithdrawOpen] = useState(false)
  const [match, setMatch] = useState<{ id: string; name: string } | null | undefined>(undefined)
  const [payerChoice, setPayerChoice] = useState<'existing' | 'new'>('existing')
  const [opening, setOpening] = useState(false)
  const reasonId = useId()

  const [offerState, offerAction] = useActionState(offerWaitlist.bind(null, entryId), initialState)
  const [withdrawState, withdrawAction] = useActionState(withdrawWaitlist.bind(null, entryId), initialState)
  const [enrollState, enrollAction] = useActionState(
    enrollWaitlist.bind(null, entryId, match?.id && payerChoice === 'existing' ? match.id : null),
    initialEnroll,
  )

  // Совпадение по телефону — до открытия диалога, как у подтверждения заявки.
  async function openEnroll() {
    setOpening(true)
    try {
      setMatch(await waitlistPayerMatch(entryId))
      setEnrollOpen(true)
    } finally {
      setOpening(false)
    }
  }

  if (enrollState.studentId) {
    return (
      <div className="space-y-1">
        <FormNotice message={enrollState.notice} />
        <Link href={`/app/students/${enrollState.studentId}`} className="text-sm text-primary underline-offset-4 hover:underline">
          {t('bookingQueue', 'openStudent')}
        </Link>
      </div>
    )
  }

  return (
    <>
      <div className="flex flex-wrap items-center gap-2">
        <form action={offerAction}>
          <SubmitButton variant="outline">{t('bookingQueue', 'offerButton')}</SubmitButton>
        </form>
        <Button type="button" size="sm" disabled={opening} onClick={() => void openEnroll()}>
          {opening ? t('bookingQueue', 'checkingPayer') : t('bookingQueue', 'enrollButton')}
        </Button>
        <Button type="button" size="sm" variant="outline" onClick={() => setWithdrawOpen(true)}>
          {t('bookingQueue', 'withdrawButton')}
        </Button>
      </div>
      <FormError message={offerState.message} />
      {enrollOpen ? null : <FormError message={enrollState.message} />}
      {withdrawOpen ? null : <FormError message={withdrawState.message} />}

      <Dialog open={enrollOpen} onClose={() => setEnrollOpen(false)} title={t('bookingQueue', 'enrollTitle')}>
        <form action={enrollAction} className="space-y-4">
          <p className="text-sm text-muted-foreground">{t('bookingQueue', 'enrollHint')}</p>
          {match === undefined ? null : match ? (
            <div className="space-y-2 text-sm">
              <p>{t('bookingQueue', 'payerMatchFound', { name: match.name })}</p>
              <label className="flex min-h-11 items-center gap-2">
                <input
                  type="radio"
                  name="payerChoice"
                  checked={payerChoice === 'existing'}
                  onChange={() => setPayerChoice('existing')}
                />
                {t('bookingQueue', 'useExisting')}
              </label>
              <label className="flex min-h-11 items-center gap-2">
                <input type="radio" name="payerChoice" checked={payerChoice === 'new'} onChange={() => setPayerChoice('new')} />
                {t('bookingQueue', 'createNew')}
              </label>
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">{t('bookingQueue', 'payerMatchNone')}</p>
          )}
          <FormError message={enrollState.message} />
          <SubmitButton>{t('bookingQueue', 'enrollButton')}</SubmitButton>
        </form>
      </Dialog>

      <Dialog open={withdrawOpen} onClose={() => setWithdrawOpen(false)} title={t('bookingQueue', 'withdrawButton')}>
        <form action={withdrawAction} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor={reasonId}>{t('bookingQueue', 'withdrawReasonLabel')}</Label>
            <Textarea id={reasonId} name="reason" rows={2} maxLength={500} />
          </div>
          <FormError message={withdrawState.message} />
          <SubmitButton variant="outline">{t('bookingQueue', 'withdrawButton')}</SubmitButton>
        </form>
      </Dialog>
    </>
  )
}
