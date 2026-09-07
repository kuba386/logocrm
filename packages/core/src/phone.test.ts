import { describe, expect, it } from 'vitest'
import { formatKgPhone, isValidKgPhone, normalizeKgPhone, whatsappNumber } from './phone'

describe('normalizeKgPhone', () => {
  // Тот же набор примеров прогоняется в pgTAP для normalize_kg_phone:
  // расхождение реализаций даст дубли плательщиков.
  const same = [
    '0700123456',
    '700123456',
    '+996700123456',
    '996700123456',
    '+996 700 123 456',
    '0700 12-34-56',
    ' +996 (700) 12 34 56 ',
  ]

  it.each(same)('«%s» → +996700123456', (input) => {
    expect(normalizeKgPhone(input)).toBe('+996700123456')
  })

  it('отвергает то, что номером не является', () => {
    for (const input of ['', '12345', 'абв', '99670012345678', '+7 900 123 45 67']) {
      expect(normalizeKgPhone(input)).toBeNull()
    }
  })

  it('null и undefined дают null', () => {
    expect(normalizeKgPhone(null)).toBeNull()
    expect(normalizeKgPhone(undefined)).toBeNull()
  })
})

describe('isValidKgPhone', () => {
  it('различает валидный и мусорный номер', () => {
    expect(isValidKgPhone('0700123456')).toBe(true)
    expect(isValidKgPhone('123')).toBe(false)
  })
})

describe('formatKgPhone', () => {
  it('разбивает номер на группы', () => {
    expect(formatKgPhone('0700123456')).toBe('+996 700 123 456')
  })

  it('нераспознанное возвращает как есть', () => {
    expect(formatKgPhone('не телефон')).toBe('не телефон')
  })
})

describe('whatsappNumber', () => {
  it('отдаёт только цифры для wa.me', () => {
    expect(whatsappNumber('+996 700 123 456')).toBe('996700123456')
    expect(whatsappNumber('мусор')).toBeNull()
  })
})
