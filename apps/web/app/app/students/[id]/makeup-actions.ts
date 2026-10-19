'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'

export type MakeupOption = {
  lessonId: string
  startsAt: string
  endsAt: string
  title: string
  teacherName: string | null
  freePlaces: number | null
}

/** Куда можно записать — makeup_lesson_options (0105): места и срок считает база. */
export async function listMakeupOptions(creditId: string): Promise<{ options: MakeupOption[] } & Partial<AppError>> {
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('makeup_lesson_options', { p_credit_id: creditId })
  if (error) return { options: [], ...toAppError(error, 'Не удалось загрузить занятия') }
  return {
    options: (data ?? []).map((row) => ({
      lessonId: row.lesson_id,
      startsAt: row.starts_at,
      endsAt: row.ends_at,
      title: row.title,
      teacherName: row.teacher_name,
      freePlaces: row.free_places,
    })),
  }
}

export type MakeupActionState = { message?: string; notice?: string }

export async function bookMakeup(studentId: string, _prev: MakeupActionState, formData: FormData): Promise<MakeupActionState> {
  const creditId = String(formData.get('creditId') ?? '')
  const lessonId = String(formData.get('lessonId') ?? '')
  if (!creditId || !lessonId) return { message: 'Выберите занятие' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('book_makeup', { p_credit_id: creditId, p_lesson_id: lessonId })
  if (error) return toAppError(error, 'Не удалось записать на отработку')

  revalidatePath(`/app/students/${studentId}`)
  revalidatePath('/app/schedule')
  return { notice: 'Записан на отработку' }
}

export async function cancelMakeupBooking(studentId: string, _prev: MakeupActionState, formData: FormData): Promise<MakeupActionState> {
  const bookingId = String(formData.get('bookingId') ?? '')
  if (!bookingId) return { message: 'Запись не найдена' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('cancel_makeup_booking', { p_booking_id: bookingId })
  if (error) return toAppError(error, 'Не удалось отменить запись')

  revalidatePath(`/app/students/${studentId}`)
  revalidatePath('/app/schedule')
  return { notice: 'Запись на отработку отменена — право снова доступно' }
}
