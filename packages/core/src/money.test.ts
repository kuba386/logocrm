import { describe, expect, it } from 'vitest'
import { formatSom, lessonPrice, toSom, toTiyin } from './money'

describe('toTiyin', () => {
  it('переводит сомы в тыйыны', () => {
    expect(toTiyin(0)).toBe(0)
    expect(toTiyin(1)).toBe(100)
    expect(toTiyin(2500)).toBe(250_000)
  })

  it('округляет копейки до ближайшего тыйына', () => {
    expect(toTiyin(10.005)).toBe(1001)
    expect(toTiyin(10.004)).toBe(1000)
  })

  it('не принимает NaN и Infinity', () => {
    expect(() => toTiyin(Number.NaN)).toThrow(TypeError)
    expect(() => toTiyin(Number.POSITIVE_INFINITY)).toThrow(TypeError)
  })
})

describe('toSom', () => {
  it('переводит тыйыны в сомы', () => {
    expect(toSom(250_000)).toBe(2500)
    expect(toSom(1)).toBe(0.01)
  })

  it('требует целое число тыйынов', () => {
    expect(() => toSom(10.5)).toThrow(TypeError)
  })

  it('round-trip не теряет значение', () => {
    for (const som of [0, 1, 99.99, 2500, 123_456.78]) {
      expect(toSom(toTiyin(som))).toBeCloseTo(som, 2)
    }
  })
})

describe('lessonPrice', () => {
  it('делит цену абонемента на количество занятий', () => {
    expect(lessonPrice(250_000, 10)).toBe(25_000)
  })

  it('округляет вниз, остаток в пользу родителя', () => {
    expect(lessonPrice(100_001, 3)).toBe(33_333)
    expect(lessonPrice(999, 10)).toBe(99)
  })

  it('нулевая цена абонемента допустима', () => {
    expect(lessonPrice(0, 8)).toBe(0)
  })

  it('отвергает недопустимые аргументы', () => {
    expect(() => lessonPrice(250_000, 0)).toThrow(RangeError)
    expect(() => lessonPrice(250_000, -1)).toThrow(RangeError)
    expect(() => lessonPrice(-1, 10)).toThrow(RangeError)
    expect(() => lessonPrice(250_000.5, 10)).toThrow(TypeError)
  })
})

describe('formatSom', () => {
  // Intl для ru-RU использует неразрывный пробел как разделитель разрядов
  const normalize = (value: string) => value.replace(/[\u00a0\u202f]/g, ' ')

  it('форматирует целые суммы без копеек', () => {
    expect(normalize(formatSom(250_000))).toBe('2 500 сом')
  })

  it('показывает копейки, когда они есть', () => {
    expect(normalize(formatSom(1099))).toBe('10,99 сом')
  })
})
