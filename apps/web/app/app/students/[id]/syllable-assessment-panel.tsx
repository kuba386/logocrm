'use client'

import { useActionState, useEffect, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { FormError, FormNotice } from '@/components/ui/alert'
import { formatInTimeZone } from '@/lib/timezone'
import {
  archiveSyllableAssessment,
  recordSyllableAssessment,
  updateSyllableAssessment,
  type ClinicalState,
} from './clinical-actions'

// 14 классов слоговой структуры по А.К. Марковой (0066) — латинские коды
// в базе (текст «1».."14"), русские подписи только здесь.
const SYLLABLE_CLASSES: readonly (readonly [string, string])[] = [
  ['1', 'двусложные из открытых слогов («дети»)'],
  ['2', 'трёхсложные из открытых слогов («машина»)'],
  ['3', 'односложные закрытого типа («дом»)'],
  ['4', 'двусложные с одним закрытым слогом («диван»)'],
  ['5', 'двусложные со стечением согласных в середине слова («банка»)'],
  ['6', 'двусложные с закрытым слогом и стечением согласных («компот»)'],
  ['7', 'трёхсложные с закрытым слогом («бегемот»)'],
  ['8', 'трёхсложные со стечением согласных («комната»)'],
  ['9', 'трёхсложные со стечением и закрытым слогом («аквариум»)'],
  ['10', 'трёхсложные с двумя стечениями («таблетка»)'],
  ['11', 'односложные со стечением в начале/конце («стол», «тигр»)'],
  ['12', 'двусложные с двумя стечениями («кнопка»)'],
  ['13', 'четырёхсложные из открытых слогов («черепаха»)'],
  ['14', 'многосложные слова из сложных элементов («велосипедист»)'],
]

const ERROR_TYPES: readonly (readonly [string, string])[] = [
  ['omission', 'пропуск слога'],
  ['permutation', 'перестановка слогов'],
  ['addition', 'добавление слога/звука'],
  ['substitution', 'замена слога'],
  ['cluster_simplification', 'упрощение стечения согласных'],
  ['perseveration', 'персеверация (застревание на слоге)'],
  ['anticipation', 'антиципация (упреждение слога)'],
  ['contamination', 'контаминация (смешение слов)'],
]

function labelFor(codes: readonly (readonly [string, string])[], code: string): string {
  return codes.find(([c]) => c === code)?.[1] ?? code
}

export type SyllableAssessmentEntry = {
  id: string
  date: string
  updatedAt: string
  teacherName: string | null
  affectedClasses: string[]
  errorTypes: string[]
  conclusion: string | null
}

const initial: ClinicalState = { message: '' }

// date — календарная дата центра, не момент: та же UTC-полдень уловка,
// что в diagnostics-panel.tsx, чтобы пояс браузера не сдвинул день.
function dateLabel(date: string): string {
  return formatInTimeZone(`${date}T12:00:00Z`, 'UTC', { day: 'numeric', month: 'long', year: 'numeric' })
}

function EntryChips({ entry }: { entry: SyllableAssessmentEntry }) {
  return (
    <div className="space-y-2">
      {entry.affectedClasses.length > 0 ? (
        <div className="flex flex-wrap gap-1">
          {entry.affectedClasses.map((c) => (
            <span
              key={c}
              className="rounded bg-destructive/10 px-2 py-1 text-xs font-medium text-destructive"
              title={labelFor(SYLLABLE_CLASSES, c)}
            >
              Класс {c}
            </span>
          ))}
        </div>
      ) : null}
      {entry.errorTypes.length > 0 ? (
        <div className="flex flex-wrap gap-1">
          {entry.errorTypes.map((t) => (
            <span key={t} className="rounded bg-muted px-2 py-1 text-xs">
              {labelFor(ERROR_TYPES, t)}
            </span>
          ))}
        </div>
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
  entry: SyllableAssessmentEntry | null
  onSaved: () => void
  onCancel: () => void
}) {
  const [state, action] = useActionState(entry ? updateSyllableAssessment : recordSyllableAssessment, initial)

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
        <Label>Нарушенные классы слоговой структуры</Label>
        <div className="grid grid-cols-1 gap-1 text-sm sm:grid-cols-2">
          {SYLLABLE_CLASSES.map(([code, label]) => (
            <label key={code} className="flex items-start gap-2">
              <input
                type="checkbox"
                name={`class_${code}`}
                defaultChecked={entry?.affectedClasses.includes(code) ?? false}
                className="mt-1"
              />
              <span>
                <span className="font-medium">Класс {code}</span> — {label}
              </span>
            </label>
          ))}
        </div>
      </div>

      <div className="space-y-1">
        <Label>Преобладающие ошибки</Label>
        <div className="grid grid-cols-1 gap-1 text-sm sm:grid-cols-2">
          {ERROR_TYPES.map(([code, label]) => (
            <label key={code} className="flex items-center gap-2">
              <input
                type="checkbox"
                name={`error_${code}`}
                defaultChecked={entry?.errorTypes.includes(code) ?? false}
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

export function SyllableAssessmentPanel({
  studentId,
  entries,
  canWrite,
}: {
  studentId: string
  entries: SyllableAssessmentEntry[]
  canWrite: boolean
}) {
  const router = useRouter()
  // 'new' — форма записи, id строки — форма правки этой записи, null — обе закрыты.
  const [formTarget, setFormTarget] = useState<'new' | string | null>(null)
  const [archiveState, setArchiveState] = useState<ClinicalState>(initial)
  const [pending, startTransition] = useTransition()

  function archive(id: string) {
    startTransition(async () => {
      const outcome = await archiveSyllableAssessment(studentId, id)
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
          <EntryChips entry={latest} />
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
                <EntryChips entry={entry} />
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
