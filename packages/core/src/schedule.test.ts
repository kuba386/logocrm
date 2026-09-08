import { describe, expect, it } from 'vitest'
import {
  findSelfOverlap,
  generateSeriesDates,
  isoWeekday,
  overlaps,
  zonedToUtc,
  type SeriesInput,
} from './schedule'

const base: SeriesInput = {
  firstDate: '2026-10-05', // понедельник
  until: '2026-10-19',
  time: '10:00',
  weekdays: [1],
  durationMin: 45,
  timeZone: 'Asia/Bishkek',
}

describe('isoWeekday', () => {
  it('понедельник — 1, воскресенье — 7', () => {
    expect(isoWeekday('2026-10-05')).toBe(1)
    expect(isoWeekday('2026-10-11')).toBe(7)
  })
})

// Эти пять случаев продублированы в pgTAP 0006_schedule.test.sql.
// Расходятся реализации — расходятся и результаты здесь.
describe('generateSeriesDates — общие с SQL случаи', () => {
  it('1. обычная неделя: три понедельника', () => {
    const slots = generateSeriesDates(base)
    expect(slots.map((s) => s.day)).toEqual(['2026-10-05', '2026-10-12', '2026-10-19'])
  })

  it('2. until ровно на нужный день недели — включается', () => {
    const slots = generateSeriesDates({ ...base, until: '2026-10-12' })
    expect(slots.map((s) => s.day)).toEqual(['2026-10-05', '2026-10-12'])
  })

  it('3. повтор дня недели — ошибка, а не два занятия', () => {
    expect(() => generateSeriesDates({ ...base, weekdays: [3, 3] })).toThrow(RangeError)
  })

  it('4. Asia/Bishkek: 10:00 местного — это 04:00 UTC', () => {
    const [slot] = generateSeriesDates({ ...base, until: '2026-10-05' })
    expect(slot!.startsAt.toISOString()).toBe('2026-10-05T04:00:00.000Z')
  })

  it('5. Europe/Moscow: то же местное время — другой момент UTC', () => {
    const [bishkek] = generateSeriesDates({ ...base, until: '2026-10-05' })
    const [moscow] = generateSeriesDates({
      ...base,
      until: '2026-10-05',
      timeZone: 'Europe/Moscow',
    })
    expect(moscow!.startsAt.toISOString()).toBe('2026-10-05T07:00:00.000Z')
    expect(moscow!.startsAt.getTime()).not.toBe(bishkek!.startsAt.getTime())
  })
})

describe('generateSeriesDates — прочее', () => {
  it('несколько дней недели идут по календарю', () => {
    const slots = generateSeriesDates({
      ...base,
      weekdays: [3, 5],
      firstDate: '2026-10-05',
      until: '2026-10-11',
    })
    expect(slots.map((s) => s.day)).toEqual(['2026-10-07', '2026-10-09'])
  })

  it('длительность даёт конец занятия', () => {
    const [slot] = generateSeriesDates({ ...base, until: '2026-10-05' })
    expect(slot!.endsAt.getTime() - slot!.startsAt.getTime()).toBe(45 * 60_000)
  })

  it('пустой список дней и дата окончания раньше начала — ошибки', () => {
    expect(() => generateSeriesDates({ ...base, weekdays: [] })).toThrow(RangeError)
    expect(() => generateSeriesDates({ ...base, until: '2026-10-01' })).toThrow(RangeError)
  })

  it('день недели вне 1–7 отвергается', () => {
    expect(() => generateSeriesDates({ ...base, weekdays: [0 as 1] })).toThrow(RangeError)
    expect(() => generateSeriesDates({ ...base, weekdays: [8 as 1] })).toThrow(RangeError)
  })

  it('нулевая длительность отвергается', () => {
    expect(() => generateSeriesDates({ ...base, durationMin: 0 })).toThrow(RangeError)
  })
})

describe('zonedToUtc', () => {
  it('переводит локальное время в момент UTC', () => {
    expect(zonedToUtc('2026-10-05', '10:00', 'Asia/Bishkek').toISOString()).toBe(
      '2026-10-05T04:00:00.000Z',
    )
    expect(zonedToUtc('2026-10-05', '10:00', 'UTC').toISOString()).toBe('2026-10-05T10:00:00.000Z')
  })

  it('переход на летнее время не ломает расчёт', () => {
    // Берлин: 25 октября 2026 часы переводят назад, 10:00 уже в CET (+01:00).
    expect(zonedToUtc('2026-10-26', '10:00', 'Europe/Berlin').toISOString()).toBe(
      '2026-10-26T09:00:00.000Z',
    )
    // За неделю до перевода то же местное время ещё в CEST (+02:00).
    expect(zonedToUtc('2026-10-19', '10:00', 'Europe/Berlin').toISOString()).toBe(
      '2026-10-19T08:00:00.000Z',
    )
  })

  it('мусор на входе отвергается', () => {
    expect(() => zonedToUtc('05.10.2026', '10:00', 'UTC')).toThrow(TypeError)
    expect(() => zonedToUtc('2026-10-05', '25:00', 'UTC')).toThrow(TypeError)
  })
})

describe('overlaps', () => {
  const at = (iso: string) => new Date(iso)

  it('касание границ не считается накладкой', () => {
    expect(
      overlaps(
        at('2026-10-05T10:00:00Z'),
        at('2026-10-05T10:45:00Z'),
        at('2026-10-05T10:45:00Z'),
        at('2026-10-05T11:30:00Z'),
      ),
    ).toBe(false)
  })

  it('пересечение на 15 минут — накладка', () => {
    expect(
      overlaps(
        at('2026-10-05T10:00:00Z'),
        at('2026-10-05T10:45:00Z'),
        at('2026-10-05T10:30:00Z'),
        at('2026-10-05T11:15:00Z'),
      ),
    ).toBe(true)
  })

  it('вложенный интервал — накладка', () => {
    expect(
      overlaps(
        at('2026-10-05T10:00:00Z'),
        at('2026-10-05T12:00:00Z'),
        at('2026-10-05T10:30:00Z'),
        at('2026-10-05T11:00:00Z'),
      ),
    ).toBe(true)
  })

  it('нулевая и вывернутая длительность — исключение, а не false', () => {
    expect(() =>
      overlaps(
        at('2026-10-05T10:00:00Z'),
        at('2026-10-05T10:00:00Z'),
        at('2026-10-05T11:00:00Z'),
        at('2026-10-05T11:45:00Z'),
      ),
    ).toThrow(RangeError)

    expect(() =>
      overlaps(
        at('2026-10-05T11:00:00Z'),
        at('2026-10-05T10:00:00Z'),
        at('2026-10-05T12:00:00Z'),
        at('2026-10-05T12:45:00Z'),
      ),
    ).toThrow(RangeError)
  })
})

describe('findSelfOverlap', () => {
  it('серия по одному занятию в день сама с собой не пересекается', () => {
    expect(findSelfOverlap(generateSeriesDates(base))).toBeNull()
  })

  it('находит пересечение, если слоты наложены', () => {
    const slots = [
      { day: '2026-10-05', startsAt: new Date('2026-10-05T10:00:00Z'), endsAt: new Date('2026-10-05T10:45:00Z') },
      { day: '2026-10-05', startsAt: new Date('2026-10-05T10:30:00Z'), endsAt: new Date('2026-10-05T11:15:00Z') },
    ]
    expect(findSelfOverlap(slots)).not.toBeNull()
  })
})
