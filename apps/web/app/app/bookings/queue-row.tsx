'use client'

import { useActionState, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { FormError } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { confirmBooking, declineBooking, payerMatch, type QueueState } from './actions'

const initialState: QueueState = {}

function SubmitButton({ children, variant }: { children: React.ReactNode; variant?: 'default' | 'outline' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {children}
    </Button>
  )
}

export function BookingQueueRow({ requestId }: { requestId: string }) {
  const [matchOpen, setMatchOpen] = useState(false)
  const [match, setMatch] = useState<{ id: string; name: string } | null | undefined>(undefined)
  const [payerChoice, setPayerChoice] = useState<'existing' | 'new'>('existing')
  const [declineOpen, setDeclineOpen] = useState(false)

  const [confirmState, confirmAction] = useActionState(
    confirmBooking.bind(null, requestId, match?.id && payerChoice === 'existing' ? match.id : null),
    initialState,
  )
  const [declineState, declineAction] = useActionState(declineBooking, initialState)

  async function openConfirm() {
    const found = await payerMatch(requestId)
    setMatch(found)
    setMatchOpen(true)
  }

  return (
    <>
      <div className="flex flex-wrap items-center gap-2">
        <Button type="button" size="sm" onClick={() => void openConfirm()}>
          {t('bookingQueue', 'confirmButton')}
        </Button>
        <Button type="button" size="sm" variant="outline" onClick={() => setDeclineOpen(true)}>
          {t('bookingQueue', 'declineButton')}
        </Button>
      </div>
      <FormError message={confirmState.message} />
      <FormError message={declineState.message} />

      <Dialog open={matchOpen} onClose={() => setMatchOpen(false)} title={t('bookingQueue', 'confirmButton')}>
        <form action={confirmAction} className="space-y-4">
          {match === undefined ? null : match ? (
            <div className="space-y-2 text-sm">
              <p>{t('bookingQueue', 'payerMatchFound', { name: match.name })}</p>
              <label className="flex items-center gap-2">
                <input
                  type="radio"
                  name="payerChoice"
                  checked={payerChoice === 'existing'}
                  onChange={() => setPayerChoice('existing')}
                />
                {t('bookingQueue', 'useExisting')}
              </label>
              <label className="flex items-center gap-2">
                <input
                  type="radio"
                  name="payerChoice"
                  checked={payerChoice === 'new'}
                  onChange={() => setPayerChoice('new')}
                />
                {t('bookingQueue', 'createNew')}
              </label>
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">{t('bookingQueue', 'payerMatchNone')}</p>
          )}
          <SubmitButton>{t('bookingQueue', 'confirmButton')}</SubmitButton>
        </form>
      </Dialog>

      <Dialog open={declineOpen} onClose={() => setDeclineOpen(false)} title={t('bookingQueue', 'declineButton')}>
        <form action={declineAction} className="space-y-4">
          <input type="hidden" name="requestId" value={requestId} />
          <div className="space-y-2">
            <Label htmlFor="reason">{t('bookingQueue', 'declineReasonLabel')}</Label>
            <Textarea id="reason" name="reason" rows={2} />
          </div>
          <SubmitButton variant="outline">{t('bookingQueue', 'declineButton')}</SubmitButton>
        </form>
      </Dialog>
    </>
  )
}
