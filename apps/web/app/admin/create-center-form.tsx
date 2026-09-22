'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { createCenterForOwner, type AdminState } from './actions'

const initial: AdminState = {}
const field = 'w-full rounded-md border border-input bg-background px-3 py-2 text-sm'

function SubmitButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" disabled={pending}>
      {children}
    </Button>
  )
}

/** Второй центр владельцу — platform_create_center (0052 Р9): trial-лимит из платформенной сессии не действует. */
export function CreateCenterForm() {
  const [state, action] = useActionState(createCenterForOwner, initial)
  return (
    <form action={action} className="space-y-2">
      <div className="grid gap-2 sm:grid-cols-3">
        <label className="space-y-1 text-xs">
          <span className="font-medium">{t('admin', 'centerName')}</span>
          <input type="text" name="name" required maxLength={120} className={field} />
        </label>
        <label className="space-y-1 text-xs">
          <span className="font-medium">{t('admin', 'ownerEmail')}</span>
          <input type="email" name="ownerEmail" required className={field} />
        </label>
        <label className="space-y-1 text-xs">
          <span className="font-medium">{t('admin', 'city')}</span>
          <input type="text" name="city" maxLength={80} className={field} />
        </label>
      </div>
      <SubmitButton>{t('admin', 'createCenter')}</SubmitButton>
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
    </form>
  )
}
