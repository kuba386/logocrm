import { describe, expect, it } from 'vitest'
import { ageLabel, ageParts, ageYears, pluralRu } from './age'

const today = '2026-09-07'

describe('ageYears', () => {
  it('считает полные годы', () => {
    expect(ageYears('2020-09-07', today)).toBe(6)
    expect(ageYears('2020-09-08', today)).toBe(5)
  })

  it('день рождения сегодня — год уже наступил', () => {
    expect(ageYears('2022-09-07', today)).toBe(4)
  })
})

describe('ageParts', () => {
  it('отдаёт годы и месяцы', () => {
    expect(ageParts('2022-06-07', today)).toEqual({ years: 4, months: 3 })
  })

  it('до первого дня рождения — только месяцы', () => {
    expect(ageParts('2026-03-07', today)).toEqual({ years: 0, months: 6 })
  })

  it('переход через год месяцев не теряет', () => {
    expect(ageParts('2021-12-20', today)).toEqual({ years: 4, months: 8 })
  })
})

describe('ageLabel', () => {
  it('склоняет годы по-русски', () => {
    expect(ageLabel('2025-09-07', today)).toBe('1 год')
    expect(ageLabel('2023-09-07', today)).toBe('3 года')
    expect(ageLabel('2021-09-07', today)).toBe('5 лет')
    expect(ageLabel('2015-09-07', today)).toBe('11 лет')
  })

  it('добавляет месяцы, когда они есть', () => {
    expect(ageLabel('2022-06-07', today)).toBe('4 года 3 мес')
  })

  it('до года показывает месяцы со склонением', () => {
    expect(ageLabel('2026-08-07', today)).toBe('1 месяц')
    expect(ageLabel('2026-06-07', today)).toBe('3 месяца')
    expect(ageLabel('2025-10-07', today)).toBe('11 месяцев')
  })

  it('младше месяца и пустая дата', () => {
    expect(ageLabel('2026-09-01', today)).toBe('меньше месяца')
    expect(ageLabel(null, today)).toBe('—')
  })
})

describe('pluralRu', () => {
  const word = (n: number) => pluralRu(n, 'ученик', 'ученика', 'учеников')

  it('1, 21, 101 — ученик; 2-4, 22 — ученика; 0, 5-20, 111-114 — учеников', () => {
    expect([1, 21, 101].map(word)).toEqual(['ученик', 'ученик', 'ученик'])
    expect([2, 3, 4, 22].map(word)).toEqual(['ученика', 'ученика', 'ученика', 'ученика'])
    expect([0, 5, 11, 12, 14, 20, 111, 114].map(word)).toEqual(Array(8).fill('учеников'))
  })
})
