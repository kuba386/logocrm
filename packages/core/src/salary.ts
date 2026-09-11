/**
 * Расчёт зарплаты специалиста. Зеркало SQL, не вторая реализация.
 *
 * Источник истины — calc_salary в миграции 0017: выбор действующей ставки,
 * формулы по моделям, кто платит на групповом занятии, причины нулевых
 * строк. Здесь то же самое для мгновенной подсказки в браузере — итог по
 * месяцу и «Утвердить» всегда идут из RPC (salary_summary, approve_salary).
 * Меняешь одну сторону — меняешь обе; общий набор случаев гоняется в Vitest
 * и в pgTAP 0017 с одинаковыми входными данными.
 *
 * Деньги — целые тыйыны. Процент — целое ×100 (3000 = 30.00 %).
 */

export type RateModel = 'per_lesson' | 'per_hour' | 'per_student' | 'percent_payment'

export const RATE_MODELS: readonly RateModel[] = ['per_lesson', 'per_hour', 'per_student', 'percent_payment']

export type TeacherRate = {
  /** null — ставка на все услуги. Конкретная услуга перекрывает общую. */
  serviceId: string | null
  model: RateModel
  /** Тыйыны для per_lesson/per_hour/per_student; проценты×100 для percent_payment. */
  value: number
  /** YYYY-MM-DD. Действует с этой даты включительно. */
  validFrom: string
}

export type AttendanceRow = {
  attendanceId: string
  lessonId: string
  /** YYYY-MM-DD в часовом поясе центра — как lesson_date в SQL. */
  lessonDate: string
  studentId: string
  serviceId: string | null
  /** lessons.status: платит только 'done'. */
  lessonStatus: string
  /** attendance.pays_teacher — следует за статусом отметки. */
  paysTeacher: boolean
  /** attendance.price_tiyin — цена занятия, замороженная при отметке. */
  priceTiyin: number
  /** ends_at − starts_at в секундах — как extract(epoch …) в SQL. */
  durationSec: number
  /** attendance.paid_teacher_id — кому заморожена оплата при отметке. */
  paidTeacherId: string
}

export type SalaryLine = {
  attendanceId: string
  lessonId: string
  lessonDate: string
  studentId: string
  /** null — ставка не найдена. */
  model: RateModel | null
  /**
   * Цена занятия. В SQL для роли teacher скрыта везде, кроме его собственной
   * percent_payment (ADR-005); здесь роль не известна — строки в браузер и
   * так приходят уже отфильтрованными RLS/RPC.
   */
  lessonPriceTiyin: number
  amountTiyin: number
  note: string | null
}

export const NOTE_NOT_DONE = 'занятие не проведено'
export const NOTE_NOT_PAID_STATUS = 'статус не оплачивается'
export const NOTE_NO_RATE = 'ставка не задана'
export const NOTE_PAID_ELSEWHERE = 'оплачено в другой строке занятия'

/**
 * Оплата за час: value × секунды / 3600, округление до ближайшего тыйына —
 * (a·b + d/2) / d целочисленно, как в SQL. Не Math.round: у него .5 идёт
 * от нуля, у формулы — вверх; на неотрицательных совпадают, формула
 * оставлена ради буквального зеркала.
 */
export function perHourAmount(valueTiyinPerHour: number, durationSec: number): number {
  assertInteger(valueTiyinPerHour, 'valueTiyinPerHour')
  assertInteger(durationSec, 'durationSec')
  if (valueTiyinPerHour < 0) throw new RangeError('Ставка не может быть отрицательной')
  if (durationSec < 0) throw new RangeError('Длительность не может быть отрицательной')
  return Math.trunc((valueTiyinPerHour * durationSec + 1800) / 3600)
}

/**
 * Процент от цены занятия: price × percent×100 / 10000, округление до
 * ближайшего тыйына тем же приёмом. 3000 = 30 %.
 */
export function percentAmount(priceTiyin: number, percentX100: number): number {
  assertInteger(priceTiyin, 'priceTiyin')
  assertInteger(percentX100, 'percentX100')
  if (priceTiyin < 0) throw new RangeError('Цена занятия не может быть отрицательной')
  if (percentX100 < 0 || percentX100 > 10000) {
    throw new RangeError('Процент — от 0 до 10000 (100 %)')
  }
  return Math.trunc((priceTiyin * percentX100 + 5000) / 10000)
}

/**
 * Действующая ставка на занятие: подходит по услуге (своя или общая) и уже
 * вступила в силу. Специфичность важнее свежести: частная ставка по услуге
 * побеждает общую, даже если общая новее и даже если частная дешевле. Среди
 * равных по специфичности — самая свежая. Зеркало lateral-подзапроса
 * calc_salary; две ставки одной специфичности в один день исключены
 * констрейнтом teacher_rates_no_same_day_conflict.
 */
export function pickRate(
  rates: readonly TeacherRate[],
  serviceId: string | null,
  lessonDate: string,
): TeacherRate | null {
  const applicable = rates.filter(
    (r) => (r.serviceId === null || r.serviceId === serviceId) && r.validFrom <= lessonDate,
  )
  if (applicable.length === 0) return null
  applicable.sort((a, b) => {
    const specificity = Number(a.serviceId === null) - Number(b.serviceId === null)
    if (specificity !== 0) return specificity
    return a.validFrom < b.validFrom ? 1 : a.validFrom > b.validFrom ? -1 : 0
  })
  return applicable[0] ?? null
}

/**
 * Построчная детализация специалиста за месяц. Одна строка = одна отметка,
 * sum(amount) по строкам — итог без второй арифметики. Строки не
 * отфильтровываются: непроведённое занятие, неоплачиваемый статус и
 * отсутствие ставки дают amount 0 с причиной.
 *
 * `rows` — ВСЕ отметки занятий месяца, где у специалиста есть хоть одна
 * строка (как lesson_scope в SQL), включая строки с чужим paidTeacherId:
 * замена посреди отметок замораживает в одном занятии разных специалистов,
 * а платящая строка per_lesson/per_hour обязана быть одна на занятие, не
 * одна на специалиста. Чужие строки нужны для нумерации и в результат не
 * попадают.
 *
 * Кто платит на групповом занятии — по модели:
 *   per_lesson, per_hour — одна строка занятия: первая ПЛАТЯЩАЯ по studentId,
 *     не первая вообще («болел» на наименьшем id не съедает оплату);
 *   per_student, percent_payment — каждая строка.
 *
 * Порядок строк — как в SQL: дата, занятие, ребёнок. Месяц не проверяется:
 * строки на вход уже отобраны за нужный месяц.
 */
export function calcSalary(
  teacherId: string,
  rows: readonly AttendanceRow[],
  rates: readonly TeacherRate[],
): SalaryLine[] {
  for (const r of rates) {
    if (!RATE_MODELS.includes(r.model)) {
      throw new RangeError(`Неизвестная модель ставки «${String(r.model)}»`)
    }
  }

  const rank = new Map<string, number>()
  const byLesson = new Map<string, AttendanceRow[]>()
  for (const row of rows) {
    const group = byLesson.get(row.lessonId) ?? []
    group.push(row)
    byLesson.set(row.lessonId, group)
  }
  for (const group of byLesson.values()) {
    // Платящие строки получают меньший номер — зеркало
    // order by (not pays_teacher), student_id, по всем строкам занятия.
    const ordered = [...group].sort(
      (a, b) => Number(!a.paysTeacher) - Number(!b.paysTeacher) || compare(a.studentId, b.studentId),
    )
    ordered.forEach((row, i) => rank.set(row.attendanceId, i + 1))
  }

  return rows
    .filter((row) => row.paidTeacherId === teacherId)
    .sort(
      (a, b) =>
        compare(a.lessonDate, b.lessonDate) ||
        compare(a.lessonId, b.lessonId) ||
        compare(a.studentId, b.studentId),
    )
    .map((row) => {
      const rate = pickRate(rates, row.serviceId, row.lessonDate)
      const rn = rank.get(row.attendanceId) ?? 1
      return {
        attendanceId: row.attendanceId,
        lessonId: row.lessonId,
        lessonDate: row.lessonDate,
        studentId: row.studentId,
        model: rate?.model ?? null,
        lessonPriceTiyin: row.priceTiyin,
        amountTiyin: lineAmount(row, rate, rn),
        note: lineNote(row, rate, rn),
      }
    })
}

/** Итог по строкам детализации — без корректировок (они в salary_summary). */
export function salaryTotal(lines: readonly SalaryLine[]): number {
  return lines.reduce((sum, l) => sum + l.amountTiyin, 0)
}

function lineAmount(row: AttendanceRow, rate: TeacherRate | null, rn: number): number {
  if (row.lessonStatus !== 'done') return 0
  if (!row.paysTeacher) return 0
  if (rate === null) return 0
  switch (rate.model) {
    case 'per_lesson':
      return rn === 1 ? rate.value : 0
    case 'per_student':
      return rate.value
    case 'per_hour':
      return rn === 1 ? perHourAmount(rate.value, row.durationSec) : 0
    case 'percent_payment':
      return percentAmount(row.priceTiyin, rate.value)
  }
}

function lineNote(row: AttendanceRow, rate: TeacherRate | null, rn: number): string | null {
  if (row.lessonStatus !== 'done') return NOTE_NOT_DONE
  if (!row.paysTeacher) return NOTE_NOT_PAID_STATUS
  if (rate === null) return NOTE_NO_RATE
  if ((rate.model === 'per_lesson' || rate.model === 'per_hour') && rn !== 1) return NOTE_PAID_ELSEWHERE
  return null
}

function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0
}

function assertInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value)) {
    throw new TypeError(`${name}: ожидалось целое число, получено ${value}`)
  }
}
