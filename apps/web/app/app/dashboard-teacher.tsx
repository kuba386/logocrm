import { createClient } from '@/lib/supabase/server'
import { addDays, dayInZone, isoDayInZone, startOfDayInZone, timeInZone } from '@/lib/timezone'
import Link from 'next/link'
import { ChevronRight } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { EmptyState } from '@/components/ui/empty-state'
import { PageHeader } from '@/components/ui/page-header'
import { StatusBadge } from '@/components/ui/status-badge'
import { cn } from '@/lib/utils'

/**
 * Дашборд специалиста: только свои занятия, без денег и абонементов —
 * это то, с чем он уходит открывать кабинет через дорогу. «Не отмечено» —
 * занятие уже прошло, а посещение никому не проставлено.
 */
export async function TeacherDashboard({ timeZone }: { timeZone: string }) {
  const supabase = await createClient()

  const { data: myTeacherId } = await supabase.rpc('my_teacher_id')

  const today = isoDayInZone(new Date(), timeZone)
  const todayStart = startOfDayInZone(today, timeZone)
  const todayEnd = startOfDayInZone(addDays(today, 1), timeZone)

  const { data: lessonRows } = myTeacherId
    ? await supabase
        .from('lessons')
        .select('id, starts_at, status, student_id, group_id')
        .is('deleted_at', null)
        .gte('starts_at', todayStart)
        .lt('starts_at', todayEnd)
        .or(`teacher_id.eq.${myTeacherId},substitute_teacher_id.eq.${myTeacherId}`)
        .order('starts_at')
    : { data: [] }

  const lessons = lessonRows ?? []

  const studentIds = [...new Set(lessons.map((l) => l.student_id).filter((v): v is string => Boolean(v)))]
  const groupIds = [...new Set(lessons.map((l) => l.group_id).filter((v): v is string => Boolean(v)))]

  // «Не отмечено» — уже началось, не отменено, и в attendance для него
  // нет ни одной строки. Считаем только по уже начавшимся: mark_attendance
  // всё равно откажет на будущем занятии.
  const now = new Date().toISOString()
  const startedIds = lessons.filter((l) => l.status !== 'cancelled' && l.starts_at <= now).map((l) => l.id)

  const [{ data: students }, { data: groups }, { data: markedRows }] = await Promise.all([
    studentIds.length ? supabase.from('students').select('id, full_name').in('id', studentIds) : Promise.resolve({ data: [] }),
    groupIds.length ? supabase.from('groups').select('id, name').in('id', groupIds) : Promise.resolve({ data: [] }),
    startedIds.length
      ? supabase.from('attendance').select('lesson_id').in('lesson_id', startedIds)
      : Promise.resolve({ data: [] as { lesson_id: string }[] }),
  ])

  const studentName = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const groupName = new Map((groups ?? []).map((g) => [g.id, g.name]))
  const markedLessonIds = new Set((markedRows ?? []).map((r) => r.lesson_id))
  const unmarked = lessons.filter((l) => startedIds.includes(l.id) && !markedLessonIds.has(l.id))

  const nowMs = Date.now()
  const lessonTitle = (lesson: (typeof lessons)[number]) =>
    lesson.group_id
      ? (groupName.get(lesson.group_id) ?? 'Группа')
      : (studentName.get(lesson.student_id ?? '') ?? 'Занятие')

  const summary =
    lessons.length === 0
      ? 'занятий нет'
      : `${lessons.length} ${plural(lessons.length, 'занятие', 'занятия', 'занятий')}` +
        (unmarked.length > 0 ? `, не отмечено: ${unmarked.length}` : '')

  return (
    <div className="space-y-6">
      <PageHeader title="Дашборд" description={`${dayInZone(new Date(), timeZone)}, сегодня: ${summary}`} />

      <Card>
        <CardHeader>
          <CardTitle>Сегодня</CardTitle>
        </CardHeader>
        <CardContent className="p-0 pb-2">
          {lessons.length === 0 ? (
            <div className="px-6 pb-4">
              <EmptyState
                title="Сегодня занятий нет"
                description="Занятия на неделю — в расписании."
                action={
                  <Link href="/app/schedule" className={buttonVariants({ variant: 'outline', size: 'sm' })}>
                    Открыть расписание
                  </Link>
                }
              />
            </div>
          ) : (
            <ul className="divide-y divide-border">
              {lessons.map((lesson) => {
                const cancelled = lesson.status === 'cancelled'
                const started = new Date(lesson.starts_at).getTime() <= nowMs
                const status = cancelled
                  ? { tone: 'neutral' as const, label: 'Отменено' }
                  : lesson.status === 'done'
                    ? { tone: 'success' as const, label: 'Проведено' }
                    : !started
                      ? null
                      : markedLessonIds.has(lesson.id)
                        ? { tone: 'info' as const, label: 'Посещение отмечено' }
                        : { tone: 'warning' as const, label: 'Не отмечено' }
                const row = (
                  <>
                    <span className="w-12 shrink-0 font-medium tabular-nums">{timeInZone(lesson.starts_at, timeZone)}</span>
                    <span className={cn('min-w-0 flex-1 truncate', cancelled && 'text-muted-foreground line-through')}>
                      {lessonTitle(lesson)}
                    </span>
                    {status ? <StatusBadge tone={status.tone}>{status.label}</StatusBadge> : null}
                  </>
                )
                // Провести можно только начавшееся занятие: complete_lesson (0039)
                // откажет на будущем, а отменённое проводить нечего.
                return (
                  <li key={lesson.id}>
                    {started && !cancelled ? (
                      <Link
                        href={`/app/schedule/lessons/${lesson.id}/complete`}
                        className="flex min-h-12 items-center gap-3 px-6 py-2 text-sm hover:bg-accent focus-visible:bg-accent focus-visible:outline-none"
                      >
                        {row}
                        <ChevronRight className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                      </Link>
                    ) : (
                      <div className="flex min-h-12 items-center gap-3 px-6 py-2 text-sm">{row}</div>
                    )}
                  </li>
                )
              })}
            </ul>
          )}
        </CardContent>
      </Card>
    </div>
  )
}

function plural(n: number, one: string, few: string, many: string): string {
  const mod10 = n % 10
  const mod100 = n % 100
  if (mod10 === 1 && mod100 !== 11) return one
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few
  return many
}
