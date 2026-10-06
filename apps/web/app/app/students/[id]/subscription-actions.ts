'use server'

import { revalidatePath } from 'next/cache'
import { sellSubscriptionPaidSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'
import { t } from '@/lib/messages'
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

/**
 * Продажа с оплатой и рассрочкой одной транзакцией (sell_subscription_paid,
 * 0023/0029): отказ любого шага откатывает всю продажу. Строки графика
 * возвращает сервер — интерфейс перерисовывается по revalidatePath, а не по
 * предпросмотру из браузера. sale_key — ключ идемпотентности против двойного
 * клика: повтор с тем же ключом сервер отбивает.
 */
export async function sellSubscriptionPaid(
  _prev: SubscriptionState,
  formData: FormData,
): Promise<SubscriptionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const paidTiyin = optionalTiyin(formData, 'paidSom') ?? 0
  const withInstallments = formData.get('withInstallments') === 'on'
  const expectedRaw = Number(formData.get('expectedRemainingTiyin') ?? '')

  const parsed = sellSubscriptionPaidSchema.safeParse({
    studentId,
    typeId: String(formData.get('typeId') ?? ''),
    saleKey: String(formData.get('saleKey') ?? ''),
    priceTiyin: optionalTiyin(formData, 'priceSom'),
    startsAt: optional(formData, 'startsAt'),
    paidTiyin,
    sourceId: paidTiyin > 0 ? optional(formData, 'sourceId') : undefined,
    paidOn: optional(formData, 'paidOn'),
    installments: withInstallments ? Number(formData.get('installments') ?? '') : undefined,
    firstDue: withInstallments ? optional(formData, 'firstDue') : undefined,
    stepMonths: withInstallments ? Number(formData.get('stepMonths') || 1) : 1,
    expectedRemainingTiyin: Number.isFinite(expectedRaw) ? expectedRaw : -1,
  })
  if (!parsed.success) {
    return { message: parsed.error.issues[0]?.message ?? t('sale', 'checkForm') }
  }
  const input = parsed.data

  const supabase = await createClient()
  const { error } = await supabase.rpc('sell_subscription_paid', {
    p_type_id: input.typeId,
    p_student_id: input.studentId,
    p_sale_key: input.saleKey,
    p_price_tiyin: input.priceTiyin,
    p_starts_at: input.startsAt,
    p_paid_tiyin: input.paidTiyin > 0 ? input.paidTiyin : undefined,
    p_source_id: input.paidTiyin > 0 ? input.sourceId : undefined,
    p_paid_on: input.paidOn,
    p_installments: input.installments,
    p_first_due: input.firstDue,
    p_step_months: input.stepMonths,
    p_expected_remaining_tiyin: input.expectedRemainingTiyin,
  })

  if (error) return toAppError(error, t('sale', 'failed'))

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: t('sale', 'sold') }
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
  // center_today(): и бессрочная, и датированная идущая заморозка (0092)
  // заканчиваются сегодня. Тот же +1 день, что и во freezeSubscription выше, здесь
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
 * (subscription_summary.refund_tiyin — стоимость неотработанных занятий,
 * не деньги). Не оптимистичный расчёт: если остаток изменился между
 * показом и кликом, RPC откажет сам, а не тихо вернёт другую сумму.
 * Источник — только если реально возвращаются деньги (0030): по
 * неоплаченному абонементу форма его не показывает и не отправляет.
 */
export async function refundSubscription(
  _prev: SubscriptionState,
  formData: FormData,
): Promise<SubscriptionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const subscriptionId = String(formData.get('subscriptionId') ?? '')
  const expectedTiyin = Number(formData.get('expectedTiyin') ?? '')
  const expectedPayoutTiyin = Number(formData.get('expectedPayoutTiyin') ?? '')
  const sourceId = optional(formData, 'sourceId')
  if (!subscriptionId || !Number.isInteger(expectedTiyin) || !Number.isInteger(expectedPayoutTiyin)) {
    return { message: t('sale', 'recalcRefund') }
  }

  // Выплату считает база (subscription_summary.payout_tiyin, 0090): сверка
  // p_expected_payout_tiyin — та сумма, что показали в форме.
  const supabase = await createClient()
  const { error } = await supabase.rpc('refund_subscription', {
    p_id: subscriptionId,
    p_expected_tiyin: expectedTiyin,
    p_expected_payout_tiyin: expectedPayoutTiyin,
    p_source_id: sourceId,
  })

  if (error) return toAppError(error, t('sale', 'refundFailed'))

  revalidatePath(`/app/students/${studentId}`)
  return { message: '', notice: t('sale', 'refundDone') }
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

/**
 * Покрыть неоплаченные занятия этим абонементом (0088). Число и сумму считает
 * база (cover_lesson_debt_preview); expected — остаток долга, по которому
 * открыли форму: изменился — 23514 со свежей суммой, без автоповтора.
 */
export async function coverLessonDebt(_prev: SubscriptionState, formData: FormData): Promise<SubscriptionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const subscriptionId = String(formData.get('subscriptionId') ?? '')
  const count = Number(formData.get('count'))
  const expected = Number(formData.get('expectedRemainingTiyin'))
  if (!subscriptionId || !Number.isInteger(count) || count < 1 || !Number.isInteger(expected)) {
    return { message: 'Обновите страницу и попробуйте снова' }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('cover_lesson_debt', {
    p_subscription_id: subscriptionId,
    p_count: count,
    p_expected_remaining_tiyin: expected,
  })
  if (error) return toAppError(error, 'Не удалось покрыть долг абонементом')

  revalidatePath(`/app/students/${studentId}`)
  revalidatePath('/app/debts')
  revalidatePath('/app')
  return { message: '', notice: count === 1 ? 'Занятие покрыто абонементом' : `Покрыто занятий: ${count}` }
}

/**
 * Оплата по существующему абонементу с карточки (0090 Р7). expected — остаток
 * к оплате, который показали в форме: изменился — 23514, без автоповтора.
 */
export async function acceptSubscriptionPayment(
  _prev: SubscriptionState,
  formData: FormData,
): Promise<SubscriptionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const subscriptionId = String(formData.get('subscriptionId') ?? '')
  const amountTiyin = optionalTiyin(formData, 'amountSom')
  const expectedDueTiyin = Number(formData.get('expectedDueTiyin'))
  const sourceId = optional(formData, 'sourceId')
  const paidOn = optional(formData, 'paidOn')
  if (!subscriptionId || !Number.isInteger(expectedDueTiyin)) {
    return { message: 'Обновите страницу и попробуйте снова' }
  }
  if (amountTiyin == null || amountTiyin <= 0) return { message: 'Укажите сумму больше нуля' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('accept_subscription_payment', {
    p_subscription_id: subscriptionId,
    p_amount_tiyin: amountTiyin,
    p_source_id: sourceId as string,
    p_paid_on: paidOn as string,
    p_expected_due_tiyin: expectedDueTiyin,
  })
  if (error) return toAppError(error, 'Не удалось принять оплату')

  revalidatePath(`/app/students/${studentId}`)
  revalidatePath('/app/debts')
  revalidatePath('/app/finance')
  return { message: '', notice: 'Оплата принята' }
}

/**
 * Списать недоплату за отработанное и закрыть абонемент (0090 Р5) — только
 * владелец, с причиной. Сумму считает база; expected — показанная в форме.
 */
export async function writeOffSubscription(
  _prev: SubscriptionState,
  formData: FormData,
): Promise<SubscriptionState> {
  const studentId = String(formData.get('studentId') ?? '')
  const subscriptionId = String(formData.get('subscriptionId') ?? '')
  const expectedShortfallTiyin = Number(formData.get('expectedShortfallTiyin'))
  const reason = String(formData.get('reason') ?? '').trim()
  if (!subscriptionId || !Number.isInteger(expectedShortfallTiyin)) {
    return { message: 'Обновите страницу и попробуйте снова' }
  }
  if (!reason) return { message: 'Укажите причину списания' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('write_off_subscription', {
    p_id: subscriptionId,
    p_expected_shortfall_tiyin: expectedShortfallTiyin,
    p_reason: reason,
  })
  if (error) return toAppError(error, 'Не удалось списать недоплату')

  revalidatePath(`/app/students/${studentId}`)
  revalidatePath('/app/debts')
  return { message: '', notice: 'Недоплата списана, абонемент закрыт' }
}
