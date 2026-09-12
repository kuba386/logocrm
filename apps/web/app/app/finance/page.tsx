import Link from 'next/link'
import { redirect } from 'next/navigation'
import { formatSom, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { centerTimeZone, dayInZone, formatInTimeZone, isoDayInZone, startOfDayInZone } from '@/lib/timezone'
import { canPayments, isFinance } from '@/lib/roles'
import { label, t } from '@/lib/messages'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { cn } from '@/lib/utils'
import { ClosePeriodForm, ExpenseForm, PayInstallmentForm, PaymentForm, ReopenPeriodForm } from './finance-forms'

export const metadata = { title: 'Финансы — LogoCRM' }

type Tab = 'payments' | 'expenses' | 'installments' | 'periods'

/** «2026-09» → первое число и первое число следующего месяца. */
function monthBounds(month: string): { first: string; next: string } {
  const [y, m] = month.split('-').map(Number)
  const nextY = m === 12 ? y! + 1 : y!
  const nextM = m === 12 ? 1 : m! + 1
  return { first: `${month}-01`, next: `${nextY}-${String(nextM).padStart(2, '0')}-01` }
}

function shiftMonth(month: string, delta: number): string {
  const [y, m] = month.split('-').map(Number)
  const total = y! * 12 + (m! - 1) + delta
  return `${Math.floor(total / 12)}-${String((total % 12) + 1).padStart(2, '0')}`
}

/** «сентябрь 2026 г.» — полдень UTC, чтобы пояс не сдвинул месяц. */
function monthLabel(first: string): string {
  const raw = new Intl.DateTimeFormat('ru-RU', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(
    new Date(`${first}T12:00:00Z`),
  )
  // «сентябрь 2026 г.» → «Сентябрь 2026 г.»: CSS capitalize сделал бы и «Г.».
  return raw.charAt(0).toUpperCase() + raw.slice(1)
}

function calendarDate(day: string, timeZone: string): string {
  return formatInTimeZone(`${day}T12:00:00Z`, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' })
}

export default async function FinancePage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; month?: string }>
}) {
  const params = await searchParams
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (!canPayments(role)) redirect('/app')
  const finance = isFinance(role)
  const isOwner = role === 'owner'

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? ''
  const { data: center } = await supabase.from('centers').select('settings').eq('id', centerId).maybeSingle()
  const timeZone = centerTimeZone(center?.settings)
  const today = isoDayInZone(new Date(), timeZone)

  // Регистратору — только платежи и рассрочки (матрица прав); остальное
  // редиректом на первую вкладку, отказ по данным и так придёт из базы.
  const requested = params.tab as Tab | undefined
  const tab: Tab =
    requested === 'expenses' || requested === 'periods'
      ? finance
        ? requested
        : 'payments'
      : requested === 'installments'
        ? 'installments'
        : 'payments'

  const month = /^\d{4}-\d{2}$/.test(params.month ?? '') ? params.month! : today.slice(0, 7)
  const { first, next } = monthBounds(month)
  const fromIso = startOfDayInZone(first, timeZone)
  const toIso = startOfDayInZone(next, timeZone)

  const [{ data: sourceRows }, { data: cashRows }] = await Promise.all([
    supabase.from('payment_sources').select('id, name').eq('is_active', true).is('deleted_at', null).order('sort'),
    supabase.from('cash_by_source').select('*').eq('month', first),
  ])
  const sources = (sourceRows ?? []).map((s) => ({ id: s.id, name: s.name }))
  const sourceName = new Map(sources.map((s) => [s.id, s.name]))
  const cash = cashRows ?? []
  const sum = (pick: (r: (typeof cash)[number]) => number | null) => cash.reduce((acc, r) => acc + (pick(r) ?? 0), 0)

  const tabs: { key: Tab; title: string }[] = [
    { key: 'payments', title: t('finance', 'tabPayments') },
    ...(finance ? [{ key: 'expenses' as const, title: t('finance', 'tabExpenses') }] : []),
    { key: 'installments', title: t('finance', 'tabInstallments') },
    ...(finance ? [{ key: 'periods' as const, title: t('finance', 'tabPeriods') }] : []),
  ]

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('finance', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('finance', 'subtitle')}</p>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <nav className="flex gap-2 border-b border-border">
          {tabs.map((item) => (
            <Link
              key={item.key}
              href={`/app/finance?tab=${item.key}&month=${month}`}
              className={cn(
                'border-b-2 px-1 pb-2 text-sm font-medium',
                tab === item.key ? 'border-primary text-foreground' : 'border-transparent text-muted-foreground',
              )}
            >
              {item.title}
            </Link>
          ))}
        </nav>
        {tab !== 'installments' ? (
          <div className="flex items-center gap-2 text-sm">
            <Link href={`/app/finance?tab=${tab}&month=${shiftMonth(month, -1)}`} className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
              {t('finance', 'prevMonth')}
            </Link>
            <span className="font-medium">{monthLabel(first)}</span>
            <Link href={`/app/finance?tab=${tab}&month=${shiftMonth(month, 1)}`} className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
              {t('finance', 'nextMonth')}
            </Link>
          </div>
        ) : null}
      </div>

      {tab === 'payments' ? (
        <PaymentsTab
          supabase={supabase}
          fromIso={fromIso}
          toIso={toIso}
          timeZone={timeZone}
          today={today}
          sources={sources}
          sourceName={sourceName}
          totals={{
            received: sum((r) => r.received_tiyin),
            refunded: sum((r) => r.refunded_tiyin),
            corrections: sum((r) => r.corrections_tiyin),
            total: sum((r) => r.total_tiyin),
          }}
          bySource={cash.map((r) => ({
            name: r.source_id ? (sourceName.get(r.source_id) ?? '—') : t('finance', 'noSource'),
            total: r.total_tiyin ?? 0,
          }))}
        />
      ) : null}
      {tab === 'expenses' ? (
        <ExpensesTab
          supabase={supabase}
          fromIso={fromIso}
          toIso={toIso}
          timeZone={timeZone}
          today={today}
          sources={sources}
          sourceName={sourceName}
          spent={sum((r) => r.spent_tiyin)}
        />
      ) : null}
      {tab === 'installments' ? <InstallmentsTab supabase={supabase} timeZone={timeZone} sources={sources} /> : null}
      {tab === 'periods' ? <PeriodsTab supabase={supabase} timeZone={timeZone} today={today} isOwner={isOwner} /> : null}
    </div>
  )
}

type Supabase = Awaited<ReturnType<typeof createClient>>

async function PaymentsTab({
  supabase,
  fromIso,
  toIso,
  timeZone,
  today,
  sources,
  sourceName,
  totals,
  bySource,
}: {
  supabase: Supabase
  fromIso: string
  toIso: string
  timeZone: string
  today: string
  sources: { id: string; name: string }[]
  sourceName: Map<string, string>
  totals: { received: number; refunded: number; corrections: number; total: number }
  bySource: { name: string; total: number }[]
}) {
  const [{ data: payments }, { data: payers }, { data: students }] = await Promise.all([
    supabase
      .from('payments')
      .select('id, payer_id, student_id, subscription_id, amount_tiyin, source_id, paid_at, kind, comment')
      .gte('paid_at', fromIso)
      .lt('paid_at', toIso)
      .order('paid_at', { ascending: false })
      .limit(200),
    supabase.from('payers').select('id, full_name').is('deleted_at', null).order('full_name'),
    supabase.from('students').select('id, full_name').is('deleted_at', null).neq('status', 'archived').order('full_name'),
  ])
  const payerName = new Map((payers ?? []).map((p) => [p.id, p.full_name]))
  const studentName = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const rows = payments ?? []

  return (
    <div className="space-y-4">
      <dl className="grid grid-cols-2 gap-3 rounded-md border border-border bg-muted/50 p-3 text-sm sm:grid-cols-4">
        <div>
          <dt className="text-xs text-muted-foreground">{t('finance', 'received')}</dt>
          <dd className="font-medium">{formatSom(totals.received)}</dd>
        </div>
        <div>
          <dt className="text-xs text-muted-foreground">{t('finance', 'refunded')}</dt>
          <dd className="font-medium">{formatSom(totals.refunded)}</dd>
        </div>
        <div>
          <dt className="text-xs text-muted-foreground">{t('finance', 'corrections')}</dt>
          <dd className="font-medium">{formatSom(totals.corrections)}</dd>
        </div>
        <div>
          <dt className="text-xs text-muted-foreground">{t('finance', 'total')}</dt>
          <dd className="font-medium">{formatSom(totals.total)}</dd>
        </div>
      </dl>
      {bySource.length ? (
        <p className="text-sm text-muted-foreground">
          {t('finance', 'bySource')}: {bySource.map((s) => `${s.name} ${formatSom(s.total)}`).join(' · ')}
        </p>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>{t('finance', 'tabPayments')}</CardTitle>
          <CardDescription>Всего: {rows.length}</CardDescription>
        </CardHeader>
        <CardContent>
          {rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('finance', 'paymentsEmpty')}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('finance', 'colDate')}</TableHead>
                  <TableHead>{t('finance', 'colPayer')}</TableHead>
                  <TableHead>{t('finance', 'colStudent')}</TableHead>
                  <TableHead>{t('finance', 'colKind')}</TableHead>
                  <TableHead>{t('finance', 'colSource')}</TableHead>
                  <TableHead className="text-right">{t('finance', 'colAmount')}</TableHead>
                  <TableHead>{t('finance', 'colComment')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((p) => (
                  <TableRow key={p.id}>
                    <TableCell className="whitespace-nowrap">{dayInZone(p.paid_at, timeZone)}</TableCell>
                    <TableCell>{payerName.get(p.payer_id) ?? '—'}</TableCell>
                    <TableCell>
                      {p.student_id ? (
                        <Link href={`/app/students/${p.student_id}`} className="hover:underline">
                          {studentName.get(p.student_id) ?? '—'}
                        </Link>
                      ) : (
                        '—'
                      )}
                    </TableCell>
                    <TableCell>{label('paymentKind', p.kind)}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {p.source_id ? (sourceName.get(p.source_id) ?? '—') : t('finance', 'noSource')}
                    </TableCell>
                    <TableCell className={cn('text-right font-medium', p.amount_tiyin < 0 && 'text-destructive')}>
                      {formatSom(p.amount_tiyin)}
                    </TableCell>
                    <TableCell className="max-w-[16rem] truncate text-muted-foreground">{p.comment ?? ''}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <PaymentForm
        payers={(payers ?? []).map((p) => ({ id: p.id, name: p.full_name }))}
        students={(students ?? []).map((s) => ({ id: s.id, name: s.full_name }))}
        sources={sources}
        today={today}
      />
    </div>
  )
}

async function ExpensesTab({
  supabase,
  fromIso,
  toIso,
  timeZone,
  today,
  sources,
  sourceName,
  spent,
}: {
  supabase: Supabase
  fromIso: string
  toIso: string
  timeZone: string
  today: string
  sources: { id: string; name: string }[]
  sourceName: Map<string, string>
  spent: number
}) {
  const [{ data: expenses }, { data: categories }] = await Promise.all([
    supabase
      .from('expenses')
      .select('id, category_id, source_id, amount_tiyin, paid_at, kind, comment')
      .gte('paid_at', fromIso)
      .lt('paid_at', toIso)
      .order('paid_at', { ascending: false })
      .limit(200),
    supabase.from('expense_categories').select('id, name').eq('is_active', true).is('deleted_at', null).order('sort'),
  ])
  const categoryName = new Map((categories ?? []).map((c) => [c.id, c.name]))
  const rows = expenses ?? []

  return (
    <div className="space-y-4">
      <p className="text-sm">
        {t('finance', 'spent')}: <strong>{formatSom(Math.abs(spent))}</strong>
      </p>
      <Card>
        <CardHeader>
          <CardTitle>{t('finance', 'tabExpenses')}</CardTitle>
          <CardDescription>Всего: {rows.length}</CardDescription>
        </CardHeader>
        <CardContent>
          {rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('finance', 'expensesEmpty')}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('finance', 'colDate')}</TableHead>
                  <TableHead>{t('finance', 'colCategory')}</TableHead>
                  <TableHead>{t('finance', 'colKind')}</TableHead>
                  <TableHead>{t('finance', 'colSource')}</TableHead>
                  <TableHead className="text-right">{t('finance', 'colAmount')}</TableHead>
                  <TableHead>{t('finance', 'colComment')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((e) => (
                  <TableRow key={e.id}>
                    <TableCell className="whitespace-nowrap">{dayInZone(e.paid_at, timeZone)}</TableCell>
                    <TableCell>{categoryName.get(e.category_id) ?? '—'}</TableCell>
                    <TableCell>{label('expenseKind', e.kind)}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {e.source_id ? (sourceName.get(e.source_id) ?? '—') : t('finance', 'noSource')}
                    </TableCell>
                    <TableCell className="text-right font-medium">{formatSom(e.amount_tiyin)}</TableCell>
                    <TableCell className="max-w-[16rem] truncate text-muted-foreground">{e.comment ?? ''}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
      <ExpenseForm categories={(categories ?? []).map((c) => ({ id: c.id, name: c.name }))} sources={sources} today={today} />
    </div>
  )
}

async function InstallmentsTab({
  supabase,
  timeZone,
  sources,
}: {
  supabase: Supabase
  timeZone: string
  sources: { id: string; name: string }[]
}) {
  const { data: rows } = await supabase
    .from('installments_view')
    .select('id, subscription_id, student_id, payer_id, seq, due_date, amount_tiyin, state, cancelled_at')
    .is('cancelled_at', null)
    .neq('state', 'paid')
    .order('due_date')
    .limit(200)
  const live = (rows ?? []).filter((r) => r.id && r.due_date && r.amount_tiyin != null)
  const studentIds = [...new Set(live.map((r) => r.student_id).filter((v): v is string => Boolean(v)))]
  const payerIds = [...new Set(live.map((r) => r.payer_id).filter((v): v is string => Boolean(v)))]
  const [{ data: students }, { data: payers }] = await Promise.all([
    studentIds.length
      ? supabase.from('students').select('id, full_name').in('id', studentIds)
      : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
    payerIds.length
      ? supabase.from('payers').select('id, full_name, phone').in('id', payerIds)
      : Promise.resolve({ data: [] as { id: string; full_name: string; phone: string | null }[] }),
  ])
  const studentName = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const payerById = new Map((payers ?? []).map((p) => [p.id, p]))

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('finance', 'tabInstallments')}</CardTitle>
        <CardDescription>Всего: {live.length}</CardDescription>
      </CardHeader>
      <CardContent>
        {live.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t('finance', 'installmentsEmpty')}</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t('finance', 'colDue')}</TableHead>
                <TableHead>{t('finance', 'colStudent')}</TableHead>
                <TableHead>{t('finance', 'colPayer')}</TableHead>
                <TableHead>{t('finance', 'colSeq')}</TableHead>
                <TableHead>{t('finance', 'colState')}</TableHead>
                <TableHead className="text-right">{t('finance', 'colAmount')}</TableHead>
                <TableHead className="text-right"> </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {live.map((r) => {
                const payer = r.payer_id ? payerById.get(r.payer_id) : undefined
                const wa = payer?.phone ? whatsappNumber(payer.phone) : null
                const student = r.student_id ? (studentName.get(r.student_id) ?? '—') : '—'
                const due = calendarDate(r.due_date as string, timeZone)
                const message = t('finance', 'whatsappReminder', {
                  student,
                  amount: formatSom(r.amount_tiyin as number),
                  due,
                })
                return (
                  <TableRow key={r.id as string} className={cn(r.state === 'overdue' && 'bg-destructive/5')}>
                    <TableCell className={cn('whitespace-nowrap', r.state === 'overdue' && 'font-medium text-destructive')}>
                      {due}
                    </TableCell>
                    <TableCell>
                      {r.student_id ? (
                        <Link href={`/app/students/${r.student_id}`} className="hover:underline">
                          {student}
                        </Link>
                      ) : (
                        student
                      )}
                    </TableCell>
                    <TableCell>{payer?.full_name ?? '—'}</TableCell>
                    <TableCell>{r.seq}</TableCell>
                    <TableCell className={cn(r.state === 'overdue' && 'text-destructive')}>
                      {label('installmentState', r.state ?? '')}
                    </TableCell>
                    <TableCell className="text-right font-medium">{formatSom(r.amount_tiyin as number)}</TableCell>
                    <TableCell>
                      <div className="flex flex-wrap items-center justify-end gap-2">
                        {wa ? (
                          <a
                            href={`https://wa.me/${wa}?text=${encodeURIComponent(message)}`}
                            target="_blank"
                            rel="noreferrer"
                            className={buttonVariants({ variant: 'outline', size: 'sm' })}
                          >
                            {t('finance', 'whatsapp')}
                          </a>
                        ) : null}
                        <PayInstallmentForm installmentId={r.id as string} amountTiyin={r.amount_tiyin as number} sources={sources} />
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
  )
}

async function PeriodsTab({
  supabase,
  timeZone,
  today,
  isOwner,
}: {
  supabase: Supabase
  timeZone: string
  today: string
  isOwner: boolean
}) {
  const currentMonth = today.slice(0, 7)
  const previous = shiftMonth(currentMonth, -1)
  const { first: prevFirst, next: prevNext } = monthBounds(previous)

  const [{ data: periods }, { count: plannedCount }] = await Promise.all([
    supabase.from('financial_periods').select('month, closed_at').order('month', { ascending: false }).limit(12),
    supabase
      .from('lessons')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'planned')
      .is('deleted_at', null)
      .gte('starts_at', startOfDayInZone(prevFirst, timeZone))
      .lt('starts_at', startOfDayInZone(prevNext, timeZone)),
  ])
  const rows = periods ?? []
  const previousClosed = rows.some((p) => p.month === prevFirst && p.closed_at)

  return (
    <div className="space-y-4">
      <Card>
        <CardHeader>
          <CardTitle>{t('finance', 'tabPeriods')}</CardTitle>
          <CardDescription>Замок месяца: платежи, расходы, отметки и ставки задним числом в закрытый месяц не проходят.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {!previousClosed ? (
            <ClosePeriodForm month={prevFirst} monthLabel={monthLabel(prevFirst)} plannedCount={plannedCount ?? 0} />
          ) : null}
          {rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('finance', 'periodsEmpty')}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Месяц</TableHead>
                  <TableHead>{t('finance', 'colState')}</TableHead>
                  <TableHead className="text-right"> </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((p) => (
                  <TableRow key={p.month}>
                    <TableCell>{monthLabel(p.month)}</TableCell>
                    <TableCell>
                      {p.closed_at
                        ? t('finance', 'periodClosed', { at: dayInZone(p.closed_at, timeZone) })
                        : t('finance', 'periodOpen')}
                    </TableCell>
                    <TableCell>
                      <div className="flex justify-end">
                        {p.closed_at ? (
                          isOwner ? (
                            <ReopenPeriodForm month={p.month} />
                          ) : (
                            <span className="text-xs text-muted-foreground">{t('finance', 'ownerOnly')}</span>
                          )
                        ) : null}
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
