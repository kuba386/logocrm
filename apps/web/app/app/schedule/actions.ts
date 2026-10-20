'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError, type ConflictDay } from '@/lib/errors'
import { centerTimeZone, zonedDateTimeToIso } from '@/lib/timezone'
import { attendanceBalanceLabel, type AttendanceBalanceLabel } from '@logocrm/core'

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
/** «2026-10-06T11:00» из <input type="datetime-local">. */
const LOCAL_DATETIME = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/

export async function rescheduleLesson(
  _prev: ScheduleState,
  formData: FormData,
): Promise<ScheduleState> {
  const lessonId = String(formData.get('lessonId') ?? '')
  const startsLocal = LOCAL_DATETIME.exec(String(formData.get('startsAt') ?? ''))
  const endsLocal = LOCAL_DATETIME.exec(String(formData.get('endsAt') ?? ''))
  if (!lessonId || !startsLocal || !endsLocal) return { message: 'Укажите новое время' }

  const supabase = await createClient()

  // <input type="datetime-local"> отдаёт время без пояса — это время центра.
  // Раньше строка уходила в timestamptz как есть и база читала её как UTC:
  // «11:00» сохранялось как 17:00 по Бишкеку. Пояс — из базы, не из браузера.
  const {
    data: { user },
  } = await supabase.auth.getUser()
  const centerId = (user?.app_metadata as { center_id?: string } | undefined)?.center_id ?? ''
  const { data: center } = await supabase.from('centers').select('settings').eq('id', centerId).maybeSingle()
  const timeZone = centerTimeZone(center?.settings)

  const { error } = await supabase.rpc('reschedule_lesson', {
    p_lesson_id: lessonId,
    p_starts_at: zonedDateTimeToIso(startsLocal[1]!, startsLocal[2]!, timeZone),
    p_ends_at: zonedDateTimeToIso(endsLocal[1]!, endsLocal[2]!, timeZone),
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
  /** Метка остатка с учётом услуги занятия (0103); числа — только стойке. */
  balance: string
  balanceTone: AttendanceBalanceLabel['tone']
  /** 0107: отметка со штрафом — владелец может его отменить или вернуть отменённый. */
  feeAttendanceId: string | null
  feeCancelled: boolean
}

export type AttendancePanelData = {
  participants: AttendanceParticipant[]
  statuses: AttendanceStatusOption[]
  /** Отменяет штраф только владелец — cancel_attendance_fee проверяет то же в SQL. */
  canCancelFee?: boolean
} & Partial<AppError>

/**
 * Список участников занятия с текущими отметками и меткой остатка.
 * Отдельный запрос на занятие, а не на неделю: участники нужны только
 * открытой панели, а не всей сетке расписания.
 *
 * Состав и метку отдаёт lesson_attendance_balances (0103): абонемент
 * подбирается тем же правилом, что при отметке, — по услуге и дате занятия.
 * Раньше метка брала student_balance без услуги и показывала остаток
 * логопедического абонемента рядом с кнопками СМК-занятия (жалоба KadamLogo).
 */
export async function getAttendancePanelData(lessonId: string): Promise<AttendancePanelData> {
  const empty = { participants: [], statuses: [] }
  if (!lessonId) return { ...empty, message: 'Занятие не найдено' }

  const supabase = await createClient()

  const [{ data: balanceRows, error: balanceError }, { data: statusRows, error: statusError }, { data: role }] =
    await Promise.all([
      supabase.rpc('lesson_attendance_balances', { p_lesson_id: lessonId }),
      supabase
        .from('attendance_statuses')
        .select('id, code, name, color, is_default')
        .is('deleted_at', null)
        .order('sort'),
      supabase.rpc('my_role'),
    ])

  if (balanceError) return { ...empty, ...toAppError(balanceError, 'Не удалось загрузить участников') }
  if (statusError) return { ...empty, ...toAppError(statusError, 'Не удалось загрузить статусы') }

  const statuses: AttendanceStatusOption[] = (statusRows ?? []).map((row) => ({
    id: row.id,
    code: row.code,
    name: row.name,
    color: row.color,
    isDefault: row.is_default,
  }))

  const rows = balanceRows ?? []
  const studentIds = rows.map((row) => row.student_id)
  if (studentIds.length === 0) return { participants: [], statuses }

  // Под parent этот select отдаёт 0 строк по RLS (0044, attendance_parent_read
  // снята) — сегодня недостижимо: lesson_attendance_balances родителю
  // отказывает, а панель отметки ему не рендерится.
  const [{ data: students }, { data: attendanceRows }] = await Promise.all([
    supabase.from('students').select('id, full_name').in('id', studentIds),
    supabase.from('attendance').select('id, student_id, status_id, comment').eq('lesson_id', lessonId),
  ])

  const nameById = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const statusById = new Map(statuses.map((s) => [s.id, s]))
  const attendanceByStudent = new Map((attendanceRows ?? []).map((row) => [row.student_id, row]))

  const participants: AttendanceParticipant[] = rows
    .map((row) => {
      const mark = attendanceByStudent.get(row.student_id)
      const status = mark?.status_id ? statusById.get(mark.status_id) : undefined
      const label = attendanceBalanceLabel(
        { kind: row.kind, lessonsLeft: row.lessons_left, priceTiyin: row.price_tiyin },
        // Признак из базы, не роль здесь: null у стойки — «безлимит», у специалиста — «скрыто».
        row.numbers,
      )

      return {
        studentId: row.student_id,
        fullName: nameById.get(row.student_id) ?? 'Ученик',
        statusId: mark?.status_id ?? null,
        statusCode: status?.code ?? null,
        comment: mark?.comment ?? null,
        balance: label.text,
        balanceTone: label.tone,
        feeAttendanceId: (row.kind === 'fee' || row.kind === 'fee_cancelled') && mark ? mark.id : null,
        feeCancelled: row.kind === 'fee_cancelled',
      }
    })
    .sort((a, b) => a.fullName.localeCompare(b.fullName, 'ru'))

  return { participants, statuses, canCancelFee: role === 'owner' }
}

/** Отмена штрафа за пропуск — cancel_attendance_fee (0107): только владелец, с причиной. */
export async function cancelAttendanceFee(_prev: ScheduleState, formData: FormData): Promise<ScheduleState> {
  const attendanceId = String(formData.get('attendanceId') ?? '')
  const reason = String(formData.get('reason') ?? '').trim()
  if (!attendanceId) return { message: 'Отметка не найдена' }
  if (!reason) return { message: 'Укажите причину отмены штрафа' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('cancel_attendance_fee', { p_attendance_id: attendanceId, p_reason: reason })
  if (error) return toAppError(error, 'Не удалось отменить штраф')

  revalidatePath('/app/schedule')
  return { message: '', notice: 'Штраф отменён' }
}

/** Вернуть ошибочно отменённый штраф — restore_attendance_fee (0107): только владелец. */
export async function restoreAttendanceFee(_prev: ScheduleState, formData: FormData): Promise<ScheduleState> {
  const attendanceId = String(formData.get('attendanceId') ?? '')
  if (!attendanceId) return { message: 'Отметка не найдена' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('restore_attendance_fee', { p_attendance_id: attendanceId })
  if (error) return toAppError(error, 'Не удалось вернуть штраф')

  revalidatePath('/app/schedule')
  return { message: '', notice: 'Штраф возвращён' }
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
