'use client'

import { useActionState, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { FormError, FormNotice } from '@/components/ui/alert'
import { setArticulation, type ClinicalState } from './clinical-actions'

export type ArticulationEntry = {
  updatedAt: string
  collectedAt: string | null
  lipsStructure: string[] | null
  lipsMobility: string | null
  teeth: string[] | null
  bite: string | null
  hardPalate: string | null
  softPalate: string[] | null
  tongueStructure: string[] | null
  tongueMobility: string | null
  frenulum: string | null
  notes: string | null
}

// Русские подписи кодов (0065) — латиница в базе, тексты только здесь.
const LIPS_STRUCTURE_CODES = [
  ['normal', 'норма'],
  ['thick', 'толстые'],
  ['thin', 'тонкие'],
  ['cleft', 'расщелина'],
  ['asymmetric', 'асимметрия'],
] as const
const TEETH_CODES = [
  ['normal', 'норма'],
  ['sparse', 'редкие'],
  ['crooked', 'кривые'],
  ['partially_missing', 'частично отсутствуют'],
] as const
const SOFT_PALATE_CODES = [
  ['normal', 'норма'],
  ['shortened', 'укороченное'],
  ['cleft', 'расщелина'],
  ['low_mobility', 'малоподвижное'],
] as const
const TONGUE_STRUCTURE_CODES = [
  ['normal', 'норма'],
  ['massive', 'массивный'],
  ['small', 'маленький'],
  ['short_frenulum', 'укороченная уздечка'],
] as const
const LIPS_MOBILITY_CODES = [
  ['normal', 'норма'],
  ['limited', 'ограничена'],
  ['paretic', 'паретична'],
] as const
const BITE_CODES = [
  ['normal', 'норма'],
  ['prognathia', 'прогнатия'],
  ['prognathism', 'прогения'],
  ['open_anterior', 'передний открытый'],
  ['open_lateral', 'боковой открытый'],
  ['crossbite', 'перекрёстный'],
] as const
const HARD_PALATE_CODES = [
  ['normal', 'норма'],
  ['gothic', 'готическое'],
  ['flattened', 'уплощённое'],
  ['cleft', 'расщелина'],
] as const
const TONGUE_MOBILITY_CODES = [
  ['normal', 'норма'],
  ['limited', 'ограничена'],
  ['paretic', 'паретична'],
] as const
const FRENULUM_CODES = [
  ['normal', 'норма'],
  ['shortened', 'укорочена'],
  ['clipped', 'подрезана'],
] as const

const ARRAY_FIELDS: {
  name: 'lipsStructure' | 'teeth' | 'softPalate' | 'tongueStructure'
  formKey: string
  label: string
  codes: readonly (readonly [string, string])[]
}[] = [
  { name: 'lipsStructure', formKey: 'lips_structure', label: 'Строение губ', codes: LIPS_STRUCTURE_CODES },
  { name: 'teeth', formKey: 'teeth', label: 'Зубы', codes: TEETH_CODES },
  { name: 'softPalate', formKey: 'soft_palate', label: 'Мягкое нёбо', codes: SOFT_PALATE_CODES },
  { name: 'tongueStructure', formKey: 'tongue_structure', label: 'Строение языка', codes: TONGUE_STRUCTURE_CODES },
]

const SINGLE_FIELDS: {
  name: 'lipsMobility' | 'bite' | 'hardPalate' | 'tongueMobility' | 'frenulum'
  formKey: string
  label: string
  codes: readonly (readonly [string, string])[]
}[] = [
  { name: 'lipsMobility', formKey: 'lips_mobility', label: 'Подвижность губ', codes: LIPS_MOBILITY_CODES },
  { name: 'bite', formKey: 'bite', label: 'Прикус', codes: BITE_CODES },
  { name: 'hardPalate', formKey: 'hard_palate', label: 'Твёрдое нёбо', codes: HARD_PALATE_CODES },
  { name: 'tongueMobility', formKey: 'tongue_mobility', label: 'Подвижность языка', codes: TONGUE_MOBILITY_CODES },
  { name: 'frenulum', formKey: 'frenulum', label: 'Подъязычная уздечка', codes: FRENULUM_CODES },
]

function labelFor(codes: readonly (readonly [string, string])[], code: string): string {
  return codes.find(([c]) => c === code)?.[1] ?? code
}

const initial: ClinicalState = { message: '' }

function summaryLine(entry: ArticulationEntry | null): string {
  if (!entry) return 'Осмотр не заполнен.'
  const totalFields = ARRAY_FIELDS.length + SINGLE_FIELDS.length
  const filled =
    ARRAY_FIELDS.filter((f) => (entry[f.name] as string[] | null)?.length).length +
    SINGLE_FIELDS.filter((f) => entry[f.name]).length
  return `Заполнено полей: ${filled} из ${totalFields}.`
}

export function ArticulationPanel({
  studentId,
  entry,
  canWrite,
}: {
  studentId: string
  entry: ArticulationEntry | null
  canWrite: boolean
}) {
  const [formOpen, setFormOpen] = useState(false)
  const [state, action] = useActionState(setArticulation, initial)

  return (
    <div className="space-y-4">
      <p className="text-sm text-muted-foreground">{summaryLine(entry)}</p>

      {entry ? (
        <dl className="grid grid-cols-1 gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
          {entry.collectedAt ? (
            <div>
              <dt className="text-muted-foreground">Дата осмотра</dt>
              <dd>{entry.collectedAt}</dd>
            </div>
          ) : null}
          {ARRAY_FIELDS.filter((f) => (entry[f.name] as string[] | null)?.length).map((f) => (
            <div key={f.name}>
              <dt className="text-muted-foreground">{f.label}</dt>
              <dd>{(entry[f.name] as string[]).map((c) => labelFor(f.codes, c)).join(', ')}</dd>
            </div>
          ))}
          {SINGLE_FIELDS.filter((f) => entry[f.name]).map((f) => (
            <div key={f.name}>
              <dt className="text-muted-foreground">{f.label}</dt>
              <dd>{labelFor(f.codes, entry[f.name] as string)}</dd>
            </div>
          ))}
          {entry.notes ? (
            <div className="sm:col-span-2">
              <dt className="text-muted-foreground">Дополнительно</dt>
              <dd className="whitespace-pre-wrap">{entry.notes}</dd>
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
            {/* key на updatedAt — та же причина, что в anamnesis-panel.tsx:
                после сохранения нужны свежие значения с сервера, не то, что
                React 19 сам оставит в неконтролируемых полях. */}
            <input type="hidden" name="studentId" value={studentId} />
            {entry ? <input type="hidden" name="expectedUpdatedAt" value={entry.updatedAt} /> : null}

            <div className="space-y-1">
              <Label htmlFor="collectedAt">Дата осмотра</Label>
              <Input id="collectedAt" name="collectedAt" type="date" defaultValue={entry?.collectedAt ?? ''} />
            </div>

            {ARRAY_FIELDS.map((f) => (
              <div key={f.name} className="space-y-1">
                <Label>{f.label}</Label>
                <div className="grid grid-cols-2 gap-1 text-sm sm:grid-cols-3">
                  {f.codes.map(([code, label]) => (
                    <label key={code} className="flex items-center gap-2">
                      <input
                        type="checkbox"
                        name={`${f.formKey}_${code}`}
                        defaultChecked={(entry?.[f.name] as string[] | null)?.includes(code) ?? false}
                      />
                      {label}
                    </label>
                  ))}
                </div>
              </div>
            ))}

            {SINGLE_FIELDS.map((f) => (
              <div key={f.name} className="space-y-1">
                <Label htmlFor={f.formKey}>{f.label}</Label>
                <Select id={f.formKey} name={f.formKey} defaultValue={entry?.[f.name] ?? ''}>
                  <option value="">— не указано —</option>
                  {f.codes.map(([code, label]) => (
                    <option key={code} value={code}>
                      {label}
                    </option>
                  ))}
                </Select>
              </div>
            ))}

            <div className="space-y-1">
              <Label htmlFor="notes">Дополнительно</Label>
              <Textarea id="notes" name="notes" defaultValue={entry?.notes ?? ''} />
            </div>

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
            {entry ? 'Редактировать' : 'Заполнить осмотр'}
          </Button>
        )
      ) : null}
    </div>
  )
}
