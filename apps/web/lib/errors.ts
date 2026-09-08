/**
 * Единственное место, где разбираются ошибки Postgres.
 *
 * Компоненты не парсят ошибки у себя: иначе один и тот же конфликт покажется
 * тремя разными текстами, а новый вызов забудут обработать вовсе.
 */

/** Одно пересечение, как его отдаёт lesson_slot_conflicts. */
export type SlotConflict = {
  kind: 'teacher' | 'room' | 'student'
  lesson_id: string
  starts_at: string
  ends_at: string
  student_id?: string
  student_name?: string
}

export type ConflictDay = {
  day: string
  starts_at: string
  conflicts: SlotConflict[]
}

export type AppError = {
  /** Что показать человеку. Всегда заполнено. */
  message: string
  /** Разбор накладок, если база их прислала. */
  conflicts?: ConflictDay[]
  /** true — имеет смысл обновить предпросмотр и повторить. */
  retryable?: boolean
}

type PostgrestLike = {
  code?: string | null
  message?: string | null
  details?: string | null
  hint?: string | null
}

const CONFLICT = '23P01'
const FORBIDDEN = '42501'
const CHECK_VIOLATION = '23514'
const UNIQUE_VIOLATION = '23505'
const NOT_FOUND = '42704'
const BAD_INPUT = '22023'
const MISSING_INPUT = '22004'

function parseConflicts(details: string | null | undefined): ConflictDay[] | undefined {
  if (!details) return undefined

  try {
    const parsed: unknown = JSON.parse(details)
    if (!Array.isArray(parsed) || parsed.length === 0) return undefined
    return parsed as ConflictDay[]
  } catch {
    // detail бывает и обычным текстом — тогда разбирать нечего.
    return undefined
  }
}

/** Человеческое описание одного пересечения. */
export function conflictLabel(conflict: SlotConflict): string {
  switch (conflict.kind) {
    case 'teacher':
      return 'специалист уже занят'
    case 'room':
      return 'кабинет уже занят'
    case 'student':
      return conflict.student_name
        ? `у ученика ${conflict.student_name} в это время другое занятие`
        : 'у ученика в это время другое занятие'
    default:
      return 'слот занят'
  }
}

export function toAppError(error: PostgrestLike | null | undefined, fallback: string): AppError {
  if (!error) return { message: fallback }

  const code = error.code ?? ''
  const message = error.message ?? ''

  if (code === CONFLICT) {
    const conflicts = parseConflicts(error.details)

    // Гонка: база отказала, но пересчёт уже ничего не нашёл — конкурент
    // откатился. Повторять за пользователя не будем, но подскажем.
    if (!conflicts) {
      return {
        message: message || 'Слот был занят на момент сохранения, попробуйте ещё раз',
        retryable: true,
      }
    }

    return { message: message || 'Время пересекается с другими занятиями', conflicts }
  }

  if (code === FORBIDDEN) {
    return { message: message || 'Недостаточно прав' }
  }

  if (code === CHECK_VIOLATION) {
    return { message: message || 'Действие нарушает правила центра' }
  }

  if (code === UNIQUE_VIOLATION) {
    return { message: message || 'Такая запись уже есть' }
  }

  if (code === NOT_FOUND) {
    return { message: message || 'Запись не найдена' }
  }

  if (code === BAD_INPUT || code === MISSING_INPUT) {
    return { message: message || 'Проверьте введённые данные' }
  }

  return { message: message || fallback }
}
