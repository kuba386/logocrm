'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'

export type CompleteLessonState = AppError & { notice?: string }

/**
 * Один вызов на всё занятие (0039) — не форма с useActionState, а обычная
 * функция: payload собирается в клиентском состоянии (черновик в
 * localStorage переживает уход со страницы), а не в FormData, тот же приём,
 * что previewSeries в ../../actions.ts.
 */
export async function completeLesson(
  lessonId: string,
  payload: Record<string, unknown>,
): Promise<CompleteLessonState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('complete_lesson', {
    p_lesson_id: lessonId,
    p: payload as never,
  })

  if (error) return toAppError(error, 'Не удалось провести занятие')

  revalidatePath('/app/schedule')
  revalidatePath(`/app/schedule/lessons/${lessonId}/complete`)
  return { message: '', notice: 'Занятие проведено' }
}


/**
 * Одноразовый токен для диктовки резюме голосом (0041/0042). Возвращается
 * один раз и уходит в deep-link бота: кнопка, а не код, который надо
 * скопировать, — тот же приём, что у привязки Telegram (0033).
 *
 * Выдача нового токена гасит прежний, поэтому нажать «Записать голосом» у
 * двух детей подряд нельзя: активна всегда последняя запись. На групповом
 * занятии это осознанно — цикл «кнопка → голосовое → кнопка» не даёт
 * модели решать, про кого из детей была диктовка.
 */
export async function requestVoiceNote(
  lessonId: string,
  studentId: string,
): Promise<{ token: string } | AppError> {
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('request_voice_note', {
    p_lesson_id: lessonId,
    p_student_id: studentId,
  })

  if (error) return toAppError(error, 'Не удалось подготовить запись')
  return { token: data as unknown as string }
}
