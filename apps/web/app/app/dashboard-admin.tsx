import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { addDays, dayInZone, isoDayInZone, startOfDayInZone, timeInZone } from '@/lib/timezone'
import { formatSom } from '@logocrm/core'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

/**
 * Дашборд администратора: сколько занятий сегодня, у кого заканчивается
 * абонемент, у кого долг. Дальше в карточку ученика — не в отдельный экран
 * долгов, его ещё нет (docs/Design/DESIGN.md, «Пробелы»).
 */
export async function AdminDashboard({ timeZone }: { timeZone: string }) {
  const supabase = await createClient()

  const today = isoDayInZone(new Date(), timeZone)
  const todayStart = startOfDayInZone(today, timeZone)
  const todayEnd = startOfDayInZone(addDays(today, 1), timeZone)

  const [{ data: lessonRows }, { data: lowBalanceRows }, { data: debtRows }] = await Promise.all([
    supabase
      .from('lessons')
      .select('id, starts_at, status, teacher_id, substitute_teacher_id, student_id, group_id')
      .is('deleted_at', null)
      .gte('starts_at', todayStart)
      .lt('starts_at', todayEnd)
      .order('starts_at'),
    // lessons_left <= 2 сам исключает и «безлимит», и «нет абонемента» —
    // оба приходят из student_balance как null, а null <= 2 в Postgres
    // ложно (и PostgREST это уважает).
    supabase
      .from('student_balance')
      .select('student_id, lessons_left')
      .lte('lessons_left', 2)
      .order('lessons_left'),
    supabase.from('student_balance').select('student_id, debt_tiyin').gt('debt_tiyin', 0).order('debt_tiyin', { ascending: false }),
  ])

  const lessons = lessonRows ?? []
  const lowBalance = lowBalanceRows ?? []
  const debts = debtRows ?? []

  const studentIds = [
    ...new Set([...lessons.map((l) => l.student_id).filter((v): v is string => Boolean(v)), ...lowBalance.map((r) => r.student_id).filter((v): v is string => Boolean(v)), ...debts.map((r) => r.student_id).filter((v): v is string => Boolean(v))]),
  ]
  const teacherIds = [...new Set(lessons.flatMap((l) => [l.teacher_id, l.substitute_teacher_id]).filter((v): v is string => Boolean(v)))]
  const groupIds = [...new Set(lessons.map((l) => l.group_id).filter((v): v is string => Boolean(v)))]

  const [{ data: students }, { data: teachers }, { data: groups }] = await Promise.all([
    studentIds.length ? supabase.from('students').select('id, full_name').in('id', studentIds) : Promise.resolve({ data: [] }),
    teacherIds.length ? supabase.from('teachers').select('id, full_name').in('id', teacherIds) : Promise.resolve({ data: [] }),
    groupIds.length ? supabase.from('groups').select('id, name').in('id', groupIds) : Promise.resolve({ data: [] }),
  ])

  const studentName = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const teacherName = new Map((teachers ?? []).map((t) => [t.id, t.full_name]))
  const groupName = new Map((groups ?? []).map((g) => [g.id, g.name]))

  const done = lessons.filter((l) => l.status === 'done').length
  const cancelled = lessons.filter((l) => l.status === 'cancelled').length
  const upcoming = lessons.filter((l) => l.status === 'planned').slice(0, 3)

  const debtTotal = debts.reduce((sum, r) => sum + (r.debt_tiyin ?? 0), 0)

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Дашборд</h1>
        <p className="text-sm text-muted-foreground">{dayInZone(new Date(), timeZone)}, сегодня</p>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
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
            <CardTitle className="text-3xl text-destructive">{debts.length}</CardTitle>
            <CardDescription>{debts.length > 0 ? `Долги — ${formatSom(debtTotal)}` : 'Долгов нет'}</CardDescription>
          </CardHeader>
          {debts.length > 0 ? (
            <CardContent className="space-y-1 text-sm">
              {debts.slice(0, 5).map((row) => (
                <Link
                  key={row.student_id}
                  href={`/app/students/${row.student_id}`}
                  className="flex justify-between gap-2 hover:underline"
                >
                  <span className="truncate">{studentName.get(row.student_id ?? '') ?? '—'}</span>
                  <span className="shrink-0 text-destructive">{formatSom(row.debt_tiyin ?? 0)}</span>
                </Link>
              ))}
              <Link href="/app/debts" className="block pt-1 font-medium text-primary hover:underline">
                Все долги →
              </Link>
            </CardContent>
          ) : null}
        </Card>
      </div>

      {lessons.length === 0 ? (
        <Card>
          <CardContent className="pt-6 text-sm text-muted-foreground">На сегодня занятий не запланировано.</CardContent>
        </Card>
      ) : null}
    </div>
  )
}
