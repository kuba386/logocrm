import { redirect } from 'next/navigation'
import { formatSom } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { label, t } from '@/lib/messages'
import { parseCenterLimits } from '@/lib/plan'
import { centerTimeZone, formatInTimeZone } from '@/lib/timezone'
import { cn } from '@/lib/utils'
import { PaymentForm, WithdrawForm } from './payment-form'

export const metadata = { title: 'Тариф и оплата — LogoCRM' }

function limitText(used: number, limit: number): string {
  return limit < 0 ? t('plan', 'usageUnlimited', { used }) : t('plan', 'usage', { used, limit })
}

function LimitRow({ title, used, limit }: { title: string; used: number; limit: number }) {
  const percent = limit > 0 ? Math.min(100, Math.round((used / limit) * 100)) : 0
  const full = limit > 0 && used >= limit
  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between text-sm">
        <span>{title}</span>
        <span className={cn('tabular-nums', full ? 'font-medium text-destructive' : 'text-muted-foreground')}>
          {limitText(used, limit)}
        </span>
      </div>
      {limit > 0 ? (
        <div className="h-2 w-full overflow-hidden rounded-full bg-muted">
          <div
            className={cn('h-full rounded-full', full ? 'bg-destructive' : 'bg-primary')}
            style={{ width: `${percent}%` }}
          />
        </div>
      ) : null}
    </div>
  )
}

/**
 * Экран тарифа: всё из center_limits() (тариф, лимиты, дни до конца,
 * writable — в поясе центра), справочник plans и история заявок. Права,
 * сумма заявки и режим только чтения считаются базой, экран рисует.
 */
export default async function PlanPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? null

  const [{ data: limitsJson, error: limitsError }, { data: plans }, { data: center }, { data: payments }] =
    await Promise.all([
      supabase.rpc('center_limits'),
      supabase.from('plans').select('code, name, price_tiyin, limits, sort').eq('is_public', true).order('sort'),
      supabase.from('centers').select('settings').eq('id', centerId ?? '').maybeSingle(),
      supabase
        .from('platform_payments')
        .select(
          'id, claimed_plan, claimed_months, claimed_amount_tiyin, source, note, created_at, withdrawn_at, rejected_at, reject_reason, confirmed_at, plan, months, amount_tiyin',
        )
        .order('created_at', { ascending: false })
        .limit(20),
    ])

  const limits = parseCenterLimits(limitsJson)
  const timeZone = centerTimeZone(center?.settings)
  const date = (iso: string) => formatInTimeZone(iso, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' })

  const planRows = (plans ?? []).map((p) => {
    const l = (p.limits ?? {}) as Record<string, unknown>
    const n = (v: unknown) => (typeof v === 'number' ? v : -1)
    return {
      code: p.code,
      name: p.name,
      priceTiyin: p.price_tiyin,
      teachers: n(l.teachers),
      students: n(l.students),
      aiNotes: n(l.ai_notes_month),
    }
  })
  const paidPlans = planRows.filter((p) => p.code !== 'trial')

  const openClaim = (payments ?? []).find((p) => !p.confirmed_at && !p.rejected_at && !p.withdrawn_at) ?? null

  const paymentStatus = (p: NonNullable<typeof payments>[number]): string => {
    if (p.confirmed_at) return t('plan', 'statusConfirmed', { date: date(p.confirmed_at) })
    if (p.rejected_at) return t('plan', 'statusRejected', { reason: p.reject_reason ?? '' })
    if (p.withdrawn_at) return t('plan', 'statusWithdrawn')
    return t('plan', 'statusOpen')
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('plan', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('plan', 'subtitle')}</p>
      </div>

      {limitsError || !limits ? (
        <p role="alert" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
          {t('plan', 'loadFailed')}
        </p>
      ) : (
        <>
          <div className="grid gap-4 md:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle>{t('plan', 'currentTitle')}</CardTitle>
                <CardDescription>
                  {limits.isTrial ? t('plan', 'trialLabel') : t('plan', 'paidLabel', { price: formatSom(limits.priceTiyin) })}
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-2">
                <p className="text-xl font-semibold">{limits.planName}</p>
                <p className="text-sm text-muted-foreground">
                  {limits.until
                    ? limits.isTrial
                      ? t('plan', 'trialUntil', { date: date(limits.until) })
                      : t('plan', 'paidUntil', { date: date(limits.until) })
                    : t('plan', 'noDate')}
                </p>
                {!limits.writable ? (
                  <p role="alert" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
                    {t('plan', 'readonlyNotice')}
                  </p>
                ) : limits.daysLeft !== null && limits.daysLeft <= 3 ? (
                  <p role="status" className="rounded-md bg-accent px-3 py-2 text-sm text-accent-foreground">
                    {t('plan', 'endingSoon', { days: limits.daysLeft })}
                  </p>
                ) : null}
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>{t('plan', 'limitsTitle')}</CardTitle>
                <CardDescription>{t('plan', 'limitsSubtitle')}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-3">
                <LimitRow title={t('plan', 'teachers')} used={limits.usage.teachers} limit={limits.limits.teachers} />
                <LimitRow title={t('plan', 'students')} used={limits.usage.students} limit={limits.limits.students} />
                <LimitRow
                  title={t('plan', 'aiNotes')}
                  used={limits.usage.aiNotesMonth}
                  limit={limits.limits.aiNotesMonth}
                />
              </CardContent>
            </Card>
          </div>

          <Card>
            <CardHeader>
              <CardTitle>{openClaim ? t('plan', 'openTitle') : t('plan', 'payTitle')}</CardTitle>
              <CardDescription>{openClaim ? t('plan', 'openSubtitle') : t('plan', 'paySubtitle')}</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <p className="rounded-md border border-border bg-muted/40 p-3 text-sm whitespace-pre-line">
                {t('plan', 'requisites')}
              </p>
              {openClaim ? (
                <div className="space-y-3">
                  <dl className="grid gap-1 text-sm sm:grid-cols-2">
                    <dt className="text-muted-foreground">{t('plan', 'openPlan')}</dt>
                    <dd>
                      {label('plan_names', openClaim.claimed_plan)} × {openClaim.claimed_months}{' '}
                      {t('plan', 'monthsShort')}
                    </dd>
                    <dt className="text-muted-foreground">{t('plan', 'openAmount')}</dt>
                    <dd className="font-medium">{formatSom(openClaim.claimed_amount_tiyin)}</dd>
                    <dt className="text-muted-foreground">{t('plan', 'openSource')}</dt>
                    <dd>{label('platformPaymentSource', openClaim.source)}</dd>
                    <dt className="text-muted-foreground">{t('plan', 'openNumber')}</dt>
                    <dd className="font-mono text-xs">{openClaim.id}</dd>
                  </dl>
                  <p className="text-sm text-muted-foreground">{t('plan', 'openHint')}</p>
                  <WithdrawForm paymentId={openClaim.id} />
                </div>
              ) : (
                <PaymentForm
                  plans={paidPlans.map((p) => ({ code: p.code, name: p.name, priceTiyin: p.priceTiyin }))}
                  currentPlan={limits.plan}
                />
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>{t('plan', 'plansTitle')}</CardTitle>
              <CardDescription>{t('plan', 'plansSubtitle')}</CardDescription>
            </CardHeader>
            <CardContent>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{t('plan', 'colPlan')}</TableHead>
                    <TableHead className="text-right">{t('plan', 'colPrice')}</TableHead>
                    <TableHead className="text-right">{t('plan', 'teachers')}</TableHead>
                    <TableHead className="text-right">{t('plan', 'students')}</TableHead>
                    <TableHead className="text-right">{t('plan', 'aiNotes')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {planRows.map((p) => (
                    <TableRow key={p.code} className={p.code === limits.plan ? 'bg-accent/40' : undefined}>
                      <TableCell className="font-medium">
                        {p.name}
                        {p.code === limits.plan ? (
                          <span className="ml-2 text-xs text-muted-foreground">{t('plan', 'currentBadge')}</span>
                        ) : null}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">
                        {p.priceTiyin > 0 ? t('plan', 'perMonth', { price: formatSom(p.priceTiyin) }) : '—'}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">{p.teachers < 0 ? t('plan', 'unlimited') : p.teachers}</TableCell>
                      <TableCell className="text-right tabular-nums">{p.students < 0 ? t('plan', 'unlimited') : p.students}</TableCell>
                      <TableCell className="text-right tabular-nums">{p.aiNotes < 0 ? t('plan', 'unlimited') : p.aiNotes}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>{t('plan', 'historyTitle')}</CardTitle>
              <CardDescription>{t('plan', 'historySubtitle')}</CardDescription>
            </CardHeader>
            <CardContent>
              {(payments ?? []).length === 0 ? (
                <p className="text-sm text-muted-foreground">{t('plan', 'historyEmpty')}</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t('plan', 'colDate')}</TableHead>
                      <TableHead>{t('plan', 'colClaim')}</TableHead>
                      <TableHead className="text-right">{t('plan', 'colAmount')}</TableHead>
                      <TableHead>{t('plan', 'colStatus')}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {(payments ?? []).map((p) => (
                      <TableRow key={p.id}>
                        <TableCell className="whitespace-nowrap">{date(p.created_at)}</TableCell>
                        <TableCell>
                          {label('plan_names', p.claimed_plan)} × {p.claimed_months} {t('plan', 'monthsShort')}
                          {p.confirmed_at && p.plan && (p.plan !== p.claimed_plan || p.months !== p.claimed_months) ? (
                            <span className="block text-xs text-muted-foreground">
                              {t('plan', 'confirmedAs', {
                                plan: label('plan_names', p.plan),
                                months: p.months ?? 0,
                              })}
                            </span>
                          ) : null}
                        </TableCell>
                        <TableCell className="text-right tabular-nums">
                          {formatSom(p.confirmed_at && p.amount_tiyin !== null ? p.amount_tiyin : p.claimed_amount_tiyin)}
                        </TableCell>
                        <TableCell>{paymentStatus(p)}</TableCell>
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
