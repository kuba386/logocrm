'use client'

import { useActionState, useEffect, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { FormError, FormNotice } from '@/components/ui/alert'
import { formatInTimeZone } from '@/lib/timezone'
import {
  archiveProsodyAssessment,
  recordProsodyAssessment,
  updateProsodyAssessment,
  type ClinicalState,
} from './clinical-actions'

// Латинские коды в базе (0067), русские подписи только здесь. 'normal' —
// единый код нормы во всех шести полях (0067 Р2); NULL — «не оценивалось»,
// поэтому у каждого поля есть отдельный вариант «— не оценено —», а не
// только норма/нарушение.
const TEMPO_CODES: readonly (readonly [string, string])[] = [
  ['normal', 'норма'],
  ['accelerated', 'ускорен (тахилалия)'],
  ['slowed', 'замедлен (брадилалия)'],
]
const RHYTHM_CODES: readonly (readonly [string, string])[] = [
  ['normal', 'норма'],
  ['disrupted', 'нарушен'],
]
const INTONATION_CODES: readonly (readonly [string, string])[] = [
  ['normal', 'норма'],
  ['insufficient', 'недостаточно выразительна'],
  ['monotone', 'монотонна'],
]
const BREATHING_CODES: readonly (readonly [string, string])[] = [
  ['normal', 'норма'],
  ['shallow', 'поверхностное'],
  ['weak_exhale', 'слабый выдох'],
  ['uneven', 'неровное'],
]
const VOICE_CODES: readonly (readonly [string, string])[] = [
  ['normal', 'норма'],
  ['weak', 'слабый'],
  ['hoarse', 'хриплый'],
  ['nasal', 'назализованный'],
  ['monotone', 'монотонный'],
]
const LOGICAL_STRESS_CODES: readonly (readonly [string, string])[] = [
  ['normal', 'норма'],
  ['incorrect', 'расставлено неверно'],
  ['absent', 'отсутствует'],
]

const FIELDS: {
  name: 'tempo' | 'rhythm' | 'intonation' | 'breathing' | 'voice' | 'logicalStress'
  formKey: string
  label: string
  codes: readonly (readonly [string, string])[]
}[] = [
  { name: 'tempo', formKey: 'tempo', label: 'Темп речи', codes: TEMPO_CODES },
  { name: 'rhythm', formKey: 'rhythm', label: 'Ритм речи', codes: RHYTHM_CODES },
  { name: 'intonation', formKey: 'intonation', label: 'Интонация', codes: INTONATION_CODES },
  { name: 'breathing', formKey: 'breathing', label: 'Речевое дыхание', codes: BREATHING_CODES },
  { name: 'voice', formKey: 'voice', label: 'Голос', codes: VOICE_CODES },
  { name: 'logicalStress', formKey: 'logicalStress', label: 'Логическое ударение', codes: LOGICAL_STRESS_CODES },
]

function labelFor(codes: readonly (readonly [string, string])[], code: string | null): string | null {
  if (!code) return null
  return codes.find(([c]) => c === code)?.[1] ?? code
}

export type ProsodyAssessmentEntry = {
  id: string
  date: string
  updatedAt: string
  teacherName: string | null
  tempo: string | null
  rhythm: string | null
  intonation: string | null
  breathing: string | null
  voice: string | null
  logicalStress: string | null
  conclusion: string | null
}

const initial: ClinicalState = { message: '' }

// date — календарная дата центра, не момент: та же UTC-полдень уловка, что
// в diagnostics-panel.tsx/syllable-assessment-panel.tsx.
function dateLabel(date: string): string {
  return formatInTimeZone(`${date}T12:00:00Z`, 'UTC', { day: 'numeric', month: 'long', year: 'numeric' })
}

function EntrySummary({ entry }: { entry: ProsodyAssessmentEntry }) {
  const rows = FIELDS.map((f) => ({ label: f.label, value: labelFor(f.codes, entry[f.name]) })).filter(
    (r) => r.value !== null,
  )

  return (
    <div className="space-y-2">
      {rows.length > 0 ? (
        <dl className="grid grid-cols-1 gap-x-4 gap-y-1 text-sm sm:grid-cols-2">
          {rows.map((r) => (
            <div key={r.label} className="flex justify-between gap-2">
              <dt className="text-muted-foreground">{r.label}</dt>
              <dd>{r.value}</dd>
            </div>
          ))}
        </dl>
      ) : null}
      {entry.conclusion ? <p className="text-sm">{entry.conclusion}</p> : null}
    </div>
  )
}

function EntryForm({
  studentId,
  entry,
  onSaved,
  onCancel,
}: {
  studentId: string
  entry: ProsodyAssessmentEntry | null
  onSaved: () => void
  onCancel: () => void
}) {
  const [state, action] = useActionState(entry ? updateProsodyAssessment : recordProsodyAssessment, initial)

  // Сервер — источник истины (нет оптимистичного UI): форма закрывается
  // только после подтверждённого notice, не по клику «Сохранить».
  useEffect(() => {
    if (state.notice) onSaved()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.notice])

  return (
    <form action={action} className="space-y-3 border-t border-border pt-4">
      <input type="hidden" name="studentId" value={studentId} />
      {entry ? <input type="hidden" name="id" value={entry.id} /> : null}
      {entry ? <input type="hidden" name="expectedUpdatedAt" value={entry.updatedAt} /> : null}

      <div className="space-y-1">
        <Label htmlFor="date">Дата обследования</Label>
        <Input id="date" name="date" type="date" defaultValue={entry?.date ?? ''} />
      </div>

      {FIELDS.map((f) => (
        <div key={f.name} className="space-y-1">
          <Label htmlFor={f.formKey}>{f.label}</Label>
          <Select id={f.formKey} name={f.formKey} defaultValue={entry?.[f.name] ?? ''}>
            <option value="">— не оценено —</option>
            {f.codes.map(([code, label]) => (
              <option key={code} value={code}>
                {label}
              </option>
            ))}
          </Select>
        </div>
      ))}

      <div className="space-y-1">
        <Label htmlFor="conclusion">Заключение</Label>
        <Textarea id="conclusion" name="conclusion" defaultValue={entry?.conclusion ?? ''} />
      </div>

      <FormError message={state.message} />
      <div className="flex gap-2">
        <Button type="submit" size="sm">
          Сохранить
        </Button>
        <Button type="button" size="sm" variant="outline" onClick={onCancel}>
          Отмена
        </Button>
      </div>
    </form>
  )
}

export function ProsodyAssessmentPanel({
  studentId,
  entries,
  canWrite,
}: {
  studentId: string
  entries: ProsodyAssessmentEntry[]
  canWrite: boolean
}) {
  const router = useRouter()
  // 'new' — форма записи, id строки — форма правки этой записи, null — обе закрыты.
  const [formTarget, setFormTarget] = useState<'new' | string | null>(null)
  const [archiveState, setArchiveState] = useState<ClinicalState>(initial)
  const [pending, startTransition] = useTransition()

  function archive(id: string) {
    startTransition(async () => {
      const outcome = await archiveProsodyAssessment(studentId, id)
      setArchiveState(outcome)
      if (outcome.notice) router.refresh()
    })
  }

  function closeForm() {
    setFormTarget(null)
    router.refresh()
  }

  const latest = entries[0]
  const history = entries.slice(1)

  return (
    <div className="space-y-4">
      {latest ? (
        <div className="space-y-2">
          <EntrySummary entry={latest} />
          <div className="flex items-center justify-between gap-2">
            <p className="text-xs text-muted-foreground">
              {dateLabel(latest.date)}
              {latest.teacherName ? ` · ${latest.teacherName}` : ''}
            </p>
            {canWrite && formTarget === null ? (
              <div className="flex gap-1">
                <Button type="button" variant="ghost" size="sm" onClick={() => setFormTarget(latest.id)}>
                  Редактировать
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  disabled={pending}
                  onClick={() => archive(latest.id)}
                >
                  Убрать
                </Button>
              </div>
            ) : null}
          </div>
        </div>
      ) : (
        <p className="text-sm text-muted-foreground">Обследований пока нет.</p>
      )}

      {formTarget === latest?.id ? (
        <EntryForm studentId={studentId} entry={latest} onSaved={closeForm} onCancel={() => setFormTarget(null)} />
      ) : null}

      {history.length > 0 ? (
        <details className="text-sm">
          <summary className="cursor-pointer text-muted-foreground">История ({history.length})</summary>
          <ul className="mt-2 space-y-3">
            {history.map((entry) => (
              <li key={entry.id} className="space-y-2 border-t border-border pt-2">
                <EntrySummary entry={entry} />
                <div className="flex items-center justify-between gap-2">
                  <p className="text-xs text-muted-foreground">
                    {dateLabel(entry.date)}
                    {entry.teacherName ? ` · ${entry.teacherName}` : ''}
                  </p>
                  {canWrite && formTarget === null ? (
                    <div className="flex gap-1">
                      <Button type="button" variant="ghost" size="sm" onClick={() => setFormTarget(entry.id)}>
                        Редактировать
                      </Button>
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        disabled={pending}
                        onClick={() => archive(entry.id)}
                      >
                        Убрать
                      </Button>
                    </div>
                  ) : null}
                </div>
                {formTarget === entry.id ? (
                  <EntryForm
                    studentId={studentId}
                    entry={entry}
                    onSaved={closeForm}
                    onCancel={() => setFormTarget(null)}
                  />
                ) : null}
              </li>
            ))}
          </ul>
        </details>
      ) : null}

      <FormNotice message={archiveState.notice} />
      <FormError message={archiveState.message} />

      {canWrite ? (
        formTarget === 'new' ? (
          <EntryForm studentId={studentId} entry={null} onSaved={closeForm} onCancel={() => setFormTarget(null)} />
        ) : formTarget === null ? (
          <Button type="button" size="sm" onClick={() => setFormTarget('new')}>
            Записать новое обследование
          </Button>
        ) : null
      ) : null}
    </div>
  )
}
