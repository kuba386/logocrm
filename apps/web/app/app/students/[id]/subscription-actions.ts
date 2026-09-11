'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'
import { addDays } from '@/lib/timezone'

export type SubscriptionState = AppError & { notice?: string }

function optional(formData: FormData, key: string): string | undefined {
  const value = String(formData.get(key) ?? '').trim()
  return value === '' ? undefined : value
}

function optionalTiyin(formData: FormData, key: string): number | undefined {
  const value = optional(formData, key)
  if (value === undefined) return undefined
  const som = Number(value)
  if (!Number.isFinite(som)) return undefined
  return Math.round(som * 100)
}

export async function sellSubscription(
  _prev: SubscriptionState,
  formData: FormData,
): Promise<SubscriptionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const typeId = String(formData.get('typeId') ?? '')
  if (!studentId || !typeId) return { message: 'Выберите тип абонемента' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('sell_subscription', {
    p_student_id: studentId,
    p_type_id: typeId,
    p_price_tiyin: optionalTiyin(formData, 'priceSom'),
    p_starts_at: optional(formData, 'startsAt'),
  })

  if (error) return toAppError(error, 'Не удалось продать абонемент')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Абонемент продан' }
}

export async function freezeSubscription(
  _prev: SubscriptionState,
  formData: FormData,
): Promise<SubscriptionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const subscriptionId = String(formData.get('subscriptionId') ?? '')
  const from = String(formData.get('from') ?? '')
  if (!subscriptionId || !from) return { message: 'Укажите дату начала заморозки' }

  const to = optional(formData, 'to')

  const supabase = await createClient()
  const { error } = await supabase.rpc('freeze_subscription', {
    p_id: subscriptionId,
    p_from: from,
    // Поле «По» в форме — включительно (последний замороженный день), а
    // freeze_subscription строит daterange с исключающей верхней границей:
    // прибавляем день, иначе введённое 15.09 молча заморозило бы только по
    // 14.09. Пустая дата конца — открытый конец, RPC сам трактует NULL как
    // «пока не разморозят».
    p_to: to ? addDays(to, 1) : undefined,
  })

  if (error) return toAppError(error, 'Не удалось заморозить абонемент')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Абонемент заморожен' }
}

export async function unfreezeSubscription(
  _prev: SubscriptionState,
  formData: FormData,
): Promise<SubscriptionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const subscriptionId = String(formData.get('subscriptionId') ?? '')
  if (!subscriptionId) return { message: 'Абонемент не найден' }

  // UnfreezeForm не заводит поле «to» — форма разморозки задним числом ещё
  // не сделана, поэтому optional() здесь всегда undefined и RPC берёт
  // center_today(). Тот же +1 день, что и во freezeSubscription выше, здесь
  // не нужен: p_to у unfreeze_subscription не «последний день заморозки»
  // (включительно), а «с какого дня абонемент снова активен» — то есть уже
  // исключающая граница по смыслу, а не только по типу daterange.
  const supabase = await createClient()
  const { error } = await supabase.rpc('unfreeze_subscription', {
    p_id: subscriptionId,
    p_to: optional(formData, 'to'),
  })

  if (error) return toAppError(error, 'Не удалось разморозить абонемент')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Абонемент разморожен' }
}

/**
 * p_expected_tiyin — сумма, которую только что показали администратору
 * (subscription_summary.refund_tiyin). Не оптимистичный расчёт: если
 * остаток изменился между показом и кликом, RPC откажет сам, а не тихо
 * вернёт другую сумму.
 */
export async function refundSubscription(
  _prev: SubscriptionState,
  formData: FormData,
): Promise<SubscriptionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const subscriptionId = String(formData.get('subscriptionId') ?? '')
  const expectedTiyin = Number(formData.get('expectedTiyin') ?? '')
  if (!subscriptionId || !Number.isInteger(expectedTiyin)) {
    return { message: 'Пересчитайте сумму возврата и попробуйте снова' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('refund_subscription', {
    p_id: subscriptionId,
    p_expected_tiyin: expectedTiyin,
  })

  if (error) return toAppError(error, 'Не удалось оформить возврат')

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: 'Возврат оформлен' }
}

export async function transferRemaining(
  _prev: SubscriptionState,
  formData: FormData,
): Promise<SubscriptionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const subscriptionId = String(formData.get('subscriptionId') ?? '')
  const toStudentId = String(formData.get('toStudentId') ?? '')
  if (!subscriptionId || !toStudentId) return { message: 'Выберите, кому перенести остаток' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('transfer_remaining', {
    p_from: subscriptionId,
    p_to_student: toStudentId,
  })

  if (error) return toAppError(error, 'Не удалось перенести остаток')

  revalidatePath(`/app/students/${studentId}`)
  revalidatePath(`/app/students/${toStudentId}`)
  return { message: '', notice: 'Остаток перенесён' }
}
