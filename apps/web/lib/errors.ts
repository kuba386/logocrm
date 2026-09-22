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
// 0050: подписка центра истекла — PostgREST отдаёт PTxxx как HTTP 402.
// Отдельно от 42501: действие у пользователя другое — не «попросить права»,
// а оплатить.
const PAYMENT_REQUIRED = 'PT402'
const CHECK_VIOLATION = '23514'
// Сериализация и deadlock: данные изменились под рукой, повтор обычно проходит.
const SERIALIZATION_FAILURE = '40001'
const DEADLOCK_DETECTED = '40P01'

/**
 * Русские тексты по имени констрейнта. Нативное сообщение Postgres —
 * английское («new row for relation ... violates check constraint ...»),
 * и без этой таблицы оно уходило бы пользователю как есть.
 */
const CHECK_MESSAGES: Record<string, string> = {
  subscriptions_not_overdrawn: 'Списание превышает оплаченное количество занятий',
  subscriptions_lesson_price_consistent: 'Цена занятия не соответствует цене абонемента',
  subscription_freezes_no_overlap: 'Заморозки пересекаются',
  attendance_statuses_default_not_deleted: 'Архивный статус не может быть по умолчанию',
  payments_sign_matches_kind: 'Сумма не соответствует типу операции',
  payments_subscription_needs_student: 'Платёж на абонемент обязан быть привязан к ученику',
  subscriptions_paid_not_negative: 'Возврат превышает оплаченную по абонементу сумму',
  financial_periods_month_is_first_of_month: 'Месяц периода — первое число месяца',
  subscriptions_status_no_frozen_check: 'Статус абонемента меняется только действиями карточки — заморозка и срок считаются по датам',
  subscription_types_lessons_no_period_check: 'У типа абонемента на количество занятий срок действия не указывается',
  payments_amount_not_zero: 'Сумма не может быть нулевой',
  payments_kind_known: 'Неизвестный тип операции',
  expenses_amount_not_zero: 'Сумма не может быть нулевой',
  expenses_kind_known: 'Неизвестный тип операции',
  expenses_sign_matches_kind: 'Сумма не соответствует типу операции',
  teacher_rates_model_known: 'Неизвестная модель ставки',
  teacher_rates_value_not_negative: 'Значение ставки не может быть отрицательным',
  teacher_rates_percent_bounded: 'Процент не может превышать 100',
  salary_adjustments_month_is_first_of_month: 'Месяц корректировки — первое число месяца',
  salary_adjustments_amount_not_zero: 'Сумма не может быть нулевой',
  salary_runs_month_is_first_of_month: 'Месяц начисления — первое число месяца',
  installments_amount_positive: 'Сумма платежа рассрочки должна быть больше нуля',
  installment_plans_base_not_negative: 'Оплачено по абонементу не может быть отрицательным',
  installments_seq_positive: 'Номер платежа рассрочки начинается с единицы',
}

/**
 * Русские тексты по имени уникального ограничения — 23505. Нативный текст
 * («duplicate key value violates unique constraint ...») на русском
 * экране появлялся как есть.
 */
const UNIQUE_MESSAGES: Record<string, string> = {
  payers_center_phone_uniq: 'Плательщик с таким телефоном уже есть',
  installment_plans_one_live_key: 'По абонементу уже есть рассрочка — сначала отмените её',
  subscriptions_sale_key_key: 'Эта продажа уже проведена — обновите страницу',
  installments_plan_seq_key: 'Платёж с таким номером в этом плане рассрочки уже есть',
  salary_runs_teacher_month_live_key:
    'Зарплата за этот месяц уже утверждена — чтобы утвердить заново, владелец отменяет снимок',
  payments_refund_once_key: 'Возврат по этому абонементу уже оформлен',
  platform_payments_one_open_per_center:
    'У центра уже есть открытая заявка на оплату — дождитесь подтверждения или отзовите её',
}

/**
 * Русские тексты по имени внешнего ключа — тот же приём, что CHECK_MESSAGES,
 * для 23503. Появилось с 0013/0014: составные FK там держат инварианты
 * («плательщик не чужому ребёнку», «абонемент не чужого центра»), которые
 * раньше проверялись бы в функции — а нативный текст Postgres для FK ещё
 * менее читаем, чем у CHECK.
 */
const FK_MESSAGES: Record<string, string> = {
  payments_student_payer_fk: 'Этот плательщик не привязан к ребёнку — выберите из списка плательщиков ребёнка',
  payments_subscription_fk: 'Абонемент не найден — возможно, он из другого центра',
  payments_source_fk: 'Источник оплаты не найден',
  payments_payer_fk: 'Плательщик не найден',
  expenses_category_fk: 'Статья расхода не найдена — возможно, она из другого центра',
  expenses_source_fk: 'Источник оплаты не найден',
  teacher_rates_teacher_fk: 'Специалист не найден',
  teacher_rates_service_fk: 'Услуга не найдена — возможно, она из другого центра',
  salary_adjustments_teacher_fk: 'Специалист не найден',
  salary_runs_teacher_fk: 'Специалист не найден',
  attendance_paid_teacher_fk: 'Специалист не найден',
  installments_subscription_fk: 'Абонемент не найден — возможно, он из другого центра',
  installments_student_payer_fk: 'Этот плательщик не привязан к ребёнку — выберите из списка плательщиков ребёнка',
  installments_plan_fk: 'Платёж рассрочки не соответствует своему плану',
  installment_plans_subscription_fk: 'Абонемент не найден — возможно, он из другого центра',
  installment_plans_student_payer_fk: 'Этот плательщик не привязан к ребёнку — выберите из списка плательщиков ребёнка',
  // 0017 завела составные FK на lessons, но не занесла их сюда — тот же
  // класс упущения, что закрывается здесь заодно с 0021.
  lessons_teacher_fk: 'Специалист не найден — возможно, он из другого центра',
  lessons_substitute_teacher_fk: 'Заменяющий специалист не найден — возможно, он из другого центра',
  // 0021 — составные FK на границах тенанта (groups/students/invitations/
  // memberships/lessons/group_students).
  groups_teacher_fk: 'Специалист не найден — возможно, он из другого центра',
  groups_room_fk: 'Кабинет не найден — возможно, он из другого центра',
  groups_service_fk: 'Услуга не найдена — возможно, она из другого центра',
  students_primary_teacher_fk: 'Специалист не найден — возможно, он из другого центра',
  students_payer_fk: 'Плательщик не найден — возможно, он из другого центра',
  invitations_teacher_fk: 'Специалист не найден — возможно, он из другого центра',
  invitations_payer_fk: 'Плательщик не найден — возможно, он из другого центра',
  memberships_teacher_fk: 'Специалист не найден — возможно, он из другого центра',
  memberships_payer_fk: 'Плательщик не найден — возможно, он из другого центра',
  lessons_student_fk: 'Ученик не найден — возможно, он из другого центра',
  lessons_group_fk: 'Группа не найдена — возможно, она из другого центра',
  lessons_room_fk: 'Кабинет не найден — возможно, он из другого центра',
  lessons_service_fk: 'Услуга не найдена — возможно, она из другого центра',
  group_students_group_fk: 'Группа не найдена — возможно, она из другого центра',
  group_students_student_fk: 'Ученик не найден — возможно, он из другого центра',
  // Соседняя дыра того же класса, найденная по пути (0008): не про 0021,
  // но раз FK_MESSAGES всё равно правится в этом PR — дешевле закрыть сразу.
  subscription_types_service_fk: 'Услуга не найдена — возможно, она из другого центра',
}

function checkConstraintName(message: string): string | null {
  const m = /violates check constraint "([a-z0-9_]+)"/i.exec(message)
  return m?.[1] ?? null
}

// Отдельно от checkConstraintName: у EXCLUDE другой текст Postgres
// («violates exclusion constraint», не «check constraint»), и это другой
// errcode (23P01) — но имя всё равно можно завести в CHECK_MESSAGES.
function exclusionConstraintName(message: string): string | null {
  const m = /violates exclusion constraint "([a-z0-9_]+)"/i.exec(message)
  return m?.[1] ?? null
}

function foreignKeyConstraintName(message: string): string | null {
  const m = /violates foreign key constraint "([a-z0-9_]+)"/i.exec(message)
  return m?.[1] ?? null
}

function uniqueConstraintName(message: string): string | null {
  const m = /violates unique constraint "([a-z0-9_]+)"/i.exec(message)
  return m?.[1] ?? null
}
const UNIQUE_VIOLATION = '23505'
const FOREIGN_KEY_VIOLATION = '23503'
const NOT_FOUND = '42704'
const BAD_INPUT = '22023'
const MISSING_INPUT = '22004'
const NOT_NULL_VIOLATION = '23502'

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
      const name = exclusionConstraintName(message)
      if (name && CHECK_MESSAGES[name]) return { message: CHECK_MESSAGES[name] }
      return {
        message: message || 'Слот был занят на момент сохранения, попробуйте ещё раз',
        retryable: true,
      }
    }

    return { message: message || 'Время пересекается с другими занятиями', conflicts }
  }

  if (code === PAYMENT_REQUIRED) {
    return { message: message || 'Подписка центра истекла — доступно только чтение' }
  }

  if (code === FORBIDDEN) {
    return { message: message || 'Недостаточно прав' }
  }

  if (code === CHECK_VIOLATION) {
    const name = checkConstraintName(message)
    if (name && CHECK_MESSAGES[name]) return { message: CHECK_MESSAGES[name] }
    // Исключения из plpgsql с этим кодом уже по-русски; нативный констрейнт —
    // нет, и его текст пользователю не показывается.
    return { message: name ? 'Действие нарушает правила центра' : message || 'Действие нарушает правила центра' }
  }

  if (code === FOREIGN_KEY_VIOLATION) {
    const name = foreignKeyConstraintName(message)
    if (name && FK_MESSAGES[name]) return { message: FK_MESSAGES[name] }
    return { message: name ? 'Ссылка на несуществующую или чужую запись' : message || fallback }
  }

  if (code === SERIALIZATION_FAILURE || code === DEADLOCK_DETECTED) {
    return {
      message: message || 'Данные изменились во время сохранения, попробуйте ещё раз',
      retryable: true,
    }
  }

  if (code === UNIQUE_VIOLATION) {
    const name = uniqueConstraintName(message)
    if (name && UNIQUE_MESSAGES[name]) return { message: UNIQUE_MESSAGES[name] }
    // Нативный констрейнт без текста в карте — русский фолбэк, как у CHECK и
    // FK: английский текст с именем объекта схемы пользователю не показывается.
    return { message: name ? 'Такая запись уже есть' : message || 'Такая запись уже есть' }
  }

  if (code === NOT_FOUND) {
    return { message: message || 'Запись не найдена' }
  }

  if (code === BAD_INPUT || code === MISSING_INPUT || code === NOT_NULL_VIOLATION) {
    return { message: message || 'Проверьте введённые данные — не хватает обязательного поля' }
  }

  return { message: message || fallback }
}
