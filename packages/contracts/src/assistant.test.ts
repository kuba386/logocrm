import { describe, expect, it } from 'vitest'
import { ASSISTANT_TOOLS, assistantIntentSchema, assistantQuestionSchema } from './assistant'

describe('assistantIntentSchema', () => {
  it('разбирает каждое намерение с обязательными параметрами', () => {
    expect(assistantIntentSchema.parse({ intent: 'lessons_on', date: '2026-09-25' }).intent).toBe('lessons_on')
    expect(assistantIntentSchema.parse({ intent: 'debtors', min_som: 5000 })).toEqual({ intent: 'debtors', min_som: 5000 })
    expect(assistantIntentSchema.parse({ intent: 'expiring_subscriptions', days: 3, lessons_left: 1 }).intent).toBe(
      'expiring_subscriptions',
    )
    expect(assistantIntentSchema.parse({ intent: 'student_info', name: 'Айжан' }).intent).toBe('student_info')
    expect(assistantIntentSchema.parse({ intent: 'payments_summary', from: '2026-09-01', to: '2026-09-30' }).intent).toBe(
      'payments_summary',
    )
    expect(assistantIntentSchema.parse({ intent: 'unknown' }).intent).toBe('unknown')
  })

  it('дефолты — когда модель опустила необязательное', () => {
    expect(assistantIntentSchema.parse({ intent: 'debtors' })).toEqual({ intent: 'debtors', min_som: 0 })
    expect(assistantIntentSchema.parse({ intent: 'expiring_subscriptions' })).toEqual({
      intent: 'expiring_subscriptions',
      days: 7,
      lessons_left: 2,
    })
  })

  it('отвергает то, что модель могла выдумать', () => {
    expect(assistantIntentSchema.safeParse({ intent: 'delete_student', id: 'x' }).success).toBe(false)
    expect(assistantIntentSchema.safeParse({ intent: 'lessons_on', date: 'завтра' }).success).toBe(false)
    expect(assistantIntentSchema.safeParse({ intent: 'debtors', min_som: -1 }).success).toBe(false)
    expect(assistantIntentSchema.safeParse({ intent: 'expiring_subscriptions', days: 400 }).success).toBe(false)
    expect(assistantIntentSchema.safeParse({ intent: 'student_info', name: 'а' }).success).toBe(false)
    expect(assistantIntentSchema.safeParse({ intent: 'payments_summary', from: '2026-09-30', to: '2026-09-01' }).success).toBe(
      false,
    )
    expect(assistantIntentSchema.safeParse({ intent: 'payments_summary', from: '2025-01-01', to: '2026-09-01' }).success).toBe(
      false,
    )
  })
})

describe('ASSISTANT_TOOLS — зеркало zod', () => {
  it('каждый инструмент — известное намерение, а его required-параметры принимает схема', () => {
    for (const tool of ASSISTANT_TOOLS) {
      const sample: Record<string, unknown> = { intent: tool.name }
      for (const key of tool.parameters.required) {
        const prop = tool.parameters.properties[key]
        expect(prop, `${tool.name}.${key} описан в properties`).toBeDefined()
        sample[key] = prop!.type === 'integer' ? 1 : key === 'name' ? 'Айжан' : '2026-09-25'
      }
      expect(assistantIntentSchema.safeParse(sample).success, `${tool.name} с required-параметрами`).toBe(true)
    }
  })

  it('unknown — не инструмент: модель говорит «не понял» отсутствием вызова', () => {
    expect(ASSISTANT_TOOLS.some((t) => (t.name as string) === 'unknown')).toBe(false)
  })
})

describe('assistantQuestionSchema', () => {
  it('2–300 символов после trim', () => {
    expect(assistantQuestionSchema.safeParse(' а ').success).toBe(false)
    expect(assistantQuestionSchema.safeParse('кто должен').success).toBe(true)
    expect(assistantQuestionSchema.safeParse('x'.repeat(301)).success).toBe(false)
  })
})
