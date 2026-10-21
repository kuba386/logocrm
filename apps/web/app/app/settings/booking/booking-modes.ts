/**
 * Режимы онлайн-записи (0109) — общий модуль для серверной страницы и клиентских
 * форм. Не в booking-forms.tsx: константа из файла с 'use client' приходит в
 * серверный компонент заглушкой, и подпись режима рендерилась пустой.
 */
export type BookingMode = 'any' | 'hours' | 'closed'
export type WorkInterval = { weekday: number; starts_at: string; ends_at: string }

export const MODE_LABELS: Record<BookingMode, string> = {
  any: 'Любое время',
  hours: 'По рабочим часам',
  closed: 'Запись закрыта',
}
