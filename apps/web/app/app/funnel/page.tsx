import Link from 'next/link'
import { redirect } from 'next/navigation'
import { whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { t } from '@/lib/messages'
import { funnelStageLabel, FUNNEL_STAGE_CLASSES, type FunnelStage } from '@/lib/students'
import { cn } from '@/lib/utils'

export const metadata = { title: 'Воронка — LogoCRM' }

type Summary = {
  current: { stage: FunnelStage; name: string; count: number }[]
  transitions: { from_stage: FunnelStage | null; to_stage: FunnelStage; count: number }[]
  conversion: { entered: number; converted: number }
  avg_days_on_stage: { stage: FunnelStage; avg_days: number }[]
  sources: { source: string; count: number }[]
}

function parseSummary(json: unknown): Summary | null {
  if (!json || typeof json !== 'object') return null
  const o = json as Record<string, unknown>
  const arr = (v: unknown) => (Array.isArray(v) ? (v as Record<string, unknown>[]) : [])
  const conv = (o.conversion ?? {}) as Record<string, unknown>
  return {
    current: arr(o.current).map((x) => ({
      stage: String(x.stage) as FunnelStage,
      name: String(x.name ?? x.stage),
      count: Number(x.count ?? 0),
    })),
    transitions: arr(o.transitions).map((x) => ({
      from_stage: x.from_stage == null ? null : (String(x.from_stage) as FunnelStage),
      to_stage: String(x.to_stage) as FunnelStage,
      count: Number(x.count ?? 0),
    })),
    conversion: { entered: Number(conv.entered ?? 0), converted: Number(conv.converted ?? 0) },
    avg_days_on_stage: arr(o.avg_days_on_stage).map((x) => ({
      stage: String(x.stage) as FunnelStage,
      avg_days: Number(x.avg_days ?? 0),
    })),
    sources: arr(o.sources).map((x) => ({ source: String(x.source ?? '—'), count: Number(x.count ?? 0) })),
  }
}

/** «2026-09-24» ± N дней от указанной даты — чистая работа со строкой, без часового пояса браузера. */
function isoDateFrom(base: string, offsetDays: number): string {
  const d = new Date(`${base}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() + offsetDays)
  return d.toISOString().slice(0, 10)
}

function daysBetween(from: string, to: string): number {
  return Math.round(
    (new Date(`${to}T00:00:00Z`).getTime() - new Date(`${from}T00:00:00Z`).getTime()) / 86400000,
  )
}

const STUCK_DAYS = 14

/**
 * Дашборд воронки (0055): всё из funnel_summary()/funnel_stuck() — счёт,
 * права и граница дня в поясе центра держит база, страница только рисует.
 * from/to в query — конец периода назад по 30 дней за раз. «Сегодня» и
 * листание — от center_today(), не от Date() браузера/сервера (CLAUDE.md:
 * время в поясе центра; ревью написанного SQL 23.09.2026, находка 4).
 */
export default async function FunnelPage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>
}) {
  const params = await searchParams
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const { data: today } = await supabase.rpc('center_today', {})
  const todayStr = today ?? new Date().toISOString().slice(0, 10)

  const to = params.to ?? todayStr
  const from = params.from ?? isoDateFrom(to, -30)

  const [{ data: summaryJson, error: summaryError }, { data: stuck, error: stuckError }] = await Promise.all([
    supabase.rpc('funnel_summary', { p_from: from, p_to: to }),
    supabase.rpc('funnel_stuck', { p_days: STUCK_DAYS }),
  ])

  const summary = parseSummary(summaryJson)
  const totalCurrent = summary?.current.reduce((s, x) => s + x.count, 0) ?? 0
  const rate = summary && summary.conversion.entered > 0
    ? Math.round((summary.conversion.converted / summary.conversion.entered) * 100)
    : null

  // Листание — от границ текущего окна, тем же шагом, что и само окно.
  const spanDays = Math.max(1, daysBetween(from, to))
  const nextFrom = isoDateFrom(to, 1)
  const nextTo = isoDateFrom(nextFrom, spanDays)
  const backTo = isoDateFrom(from, -1)
  const backFrom = isoDateFrom(backTo, -spanDays)

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('funnel', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('funnel', 'subtitle')}</p>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2 text-sm text-muted-foreground">
        <span>
          {t('funnel', 'period')}: {from} — {to}
        </span>
        <div className="flex gap-2">
          <Link href={`/app/funnel?from=${backFrom}&to=${backTo}`} className="hover:underline">
            {t('funnel', 'prevPeriod')}
          </Link>
          <Link href={`/app/funnel?from=${nextFrom}&to=${nextTo}`} className="hover:underline">
            {t('funnel', 'nextPeriod')}
          </Link>
        </div>
      </div>

      {summaryError || !summary ? (
        <p role="alert" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
          Не удалось загрузить сводку
        </p>
      ) : (
        <>
          <Card>
            <CardHeader>
              <CardTitle>{t('funnel', 'currentTitle')}</CardTitle>
              <CardDescription>{t('funnel', 'currentSubtitle')}</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-4 lg:grid-cols-7">
                {summary.current.map((x) => (
                  <div key={x.stage} className="rounded-md border border-border p-3 text-center">
                    <p
                      className={cn(
                        'mx-auto mb-1 w-fit rounded-full px-2 py-0.5 text-xs',
                        FUNNEL_STAGE_CLASSES[x.stage] ?? 'bg-muted text-muted-foreground',
                      )}
                    >
                      {x.name}
                    </p>
                    <p className="text-xl font-semibold tabular-nums">{x.count}</p>
                  </div>
                ))}
              </div>
              {totalCurrent === 0 ? (
                <p className="mt-3 text-sm text-muted-foreground">Учеников в воронке пока нет.</p>
              ) : null}
            </CardContent>
          </Card>

          <div className="grid gap-4 md:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle>{t('funnel', 'conversionTitle')}</CardTitle>
                <CardDescription>{t('funnel', 'conversionSubtitle')}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-1">
                <p className="text-sm text-muted-foreground">
                  {t('funnel', 'entered')}: <span className="font-medium text-foreground">{summary.conversion.entered}</span>
                </p>
                <p className="text-sm text-muted-foreground">
                  {t('funnel', 'converted')}: <span className="font-medium text-foreground">{summary.conversion.converted}</span>
                </p>
                {rate !== null ? (
                  <p className="text-2xl font-semibold tabular-nums">{rate}%</p>
                ) : (
                  <p className="text-sm text-muted-foreground">Нет вошедших за период.</p>
                )}
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>{t('funnel', 'sourcesTitle')}</CardTitle>
              </CardHeader>
              <CardContent>
                {summary.sources.length === 0 ? (
                  <p className="text-sm text-muted-foreground">{t('funnel', 'sourcesEmpty')}</p>
                ) : (
                  <ul className="space-y-1 text-sm">
                    {summary.sources.map((s) => (
                      <li key={s.source} className="flex items-center justify-between">
                        <span className="text-muted-foreground">{s.source}</span>
                        <span className="font-medium tabular-nums">{s.count}</span>
                      </li>
                    ))}
                  </ul>
                )}
              </CardContent>
            </Card>
          </div>

          <Card>
            <CardHeader>
              <CardTitle>{t('funnel', 'transitionsTitle')}</CardTitle>
              <CardDescription>{t('funnel', 'transitionsSubtitle')}</CardDescription>
            </CardHeader>
            <CardContent>
              {summary.transitions.length === 0 ? (
                <p className="text-sm text-muted-foreground">{t('funnel', 'transitionsEmpty')}</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t('funnel', 'colFrom')}</TableHead>
                      <TableHead>{t('funnel', 'colTo')}</TableHead>
                      <TableHead className="text-right">{t('funnel', 'colCount')}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {summary.transitions.map((tr, i) => (
                      <TableRow key={i}>
                        <TableCell>{tr.from_stage ? funnelStageLabel(tr.from_stage) : t('funnel', 'fromNew')}</TableCell>
                        <TableCell>{funnelStageLabel(tr.to_stage)}</TableCell>
                        <TableCell className="text-right tabular-nums">{tr.count}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>{t('funnel', 'avgTitle')}</CardTitle>
              <CardDescription>{t('funnel', 'avgSubtitle')}</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                {summary.avg_days_on_stage.map((x) => (
                  <div key={x.stage} className="rounded-md border border-border p-3">
                    <p className="text-xs text-muted-foreground">{funnelStageLabel(x.stage)}</p>
                    <p className="text-lg font-semibold tabular-nums">{t('funnel', 'avgDays', { days: x.avg_days })}</p>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        </>
      )}

      <Card>
        <CardHeader>
          <CardTitle>{t('funnel', 'stuckTitle')}</CardTitle>
          <CardDescription>{t('funnel', 'stuckSubtitle', { days: STUCK_DAYS })}</CardDescription>
        </CardHeader>
        <CardContent>
          {stuckError ? (
            <p role="alert" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
              Не удалось загрузить список
            </p>
          ) : (stuck ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('funnel', 'stuckEmpty')}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('funnel', 'colStudent')}</TableHead>
                  <TableHead>{t('funnel', 'colStage')}</TableHead>
                  <TableHead className="text-right">{t('funnel', 'colDays')}</TableHead>
                  <TableHead className="text-right"> </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(stuck ?? []).map((row) => {
                  const wa = row.payer_phone ? whatsappNumber(row.payer_phone) : null
                  return (
                    <TableRow key={row.student_id}>
                      <TableCell>
                        <Link href={`/app/students/${row.student_id}`} className="hover:underline">
                          {row.full_name}
                        </Link>
                      </TableCell>
                      <TableCell>
                        <span
                          className={cn(
                            'rounded-full px-2 py-0.5 text-xs',
                            FUNNEL_STAGE_CLASSES[row.stage as FunnelStage] ?? 'bg-muted text-muted-foreground',
                          )}
                        >
                          {row.stage_name}
                        </span>
                      </TableCell>
                      <TableCell className="text-right tabular-nums">
                        {t('funnel', 'daysCount', { days: row.days_on_stage })}
                      </TableCell>
                      <TableCell className="text-right">
                        {wa ? (
                          <a
                            href={`https://wa.me/${wa}`}
                            target="_blank"
                            rel="noreferrer"
                            className="text-sm text-primary hover:underline"
                          >
                            {t('funnel', 'whatsapp')}
                          </a>
                        ) : null}
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
