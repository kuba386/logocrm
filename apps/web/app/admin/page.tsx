import { formatSom, toSom } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { label, t } from '@/lib/messages'
import { formatInTimeZone } from '@/lib/timezone'
import { ConfirmForm, RejectForm } from './claim-forms'

export const metadata = { title: 'Платформа — LogoCRM' }

/**
 * Пульт платформы (этап 8a): открытые заявки — из platform_open_payments()
 * (источник истины, Telegram-уведомление лишь дополнение), подтверждение и
 * отклонение — RPC 0051, история и выручка — по platform_payments (политика
 * select пускает is_platform_admin()). Даты — в поясе центра-заявителя,
 * строкой из базы.
 */
export default async function AdminPage() {
  const supabase = await createClient()

  const [{ data: open, error: openError }, { data: plans }, { data: confirmed }] = await Promise.all([
    supabase.rpc('platform_open_payments'),
    supabase.from('plans').select('code, name').eq('is_public', true).order('sort'),
    supabase
      .from('platform_payments')
      .select('id, center_id, plan, months, amount_tiyin, confirmed_at, receipt_received, claimed_plan, claimed_months')
      .not('confirmed_at', 'is', null)
      .order('confirmed_at', { ascending: false })
      .limit(50),
  ])

  const planOptions = (plans ?? []).filter((p) => p.code !== 'trial')

  // Выручка по месяцам подтверждения (UTC-месяц: платформа одна, центры в
  // разных поясах — здесь считаем деньги платформы, не дни центра).
  const byMonth = new Map<string, { total: number; count: number }>()
  for (const p of confirmed ?? []) {
    if (!p.confirmed_at || p.amount_tiyin === null) continue
    const key = p.confirmed_at.slice(0, 7)
    const row = byMonth.get(key) ?? { total: 0, count: 0 }
    row.total += p.amount_tiyin
    row.count += 1
    byMonth.set(key, row)
  }
  const months = [...byMonth.entries()].sort((a, b) => (a[0] < b[0] ? 1 : -1)).slice(0, 6)

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('admin', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('admin', 'subtitle')}</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{t('admin', 'openTitle')}</CardTitle>
          <CardDescription>{t('admin', 'openSubtitle')}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {openError ? (
            <p role="alert" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
              {t('admin', 'loadFailed')}
            </p>
          ) : (open ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('admin', 'openEmpty')}</p>
          ) : (
            (open ?? []).map((row) => (
              <div key={row.payment_id} className="space-y-3 rounded-md border border-border p-4">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <div>
                    <p className="font-medium">{row.center_name}</p>
                    <p className="text-xs text-muted-foreground">
                      {t('admin', 'centerNow', {
                        plan: label('plan_names', row.center_plan),
                        until: row.center_until_text ?? '—',
                      })}
                      {row.submitted_by_email ? ` · ${row.submitted_by_email}` : ''}
                    </p>
                  </div>
                  <p className="text-xs text-muted-foreground">
                    {formatInTimeZone(row.created_at, row.center_timezone, {
                      day: '2-digit',
                      month: '2-digit',
                      year: 'numeric',
                      hour: '2-digit',
                      minute: '2-digit',
                    })}
                  </p>
                </div>

                <dl className="grid gap-1 text-sm sm:grid-cols-4">
                  <dt className="text-muted-foreground">{t('admin', 'claimed')}</dt>
                  <dd className="sm:col-span-3">
                    {label('plan_names', row.claimed_plan)} × {row.claimed_months} {t('plan', 'monthsShort')} —{' '}
                    <span className="font-medium">{formatSom(row.claimed_amount_tiyin)}</span>,{' '}
                    {label('platformPaymentSource', row.source)}
                  </dd>
                  {row.note ? (
                    <>
                      <dt className="text-muted-foreground">{t('admin', 'note')}</dt>
                      <dd className="sm:col-span-3">{row.note}</dd>
                    </>
                  ) : null}
                  <dt className="text-muted-foreground">{t('admin', 'number')}</dt>
                  <dd className="font-mono text-xs sm:col-span-3">{row.payment_id}</dd>
                </dl>

                <div className="grid gap-4 md:grid-cols-2">
                  <ConfirmForm
                    paymentId={row.payment_id}
                    plans={planOptions}
                    claimedPlan={row.claimed_plan}
                    claimedMonths={row.claimed_months}
                    claimedAmountSom={toSom(row.claimed_amount_tiyin)}
                  />
                  <RejectForm paymentId={row.payment_id} />
                </div>
              </div>
            ))
          )}
        </CardContent>
      </Card>

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>{t('admin', 'revenueTitle')}</CardTitle>
            <CardDescription>{t('admin', 'revenueSubtitle')}</CardDescription>
          </CardHeader>
          <CardContent>
            {months.length === 0 ? (
              <p className="text-sm text-muted-foreground">{t('admin', 'revenueEmpty')}</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t('admin', 'colMonth')}</TableHead>
                    <TableHead className="text-right">{t('admin', 'colCount')}</TableHead>
                    <TableHead className="text-right">{t('admin', 'colTotal')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {months.map(([month, row]) => (
                    <TableRow key={month}>
                      <TableCell>{month}</TableCell>
                      <TableCell className="text-right tabular-nums">{row.count}</TableCell>
                      <TableCell className="text-right tabular-nums">{formatSom(row.total)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{t('admin', 'recentTitle')}</CardTitle>
            <CardDescription>{t('admin', 'recentSubtitle')}</CardDescription>
          </CardHeader>
          <CardContent>
            {(confirmed ?? []).length === 0 ? (
              <p className="text-sm text-muted-foreground">{t('admin', 'recentEmpty')}</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t('admin', 'colDate')}</TableHead>
                    <TableHead>{t('admin', 'colPlan')}</TableHead>
                    <TableHead className="text-right">{t('admin', 'colTotal')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(confirmed ?? []).slice(0, 10).map((p) => (
                    <TableRow key={p.id}>
                      <TableCell className="whitespace-nowrap">{p.confirmed_at?.slice(0, 10) ?? '—'}</TableCell>
                      <TableCell>
                        {label('plan_names', p.plan ?? '')} × {p.months ?? 0} {t('plan', 'monthsShort')}
                        {!p.receipt_received ? (
                          <span className="block text-xs text-muted-foreground">{t('admin', 'noReceipt')}</span>
                        ) : null}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">
                        {p.amount_tiyin !== null ? formatSom(p.amount_tiyin) : '—'}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
