import { createClient } from '@/lib/supabase/server'
import { addDays, dayInZone, isoDayInZone, startOfDayInZone, timeInZone } from '@/lib/timezone'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
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

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Дашборд</h1>
        <p className="text-sm text-muted-foreground">{dayInZone(new Date(), timeZone)}, сегодня</p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-3xl">{lessons.length}</CardTitle>
            <CardDescription>Занятий сегодня</CardDescription>
          </CardHeader>
          {lessons.length > 0 ? (
            <CardContent className="space-y-1 text-sm">
              {lessons.map((lesson) => {
                const title = lesson.group_id
                  ? (groupName.get(lesson.group_id) ?? 'Группа')
                  : (studentName.get(lesson.student_id ?? '') ?? 'Занятие')
                return (
                  <p
                    key={lesson.id}
                    className={cn('truncate', lesson.status === 'cancelled' && 'text-muted-foreground line-through')}
                  >
                    {timeInZone(lesson.starts_at, timeZone)} {title}
                  </p>
                )
              })}
            </CardContent>
          ) : null}
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className={cn('text-3xl', unmarked.length > 0 && 'text-destructive')}>
              {unmarked.length}
            </CardTitle>
            <CardDescription>Не отмечено</CardDescription>
          </CardHeader>
          {unmarked.length > 0 ? (
            <CardContent className="space-y-1 text-sm">
              {unmarked.map((lesson) => {
                const title = lesson.group_id
                  ? (groupName.get(lesson.group_id) ?? 'Группа')
                  : (studentName.get(lesson.student_id ?? '') ?? 'Занятие')
                return (
                  <p key={lesson.id} className="truncate">
                    {timeInZone(lesson.starts_at, timeZone)} {title}
                  </p>
                )
              })}
            </CardContent>
          ) : (
            <CardContent className="text-sm text-muted-foreground">Всё отмечено.</CardContent>
          )}
        </Card>
      </div>
    </div>
  )
}
