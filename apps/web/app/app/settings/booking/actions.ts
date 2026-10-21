'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'

export type BookingSettingsState = { message?: string; notice?: string }

const MODES = new Set(['any', 'hours', 'closed'])

/** Горизонт и шаг витрины — set_booking_settings (0109): owner/admin. */
export async function saveBookingSettings(_prev: BookingSettingsState, formData: FormData): Promise<BookingSettingsState> {
  const horizon = Number(formData.get('horizon'))
  const step = Number(formData.get('step'))
  if (!Number.isInteger(horizon) || horizon < 7 || horizon > 31) return { message: 'Горизонт — от 7 до 31 дня' }
  if (![15, 30, 60].includes(step)) return { message: 'Шаг сетки — 15, 30 или 60 минут' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('set_booking_settings', { p_horizon_days: horizon, p_step_min: step })
  if (error) return { message: toAppError(error, 'Не удалось сохранить настройки').message }

  revalidatePath('/app/settings/booking')
  return { notice: 'Сохранено' }
}

/**
 * Режим записи и часы специалиста — set_teacher_booking (0109). Часы
 * передаются только в режиме «по часам»: в других режимах они не трогаются,
 * и возврат в «по часам» поднимает прежнюю неделю.
 */
export async function saveTeacherBooking(
  teacherId: string,
  _prev: BookingSettingsState,
  formData: FormData,
): Promise<BookingSettingsState> {
  const mode = String(formData.get('mode') ?? '')
  if (!MODES.has(mode)) return { message: 'Выберите режим записи' }

  let intervals: { weekday: number; starts_at: string; ends_at: string }[] | null = null
  if (mode === 'hours') {
    try {
      const raw = JSON.parse(String(formData.get('intervals') ?? '[]')) as { weekday: number; starts_at: string; ends_at: string }[]
      intervals = raw
        .filter((i) => i.starts_at && i.ends_at)
        .map((i) => ({ weekday: i.weekday, starts_at: i.starts_at.slice(0, 5), ends_at: i.ends_at.slice(0, 5) }))
    } catch {
      return { message: 'Не удалось прочитать рабочие часы' }
    }
  }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('set_teacher_booking', {
    p_teacher_id: teacherId,
    p_mode: mode,
    p_intervals: intervals ?? undefined,
  })
  if (error) return { message: toAppError(error, 'Не удалось сохранить').message }

  revalidatePath('/app/settings/booking')
  const result = (data ?? {}) as { requests?: unknown[]; lessons?: unknown[] }
  const requests = result.requests?.length ?? 0
  const lessons = result.lessons?.length ?? 0
  if (requests > 0 || lessons > 0) {
    return {
      notice: `Сохранено. Вне новых часов: заявок — ${requests}, занятий — ${lessons}. Ничего не отменено — проверьте их вручную.`,
    }
  }
  return { notice: 'Сохранено' }
}
