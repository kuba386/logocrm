import { describe, expect, it } from 'vitest'
import { safeNextPath } from './safe-next'

describe('safeNextPath', () => {
  it('пропускает путь приложения вместе с параметрами', () => {
    expect(safeNextPath('/app/finance?tab=cash')).toBe('/app/finance?tab=cash')
    expect(safeNextPath('/app/students/1?x=1&y=2#z')).toBe('/app/students/1?x=1&y=2#z')
  })

  it('чужой хост и не-путь — на запасной адрес', () => {
    expect(safeNextPath('https://evil.example')).toBe('/app')
    expect(safeNextPath('//evil.example/app')).toBe('/app')
    expect(safeNextPath('/\\evil.example')).toBe('/app')
    expect(safeNextPath('javascript:alert(1)')).toBe('/app')
    expect(safeNextPath('app/finance')).toBe('/app')
  })

  it('пусто, не строка, управляющие символы — на запасной адрес', () => {
    expect(safeNextPath('')).toBe('/app')
    expect(safeNextPath(null)).toBe('/app')
    expect(safeNextPath(undefined, '/onboarding')).toBe('/onboarding')
    expect(safeNextPath('/app\n//evil')).toBe('/app')
  })
})
