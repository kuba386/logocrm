import { ArrowDownToLine, ArrowUpFromLine, Banknote, TrendingUp, Users } from 'lucide-react'
import { formatSom } from '@logocrm/core'
import type { createClient } from '@/lib/supabase/server'
import { t } from '@/lib/messages'
import { monthBounds, shiftMonth } from '@/lib/month'
import { monthLabel, startOfDayInZone } from '@/lib/timezone'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { PeriodNav } from '@/components/ui/period-nav'
import { StatTile } from '@/components/ui/stat-tile'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { FormError } from '@/components/ui/alert'
import { loadErrorMessage } from '@/lib/errors'

type Supabase = Awaited<ReturnType<typeof createClient>>

/**
 * Итоги месяца на экране — то, что раньше было только в CSV. Ни одной
 * формулы здесь: касса — cash_by_source, выручка — revenue_by_month, зарплата
 * — salary_summary, расходы — строки expenses за месяц в поясе центра. Те же
 * источники, что у «Финансов» и дашборда, поэтому цифры совпадают с ними.
 *
 * «Прибыли» нет намеренно: выплаченная зарплата часто проводится расходом по
 * статье «Зарплата», и «выручка − зарплата − расходы» посчитала бы её дважды.
 * Касса — что реально пришло и ушло; выручка и зарплата — начисление.
 */
export async function MonthSummary({
  supabase,
  month,
  timeZone,
}: {
  supabase: Supabase
  month: string
  timeZone: string
}) {
  const { first, next } = monthBounds(month)
  const fromIso = startOfDayInZone(first, timeZone)
  const toIso = startOfDayInZone(next, timeZone)

  const results = await Promise.all([
    supabase.from('cash_by_source').select('received_tiyin, refunded_tiyin, corrections_tiyin, spent_tiyin, total_tiyin').eq('month', first),
    supabase.from('revenue_by_month').select('revenue_tiyin, visits').eq('month', first),
    supabase.rpc('salary_summary', { p_month: first }),
    supabase.from('expenses').select('category_id, amount_tiyin').gte('paid_at', fromIso).lt('paid_at', toIso),
    supabase.from('expense_categories').select('id, name'),
    // Разрез выручки — те же витрины, что «Выручка» выше (0021): сумма строк сходится с плиткой.
    supabase.from('revenue_by_teacher').select('teacher_id, lessons, visits, revenue_tiyin').eq('month', first),
    supabase.from('revenue_by_service').select('service_id, lessons, visits, revenue_tiyin').eq('month', first),
  ])
  const [{ data: cash }, { data: revenue }, { data: salary }, { data: expenses }, { data: categories }, { data: byTeacher }, { data: byService }] =
    results
  // Имена резолвит интерфейс (Database.md, «Правила витрин»): архивного специалиста
  // RLS teachers не отдаёт, услуги бухгалтеру закрыты — тогда подпись-заглушка.
  const teacherIds = (byTeacher ?? []).map((r) => r.teacher_id).filter((v): v is string => Boolean(v))
  const serviceIds = (byService ?? []).map((r) => r.service_id).filter((v): v is string => Boolean(v))
  const [{ data: teacherRows }, { data: serviceRows }] = await Promise.all([
    teacherIds.length ? supabase.from('teachers').select('id, full_name').in('id', teacherIds) : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
    serviceIds.length ? supabase.from('services').select('id, name').in('id', serviceIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
  ])
  const teacherName = new Map((teacherRows ?? []).map((r) => [r.id, r.full_name]))
  const serviceName = new Map((serviceRows ?? []).map((r) => [r.id, r.name]))
  const teacherBreakdown = (byTeacher ?? [])
    .map((r) => ({
      key: r.teacher_id ?? 'none',
      name: r.teacher_id ? (teacherName.get(r.teacher_id) ?? 'Специалист в архиве') : 'Без специалиста',
      lessons: r.lessons ?? 0,
      visits: r.visits ?? 0,
      revenue: r.revenue_tiyin ?? 0,
    }))
    .sort((a, b) => b.revenue - a.revenue)
  const serviceBreakdown = (byService ?? [])
    .map((r) => ({
      key: r.service_id ?? 'none',
      name: r.service_id ? (serviceName.get(r.service_id) ?? 'Услуга') : 'Без услуги',
      lessons: r.lessons ?? 0,
      visits: r.visits ?? 0,
      revenue: r.revenue_tiyin ?? 0,
    }))
    .sort((a, b) => b.revenue - a.revenue)
  // Любой отказ — плашка вместо плиток: «Касса 0 сом» при сбое читалась бы
  // как настоящая цифра (UX-аудит 6.10.2026, пакет 4).
  const loadError = results.find((r) => r.error)?.error ?? null

  const sum = <T,>(rows: T[] | null, pick: (r: T) => number | null) => (rows ?? []).reduce((acc, r) => acc + (pick(r) ?? 0), 0)
  const received = sum(cash, (r) => r.received_tiyin) + sum(cash, (r) => r.corrections_tiyin) + sum(cash, (r) => r.refunded_tiyin)
  // spent_tiyin в кассе — со знаком минус (деньги ушли); на плитке — сумма расходов.
  // `|| 0`: без расходов здесь получался «-0 сом» (минус нуля).
  const spent = -sum(cash, (r) => r.spent_tiyin) || 0
  const total = sum(cash, (r) => r.total_tiyin)
  const revenueTotal = sum(revenue, (r) => r.revenue_tiyin)
  const visits = sum(revenue, (r) => r.visits)
  const salaryTotal = sum(salary, (r) => r.total_tiyin)

  const categoryName = new Map((categories ?? []).map((c) => [c.id, c.name]))
  const byCategory = new Map<string, number>()
  for (const row of expenses ?? []) {
    byCategory.set(row.category_id, (byCategory.get(row.category_id) ?? 0) + row.amount_tiyin)
  }
  const categoryRows = [...byCategory.entries()]
    .map(([id, amount]) => ({ name: categoryName.get(id) ?? '—', amount }))
    .filter((r) => r.amount !== 0)
    .sort((a, b) => b.amount - a.amount)

  return (
    <Card>
      <CardHeader className="gap-3 sm:flex-row sm:items-start sm:justify-between sm:space-y-0">
        <div className="space-y-1.5">
          <CardTitle>{t('reports', 'monthTitle')}</CardTitle>
          <CardDescription>{t('reports', 'monthHint')}</CardDescription>
        </div>
        <PeriodNav
          label={monthLabel(first)}
          prev={`/app/reports?month=${shiftMonth(month, -1)}`}
          next={`/app/reports?month=${shiftMonth(month, 1)}`}
          prevLabel="Предыдущий месяц"
          nextLabel="Следующий месяц"
        />
      </CardHeader>
      <CardContent className="space-y-6">
        {loadError ? <FormError message={loadErrorMessage(loadError, t('reports', 'monthLoadFailed'))} /> : null}
        {/* Условный рендер, а не hidden: у Tailwind .grid перебивает [hidden] — при сбое
            рядом с ошибкой оставались нулевые плитки. */}
        {loadError ? null : (
          <>
          <div className="grid grid-cols-[repeat(auto-fit,minmax(9.5rem,1fr))] gap-3" data-testid="month-summary">
            <StatTile icon={ArrowDownToLine} tone="success" value={formatSom(received)} label={t('reports', 'monthReceived')} hint={t('reports', 'monthReceivedHint')} />
            <StatTile icon={ArrowUpFromLine} tone={spent > 0 ? 'warning' : 'neutral'} value={formatSom(spent)} label={t('reports', 'monthSpent')} />
            <StatTile icon={Banknote} tone="primary" value={formatSom(total)} label={t('reports', 'monthCash')} hint={t('reports', 'monthCashHint')} />
            <StatTile
              icon={TrendingUp}
              tone="info"
              value={formatSom(revenueTotal)}
              label={t('reports', 'monthRevenue')}
              hint={t('reports', 'monthRevenueHint', { visits })}
            />
            <StatTile icon={Users} tone="neutral" value={formatSom(salaryTotal)} label={t('reports', 'monthSalary')} hint={t('reports', 'monthSalaryHint')} />
          </div>

          <div className="grid gap-6 lg:grid-cols-2">
            <Breakdown title={t('reports', 'monthByTeacher')} rows={teacherBreakdown} />
            <Breakdown title={t('reports', 'monthByService')} rows={serviceBreakdown} />
          </div>

          <div className="space-y-2">
            <h3 className="text-sm font-medium">{t('reports', 'monthByCategory')}</h3>
            {categoryRows.length === 0 ? (
              <p className="text-sm text-muted-foreground">{t('reports', 'monthNoExpenses')}</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t('reports', 'monthCategory')}</TableHead>
                    <TableHead className="text-right">{t('reports', 'monthAmount')}</TableHead>
                    <TableHead className="text-right">{t('reports', 'monthShare')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {categoryRows.map((row) => (
                    <TableRow key={row.name}>
                      <TableCell>{row.name}</TableCell>
                      <TableCell className="text-right tabular-nums">{formatSom(row.amount)}</TableCell>
                      <TableCell className="text-right tabular-nums text-muted-foreground">
                        {spent > 0 ? `${Math.round((row.amount / spent) * 100)}%` : '—'}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </div>
          </>
        )}
      </CardContent>
    </Card>
  )
}

/** Разрез выручки месяца (по специалистам или услугам): строки витрины как есть, без формул. */
function Breakdown({
  title,
  rows,
}: {
  title: string
  rows: { key: string; name: string; lessons: number; visits: number; revenue: number }[]
}) {
  return (
    <div className="space-y-2">
      <h3 className="text-sm font-medium">{title}</h3>
      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('reports', 'monthNoRevenue')}</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>{t('reports', 'monthName')}</TableHead>
              <TableHead className="text-right">{t('reports', 'monthVisits')}</TableHead>
              <TableHead className="text-right">{t('reports', 'monthRevenue')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.key}>
                <TableCell>{row.name}</TableCell>
                <TableCell className="text-right tabular-nums text-muted-foreground">{row.visits}</TableCell>
                <TableCell className="text-right tabular-nums">{formatSom(row.revenue)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  )
}
