import type ru from '@/messages/ru.json'

/**
 * Шаги плашки «Настройка центра» на дашборде owner/admin. Порядок — порядок,
 * в котором их удобно делать: без кабинета, услуги и специалиста занятие не
 * поставить, без типа абонемента ученику нечего продать.
 *
 * Обязательные шаги решают, видна ли плашка: когда все готовы, она исчезает
 * сама. Необязательные показываются рядом, но завершения не держат — центр
 * без онлайн-записи не «недонастроен».
 */
export type SetupStepKey = 'rooms' | 'services' | 'subscriptionTypes' | 'teachers' | 'students' | 'lessons' | 'telegram' | 'booking'

type SetupMessageKey = keyof (typeof ru)['setup']

export type SetupStep = {
  key: SetupStepKey
  href: string
  optional: boolean
  title: SetupMessageKey
  hint: SetupMessageKey
}

export const SETUP_STEPS: SetupStep[] = [
  { key: 'rooms', href: '/app/settings/rooms', optional: false, title: 'roomsTitle', hint: 'roomsHint' },
  { key: 'services', href: '/app/settings/services', optional: false, title: 'servicesTitle', hint: 'servicesHint' },
  { key: 'subscriptionTypes', href: '/app/settings/subscription-types', optional: false, title: 'subscriptionTypesTitle', hint: 'subscriptionTypesHint' },
  { key: 'teachers', href: '/app/settings/staff', optional: false, title: 'teachersTitle', hint: 'teachersHint' },
  { key: 'students', href: '/app/students', optional: false, title: 'studentsTitle', hint: 'studentsHint' },
  { key: 'lessons', href: '/app/schedule', optional: false, title: 'lessonsTitle', hint: 'lessonsHint' },
  { key: 'telegram', href: '/app/telegram', optional: true, title: 'telegramTitle', hint: 'telegramHint' },
  { key: 'booking', href: '/app/settings/plan#booking', optional: true, title: 'bookingTitle', hint: 'bookingHint' },
]

export type SetupProgress = {
  done: number
  total: number
  /** Все обязательные шаги готовы — плашку не показываем. */
  complete: boolean
}

/** Прогресс считается по всем шагам, а «готово» — только по обязательным. */
export function setupProgress(state: Record<SetupStepKey, boolean>): SetupProgress {
  return {
    done: SETUP_STEPS.filter((step) => state[step.key]).length,
    total: SETUP_STEPS.length,
    complete: SETUP_STEPS.every((step) => step.optional || state[step.key]),
  }
}

export function setupHiddenCookie(centerId: string) {
  return `logocrm_setup_hidden_${centerId}`
}
