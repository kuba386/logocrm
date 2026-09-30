import Link from 'next/link'
import { redirect } from 'next/navigation'
import {
  debtWhatsappMessage,
  formatKgPhone,
  formatSom,
  parseDebtSummary,
  subscriptionOverdueAddressable,
  whatsappNumber,
} from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { centerTimeZone, dayInZone } from '@/lib/timezone'
import { isFinance } from '@/lib/roles'
import { Card, CardContent } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { cn } from '@/lib/utils'

export const metadata = { title: 'Долги — LogoCRM' }

type Filter = 'all' | 'debt' | 'zero'
type Sort = 'amount' | 'name'

type Row = {
  studentId: string
  studentName: string
  payerId: string | null
  payerName: string | null
  payerPhone: string | null
  debtTiyin: number
  overdrawnTiyin: number
  subscriptionOverdueTiyin: number
  // Плательщик АБОНЕМЕНТА (subscriptions.payer_id на момент продажи), не
  // текущий payer_id ребёнка — их могли развести (link_parent_payer, 0060).
  // NULL, если у ребёнка сразу несколько просроченных абонементов разных
  // плательщиков — тогда автосообщение не пишем никому наугад (0070).
  subscriptionOverduePayerId: string | null
  overduePayerName: string | null
  overduePayerPhone: string | null
  lessonsLeft: number | null
  activeSubscriptionId: string | null
  // Исчерпанный остаток без денежных проблем — из SQL (0076), не пересчитывается здесь.
  zeroLeft: boolean
  lastLessonAt: string | null
  nextLessonAt: string | null
}

// Три разных долга не складываются в один (docs/Database.md, «Два слова,
// два определения»): за занятия без абонемента, перерасход по абонементу и
// просрочка оплаты САМОГО абонемента (0070) — разные деньги, разные причины
// написать родителю. «Остаток исчерпан» — не долг, а сигнал «пора продлить»,
// показывается только когда денежных проблем нет вовсе.
function problems(row: Row): Array<{ label: string; amount: number | null; tone: 'danger' | 'warning' }> {
  const list: Array<{ label: string; amount: number | null; tone: 'danger' | 'warning' }> = []
  if (row.debtTiyin > 0) list.push({ label: 'Долг за занятия', amount: row.debtTiyin, tone: 'danger' })
  if (row.overdrawnTiyin > 0) list.push({ label: 'Перерасход', amount: row.overdrawnTiyin, tone: 'danger' })
  if (row.subscriptionOverdueTiyin > 0) {
    list.push({ label: 'Просрочен платёж за абонемент', amount: row.subscriptionOverdueTiyin, tone: 'danger' })
  }
  if (list.length === 0) list.push({ label: 'Остаток исчерпан', amount: null, tone: 'warning' })
  return list
}

export default async function DebtsPage({
  searchParams,
}: {
  searchParams: Promise<{ filter?: string; sort?: string }>
}) {
  const params = await searchParams
  const filter: Filter = params.filter === 'debt' || params.filter === 'zero' ? params.filter : 'all'
  const sort: Sort = params.sort === 'name' ? 'name' : 'amount'

  const supabase = await createClient()

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const {
    data: { user },
  } = await supabase.auth.getUser()
  const centerId = (user?.app_metadata as { center_id?: string } | undefined)?.center_id ?? null
  const { data: center } = await supabase.from('centers').select('settings').eq('id', centerId ?? '').maybeSingle()
  const timeZone = centerTimeZone(center?.settings)

  // Одним запросом на всех (0078): строки student_debt_problems (0076 — тот же источник у
  // дашборда, ассистента и бота /debts), контакты плательщиков и последнее/ближайшее занятие
  // собирает SQL. Без .in(ids): сотни uuid в URL упирались в его длину, а прошлые уроки без
  // лимита резались по max_rows.
  const [{ data: problemRows, error: problemsError }, { data: summaryJson, error: summaryError }] = await Promise.all([
    supabase.rpc('student_debt_page'),
    // Шапка — итоги SQL, а не reduce по строкам: PostgREST режет ответ по max_rows (1000).
    supabase.rpc('student_debt_summary', { p_top: 0 }),
  ])
  // Отказ RPC (не применена миграция, сбой, таймаут) — не «Долгов нет»: показываем ошибку.
  const loadError = problemsError ?? summaryError
  if (loadError) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold tracking-tight">Долги</h1>
        <Card>
          <CardContent className="pt-6 text-sm text-destructive">
            {toAppError(loadError, 'Не удалось загрузить долги').message}
          </CardContent>
        </Card>
      </div>
    )
  }
  const problematic = problemRows ?? []
  const summary = parseDebtSummary(summaryJson)

  if (problematic.length === 0) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold tracking-tight">Долги</h1>
        <Card>
          <CardContent className="pt-6 text-sm text-muted-foreground">Долгов нет.</CardContent>
        </Card>
      </div>
    )
  }

  // Генератор типов объявляет колонки table-функции non-null, в рантайме они бывают NULL.
  let rows: Row[] = problematic.map((r) => ({
    studentId: r.student_id,
    studentName: r.full_name || '—',
    // payer_id сырой (0078 Р3): сравнивается с плательщиком просрочки. Контакт есть, только
    // если плательщик виден и не удалён — payer_name не NULL.
    payerId: (r.payer_id as string | null) ?? null,
    payerName: (r.payer_name as string | null) ?? null,
    payerPhone: (r.payer_phone as string | null) ?? null,
    debtTiyin: r.debt_tiyin,
    overdrawnTiyin: r.overdrawn_tiyin,
    subscriptionOverdueTiyin: r.overdue_tiyin,
    // NULL — «просрочки нет» либо просрочены абонементы разных плательщиков (0070); значимо только при просрочке.
    subscriptionOverduePayerId: (r.overdue_payer_id as string | null) ?? null,
    overduePayerName: (r.overdue_payer_name as string | null) ?? null,
    overduePayerPhone: (r.overdue_payer_phone as string | null) ?? null,
    lessonsLeft: (r.lessons_left as number | null) ?? null,
    activeSubscriptionId: (r.active_subscription_id as string | null) ?? null,
    zeroLeft: r.zero_left,
    lastLessonAt: (r.last_lesson_at as string | null) ?? null,
    nextLessonAt: (r.next_lesson_at as string | null) ?? null,
  }))

  if (filter === 'debt') rows = rows.filter((r) => !r.zeroLeft)
  if (filter === 'zero') rows = rows.filter((r) => r.zeroLeft)

  // «По сумме» — порядок из SQL (sort_tiyin desc, full_name, student_id): максимум двух
  // корзин, а не сумма — долг 500 сом не выше просрочки 50 000 (Database.md, «Два слова…»).
  // Своей копии формулы здесь нет. «По имени» — только представление.
  if (sort === 'name') rows.sort((a, b) => a.studentName.localeCompare(b.studentName, 'ru'))

  // Шапка — из student_debt_summary (та же цифра, что на дашборде и в боте). Исчерпанный
  // остаток без денег — не должник: в «Только долги» его нет, в «Только нулевой остаток» — только он.
  const headerCount =
    filter === 'debt' ? summary.debtorsN : filter === 'zero' ? summary.zeroN : summary.debtorsN + summary.zeroN
  const totalDebt = filter === 'zero' ? 0 : summary.usageTiyin
  const totalSubscriptionOverdue = filter === 'zero' ? 0 : summary.overdueTiyin
  // PostgREST режет ответ по max_rows: строк может быть больше, чем показано.
  const truncated = problematic.length >= 1000

  const filterLink = (value: Filter) => `/app/debts?filter=${value}&sort=${sort}`
  const sortLink = (value: Sort) => `/app/debts?filter=${filter}&sort=${value}`

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Долги</h1>
        <p className="text-sm text-muted-foreground">
          {headerCount} {headerCount === 1 ? 'ученик' : 'учеников'}
          {totalDebt > 0 ? ` · долг ${formatSom(totalDebt)}` : ''}
          {/* Отдельная сумма, не сложенная с долгом за занятия — разные деньги (docs/Database.md). */}
          {totalSubscriptionOverdue > 0 ? ` · просрочка по абонементам ${formatSom(totalSubscriptionOverdue)}` : ''}
        </p>
        {truncated ? (
          <p className="text-sm text-destructive">
            Показаны не все ученики — сервер отдаёт не больше 1000 строк; итоги в шапке считаются по всем.
          </p>
        ) : null}
        {/* Выгрузка — только can_finance (0058), регистратору не показываем. */}
        {isFinance(role) ? (
          <Link href="/app/reports" className="text-sm text-primary underline-offset-4 hover:underline">
            Отчёты →
          </Link>
        ) : null}
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap gap-2">
          <Link href={filterLink('all')} className={buttonVariants({ variant: filter === 'all' ? 'default' : 'outline', size: 'sm' })}>
            Все
          </Link>
          <Link href={filterLink('debt')} className={buttonVariants({ variant: filter === 'debt' ? 'default' : 'outline', size: 'sm' })}>
            Только долги
          </Link>
          <Link href={filterLink('zero')} className={buttonVariants({ variant: filter === 'zero' ? 'default' : 'outline', size: 'sm' })}>
            Только нулевой остаток
          </Link>
        </div>
        <div className="flex flex-wrap gap-2">
          <Link href={sortLink('amount')} className={buttonVariants({ variant: sort === 'amount' ? 'default' : 'outline', size: 'sm' })}>
            По сумме
          </Link>
          <Link href={sortLink('name')} className={buttonVariants({ variant: sort === 'name' ? 'default' : 'outline', size: 'sm' })}>
            По имени
          </Link>
        </div>
      </div>

      {rows.length === 0 ? (
        <Card>
          <CardContent className="pt-6 text-sm text-muted-foreground">Ничего не найдено с этим фильтром.</CardContent>
        </Card>
      ) : (
        <div className="space-y-3">
          {rows.map((row) => {
            const rowProblems = problems(row)
            const waNumber = whatsappNumber(row.payerPhone)
            // null — сказать текущему плательщику нечего (только чужая просрочка): кнопки нет.
            const waText = debtWhatsappMessage(row)
            // Просрочка есть, но платить должен не тот, чей контакт на
            // карточке — молча звать текущего плательщика ребёнка нельзя
            // (0070, находка №6). subscriptionOverduePayerId = null, если у
            // ребёнка сразу несколько просроченных абонементов разных
            // плательщиков — уточнить, кому писать, тогда может только
            // человек, а не эта карточка.
            const overdueMismatch = row.subscriptionOverdueTiyin > 0 && !subscriptionOverdueAddressable(row)
            return (
              <Card key={row.studentId}>
                <CardContent className="flex flex-col gap-3 pt-6 sm:flex-row sm:items-center sm:justify-between">
                  <div className="min-w-0 space-y-1">
                    <Link href={`/app/students/${row.studentId}`} className="font-medium hover:underline">
                      {row.studentName}
                    </Link>
                    <p className="text-sm text-muted-foreground">
                      {row.payerName ?? 'Плательщик не указан'}
                      {row.payerPhone ? ` · ${formatKgPhone(row.payerPhone)}` : ''}
                    </p>
                    {overdueMismatch ? (
                      <p className="text-xs text-warning">
                        Абонемент оформлен на{' '}
                        {row.overduePayerName
                          ? `${row.overduePayerName}${row.overduePayerPhone ? ` · ${formatKgPhone(row.overduePayerPhone)}` : ''}`
                          : 'другого плательщика'}
                        — писать текущему плательщику ребёнка про эту сумму нельзя.
                      </p>
                    ) : null}
                    <p className="text-xs text-muted-foreground">
                      Последнее: {row.lastLessonAt ? dayInZone(row.lastLessonAt, timeZone) : '—'} · Ближайшее:{' '}
                      {row.nextLessonAt ? dayInZone(row.nextLessonAt, timeZone) : 'не запланировано'}
                    </p>
                  </div>

                  <div className="flex shrink-0 flex-wrap items-center gap-2">
                    {rowProblems.map((problem) => (
                      <span
                        key={problem.label}
                        className={cn(
                          'rounded px-2 py-1 text-sm font-medium',
                          problem.tone === 'danger' ? 'bg-destructive/10 text-destructive' : 'bg-warning-bg text-warning',
                        )}
                      >
                        {problem.label}
                        {problem.amount != null ? ` ${formatSom(problem.amount)}` : ''}
                      </span>
                    ))}
                    {waNumber && waText ? (
                      <a
                        href={`https://wa.me/${waNumber}?text=${encodeURIComponent(waText)}`}
                        target="_blank"
                        rel="noreferrer"
                        className={buttonVariants({ variant: 'outline', size: 'sm' })}
                      >
                        WhatsApp
                      </a>
                    ) : null}
                    <Link href={`/app/students/${row.studentId}`} className={buttonVariants({ size: 'sm' })}>
                      Продать абонемент
                    </Link>
                  </div>
                </CardContent>
              </Card>
            )
          })}
        </div>
      )}
    </div>
  )
}
