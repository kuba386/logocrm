'use client'

import { conflictLabel, type AppError } from '@/lib/errors'

/**
 * Единственный способ показать накладку. Разбор ошибки живёт в lib/errors.ts,
 * здесь только вывод — иначе один и тот же конфликт покажется в трёх местах
 * тремя разными текстами.
 */
export function ConflictList({ error }: { error: AppError }) {
  if (!error.message && !error.conflicts) return null

  return (
    <div role="alert" className="space-y-2 rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
      <p>{error.message}</p>

      {error.retryable ? (
        <p className="text-xs">Обновите предпросмотр и попробуйте ещё раз.</p>
      ) : null}

      {error.conflicts?.length ? (
        <ul className="space-y-1 text-xs">
          {error.conflicts.map((day) => (
            <li key={`${day.day}-${day.starts_at}`}>
              <span className="font-medium">{new Date(day.starts_at).toLocaleDateString('ru-RU')}</span>
              {': '}
              {day.conflicts.map((conflict) => conflictLabel(conflict)).join('; ')}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  )
}
