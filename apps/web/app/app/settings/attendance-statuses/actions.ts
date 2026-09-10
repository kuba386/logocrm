'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { ATTENDANCE_COLORS } from '@/lib/attendance'
import type { CatalogState } from '../services/actions'

function text(formData: FormData, key: string): string {
  return String(formData.get(key) ?? '').trim()
}

function flag(formData: FormData, key: string): boolean {
  return formData.get(key) === 'on'
}

// mark_attendance ищет статус по коду — код должен быть пригоден как
// идентификатор, а не как подпись: латиница, без пробелов.
const CODE_RE = /^[a-z][a-z0-9_]{1,31}$/

export async function saveAttendanceStatus(
  _prev: CatalogState,
  formData: FormData,
): Promise<CatalogState> {
  const id = text(formData, 'id')
  const code = text(formData, 'code').toLowerCase()
  const name = text(formData, 'name')
  const color = text(formData, 'color')
  const sort = Number(text(formData, 'sort') || '100')
  const isDefault = flag(formData, 'isDefault')

  if (name.length < 2) return { message: 'Укажите название статуса' }
  if (!CODE_RE.test(code)) {
    return { message: 'Код — латиница, цифры и подчёркивание, от 2 до 32 символов, начинается с буквы' }
  }
  if (!ATTENDANCE_COLORS.some((c) => c.value === color)) return { message: 'Выберите цвет из списка' }
  if (!Number.isInteger(sort)) return { message: 'Порядок — целое число' }

  const supabase = await createClient()

  // Уникальность кода держит частичный индекс, но его нативное сообщение
  // английское — проверяем заранее, чтобы ответить по-русски.
  let duplicate = supabase.from('attendance_statuses').select('id').eq('code', code).is('deleted_at', null)
  if (id) duplicate = duplicate.neq('id', id)
  const { data: dup } = await duplicate.maybeSingle()
  if (dup) return { message: `Код «${code}» уже занят другим статусом` }

  // is_default вне гранта на update (0012) — «ровно один default на центр»
  // держит отложенный констрейнт-триггер, менять флаг умеет только
  // set_default_attendance_status. При создании нового статуса колонка
  // ещё доступна через insert, поэтому isDefault учитываем только там.
  const payload = {
    code,
    name,
    color,
    deducts_lesson: flag(formData, 'deductsLesson'),
    pays_teacher: flag(formData, 'paysTeacher'),
    counts_absence: flag(formData, 'countsAbsence'),
    notify_parent: flag(formData, 'notifyParent'),
    sort,
  }

  const { error } = id
    ? await supabase.from('attendance_statuses').update(payload).eq('id', id)
    : await supabase.from('attendance_statuses').insert({ ...payload, is_default: isDefault })

  if (error) return toAppError(error, 'Не удалось сохранить статус')

  revalidatePath('/app/settings/attendance-statuses')
  return { message: '', notice: 'Сохранено' }
}

export async function setDefaultAttendanceStatus(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Статус не найден' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('set_default_attendance_status', { p_id: id })
  if (error) return toAppError(error, 'Не удалось назначить статус по умолчанию')

  revalidatePath('/app/settings/attendance-statuses')
  return { message: '', notice: 'Статус назначен по умолчанию' }
}

export async function archiveAttendanceStatus(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Статус не найден' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('archive_attendance_status', { p_id: id })
  if (error) return toAppError(error, 'Не удалось отправить статус в архив')

  revalidatePath('/app/settings/attendance-statuses')
  return { message: '', notice: 'Статус в архиве' }
}

export async function restoreAttendanceStatus(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Статус не найден' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('restore_attendance_status', { p_id: id })
  if (error) return toAppError(error, 'Не удалось восстановить статус')

  revalidatePath('/app/settings/attendance-statuses')
  return { message: '', notice: 'Статус восстановлен' }
}
