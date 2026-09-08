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
