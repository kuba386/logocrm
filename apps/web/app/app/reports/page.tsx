import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { isFinance } from '@/lib/roles'
import { t } from '@/lib/messages'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { DebtsReportForm, PeriodReportForm, SalaryReportForm } from './report-forms'

export const metadata = { title: 'Отчёты — LogoCRM' }

/**
 * Выгрузки в CSV (0058) — одна страница на все роли, ветвление внутри:
 * деньги (платежи, зарплата, долги) — owner/admin/finance, посещаемость —
 * только owner/admin. Карточки рисуются по тому же предикату, что гейт в
 * SQL (Р14), но отказ приходит из базы.
 */
export default async function ReportsPage() {
  const supabase = await createClient()
  const { data: role } = await supabase.rpc('my_role')
  if (!role) redirect('/select-center')
  if (!isFinance(role)) redirect('/app')
  const isAdmin = role === 'owner' || role === 'admin'

  // Даты по умолчанию — от пояса центра, не от UTC сервера: вечером в
  // Бишкеке «сегодня» иначе означало бы вчера.
  const { data: today } = await supabase.rpc('center_today', {})
  const todayIso = today ?? new Date().toISOString().slice(0, 10)
  const monthStart = `${todayIso.slice(0, 7)}-01`
  const [y, m] = todayIso.split('-').map(Number)
  const prevMonth = new Date(Date.UTC(y!, m! - 2, 1)).toISOString().slice(0, 7)

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('reports', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('reports', 'subtitle')}</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{t('reports', 'paymentsTitle')}</CardTitle>
          <CardDescription>{t('reports', 'paymentsHint')}</CardDescription>
        </CardHeader>
        <CardContent>
          <PeriodReportForm report="payments" from={monthStart} to={todayIso} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t('reports', 'salaryTitle')}</CardTitle>
          <CardDescription>{t('reports', 'salaryHint')}</CardDescription>
        </CardHeader>
        <CardContent>
          <SalaryReportForm month={prevMonth} />
        </CardContent>
      </Card>

      {isAdmin ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('reports', 'attendanceTitle')}</CardTitle>
            <CardDescription>{t('reports', 'attendanceHint')}</CardDescription>
          </CardHeader>
          <CardContent>
            <PeriodReportForm report="attendance" from={monthStart} to={todayIso} />
          </CardContent>
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>{t('reports', 'debtsTitle')}</CardTitle>
          <CardDescription>{t('reports', 'debtsHint')}</CardDescription>
        </CardHeader>
        <CardContent>
          <DebtsReportForm />
        </CardContent>
      </Card>
    </div>
  )
}
