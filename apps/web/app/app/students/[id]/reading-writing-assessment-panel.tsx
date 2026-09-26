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
  archiveReadingWritingAssessment,
  recordReadingWritingAssessment,
  updateReadingWritingAssessment,
  type ClinicalState,
} from './clinical-actions'

// Латинские коды в базе (0068), русские подписи только здесь.
// reading_method — описательная шкала прогрессии, БЕЗ кода 'normal' (в
// отличие от трёх осей нормы ниже) — способ чтения ожидаемо разный по
// возрасту, это не «норма/нарушение» (0068 Р4).
const READING_METHOD_CODES: readonly (readonly [string, string])[] = [
  ['letter_by_letter', 'по буквам'],
  ['syllable_by_syllable', 'по слогам'],
  ['whole_word_syllable', 'слого-словами (смешанно)'],
  ['whole_word', 'целыми словами'],
]
const READING_PACE_CODES: readonly (readonly [string, string])[] = [
  ['normal', 'норма'],
  ['slowed', 'замедлен'],
  ['accelerated', 'ускорен'],
]
const READING_COMPREHENSION_CODES: readonly (readonly [string, string])[] = [
  ['normal', 'норма'],
  ['impaired', 'нарушено'],
]
// Коды ошибок чтения и письма — РАЗНЫЕ множества (0068 Р6): некоторые
// текстовые коды совпадают ('omission', 'permutation'), но это два
// независимых списка с отдельными подписями и отдельными префиксами полей
// формы — не общая константа.
const READING_ERROR_CODES: readonly (readonly [string, string])[] = [
  ['substitution', 'замена букв'],
  ['omission', 'пропуск букв/слогов'],
  ['permutation', 'перестановка букв/слогов'],
  ['guessing', 'угадывающее чтение'],
  ['repetition', 'повторы'],
  ['stumbling', 'побуквенное спотыкание'],
]
const WRITING_QUALITY_CODES: readonly (readonly [string, string])[] = [
  ['normal', 'норма'],
  ['impaired', 'нарушено'],
]
const WRITING_ERROR_CODES: readonly (readonly [string, string])[] = [
  ['acoustic_substitution', 'замена по акустическому сходству'],
  ['optical_substitution', 'замена по оптическому сходству'],
  ['omission', 'пропуск букв'],
  ['permutation', 'перестановка букв'],
  ['word_boundary', 'слитное/раздельное написание'],
  ['mirror_writing', 'зеркальное письмо'],
  ['agrammatism', 'аграмматизмы'],
  ['incomplete_elements', 'недописывание элементов'],
]

function labelFor(codes: readonly (readonly [string, string])[], code: string | null): string | null {
  if (!code) return null
  return codes.find(([c]) => c === code)?.[1] ?? code
}

export type ReadingWritingAssessmentEntry = {
  id: string
  date: string
  updatedAt: string
  teacherName: string | null
  readingMethod: string | null
  readingPace: string | null
  readingComprehension: string | null
  readingErrors: string[]
  writingQuality: string | null
  writingErrors: string[]
  conclusion: string | null
}

const initial: ClinicalState = { message: '' }

// date — календарная дата центра, не момент: та же UTC-полдень уловка,
// что в остальных панелях речевой карты.
function dateLabel(date: string): string {
  return formatInTimeZone(`${date}T12:00:00Z`, 'UTC', { day: 'numeric', month: 'long', year: 'numeric' })
}

function ErrorChips({ codes, values }: { codes: readonly (readonly [string, string])[]; values: string[] }) {
  if (values.length === 0) return null
  return (
    <div className="flex flex-wrap gap-1">
      {values.map((v) => (
        <span key={v} className="rounded bg-muted px-2 py-1 text-xs">
          {labelFor(codes, v)}
        </span>
      ))}
    </div>
  )
}

function EntrySummary({ entry }: { entry: ReadingWritingAssessmentEntry }) {
  const scalarRows = [
    { label: 'Способ чтения', value: labelFor(READING_METHOD_CODES, entry.readingMethod) },
    { label: 'Темп чтения', value: labelFor(READING_PACE_CODES, entry.readingPace) },
    { label: 'Понимание прочитанного', value: labelFor(READING_COMPREHENSION_CODES, entry.readingComprehension) },
    { label: 'Качество письма', value: labelFor(WRITING_QUALITY_CODES, entry.writingQuality) },
  ].filter((r) => r.value !== null)

  return (
    <div className="space-y-2">
      {scalarRows.length > 0 ? (
        <dl className="grid grid-cols-1 gap-x-4 gap-y-1 text-sm sm:grid-cols-2">
          {scalarRows.map((r) => (
            <div key={r.label} className="flex justify-between gap-2">
              <dt className="text-muted-foreground">{r.label}</dt>
              <dd>{r.value}</dd>
            </div>
          ))}
        </dl>
      ) : null}
      <ErrorChips codes={READING_ERROR_CODES} values={entry.readingErrors} />
      <ErrorChips codes={WRITING_ERROR_CODES} values={entry.writingErrors} />
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
  entry: ReadingWritingAssessmentEntry | null
  onSaved: () => void
  onCancel: () => void
}) {
  const [state, action] = useActionState(entry ? updateReadingWritingAssessment : recordReadingWritingAssessment, initial)

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

      <div className="space-y-1">
        <Label htmlFor="readingMethod">Способ чтения</Label>
        <Select id="readingMethod" name="readingMethod" defaultValue={entry?.readingMethod ?? ''}>
          <option value="">— не оценено —</option>
          {READING_METHOD_CODES.map(([code, label]) => (
            <option key={code} value={code}>
              {label}
            </option>
          ))}
        </Select>
      </div>

      <div className="space-y-1">
        <Label htmlFor="readingPace">Темп чтения</Label>
        <Select id="readingPace" name="readingPace" defaultValue={entry?.readingPace ?? ''}>
          <option value="">— не оценено —</option>
          {READING_PACE_CODES.map(([code, label]) => (
            <option key={code} value={code}>
              {label}
            </option>
          ))}
        </Select>
      </div>

      <div className="space-y-1">
        <Label htmlFor="readingComprehension">Понимание прочитанного</Label>
        <Select id="readingComprehension" name="readingComprehension" defaultValue={entry?.readingComprehension ?? ''}>
          <option value="">— не оценено —</option>
          {READING_COMPREHENSION_CODES.map(([code, label]) => (
            <option key={code} value={code}>
              {label}
            </option>
          ))}
        </Select>
      </div>

      <div className="space-y-1">
        <Label>Ошибки чтения</Label>
        <div className="grid grid-cols-1 gap-1 text-sm sm:grid-cols-2">
          {READING_ERROR_CODES.map(([code, label]) => (
            <label key={code} className="flex items-center gap-2">
              <input
                type="checkbox"
                name={`readingError_${code}`}
                defaultChecked={entry?.readingErrors.includes(code) ?? false}
              />
              {label}
            </label>
          ))}
        </div>
      </div>

      <div className="space-y-1">
        <Label htmlFor="writingQuality">Качество письма</Label>
        <Select id="writingQuality" name="writingQuality" defaultValue={entry?.writingQuality ?? ''}>
          <option value="">— не оценено —</option>
          {WRITING_QUALITY_CODES.map(([code, label]) => (
            <option key={code} value={code}>
              {label}
            </option>
          ))}
        </Select>
      </div>

      <div className="space-y-1">
        <Label>Ошибки письма</Label>
        <div className="grid grid-cols-1 gap-1 text-sm sm:grid-cols-2">
          {WRITING_ERROR_CODES.map(([code, label]) => (
            <label key={code} className="flex items-center gap-2">
              <input
                type="checkbox"
                name={`writingError_${code}`}
                defaultChecked={entry?.writingErrors.includes(code) ?? false}
              />
              {label}
            </label>
          ))}
        </div>
      </div>

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

export function ReadingWritingAssessmentPanel({
  studentId,
  entries,
  canWrite,
}: {
  studentId: string
  entries: ReadingWritingAssessmentEntry[]
  canWrite: boolean
}) {
  const router = useRouter()
  // 'new' — форма записи, id строки — форма правки этой записи, null — обе закрыты.
  const [formTarget, setFormTarget] = useState<'new' | string | null>(null)
  const [archiveState, setArchiveState] = useState<ClinicalState>(initial)
  const [pending, startTransition] = useTransition()

  function archive(id: string) {
    startTransition(async () => {
      const outcome = await archiveReadingWritingAssessment(studentId, id)
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
