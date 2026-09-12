/** Названия ролей для интерфейса. Список — memberships_role_check (0001, 0026). */
export const ROLE_LABELS: Record<string, string> = {
  owner: 'Владелец',
  admin: 'Администратор',
  teacher: 'Специалист',
  parent: 'Родитель',
  registrar: 'Регистратор',
  finance: 'Бухгалтер',
}

export function roleLabel(role: string | null | undefined): string {
  if (!role) return '—'
  return ROLE_LABELS[role] ?? role
}

/** Стойка: ученики, расписание, абонементы, платежи (can_front_desk, 0026). */
export function isFrontDesk(role: string | null | undefined): boolean {
  return role === 'owner' || role === 'admin' || role === 'registrar'
}

/** Деньги сотрудников: расходы, ставки, зарплата, периоды (can_finance, 0027). */
export function isFinance(role: string | null | undefined): boolean {
  return role === 'owner' || role === 'admin' || role === 'finance'
}

/** Платежи и рассрочки клиентов — обе новые роли (can_payments, 0026). */
export function canPayments(role: string | null | undefined): boolean {
  return isFrontDesk(role) || role === 'finance'
}

/**
 * Роли, которые может выдавать текущий пользователь. Та же лестница, что в
 * change_member_role (0028): владелец — любую, администратор — только три
 * роли сотрудников. Здесь только подсказка меню; отказ приходит из базы.
 */
export function assignableRoles(actorRole: string): { value: string; label: string }[] {
  if (actorRole === 'owner') {
    return ['owner', 'admin', 'teacher', 'registrar', 'finance', 'parent'].map((value) => ({
      value,
      label: ROLE_LABELS[value]!,
    }))
  }
  return ['teacher', 'registrar', 'finance'].map((value) => ({ value, label: ROLE_LABELS[value]! }))
}

/** Роли, которые можно пригласить (create_invitation, 0028). Владельца пригласить нельзя. */
export function invitableRoles(actorRole: string): { value: string; label: string }[] {
  const roles = ['teacher', 'registrar', 'finance', 'parent'].map((value) => ({ value, label: ROLE_LABELS[value]! }))
  if (actorRole === 'owner') {
    roles.unshift({ value: 'admin', label: ROLE_LABELS.admin! })
  }
  return roles
}
