import { describe, expect, it } from 'vitest'
import { allowedFunnelTransitions, FUNNEL_STAGES, type FunnelStage } from './funnel'

// Эти случаи продублированы в pgTAP 0055_funnel.test.sql, раздел 3
// («Граф переходов: ручной путь»), тем же путём — set_funnel_stage.
// Расходятся реализации — расходятся и результаты здесь.
describe('allowedFunnelTransitions — общие с SQL случаи', () => {
  it('1. шаг вперёд на непосредственно следующий этап разрешён', () => {
    expect(allowedFunnelTransitions('lead')).toContain('contacted')
  })

  it('2. пропуск вперёд (contacted → trial, минуя consultation/assessment) недоступен', () => {
    expect(allowedFunnelTransitions('contacted')).not.toContain('trial')
  })

  it('3. ещё шаг вперёд — на следующий этап (contacted → consultation)', () => {
    expect(allowedFunnelTransitions('contacted')).toContain('consultation')
  })

  it('4. назад — на ЛЮБОЙ более ранний этап, не только на непосредственно предыдущий', () => {
    const back = allowedFunnelTransitions('consultation')
    expect(back).toContain('lead')
    expect(back).toContain('contacted')
  })

  it('5. completed — последний этап, вперёд шагать некуда, назад — все шесть', () => {
    const back = allowedFunnelTransitions('completed')
    expect(back).toHaveLength(6)
    expect(back).not.toContain('completed')
  })

  it('неизвестный этап — пустой список, а не ошибка', () => {
    expect(allowedFunnelTransitions('unknown' as FunnelStage)).toEqual([])
  })

  it('для каждого этапа: вперёд — ровно следующий по sort, назад — все более ранние', () => {
    FUNNEL_STAGES.forEach((stage, i) => {
      const allowed = allowedFunnelTransitions(stage)
      const expectedForward = FUNNEL_STAGES[i + 1] ? [FUNNEL_STAGES[i + 1]] : []
      const expectedBackward = FUNNEL_STAGES.slice(0, i)
      expect(allowed).toEqual([...expectedForward, ...expectedBackward])
    })
  })
})
