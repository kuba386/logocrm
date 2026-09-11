import { describe, expect, it } from 'vitest'

import {
  NOTE_NO_RATE,
  NOTE_NOT_DONE,
  NOTE_NOT_PAID_STATUS,
  NOTE_PAID_ELSEWHERE,
  calcSalary,
  perHourAmount,
  percentAmount,
  pickRate,
  salaryTotal,
  type AttendanceRow,
  type TeacherRate,
} from './salary'

// Общий набор случаев с pgTAP 0017: те же ставки, длительности и цены.
// Меняется одна сторона — меняется обе.

const T1 = 'aaaaaaaa-0000-0000-0000-000000000001'
const T2 = 'aaaaaaaa-0000-0000-0000-000000000002'
const SERVICE_1 = 'f1111111-0000-0000-0000-000000000001'
const SERVICE_2 = 'f1111111-0000-0000-0000-000000000002'
const SERVICE_3 = 'f1111111-0000-0000-0000-000000000003'
const CHILD_1 = 'eeeeeeee-0000-0000-0000-000000000001'
const CHILD_2 = 'eeeeeeee-0000-0000-0000-000000000002'
const CHILD_3 = 'eeeeeeee-0000-0000-0000-000000000003'

const row = (over: Partial<AttendanceRow> & Pick<AttendanceRow, 'attendanceId' | 'lessonId'>): AttendanceRow => ({
  lessonDate: '2026-08-11',
  studentId: CHILD_1,
  serviceId: SERVICE_1,
  lessonStatus: 'done',
  paysTeacher: true,
  priceTiyin: 50_000,
  durationSec: 45 * 60,
  paidTeacherId: T1,
  ...over,
})

const rate = (over: Partial<TeacherRate> & Pick<TeacherRate, 'model' | 'value'>): TeacherRate => ({
  serviceId: null,
  validFrom: '2026-08-01',
  ...over,
})

describe('perHourAmount — формула (a·b + d/2) / d', () => {
  it('47 минут × 400 сом/час = 31333.33 → 31333 (тест 11 pgTAP)', () => {
    expect(perHourAmount(40_000, 47 * 60)).toBe(31_333)
  })

  it('ровно час — ровно ставка', () => {
    expect(perHourAmount(40_000, 3600)).toBe(40_000)
  })

  it('половина тыйына округляется вверх, не отбрасывается', () => {
    // 1 тыйын/час × 1800 с = 0.5 → 1
    expect(perHourAmount(1, 1800)).toBe(1)
  })

  it('нулевая длительность — ноль', () => {
    expect(perHourAmount(40_000, 0)).toBe(0)
  })

  it('дробные и отрицательные значения — ошибка, а не тихий мусор', () => {
    expect(() => perHourAmount(40_000.5, 3600)).toThrow(TypeError)
    expect(() => perHourAmount(-1, 3600)).toThrow(RangeError)
    expect(() => perHourAmount(40_000, -1)).toThrow(RangeError)
  })
})

describe('percentAmount — процент ×100 от цены занятия', () => {
  it('30 % от 500 сом = 150 сом', () => {
    expect(percentAmount(50_000, 3000)).toBe(15_000)
  })

  it('безлимитный абонемент: цена занятия 0 → 0, не ошибка (тест 12 pgTAP)', () => {
    expect(percentAmount(0, 3000)).toBe(0)
  })

  it('округление до ближайшего тыйына: 33.33 % от 100 → 33', () => {
    expect(percentAmount(100, 3333)).toBe(33)
  })

  it('половина тыйына — вверх: 0.5 % от 100 = 0.5 → 1', () => {
    expect(percentAmount(100, 50)).toBe(1)
  })

  it('процент вне 0..100 — ошибка (зеркало teacher_rates_percent_bounded)', () => {
    expect(() => percentAmount(50_000, 10_001)).toThrow(RangeError)
    expect(() => percentAmount(50_000, -1)).toThrow(RangeError)
  })
})

describe('pickRate — специфичность важнее свежести (тесты 4-5 pgTAP)', () => {
  const rates: TeacherRate[] = [
    rate({ model: 'per_lesson', value: 20_000, validFrom: '2026-08-01' }),
    rate({ model: 'per_lesson', value: 25_000, serviceId: SERVICE_1, validFrom: '2026-07-22' }),
    rate({ model: 'per_lesson', value: 15_000, serviceId: SERVICE_3, validFrom: '2026-07-22' }),
  ]

  it('частная по услуге старше и дороже общей — побеждает', () => {
    expect(pickRate(rates, SERVICE_1, '2026-08-11')?.value).toBe(25_000)
  })

  it('частная старше и ДЕШЕВЛЕ общей — тоже побеждает', () => {
    expect(pickRate(rates, SERVICE_3, '2026-08-11')?.value).toBe(15_000)
  })

  it('услуга без частной ставки берёт общую', () => {
    expect(pickRate(rates, SERVICE_2, '2026-08-11')?.value).toBe(20_000)
  })

  it('ставка, вступающая в силу позже занятия, не действует', () => {
    expect(pickRate(rates, SERVICE_2, '2026-07-31')).toBeNull()
  })

  it('среди равных по специфичности — самая свежая', () => {
    const two = [
      rate({ model: 'per_lesson', value: 30_000, validFrom: '2026-08-01' }),
      rate({ model: 'per_lesson', value: 35_000, validFrom: '2026-08-10' }),
    ]
    expect(pickRate(two, SERVICE_1, '2026-08-11')?.value).toBe(35_000)
    expect(pickRate(two, SERVICE_1, '2026-08-05')?.value).toBe(30_000)
  })

  it('ставка действует с даты включительно', () => {
    expect(pickRate(rates, SERVICE_2, '2026-08-01')?.value).toBe(20_000)
  })
})

describe('calcSalary — чек-лист этапа (тесты 1-3, 6 pgTAP)', () => {
  const rates = [rate({ model: 'per_lesson', value: 30_000 })]
  const rows = [0, 1, 2, 3, 4, 5].map((i) =>
    row({
      attendanceId: `a${i}`,
      lessonId: `l${i}`,
      paysTeacher: i !== 5,
    }),
  )

  it('300 сом × 5 «пришёл» + 1 «болел» = 1500 сом, шесть строк', () => {
    const lines = calcSalary(T1, rows, rates)
    expect(lines).toHaveLength(6)
    expect(salaryTotal(lines)).toBe(150_000)
  })

  it('«болел» — строка на месте, amount 0, причина явная', () => {
    const sick = calcSalary(T1, rows, rates).find((l) => l.attendanceId === 'a5')
    expect(sick?.amountTiyin).toBe(0)
    expect(sick?.note).toBe(NOTE_NOT_PAID_STATUS)
  })

  it('модель в строке — per_lesson', () => {
    expect(calcSalary(T1, rows, rates)[0]?.model).toBe('per_lesson')
  })
})

describe('calcSalary — групповое занятие', () => {
  const groupRow = (attendanceId: string, studentId: string, paysTeacher = true): AttendanceRow =>
    row({ attendanceId, lessonId: 'g1', studentId, serviceId: SERVICE_2, paysTeacher, durationSec: 3600 })

  it('per_student: каждая строка платит — 100 сом × 3 = 300 сом (тесты 13-14)', () => {
    const lines = calcSalary(
      T1,
      [groupRow('a1', CHILD_1), groupRow('a2', CHILD_2), groupRow('a3', CHILD_3)],
      [rate({ model: 'per_student', value: 10_000 })],
    )
    expect(lines).toHaveLength(3)
    expect(salaryTotal(lines)).toBe(30_000)
    expect(lines.every((l) => l.note === null)).toBe(true)
  })

  it('per_lesson: «болел» на наименьшем id не съедает оплату — платит первая ПЛАТЯЩАЯ (тесты 15-18)', () => {
    const lines = calcSalary(
      T1,
      [groupRow('a1', CHILD_1, false), groupRow('a2', CHILD_2), groupRow('a3', CHILD_3)],
      [rate({ model: 'per_lesson', value: 45_000 })],
    )
    const by = (id: string) => lines.find((l) => l.attendanceId === id)
    expect(salaryTotal(lines)).toBe(45_000)
    expect(by('a1')?.note).toBe(NOTE_NOT_PAID_STATUS)
    expect(by('a2')?.amountTiyin).toBe(45_000)
    expect(by('a3')?.amountTiyin).toBe(0)
    expect(by('a3')?.note).toBe(NOTE_PAID_ELSEWHERE)
  })

  it('per_lesson: все «болели» — ни одной строки «оплачено в другой строке»', () => {
    const lines = calcSalary(
      T1,
      [groupRow('a1', CHILD_1, false), groupRow('a2', CHILD_2, false)],
      [rate({ model: 'per_lesson', value: 45_000 })],
    )
    expect(salaryTotal(lines)).toBe(0)
    expect(lines.every((l) => l.note === NOTE_NOT_PAID_STATUS)).toBe(true)
  })

  it('per_hour: час работы один, детей трое — 400 сом, не 1200 (тесты 19-20)', () => {
    const lines = calcSalary(
      T1,
      [groupRow('a1', CHILD_1), groupRow('a2', CHILD_2), groupRow('a3', CHILD_3)],
      [rate({ model: 'per_hour', value: 40_000 })],
    )
    expect(salaryTotal(lines)).toBe(40_000)
    expect(lines.filter((l) => l.amountTiyin > 0)).toHaveLength(1)
    expect(lines.filter((l) => l.note === NOTE_PAID_ELSEWHERE)).toHaveLength(2)
  })

  it('percent_payment: каждая строка — процент от цены своего абонемента', () => {
    const lines = calcSalary(
      T1,
      [
        groupRow('a1', CHILD_1),
        { ...groupRow('a2', CHILD_2), priceTiyin: 0 },
        { ...groupRow('a3', CHILD_3), priceTiyin: 30_000 },
      ],
      [rate({ model: 'percent_payment', value: 3000 })],
    )
    expect(lines.map((l) => l.amountTiyin)).toEqual([15_000, 0, 9_000])
  })

  it('замена посреди отметок: одна оплата на занятие, не на специалиста (тесты 60-62)', () => {
    // Ребёнок 1 отмечен при T1, затем замена на T2, затем дети 2 и 3.
    const rows = [
      groupRow('a1', CHILD_1),
      { ...groupRow('a2', CHILD_2), paidTeacherId: T2 },
      { ...groupRow('a3', CHILD_3), paidTeacherId: T2 },
    ]
    const rates = [rate({ model: 'per_lesson', value: 45_000 })]

    const mine = calcSalary(T1, rows, rates)
    const theirs = calcSalary(T2, rows, rates)

    expect(mine.map((l) => l.attendanceId)).toEqual(['a1'])
    expect(salaryTotal(mine)).toBe(45_000)
    expect(theirs.map((l) => l.attendanceId)).toEqual(['a2', 'a3'])
    expect(salaryTotal(theirs)).toBe(0)
    expect(theirs.every((l) => l.note === NOTE_PAID_ELSEWHERE)).toBe(true)
  })

  it('чужие строки в результат не попадают, даже если платящая — среди них', () => {
    const rows = [
      { ...groupRow('a1', CHILD_1), paidTeacherId: T2 },
      groupRow('a2', CHILD_2),
    ]
    const mine = calcSalary(T1, rows, [rate({ model: 'per_hour', value: 40_000 })])
    expect(mine).toHaveLength(1)
    expect(mine[0]?.amountTiyin).toBe(0)
    expect(mine[0]?.note).toBe(NOTE_PAID_ELSEWHERE)
  })
})

describe('calcSalary — нулевые строки не исчезают (тесты 21-25 pgTAP)', () => {
  it('без ставки — строка есть, amount 0, «ставка не задана»', () => {
    const [line] = calcSalary(T1, [row({ attendanceId: 'a1', lessonId: 'l1' })], [])
    expect(line?.amountTiyin).toBe(0)
    expect(line?.model).toBeNull()
    expect(line?.note).toBe(NOTE_NO_RATE)
  })

  it('занятие не в статусе done — amount 0, «занятие не проведено», даже при ставке и «пришёл»', () => {
    const [line] = calcSalary(
      T1,
      [row({ attendanceId: 'a1', lessonId: 'l1', lessonStatus: 'planned' })],
      [rate({ model: 'per_lesson', value: 30_000 })],
    )
    expect(line?.amountTiyin).toBe(0)
    expect(line?.note).toBe(NOTE_NOT_DONE)
  })

  it('порядок причин — как в SQL: непроведённое занятие раньше статуса и ставки', () => {
    const [line] = calcSalary(
      T1,
      [row({ attendanceId: 'a1', lessonId: 'l1', lessonStatus: 'planned', paysTeacher: false })],
      [],
    )
    expect(line?.note).toBe(NOTE_NOT_DONE)
  })
})

describe('calcSalary — порядок и ошибки', () => {
  it('строки отсортированы по дате, занятию, ребёнку — как order by в SQL', () => {
    const lines = calcSalary(
      T1,
      [
        row({ attendanceId: 'b', lessonId: 'l2', lessonDate: '2026-08-12', studentId: CHILD_2 }),
        row({ attendanceId: 'a', lessonId: 'l2', lessonDate: '2026-08-12', studentId: CHILD_1 }),
        row({ attendanceId: 'c', lessonId: 'l1', lessonDate: '2026-08-11' }),
      ],
      [rate({ model: 'per_student', value: 10_000 })],
    )
    expect(lines.map((l) => l.attendanceId)).toEqual(['c', 'a', 'b'])
  })

  it('неизвестная модель — громкая ошибка, а не молчаливый ноль (зеркало 22023)', () => {
    expect(() =>
      calcSalary(T1, [row({ attendanceId: 'a1', lessonId: 'l1' })], [rate({ model: 'per_day' as never, value: 1 })]),
    ).toThrow(RangeError)
  })

  it('пустой месяц — пустая детализация и нулевой итог', () => {
    expect(calcSalary(T1, [], [rate({ model: 'per_lesson', value: 30_000 })])).toEqual([])
    expect(salaryTotal([])).toBe(0)
  })
})
