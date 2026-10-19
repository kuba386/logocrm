/**
 * Слова интерфейса по типу центра (0104, ADR-013 Р7). Ключи — целые фразы, а
 * не слово с падежом: подстановка ломает род и число («Урок отменён», а не
 * «отменено»). Набор ключей у типов обязан совпадать — проверяет тест.
 */
export type CenterKind = 'speech' | 'education'

const speech = {
  teacher: 'Специалист',
  teachers: 'Специалисты',
  allTeachers: 'Все специалисты',
  room: 'Кабинет',
  rooms: 'Кабинеты',
  allRooms: 'Все кабинеты',
  roomPlaceholder: 'Кабинет 1',
  noRooms: 'Кабинетов пока нет',
  student: 'Ребёнок',
  students: 'Ученики',
  lesson: 'Занятие',
  lessons: 'Занятия',
}

export type CenterTerms = typeof speech

const education: CenterTerms = {
  teacher: 'Преподаватель',
  teachers: 'Преподаватели',
  allTeachers: 'Все преподаватели',
  room: 'Аудитория',
  rooms: 'Аудитории',
  allRooms: 'Все аудитории',
  roomPlaceholder: 'Аудитория 1',
  noRooms: 'Аудиторий пока нет',
  student: 'Ученик',
  students: 'Ученики',
  lesson: 'Урок',
  lessons: 'Уроки',
}

export const CENTER_TERMS: Record<CenterKind, CenterTerms> = { speech, education }

/** Неизвестный тип — словарь логопедического центра: так было до 0104. */
export function centerTerms(kind: string | null | undefined): CenterTerms {
  return kind === 'education' ? education : speech
}

export function isCenterKind(value: unknown): value is CenterKind {
  return value === 'speech' || value === 'education'
}
