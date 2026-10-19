import { describe, expect, it } from 'vitest'
import { CENTER_TERMS, centerTerms } from './center-terms'

describe('centerTerms', () => {
  it('у всех типов одинаковый набор ключей и ни одной пустой фразы', () => {
    const [first, ...rest] = Object.values(CENTER_TERMS)
    const keys = Object.keys(first!).sort()
    for (const terms of rest) expect(Object.keys(terms).sort()).toEqual(keys)
    for (const terms of Object.values(CENTER_TERMS)) {
      for (const value of Object.values(terms)) expect(value.trim()).not.toBe('')
    }
  })

  it('учебный центр говорит «преподаватель» и «аудитория»', () => {
    expect(centerTerms('education').teachers).toBe('Преподаватели')
    expect(centerTerms('education').rooms).toBe('Аудитории')
  })

  it('неизвестный и пустой тип — слова логопедического центра', () => {
    expect(centerTerms(null).teacher).toBe('Специалист')
    expect(centerTerms('gym').room).toBe('Кабинет')
  })
})
