import { describe, expect, it } from 'vitest'
import { buildClassifyRequest, parseClassifyResponse } from './assistant-request'

const ALL = ['lessons_on', 'debtors', 'expiring_subscriptions', 'student_info', 'payments_summary']

describe('buildClassifyRequest — что уходит провайдеру (ADR-009, В1)', () => {
  it('в теле только системная инструкция, дата и текст вопроса', () => {
    const body = buildClassifyRequest('кто должен денег', '2026-09-25', ALL)
    expect(body.messages).toHaveLength(2)
    expect(body.messages[0]!.role).toBe('system')
    expect(body.messages[0]!.content).toContain('2026-09-25')
    expect(body.messages[0]!.content).toContain('пятница')
    expect(body.messages[1]).toEqual({ role: 'user', content: 'кто должен денег' })
    const raw = JSON.stringify(body)
    // Ни имён, ни идентификаторов, ни денег центра — только описания инструментов.
    expect(raw).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-/)
    expect(body.parallel_tool_calls).toBe(false)
    expect(body.temperature).toBe(0)
  })

  it('инструменты — только разрешённые роли (карта в SQL, Р3)', () => {
    const teacher = buildClassifyRequest('кто должен', '2026-09-25', ['lessons_on', 'student_info'])
    expect(teacher.tools.map((t) => t.function.name)).toEqual(['lessons_on', 'student_info'])
    const finance = buildClassifyRequest('занятия завтра', '2026-09-25', ['debtors', 'expiring_subscriptions'])
    expect(finance.tools.map((t) => t.function.name)).toEqual(['debtors', 'expiring_subscriptions'])
    expect(buildClassifyRequest('x', '2026-09-25', []).tools).toEqual([])
  })
})

describe('parseClassifyResponse — ответ модели как данные', () => {
  const ok = (name: string, args: unknown) => ({
    model: 'gpt-4o-mini-2024-07-18',
    usage: { prompt_tokens: 210, completion_tokens: 18 },
    choices: [{ message: { tool_calls: [{ function: { name, arguments: JSON.stringify(args) } }] } }],
  })

  it('валидный вызов → намерение и токены', () => {
    const r = parseClassifyResponse(ok('lessons_on', { date: '2026-09-26' }), ALL)
    expect(r.intent).toEqual({ intent: 'lessons_on', date: '2026-09-26' })
    expect(r.tokensIn).toBe(210)
    expect(r.tokensOut).toBe(18)
    expect(r.model).toBe('gpt-4o-mini')
  })

  it('без вызова инструмента → unknown', () => {
    expect(parseClassifyResponse({ choices: [{ message: {} }] }, ALL).intent).toEqual({ intent: 'unknown' })
  })

  it('выдуманный инструмент, кривые аргументы, неразрешённое роли → unknown', () => {
    expect(parseClassifyResponse(ok('drop_center', {}), ALL).intent).toEqual({ intent: 'unknown' })
    expect(parseClassifyResponse(ok('lessons_on', { date: 'завтра' }), ALL).intent).toEqual({ intent: 'unknown' })
    expect(parseClassifyResponse(ok('payments_summary', { from: '2026-09-01', to: '2026-09-30' }), ['lessons_on']).intent).toEqual({
      intent: 'unknown',
    })
    const broken = ok('debtors', {})
    broken.choices[0]!.message.tool_calls![0]!.function.arguments = '{not json'
    expect(parseClassifyResponse(broken, ALL).intent).toEqual({ intent: 'debtors', min_som: 0 })
  })
})
