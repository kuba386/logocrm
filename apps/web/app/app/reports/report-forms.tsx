'use client'

import { useActionState, useEffect, useRef } from 'react'
import { useFormStatus } from 'react-dom'
import type { ExportReport } from '@logocrm/contracts'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { exportReport, type ExportState } from './actions'

const initial: ExportState = {}

function SubmitButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" disabled={pending}>
      {pending ? 'Секунду…' : children}
    </Button>
  )
}

/** Скачивает CSV, отданный сервером в state.csv, как только он появится (0056 — тот же приём). */
function downloadCsv(csv: string, filename: string) {
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}

/**
 * Скачивание — по смене nonce, не содержимого: повторная выгрузка того же
 * периода даёт байт в байт тот же CSV, а файл пользователю нужен снова.
 */
function useDownload(state: ExportState) {
  const downloaded = useRef<string | undefined>(undefined)
  useEffect(() => {
    if (state.csv && state.nonce && state.nonce !== downloaded.current) {
      downloaded.current = state.nonce
      downloadCsv(state.csv, state.filename ?? 'logocrm-report.csv')
    }
  }, [state.csv, state.filename, state.nonce])
}

/** Платежи и посещаемость — период «с … по». */
export function PeriodReportForm({ report, from, to }: { report: Extract<ExportReport, 'payments' | 'attendance'>; from: string; to: string }) {
  const [state, action] = useActionState(exportReport, initial)
  useDownload(state)
  return (
    <form action={action} className="flex flex-wrap items-end gap-3">
      <input type="hidden" name="report" value={report} />
      <div className="space-y-1">
        <Label htmlFor={`${report}-from`} className="text-xs">{t('reports', 'from')}</Label>
        <Input id={`${report}-from`} name="from" type="date" defaultValue={from} required className="h-9 w-40" />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`${report}-to`} className="text-xs">{t('reports', 'to')}</Label>
        <Input id={`${report}-to`} name="to" type="date" defaultValue={to} required className="h-9 w-40" />
      </div>
      <SubmitButton>{t('reports', 'download')}</SubmitButton>
      {state.message ? <FormError message={state.message} /> : null}
    </form>
  )
}

/**
 * Зарплата — один месяц, две кнопки одной формы: какой отчёт собирать,
 * говорит name/value нажатой кнопки (попадает в FormData), поле месяца —
 * общее.
 */
export function SalaryReportForm({ month }: { month: string }) {
  const [state, action] = useActionState(exportReport, initial)
  const { pending } = useFormStatus()
  useDownload(state)
  return (
    <form action={action} className="flex flex-wrap items-end gap-3">
      <div className="space-y-1">
        <Label htmlFor="salary-month" className="text-xs">{t('reports', 'month')}</Label>
        <Input id="salary-month" name="month" type="month" defaultValue={month} required className="h-9 w-40" />
      </div>
      <Button type="submit" size="sm" name="report" value="salary_summary" disabled={pending}>
        {t('reports', 'salarySummary')}
      </Button>
      <Button type="submit" size="sm" variant="outline" name="report" value="salary_details" disabled={pending}>
        {t('reports', 'salaryDetails')}
      </Button>
      {state.message ? <FormError message={state.message} /> : null}
    </form>
  )
}

/** Долги — без параметров, срез на сегодня по центру. */
export function DebtsReportForm() {
  const [state, action] = useActionState(exportReport, initial)
  useDownload(state)
  return (
    <form action={action} className="flex flex-wrap items-end gap-3">
      <input type="hidden" name="report" value="debts" />
      <SubmitButton>{t('reports', 'download')}</SubmitButton>
      {state.message ? <FormError message={state.message} /> : null}
    </form>
  )
}
