import Link from 'next/link'
import { redirect } from 'next/navigation'
import { formatSom } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { centerTimeZone, dayInZone, formatInTimeZone, isoDayInZone } from '@/lib/timezone'
import { isFinance } from '@/lib/roles'
import { label, t } from '@/lib/messages'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { PeriodNav } from '@/components/ui/period-nav'
import { monthLabel } from '@/lib/timezone'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { cn } from '@/lib/utils'
import { toAppError } from '@/lib/errors'
import { FormError } from '@/components/ui/alert'
import { PageNoticeProvider } from '@/components/ui/page-notice'
import { AdjustmentForm, ApproveForm, CancelRunForm, PayoutAction } from './salary-forms'
import { VoidExpenseForm } from '../finance/finance-forms'

export const metadata = { title: 'Зарплата — LogoCRM' }

function shiftMonth(month: string, delta: number): string {
  const [y, m] = month.split('-').map(Number)
  const total = y! * 12 + (m! - 1) + delta
  return `${Math.floor(total / 12)}-${String((total % 12) + 1).padStart(2, '0')}`
}


function calendarDate(day: string, timeZone: string): string {
  return formatInTimeZone(`${day}T12:00:00Z`, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' })
}

export default async function SalaryPage({
  searchParams,
}: {
  searchParams: Promise<{ month?: string; teacher?: string }>
}) {
  const params = await searchParams
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  // Специалист смотрит своё в /app/my-salary; здесь — все специалисты
  // (salary_summary под can_finance отдаёт всех, под teacher — свою строку).
  const { data: role } = await supabase.rpc('my_role')
  if (!isFinance(role)) redirect('/app')
  const isOwner = role === 'owner'

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? ''
  const { data: center } = await supabase.from('centers').select('settings').eq('id', centerId).maybeSingle()
  const timeZone = centerTimeZone(center?.settings)
  const today = isoDayInZone(new Date(), timeZone)

  const month = /^\d{4}-\d{2}$/.test(params.month ?? '') ? params.month! : today.slice(0, 7)
  const first = `${month}-01`
  // approve_salary — только за полностью прошедший месяц.
  const isPastMonth = month < today.slice(0, 7)
  // pay_salary — за текущий и прошлые месяцы (аванс — не больше заработанного на сегодня).
  const canPayMonth = month <= today.slice(0, 7)
  const expanded = params.teacher && /^[0-9a-f-]{36}$/.test(params.teacher) ? params.teacher : null

  const [{ data: summary, error: summaryError }, { data: teachers }, { data: adjustments }, { data: sourceRows }] = await Promise.all([
    supabase.rpc('salary_summary', { p_month: first }),
    supabase.from('teachers').select('id, full_name').is('deleted_at', null).order('full_name'),
    supabase
      .from('salary_adjustments')
      .select('id, teacher_id, amount_tiyin, reason, created_at')
      .eq('month', first)
      .order('created_at'),
    // Кассы для выплаты — живые, как в формах платежей.
    supabase.from('payment_sources').select('id, name').eq('is_active', true).is('deleted_at', null).order('sort'),
  ])
  const sources = (sourceRows ?? []).map((src) => ({ id: src.id, name: src.name }))
  const teacherName = new Map((teachers ?? []).map((tr) => [tr.id, tr.full_name]))
  const rows = summary ?? []

  const [{ data: details }, { data: payouts }, { data: allSources }] = expanded
    ? await Promise.all([
        supabase.rpc('calc_salary', { p_teacher_id: expanded, p_month: first }),
        // Выплаты за месяц (0101) — строки expenses со специалистом и месяцем, отмены с минусом.
        supabase
          .from('expenses')
          .select('id, amount_tiyin, paid_at, source_id, kind, comment, voids_expense_id')
          .eq('teacher_id', expanded)
          .eq('salary_month', first)
          .order('paid_at'),
        supabase.from('payment_sources').select('id, name'),
      ])
    : [{ data: null }, { data: null }, { data: null }]
  const sourceName = new Map((allSources ?? []).map((src) => [src.id, src.name]))

  return (
    <PageNoticeProvider>
    <div className="space-y-6">
      <div>
        <h1 className="page-title">{t('salary', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('salary', 'subtitle')}</p>
        <Link href="/app/reports" className="text-sm text-primary underline-offset-4 hover:underline">
          {t('reports', 'title')} →
        </Link>
      </div>

      <PeriodNav
        label={monthLabel(first)}
        prev={`/app/salary?month=${shiftMonth(month, -1)}`}
        next={`/app/salary?month=${shiftMonth(month, 1)}`}
        prevLabel="Предыдущий месяц"
        nextLabel="Следующий месяц"
      />

      <Card>
        <CardHeader>
          <CardTitle>{monthLabel(first)}</CardTitle>
          <CardDescription>{t('salary', 'approveHint')}</CardDescription>
        </CardHeader>
        <CardContent>
          {/* Отказ salary_summary — не «специалистов нет»: раньше любая ошибка
              базы выглядела здесь как пустой центр. */}
          {summaryError ? (
            <FormError message={toAppError(summaryError, 'Не удалось посчитать зарплату за месяц').message} />
          ) : rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('salary', 'empty')}</p>
          ) : (
            <Table className="max-sm:[&_tr>*:nth-child(2)]:hidden max-sm:[&_tr>*:nth-child(3)]:hidden max-sm:[&_tr>*:nth-child(5)]:hidden max-sm:[&_tr>*:nth-child(7)]:hidden">
              <TableHeader>
                <TableRow>
                  <TableHead>{t('salary', 'colTeacher')}</TableHead>
                  <TableHead className="text-right">{t('salary', 'colCalc')}</TableHead>
                  <TableHead className="text-right">{t('salary', 'colAdjustments')}</TableHead>
                  <TableHead className="text-right">{t('salary', 'colTotal')}</TableHead>
                  <TableHead className="text-right">{t('salary', 'colPaid')}</TableHead>
                  <TableHead className="text-right">{t('salary', 'colDue')}</TableHead>
                  <TableHead>{t('salary', 'colApproved')}</TableHead>
                  <TableHead className="text-right"> </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((r) => {
                  const name = teacherName.get(r.teacher_id) ?? '—'
                  const isExpanded = expanded === r.teacher_id
                  const own = (adjustments ?? []).filter((a) => a.teacher_id === r.teacher_id)
                  return (
                    <TableRow key={r.teacher_id} className="align-top">
                      <TableCell className="font-medium">
                        {name}
                        {isExpanded ? (
                          <div className="mt-3 space-y-3 font-normal">
                            <DetailsTable rows={details ?? []} timeZone={timeZone} />
                            {own.length ? (
                              <ul className="space-y-1 text-sm text-muted-foreground">
                                {own.map((a) => (
                                  <li key={a.id}>
                                    {formatSom(a.amount_tiyin)} — {a.reason}
                                  </li>
                                ))}
                              </ul>
                            ) : null}
                            {!r.approved_run_id ? <AdjustmentForm teacherId={r.teacher_id} month={first} /> : null}
                            <PayoutsList
                              rows={payouts ?? []}
                              sourceName={sourceName}
                              timeZone={timeZone}
                              isOwner={isOwner}
                            />
                          </div>
                        ) : null}
                      </TableCell>
                      <TableCell className="text-right">{formatSom(r.calc_tiyin)}</TableCell>
                      <TableCell className={cn('text-right', r.adjustments_tiyin < 0 && 'text-destructive')}>
                        {formatSom(r.adjustments_tiyin)}
                      </TableCell>
                      <TableCell className="text-right font-medium">{formatSom(r.total_tiyin)}</TableCell>
                      <TableCell className="text-right tabular-nums">{formatSom(r.paid_tiyin)}</TableCell>
                      <TableCell className={cn('text-right font-medium tabular-nums', r.due_tiyin < 0 && 'text-destructive')}>
                        {r.due_tiyin < 0 ? t('salary', 'overpaid', { sum: formatSom(-r.due_tiyin) }) : formatSom(r.due_tiyin)}
                      </TableCell>
                      <TableCell className="text-sm">
                        {r.approved_run_id && r.approved_at
                          ? t('salary', 'approvedAt', { at: dayInZone(r.approved_at, timeZone) })
                          : t('salary', 'notApproved')}
                        {r.cancelled_runs > 0 ? (
                          <span className="block text-xs text-muted-foreground">
                            {t('salary', 'cancelledRuns', { count: r.cancelled_runs })}
                          </span>
                        ) : null}
                      </TableCell>
                      <TableCell>
                        <div className="flex flex-col items-end gap-2">
                          <Link
                            href={isExpanded ? `/app/salary?month=${month}` : `/app/salary?month=${month}&teacher=${r.teacher_id}`}
                            className={buttonVariants({ variant: 'outline', size: 'sm' })}
                          >
                            {isExpanded ? t('salary', 'hideDetails') : t('salary', 'details')}
                          </Link>
                          {canPayMonth && r.due_tiyin > 0 && sources.length ? (
                            <PayoutAction
                              teacherId={r.teacher_id}
                              teacherName={name}
                              month={first}
                              monthLabel={monthLabel(first)}
                              dueTiyin={r.due_tiyin}
                              sources={sources}
                              today={today}
                            />
                          ) : null}
                          {!r.approved_run_id && isPastMonth ? (
                            <ApproveForm teacherId={r.teacher_id} month={first} monthLabel={monthLabel(first)} teacherName={name} totalLabel={formatSom(r.total_tiyin)} />
                          ) : null}
                          {r.approved_run_id ? (
                            isOwner ? (
                              <CancelRunForm teacherId={r.teacher_id} month={first} monthLabel={monthLabel(first)} teacherName={name} totalLabel={formatSom(r.total_tiyin)} />
                            ) : (
                              <span className="text-xs text-muted-foreground">{t('salary', 'ownerOnly')}</span>
                            )
                          ) : null}
                        </div>
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
    </PageNoticeProvider>
  )
}

function DetailsTable({
  rows,
  timeZone,
}: {
  rows: { attendance_id: string; lesson_date: string; student_id: string; model: string | null; lesson_price_tiyin: number | null; amount_tiyin: number; note: string | null }[]
  timeZone: string
}) {
  if (rows.length === 0) {
    return <p className="text-sm text-muted-foreground">{t('salary', 'detailsEmpty')}</p>
  }
  return (
    <Table className="max-sm:[&_tr>*:nth-child(2)]:hidden max-sm:[&_tr>*:nth-child(3)]:hidden max-sm:[&_tr>*:nth-child(5)]:hidden">
      <TableHeader>
        <TableRow>
          <TableHead>{t('salary', 'colDate')}</TableHead>
          <TableHead>{t('salary', 'colModel')}</TableHead>
          <TableHead className="text-right">{t('salary', 'colLessonPrice')}</TableHead>
          <TableHead className="text-right">{t('salary', 'colAmount')}</TableHead>
          <TableHead>{t('salary', 'colNote')}</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((r) => (
          <TableRow key={r.attendance_id}>
            <TableCell className="whitespace-nowrap">{calendarDate(r.lesson_date, timeZone)}</TableCell>
            <TableCell>{r.model ? label('salary', `model_${r.model}`) : '—'}</TableCell>
            <TableCell className="text-right">{r.lesson_price_tiyin == null ? '—' : formatSom(r.lesson_price_tiyin)}</TableCell>
            <TableCell className="text-right font-medium">{formatSom(r.amount_tiyin)}</TableCell>
            <TableCell className="text-muted-foreground">{r.note ?? ''}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}

/**
 * Выплаты специалисту за месяц (0101): строки expenses со специалистом и
 * месяцем. Отменённая выплата остаётся в списке зачёркнутой, рядом — её
 * отмена с минусом; «Выплачено» в строке выше уже за вычетом отмен.
 */
function PayoutsList({
  rows,
  sourceName,
  timeZone,
  isOwner,
}: {
  rows: { id: string; amount_tiyin: number; paid_at: string; source_id: string | null; kind: string; comment: string | null; voids_expense_id: string | null }[]
  sourceName: Map<string, string>
  timeZone: string
  isOwner: boolean
}) {
  const voided = new Set(rows.map((r) => r.voids_expense_id).filter((v): v is string => Boolean(v)))
  return (
    <div className="space-y-2">
      <p className="text-sm font-medium">{t('salary', 'payoutsTitle')}</p>
      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('salary', 'payoutsEmpty')}</p>
      ) : (
        <ul className="space-y-2 text-sm">
          {rows.map((r) => (
            <li key={r.id} className="flex flex-wrap items-start justify-between gap-2">
              <span className={cn(voided.has(r.id) && 'text-muted-foreground line-through')}>
                {dayInZone(r.paid_at, timeZone)} · {r.source_id ? (sourceName.get(r.source_id) ?? '—') : '—'}
                {r.comment ? ` · ${r.comment}` : ''}
                {voided.has(r.id) ? ` · ${t('salary', 'payoutVoided')}` : ''}
              </span>
              <span className="flex items-start gap-2">
                <span className={cn('tabular-nums font-medium', r.amount_tiyin < 0 && 'text-destructive')}>{formatSom(r.amount_tiyin)}</span>
                {isOwner && r.kind === 'expense' && !voided.has(r.id) ? <VoidExpenseForm expenseId={r.id} amountTiyin={r.amount_tiyin} /> : null}
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
