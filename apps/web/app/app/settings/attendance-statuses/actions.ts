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

  if (id && !isDefault) {
    // Снять «по умолчанию» с единственного статуса нельзя: массовая отметка
    // без него откажет всей форме. Назначить другой — можно, флаг переедет сам.
    const { data: current } = await supabase
      .from('attendance_statuses')
      .select('is_default')
      .eq('id', id)
      .maybeSingle()
    if (current?.is_default) {
      return { message: 'Сначала назначьте другой статус по умолчанию — центр не может остаться без него' }
    }
  }

  if (isDefault) {
    // Статус по умолчанию один на центр — частичный уникальный индекс.
    // Триггера, снимающего флаг с прежнего, нет, поэтому снимаем здесь до
    // записи. Между двумя запросами центр на миг без default — для
    // справочника терпимо: mark_attendance без статуса откажет, а не
    // поставит случайный.
    let clear = supabase.from('attendance_statuses').update({ is_default: false }).eq('is_default', true)
    if (id) clear = clear.neq('id', id)
    const { error } = await clear
    if (error) return toAppError(error, 'Не удалось снять прежний статус по умолчанию')
  }

  const payload = {
    code,
    name,
    color,
    deducts_lesson: flag(formData, 'deductsLesson'),
    pays_teacher: flag(formData, 'paysTeacher'),
    counts_absence: flag(formData, 'countsAbsence'),
    notify_parent: flag(formData, 'notifyParent'),
    is_default: isDefault,
    sort,
  }

  const { error } = id
    ? await supabase.from('attendance_statuses').update(payload).eq('id', id)
    : await supabase.from('attendance_statuses').insert(payload)

  if (error) return toAppError(error, 'Не удалось сохранить статус')

  revalidatePath('/app/settings/attendance-statuses')
  return { message: '', notice: 'Сохранено' }
}

// Архива здесь нет намеренно: прямой update deleted_at не проходит
// tenant_admin — PostgREST добавляет RETURNING, а using(deleted_at is null)
// не пропускает обновлённую строку. Нужен security-definer RPC по образцу
// archive_student, это следующая миграция.
