'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError, type AppError } from '@/lib/errors'

export type CatalogState = AppError & { notice?: string }

function text(formData: FormData, key: string): string {
  return String(formData.get(key) ?? '').trim()
}

export async function saveService(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  const name = text(formData, 'name')
  const duration = Number(text(formData, 'durationMin'))
  const priceSom = text(formData, 'priceSom')

  if (name.length < 2) return { message: 'Укажите название услуги' }
  if (!Number.isInteger(duration) || duration < 5) return { message: 'Длительность — от 5 минут' }

  // Деньги в базе — целые тыйыны. В форме сомы, поэтому переводим здесь.
  const priceTiyin = priceSom === '' ? null : Math.round(Number(priceSom) * 100)
  if (priceTiyin !== null && (!Number.isFinite(priceTiyin) || priceTiyin < 0)) {
    return { message: 'Цена должна быть неотрицательным числом' }
  }

  const supabase = await createClient()
  const payload = {
    name,
    duration_min: duration,
    default_price_tiyin: priceTiyin,
    kind: text(formData, 'kind') || 'individual',
    is_active: formData.get('isActive') === 'on',
  }

  const { error } = id
    ? await supabase.from('services').update(payload).eq('id', id)
    : await supabase.from('services').insert(payload)

  if (error) return toAppError(error, 'Не удалось сохранить услугу')

  revalidatePath('/app/settings/services')
  return { message: '', notice: 'Сохранено' }
}

export async function saveRoom(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  const name = text(formData, 'name')
  const capacity = Number(text(formData, 'capacity') || '1')

  if (name.length < 1) return { message: 'Укажите название кабинета' }
  if (!Number.isInteger(capacity) || capacity < 1) return { message: 'Вместимость — от одного места' }

  const supabase = await createClient()
  const payload = { name, capacity, is_active: formData.get('isActive') === 'on' }

  const { error } = id
    ? await supabase.from('rooms').update(payload).eq('id', id)
    : await supabase.from('rooms').insert(payload)

  if (error) return toAppError(error, 'Не удалось сохранить кабинет')

  revalidatePath('/app/settings/rooms')
  return { message: '', notice: 'Сохранено' }
}

export async function saveGroup(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  const name = text(formData, 'name')
  if (name.length < 2) return { message: 'Укажите название группы' }

  const maxStudents = text(formData, 'maxStudents')

  const supabase = await createClient()
  const payload = {
    name,
    service_id: text(formData, 'serviceId') || null,
    teacher_id: text(formData, 'teacherId') || null,
    room_id: text(formData, 'roomId') || null,
    max_students: maxStudents === '' ? null : Number(maxStudents),
    is_active: formData.get('isActive') === 'on',
  }

  const { error } = id
    ? await supabase.from('groups').update(payload).eq('id', id)
    : await supabase.from('groups').insert(payload)

  if (error) return toAppError(error, 'Не удалось сохранить группу')

  revalidatePath('/app/groups')
  return { message: '', notice: 'Сохранено' }
}

/**
 * Добавление ребёнка в группу может упасть по накладке: триггер перепишет
 * состав будущих занятий, и EXCLUDE проверит его слоты.
 */
export async function addStudentToGroup(
  _prev: CatalogState,
  formData: FormData,
): Promise<CatalogState> {
  const groupId = text(formData, 'groupId')
  const studentId = text(formData, 'studentId')
  if (!groupId || !studentId) return { message: 'Выберите ученика' }

  const supabase = await createClient()
  const { error } = await supabase
    .from('group_students')
    .insert({ group_id: groupId, student_id: studentId })

  if (error) return toAppError(error, 'Не удалось добавить в группу')

  revalidatePath('/app/groups')
  return { message: '', notice: 'Ученик добавлен в группу' }
}

export async function removeStudentFromGroup(
  _prev: CatalogState,
  formData: FormData,
): Promise<CatalogState> {
  const id = text(formData, 'membershipId')
  if (!id) return { message: 'Запись не найдена' }

  const supabase = await createClient()
  // Не удаляем, а закрываем период — история состава нужна для отчётов.
  const { error } = await supabase
    .from('group_students')
    .update({ left_at: new Date().toISOString().slice(0, 10) })
    .eq('id', id)

  if (error) return toAppError(error, 'Не удалось убрать из группы')

  revalidatePath('/app/groups')
  return { message: '', notice: 'Ученик выведен из группы' }
}
