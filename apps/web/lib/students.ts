import { ageLabel } from '@logocrm/core'

/** Статусы ученика для интерфейса. */
export const STUDENT_STATUS_LABELS: Record<string, string> = {
  lead: 'Заявка',
  active: 'Занимается',
  paused: 'Пауза',
  archived: 'В архиве',
}

export const STUDENT_STATUS_CLASSES: Record<string, string> = {
  lead: 'bg-accent text-accent-foreground',
  active: 'bg-primary/10 text-primary',
  paused: 'bg-muted text-muted-foreground',
  archived: 'bg-muted text-muted-foreground line-through',
}

export function statusLabel(status: string | null | undefined): string {
  if (!status) return '—'
  return STUDENT_STATUS_LABELS[status] ?? status
}

export const PAYER_RELATIONS = ['мама', 'папа', 'бабушка', 'дедушка', 'опекун', 'другое'] as const

/** Общая для списка и карточки строка возраста. */
export function studentAge(birthDate: string | null | undefined): string {
  return ageLabel(birthDate ?? null)
}
