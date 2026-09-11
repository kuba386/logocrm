'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError, type ConflictDay } from '@/lib/errors'

export type ScheduleState = AppError & { notice?: string }

export type SeriesPreviewRow = {
  day: string
  startsAt: string
  endsAt: string
  conflicts: ConflictDay['conflicts']
}

function optional(formData: FormData, key: string): string | undefined {
  const value = String(formData.get(key) ?? '').trim()
  return value === '' ? undefined : value
}

function seriesPayload(formData: FormData) {
  const weekdays = formData
    .getAll('weekdays')
    .map((value) => Number(value))
    .filter((value) => Number.isInteger(value))

  return {
    service_id: optional(formData, 'serviceId'),
    teacher_id: optional(formData, 'teacherId'),
    room_id: optional(formData, 'roomId'),
    group_id: optional(formData, 'groupId'),
    student_id: optional(formData, 'studentId'),
    first_date: optional(formData, 'firstDate'),
    until: optional(formData, 'until') ?? optional(formData, 'firstDate'),
    time: optional(formData, 'time'),
    weekdays,
    notes: optional(formData, 'notes'),
  }
}

/**
 * Предпросмотр серии. Занятость считает только база — в браузере её не
 * повторяем, иначе диалог покажет «свободно» там, где сохранение откажет.
 */
export async function previewSeries(
  payload: Record<string, unknown>,
): Promise<{ rows?: SeriesPreviewRow[] } & Partial<AppError>> {
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('create_lesson_series_preview', {
    p: payload as never,
  })

  if (error) return toAppError(error, 'Не удалось построить предпросмотр')

  return {
    rows: (data ?? []).map((row) => ({
      day: row.day,
      startsAt: row.starts_at,
      endsAt: row.ends_at,
      conflicts: (row.conflicts ?? []) as ConflictDay['conflicts'],
    })),
  }
}

export async function createSeries(
  _prev: ScheduleState,
  formData: FormData,
): Promise<ScheduleState> {
  const payload = seriesPayload(formData)

  if (!payload.teacher_id) return { message: 'Выберите специалиста' }
  if (!payload.first_date || !payload.time) return { message: 'Укажите дату и время' }
  if (Boolean(payload.group_id) === Boolean(payload.student_id)) {
    return { message: 'Выберите либо ученика, либо группу' }
  }
  if (payload.weekdays.length === 0) return { message: 'Выберите хотя бы один день недели' }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('create_lesson_series', { p: payload as never })

  if (error) return toAppError(error, 'Не удалось создать занятия')

  revalidatePath('/app/schedule')
  const count = data?.length ?? 0
  return { message: '', notice: count === 1 ? 'Занятие создано' : `Создано занятий: ${count}` }
}

export async function cancelLesson(
  _prev: ScheduleState,
  formData: FormData,
): Promise<ScheduleState> {
  const id = String(formData.get('lessonId') ?? '')
  if (!id) return { message: 'Занятие не найдено' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('cancel_lesson', {
    p_id: id,
    p_reason: optional(formData, 'reason'),
  })

  if (error) return toAppError(error, 'Не удалось отменить занятие')

  revalidatePath('/app/schedule')
  return { message: '', notice: 'Занятие отменено' }
}

export async function cancelSeriesFrom(
  _prev: ScheduleState,
  formData: FormData,
): Promise<ScheduleState> {
  const seriesId = String(formData.get('seriesId') ?? '')
  const from = String(formData.get('from') ?? '')
  if (!seriesId || !from) return { message: 'Не хватает данных для отмены серии' }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('cancel_series_from', {
    p_series_id: seriesId,
    p_from: from,
    p_reason: optional(formData, 'reason'),
  })

  if (error) return toAppError(error, 'Не удалось отменить серию')

  revalidatePath('/app/schedule')
  return { message: '', notice: `Отменено занятий: ${data ?? 0}` }
}

export async function substituteTeacher(
  _prev: ScheduleState,
  formData: FormData,
): Promise<ScheduleState> {
  const lessonId = String(formData.get('lessonId') ?? '')
  const teacherId = String(formData.get('teacherId') ?? '')
  if (!lessonId || !teacherId) return { message: 'Выберите специалиста' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('substitute_teacher', {
    p_lesson_id: lessonId,
    p_new_teacher_id: teacherId,
  })

  if (error) return toAppError(error, 'Не удалось назначить замену')

  revalidatePath('/app/schedule')
  return { message: '', notice: 'Замена назначена' }
}

/** Перенос — через RPC: ошибка о накладке приходит тем же форматом. */
export async function rescheduleLesson(
  _prev: ScheduleState,
  formData: FormData,
): Promise<ScheduleState> {
  const lessonId = String(formData.get('lessonId') ?? '')
  const startsAt = String(formData.get('startsAt') ?? '')
  const endsAt = String(formData.get('endsAt') ?? '')
  if (!lessonId || !startsAt || !endsAt) return { message: 'Укажите новое время' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('reschedule_lesson', {
    p_lesson_id: lessonId,
    p_starts_at: startsAt,
    p_ends_at: endsAt,
  })

  if (error) return toAppError(error, 'Не удалось перенести занятие')

  revalidatePath('/app/schedule')
  return { message: '', notice: 'Занятие перенесено' }
}

export async function markLessonStatus(
  _prev: ScheduleState,
  formData: FormData,
): Promise<ScheduleState> {
  const lessonId = String(formData.get('lessonId') ?? '')
  const status = String(formData.get('status') ?? '')
  if (!lessonId || !status) return { message: 'Не хватает данных' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('mark_lesson_status', {
    p_lesson_id: lessonId,
    p_status: status,
    p_notes: optional(formData, 'notes'),
  })

  if (error) return toAppError(error, 'Не удалось изменить статус')

  revalidatePath('/app/schedule')
  return { message: '', notice: status === 'done' ? 'Занятие проведено' : 'Статус изменён' }
}

export type AttendanceStatusOption = {
  id: string
  code: string
  name: string
  color: string
  isDefault: boolean
}

export type AttendanceParticipant = {
  studentId: string
  fullName: string
  statusId: string | null
  statusCode: string | null
  comment: string | null
  /** Родителю и teacher — только слово («есть»/«заканчивается»/«нет»); admin/owner — число занятий. */
  balance: string
}

export type AttendancePanelData = {
  participants: AttendanceParticipant[]
  statuses: AttendanceStatusOption[]
} & Partial<AppError>

/**
 * Список участников занятия с текущими отметками и остатком абонемента.
 * Отдельный запрос на занятие, а не на неделю: участники нужны только
 * открытой панели, а не всей сетке расписания.
 */
export async function getAttendancePanelData(lessonId: string): Promise<AttendancePanelData> {
  const empty = { participants: [], statuses: [] }
  if (!lessonId) return { ...empty, message: 'Занятие не найдено' }

  const supabase = await createClient()

  const [{ data: lesson, error: lessonError }, { data: role }, { data: statusRows, error: statusError }] =
    await Promise.all([
      supabase.from('lessons').select('id, student_id, group_id').eq('id', lessonId).maybeSingle(),
      supabase.rpc('my_role'),
      supabase
        .from('attendance_statuses')
        .select('id, code, name, color, is_default')
        .is('deleted_at', null)
        .order('sort'),
    ])

  if (lessonError) return { ...empty, ...toAppError(lessonError, 'Не удалось загрузить занятие') }
  if (!lesson) return { ...empty, message: 'Занятие не найдено' }
  if (statusError) return { ...empty, ...toAppError(statusError, 'Не удалось загрузить статусы') }

  const statuses: AttendanceStatusOption[] = (statusRows ?? []).map((row) => ({
    id: row.id,
    code: row.code,
    name: row.name,
    color: row.color,
    isDefault: row.is_default,
  }))

  let studentIds: string[] = []
  if (lesson.group_id) {
    const { data: participantRows, error: participantsError } = await supabase
      .from('lesson_participants')
      .select('student_id')
      .eq('lesson_id', lessonId)
      .is('deleted_at', null)
    if (participantsError) return { ...empty, statuses, ...toAppError(participantsError, 'Не удалось загрузить участников') }
    studentIds = (participantRows ?? []).map((row) => row.student_id)
  } else if (lesson.student_id) {
    studentIds = [lesson.student_id]
  }

  if (studentIds.length === 0) return { participants: [], statuses }

  const isAdmin = role === 'owner' || role === 'admin'

  // Admin/owner — число из student_balance (teacher туда не пущен самой
  // вьюхой); teacher/parent — только слово из student_subscription_badge.
  // Разные формы одного и того же результата сведены к одной форме здесь,
  // а не разбираются в JSX компонента.
  const fetchBalanceLabels = async (): Promise<{ studentId: string; label: string }[]> => {
    if (isAdmin) {
      const { data } = await supabase
        .from('student_balance')
        .select('student_id, active_subscription_id, lessons_left, state')
        .in('student_id', studentIds)
      return (data ?? []).map((row) => {
        // lessons_left = null неоднозначен сам по себе: у student_balance
        // это и «абонемент безлимитный», и «абонемента нет вовсе» —
        // отличает только active_subscription_id. DESIGN.md уже наступал
        // на этот же null в другом месте (0010, «Пробелы» по subscription_lessons_left).
        //
        // state считается на СЕГОДНЯ, а отметка в этой же панели — на дату
        // ЗАНЯТИЯ (attendance_fill_and_check, v_lesson_date). Для занятия
        // из другого дня рядом с границей заморозки метка может разойтись
        // с тем, что ответит клик «Пришёл» — известный, не устранённый в
        // этой миграции пробел (0015_freeze_state_unification.sql, раздел
        // 11 в шапке файла); для сегодняшних занятий, подавляющего
        // большинства отметок, метка точна.
        let label: string
        if (!row.active_subscription_id) label = 'нет абонемента'
        else if (row.state === 'frozen') label = 'заморожен'
        else if (row.lessons_left == null) label = 'без лимита'
        else label = `${row.lessons_left} зан.`
        return { studentId: row.student_id ?? '', label }
      })
    }

    return Promise.all(
      studentIds.map(async (studentId) => {
        const { data } = await supabase.rpc('student_subscription_badge', { p_student_id: studentId })
        return { studentId, label: data ?? '—' }
      }),
    )
  }

  const [{ data: students }, { data: attendanceRows }, balanceLabels] = await Promise.all([
    supabase.from('students').select('id, full_name').in('id', studentIds),
    supabase.from('attendance').select('student_id, status_id, comment').eq('lesson_id', lessonId),
    fetchBalanceLabels(),
  ])

  const nameById = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const statusById = new Map(statuses.map((s) => [s.id, s]))
  const attendanceByStudent = new Map((attendanceRows ?? []).map((row) => [row.student_id, row]))
  const balanceByStudent = new Map(balanceLabels.map((row) => [row.studentId, row.label]))

  const participants: AttendanceParticipant[] = studentIds.map((studentId) => {
    const mark = attendanceByStudent.get(studentId)
    const status = mark?.status_id ? statusById.get(mark.status_id) : undefined

    return {
      studentId,
      fullName: nameById.get(studentId) ?? 'Ученик',
      statusId: mark?.status_id ?? null,
      statusCode: status?.code ?? null,
      comment: mark?.comment ?? null,
      balance: balanceByStudent.get(studentId) ?? '—',
    }
  })

  return { participants, statuses }
}

export async function markAttendance(_prev: ScheduleState, formData: FormData): Promise<ScheduleState> {
  const lessonId = String(formData.get('lessonId') ?? '')
  const studentId = String(formData.get('studentId') ?? '')
  const statusCode = String(formData.get('statusCode') ?? '')
  if (!lessonId || !studentId || !statusCode) return { message: 'Не хватает данных' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('mark_attendance', {
    p_lesson_id: lessonId,
    p_student_id: studentId,
    p_status_code: statusCode,
    p_comment: optional(formData, 'comment'),
  })

  if (error) return toAppError(error, 'Не удалось отметить посещение')

  revalidatePath('/app/schedule')
  return { message: '', notice: 'Отмечено' }
}

/** «Все пришли»: статус не передаётся — каждому ставится статус по умолчанию центра. */
export async function markAttendanceAllPresent(
  _prev: ScheduleState,
  formData: FormData,
): Promise<ScheduleState> {
  const lessonId = String(formData.get('lessonId') ?? '')
  const studentIds = formData.getAll('studentId').map(String)
  if (!lessonId || studentIds.length === 0) return { message: 'Нет участников' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('mark_attendance_bulk', {
    p_lesson_id: lessonId,
    p: studentIds.map((studentId) => ({ student_id: studentId })) as never,
  })

  if (error) return toAppError(error, 'Не удалось отметить посещение')

  revalidatePath('/app/schedule')
  return { message: '', notice: 'Отмечены все участники' }
}

export async function teacherVacation(
  _prev: ScheduleState,
  formData: FormData,
): Promise<ScheduleState> {
  const teacherId = String(formData.get('teacherId') ?? '')
  const from = String(formData.get('from') ?? '')
  const to = String(formData.get('to') ?? '')
  if (!teacherId || !from || !to) return { message: 'Укажите период отпуска' }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('teacher_vacation', {
    p_teacher_id: teacherId,
    p_from: from,
    p_to: to,
  })

  if (error) return toAppError(error, 'Не удалось оформить отпуск')

  revalidatePath('/app/schedule')
  revalidatePath('/app/settings/staff')
  return { message: '', notice: `Отменено занятий: ${data ?? 0}` }
}

export async function vacationPreview(
  teacherId: string,
  from: string,
  to: string,
): Promise<{ lessons?: { id: string; startsAt: string; asSubstitute: boolean }[] } & Partial<AppError>> {
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('teacher_vacation_preview', {
    p_teacher_id: teacherId,
    p_from: from,
    p_to: to,
  })

  if (error) return toAppError(error, 'Не удалось получить список занятий')

  return {
    lessons: (data ?? []).map((row) => ({
      id: row.lesson_id,
      startsAt: row.starts_at,
      asSubstitute: row.as_substitute,
    })),
  }
}
