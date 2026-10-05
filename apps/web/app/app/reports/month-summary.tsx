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

  const [{ data: cash }, { data: revenue }, { data: salary }, { data: expenses }, { data: categories }] = await Promise.all([
    supabase.from('cash_by_source').select('received_tiyin, refunded_tiyin, corrections_tiyin, spent_tiyin, total_tiyin').eq('month', first),
    supabase.from('revenue_by_month').select('revenue_tiyin, visits').eq('month', first),
    supabase.rpc('salary_summary', { p_month: first }),
    supabase.from('expenses').select('category_id, amount_tiyin').gte('paid_at', fromIso).lt('paid_at', toIso),
    supabase.from('expense_categories').select('id, name'),
  ])

  const sum = <T,>(rows: T[] | null, pick: (r: T) => number | null) => (rows ?? []).reduce((acc, r) => acc + (pick(r) ?? 0), 0)
  const received = sum(cash, (r) => r.received_tiyin) + sum(cash, (r) => r.corrections_tiyin) + sum(cash, (r) => r.refunded_tiyin)
  // spent_tiyin в кассе — со знаком минус (деньги ушли); на плитке — сумма расходов.
  const spent = -sum(cash, (r) => r.spent_tiyin)
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
      </CardContent>
    </Card>
  )
}
