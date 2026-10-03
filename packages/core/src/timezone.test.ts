import { describe, expect, it } from 'vitest'
import { CENTER_TIME_ZONE_CASES, centerTimeZoneName } from './timezone'

describe('centerTimeZoneName — зеркало center_timezone() (0086)', () => {
  it.each(CENTER_TIME_ZONE_CASES.map(([input, expected]) => [JSON.stringify(input).slice(0, 40), input, expected]))(
    '%s',
    (_label, input, expected) => {
      expect(centerTimeZoneName(input)).toBe(expected)
    },
  )
})
