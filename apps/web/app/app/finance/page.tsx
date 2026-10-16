import Link from 'next/link'
import { redirect } from 'next/navigation'
import { ReceiptText } from 'lucide-react'
import { formatSom, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { monthBounds, shiftMonth } from '@/lib/month'
import { centerTimeZone, dayInZone, formatInTimeZone, isoDayInZone, startOfDayInZone } from '@/lib/timezone'
import { canPayments, isFinance } from '@/lib/roles'
import { label, t } from '@/lib/messages'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { PeriodNav } from '@/components/ui/period-nav'
import { PageHeader } from '@/components/ui/page-header'
import { PageNoticeProvider } from '@/components/ui/page-notice'
import { monthLabel } from '@/lib/timezone'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { cn } from '@/lib/utils'
import { loadErrorMessage } from '@/lib/errors'
import { receiptHref } from '@/lib/receipt'
import { FormError } from '@/components/ui/alert'
import {
  ClosePeriodForm,
  ExpenseDialog,
  PayInstallmentForm,
  PaymentDialog,
  ReopenPeriodForm,
  VoidPaymentForm,
  type StudentOption,
} from './finance-forms'

/** Списки ниже обрезаны до LIST_LIMIT строк. «Всего» — настоящее число из базы
 *  (count: 'exact'), а если строк больше, чем показано, — так и пишем: иначе
 *  в 201-й платёж месяца верилось бы как в «Всего: 200». */
const LIST_LIMIT = 200

function shownOfTotal(shown: number, total: number | null, which = 'последние') {
  const all = total ?? shown
  return all > shown ? `Всего: ${all}, показаны ${which} ${shown}` : `Всего: ${all}`
}

export const metadata = { title: 'Финансы — LogoCRM' }

type Tab = 'payments' | 'expenses' | 'installments' | 'periods'
type Kind = 'payment' | 'refund' | 'correction'

const UUID = /^[0-9a-f-]{36}$/

function calendarDate(day: string, timeZone: string): string {
  return formatInTimeZone(`${day}T12:00:00Z`, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' })
}

/** Фильтры списка платежей — из адреса, как у «Долгов»: ссылку можно переслать, назад работает. */
type PaymentFilters = { q: string; source: string; kind: Kind | '' }

function firstParam(value: string | string[] | undefined): string {
  return (Array.isArray(value) ? value[0] : value) ?? ''
}

function pickFilters(params: { q?: string | string[]; source?: string | string[]; kind?: string | string[] }): PaymentFilters {
  const q = firstParam(params.q).trim().slice(0, 60)
  const sourceRaw = firstParam(params.source)
  const kindRaw = firstParam(params.kind)
  const source = sourceRaw === 'none' || UUID.test(sourceRaw) ? sourceRaw : ''
  const kind = kindRaw === 'payment' || kindRaw === 'refund' || kindRaw === 'correction' ? kindRaw : ''
  return { q, source, kind }
}

export default async function FinancePage({
  searchParams,
}: {
  searchParams: Promise<{
    tab?: string
    month?: string
    q?: string | string[]
    source?: string | string[]
    kind?: string | string[]
    category?: string
    day?: string | string[]
  }>
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
  const filters = pickFilters(params)
  // День для «Поступлений за день» — не позже сегодняшнего дня центра.
  const dayRaw = firstParam(params.day)
  const day = /^\d{4}-\d{2}-\d{2}$/.test(dayRaw) && dayRaw <= today ? dayRaw : today
  const categoryFilter = UUID.test(params.category ?? '') ? params.category! : ''

  // Касса — только can_finance (cash_by_source, 0028): регистратору вью отдаёт
  // ноль строк без ошибки, и «Итого в кассе 0 сом» читалось бы как настоящая
  // цифра (аудит финансов 16.10.2026). Ему итоги не запрашиваем и не рисуем.
  const [{ data: sourceRows }, { data: cashRows, error: cashLoadError }, { data: payerRows }, { data: studentRows }, { data: balanceRows }, { data: categoryRows }] =
    await Promise.all([
      supabase.from('payment_sources').select('id, name').eq('is_active', true).is('deleted_at', null).order('sort'),
      finance ? supabase.from('cash_by_source').select('*').eq('month', first) : Promise.resolve({ data: [], error: null }),
      // Имена — из definer-источников без заметок (0031): таблицы students и
      // payers бухгалтеру закрыты, а экран один на все роли.
      supabase.rpc('payers_brief').order('full_name'),
      supabase.rpc('students_brief').order('full_name'),
      // Долг, аванс и просрочка по ребёнку — для подсказок в форме оплаты (считает база).
      supabase.from('student_balance').select('student_id, debt_tiyin, overdrawn_tiyin, lesson_credit_tiyin, subscription_overdue_tiyin'),
      finance
        ? supabase.from('expense_categories').select('id, name').eq('is_active', true).is('deleted_at', null).order('sort')
        : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    ])
  const sources = (sourceRows ?? []).map((s) => ({ id: s.id, name: s.name }))
  const sourceName = new Map(sources.map((s) => [s.id, s.name]))
  const cash = cashRows ?? []
  // Касса не загрузилась — не «0 сом»: нули читались бы как настоящие цифры.
  const cashError = cashLoadError ? loadErrorMessage(cashLoadError, t('finance', 'loadCashFailed')) : null
  const sum = (pick: (r: (typeof cash)[number]) => number | null) => cash.reduce((acc, r) => acc + (pick(r) ?? 0), 0)

  const payers = (payerRows ?? []).map((p) => ({ id: p.id, name: p.full_name }))
  const payerById = new Map((payerRows ?? []).map((p) => [p.id, p]))
  const balanceByStudent = new Map((balanceRows ?? []).map((b) => [b.student_id, b]))
  const students: StudentOption[] = (studentRows ?? [])
    .filter((s) => s.status !== 'archived')
    .map((s) => {
      const b = balanceByStudent.get(s.id)
      return {
        id: s.id,
        name: s.full_name,
        payerId: (s.payer_id as string | null) ?? null,
        lessonDebtTiyin: (b?.debt_tiyin ?? 0) + (b?.overdrawn_tiyin ?? 0),
        creditTiyin: b?.lesson_credit_tiyin ?? 0,
        overdueTiyin: b?.subscription_overdue_tiyin ?? 0,
      }
    })
  const studentName = new Map((studentRows ?? []).map((s) => [s.id, s.full_name]))
  const categories = (categoryRows ?? []).map((c) => ({ id: c.id, name: c.name }))

  const tabs: { key: Tab; title: string }[] = [
    { key: 'payments', title: t('finance', 'tabPayments') },
    ...(finance ? [{ key: 'expenses' as const, title: t('finance', 'tabExpenses') }] : []),
    { key: 'installments', title: t('finance', 'tabInstallments') },
    ...(finance ? [{ key: 'periods' as const, title: t('finance', 'tabPeriods') }] : []),
  ]

  return (
    <div className="space-y-6">
      <PageNoticeProvider>
        <div className="space-y-6">
          <PageHeader
            title={t('finance', 'title')}
            description={
              <>
                {t('finance', 'subtitle')}{' '}
                {/* Выгрузка — только can_finance (0058): регистратор экран видит, файлы не выносит. */}
                {finance ? (
                  <Link href="/app/reports" className="whitespace-nowrap text-primary underline-offset-4 hover:underline">
                    {t('reports', 'title')} →
                  </Link>
                ) : null}
              </>
            }
            actions={
              <>
                <PaymentDialog payers={payers} students={students} sources={sources} today={today} />
                {finance ? <ExpenseDialog categories={categories} sources={sources} today={today} /> : null}
              </>
            }
          />

          <div className="flex flex-wrap items-center justify-between gap-3">
            <nav className="flex gap-2 overflow-x-auto border-b border-border">
              {tabs.map((item) => (
                <Link
                  key={item.key}
                  href={`/app/finance?tab=${item.key}&month=${month}`}
                  aria-current={tab === item.key ? 'page' : undefined}
                  className={cn(
                    'inline-flex min-h-11 shrink-0 items-end border-b-2 px-1 pb-2 text-sm font-medium sm:min-h-0',
                    tab === item.key ? 'border-primary text-foreground' : 'border-transparent text-muted-foreground',
                  )}
                >
                  {item.title}
                </Link>
              ))}
            </nav>
            {tab !== 'installments' ? (
              <PeriodNav
                label={monthLabel(first)}
                prev={`/app/finance?tab=${tab}&month=${shiftMonth(month, -1)}`}
                next={`/app/finance?tab=${tab}&month=${shiftMonth(month, 1)}`}
                today={{ href: `/app/finance?tab=${tab}`, label: 'Этот месяц', current: month === today.slice(0, 7) }}
                prevLabel="Предыдущий месяц"
                nextLabel="Следующий месяц"
              />
            ) : null}
          </div>

          {tab === 'payments' ? (
            <PaymentsTab
              supabase={supabase}
              finance={finance}
              isOwner={isOwner}
              month={month}
              fromIso={fromIso}
              toIso={toIso}
              timeZone={timeZone}
              sources={sources}
              sourceName={sourceName}
              cashError={cashError}
              filters={filters}
              day={day}
              today={today}
              payerName={(id) => payerById.get(id)?.full_name ?? '—'}
              studentName={studentName}
              totals={{
                received: sum((r) => r.received_tiyin),
                refunded: sum((r) => r.refunded_tiyin),
                corrections: sum((r) => r.corrections_tiyin),
                spent: sum((r) => r.spent_tiyin),
                total: sum((r) => r.total_tiyin),
              }}
              bySource={cash.map((r) => ({
                name: r.source_id ? (sourceName.get(r.source_id) ?? '—') : t('finance', 'noSource'),
                total: r.total_tiyin ?? 0,
              }))}
              payers={payerRows ?? []}
              students={studentRows ?? []}
            />
          ) : null}
          {tab === 'expenses' ? (
            <ExpensesTab
              supabase={supabase}
              month={month}
              fromIso={fromIso}
              toIso={toIso}
              timeZone={timeZone}
              categories={categories}
              categoryFilter={categoryFilter}
              sourceName={sourceName}
              cashError={cashError}
              spent={sum((r) => r.spent_tiyin)}
            />
          ) : null}
          {tab === 'installments' ? <InstallmentsTab supabase={supabase} timeZone={timeZone} sources={sources} /> : null}
          {tab === 'periods' ? <PeriodsTab supabase={supabase} timeZone={timeZone} today={today} isOwner={isOwner} /> : null}
        </div>
      </PageNoticeProvider>
    </div>
  )
}

type Supabase = Awaited<ReturnType<typeof createClient>>

async function PaymentsTab({
  supabase,
  day,
  today,
  finance,
  isOwner,
  month,
  fromIso,
  toIso,
  timeZone,
  sources,
  sourceName,
  cashError,
  filters,
  payerName,
  studentName,
  totals,
  bySource,
  payers,
  students,
}: {
  supabase: Supabase
  /** День «Поступлений за день» (ГГГГ-ММ-ДД, не позже сегодня по центру). */
  day: string
  today: string
  /** owner/admin/finance — итоги кассы (cash_by_source); регистратору их нет. */
  finance: boolean
  /** Владелец — «Отменить» у ошибочного поступления (0093); право проверяет база. */
  isOwner: boolean
  month: string
  fromIso: string
  toIso: string
  timeZone: string
  sources: { id: string; name: string }[]
  sourceName: Map<string, string>
  cashError: string | null
  filters: PaymentFilters
  payerName: (id: string) => string
  studentName: Map<string, string>
  totals: { received: number; refunded: number; corrections: number; spent: number; total: number }
  bySource: { name: string; total: number }[]
  payers: { id: string; full_name: string }[]
  students: { id: string; full_name: string }[]
}) {
  // Поиск по имени — через id из уже загруженных списков плательщиков и
  // детей (имена в payments не хранятся). Ничего не совпало — пустой список,
  // а не все платежи месяца.
  const needle = filters.q.toLocaleLowerCase('ru')
  const payerIds = needle ? payers.filter((p) => p.full_name.toLocaleLowerCase('ru').includes(needle)).map((p) => p.id) : []
  const studentIds = needle ? students.filter((s) => s.full_name.toLocaleLowerCase('ru').includes(needle)).map((s) => s.id) : []
  const nameMiss = Boolean(needle) && payerIds.length === 0 && studentIds.length === 0
  // Сотни uuid в адресе запроса упираются в его длину (тот же урок, что на «Долгах»):
  // слишком общий запрос («а») — просим уточнить, а не режем молча.
  const tooBroad = payerIds.length + studentIds.length > 150

  let query = supabase
    .from('payments')
    .select('id, payer_id, student_id, subscription_id, amount_tiyin, source_id, paid_at, kind, comment, covers_lesson_debt, voids_payment_id', { count: 'exact' })
    .gte('paid_at', fromIso)
    .lt('paid_at', toIso)
  if (filters.kind) query = query.eq('kind', filters.kind)
  if (filters.source === 'none') query = query.is('source_id', null)
  else if (filters.source) query = query.eq('source_id', filters.source)
  if (needle && !nameMiss && !tooBroad) {
    const parts = [
      payerIds.length ? `payer_id.in.(${payerIds.join(',')})` : null,
      studentIds.length ? `student_id.in.(${studentIds.join(',')})` : null,
    ].filter(Boolean)
    query = query.or(parts.join(','))
  }

  const { data: payments, error: paymentsError, count: paymentsCount } = nameMiss || tooBroad
    ? { data: [], error: null, count: 0 }
    : await query
        .order('paid_at', { ascending: false })
        // У отмены та же дата, что у исходного (0093): вторичный порядок держит
        // пару рядом и не режет её границей limit.
        .order('created_at', { ascending: false })
        .limit(LIST_LIMIT)
  const rows = payments ?? []
  // Отменённые (0093) — отдельным запросом по id строк страницы, а не по самим
  // строкам: отмена — строка kind='correction', и фильтр «Вид = Платёж» её
  // убирал — отменённый платёж выглядел живым, с кнопкой «Отменить».
  const pageIds = rows.map((p) => p.id)
  const { data: voidRows } = pageIds.length
    ? await supabase.from('payments').select('voids_payment_id').in('voids_payment_id', pageIds)
    : { data: [] as { voids_payment_id: string | null }[] }
  const voidedIds = new Set((voidRows ?? []).map((v) => v.voids_payment_id).filter((v): v is string => Boolean(v)))
  const filtered = Boolean(filters.q || filters.source || filters.kind)
  const back = `/app/finance?tab=payments&month=${month}`

  return (
    <div className="space-y-4">
      {/* «Итого в кассе» из cash_by_source — уже за вычетом расходов. Без
          строки «Расходы» сумма над итогом не сходилась: получено 5 500,
          итого 5 000, а куда делись 500 — не видно. Знаки как в базе:
          возвраты и расходы отрицательные, строки складываются в итог. */}
      {finance ? (
        <>
          {/* Условный рендер, а не hidden: у Tailwind .grid перебивает [hidden], и при
              сбое кассы рядом с ошибкой оставались нули «Итого в кассе 0 сом». */}
          {cashError ? <FormError message={cashError} /> : null}
          {cashError ? null : (
          <dl
            data-testid="cash-totals"
            className="grid grid-cols-2 gap-3 rounded-md border border-border bg-muted/50 p-3 text-sm sm:grid-cols-5"
          >
            <div>
              <dt className="text-xs text-muted-foreground">{t('finance', 'received')}</dt>
              <dd className="font-medium tabular-nums">{formatSom(totals.received)}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">{t('finance', 'refunded')}</dt>
              <dd className="font-medium tabular-nums">{formatSom(totals.refunded)}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">{t('finance', 'corrections')}</dt>
              <dd className="font-medium tabular-nums">{formatSom(totals.corrections)}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">{t('finance', 'spent')}</dt>
              <dd className="font-medium tabular-nums">{formatSom(totals.spent)}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">{t('finance', 'total')}</dt>
              <dd className="font-medium tabular-nums">{formatSom(totals.total)}</dd>
            </div>
          </dl>
          )}
          {bySource.length && !cashError ? (
            <ul className="flex flex-wrap gap-2 text-sm" aria-label={t('finance', 'bySource')}>
              {bySource.map((s) => (
                <li key={s.name} className="rounded-full border border-border px-3 py-1">
                  <span className="text-muted-foreground">{s.name}</span>{' '}
                  <span className={cn('font-medium tabular-nums', s.total < 0 && 'text-destructive')}>{formatSom(s.total)}</span>
                </li>
              ))}
            </ul>
          ) : null}
        </>
      ) : (
        <p className="text-sm text-muted-foreground">{t('finance', 'registrarNoCash')}</p>
      )}

      {/* Поступления за день — всем, кто принимает оплату (0100: решение владельца — стойке тоже, сдать кассу вечером). */}
      <DaySummary supabase={supabase} day={day} today={today} month={month} timeZone={timeZone} />

      {/* GET-форма: фильтры попадают в адрес, как на «Долгах». */}
      <form action="/app/finance" className="flex flex-wrap items-end gap-2">
        <input type="hidden" name="tab" value="payments" />
        <input type="hidden" name="month" value={month} />
        <div className="min-w-[12rem] flex-1 space-y-1 sm:max-w-xs">
          <Label htmlFor="filter-q">{t('finance', 'filterSearch')}</Label>
          <Input id="filter-q" name="q" defaultValue={filters.q} placeholder="Например, Иванова" maxLength={60} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="filter-source">{t('finance', 'filterSource')}</Label>
          <Select id="filter-source" name="source" defaultValue={filters.source} className="w-auto">
            <option value="">{t('finance', 'filterAll')}</option>
            {sources.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
            <option value="none">{t('finance', 'noSource')}</option>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="filter-kind">{t('finance', 'filterKind')}</Label>
          <Select id="filter-kind" name="kind" defaultValue={filters.kind} className="w-auto">
            <option value="">{t('finance', 'filterAll')}</option>
            {(['payment', 'refund', 'correction'] as const).map((kind) => (
              <option key={kind} value={kind}>
                {label('paymentKind', kind)}
              </option>
            ))}
          </Select>
        </div>
        <button type="submit" className={buttonVariants({ variant: 'outline', size: 'sm' })}>
          {t('finance', 'filterApply')}
        </button>
        {filtered ? (
          <Link href={back} className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
            {t('finance', 'filterReset')}
          </Link>
        ) : null}
      </form>

      <Card>
        <CardHeader>
          <CardTitle>{t('finance', 'tabPayments')}</CardTitle>
          {paymentsError ? null : <CardDescription>{shownOfTotal(rows.length, paymentsCount)}</CardDescription>}
        </CardHeader>
        <CardContent>
          {paymentsError ? (
            <FormError message={loadErrorMessage(paymentsError, t('finance', 'loadPaymentsFailed'))} />
          ) : rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {tooBroad ? t('finance', 'searchTooBroad') : filtered ? t('finance', 'paymentsFilteredEmpty') : t('finance', 'paymentsEmpty')}
            </p>
          ) : (
            <Table className="max-sm:[&_tr>*:nth-child(2)]:hidden max-sm:[&_tr>*:nth-child(4)]:hidden max-sm:[&_tr>*:nth-child(5)]:hidden max-sm:[&_tr>*:nth-child(7)]:hidden">
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
                    <TableCell>{payerName(p.payer_id)}</TableCell>
                    <TableCell>
                      {p.student_id ? (
                        <Link href={`/app/students/${p.student_id}`} className="hover:underline">
                          {studentName.get(p.student_id) ?? '—'}
                        </Link>
                      ) : (
                        <span className="sm:hidden">{payerName(p.payer_id)}</span>
                      )}
                      {p.student_id ? null : <span className="hidden sm:inline">—</span>}
                      {/* На телефоне колонки «Вид» и «Плательщик» скрыты — без этой строки
                          корректировку не отличить от оплаты (UX-аудит, UX71). */}
                      <span className="block text-xs text-muted-foreground sm:hidden">
                        {label('paymentKind', p.kind)} ·{' '}
                        <Link href={receiptHref(p.id, back)} className="text-primary underline-offset-4 hover:underline">
                          {t('finance', 'receipt').toLowerCase()}
                        </Link>
                      </span>
                    </TableCell>
                    <TableCell>{label('paymentKind', p.kind)}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {p.source_id ? (sourceName.get(p.source_id) ?? '—') : t('finance', 'noSource')}
                    </TableCell>
                    {/* Метка «отменён», квитанция и кнопка отмены — в колонке суммы: она видна
                        и на телефоне, где комментарий скрыт (0093). */}
                    <TableCell className={cn('text-right font-medium tabular-nums', p.amount_tiyin < 0 && 'text-destructive')}>
                      <span className="inline-flex items-center justify-end gap-1.5 whitespace-nowrap">
                        {formatSom(p.amount_tiyin)}
                        {/* На телефоне ссылка — словом под именем ученика: иконка раздвигала таблицу. */}
                        <Link
                          href={receiptHref(p.id, back)}
                          aria-label={`${t('finance', 'receipt')}: ${formatSom(p.amount_tiyin)}`}
                          title={t('finance', 'receipt')}
                          className="hidden rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:inline-flex"
                        >
                          <ReceiptText className="size-4" aria-hidden="true" />
                        </Link>
                      </span>
                      {voidedIds.has(p.id) ? <span className="block text-xs font-normal text-destructive">отменён</span> : null}
                      {isOwner &&
                      p.kind === 'payment' &&
                      !p.subscription_id &&
                      !p.covers_lesson_debt &&
                      !voidedIds.has(p.id) ? (
                        <VoidPaymentForm paymentId={p.id} amountTiyin={p.amount_tiyin} />
                      ) : null}
                    </TableCell>
                    <TableCell className="max-w-[16rem] truncate text-muted-foreground" title={p.comment ?? undefined}>
                      {p.comment ?? ''}
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

async function ExpensesTab({
  supabase,
  month,
  fromIso,
  toIso,
  timeZone,
  categories,
  categoryFilter,
  sourceName,
  cashError,
  spent,
}: {
  supabase: Supabase
  month: string
  fromIso: string
  toIso: string
  timeZone: string
  categories: { id: string; name: string }[]
  categoryFilter: string
  sourceName: Map<string, string>
  cashError: string | null
  spent: number
}) {
  let query = supabase
    .from('expenses')
    .select('id, category_id, source_id, amount_tiyin, paid_at, kind, comment', { count: 'exact' })
    .gte('paid_at', fromIso)
    .lt('paid_at', toIso)
  if (categoryFilter) query = query.eq('category_id', categoryFilter)
  // Имена статей — со всеми, включая скрытые и архивные: у прошлых расходов
  // название не должно пропадать (read_archived, 0028).
  const [{ data: expenses, error: expensesError, count: expensesCount }, { data: allCategories }] = await Promise.all([
    query.order('paid_at', { ascending: false }).limit(LIST_LIMIT),
    supabase.from('expense_categories').select('id, name'),
  ])
  const categoryName = new Map((allCategories ?? []).map((c) => [c.id, c.name]))
  const rows = expenses ?? []
  const back = `/app/finance?tab=expenses&month=${month}`

  return (
    <div className="space-y-4">
      {cashError ? (
        <FormError message={cashError} />
      ) : (
        <p className="text-sm">
          {t('finance', 'spent')}: <strong className="tabular-nums">{formatSom(Math.abs(spent))}</strong>
          {categoryFilter ? <span className="text-muted-foreground"> — за месяц, все статьи</span> : null}
        </p>
      )}
      <form action="/app/finance" className="flex flex-wrap items-end gap-2">
        <input type="hidden" name="tab" value="expenses" />
        <input type="hidden" name="month" value={month} />
        <div className="space-y-1">
          <Label htmlFor="filter-category">{t('finance', 'filterCategory')}</Label>
          <Select id="filter-category" name="category" defaultValue={categoryFilter} className="w-auto">
            <option value="">{t('finance', 'filterAll')}</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
        </div>
        <button type="submit" className={buttonVariants({ variant: 'outline', size: 'sm' })}>
          {t('finance', 'filterApply')}
        </button>
        {categoryFilter ? (
          <Link href={back} className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
            {t('finance', 'filterReset')}
          </Link>
        ) : null}
      </form>
      <Card>
        <CardHeader>
          <CardTitle>{t('finance', 'tabExpenses')}</CardTitle>
          {expensesError ? null : <CardDescription>{shownOfTotal(rows.length, expensesCount)}</CardDescription>}
        </CardHeader>
        <CardContent>
          {expensesError ? (
            <FormError message={loadErrorMessage(expensesError, t('finance', 'loadExpensesFailed'))} />
          ) : rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">{categoryFilter ? t('finance', 'paymentsFilteredEmpty') : t('finance', 'expensesEmpty')}</p>
          ) : (
            <Table className="max-sm:[&_tr>*:nth-child(3)]:hidden max-sm:[&_tr>*:nth-child(4)]:hidden max-sm:[&_tr>*:nth-child(6)]:hidden">
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
                    <TableCell className="text-right font-medium tabular-nums">{formatSom(e.amount_tiyin)}</TableCell>
                    <TableCell className="max-w-[16rem] truncate text-muted-foreground">{e.comment ?? ''}</TableCell>
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

async function InstallmentsTab({
  supabase,
  timeZone,
  sources,
}: {
  supabase: Supabase
  timeZone: string
  sources: { id: string; name: string }[]
}) {
  const { data: rows, error: installmentsError, count: installmentsCount } = await supabase
    .from('installments_view')
    .select('id, subscription_id, student_id, payer_id, seq, due_date, amount_tiyin, state, cancelled_at, due_through_tiyin, row_remaining_tiyin', {
      count: 'exact',
    })
    .is('cancelled_at', null)
    .neq('state', 'paid')
    .order('due_date')
    .limit(LIST_LIMIT)
  const live = (rows ?? []).filter(
    (r) => r.id && r.due_date && r.amount_tiyin != null && r.due_through_tiyin != null && r.row_remaining_tiyin != null,
  )
  const studentIds = [...new Set(live.map((r) => r.student_id).filter((v): v is string => Boolean(v)))]
  const payerIds = [...new Set(live.map((r) => r.payer_id).filter((v): v is string => Boolean(v)))]
  const [{ data: students }, { data: payers }] = await Promise.all([
    studentIds.length
      ? supabase.rpc('students_brief').in('id', studentIds)
      : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
    payerIds.length
      ? supabase.rpc('payers_brief').in('id', payerIds)
      : Promise.resolve({ data: [] as { id: string; full_name: string; phone: string | null }[] }),
  ])
  const studentName = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const payerById = new Map((payers ?? []).map((p) => [p.id, p]))

  // Источник по умолчанию — тот, которым по этому абонементу платили последним:
  // семья обычно платит одним способом. Раньше всегда стояли «Наличные».
  const subscriptionIds = [...new Set(live.map((r) => r.subscription_id).filter((v): v is string => Boolean(v)))]
  const { data: lastPayments } = subscriptionIds.length
    ? await supabase
        .from('payments')
        .select('subscription_id, source_id, paid_at')
        .in('subscription_id', subscriptionIds)
        .eq('kind', 'payment')
        .not('source_id', 'is', null)
        .order('paid_at', { ascending: false })
    : { data: [] as { subscription_id: string | null; source_id: string | null; paid_at: string }[] }
  const lastSourceBySubscription = new Map<string, string>()
  for (const p of lastPayments ?? []) {
    if (p.subscription_id && p.source_id && !lastSourceBySubscription.has(p.subscription_id)) {
      lastSourceBySubscription.set(p.subscription_id, p.source_id)
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('finance', 'tabInstallments')}</CardTitle>
        {installmentsError ? null : <CardDescription>{shownOfTotal(rows?.length ?? 0, installmentsCount, 'ближайшие')}</CardDescription>}
      </CardHeader>
      <CardContent>
        {installmentsError ? (
          <FormError message={loadErrorMessage(installmentsError, t('finance', 'loadInstallmentsFailed'))} />
        ) : live.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t('finance', 'installmentsEmpty')}</p>
        ) : (
          <Table className="max-sm:[&_tr>*:nth-child(3)]:hidden max-sm:[&_tr>*:nth-child(4)]:hidden">
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
                // Остаток строки (0100): после частичной оплаты родителю не напомним плановую сумму.
                const remaining = r.row_remaining_tiyin as number
                const message = t('finance', 'whatsappReminder', {
                  student,
                  amount: formatSom(remaining),
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
                    <TableCell className="text-right font-medium tabular-nums">
                      {formatSom(remaining)}
                      {remaining < (r.amount_tiyin as number) ? (
                        <span className="block text-xs font-normal text-muted-foreground">
                          {t('finance', 'partOf', { sum: formatSom(r.amount_tiyin as number) })}
                        </span>
                      ) : null}
                    </TableCell>
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
                        <PayInstallmentForm
                          installmentId={r.id as string}
                          dueThroughTiyin={r.due_through_tiyin as number}
                          rowRemainingTiyin={remaining}
                          sources={sources}
                          defaultSourceId={r.subscription_id ? lastSourceBySubscription.get(r.subscription_id) : undefined}
                        />
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
  const { first: prevFirst } = monthBounds(previous)

  // Тот же счётчик, по которому откажет close_month (0031): не только
  // planned, но и проведённые без отметки участника.
  const [{ data: periods, error: periodsError }, { data: openCount, error: openCountError }] = await Promise.all([
    supabase.from('financial_periods').select('month, closed_at').order('month', { ascending: false }).limit(12),
    supabase.rpc('month_open_lessons_count', { p_month: prevFirst }),
  ])
  const rows = periods ?? []
  const previousClosed = rows.some((p) => p.month === prevFirst && p.closed_at)

  // Без списка периодов previousClosed — всегда false, и форма «Закрыть месяц»
  // показалась бы и у уже закрытого месяца. Отказ — только ошибка.
  if (periodsError) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>{t('finance', 'tabPeriods')}</CardTitle>
        </CardHeader>
        <CardContent>
          <FormError message={loadErrorMessage(periodsError, t('finance', 'loadPeriodsFailed'))} />
        </CardContent>
      </Card>
    )
  }

  return (
    <div className="space-y-4">
      <Card>
        <CardHeader>
          <CardTitle>{t('finance', 'tabPeriods')}</CardTitle>
          <CardDescription>Замок месяца: платежи, расходы, отметки и ставки задним числом в закрытый месяц не проходят.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {/* null — счётчик неизвестен: «0» здесь читалось бы как «можно
              закрывать», а это ровно то обещание, ради которого счётчик и
              переписан на условие close_month. */}
          {!previousClosed ? (
            <ClosePeriodForm
              month={prevFirst}
              monthLabel={monthLabel(prevFirst)}
              openCount={openCountError ? null : (openCount ?? 0)}
            />
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

type DayJson = { total_tiyin?: number; ops?: number; by_source?: { name: string; total_tiyin: number; ops: number }[] }

/**
 * Поступления за день (0100 Р6) — то же, что /cash в боте: платежи дня центра
 * по способам оплаты, расходы не входят. Только can_finance — как /cash и
 * cash_by_source; регистратору блок не рисуется (база ответила бы 42501).
 */
async function DaySummary({
  supabase,
  day,
  today,
  month,
  timeZone,
}: {
  supabase: Supabase
  day: string
  today: string
  month: string
  timeZone: string
}) {
  const { data, error } = await supabase.rpc('payments_day_summary', { p_day: day })
  const summary = (data ?? {}) as DayJson
  const label = calendarDate(day, timeZone)
  return (
    <Card>
      <CardHeader className="gap-3 sm:flex-row sm:items-end sm:justify-between sm:space-y-0">
        <div className="space-y-1.5">
          <CardTitle>{t('finance', 'dayTitle')}</CardTitle>
          <CardDescription>{t('finance', 'dayHint')}</CardDescription>
        </div>
        <form action="/app/finance" className="flex items-end gap-2">
          <input type="hidden" name="tab" value="payments" />
          <input type="hidden" name="month" value={month} />
          <div className="space-y-1">
            <Label htmlFor="day-pick">{t('finance', 'dayPick')}</Label>
            <Input id="day-pick" name="day" type="date" defaultValue={day} max={today} className="w-auto" />
          </div>
          <button type="submit" className={buttonVariants({ variant: 'outline', size: 'sm' })}>
            {t('finance', 'filterApply')}
          </button>
        </form>
      </CardHeader>
      <CardContent>
        {error ? (
          <FormError message={loadErrorMessage(error, t('finance', 'dayLoadFailed'))} />
        ) : (summary.ops ?? 0) === 0 ? (
          <p className="text-sm text-muted-foreground">{t('finance', 'dayEmpty', { day: label })}</p>
        ) : (
          <div className="space-y-3 text-sm">
            <p>
              {label}: <strong className="tabular-nums">{formatSom(Number(summary.total_tiyin ?? 0))}</strong>
              <span className="text-muted-foreground"> · {t('finance', 'dayOps', { n: Number(summary.ops ?? 0) })}</span>
            </p>
            <ul className="flex flex-wrap gap-2">
              {(summary.by_source ?? []).map((row) => (
                <li key={row.name} className="rounded-full border border-border px-3 py-1">
                  <span className="text-muted-foreground">{row.name}</span>{' '}
                  <span className={cn('font-medium tabular-nums', row.total_tiyin < 0 && 'text-destructive')}>
                    {formatSom(Number(row.total_tiyin))}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
