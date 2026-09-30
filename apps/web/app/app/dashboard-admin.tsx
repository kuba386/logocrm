import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { addDays, dayInZone, isoDayInZone, startOfDayInZone, timeInZone } from '@/lib/timezone'
import { debtSummaryLine, debtTopAmountLine, formatSom, parseDebtSummary } from '@logocrm/core'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { t } from '@/lib/messages'
import { toAppError } from '@/lib/errors'

/**
 * Дашборд администратора: сколько занятий сегодня, у кого заканчивается
 * абонемент, у кого долг, плюс деньги месяца (этап 5): выручка из
 * revenue_by_month, касса из cash_by_source, просрочки из installments_view.
 * Витрины считает база; под registrar выручка и касса пусты по RLS —
 * карточки скрываются флагом finance, а не «покажем нули». Под finance
 * закрыты lessons (0031) — блок занятий скрывается флагом showLessons.
 * Имена учеников — students_brief(): единственный источник без заметок,
 * общий для всех четырёх ролей этого дашборда.
 */
export async function AdminDashboard({
  timeZone,
  finance = true,
  showLessons = true,
  canOpenDebts = false,
}: {
  timeZone: string
  finance?: boolean
  showLessons?: boolean
  /** Ссылка «Все долги →»: тем же условием, что редирект /app/debts (owner/admin). */
  canOpenDebts?: boolean
}) {
  const supabase = await createClient()

  const today = isoDayInZone(new Date(), timeZone)
  const todayStart = startOfDayInZone(today, timeZone)
  const todayEnd = startOfDayInZone(addDays(today, 1), timeZone)
  const monthFirst = `${today.slice(0, 7)}-01`

  const [{ data: revenueRows }, { data: cashRows }, { count: overdueCount }] = await Promise.all([
    finance ? supabase.from('revenue_by_month').select('revenue_tiyin, visits').eq('month', monthFirst) : Promise.resolve({ data: [] }),
    finance ? supabase.from('cash_by_source').select('total_tiyin').eq('month', monthFirst) : Promise.resolve({ data: [] }),
    supabase
      .from('installments_view')
      .select('id', { count: 'exact', head: true })
      .eq('state', 'overdue')
      .is('cancelled_at', null),
  ])
  const revenue = (revenueRows ?? []).reduce((s, r) => s + (r.revenue_tiyin ?? 0), 0)
  const visits = (revenueRows ?? []).reduce((s, r) => s + (r.visits ?? 0), 0)
  const cashTotal = (cashRows ?? []).reduce((s, r) => s + (r.total_tiyin ?? 0), 0)

  const [{ data: lessonRows }, { data: lowBalanceRows }, { data: debtJson, error: debtError }] = await Promise.all([
    showLessons
      ? supabase
          .from('lessons')
          .select('id, starts_at, status, teacher_id, substitute_teacher_id, student_id, group_id')
          .is('deleted_at', null)
          .gte('starts_at', todayStart)
          .lt('starts_at', todayEnd)
          .order('starts_at')
      : Promise.resolve({ data: [] }),
    // lessons_left <= 2 сам исключает и «безлимит», и «нет абонемента» —
    // оба приходят из student_balance как null, а null <= 2 в Postgres
    // ложно (и PostgREST это уважает). state <> 'frozen' исключает
    // абонемент на оплаченной паузе: заканчивающийся остаток на паузе не
    // повод звонить и продавать — семья и так не расходует занятия сейчас.
    supabase
      .from('student_balance')
      .select('student_id, lessons_left, state')
      .lte('lessons_left', 2)
      .neq('state', 'frozen')
      .order('lessons_left'),
    // Долги — общий SQL-источник (0076): итоги по корзинам и топ считает база, а не
    // TypeScript по строкам (PostgREST режет ответ по max_rows). «Должник» — тот же,
    // что на /app/debts, в ассистенте и в боте /debts.
    supabase.rpc('student_debt_summary', { p_top: 5 }),
  ])

  const lessons = lessonRows ?? []
  const lowBalance = lowBalanceRows ?? []
  const debt = parseDebtSummary(debtJson)
  // Исчерпанный остаток без денег — не долг: в карточку не попадает.
  const debtTop = debt.top.filter((row) => !row.zeroLeft)

  const studentIds = [
    ...new Set([...lessons.map((l) => l.student_id).filter((v): v is string => Boolean(v)), ...lowBalance.map((r) => r.student_id).filter((v): v is string => Boolean(v))]),
  ]
  const teacherIds = [...new Set(lessons.flatMap((l) => [l.teacher_id, l.substitute_teacher_id]).filter((v): v is string => Boolean(v)))]
  const groupIds = [...new Set(lessons.map((l) => l.group_id).filter((v): v is string => Boolean(v)))]

  const [{ data: students }, { data: teachers }, { data: groups }] = await Promise.all([
    studentIds.length ? supabase.rpc('students_brief').in('id', studentIds) : Promise.resolve({ data: [] }),
    teacherIds.length ? supabase.from('teachers').select('id, full_name').in('id', teacherIds) : Promise.resolve({ data: [] }),
    groupIds.length ? supabase.from('groups').select('id, name').in('id', groupIds) : Promise.resolve({ data: [] }),
  ])

  const studentName = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const teacherName = new Map((teachers ?? []).map((t) => [t.id, t.full_name]))
  const groupName = new Map((groups ?? []).map((g) => [g.id, g.name]))

  const done = lessons.filter((l) => l.status === 'done').length
  const cancelled = lessons.filter((l) => l.status === 'cancelled').length
  const upcoming = lessons.filter((l) => l.status === 'planned').slice(0, 3)


  return (
    <div className="space-y-6">
      <div>
        <h1 className="page-title">Дашборд</h1>
        <p className="text-sm text-muted-foreground">{dayInZone(new Date(), timeZone)}, сегодня</p>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        {showLessons ? (
          <Card>
            <CardHeader>
              <CardTitle className="text-3xl">{lessons.length}</CardTitle>
              <CardDescription>
                Занятий сегодня{lessons.length > 0 ? ` · проведено ${done}, отменено ${cancelled}` : ''}
              </CardDescription>
            </CardHeader>
            {upcoming.length > 0 ? (
              <CardContent className="space-y-1 text-sm">
                {upcoming.map((lesson) => {
                  const effectiveTeacher = lesson.substitute_teacher_id ?? lesson.teacher_id
                  const title = lesson.group_id
                    ? (groupName.get(lesson.group_id) ?? 'Группа')
                    : (studentName.get(lesson.student_id ?? '') ?? 'Занятие')
                  return (
                    <p key={lesson.id} className="flex justify-between gap-2">
                      <span className="truncate">
                        {timeInZone(lesson.starts_at, timeZone)} {title}
                      </span>
                      <span className="shrink-0 text-muted-foreground">
                        {effectiveTeacher ? (teacherName.get(effectiveTeacher) ?? '—') : '—'}
                      </span>
                    </p>
                  )
                })}
              </CardContent>
            ) : null}
          </Card>
        ) : null}

        <Card>
          <CardHeader>
            <CardTitle className="text-3xl">{lowBalance.length}</CardTitle>
            <CardDescription>Заканчивается абонемент</CardDescription>
          </CardHeader>
          {lowBalance.length > 0 ? (
            <CardContent className="space-y-1 text-sm">
              {lowBalance.slice(0, 5).map((row) => (
                <Link
                  key={row.student_id}
                  href={`/app/students/${row.student_id}`}
                  className="flex justify-between gap-2 hover:underline"
                >
                  <span className="truncate">{studentName.get(row.student_id ?? '') ?? '—'}</span>
                  <span className="shrink-0 text-muted-foreground">{row.lessons_left} зан.</span>
                </Link>
              ))}
            </CardContent>
          ) : null}
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-3xl text-destructive">{debt.debtorsN}</CardTitle>
            {/* Отказ RPC (миграция не применена, сбой) — не «Долгов нет». */}
            <CardDescription>
              {debtError
                ? toAppError(debtError, 'Не удалось загрузить долги').message
                : debt.debtorsN > 0
                  ? `Долги — ${debtSummaryLine(debt)}`
                  : 'Долгов нет'}
            </CardDescription>
          </CardHeader>
          {debt.debtorsN > 0 ? (
            <CardContent className="space-y-1 text-sm">
              {debtTop.map((row) => (
                <Link
                  key={row.studentId}
                  href={`/app/students/${row.studentId}`}
                  className="flex justify-between gap-2 hover:underline"
                >
                  <span className="truncate">{row.name}</span>
                  <span className="shrink-0 text-destructive">{debtTopAmountLine(row)}</span>
                </Link>
              ))}
              {/* /app/debts открыт owner/admin (страница редиректит остальных). */}
              {canOpenDebts ? (
                <Link href="/app/debts" className="block pt-1 font-medium text-primary hover:underline">
                  Все долги →
                </Link>
              ) : null}
            </CardContent>
          ) : null}
        </Card>
      </div>

      {showLessons && lessons.length === 0 ? (
        <Card>
          <CardContent className="pt-6 text-sm text-muted-foreground">На сегодня занятий не запланировано.</CardContent>
        </Card>
      ) : null}

      <div className="grid gap-4 sm:grid-cols-3">
        {finance ? (
          <>
            <Card>
              <CardHeader>
                <CardTitle className="text-3xl">{formatSom(revenue)}</CardTitle>
                <CardDescription>
                  {t('dashboard', 'revenueMonth')} · {t('dashboard', 'revenueHint')}
                  {visits > 0 ? ` · посещений ${visits}` : ''}
                </CardDescription>
              </CardHeader>
            </Card>
            <Card>
              <CardHeader>
                <CardTitle className="text-3xl">{formatSom(cashTotal)}</CardTitle>
                <CardDescription>
                  {t('dashboard', 'cashMonth')} · {t('dashboard', 'cashHint')}
                </CardDescription>
              </CardHeader>
              <CardContent className="text-sm">
                <Link href="/app/finance" className="font-medium text-primary hover:underline">
                  {t('dashboard', 'toFinance')}
                </Link>
              </CardContent>
            </Card>
          </>
        ) : null}
        <Card>
          <CardHeader>
            <CardTitle className={(overdueCount ?? 0) > 0 ? 'text-3xl text-destructive' : 'text-3xl'}>{overdueCount ?? 0}</CardTitle>
            <CardDescription>
              {(overdueCount ?? 0) > 0 ? t('dashboard', 'overdueInstallments') : t('dashboard', 'overdueNone')}
            </CardDescription>
          </CardHeader>
          {(overdueCount ?? 0) > 0 ? (
            <CardContent className="text-sm">
              <Link href="/app/finance?tab=installments" className="font-medium text-primary hover:underline">
                {t('dashboard', 'toInstallments')}
              </Link>
            </CardContent>
          ) : null}
        </Card>
      </div>
    </div>
  )
}
