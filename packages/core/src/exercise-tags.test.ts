import { describe, expect, it } from 'vitest'
import { isSpecialistOnly } from './exercise-tags'

// Те же случаи — в tests/0081_specialist_only_exercises.test.sql.
const CASES: Array<[string[] | null, boolean]> = [
  [['только специалист'], true],
  [['Только Специалист'], true],
  [['  только специалист  '], true],
  [['\tтолько специалист\n'], true],
  [['\u00a0только специалист'], false],
  [['дом', 'только специалист', 'зеркало'], true],
  [[], false],
  [null, false],
  [['только специалиста'], false],
  [['специалист'], false],
  [['дом', 'кабинет'], false],
]

describe('isSpecialistOnly', () => {
  it.each(CASES)('%j → %s', (tags, expected) => {
    expect(isSpecialistOnly(tags)).toBe(expected)
  })
})
