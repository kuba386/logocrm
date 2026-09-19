'use client'

import { useActionState, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { FormError, FormNotice } from '@/components/ui/alert'
import { archiveDiagnostic, recordDiagnostic, type ClinicalState } from './clinical-actions'

const SOUNDS = ['р', 'л', 'ш', 'ж', 'с', 'з', 'ц', 'ч', 'щ']
const SOUND_STATUSES = [
  { code: '', label: 'норма' },
  { code: 'искажение', label: 'искажение' },
  { code: 'отсутствие', label: 'отсутствие' },
  { code: 'замена', label: 'замена' },
]
const SPEECH_AREAS = ['звукопроизношение', 'фонематика', 'лексика', 'грамматика', 'связная речь']

const SOUND_COLORS: Record<string, string> = {
  '': 'bg-muted text-muted-foreground',
  искажение: 'bg-accent text-accent-foreground',
  отсутствие: 'bg-destructive/10 text-destructive',
  замена: 'bg-primary/10 text-primary',
}

export type DiagnosticEntry = {
  id: string
  date: string
  conclusion: string | null
  teacherName: string | null
  sounds: Record<string, string>
  speechAreas: Record<string, number>
}

const initial: ClinicalState = { message: '' }

export function DiagnosticsPanel({
  studentId,
  entries,
  canWrite,
}: {
  studentId: string
  entries: DiagnosticEntry[]
  canWrite: boolean
}) {
  const router = useRouter()
  const [formOpen, setFormOpen] = useState(false)
  const [state, action] = useActionState(recordDiagnostic, initial)
  const [archiveState, setArchiveState] = useState<ClinicalState>(initial)
  const [pending, startTransition] = useTransition()

  function archive(id: string) {
    startTransition(async () => {
      const outcome = await archiveDiagnostic(studentId, id)
      setArchiveState(outcome)
      if (outcome.notice) router.refresh()
    })
  }

  const latest = entries[0]

  return (
    <div className="space-y-4">
      {/* Карта звуков последней записи — цветом, не только текстом. */}
      {latest ? (
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2">
            {SOUNDS.map((sound) => {
              const status = latest.sounds[sound] ?? ''
              return (
                <span
                  key={sound}
                  className={`rounded px-2 py-1 text-sm font-medium ${SOUND_COLORS[status] ?? SOUND_COLORS['']}`}
                  title={status || 'норма'}
                >
                  {sound}
                </span>
              )
            })}
          </div>
          {Object.keys(latest.speechAreas).length > 0 ? (
            <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm sm:grid-cols-3">
              {SPEECH_AREAS.filter((area) => latest.speechAreas[area] != null).map((area) => (
                <div key={area} className="flex justify-between gap-2">
                  <dt className="text-muted-foreground">{area}</dt>
                  <dd>{latest.speechAreas[area]}/5</dd>
                </div>
              ))}
            </dl>
          ) : null}
          {latest.conclusion ? <p className="text-sm">{latest.conclusion}</p> : null}
          <p className="text-xs text-muted-foreground">
            {new Date(latest.date).toLocaleDateString('ru-RU')}
            {latest.teacherName ? ` · ${latest.teacherName}` : ''}
          </p>
        </div>
      ) : (
        <p className="text-sm text-muted-foreground">Диагностики пока нет.</p>
      )}

      {entries.length > 1 ? (
        <details className="text-sm">
          <summary className="cursor-pointer text-muted-foreground">История ({entries.length - 1})</summary>
          <ul className="mt-2 space-y-2">
            {entries.slice(1).map((entry) => (
              <li key={entry.id} className="flex items-start justify-between gap-2 border-t border-border pt-2">
                <div>
                  <p className="text-xs text-muted-foreground">
                    {new Date(entry.date).toLocaleDateString('ru-RU')}
                    {entry.teacherName ? ` · ${entry.teacherName}` : ''}
                  </p>
                  {entry.conclusion ? <p>{entry.conclusion}</p> : null}
                </div>
                {canWrite ? (
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    disabled={pending}
                    onClick={() => archive(entry.id)}
                  >
                    Убрать
                  </Button>
                ) : null}
              </li>
            ))}
          </ul>
        </details>
      ) : null}

      <FormNotice message={archiveState.notice} />
      <FormError message={archiveState.message} />

      {canWrite ? (
        formOpen ? (
          <form action={action} className="space-y-3 border-t border-border pt-4">
            <input type="hidden" name="studentId" value={studentId} />
            <div className="space-y-1">
              <Label>Карта звуков</Label>
              <div className="grid grid-cols-3 gap-2 sm:grid-cols-5">
                {SOUNDS.map((sound) => (
                  <div key={sound} className="space-y-1">
                    <Label htmlFor={`sound_${sound}`} className="text-xs">
                      «{sound}»
                    </Label>
                    <Select id={`sound_${sound}`} name={`sound_${sound}`} defaultValue="">
                      {SOUND_STATUSES.map((s) => (
                        <option key={s.code} value={s.code}>
                          {s.label}
                        </option>
                      ))}
                    </Select>
                  </div>
                ))}
              </div>
            </div>
            <div className="space-y-1">
              <Label>Речевые области (1–5)</Label>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                {SPEECH_AREAS.map((area) => (
                  <div key={area} className="space-y-1">
                    <Label htmlFor={`area_${area}`} className="text-xs">
                      {area}
                    </Label>
                    <Input id={`area_${area}`} name={`area_${area}`} type="number" min={1} max={5} />
                  </div>
                ))}
              </div>
            </div>
            <div className="space-y-1">
              <Label htmlFor="conclusion">Заключение</Label>
              <Textarea id="conclusion" name="conclusion" />
            </div>
            <FormError message={state.message} />
            <FormNotice message={state.notice} />
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
            Записать диагностику
          </Button>
        )
      ) : null}
    </div>
  )
}
