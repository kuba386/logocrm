/** Названия ролей для интерфейса. */
export const ROLE_LABELS: Record<string, string> = {
  owner: 'Владелец',
  admin: 'Администратор',
  teacher: 'Специалист',
  parent: 'Родитель',
}

export function roleLabel(role: string | null | undefined): string {
  if (!role) return '—'
  return ROLE_LABELS[role] ?? role
}

/** Роли, которые может выдавать текущий пользователь. */
export function assignableRoles(actorRole: string): { value: string; label: string }[] {
  if (actorRole === 'owner') {
    return [
      { value: 'owner', label: ROLE_LABELS.owner! },
      { value: 'admin', label: ROLE_LABELS.admin! },
      { value: 'teacher', label: ROLE_LABELS.teacher! },
      { value: 'parent', label: ROLE_LABELS.parent! },
    ]
  }
  // Администратор может назначать только специалистов — это же правило
  // продублировано в change_member_role, здесь только UI.
  return [{ value: 'teacher', label: ROLE_LABELS.teacher! }]
}

/** Роли, которые можно пригласить. Владельца пригласить нельзя. */
export function invitableRoles(actorRole: string): { value: string; label: string }[] {
  const roles = [
    { value: 'teacher', label: ROLE_LABELS.teacher! },
    { value: 'parent', label: ROLE_LABELS.parent! },
  ]
  if (actorRole === 'owner') {
    roles.unshift({ value: 'admin', label: ROLE_LABELS.admin! })
  }
  return roles
}
