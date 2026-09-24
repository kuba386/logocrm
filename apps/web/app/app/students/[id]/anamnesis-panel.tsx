'use client'

import { useActionState, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { FormError, FormNotice } from '@/components/ui/alert'
import { setAnamnesis, type ClinicalState } from './clinical-actions'

export type AnamnesisEntry = {
  updatedAt: string
  collectedAt: string | null
  pregnancyNumber: number | null
  birthNumber: number | null
  pregnancyCourse: string | null
  birthCourse: string | null
  apgarNote: string | null
  earlyDevelopment: string | null
  cooingAge: string | null
  babblingAge: string | null
  firstWordsAge: string | null
  phraseSpeechAge: string | null
  illnessesInjuries: string | null
  heredity: string | null
  upbringingConditions: string | null
  hearingNote: string | null
  visionNote: string | null
  notes: string | null
}

const TEXT_FIELDS: { name: keyof AnamnesisEntry; label: string; multiline?: boolean }[] = [
  { name: 'pregnancyCourse', label: 'Течение беременности', multiline: true },
  { name: 'birthCourse', label: 'Течение родов', multiline: true },
  { name: 'apgarNote', label: 'Оценка по Апгар' },
  { name: 'earlyDevelopment', label: 'Раннее развитие (сел/встал/пошёл)', multiline: true },
  { name: 'cooingAge', label: 'Гуление' },
  { name: 'babblingAge', label: 'Лепет' },
  { name: 'firstWordsAge', label: 'Первые слова' },
  { name: 'phraseSpeechAge', label: 'Фразовая речь' },
  { name: 'illnessesInjuries', label: 'Перенесённые заболевания, травмы', multiline: true },
  { name: 'heredity', label: 'Наследственность', multiline: true },
  { name: 'upbringingConditions', label: 'Условия воспитания', multiline: true },
  { name: 'hearingNote', label: 'Слух' },
  { name: 'visionNote', label: 'Зрение' },
  { name: 'notes', label: 'Дополнительно', multiline: true },
]

const initial: ClinicalState = { message: '' }

function summaryLine(entry: AnamnesisEntry | null): string {
  if (!entry) return 'Анамнез не заполнен.'
  const totalFields = TEXT_FIELDS.length + 2 // + pregnancyNumber, birthNumber
  const filled =
    TEXT_FIELDS.filter((f) => entry[f.name]).length +
    (entry.pregnancyNumber != null ? 1 : 0) +
    (entry.birthNumber != null ? 1 : 0)
  return `Заполнено полей: ${filled} из ${totalFields}.`
}

export function AnamnesisPanel({
  studentId,
  entry,
  canWrite,
}: {
  studentId: string
  entry: AnamnesisEntry | null
  canWrite: boolean
}) {
  const [formOpen, setFormOpen] = useState(false)
  const [state, action] = useActionState(setAnamnesis, initial)

  return (
    <div className="space-y-4">
      <p className="text-sm text-muted-foreground">{summaryLine(entry)}</p>

      {entry ? (
        <dl className="grid grid-cols-1 gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
          {entry.collectedAt ? (
            <div>
              <dt className="text-muted-foreground">Дата сбора</dt>
              <dd>{entry.collectedAt}</dd>
            </div>
          ) : null}
          {TEXT_FIELDS.filter((f) => entry[f.name]).map((f) => (
            <div key={f.name} className={f.multiline ? 'sm:col-span-2' : undefined}>
              <dt className="text-muted-foreground">{f.label}</dt>
              <dd className="whitespace-pre-wrap">{entry[f.name] as string}</dd>
            </div>
          ))}
          {entry.pregnancyNumber != null ? (
            <div>
              <dt className="text-muted-foreground">Беременность по счёту</dt>
              <dd>{entry.pregnancyNumber}</dd>
            </div>
          ) : null}
          {entry.birthNumber != null ? (
            <div>
              <dt className="text-muted-foreground">Роды по счёту</dt>
              <dd>{entry.birthNumber}</dd>
            </div>
          ) : null}
        </dl>
      ) : null}

      <FormNotice message={state.notice} />
      <FormError message={state.message} />

      {canWrite ? (
        formOpen ? (
          <form
            key={entry?.updatedAt ?? 'new'}
            action={action}
            className="space-y-3 border-t border-border pt-4"
          >
            {/* key на updatedAt — после сохранения revalidatePath даёт новый
                entry, форма должна показать свежие значения, а не то, что
                React 19 оставит в неконтролируемых полях сама (не гарантированно
                совпадает ни со старым, ни с новым состоянием). */}
            <input type="hidden" name="studentId" value={studentId} />
            {entry ? <input type="hidden" name="expectedUpdatedAt" value={entry.updatedAt} /> : null}

            <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
              <div className="space-y-1">
                <Label htmlFor="collectedAt">Дата сбора</Label>
                <Input
                  id="collectedAt"
                  name="collectedAt"
                  type="date"
                  defaultValue={entry?.collectedAt ?? ''}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="pregnancyNumber">Беременность по счёту</Label>
                <Input
                  id="pregnancyNumber"
                  name="pregnancyNumber"
                  type="number"
                  min={1}
                  max={20}
                  defaultValue={entry?.pregnancyNumber ?? ''}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="birthNumber">Роды по счёту</Label>
                <Input id="birthNumber" name="birthNumber" type="number" min={1} max={20} defaultValue={entry?.birthNumber ?? ''} />
              </div>
            </div>

            {TEXT_FIELDS.map((f) => (
              <div key={f.name} className="space-y-1">
                <Label htmlFor={f.name}>{f.label}</Label>
                {f.multiline ? (
                  <Textarea id={f.name} name={f.name} defaultValue={(entry?.[f.name] as string) ?? ''} />
                ) : (
                  <Input id={f.name} name={f.name} defaultValue={(entry?.[f.name] as string) ?? ''} />
                )}
              </div>
            ))}

            <div className="flex gap-2">
              <Button type="submit" size="sm">
                Сохранить
              </Button>
              <Button type="button" size="sm" variant="outline" onClick={() => setFormOpen(false)}>
                Отмена
              </Button>
            </div>
          </form>
        ) : (
          <Button type="button" size="sm" onClick={() => setFormOpen(true)}>
            {entry ? 'Редактировать' : 'Заполнить анамнез'}
          </Button>
        )
      ) : null}
    </div>
  )
}
