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
