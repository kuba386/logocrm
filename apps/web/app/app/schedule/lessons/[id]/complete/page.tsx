import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { buttonVariants } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { cn } from '@/lib/utils'
import { dayInZone, timeInZone, centerTimeZone } from '@/lib/timezone'
import { studentAge } from '@/lib/students'
import type { GoalTrend } from '@/lib/goal-trend'
import { CompleteLessonForm, type StudentEntry, type ExerciseOption } from './complete-lesson-form'

export const metadata = { title: 'Провести занятие — LogoCRM' }

function Back() {
  return (
    <Link href="/app/schedule" className={cn(buttonVariants({ variant: 'ghost', size: 'sm' }), 'mb-4')}>
      ← К расписанию
    </Link>
  )
}

function Message({ title, children }: { title: string; children?: React.ReactNode }) {
  return (
    <div className="mx-auto max-w-2xl p-6">
      <Back />
      <Card>
        <CardHeader>
          <CardTitle>{title}</CardTitle>
        </CardHeader>
        {children ? <CardContent>{children}</CardContent> : null}
      </Card>
    </div>
  )
}

export default async function CompleteLessonPage({ params }: { params: Promise<{ id: string }> }) {
  const { id: lessonId } = await params
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const [{ data: role }, { data: myTeacherId }, { data: center }] = await Promise.all([
    supabase.rpc('my_role'),
    supabase.rpc('my_teacher_id'),
    supabase.rpc('current_center'),
  ])
  if (!role || !center) redirect('/select-center')

  const { data: lesson, error: lessonError } = await supabase
    .from('lessons')
    .select(
      'id, teacher_id, substitute_teacher_id, group_id, student_id, service_id, status, starts_at, ends_at',
    )
    .eq('id', lessonId)
    .is('deleted_at', null)
    .maybeSingle()

  if (lessonError || !lesson) notFound()

  const isAdmin = role === 'owner' || role === 'admin'
  const effectiveTeacherId = lesson.substitute_teacher_id ?? lesson.teacher_id
  const isMine = Boolean(myTeacherId) && effectiveTeacherId === myTeacherId

  if (!isAdmin && !isMine) {
    return <Message title="Это занятие ведёт другой специалист" />
  }
  if (role !== 'owner' && role !== 'admin' && role !== 'teacher') {
    return <Message title="Недостаточно прав" />
  }

  const { data: settings } = await supabase.from('centers').select('settings').eq('id', center).maybeSingle()
  const timeZone = centerTimeZone(settings?.settings)

  const when = `${dayInZone(lesson.starts_at, timeZone)}, ${timeInZone(lesson.starts_at, timeZone)}–${timeInZone(lesson.ends_at, timeZone)}`

  if (lesson.status === 'cancelled') {
    return <Message title="Занятие отменено">Провести отменённое занятие нельзя.</Message>
  }
  if (new Date(lesson.starts_at) > new Date()) {
    return (
      <Message title="Занятие ещё не началось">
        Начало — {when}. Открыть экран можно после начала занятия.
      </Message>
    )
  }

  // Состав: групповое — через lesson_participants, одиночное — student_id
  // напрямую (тот же приём, что getAttendancePanelData в ../../actions.ts).
  let studentIds: string[] = []
  if (lesson.group_id) {
    const { data: rows } = await supabase
      .from('lesson_participants')
      .select('student_id')
      .eq('lesson_id', lessonId)
      .is('deleted_at', null)
    studentIds = (rows ?? []).map((r) => r.student_id)
  } else if (lesson.student_id) {
    studentIds = [lesson.student_id]
  }

  if (studentIds.length === 0) {
    return <Message title="В занятии нет участников">Отмечать нечего.</Message>
  }

  if (lesson.status === 'done') {
    return await renderDone(supabase, lessonId, studentIds, when)
  }

  const [
    { data: students },
    { data: attendanceStatuses },
    { data: existingAttendance },
    { data: exercises },
    { data: service },
  ] = await Promise.all([
    supabase.from('students').select('id, full_name, birth_date').in('id', studentIds),
    supabase
      .from('attendance_statuses')
      .select('id, code, name, is_default')
      .is('deleted_at', null)
      .order('sort'),
    supabase.from('attendance').select('student_id, status_id, comment').eq('lesson_id', lessonId),
    supabase
      .from('exercise_library')
      .select('id, title, instructions, sound, stage_code')
      .eq('is_active', true)
      .is('deleted_at', null)
      .order('title'),
    lesson.service_id
      ? supabase.from('services').select('name').eq('id', lesson.service_id).maybeSingle()
      : Promise.resolve({ data: null }),
  ])

  const statusByRow = new Map((attendanceStatuses ?? []).map((s) => [s.id, s]))
  const attendanceByStudent = new Map((existingAttendance ?? []).map((a) => [a.student_id, a]))
  const defaultStatusCode = (attendanceStatuses ?? []).find((s) => s.is_default)?.code ?? null

  const students_: StudentEntry[] = await Promise.all(
    (students ?? []).map(async (student) => {
      const [{ data: goals }, { data: prevNotes }] = await Promise.all([
        supabase.rpc('student_goals_brief', { p_student_id: student.id }),
        supabase
          .from('lesson_notes')
          .select('id, soap, parent_summary, created_at')
          .eq('student_id', student.id)
          .neq('lesson_id', lessonId)
          .is('deleted_at', null)
          .order('created_at', { ascending: false })
          .limit(1),
      ])

      const mark = attendanceByStudent.get(student.id)
      const markedStatus = mark?.status_id ? statusByRow.get(mark.status_id) : undefined
      const prev = prevNotes?.[0]

      return {
        id: student.id,
        fullName: student.full_name,
        age: studentAge(student.birth_date),
        goals: (goals ?? [])
          .filter((g) => g.status === 'active')
          .map((g) => ({
            id: g.id,
            title: g.title,
            sound: g.sound,
            stageTitle: g.stage_title,
            lastScore: g.last_score,
            trend: g.trend as GoalTrend | null,
          })),
        previousNote: prev
          ? {
              parentSummary: prev.parent_summary,
              soapPlan: prev.soap && typeof prev.soap === 'object' ? ((prev.soap as Record<string, unknown>).plan as string | undefined) ?? null : null,
            }
          : null,
        attendanceStatusCode: markedStatus?.code ?? defaultStatusCode,
        attendanceComment: mark?.comment ?? '',
      }
    }),
  )

  const exerciseOptions: ExerciseOption[] = (exercises ?? []).map((e) => ({
    id: e.id,
    title: e.title,
    instructions: e.instructions,
    sound: e.sound,
    stageCode: e.stage_code,
  }))

  return (
    <div className="mx-auto max-w-3xl p-6">
      <Back />
      <div className="mb-6 space-y-1">
        <h1 className="text-2xl font-semibold tracking-tight">Провести занятие</h1>
        <p className="text-sm text-muted-foreground">
          {service?.name ? `${service.name} · ` : ''}
          {when}
        </p>
      </div>
      <CompleteLessonForm
        lessonId={lessonId}
        students={students_}
        attendanceStatuses={(attendanceStatuses ?? []).map((s) => ({ code: s.code, name: s.name }))}
        exercises={exerciseOptions}
        botName={process.env.NEXT_PUBLIC_TELEGRAM_BOT ?? null}
      />
    </div>
  )
}

async function renderDone(
  supabase: Awaited<ReturnType<typeof createClient>>,
  lessonId: string,
  studentIds: string[],
  when: string,
) {
  const [{ data: students }, { data: attendance }, { data: progress }, { data: notes }, { data: homework }] =
    await Promise.all([
      supabase.from('students').select('id, full_name').in('id', studentIds),
      supabase
        .from('attendance')
        .select('student_id, status_id, attendance_statuses(name)')
        .eq('lesson_id', lessonId),
      supabase.from('goal_progress').select('goal_id, score, note, goals(title)').eq('lesson_id', lessonId),
      supabase.from('lesson_notes').select('student_id, parent_summary').eq('lesson_id', lessonId),
      supabase.from('homework').select('student_id, free_text, due_on').eq('lesson_id', lessonId),
    ])

  const nameById = new Map((students ?? []).map((s) => [s.id, s.full_name]))

  return (
    <div className="mx-auto max-w-2xl p-6">
      <Back />
      <Card>
        <CardHeader>
          <CardTitle>Занятие проведено</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm">
          <p className="text-muted-foreground">{when}</p>
          <div>
            <h3 className="font-medium">Посещение</h3>
            <ul className="mt-1 space-y-1">
              {(attendance ?? []).map((a, i) => (
                <li key={i}>
                  {nameById.get(a.student_id) ?? 'Ученик'} —{' '}
                  {(a.attendance_statuses as unknown as { name: string } | null)?.name ?? '—'}
                </li>
              ))}
            </ul>
          </div>
          {(progress ?? []).length > 0 ? (
            <div>
              <h3 className="font-medium">Прогресс по целям</h3>
              <ul className="mt-1 space-y-1">
                {(progress ?? []).map((p, i) => (
                  <li key={i}>
                    {(p.goals as unknown as { title: string } | null)?.title ?? 'Цель'}: {p.score}
                    {p.note ? ` — ${p.note}` : ''}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          {(notes ?? []).length > 0 ? (
            <div>
              <h3 className="font-medium">Заметка</h3>
              <ul className="mt-1 space-y-1">
                {(notes ?? []).map((n, i) => (
                  <li key={i} className="whitespace-pre-line">
                    {nameById.get(n.student_id) ?? 'Ученик'}: {n.parent_summary || '—'}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          {(homework ?? []).length > 0 ? (
            <div>
              <h3 className="font-medium">Домашнее задание</h3>
              <ul className="mt-1 space-y-1">
                {(homework ?? []).map((h, i) => (
                  <li key={i}>
                    {nameById.get(h.student_id) ?? 'Ученик'}: {h.free_text || '—'}
                    {h.due_on ? ` (до ${h.due_on})` : ''}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          <p className="text-xs text-muted-foreground">
            Правка проведённого занятия — отдельными действиями в карточке ученика, здесь пока только
            просмотр.
          </p>
        </CardContent>
      </Card>
    </div>
  )
}
