'use client'

import { useActionState, useEffect, useRef } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import {
  cancelDeletion,
  exportCenterAudit,
  exportCenterData,
  requestDeletion,
  type ExportState,
  type PlanState,
} from './actions'

const initialExport: ExportState = {}
const initialPlan: PlanState = {}

function SubmitButton({ children, variant }: { children: React.ReactNode; variant?: 'destructive' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant={variant} disabled={pending}>
      {children}
    </Button>
  )
}

/** Скачивает JSON, отдаваемый сервером в state.json, как только он появится. */
function downloadJson(json: string, filename: string) {
  const blob = new Blob([json], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}

/** Экспорт всех данных центра одним файлом (0056 Р1/Р4/Р11). */
export function ExportDataForm() {
  const [state, action] = useActionState(exportCenterData, initialExport)
  const downloaded = useRef<string | undefined>(undefined)

  useEffect(() => {
    if (state.json && state.json !== downloaded.current) {
      downloaded.current = state.json
      downloadJson(state.json, state.filename ?? 'logocrm-export.json')
    }
  }, [state.json, state.filename])

  return (
    <form action={action} className="space-y-2">
      {state.message ? <FormError message={state.message} /> : null}
      <SubmitButton>{t('plan', 'exportButton')}</SubmitButton>
    </form>
  )
}

/**
 * Журнал изменений (audit_log) за период — отдельным файлом (0056 Р4).
 * Даты по умолчанию приходят пропсами из пояса центра (center_today()
 * на сервере), не из UTC браузера — иначе вечером в Бишкеке «сегодня»
 * в форме означало бы вчера и часть журнала выпадала бы из выборки
 * молча (ревью написанного SQL, находка 8).
 */
export function ExportAuditForm({ today, monthAgo }: { today: string; monthAgo: string }) {
  const [state, action] = useActionState(exportCenterAudit, initialExport)
  const downloaded = useRef<string | undefined>(undefined)

  useEffect(() => {
    if (state.json && state.json !== downloaded.current) {
      downloaded.current = state.json
      downloadJson(state.json, state.filename ?? 'logocrm-audit.json')
    }
  }, [state.json, state.filename])

  return (
    <form action={action} className="flex flex-wrap items-end gap-3">
      <div className="space-y-1">
        <Label htmlFor="audit-from" className="text-xs">
          {t('plan', 'exportAuditFrom')}
        </Label>
        <Input id="audit-from" name="from" type="date" defaultValue={monthAgo} className="h-9 w-40" />
      </div>
      <div className="space-y-1">
        <Label htmlFor="audit-to" className="text-xs">
          {t('plan', 'exportAuditTo')}
        </Label>
        <Input id="audit-to" name="to" type="date" defaultValue={today} className="h-9 w-40" />
      </div>
      <SubmitButton>{t('plan', 'exportAuditButton')}</SubmitButton>
      {state.message ? <FormError message={state.message} /> : null}
    </form>
  )
}

/** Заявка на удаление (0056 Р8) — имя центра как подтверждение. */
export function DeleteCenterForm({ centerName }: { centerName: string }) {
  const [state, action] = useActionState(requestDeletion, initialPlan)

  return (
    <form action={action} className="space-y-3">
      <div className="space-y-1">
        <Label htmlFor="confirm-name" className="text-xs">
          {t('plan', 'deleteConfirmLabel')} — «{centerName}»
        </Label>
        <Input id="confirm-name" name="confirmName" placeholder={centerName} className="h-9 max-w-sm" />
      </div>
      {state.message ? <FormError message={state.message} /> : null}
      {state.notice ? <FormNotice message={state.notice} /> : null}
      <SubmitButton variant="destructive">{t('plan', 'deleteButton')}</SubmitButton>
    </form>
  )
}

/** Отмена заявки на удаление (0056 Р9). */
export function CancelDeletionForm() {
  const [state, action] = useActionState(cancelDeletion, initialPlan)

  return (
    <form action={action} className="space-y-2">
      {state.message ? <FormError message={state.message} /> : null}
      {state.notice ? <FormNotice message={state.notice} /> : null}
      <SubmitButton>{t('plan', 'cancelDeleteButton')}</SubmitButton>
    </form>
  )
}
