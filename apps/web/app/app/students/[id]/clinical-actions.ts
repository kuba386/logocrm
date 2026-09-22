'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'

export type ClinicalState = AppError & { notice?: string }

function optional(formData: FormData, key: string): string | undefined {
  const value = String(formData.get(key) ?? '').trim()
  return value === '' ? undefined : value
}

// --- Диагностика --------------------------------------------------------------

export async function recordDiagnostic(_prev: ClinicalState, formData: FormData): Promise<ClinicalState> {
  const studentId = String(formData.get('studentId') ?? '')
  const conclusion = optional(formData, 'conclusion')

  const sounds: Record<string, string> = {}
  for (const [key, value] of formData.entries()) {
    const match = /^sound_(.+)$/.exec(key)
    if (match && typeof value === 'string' && value) sounds[match[1]!] = value
  }

  const speechAreas: Record<string, number> = {}
  for (const [key, value] of formData.entries()) {
    const match = /^area_(.+)$/.exec(key)
    if (match && typeof value === 'string' && value) speechAreas[match[1]!] = Number(value)
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('record_diagnostic', {
    p_student_id: studentId,
    p_conclusion: conclusion,
    p_sounds: sounds,
    p_speech_areas: speechAreas,
  })

  if (error) return toAppError(error, 'Не удалось записать диагностику')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Диагностика записана' }
}

export async function archiveDiagnostic(studentId: string, id: string): Promise<ClinicalState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('archive_diagnostic', { p_id: id })
  if (error) return toAppError(error, 'Не удалось убрать запись')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Запись убрана' }
}

// --- Цели ------------------------------------------------------------------------

export async function createGoal(_prev: ClinicalState, formData: FormData): Promise<ClinicalState> {
  const studentId = String(formData.get('studentId') ?? '')
  const title = optional(formData, 'title')
  const stageId = optional(formData, 'stageId')
  if (!title) return { message: 'Укажите формулировку цели' }
  if (!stageId) return { message: 'Выберите этап' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('create_goal', {
    p_student_id: studentId,
    p_stage_id: stageId,
    p_title: title,
    p_area: optional(formData, 'area'),
    p_sound: optional(formData, 'sound'),
    p_target_date: optional(formData, 'targetDate'),
  })

  if (error) return toAppError(error, 'Не удалось завести цель')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Цель заведена' }
}

export async function setGoalStatus(studentId: string, goalId: string, status: string): Promise<ClinicalState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('set_goal_status', { p_id: goalId, p_status: status })
  if (error) return toAppError(error, 'Не удалось изменить статус цели')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: status === 'achieved' ? 'Цель отмечена достигнутой' : 'Статус изменён' }
}

export async function archiveGoal(studentId: string, goalId: string): Promise<ClinicalState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('archive_goal', { p_id: goalId })
  if (error) return toAppError(error, 'Не удалось убрать цель')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Цель убрана' }
}

// --- Домашние задания --------------------------------------------------------------

export async function assignHomeworkStandalone(
  _prev: ClinicalState,
  formData: FormData,
): Promise<ClinicalState> {
  const studentId = String(formData.get('studentId') ?? '')
  const freeText = optional(formData, 'freeText')
  const exerciseIds = formData.getAll('exerciseIds').map(String).filter(Boolean)
  const dueInDays = optional(formData, 'dueInDays')

  if (!freeText && exerciseIds.length === 0) {
    return { message: 'Добавьте текст задания или упражнение' }
  }

  const supabase = await createClient()

  // Срок — от сегодняшней даты центра (docs/Database.md: время в поясе
  // центра, не браузера), не от даты клиента.
  let dueOn: string | undefined
  if (dueInDays) {
    const { data: today } = await supabase.rpc('center_today', {})
    if (today) {
      const date = new Date(today)
      date.setDate(date.getDate() + Number(dueInDays))
      dueOn = date.toISOString().slice(0, 10)
    }
  }

  const { error } = await supabase.rpc('assign_homework', {
    p_student_id: studentId,
    p_free_text: freeText,
    p_exercise_ids: exerciseIds,
    p_due_on: dueOn,
  })

  if (error) return toAppError(error, 'Не удалось выдать задание')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Задание выдано' }
}

export async function reviewHomework(
  studentId: string,
  homeworkId: string,
  feedback: string,
): Promise<ClinicalState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('review_homework', {
    p_id: homeworkId,
    p_teacher_feedback: feedback || undefined,
  })
  if (error) return toAppError(error, 'Не удалось отметить проверку')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Задание проверено' }
}

export async function archiveHomework(studentId: string, homeworkId: string): Promise<ClinicalState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('archive_homework', { p_id: homeworkId })
  if (error) return toAppError(error, 'Не удалось убрать задание')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Задание убрано' }
}

// --- Отчёт за месяц (0043) -----------------------------------------------------------

export type MonthlyReport = {
  student_id: string
  student_name: string
  period_month: string
  lessons_total: number
  absences: number
  attendance: { date: string; status: string }[]
  goals: { title: string; stage: string | null; from: number | null; to: number | null; points: number }[]
  notes: { date: string; summary: string }[]
  teacher_comment: string | null
  is_empty: boolean
  generated_at: string
  sent: {
    count: number
    last_at: string
    summary: string
    stats: unknown
    is_stale: boolean
  } | null
}

export type MonthlyReportState = AppError & { report?: MonthlyReport }

// Чтение отдельно от отправки — разные права (0043 Р3): родитель читает,
// но не отправляет.
export async function loadMonthlyReport(studentId: string, month: string): Promise<MonthlyReportState> {
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('student_monthly_report', {
    p_student_id: studentId,
    p_month: month,
  })
  if (error) return toAppError(error, 'Не удалось собрать отчёт')
  return { message: '', report: data as unknown as MonthlyReport }
}

// Повтор — только с явным подтверждением и только администрацией (0043 Р5):
// force сюда приходит из подтверждённого чекбокса, а право решает база.
export async function sendMonthlyReport(
  studentId: string,
  month: string,
  comment: string,
  force: boolean,
): Promise<ClinicalState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('send_monthly_report', {
    p_student_id: studentId,
    p_month: month,
    p_comment: comment.trim() || undefined,
    p_force: force,
  })
  if (error) return toAppError(error, 'Не удалось отправить отчёт')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Отчёт поставлен в очередь на отправку родителю' }
}

// --- Заметки занятий ---------------------------------------------------------------

// Утверждение — единственная точка, после которой резюме уходит родителю, а
// предложенные моделью оценки попадают в goal_progress (0042 Б1). Право —
// в approve_lesson_note: owner/admin или автор черновика.
export async function approveLessonNote(studentId: string, noteId: string): Promise<ClinicalState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('approve_lesson_note', { p_id: noteId })
  if (error) return toAppError(error, 'Не удалось утвердить заметку')

  revalidatePath(`/app/students/${studentId}`)
  // Дойдёт ли резюме — решает доставка (event_messages, 0047), а не форма:
  // отменённое занятие или родитель без канала — тишина по правилам базы.
  return { message: '', notice: 'Заметка утверждена' }
}
