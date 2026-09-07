import { describe, expect, it } from 'vitest'
import { appEventSchema, baseEventSchema, parseAppEvent } from './events'

describe('baseEventSchema', () => {
  it('требует формат «сущность.действие»', () => {
    expect(baseEventSchema.safeParse({ type: 'center.created', payload: {} }).success).toBe(true)
    expect(baseEventSchema.safeParse({ type: 'centerCreated', payload: {} }).success).toBe(false)
  })

  it('payload по умолчанию — пустой объект', () => {
    expect(baseEventSchema.parse({ type: 'center.created' }).payload).toEqual({})
  })
})

describe('appEventSchema', () => {
  it('разбирает center.created', () => {
    const event = appEventSchema.parse({
      type: 'center.created',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        name: 'Логопед Плюс',
        slug: 'logoped-plyus',
        city: 'Бишкек',
      },
    })
    expect(event.type).toBe('center.created')
  })

  it('разбирает membership.created', () => {
    const event = appEventSchema.parse({
      type: 'membership.created',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        user_id: '00000000-0000-0000-0000-0000000000a1',
        role: 'owner',
      },
    })
    if (event.type !== 'membership.created') throw new Error('ожидался membership.created')
    expect(event.payload.role).toBe('owner')
  })

  it('отвергает неизвестную роль', () => {
    const result = appEventSchema.safeParse({
      type: 'membership.created',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        user_id: '00000000-0000-0000-0000-0000000000a1',
        role: 'director',
      },
    })
    expect(result.success).toBe(false)
  })
})

describe('parseAppEvent', () => {
  it('возвращает ошибку вместо исключения для неизвестного типа', () => {
    const result = parseAppEvent({ type: 'lesson.rescheduled', payload: {} })
    expect(result.ok).toBe(false)
  })
})

describe('события этапа 1', () => {
  it('разбирает invitation.created', () => {
    const event = appEventSchema.parse({
      type: 'invitation.created',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        invitation_id: '00000000-0000-0000-0000-0000000000e1',
        role: 'teacher',
        teacher_id: '00000000-0000-0000-0000-0000000000t1'.replace(/t/g, 'a'),
      },
    })
    expect(event.type).toBe('invitation.created')
  })

  it('разбирает membership.revoked', () => {
    const event = appEventSchema.parse({
      type: 'membership.revoked',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        user_id: '00000000-0000-0000-0000-0000000000a1',
        role: 'teacher',
      },
    })
    if (event.type !== 'membership.revoked') throw new Error('ожидался membership.revoked')
    expect(event.payload.role).toBe('teacher')
  })

  it('teacher_id в invitation.created может быть null', () => {
    const event = appEventSchema.parse({
      type: 'invitation.created',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        invitation_id: '00000000-0000-0000-0000-0000000000e1',
        role: 'parent',
        teacher_id: null,
      },
    })
    if (event.type !== 'invitation.created') throw new Error('ожидался invitation.created')
    expect(event.payload.teacher_id).toBeNull()
  })
})
