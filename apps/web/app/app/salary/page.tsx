import Link from 'next/link'
import { redirect } from 'next/navigation'
import { formatSom } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { centerTimeZone, dayInZone, formatInTimeZone, isoDayInZone } from '@/lib/timezone'
import { isFinance } from '@/lib/roles'
import { label, t } from '@/lib/messages'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { cn } from '@/lib/utils'
import { AdjustmentForm, ApproveForm, CancelRunForm } from './salary-forms'

export const metadata = { title: 'Зарплата — LogoCRM' }

function shiftMonth(month: string, delta: number): string {
  const [y, m] = month.split('-').map(Number)
  const total = y! * 12 + (m! - 1) + delta
  return `${Math.floor(total / 12)}-${String((total % 12) + 1).padStart(2, '0')}`
}

function monthLabel(first: string): string {
  const raw = new Intl.DateTimeFormat('ru-RU', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(
    new Date(`${first}T12:00:00Z`),
  )
  return raw.charAt(0).toUpperCase() + raw.slice(1)
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
  const expanded = params.teacher && /^[0-9a-f-]{36}$/.test(params.teacher) ? params.teacher : null

  const [{ data: summary }, { data: teachers }, { data: adjustments }] = await Promise.all([
    supabase.rpc('salary_summary', { p_month: first }),
    supabase.from('teachers').select('id, full_name').is('deleted_at', null).order('full_name'),
    supabase
      .from('salary_adjustments')
      .select('id, teacher_id, amount_tiyin, reason, created_at')
      .eq('month', first)
      .order('created_at'),
  ])
  const teacherName = new Map((teachers ?? []).map((tr) => [tr.id, tr.full_name]))
  const rows = summary ?? []

  const { data: details } = expanded ? await supabase.rpc('calc_salary', { p_teacher_id: expanded, p_month: first }) : { data: null }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('salary', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('salary', 'subtitle')}</p>
        <Link href="/app/reports" className="text-sm text-primary underline-offset-4 hover:underline">
          {t('reports', 'title')} →
        </Link>
      </div>

      <div className="flex items-center gap-2 text-sm">
        <Link href={`/app/salary?month=${shiftMonth(month, -1)}`} className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
          {t('finance', 'prevMonth')}
        </Link>
        <span className="font-medium">{monthLabel(first)}</span>
        <Link href={`/app/salary?month=${shiftMonth(month, 1)}`} className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
          {t('finance', 'nextMonth')}
        </Link>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{monthLabel(first)}</CardTitle>
          <CardDescription>{t('salary', 'approveHint')}</CardDescription>
        </CardHeader>
        <CardContent>
          {rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('salary', 'empty')}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('salary', 'colTeacher')}</TableHead>
                  <TableHead className="text-right">{t('salary', 'colCalc')}</TableHead>
                  <TableHead className="text-right">{t('salary', 'colAdjustments')}</TableHead>
                  <TableHead className="text-right">{t('salary', 'colTotal')}</TableHead>
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
                          </div>
                        ) : null}
                      </TableCell>
                      <TableCell className="text-right">{formatSom(r.calc_tiyin)}</TableCell>
                      <TableCell className={cn('text-right', r.adjustments_tiyin < 0 && 'text-destructive')}>
                        {formatSom(r.adjustments_tiyin)}
                      </TableCell>
                      <TableCell className="text-right font-medium">{formatSom(r.total_tiyin)}</TableCell>
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
                          {!r.approved_run_id && isPastMonth ? (
                            <ApproveForm teacherId={r.teacher_id} month={first} monthLabel={monthLabel(first)} />
                          ) : null}
                          {r.approved_run_id ? (
                            isOwner ? (
                              <CancelRunForm teacherId={r.teacher_id} month={first} />
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
    <Table>
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
