import { describe, expect, it } from 'vitest'
import { createInvitationSchema, sellSubscriptionPaidSchema } from './dto'

const sale = {
  studentId: '00000000-0000-0000-0000-0000000000e1',
  typeId: '00000000-0000-0000-0000-000000000071',
  saleKey: '00000000-0000-0000-0000-000000000055',
  paidTiyin: 200000,
  sourceId: '00000000-0000-0000-0000-0000000000f1',
  expectedRemainingTiyin: 200000,
}

describe('sellSubscriptionPaidSchema', () => {
  it('чек-лист п.1: 4 000 / 2 000 / 2 платежа', () => {
    const result = sellSubscriptionPaidSchema.safeParse({ ...sale, installments: 2 })
    expect(result.success).toBe(true)
    if (result.success) expect(result.data.stepMonths).toBe(1)
  })

  it('оплата без источника — отказ', () => {
    const result = sellSubscriptionPaidSchema.safeParse({ ...sale, sourceId: undefined })
    expect(result.success).toBe(false)
    if (!result.success) expect(result.error.issues[0]?.message).toBe('Укажите источник оплаты')
  })

  it('без оплаты источник не нужен', () => {
    expect(sellSubscriptionPaidSchema.safeParse({ ...sale, paidTiyin: 0, sourceId: undefined, expectedRemainingTiyin: 400000 }).success).toBe(true)
  })

  it('рассрочка при полной оплате — отказ', () => {
    const result = sellSubscriptionPaidSchema.safeParse({ ...sale, paidTiyin: 400000, expectedRemainingTiyin: 0, installments: 2 })
    expect(result.success).toBe(false)
  })

  it('платежей больше, чем тыйынов в остатке — отказ', () => {
    expect(sellSubscriptionPaidSchema.safeParse({ ...sale, expectedRemainingTiyin: 1, installments: 2 }).success).toBe(false)
  })

  it('25 платежей — отказ, 0 — отказ', () => {
    expect(sellSubscriptionPaidSchema.safeParse({ ...sale, installments: 25 }).success).toBe(false)
    expect(sellSubscriptionPaidSchema.safeParse({ ...sale, installments: 0 }).success).toBe(false)
  })

  it('пустой ключ продажи — отказ', () => {
    expect(sellSubscriptionPaidSchema.safeParse({ ...sale, saleKey: '' }).success).toBe(false)
  })
})

describe('createInvitationSchema', () => {
  it('для специалиста требует ФИО или существующую карточку', () => {
    const result = createInvitationSchema.safeParse({ role: 'teacher' })
    expect(result.success).toBe(false)
  })

  it('принимает специалиста с ФИО', () => {
    expect(createInvitationSchema.safeParse({ role: 'teacher', fullName: 'Айгуль К.' }).success).toBe(true)
  })

  it('принимает специалиста с выбранной карточкой', () => {
    const result = createInvitationSchema.safeParse({
      role: 'teacher',
      teacherId: '00000000-0000-0000-0000-0000000000a1',
    })
    expect(result.success).toBe(true)
  })

  it('родителю ФИО не обязательно', () => {
    expect(createInvitationSchema.safeParse({ role: 'parent' }).success).toBe(true)
  })

  it('отвергает кривой телефон', () => {
    const result = createInvitationSchema.safeParse({ role: 'parent', phone: 'абв' })
    expect(result.success).toBe(false)
  })
})
