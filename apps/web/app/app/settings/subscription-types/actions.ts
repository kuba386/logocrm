'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import type { CatalogState } from '../services/actions'

function text(formData: FormData, key: string): string {
  return String(formData.get(key) ?? '').trim()
}

const KINDS = ['lessons', 'period', 'unlimited'] as const
type Kind = (typeof KINDS)[number]

function isKind(value: string): value is Kind {
  return (KINDS as readonly string[]).includes(value)
}

export async function saveSubscriptionType(
  _prev: CatalogState,
  formData: FormData,
): Promise<CatalogState> {
  const id = text(formData, 'id')
  const name = text(formData, 'name')
  const kind = text(formData, 'kind')
  const priceSom = text(formData, 'priceSom')
  const lessonsCount = Number(text(formData, 'lessonsCount'))
  const periodDays = Number(text(formData, 'periodDays'))

  if (name.length < 2) return { message: 'Укажите название типа' }
  if (!isKind(kind)) return { message: 'Выберите вид абонемента' }

  // Деньги в базе — целые тыйыны. В форме сомы, поэтому переводим здесь.
  const priceTiyin = Math.round(Number(priceSom) * 100)
  if (priceSom === '' || !Number.isFinite(priceTiyin) || priceTiyin < 0) {
    return { message: 'Цена должна быть неотрицательным числом' }
  }

  // Те же правила, что check-констрейнты в 0008: пакет обязан знать число
  // занятий, периодный — срок. База откажет и без нас, но по-английски.
  if (kind === 'lessons' && (!Number.isInteger(lessonsCount) || lessonsCount <= 0)) {
    return { message: 'Для пакета занятий укажите их количество' }
  }
  if (kind === 'period' && (!Number.isInteger(periodDays) || periodDays <= 0)) {
    return { message: 'Для периодного абонемента укажите срок в днях' }
  }

  // 0106: услуги — набор галочек; пусто — «любая услуга».
  const serviceIds = formData
    .getAll('serviceIds')
    .map((v) => String(v).trim())
    .filter(Boolean)

  const supabase = await createClient()
  const payload = {
    name,
    kind,
    lessons_count: kind === 'lessons' ? lessonsCount : null,
    period_days: kind === 'period' ? periodDays : null,
    price_tiyin: priceTiyin,
    is_active: formData.get('isActive') === 'on',
  }

  // Новый тип несёт основную услугу в той же строке: если запись набора
  // ниже сорвётся, покрытие сузится до одной услуги, а не расширится до
  // «любой» (ревью 0106 п.3). Набор целиком пишет одна RPC под блокировкой
  // типа — у существующего типа service_id в PATCH не уходит.
  let typeId = id
  if (id) {
    const { error } = await supabase.from('subscription_types').update(payload).eq('id', id)
    if (error) return toAppError(error, 'Не удалось сохранить тип абонемента')
  } else {
    const { data, error } = await supabase
      .from('subscription_types')
      .insert({ ...payload, service_id: serviceIds[0] ?? null })
      .select('id')
      .single()
    if (error) return toAppError(error, 'Не удалось сохранить тип абонемента')
    typeId = data.id
  }

  const { error: servicesError } = await supabase.rpc('set_subscription_type_services', {
    p_type_id: typeId,
    p_service_ids: serviceIds,
  })
  if (servicesError) {
    // Тип уже записан: обновляем список, чтобы повторное «Добавить» не
    // создало второй тип с тем же названием (ревью 0106 п.2).
    revalidatePath('/app/settings/subscription-types')
    const failed = toAppError(servicesError, 'Услуги не записались')
    return {
      message: id
        ? failed.message
        : `Тип создан, но услуги не записались: ${failed.message}. Откройте его в списке и отметьте услуги.`,
    }
  }

  revalidatePath('/app/settings/subscription-types')
  // Форма продажи на карточке ученика читает этот список.
  revalidatePath('/app/students/[id]', 'page')
  return { message: '', notice: 'Сохранено' }
}

export async function archiveSubscriptionType(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Тип абонемента не найден' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('archive_subscription_type', { p_id: id })
  if (error) return toAppError(error, 'Не удалось отправить тип в архив')

  revalidatePath('/app/settings/subscription-types')
  revalidatePath('/app/students/[id]', 'page')
  return { message: '', notice: 'Тип в архиве' }
}

export async function restoreSubscriptionType(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Тип абонемента не найден' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('restore_subscription_type', { p_id: id })
  if (error) return toAppError(error, 'Не удалось восстановить тип')

  revalidatePath('/app/settings/subscription-types')
  revalidatePath('/app/students/[id]', 'page')
  return { message: '', notice: 'Тип восстановлен' }
}
