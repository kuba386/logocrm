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
 * Каталог упражнений: как «Услуги» (settings/services) — редактируют
 * owner/admin, RLS (tenant_admin) сама режет чужой центр и платформенные
 * строки (center_id is null правит только миграция, не экран).
 */
export async function saveExercise(_prev: LibraryState, formData: FormData): Promise<LibraryState> {
  const id = text(formData, 'id')
  const title = text(formData, 'title')
  if (title.length < 2) return { message: 'Укажите название упражнения' }

  const ageFrom = optional(formData, 'ageFrom')
  const ageTo = optional(formData, 'ageTo')
  const tags = optional(formData, 'tags')

  const supabase = await createClient()
  const payload = {
    title,
    area: optional(formData, 'area') ?? null,
    sound: optional(formData, 'sound') ?? null,
    stage_code: optional(formData, 'stageCode') ?? null,
    instructions: optional(formData, 'instructions') ?? null,
    media_url: optional(formData, 'mediaUrl') ?? null,
    age_from: ageFrom ? Number(ageFrom) : null,
    age_to: ageTo ? Number(ageTo) : null,
    tags: tags ? tags.split(',').map((t) => t.trim()).filter(Boolean) : [],
    is_active: formData.get('isActive') === 'on',
  }

  const { error } = id
    ? await supabase.from('exercise_library').update(payload).eq('id', id)
    : await supabase.from('exercise_library').insert(payload)

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
  })

  if (error) return toAppError(error, 'Не удалось выдать задание')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Упражнение добавлено в домашнее задание' }
}
