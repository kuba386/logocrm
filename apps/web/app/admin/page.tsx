import { formatSom, toSom } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { label, t } from '@/lib/messages'
import { formatInTimeZone } from '@/lib/timezone'
import { cn } from '@/lib/utils'
import { ConfirmForm, RejectForm } from './claim-forms'
import { CreateCenterForm } from './create-center-form'

export const metadata = { title: 'Платформа — LogoCRM' }

type Summary = {
  centers_total: number
  centers_trial: number
  centers_paid: number
  centers_expired: number
  centers_no_date: number
  open_claims: number
  mrr_tiyin: number
  revenue: { month: string; count: number; total_tiyin: number }[]
}

function parseSummary(json: unknown): Summary | null {
  if (!json || typeof json !== 'object') return null
  const o = json as Record<string, unknown>
  const n = (v: unknown) => (typeof v === 'number' ? v : 0)
  const revenue = Array.isArray(o.revenue)
    ? o.revenue
        .filter((r): r is Record<string, unknown> => !!r && typeof r === 'object')
        .map((r) => ({ month: String(r.month ?? ''), count: n(r.count), total_tiyin: n(r.total_tiyin) }))
    : []
  return {
    centers_total: n(o.centers_total),
    centers_trial: n(o.centers_trial),
    centers_paid: n(o.centers_paid),
    centers_expired: n(o.centers_expired),
    centers_no_date: n(o.centers_no_date),
    open_claims: n(o.open_claims),
    mrr_tiyin: n(o.mrr_tiyin),
    revenue,
  }
}

function daysText(days: number | null): string {
  if (days === null) return t('admin', 'untilNone')
  if (days === 0) return t('admin', 'daysToday')
  if (days < 0) return t('admin', 'daysOverdue', { days: -days })
  return t('admin', 'daysLeft', { days })
}

function Stat({ title, value, hint }: { title: string; value: string; hint?: string }) {
  return (
    <div className="rounded-md border border-border p-3">
      <p className="text-xs text-muted-foreground">{title}</p>
      <p className="text-xl font-semibold tabular-nums">{value}</p>
      {hint ? <p className="text-xs text-muted-foreground">{hint}</p> : null}
    </div>
  )
}

/**
 * Пульт платформы (этап 8a): сводка и список центров — platform_summary()
 * и platform_centers() (0052), открытые заявки — platform_open_payments()
 * (источник истины, Telegram лишь дополнение), подтверждение и отклонение —
 * RPC 0051. Деньги, дни и режим считает SQL; даты — в поясе центра строкой.
 */
export default async function AdminPage() {
  const supabase = await createClient()

  const [
    { data: summaryJson },
    { data: centers },
    { data: open, error: openError },
    { data: plans },
    { data: confirmed },
  ] = await Promise.all([
    supabase.rpc('platform_summary'),
    supabase.rpc('platform_centers'),
    supabase.rpc('platform_open_payments'),
    supabase.from('plans').select('code, name').eq('is_public', true).order('sort'),
    supabase
      .from('platform_payments')
      .select('id, center_id, plan, months, amount_tiyin, confirmed_at, receipt_received')
      .not('confirmed_at', 'is', null)
      .order('confirmed_at', { ascending: false })
      .limit(10),
  ])

  const summary = parseSummary(summaryJson)
  const planOptions = (plans ?? []).filter((p) => p.code !== 'trial')

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('admin', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('admin', 'subtitle')}</p>
      </div>

      {summary ? (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Stat
            title={t('admin', 'summaryCenters')}
            value={String(summary.centers_total)}
            hint={`${summary.centers_trial} ${t('admin', 'summaryTrial')} · ${summary.centers_paid} ${t('admin', 'summaryPaid')}`}
          />
          <Stat
            title={t('admin', 'summaryExpired')}
            value={String(summary.centers_expired)}
            hint={`${summary.centers_no_date} ${t('admin', 'summaryNoDate')}`}
          />
          <Stat title={t('admin', 'summaryOpen')} value={String(summary.open_claims)} />
          <Stat title={t('admin', 'summaryMrr')} value={formatSom(summary.mrr_tiyin)} hint={t('admin', 'summaryMrrHint')} />
        </div>
      ) : null}

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

      <Card>
        <CardHeader>
          <CardTitle>{t('admin', 'centersTitle')}</CardTitle>
          <CardDescription>{t('admin', 'centersSubtitle')}</CardDescription>
        </CardHeader>
        <CardContent>
          {(centers ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('admin', 'centersEmpty')}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('admin', 'colCenter')}</TableHead>
                  <TableHead>{t('admin', 'colPlan')}</TableHead>
                  <TableHead>{t('admin', 'colUntil')}</TableHead>
                  <TableHead className="text-right">{t('admin', 'colUsage')}</TableHead>
                  <TableHead>{t('admin', 'colOwner')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(centers ?? []).map((c) => (
                  <TableRow key={c.center_id} className={!c.writable ? 'bg-destructive/5' : undefined}>
                    <TableCell className="font-medium">
                      {c.name}
                      {!c.writable ? (
                        <span className="ml-2 text-xs text-destructive">{t('admin', 'readonlyBadge')}</span>
                      ) : null}
                      {c.open_claims > 0 ? (
                        <span className="ml-2 text-xs text-muted-foreground">{t('admin', 'openClaimsBadge')}</span>
                      ) : null}
                    </TableCell>
                    <TableCell>{c.plan_name}</TableCell>
                    <TableCell className={cn('whitespace-nowrap', c.no_date || (c.days_left !== null && c.days_left <= 3) ? 'text-destructive' : '')}>
                      {c.until_text ?? '—'} · {daysText(c.days_left)}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {c.teachers} / {c.students}
                    </TableCell>
                    <TableCell className="text-xs">{c.owner_email ?? '—'}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t('admin', 'createTitle')}</CardTitle>
          <CardDescription>{t('admin', 'createSubtitle')}</CardDescription>
        </CardHeader>
        <CardContent>
          <CreateCenterForm />
        </CardContent>
      </Card>

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>{t('admin', 'revenueTitle')}</CardTitle>
            <CardDescription>{t('admin', 'revenueSubtitle')}</CardDescription>
          </CardHeader>
          <CardContent>
            {!summary || summary.revenue.length === 0 ? (
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
                  {summary.revenue.map((row) => (
                    <TableRow key={row.month}>
                      <TableCell>{row.month}</TableCell>
                      <TableCell className="text-right tabular-nums">{row.count}</TableCell>
                      <TableCell className="text-right tabular-nums">{formatSom(row.total_tiyin)}</TableCell>
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
                  {(confirmed ?? []).map((p) => (
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
