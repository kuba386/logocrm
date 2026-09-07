import { describe, expect, it } from 'vitest'
import { createInvitationSchema } from './dto'

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
