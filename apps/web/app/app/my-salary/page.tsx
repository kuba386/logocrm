import Link from 'next/link'
import { redirect } from 'next/navigation'
import { formatSom } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { centerTimeZone, dayInZone, formatInTimeZone, isoDayInZone } from '@/lib/timezone'
import { label, t } from '@/lib/messages'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'

export const metadata = { title: 'Моя зарплата — LogoCRM' }

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

/**
 * Специалист видит только своё: salary_summary под teacher отдаёт одну
 * строку (t.id = my_teacher_id()), calc_salary — свои строки, цена занятия
 * скрыта везде, кроме собственного процента (ADR-005). Ни денег центра, ни
 * чужих сумм здесь нет физически — не потому что не показали.
 */
export default async function MySalaryPage({ searchParams }: { searchParams: Promise<{ month?: string }> }) {
  const params = await searchParams
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'teacher') redirect('/app')

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? ''
  const [{ data: center }, { data: teacherId }] = await Promise.all([
    supabase.from('centers').select('settings').eq('id', centerId).maybeSingle(),
    supabase.rpc('my_teacher_id'),
  ])
  const timeZone = centerTimeZone(center?.settings)
  const today = isoDayInZone(new Date(), timeZone)
  const month = /^\d{4}-\d{2}$/.test(params.month ?? '') ? params.month! : today.slice(0, 7)
  const first = `${month}-01`

  const [{ data: summary }, { data: details }] = await Promise.all([
    supabase.rpc('salary_summary', { p_month: first }),
    teacherId ? supabase.rpc('calc_salary', { p_teacher_id: teacherId, p_month: first }) : Promise.resolve({ data: null }),
  ])
  const mine = summary?.[0]
  const rows = details ?? []

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('mySalary', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('mySalary', 'subtitle')}</p>
      </div>

      <div className="flex items-center gap-2 text-sm">
        <Link href={`/app/my-salary?month=${shiftMonth(month, -1)}`} className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
          {t('finance', 'prevMonth')}
        </Link>
        <span className="font-medium">{monthLabel(first)}</span>
        <Link href={`/app/my-salary?month=${shiftMonth(month, 1)}`} className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
          {t('finance', 'nextMonth')}
        </Link>
      </div>

      {!teacherId || !mine ? (
        <p className="text-sm text-muted-foreground">{t('mySalary', 'noCard')}</p>
      ) : (
        <>
          <dl className="grid grid-cols-2 gap-3 rounded-md border border-border bg-muted/50 p-3 text-sm sm:grid-cols-4">
            <div>
              <dt className="text-xs text-muted-foreground">{t('salary', 'colCalc')}</dt>
              <dd className="font-medium">{formatSom(mine.calc_tiyin)}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">{t('salary', 'colAdjustments')}</dt>
              <dd className="font-medium">{formatSom(mine.adjustments_tiyin)}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">{t('salary', 'colTotal')}</dt>
              <dd className="font-medium">{formatSom(mine.total_tiyin)}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">{t('salary', 'colApproved')}</dt>
              <dd className="font-medium">
                {mine.approved_run_id && mine.approved_at
                  ? t('salary', 'approvedAt', { at: dayInZone(mine.approved_at, timeZone) })
                  : t('salary', 'notApproved')}
              </dd>
            </div>
          </dl>

          <Card>
            <CardHeader>
              <CardTitle>{t('salary', 'details')}</CardTitle>
              <CardDescription>{t('mySalary', 'detailsHint')}</CardDescription>
            </CardHeader>
            <CardContent>
              {rows.length === 0 ? (
                <p className="text-sm text-muted-foreground">{t('mySalary', 'detailsEmpty')}</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t('salary', 'colDate')}</TableHead>
                      <TableHead>{t('salary', 'colModel')}</TableHead>
                      <TableHead className="text-right">{t('salary', 'colAmount')}</TableHead>
                      <TableHead>{t('salary', 'colNote')}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {rows.map((r) => (
                      <TableRow key={r.attendance_id}>
                        <TableCell className="whitespace-nowrap">{calendarDate(r.lesson_date, timeZone)}</TableCell>
                        <TableCell>{r.model ? label('salary', `model_${r.model}`) : '—'}</TableCell>
                        <TableCell className="text-right font-medium">{formatSom(r.amount_tiyin)}</TableCell>
                        <TableCell className="text-muted-foreground">{r.note ?? ''}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  )
}
