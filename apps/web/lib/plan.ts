/**
 * Ответ center_limits() (0049 Р9, 0050 Р11): тариф, лимиты, использование,
 * дни до конца и writable — всё посчитано в SQL в поясе центра. Здесь только
 * разбор JSON: права, деньги и занятость в браузере не считаются.
 */
export type CenterLimits = {
  plan: string
  planName: string
  priceTiyin: number
  isTrial: boolean
  until: string | null
  daysLeft: number | null
  writable: boolean
  /** ok/expired/deleted/missing (0056 Р7) — центр может быть read-only по двум разным причинам. */
  state: 'ok' | 'expired' | 'deleted' | 'missing'
  limits: { teachers: number; students: number; aiNotesMonth: number }
  usage: { teachers: number; students: number; aiNotesMonth: number }
  onboarding: { teacher: boolean; service: boolean; student: boolean; lesson: boolean; attendance: boolean }
}

function num(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function bool(value: unknown): boolean {
  return value === true
}

export function parseCenterLimits(json: unknown): CenterLimits | null {
  if (!json || typeof json !== 'object') return null
  const o = json as Record<string, unknown>
  const limits = (o.limits ?? {}) as Record<string, unknown>
  const usage = (o.usage ?? {}) as Record<string, unknown>
  const onboarding = (o.onboarding ?? {}) as Record<string, unknown>
  if (typeof o.plan !== 'string') return null
  return {
    plan: o.plan,
    planName: typeof o.plan_name === 'string' ? o.plan_name : o.plan,
    priceTiyin: num(o.price_tiyin),
    isTrial: bool(o.is_trial),
    until: typeof o.until === 'string' ? o.until : null,
    daysLeft: typeof o.days_left === 'number' ? o.days_left : null,
    writable: bool(o.writable),
    state: o.state === 'ok' || o.state === 'expired' || o.state === 'deleted' || o.state === 'missing' ? o.state : 'ok',
    limits: {
      teachers: num(limits.teachers, -1),
      students: num(limits.students, -1),
      aiNotesMonth: num(limits.ai_notes_month, -1),
    },
    usage: {
      teachers: num(usage.teachers),
      students: num(usage.students),
      aiNotesMonth: num(usage.ai_notes_month),
    },
    onboarding: {
      teacher: bool(onboarding.teacher),
      service: bool(onboarding.service),
      student: bool(onboarding.student),
      lesson: bool(onboarding.lesson),
      attendance: bool(onboarding.attendance),
    },
  }
}

/** Баннер показывается за 3 дня до конца срока и после его истечения. */
export const PLAN_WARNING_DAYS = 3
