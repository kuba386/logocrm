import { describe, expect, it } from 'vitest'
import { formatSom } from './money'
import { debtWhatsappMessage, subscriptionOverdueAddressable, type DebtMessageRow } from './debt-message'

const base: DebtMessageRow = {
  studentName: 'Аня',
  payerId: 'p1',
  debtTiyin: 0,
  overdrawnTiyin: 0,
  subscriptionOverdueTiyin: 0,
  subscriptionOverduePayerId: null,
  zeroLeft: false,
}

describe('subscriptionOverdueAddressable', () => {
  it('просрочка того же плательщика — адресуема', () => {
    expect(subscriptionOverdueAddressable({ ...base, subscriptionOverdueTiyin: 500000, subscriptionOverduePayerId: 'p1' })).toBe(true)
  })

  it('просрочка другого плательщика — нет', () => {
    expect(subscriptionOverdueAddressable({ ...base, subscriptionOverdueTiyin: 500000, subscriptionOverduePayerId: 'p2' })).toBe(false)
  })

  it('несколько плательщиков (NULL, 0070) — нет', () => {
    expect(subscriptionOverdueAddressable({ ...base, subscriptionOverdueTiyin: 500000 })).toBe(false)
  })

  it('два NULL — не совпадение', () => {
    expect(subscriptionOverdueAddressable({ ...base, payerId: null, subscriptionOverdueTiyin: 500000 })).toBe(false)
  })

  it('без просрочки — нет', () => {
    expect(subscriptionOverdueAddressable({ ...base, subscriptionOverduePayerId: 'p1' })).toBe(false)
  })
})

describe('debtWhatsappMessage', () => {
  it('только просрочка чужого абонемента — кнопки нет', () => {
    expect(debtWhatsappMessage({ ...base, subscriptionOverdueTiyin: 500000, subscriptionOverduePayerId: 'p2' })).toBeNull()
  })

  it('только просрочка при нескольких плательщиках — кнопки нет', () => {
    expect(debtWhatsappMessage({ ...base, subscriptionOverdueTiyin: 500000 })).toBeNull()
  })

  it('исчерпанный остаток — «закончился абонемент»', () => {
    expect(debtWhatsappMessage({ ...base, zeroLeft: true })).toBe(
      'Здравствуйте! У Аня закончился абонемент. Хотите продлить?',
    )
  })

  it('ни денег, ни zeroLeft — кнопки нет', () => {
    expect(debtWhatsappMessage(base)).toBeNull()
  })

  it('своя просрочка — в тексте', () => {
    const text = debtWhatsappMessage({ ...base, subscriptionOverdueTiyin: 500000, subscriptionOverduePayerId: 'p1' })
    expect(text).toContain(`просроченный платёж за абонемент ${formatSom(500000)}`)
    expect(text).not.toContain('закончился')
  })

  it('долг и чужая просрочка — только долг, чужой суммы нет', () => {
    const text = debtWhatsappMessage({
      ...base,
      debtTiyin: 120000,
      subscriptionOverdueTiyin: 500000,
      subscriptionOverduePayerId: 'p2',
    })
    expect(text).toBe(
      `Здравствуйте! У Аня долг за занятия ${formatSom(120000)} в LogoCRM. Пожалуйста, оплатите при возможности.`,
    )
    expect(text).not.toContain(formatSom(500000))
  })

  it('долг и перерасход — обе суммы раздельно', () => {
    const text = debtWhatsappMessage({ ...base, debtTiyin: 120000, overdrawnTiyin: 80000 })
    expect(text).toContain(`долг за занятия ${formatSom(120000)} и перерасход по абонементу ${formatSom(80000)}`)
  })
})
