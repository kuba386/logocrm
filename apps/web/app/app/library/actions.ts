'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'

export type LibraryState = AppError & { notice?: string }

function text(formData: FormData, key: string): string {
  return String(formData.get(key) ?? '').trim()
}

function optional(formData: FormData, key: string): string | undefined {
  const value = text(formData, key)
  return value === '' ? undefined : value
}

/**
 * Каталог упражнений — как «Услуги» (settings/services) по кругу
 * редакторов (owner/admin), но не прямым insert/update: 0040 закрыла
 * exercise_library на грант и завела save_exercise — тем же приёмом, что
 * 0038 сделала для остальных клинических таблиц (reports/stage-7.md, Р10).
 */
export async function saveExercise(_prev: LibraryState, formData: FormData): Promise<LibraryState> {
  const id = text(formData, 'id')
  const title = text(formData, 'title')
  if (title.length < 2) return { message: 'Укажите название упражнения' }

  const ageFrom = optional(formData, 'ageFrom')
  const ageTo = optional(formData, 'ageTo')
  const tags = optional(formData, 'tags')

  const supabase = await createClient()
  const { error } = await supabase.rpc('save_exercise', {
    p_title: title,
    p_id: id || undefined,
    p_area: optional(formData, 'area'),
    p_sound: optional(formData, 'sound'),
    p_stage_code: optional(formData, 'stageCode'),
    p_instructions: optional(formData, 'instructions'),
    p_media_url: optional(formData, 'mediaUrl'),
    p_age_from: ageFrom ? Number(ageFrom) : undefined,
    p_age_to: ageTo ? Number(ageTo) : undefined,
    p_tags: tags ? tags.split(',').map((t) => t.trim()).filter(Boolean) : [],
    p_is_active: formData.get('isActive') === 'on',
  })

  if (error) return toAppError(error, 'Не удалось сохранить упражнение')

  revalidatePath('/app/library')
  return { message: '', notice: 'Сохранено' }
}

export async function assignExerciseToStudent(
  _prev: LibraryState,
  formData: FormData,
): Promise<LibraryState> {
  const studentId = text(formData, 'studentId')
  const exerciseId = text(formData, 'exerciseId')
  const dueInDays = optional(formData, 'dueInDays')
  // Повторный клик «Добавить» (без оптимистичного UI ответ ждём, кнопка не
  // блокирована) не должен выдать упражнение дважды — assign_homework (0038)
  // принимает p_conduct_key и возвращает тот же id повторно, если он уже
  // встречался.
  const conductKey = optional(formData, 'conductKey')

  if (!studentId) return { message: 'Выберите ученика' }

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
    p_exercise_ids: [exerciseId],
    p_due_on: dueOn,
    p_conduct_key: conductKey,
  })

  if (error) return toAppError(error, 'Не удалось выдать задание')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Упражнение добавлено в домашнее задание' }
}
