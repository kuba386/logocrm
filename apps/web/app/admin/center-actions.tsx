'use client'

import { useActionState } from 'react'
import { FormError, FormNotice } from '@/components/ui/alert'
import { ConfirmSubmit } from '@/components/ui/confirm-submit'
import { DialogButton } from '@/components/ui/dialog-button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { SubmitButton } from '@/components/ui/submit-button'
import { Textarea } from '@/components/ui/textarea'
import { useKeepValuesOnError } from '@/lib/use-keep-values'
import { t } from '@/lib/messages'
import { deleteCenter, extendTrial, grantSubscription, restoreCenter, type AdminState } from './actions'

const initial: AdminState = {}

export type ActionCenter = {
  id: string
  name: string
  plan: string
  isTrial: boolean
  /** Срок, который видит форма, — уходит в RPC для сверки (0099 Р5). */
  until: string | null
  /** «ГГГГ-ММ-ДД» в поясе центра — значение по умолчанию для даты. */
  untilDay: string | null
  hasOpenClaim: boolean
}

function Reason({ id }: { id: string }) {
  return (
    <div className="space-y-1">
      <Label htmlFor={id}>{t('admin', 'reason')}</Label>
      <Textarea id={id} name="reason" required minLength={3} maxLength={500} rows={2} placeholder={t('admin', 'actionReasonPlaceholder')} />
    </div>
  )
}

/**
 * «Действия» в строке центра на пульте (0099): продлить или сменить тариф
 * вручную, продлить пробный, удалить. Права, даты, сверку срока и причину
 * проверяет база; ответ — только с сервера.
 */
export function CenterActions({ center, plans }: { center: ActionCenter; plans: { code: string; name: string }[] }) {
  return (
    <DialogButton
      label={t('admin', 'actions')}
      title={t('admin', 'actionsTitle', { name: center.name })}
      description={t('admin', 'actionsSubtitle')}
      variant="outline"
      size="sm"
    >
      <div className="space-y-6">
        <GrantForm center={center} plans={plans} />
        {center.isTrial ? <TrialForm center={center} /> : null}
        <DeleteForm center={center} />
      </div>
    </DialogButton>
  )
}

function GrantForm({ center, plans }: { center: ActionCenter; plans: { code: string; name: string }[] }) {
  const [state, action] = useActionState(grantSubscription, initial)
  const keep = useKeepValuesOnError(state, Boolean(state.message))
  const id = `grant-${center.id}`
  return (
    <form action={action} className="space-y-3 border-b border-border pb-6" {...keep}>
      <h3 className="font-medium">{t('admin', 'grantTitle')}</h3>
      <p className="text-xs text-muted-foreground">{t('admin', 'grantHint')}</p>
      <input type="hidden" name="centerId" value={center.id} />
      <input type="hidden" name="expectedUntil" value={center.until ?? ''} />
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor={`${id}-plan`}>{t('admin', 'grantPlan')}</Label>
          <Select id={`${id}-plan`} name="plan" defaultValue={center.isTrial ? plans[0]?.code : center.plan}>
            {plans.map((p) => (
              <option key={p.code} value={p.code}>
                {p.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor={`${id}-until`}>{t('admin', 'grantUntil')}</Label>
          <Input id={`${id}-until`} name="until" type="date" required defaultValue={center.untilDay ?? ''} />
        </div>
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" name="shorten" className="size-4" />
        {t('admin', 'grantShorten')}
      </label>
      <Reason id={`${id}-reason`} />
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
      <SubmitButton size="sm" pendingLabel={t('common', 'pending')}>
        {t('admin', 'grantSubmit')}
      </SubmitButton>
    </form>
  )
}

function TrialForm({ center }: { center: ActionCenter }) {
  const [state, action] = useActionState(extendTrial, initial)
  const keep = useKeepValuesOnError(state, Boolean(state.message))
  const id = `trial-${center.id}`
  return (
    <form action={action} className="space-y-3 border-b border-border pb-6" {...keep}>
      <h3 className="font-medium">{t('admin', 'trialTitle')}</h3>
      <p className="text-xs text-muted-foreground">{t('admin', 'trialHint')}</p>
      <input type="hidden" name="centerId" value={center.id} />
      <input type="hidden" name="expectedUntil" value={center.until ?? ''} />
      <div className="space-y-1 sm:max-w-xs">
        <Label htmlFor={`${id}-until`}>{t('admin', 'grantUntil')}</Label>
        <Input id={`${id}-until`} name="until" type="date" required defaultValue={center.untilDay ?? ''} />
      </div>
      <Reason id={`${id}-reason`} />
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
      <SubmitButton size="sm" pendingLabel={t('common', 'pending')}>
        {t('admin', 'trialSubmit')}
      </SubmitButton>
    </form>
  )
}

function DeleteForm({ center }: { center: ActionCenter }) {
  const [state, action] = useActionState(deleteCenter, initial)
  const keep = useKeepValuesOnError(state, Boolean(state.message))
  const id = `delete-${center.id}`
  return (
    <form action={action} className="space-y-3" {...keep}>
      <h3 className="font-medium text-destructive">{t('admin', 'deleteTitle')}</h3>
      <p className="text-xs text-muted-foreground">{t('admin', 'deleteHint')}</p>
      {center.hasOpenClaim ? (
        <p role="note" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
          {t('admin', 'deleteOpenClaim')}
        </p>
      ) : null}
      <input type="hidden" name="centerId" value={center.id} />
      <div className="space-y-1">
        <Label htmlFor={`${id}-name`}>{t('admin', 'deleteConfirmName')}</Label>
        <Input id={`${id}-name`} name="confirmName" required autoComplete="off" placeholder={center.name} />
      </div>
      <Reason id={`${id}-reason`} />
      <FormError message={state.message} />
      <FormNotice message={state.notice} />
      <ConfirmSubmit label={t('admin', 'deleteSubmit')} question={t('admin', 'deleteQuestion', { name: center.name })} />
    </form>
  )
}

/** «Восстановить» в разделе удалённых центров — только для удалённых платформой. */
export function RestoreForm({ centerId }: { centerId: string }) {
  const [state, action] = useActionState(restoreCenter, initial)
  const keep = useKeepValuesOnError(state, Boolean(state.message))
  return (
    <form action={action} className="flex flex-wrap items-end gap-2" {...keep}>
      <input type="hidden" name="centerId" value={centerId} />
      <div className="min-w-[220px] flex-1 space-y-1">
        <Label htmlFor={`restore-${centerId}`} className="sr-only">
          {t('admin', 'reason')}
        </Label>
        <Input id={`restore-${centerId}`} name="reason" required minLength={3} maxLength={500} placeholder={t('admin', 'reason')} />
      </div>
      <SubmitButton size="sm" variant="outline" pendingLabel={t('common', 'pending')}>
        {t('admin', 'restoreSubmit')}
      </SubmitButton>
      <div className="w-full">
        <FormError message={state.message} />
        <FormNotice message={state.notice} />
      </div>
    </form>
  )
}
