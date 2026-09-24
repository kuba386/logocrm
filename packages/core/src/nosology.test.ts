import { describe, expect, it } from 'vitest'
import { suggestSpeechConclusion } from './nosology'

const FULL_NORM = {
  звукопроизношение: 5,
  фонематика: 5,
  лексика: 5,
  грамматика: 5,
  'связная речь': 5,
}

// Единый пронумерованный список случаев — тот же в
// 0061_conclusion_suggestion.test.sql (pgTAP). Расходятся реализации,
// расходятся и результаты; список случаев должен остаться один в один.
describe('suggestSpeechConclusion — общие с SQL случаи', () => {
  it('1. все пять в норме — null, а не norm (функция не видит sounds, Р8)', () => {
    expect(suggestSpeechConclusion(FULL_NORM)).toBeNull()
  })

  it('2. граница: 3 по всем — ещё «не нарушено», тоже null', () => {
    expect(
      suggestSpeechConclusion({
        звукопроизношение: 3,
        фонематика: 3,
        лексика: 3,
        грамматика: 3,
        'связная речь': 3,
      }),
    ).toBeNull()
  })

  it('3. граница: 2 в звукопроизношении — уже нарушено, fnr', () => {
    expect(suggestSpeechConclusion({ ...FULL_NORM, звукопроизношение: 2 })).toBe('fnr')
  })

  it('4. только звукопроизношение нарушено (1) — fnr', () => {
    expect(suggestSpeechConclusion({ ...FULL_NORM, звукопроизношение: 1 })).toBe('fnr')
  })

  it('5. звукопроизношение и фонематика нарушены, остальное в норме — ffnr', () => {
    expect(
      suggestSpeechConclusion({ ...FULL_NORM, звукопроизношение: 2, фонематика: 2 }),
    ).toBe('ffnr')
  })

  it('6. только фонематика нарушена (без звукопроизношения) — тоже ffnr', () => {
    expect(suggestSpeechConclusion({ ...FULL_NORM, фонематика: 1 })).toBe('ffnr')
  })

  it('7. нарушена лексика — onr_suspected', () => {
    expect(suggestSpeechConclusion({ ...FULL_NORM, лексика: 2 })).toBe('onr_suspected')
  })

  it('8. нарушена только грамматика — тоже onr_suspected', () => {
    expect(suggestSpeechConclusion({ ...FULL_NORM, грамматика: 1 })).toBe('onr_suspected')
  })

  it('9. нарушена только связная речь — тоже onr_suspected', () => {
    expect(suggestSpeechConclusion({ ...FULL_NORM, 'связная речь': 2 })).toBe('onr_suspected')
  })

  it('10. тяжесть не влияет на флаг: одна область=1 и три области=2 дают один и тот же onr_suspected (Р1)', () => {
    const oneAreaSevere = suggestSpeechConclusion({ ...FULL_NORM, лексика: 1 })
    const threeAreasMild = suggestSpeechConclusion({
      ...FULL_NORM,
      лексика: 2,
      грамматика: 2,
      'связная речь': 2,
    })
    expect(oneAreaSevere).toBe('onr_suspected')
    expect(threeAreasMild).toBe('onr_suspected')
  })

  it('11. приоритет: нарушены звукопроизношение/фонематика/лексика разом — onr_suspected, не ффнр', () => {
    expect(
      suggestSpeechConclusion({
        звукопроизношение: 1,
        фонематика: 1,
        лексика: 1,
        грамматика: 5,
        'связная речь': 5,
      }),
    ).toBe('onr_suspected')
  })

  it('12. не хватает одной из пяти областей — null (недостаточно данных)', () => {
    const { звукопроизношение: _drop, ...partial } = FULL_NORM
    expect(suggestSpeechConclusion(partial)).toBeNull()
  })

  it('13. нечисловое значение (строка из формы) в любой из пяти — null, не бросает', () => {
    expect(
      suggestSpeechConclusion({ ...FULL_NORM, лексика: Number('что-то') }),
    ).toBeNull()
  })

  it('14. значение 0 — вне шкалы [1,5], null, не «тяжело нарушено»', () => {
    expect(suggestSpeechConclusion({ ...FULL_NORM, лексика: 0 })).toBeNull()
  })

  it('15. значение 6 — вне шкалы [1,5], null, не «норма»', () => {
    expect(suggestSpeechConclusion({ ...FULL_NORM, звукопроизношение: 6 })).toBeNull()
  })

  it('16. дробное значение внутри диапазона (2.5) — валидный балл, не нарушено', () => {
    expect(suggestSpeechConclusion({ ...FULL_NORM, лексика: 2.5 })).toBeNull()
  })

  it('onr_suspected не строка из справочника speech_conclusions — приложение обязано не давать «Применить» для неё', () => {
    const result = suggestSpeechConclusion({ ...FULL_NORM, грамматика: 2 })
    expect(result).not.toMatch(/^(fnr|ffnr)$/)
  })

  it('zrr не предлагается ни на одном входе — возрастная категория, не выводится из баллов', () => {
    const cases = [
      FULL_NORM,
      { ...FULL_NORM, звукопроизношение: 1 },
      { ...FULL_NORM, фонематика: 1 },
      { ...FULL_NORM, лексика: 1, грамматика: 1, 'связная речь': 1 },
    ]
    for (const areas of cases) {
      expect(suggestSpeechConclusion(areas)).not.toBe('zrr')
    }
  })
})
