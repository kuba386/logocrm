'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { FormError, FormNotice } from '@/components/ui/alert'
import { formatInTimeZone } from '@/lib/timezone'
import {
  loadMonthlyReport,
  sendMonthlyReport,
  type ClinicalState,
  type MonthlyReport,
} from './clinical-actions'

export type MonthOption = { value: string; label: string }

const initial: ClinicalState = { message: '' }

function ReportBody({ report }: { report: MonthlyReport }) {
  return (
    <div className="space-y-3 text-sm">
      <div className="flex flex-wrap gap-4">
        <div>
          <p className="text-xs text-muted-foreground">Занятий</p>
          <p className="text-lg font-semibold">{report.lessons_total}</p>
        </div>
        <div>
          <p className="text-xs text-muted-foreground">Пропусков</p>
          <p className="text-lg font-semibold">{report.absences}</p>
        </div>
      </div>

      {report.goals.length > 0 ? (
        <div>
          <p className="font-medium">Цели</p>
          <ul className="mt-1 space-y-0.5">
            {report.goals.map((g, i) => (
              <li key={i}>
                {g.title}
                {g.stage ? <span className="text-muted-foreground"> · {g.stage}</span> : null}
                {' — '}
                {g.from ?? '—'}→{g.to ?? '—'}
                <span className="text-muted-foreground"> ({g.points} оц.)</span>
              </li>
            ))}
          </ul>
        </div>
      ) : (
        <p className="text-muted-foreground">Оценок по целям за месяц нет.</p>
      )}

      {report.notes.length > 0 ? (
        <details>
          <summary className="cursor-pointer font-medium">Резюме занятий ({report.notes.length})</summary>
          <ul className="mt-1 space-y-2">
            {report.notes.map((n, i) => (
              <li key={i}>
                <span className="text-muted-foreground">{n.date}</span> — {n.summary}
              </li>
            ))}
          </ul>
        </details>
      ) : null}

      {report.attendance.length > 0 ? (
        <details>
          <summary className="cursor-pointer font-medium">Посещения ({report.attendance.length})</summary>
          <ul className="mt-1 space-y-0.5 text-muted-foreground">
            {report.attendance.map((a, i) => (
              <li key={i}>
                {a.date} — {a.status}
              </li>
            ))}
          </ul>
        </details>
      ) : null}
    </div>
  )
}

export function MonthlyReportPanel({
  studentId,
  months,
  initialMonth,
  initialReport,
  canSend,
  canResend,
  timeZone,
}: {
  studentId: string
  months: MonthOption[]
  initialMonth: string
  initialReport: MonthlyReport | null
  canSend: boolean
  canResend: boolean
  timeZone: string
}) {
  const router = useRouter()
  const [month, setMonth] = useState(initialMonth)
  const [report, setReport] = useState<MonthlyReport | null>(initialReport)
  const [comment, setComment] = useState('')
  const [confirmResend, setConfirmResend] = useState(false)
  const [pending, startTransition] = useTransition()
  const [result, setResult] = useState<ClinicalState>(initial)

  function changeMonth(value: string) {
    setMonth(value)
    setConfirmResend(false)
    setResult(initial)
    startTransition(async () => {
      const outcome = await loadMonthlyReport(studentId, value)
      if (outcome.report) setReport(outcome.report)
      else setResult({ message: outcome.message })
    })
  }

  const alreadySent = Boolean(report?.sent && report.sent.count > 0)

  function send() {
    startTransition(async () => {
      const outcome = await sendMonthlyReport(studentId, month, comment, alreadySent && confirmResend)
      setResult(outcome)
      if (outcome.notice) {
        setConfirmResend(false)
        const fresh = await loadMonthlyReport(studentId, month)
        if (fresh.report) setReport(fresh.report)
        router.refresh()
      }
    })
  }

  return (
    <div className="space-y-4">
      <div className="max-w-xs space-y-1">
        <Label htmlFor="reportMonth">Месяц</Label>
        <Select id="reportMonth" value={month} onChange={(e) => changeMonth(e.target.value)} disabled={pending}>
          {months.map((m) => (
            <option key={m.value} value={m.value}>
              {m.label}
            </option>
          ))}
        </Select>
      </div>

      {report ? (
        report.is_empty ? (
          <p className="text-sm text-muted-foreground">За этот месяц занятий не было — отправлять нечего.</p>
        ) : (
          <ReportBody report={report} />
        )
      ) : (
        <p className="text-sm text-muted-foreground">Отчёт не загружен.</p>
      )}

      {report?.sent ? (
        <div className="rounded-md border border-border p-3 text-sm">
          <p>
            Отправлен родителю{' '}
            {formatInTimeZone(report.sent.last_at, timeZone, {
              day: '2-digit',
              month: '2-digit',
              year: 'numeric',
              hour: '2-digit',
              minute: '2-digit',
            })}
            {report.sent.count > 1 ? ` (раз: ${report.sent.count})` : ''}
          </p>
          <p className="mt-1 whitespace-pre-line text-muted-foreground">{report.sent.summary}</p>
          {/* 0043 Р4: родитель получил снимок, числа выше пересчитаны живьём —
              расхождение показывается, а не прячется. */}
          {report.sent.is_stale ? (
            <p className="mt-1 text-warning">
              С момента отправки данные изменились — у родителя другие цифры.
            </p>
          ) : null}
        </div>
      ) : null}

      {canSend && report && !report.is_empty ? (
        <div className="space-y-3 border-t border-border pt-4">
          <div className="space-y-1">
            <Label htmlFor="reportComment">Строка от специалиста (необязательно)</Label>
            <Textarea
              id="reportComment"
              value={comment}
              onChange={(e) => setComment(e.target.value)}
              placeholder="Например: дома повторяйте слоги со звуком «р» по 5 минут."
              rows={2}
            />
          </div>

          {alreadySent ? (
            canResend ? (
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={confirmResend}
                  onChange={(e) => setConfirmResend(e.target.checked)}
                />
                Отправить повторно — родитель получит отчёт ещё раз
              </label>
            ) : (
              <p className="text-sm text-muted-foreground">
                Отчёт уже отправлен. Повторную отправку делает администрация.
              </p>
            )
          ) : null}

          <Button
            type="button"
            disabled={pending || (alreadySent && (!canResend || !confirmResend))}
            onClick={send}
          >
            {pending ? 'Отправляю…' : alreadySent ? 'Отправить повторно' : 'Отправить родителю'}
          </Button>
        </div>
      ) : null}

      <FormNotice message={result.notice} />
      <FormError message={result.message} />
    </div>
  )
}
