import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { addDays, dayInZone, isoDayInZone, startOfDayInZone, timeInZone } from '@/lib/timezone'
import { debtSummaryLine, debtTopAmountLine, formatSom, parseDebtSummary } from '@logocrm/core'
import { AlarmClock, Banknote, CalendarDays, Hourglass, TrendingUp, Wallet } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { StatTile } from '@/components/ui/stat-tile'
import { t } from '@/lib/messages'
import { toAppError } from '@/lib/errors'
import { PageHeader } from '@/components/ui/page-header'
import { SetupChecklist } from './setup-checklist'

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
  setupCenterId = null,
}: {
  timeZone: string
  finance?: boolean
  showLessons?: boolean
  /** Ссылка «Все долги →»: тем же условием, что редирект /app/debts (can_payments, 0087). */
  canOpenDebts?: boolean
  /** Плашка «Настройка центра» — только owner/admin: шаги ведут в их настройки. */
  setupCenterId?: string | null
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
  const upcomingAll = lessons.filter((l) => l.status === 'planned' && l.starts_at >= new Date().toISOString())
  const upcoming = upcomingAll.slice(0, 6)


  const debtorsLabel = debtError
    ? toAppError(debtError, 'Не удалось загрузить долги').message
    : debt.debtorsN > 0
      ? debtSummaryLine(debt)
      : t('dashboard', 'debtorsNone')

  return (
    <div className="space-y-6">
      <PageHeader title="Дашборд" description={`${dayInZone(new Date(), timeZone)}, сегодня`} />

      {setupCenterId ? <SetupChecklist centerId={setupCenterId} /> : null}

      <div className="grid grid-cols-[repeat(auto-fit,minmax(9.5rem,1fr))] gap-3">
        {showLessons ? (
          <StatTile
            icon={CalendarDays}
            tone="info"
            value={lessons.length}
            label={t('dashboard', 'lessonsToday')}
            hint={lessons.length > 0 ? t('dashboard', 'lessonsTodayHint', { done, cancelled }) : t('dashboard', 'lessonsNone')}
            href="/app/schedule"
          />
        ) : null}
        <StatTile
          icon={Hourglass}
          tone={lowBalance.length > 0 ? 'warning' : 'neutral'}
          value={lowBalance.length}
          label={t('dashboard', 'lowBalance')}
          hint={t('dashboard', 'lowBalanceHint')}
        />
        {/* /app/debts открыт can_payments (страница редиректит остальных). */}
        <StatTile
          icon={Wallet}
          tone={debt.debtorsN > 0 ? 'danger' : 'neutral'}
          value={debtError ? '—' : debt.debtorsN}
          label={t('dashboard', 'debtors')}
          hint={debtorsLabel}
          href={canOpenDebts ? '/app/debts' : undefined}
        />
        {finance ? (
          <>
            <StatTile
              icon={TrendingUp}
              tone="success"
              value={formatSom(revenue)}
              label={t('dashboard', 'revenueMonth')}
              hint={visits > 0 ? t('dashboard', 'revenueVisits', { visits }) : t('dashboard', 'revenueHint')}
              href="/app/finance"
            />
            <StatTile
              icon={Banknote}
              tone="primary"
              value={formatSom(cashTotal)}
              label={t('dashboard', 'cashMonth')}
              hint={t('dashboard', 'cashHint')}
              href="/app/finance"
            />
          </>
        ) : null}
        <StatTile
          icon={AlarmClock}
          tone={(overdueCount ?? 0) > 0 ? 'danger' : 'neutral'}
          value={overdueCount ?? 0}
          label={t('dashboard', 'overdueInstallments')}
          href="/app/finance?tab=installments"
        />
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        {showLessons ? (
          <Card>
            <CardHeader>
              <CardTitle className="text-base">{t('dashboard', 'upcomingTitle')}</CardTitle>
            </CardHeader>
            <CardContent className="space-y-1 text-sm">
              {upcoming.length === 0 ? <p className="text-muted-foreground">{t('dashboard', 'upcomingNone')}</p> : null}
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
              <Link href="/app/schedule" className="block pt-1 font-medium text-primary hover:underline">
                {upcomingAll.length > upcoming.length
                  ? t('dashboard', 'moreInSchedule', { count: upcomingAll.length - upcoming.length })
                  : t('dashboard', 'toSchedule')}
              </Link>
            </CardContent>
          </Card>
        ) : null}

        <Card>
          <CardHeader>
            <CardTitle className="text-base">{t('dashboard', 'lowBalance')}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm">
            {lowBalance.length === 0 ? <p className="text-muted-foreground">{t('dashboard', 'lowBalanceNone')}</p> : null}
            {lowBalance.slice(0, 5).map((row) => (
              <Link
                key={row.student_id}
                href={`/app/students/${row.student_id}`}
                className="flex justify-between gap-2 hover:underline"
              >
                <span className="truncate">{studentName.get(row.student_id ?? '') ?? '—'}</span>
                <span className="shrink-0 text-muted-foreground">
                  {t('dashboard', 'lessonsLeft', { count: row.lessons_left ?? 0 })}
                </span>
              </Link>
            ))}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">{t('dashboard', 'debtsTitle')}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm">
            {/* Отказ RPC (миграция не применена, сбой) — не «Долгов нет». */}
            {debtError || debt.debtorsN === 0 ? <p className="text-muted-foreground">{debtorsLabel}</p> : null}
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
            {canOpenDebts && debt.debtorsN > 0 ? (
              <Link href="/app/debts" className="block pt-1 font-medium text-primary hover:underline">
                {t('dashboard', 'allDebts')}
              </Link>
            ) : null}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
