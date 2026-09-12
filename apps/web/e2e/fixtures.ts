// Значения из packages/db/supabase/fixtures/e2e.sql.
//
// Тесты ссылаются на данные по имени, а не ищут их по порядку в списке:
// иначе добавление ещё одного ученика в фикстуру ломало бы половину
// сценариев по причине, не имеющей отношения к делу.

export const PASSWORD = 'e2e-password-123'

export const USERS = {
  owner: 'owner-e2e@logocrm.kg',
  admin: 'admin-e2e@logocrm.kg',
  teacher: 'teacher-e2e@logocrm.kg',
  parent: 'parent-e2e@logocrm.kg',
} as const

export const TEACHERS = {
  nurgul: 'Нургуль Абдырахманова',
  aigul: 'Айгуль Кадырова',
} as const

export const STUDENTS = {
  ailin: 'Айлин Иванова',
  daniyar: 'Данияр Иванов',
  foreign: 'Чужой Ребёнок',
  timur: 'Тимур Сыдыков',
} as const

export const SERVICES = {
  individual: 'Индивидуальное занятие · 45 мин',
  group: 'Групповое занятие · 60 мин',
} as const

export const ROOM = 'Кабинет 1'

// Даты берутся далеко в будущем и от фиксированного понедельника: тест не
// должен зависеть от того, в какой день недели его запустили, а прошедшие
// даты вели бы себя иначе при отмене серии.
export const MONDAY = '2027-03-01'
export const WEDNESDAY = '2027-03-03'
export const FRIDAY = '2027-03-05'
export const MONTH_END = '2027-03-31'
