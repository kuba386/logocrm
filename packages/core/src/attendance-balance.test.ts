import { describe, expect, it } from 'vitest'
import { attendanceBalanceLabel } from './attendance-balance'
import { formatSom } from './money'

const row = (kind: string, lessonsLeft: number | null = null, priceTiyin: number | null = null) => ({
  kind,
  lessonsLeft,
  priceTiyin,
})

describe('attendanceBalanceLabel', () => {
  it('стойка видит остаток числом, безлимит — словом', () => {
    expect(attendanceBalanceLabel(row('subscription', 8), true).text).toBe('8 зан.')
    expect(attendanceBalanceLabel(row('subscription', null), true).text).toBe('без лимита')
  })

  it('специалисту null — не «безлимит»: только «есть»', () => {
    expect(attendanceBalanceLabel(row('subscription', null), false).text).toBe('есть')
    expect(attendanceBalanceLabel(row('subscription_low', null), false).text).toBe('заканчивается')
  })

  it('нет абонемента на услугу занятия — долг с ценой услуги у стойки, без суммы у специалиста', () => {
    const admin = attendanceBalanceLabel(row('no_subscription', null, 80_000), true)
    expect(admin).toEqual({ text: `нет абонемента на эту услугу — в долг ${formatSom(80_000)}`, tone: 'danger' })
    expect(attendanceBalanceLabel(row('no_subscription', null, 80_000), false).text).not.toContain('сом')
  })

  it('списано: текущий остаток, а не «после этого занятия»', () => {
    expect(attendanceBalanceLabel(row('charged', 7), true).text).toBe('списано · сейчас осталось 7 зан.')
    expect(attendanceBalanceLabel(row('charged', 7), false).text).toBe('списано с абонемента')
  })

  it('долг, покрытие, занятие без услуги, исчерпанный в минус', () => {
    expect(attendanceBalanceLabel(row('debt'), true).tone).toBe('danger')
    expect(attendanceBalanceLabel(row('covered'), true)).toEqual({ text: 'долг покрыт абонементом', tone: 'muted' })
    expect(attendanceBalanceLabel(row('no_service'), false).text).not.toContain('долг')
    expect(attendanceBalanceLabel(row('free'), true)).toEqual({ text: 'без абонемента — бесплатно', tone: 'muted' })
    expect(attendanceBalanceLabel(row('debt'), true).text).not.toContain('сом')
    expect(attendanceBalanceLabel(row('subscription_empty', -1), true).text).toBe('-1 зан. — в минус')
  })

  it('отработка — без списания и без чисел', () => {
    expect(attendanceBalanceLabel(row('makeup', 3, 50_000), true)).toEqual({ text: 'отработка — без списания', tone: 'muted' })
  })

  it('неизвестный вид — прочерк, не падение', () => {
    expect(attendanceBalanceLabel(row('что-то новое'), true).text).toBe('—')
  })
})
