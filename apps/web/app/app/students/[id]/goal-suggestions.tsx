'use client'

import { useActionState, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { createGoalsFromDiagnostic, type ClinicalState } from './clinical-actions'

export type GoalSuggestion = {
  sound: string
  soundStatus: string
  stageTitle: string
  title: string
  alreadyActive: boolean
  /** Живая цель по этому звуку на любом этапе — предупреждение (0085 Р3). */
  existingStageTitle: string | null
  existingStatus: string | null
}

const initial: ClinicalState = { message: '' }

function SubmitButton({ disabled }: { disabled: boolean }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" disabled={disabled || pending}>
      {pending ? 'Создаём…' : 'Создать выбранные'}
    </Button>
  )
}

/**
 * Цели из последней диагностики (этап 9): какие звуки нарушены — те и
 * предлагаются, этап и формулировку отдаёт goal_suggestions в SQL. Уже
 * активные показаны без галочки — второй такой цели база не даст.
 */
export function GoalSuggestions({
  studentId,
  diagnosticId,
  suggestions,
}: {
  studentId: string
  diagnosticId: string
  suggestions: GoalSuggestion[]
}) {
  const [state, action] = useActionState(createGoalsFromDiagnostic, initial)
  const available = suggestions.filter((s) => !s.alreadyActive)
  // По умолчанию отмечены только звуки без живой цели: цель на другом этапе
  // или на паузе — повод подумать, а не создать «постановку» по инерции.
  const [selected, setSelected] = useState<Set<string>>(
    () => new Set(available.filter((s) => !s.existingStatus).map((s) => s.sound)),
  )

  if (suggestions.length === 0) return null

  const toggle = (sound: string) =>
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(sound)) next.delete(sound)
      else next.add(sound)
      return next
    })

  return (
    <form action={action} className="space-y-3 rounded-md border border-border bg-muted/30 p-3 print:hidden">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="diagnosticId" value={diagnosticId} />
      <div>
        <p className="text-sm font-medium">Предложенные цели</p>
        <p className="text-xs text-muted-foreground">По нарушенным звукам последней диагностики.</p>
      </div>
      <ul className="space-y-1.5">
        {suggestions.map((s) => (
          <li key={s.sound}>
            <label
              className={`flex items-center gap-2 text-sm ${s.alreadyActive ? 'text-muted-foreground' : 'cursor-pointer'}`}
            >
              <input
                type="checkbox"
                name="sounds"
                value={s.sound}
                checked={!s.alreadyActive && selected.has(s.sound)}
                disabled={s.alreadyActive}
                onChange={() => toggle(s.sound)}
                className="h-4 w-4"
              />
              <span>{s.title}</span>
              <span className="text-xs text-muted-foreground">
                ({s.alreadyActive
                  ? 'цель уже есть'
                  : s.existingStatus
                    ? `${s.soundStatus}; уже есть цель: ${s.existingStageTitle?.toLowerCase()}${s.existingStatus === 'paused' ? ', на паузе' : ''}`
                    : s.soundStatus})
              </span>
            </label>
          </li>
        ))}
      </ul>
      {available.length > 0 ? <SubmitButton disabled={selected.size === 0} /> : null}
      <FormError message={state.message || undefined} />
      <FormNotice message={state.notice} />
    </form>
  )
}
