import { describe, expect, it } from 'vitest'
import { groupSlotsByDay, isoWeekdayInZone, localTimeInZone, parseWeekdays, slotLabel, workHoursSummary } from './booking'

// Случаи 1–3 продублированы в pgTAP 0109_booking_slots.test.sql (пояс UTC+5
// против Бишкека, isodow, DST): расходятся SQL и подписи — расходятся и тут.
describe('окно в поясе центра — общие с SQL случаи', () => {
  it('1. одно окно: 9:00 по Бишкеку — 8:00 по Ташкенту (UTC+5)', () => {
    expect(localTimeInZone('2026-10-26T03:00:00Z', 'Asia/Bishkek')).toBe('09:00')
    expect(localTimeInZone('2026-10-26T04:00:00Z', 'Asia/Tashkent')).toBe('09:00')
    expect(localTimeInZone('2026-10-26T03:00:00Z', 'Asia/Tashkent')).toBe('08:00')
  })

  it('2. isodow — по дню центра: 19:30 UTC воскресенья — уже понедельник в Бишкеке', () => {
    expect(isoWeekdayInZone('2026-10-25T19:30:00Z', 'UTC')).toBe(7)
    expect(isoWeekdayInZone('2026-10-25T19:30:00Z', 'Asia/Bishkek')).toBe(1)
  })

  it('3. DST: 9:00 в Берлине до и после перехода на зимнее время — разные UTC', () => {
    expect(localTimeInZone('2026-10-24T07:00:00Z', 'Europe/Berlin')).toBe('09:00')
    expect(localTimeInZone('2026-10-26T08:00:00Z', 'Europe/Berlin')).toBe('09:00')
  })
})

describe('slotLabel', () => {
  it('«Пн 26 окт · 09:00» в поясе центра', () => {
    expect(slotLabel('2026-10-26T03:00:00Z', 'Asia/Bishkek')).toBe('Пн 26 окт · 09:00')
  })

  it('воскресенье — «Вс», май — родительный падеж', () => {
    expect(slotLabel('2026-05-31T10:00:00Z', 'Asia/Bishkek')).toBe('Вс 31 мая · 16:00')
  })
})

describe('groupSlotsByDay', () => {
  it('группирует по местному дню, а не по UTC, и сортирует', () => {
    const days = groupSlotsByDay(
      [
        { starts_at: '2026-10-26T04:00:00Z' },
        { starts_at: '2026-10-25T19:30:00Z' },
        { starts_at: '2026-10-27T03:00:00Z' },
      ],
      'Asia/Bishkek',
    )
    expect(days.map((d) => d.day)).toEqual(['2026-10-26', '2026-10-27'])
    expect(days[0]?.slots.map((s) => s.time)).toEqual(['01:30', '10:00'])
    expect(days[0]?.label).toBe('Пн 26 окт')
  })

  it('пустой список — пусто', () => {
    expect(groupSlotsByDay([], 'Asia/Bishkek')).toEqual([])
  })
})

describe('parseWeekdays — как submit_waitlist_entry', () => {
  it('повторы схлопываются, порядок по возрастанию', () => {
    expect(parseWeekdays(['3', '1', '3'])).toEqual([1, 3])
  })

  it('пустой выбор — null, «любой день»', () => {
    expect(parseWeekdays([])).toBeNull()
  })

  it('значение вне 1..7 — ошибка, а не тихий пропуск', () => {
    expect(() => parseWeekdays(['8'])).toThrow(RangeError)
    expect(() => parseWeekdays(['0'])).toThrow(RangeError)
  })
})

describe('workHoursSummary', () => {
  const h = (weekday: number, starts_at: string, ends_at: string) => ({ weekday, starts_at, ends_at })

  it('будни с перерывом и суббота отдельно', () => {
    const week = [1, 2, 3, 4, 5].flatMap((d) => [h(d, '14:00:00', '18:00:00'), h(d, '09:00:00', '13:00:00')])
    expect(workHoursSummary([...week, h(6, '10:00', '14:00')])).toBe('Пн–Пт 09:00–13:00, 14:00–18:00; Сб 10:00–14:00')
  })

  it('разрыв в середине недели не склеивает дни через выходной', () => {
    expect(workHoursSummary([h(1, '09:00', '12:00'), h(3, '09:00', '12:00')])).toBe('Пн 09:00–12:00; Ср 09:00–12:00')
  })

  it('разные часы соседних дней — отдельно; воскресенье в конце', () => {
    expect(workHoursSummary([h(6, '10:00', '14:00'), h(7, '10:00', '13:00')])).toBe('Сб 10:00–14:00; Вс 10:00–13:00')
  })

  it('без часов — пустая строка', () => {
    expect(workHoursSummary([])).toBe('')
  })
})
