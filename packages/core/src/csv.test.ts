import { describe, expect, it } from 'vitest'
import { csvDate, csvEscape, csvMoney, toCsv } from './csv'

describe('csvEscape', () => {
  it('пустое — пустая ячейка', () => {
    expect(csvEscape(null)).toBe('')
    expect(csvEscape(undefined)).toBe('')
  })

  it('булево — да/нет по-русски', () => {
    expect(csvEscape(true)).toBe('да')
    expect(csvEscape(false)).toBe('нет')
  })

  it('кавычки удваиваются, поле с ; или переводом строки берётся в кавычки', () => {
    expect(csvEscape('Иванова «Аня»')).toBe('Иванова «Аня»')
    expect(csvEscape('он сказал "да"')).toBe('"он сказал ""да"""')
    expect(csvEscape('наличными; сдача')).toBe('"наличными; сдача"')
    expect(csvEscape('две\nстроки')).toBe('"две\nстроки"')
  })

  it('формула получает префикс — Excel не выполнит её (0058 Р8)', () => {
    expect(csvEscape('=HYPERLINK("http://evil")')).toBe(`"'=HYPERLINK(""http://evil"")"`)
    expect(csvEscape('+996700000001')).toBe("'+996700000001")
    expect(csvEscape('-500')).toBe("'-500")
    expect(csvEscape('@mention')).toBe("'@mention")
    expect(csvEscape('\tтаб')).toBe("'\tтаб")
  })

  it('числа — как есть', () => {
    expect(csvEscape(42)).toBe('42')
  })
})

describe('toCsv', () => {
  it('BOM, разделитель ;, CRLF, завершающий перевод строки', () => {
    const csv = toCsv(['Дата', 'Сумма'], [['01.09.2026', '1234,50'], ['02.09.2026', '0,00']])
    expect(csv.startsWith('﻿')).toBe(true)
    expect(csv).toBe('﻿Дата;Сумма\r\n01.09.2026;1234,50\r\n02.09.2026;0,00\r\n')
  })

  it('пустой отчёт — только заголовок', () => {
    expect(toCsv(['A', 'B'], [])).toBe('﻿A;B\r\n')
  })
})

describe('csvMoney — тыйыны в сомы с десятичной запятой', () => {
  it('целые и дробные', () => {
    expect(csvMoney(123450)).toBe('1234,50')
    expect(csvMoney(100)).toBe('1,00')
    expect(csvMoney(0)).toBe('0,00')
    expect(csvMoney(-20000)).toBe('-200,00')
  })

  it('null — пусто, не 0,00: «не задано» отличается от «ноль»', () => {
    expect(csvMoney(null)).toBe('')
  })
})

describe('csvDate', () => {
  it('ISO → ДД.ММ.ГГГГ', () => {
    expect(csvDate('2026-09-24')).toBe('24.09.2026')
    expect(csvDate('2026-09-24T10:00:00+06:00')).toBe('24.09.2026')
  })

  it('пусто и мусор — не падает', () => {
    expect(csvDate(null)).toBe('')
    expect(csvDate('вчера')).toBe('вчера')
  })
})
