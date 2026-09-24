'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { setBookingEnabled, type PlanState } from './actions'

const initialState: PlanState = {}

function ToggleButton({ enabled }: { enabled: boolean }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" variant={enabled ? 'outline' : 'default'} disabled={pending}>
      {enabled ? t('bookingQueue', 'publishOff') : t('bookingQueue', 'publishOn')}
    </Button>
  )
}

export function BookingToggleForm({ enabled }: { enabled: boolean }) {
  const [state, action] = useActionState(setBookingEnabled.bind(null, !enabled), initialState)

  return (
    <form action={action} className="flex items-center gap-4">
      <p className="text-sm font-medium">{enabled ? t('bookingQueue', 'publishOn') : t('bookingQueue', 'publishOff')}</p>
      <ToggleButton enabled={enabled} />
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}
