import Link from 'next/link'
import { redirect } from 'next/navigation'
import { formatKgPhone, formatSom, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
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
  lessonsLeft: number | null
  activeSubscriptionId: string | null
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

// Просрочку абонемента упоминаем в сообщении, только если платить по нему
// должен ТОТ ЖЕ человек, чей это WhatsApp — иначе требование денег уйдёт
// не тому плательщику (архитектор-ревью 0070, находка №6).
function subscriptionOverdueAddressable(row: Row): boolean {
  return row.subscriptionOverdueTiyin > 0 && row.subscriptionOverduePayerId === row.payerId
}

function whatsappMessage(row: Row): string {
  const parts: string[] = []
  if (row.debtTiyin > 0) parts.push(`долг за занятия ${formatSom(row.debtTiyin)}`)
  if (row.overdrawnTiyin > 0) parts.push(`перерасход по абонементу ${formatSom(row.overdrawnTiyin)}`)
  if (subscriptionOverdueAddressable(row)) {
    parts.push(`просроченный платёж за абонемент ${formatSom(row.subscriptionOverdueTiyin)}`)
  }

  if (parts.length > 0) {
    return `Здравствуйте! У ${row.studentName} ${parts.join(' и ')} в LogoCRM. Пожалуйста, оплатите при возможности.`
  }
  return `Здравствуйте! У ${row.studentName} закончился абонемент. Хотите продлить?`
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

  // Одним запросом на всех, не по одному студенту — «Список за период —
  // один запрос на диапазон, не N запросов по дням», CLAUDE.md, тот же
  // принцип на список проблемных балансов.
  const { data: balanceRows } = await supabase
    .from('student_balance')
    .select(
      'student_id, debt_tiyin, overdrawn_tiyin, subscription_overdue_tiyin, subscription_overdue_payer_id, lessons_left, active_subscription_id',
    )

  const problematic = (balanceRows ?? []).filter((row) => {
    const debt = row.debt_tiyin ?? 0
    const overdrawn = row.overdrawn_tiyin ?? 0
    const subscriptionOverdue = row.subscription_overdue_tiyin ?? 0
    // «Остаток 0» — абонемент активен, но исчерпан: null здесь ambiguous
    // (без абонемента тоже null), поэтому только когда active_subscription_id
    // заполнен — тот же приём, что в BalanceStrip (students/[id]).
    const zeroLeft = row.active_subscription_id !== null && row.lessons_left === 0
    return debt > 0 || overdrawn > 0 || subscriptionOverdue > 0 || zeroLeft
  })

  const studentIds = problematic.map((r) => r.student_id).filter((v): v is string => Boolean(v))

  if (studentIds.length === 0) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold tracking-tight">Долги</h1>
        <Card>
          <CardContent className="pt-6 text-sm text-muted-foreground">Долгов нет.</CardContent>
        </Card>
      </div>
    )
  }

  const nowIso = new Date().toISOString()

  const [{ data: students }, { data: pastLessons }, { data: futureLessons }] = await Promise.all([
    supabase.from('students').select('id, full_name, payer_id').in('id', studentIds),
    supabase
      .from('lesson_participants')
      .select('student_id, starts_at')
      .in('student_id', studentIds)
      .lt('starts_at', nowIso)
      .order('starts_at', { ascending: false }),
    supabase
      .from('lesson_participants')
      .select('student_id, starts_at')
      .in('student_id', studentIds)
      .eq('status', 'planned')
      .gte('starts_at', nowIso)
      .order('starts_at'),
  ])

  // Плательщик студента и плательщик просроченного абонемента — не всегда
  // один человек (0070, находка №6) — оба набора id нужны в payerById.
  const payerIds = [
    ...new Set(
      [
        ...(students ?? []).map((s) => s.payer_id),
        ...problematic.map((r) => r.subscription_overdue_payer_id),
      ].filter((v): v is string => Boolean(v)),
    ),
  ]
  const { data: payers } = payerIds.length
    ? await supabase.from('payers').select('id, full_name, phone').in('id', payerIds)
    : { data: [] }

  const studentById = new Map((students ?? []).map((s) => [s.id, s]))
  const payerById = new Map((payers ?? []).map((p) => [p.id, p]))

  const lastByStudent = new Map<string, string>()
  for (const row of pastLessons ?? []) {
    if (row.student_id && !lastByStudent.has(row.student_id)) lastByStudent.set(row.student_id, row.starts_at)
  }
  const nextByStudent = new Map<string, string>()
  for (const row of futureLessons ?? []) {
    if (row.student_id && !nextByStudent.has(row.student_id)) nextByStudent.set(row.student_id, row.starts_at)
  }

  let rows: Row[] = problematic.map((r) => {
    const student = r.student_id ? studentById.get(r.student_id) : undefined
    const payer = student?.payer_id ? payerById.get(student.payer_id) : undefined
    return {
      studentId: r.student_id ?? '',
      studentName: student?.full_name ?? '—',
      payerId: payer?.id ?? null,
      payerName: payer?.full_name ?? null,
      payerPhone: payer?.phone ?? null,
      debtTiyin: r.debt_tiyin ?? 0,
      overdrawnTiyin: r.overdrawn_tiyin ?? 0,
      subscriptionOverdueTiyin: r.subscription_overdue_tiyin ?? 0,
      subscriptionOverduePayerId: r.subscription_overdue_payer_id,
      lessonsLeft: r.lessons_left,
      activeSubscriptionId: r.active_subscription_id,
      lastLessonAt: r.student_id ? (lastByStudent.get(r.student_id) ?? null) : null,
      nextLessonAt: r.student_id ? (nextByStudent.get(r.student_id) ?? null) : null,
    }
  })

  if (filter === 'debt') {
    rows = rows.filter((r) => r.debtTiyin > 0 || r.overdrawnTiyin > 0 || r.subscriptionOverdueTiyin > 0)
  }
  if (filter === 'zero') {
    rows = rows.filter((r) => r.debtTiyin === 0 && r.overdrawnTiyin === 0 && r.subscriptionOverdueTiyin === 0)
  }

  rows.sort((a, b) => {
    if (sort === 'name') return a.studentName.localeCompare(b.studentName, 'ru')
    // Долг за занятия и перерасход — одна и та же «за услугу уже заплатили
    // меньше, чем она стоила» природа, их можно сложить для сортировки.
    // Просрочка абонемента — другие деньги (docs/Database.md, «Два слова,
    // два определения»); сумма с ней дала бы бессмысленный порядок (долг
    // 500 сом выше просрочки 50 000), поэтому сортируем по максимуму из
    // двух корзин, а не по общей сумме.
    const usageA = a.debtTiyin + a.overdrawnTiyin
    const usageB = b.debtTiyin + b.overdrawnTiyin
    return Math.max(usageB, b.subscriptionOverdueTiyin) - Math.max(usageA, a.subscriptionOverdueTiyin)
  })

  const totalDebt = rows.reduce((sum, r) => sum + r.debtTiyin + r.overdrawnTiyin, 0)
  const totalSubscriptionOverdue = rows.reduce((sum, r) => sum + r.subscriptionOverdueTiyin, 0)

  const filterLink = (value: Filter) => `/app/debts?filter=${value}&sort=${sort}`
  const sortLink = (value: Sort) => `/app/debts?filter=${filter}&sort=${value}`

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Долги</h1>
        <p className="text-sm text-muted-foreground">
          {rows.length} {rows.length === 1 ? 'ученик' : 'учеников'}
          {totalDebt > 0 ? ` · долг ${formatSom(totalDebt)}` : ''}
          {/* Отдельная сумма, не сложенная с долгом за занятия — разные деньги (docs/Database.md). */}
          {totalSubscriptionOverdue > 0 ? ` · просрочка по абонементам ${formatSom(totalSubscriptionOverdue)}` : ''}
        </p>
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
            // Просрочка есть, но платить должен не тот, чей контакт на
            // карточке — молча звать текущего плательщика ребёнка нельзя
            // (0070, находка №6). subscriptionOverduePayerId = null, если у
            // ребёнка сразу несколько просроченных абонементов разных
            // плательщиков — уточнить, кому писать, тогда может только
            // человек, а не эта карточка.
            const overdueMismatch = row.subscriptionOverdueTiyin > 0 && !subscriptionOverdueAddressable(row)
            const overduePayer = row.subscriptionOverduePayerId ? payerById.get(row.subscriptionOverduePayerId) : undefined
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
                        {overduePayer ? `${overduePayer.full_name}${overduePayer.phone ? ` · ${formatKgPhone(overduePayer.phone)}` : ''}` : 'другого плательщика'}
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
                    {waNumber ? (
                      <a
                        href={`https://wa.me/${waNumber}?text=${encodeURIComponent(whatsappMessage(row))}`}
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
