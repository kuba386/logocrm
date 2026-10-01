import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader } from '@/components/ui/card'
import { PageHeader } from '@/components/ui/page-header'
import { PeriodNav } from '@/components/ui/period-nav'
import { centerTimeZone, addDays, isoDayInZone, startOfWeek, formatInTimeZone } from '@/lib/timezone'
import { WEEKDAY_LABELS } from '@/lib/schedule'
import { CreateLessonDialog } from './create-dialog'
import { WeekGrid, type DayColumn } from './week-grid'
import type { LessonView } from './lesson-panel'
import { ScheduleFilters } from './filters'

export const metadata = { title: 'Расписание — LogoCRM' }

/**
 * Одна страница на все роли: ветвление внутри.
 *
 * Три отдельных страницы под admin/teacher/parent неизбежно разъедутся —
 * правку сетки придётся вносить трижды, и на третий раз о ней забудут.
 */
export default async function SchedulePage({
  searchParams,
}: {
  searchParams: Promise<{ week?: string; teacher?: string; room?: string }>
}) {
  const params = await searchParams
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (!role) redirect('/select-center')
  // Бухгалтеру lessons закрыты политикой (0031) — редирект вместо пустой сетки.
  if (role === 'finance') redirect('/app')

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? null
  const { data: center } = await supabase
    .from('centers')
    .select('settings')
    .eq('id', centerId ?? '')
    .maybeSingle()

  const timeZone = centerTimeZone(center?.settings)
  const canManage = role === 'owner' || role === 'admin'

  const weekStart = startOfWeek(params.week ?? isoDayInZone(new Date(), timeZone))
  const weekEnd = addDays(weekStart, 7)

  // Одним запросом на диапазон, а не семью по дням.
  const { data: rows } = await supabase
    .from('lessons')
    .select(
      'id, starts_at, ends_at, status, notes, series_id, teacher_id, substitute_teacher_id, room_id, student_id, group_id',
    )
    .is('deleted_at', null)
    .gte('starts_at', `${weekStart}T00:00:00Z`)
    .lt('starts_at', `${weekEnd}T00:00:00Z`)
    .order('starts_at')

  const [{ data: teachers }, { data: rooms }, { data: services }, { data: students }, { data: groups }] =
    await Promise.all([
      supabase.from('teachers').select('id, full_name').is('deleted_at', null).eq('is_active', true).order('full_name'),
      supabase.from('rooms').select('id, name').is('deleted_at', null).eq('is_active', true).order('name'),
      supabase.from('services').select('id, name, duration_min, kind').is('deleted_at', null).eq('is_active', true).order('name'),
      // Ученики и группы нужны всем ролям — из них собирается заголовок
      // карточки. Раньше запрос шёл только для owner/admin, и специалист
      // видел «11:00 Занятие» без имени ребёнка. Границы держит RLS:
      // students_teacher_read_own отдаёт специалисту только его учеников,
      // students_parent_read_own — родителю только его детей.
      supabase.from('students').select('id, full_name').is('deleted_at', null).order('full_name'),
      supabase.from('groups').select('id, name').is('deleted_at', null).eq('is_active', true).order('name'),
    ])

  const teacherNames = new Map((teachers ?? []).map((t) => [t.id, t.full_name]))
  const roomNames = new Map((rooms ?? []).map((r) => [r.id, r.name]))
  const studentNames = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const groupNames = new Map((groups ?? []).map((g) => [g.id, g.name]))

  const { data: myTeacherId } = await supabase.rpc('my_teacher_id')

  const filtered = (rows ?? []).filter((row) => {
    if (params.teacher && row.teacher_id !== params.teacher && row.substitute_teacher_id !== params.teacher) {
      return false
    }
    // «Без кабинета» — отдельный пункт: такие занятия не должны исчезать.
    if (params.room === 'none') return row.room_id === null
    if (params.room && row.room_id !== params.room) return false
    return true
  })

  // Подтверждения прихода из бота — одним запросом на весь диапазон, не по
  // занятию: правило «список за период — один запрос» (CLAUDE.md).
  const lessonIds = filtered.map((row) => row.id)
  const { data: confirmations } = lessonIds.length
    ? await supabase.from('lesson_confirmations').select('lesson_id').in('lesson_id', lessonIds)
    : { data: [] as { lesson_id: string }[] }

  const confirmedCounts = new Map<string, number>()
  for (const row of confirmations ?? []) {
    confirmedCounts.set(row.lesson_id, (confirmedCounts.get(row.lesson_id) ?? 0) + 1)
  }

  const lessons: LessonView[] = filtered.map((row) => {
    const effectiveTeacher = row.substitute_teacher_id ?? row.teacher_id
    const title = row.group_id
      ? (groupNames.get(row.group_id) ?? 'Группа')
      : (studentNames.get(row.student_id ?? '') ?? 'Занятие')

    return {
      id: row.id,
      day: isoDayInZone(row.starts_at, timeZone),
      startsAt: row.starts_at,
      endsAt: row.ends_at,
      status: row.status,
      title,
      teacherName:
        (teacherNames.get(effectiveTeacher) ?? '—') +
        (row.substitute_teacher_id ? ' (замена)' : ''),
      roomName: row.room_id ? (roomNames.get(row.room_id) ?? null) : null,
      seriesId: row.series_id,
      notes: row.notes,
      isMine: Boolean(myTeacherId) && effectiveTeacher === myTeacherId,
      confirmedCount: confirmedCounts.get(row.id) ?? 0,
    }
  })

  const days: DayColumn[] = Array.from({ length: 7 }, (_, index) => {
    const day = addDays(weekStart, index)
    return {
      day,
      label: formatInTimeZone(`${day}T12:00:00Z`, timeZone, { day: 'numeric', month: 'short' }),
      weekdayLabel: WEEKDAY_LABELS[index]!,
      isToday: day === isoDayInZone(new Date(), timeZone),
    }
  })

  const teacherOptions = (teachers ?? []).map((t) => ({ id: t.id, fullName: t.full_name }))

  const todayIso = isoDayInZone(new Date(), timeZone)
  const weekLabel =
    formatInTimeZone(`${weekStart}T12:00:00Z`, timeZone, { day: 'numeric', month: 'short' }) +
    ' – ' +
    formatInTimeZone(`${addDays(weekStart, 6)}T12:00:00Z`, timeZone, { day: 'numeric', month: 'short' })

  return (
    <div className="space-y-6">
      <PageHeader
        title="Расписание"
        description={
          canManage
            ? 'Накладки по специалисту и кабинету база не даст сохранить.'
            : 'Здесь только ваши занятия.'
        }
        actions={
          canManage ? (
            <CreateLessonDialog
              teachers={teacherOptions}
              rooms={(rooms ?? []).map((r) => ({ id: r.id, name: r.name }))}
              services={(services ?? []).map((s) => ({
                id: s.id,
                name: s.name,
                durationMin: s.duration_min,
                kind: s.kind,
              }))}
              students={(students ?? []).map((s) => ({ id: s.id, fullName: s.full_name }))}
              groups={(groups ?? []).map((g) => ({ id: g.id, name: g.name }))}
            />
          ) : null
        }
      />

      <div className="flex flex-wrap items-center justify-between gap-3">
        <PeriodNav
          label={weekLabel}
          prev={`/app/schedule?week=${addDays(weekStart, -7)}`}
          next={`/app/schedule?week=${addDays(weekStart, 7)}`}
          prevLabel="Предыдущая неделя"
          nextLabel="Следующая неделя"
          today={{
            href: `/app/schedule?week=${todayIso}`,
            label: 'Сегодня',
            current: todayIso >= weekStart && todayIso <= addDays(weekStart, 6),
          }}
        />

        <ScheduleFilters
          week={weekStart}
          teachers={teacherOptions}
          rooms={(rooms ?? []).map((r) => ({ id: r.id, name: r.name }))}
          selectedTeacher={params.teacher ?? ''}
          selectedRoom={params.room ?? ''}
          showTeacherFilter={canManage}
        />
      </div>

      <Card>
        <CardHeader className="pb-3">
          <CardDescription>
            Занятий на неделе: {lessons.length}. Время — по часовому поясу центра.
          </CardDescription>
        </CardHeader>
        <CardContent className="px-3 sm:px-6">
          <WeekGrid
            days={days}
            lessons={lessons}
            timeZone={timeZone}
            canManage={canManage}
            teachers={teacherOptions}
          />
        </CardContent>
      </Card>
    </div>
  )
}
