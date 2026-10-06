import { describe, expect, it } from 'vitest'
import { pickSavedFilterParams, sameSavedFilterParams, savedFilterParamsOk } from './saved-filters'

// Тот же набор случаев, что в packages/db/supabase/tests/0094_saved_filters.test.sql
// (раздел 3): SQL — источник истины, здесь зеркало.
const TEACHER = '94000000-0000-0000-0000-000000000003'

describe('savedFilterParamsOk — зеркало saved_filter_params_ok', () => {
  it.each([
    ['schedule', { teacher: TEACHER, room: 'none' }],
    ['schedule', {}],
    ['debts', { filter: 'debt', sort: 'name', min: '5000' }],
    ['debts', { min: '9999999' }],
  ] as const)('допустимо: %s %j', (page, params) => {
    expect(savedFilterParamsOk(page, params)).toBe(true)
  })

  it.each([
    ['schedule', { week: '2026-10-05' }],
    ['schedule', { teacher: 'нет' }],
    ['schedule', { teacher: 123 }],
    ['debts', { min: '0' }],
    ['debts', { min: '05' }],
    ['debts', { min: '5000.5' }],
    ['debts', { min: '10000000' }],
    ['debts', { filter: 'overdue' }],
    ['debts', { teacher: TEACHER }],
    ['schedule', []],
    ['debts', { min: 5000 }],
  ] as const)('недопустимо: %s %j', (page, params) => {
    expect(savedFilterParamsOk(page, params)).toBe(false)
  })
})

describe('pickSavedFilterParams', () => {
  it('неделя расписания не сохраняется, мусор отбрасывается', () => {
    expect(pickSavedFilterParams('schedule', { week: '2026-10-05', teacher: TEACHER, room: 'x' })).toEqual({ teacher: TEACHER })
  })

  it('значения по умолчанию долгов не сохраняются', () => {
    expect(pickSavedFilterParams('debts', { filter: 'all', sort: 'amount', min: '5000' })).toEqual({ min: '5000' })
    expect(pickSavedFilterParams('debts', { filter: 'debt', sort: 'name' })).toEqual({ filter: 'debt', sort: 'name' })
  })

  it('результат всегда проходит валидатор', () => {
    const picked = pickSavedFilterParams('debts', { filter: ['zero', 'debt'], min: '05' })
    expect(picked).toEqual({ filter: 'zero' })
    expect(savedFilterParamsOk('debts', picked)).toBe(true)
  })
})

describe('sameSavedFilterParams', () => {
  it('порядок ключей не важен, лишний ключ — уже другой набор', () => {
    expect(sameSavedFilterParams({ a: '1', b: '2' }, { b: '2', a: '1' })).toBe(true)
    expect(sameSavedFilterParams({ a: '1' }, { a: '1', b: '2' })).toBe(false)
  })
})
