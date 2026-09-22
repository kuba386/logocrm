'use client'

import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Button, buttonVariants } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { cn } from '@/lib/utils'
import { approveLessonNote, type ClinicalState } from './clinical-actions'

export type NoteSoap = {
  subjective?: string | null
  objective?: string | null
  assessment?: string | null
  plan?: string | null
}

export type NoteGoalScore = { goalTitle: string; score: number; note: string | null }

export type NoteEntry = {
  id: string
  lessonId: string
  lessonAt: string | null
  status: string
  source: string
  parentSummary: string | null
  /** Только персоналу: родителю RPC отдаёт одно резюме (0036 Р4). */
  soap: NoteSoap | null
  rawTranscript: string | null
  goalScores: NoteGoalScore[]
}

const initial: ClinicalState = { message: '' }

const SOAP_LABELS: Array<[keyof NoteSoap, string]> = [
  ['subjective', 'Жалобы и настрой'],
  ['objective', 'Что делали'],
  ['assessment', 'Оценка'],
  ['plan', 'План'],
]

const SOURCE_LABELS: Record<string, string> = {
  voice: 'голосом',
  text: 'текстом',
}

function NoteCard({ studentId, note, canWrite }: { studentId: string; note: NoteEntry; canWrite: boolean }) {
  const router = useRouter()
  const [pending, startTransition] = useTransition()
  const [result, setResult] = useState<ClinicalState>(initial)
  const isDraft = note.status !== 'approved'
  const soapRows = SOAP_LABELS.filter(([key]) => note.soap?.[key])

  function approve() {
    startTransition(async () => {
      const outcome = await approveLessonNote(studentId, note.id)
      setResult(outcome)
      if (outcome.notice) router.refresh()
    })
  }

  return (
    <div className="space-y-2 rounded-md border border-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <p className="text-sm font-medium">
          {note.lessonAt ? new Date(note.lessonAt).toLocaleDateString('ru-RU') : 'Занятие'}
          <span className="text-muted-foreground"> · {SOURCE_LABELS[note.source] ?? note.source}</span>
        </p>
        <span
          className={cn(
            'rounded-full px-2 py-0.5 text-xs font-medium',
            isDraft ? 'bg-warning-bg text-warning' : 'bg-success-bg text-success',
          )}
        >
          {isDraft ? 'Черновик' : 'Утверждено'}
        </span>
      </div>

      {note.parentSummary ? (
        <p className="whitespace-pre-line text-sm">{note.parentSummary}</p>
      ) : (
        <p className="text-sm text-muted-foreground">Резюме для родителя не заполнено.</p>
      )}

      {soapRows.length > 0 ? (
        <details className="text-sm">
          <summary className="cursor-pointer text-muted-foreground">Разбор занятия (SOAP)</summary>
          <dl className="mt-2 space-y-2">
            {soapRows.map(([key, label]) => (
              <div key={key}>
                <dt className="text-xs uppercase tracking-wide text-muted-foreground">{label}</dt>
                <dd className="whitespace-pre-line">{note.soap?.[key]}</dd>
              </div>
            ))}
          </dl>
        </details>
      ) : null}

      {note.goalScores.length > 0 ? (
        <details className="text-sm">
          <summary className="cursor-pointer text-muted-foreground">
            {isDraft ? 'Предложенные оценки целей' : 'Оценки целей'} ({note.goalScores.length})
          </summary>
          <ul className="mt-1 space-y-0.5 text-xs text-muted-foreground">
            {note.goalScores.map((g, i) => (
              <li key={i}>
                {g.goalTitle} — {g.score}/100{g.note ? ` (${g.note})` : ''}
              </li>
            ))}
          </ul>
          {isDraft ? (
            <p className="mt-1 text-xs text-muted-foreground">Попадут в прогресс ребёнка после утверждения.</p>
          ) : null}
        </details>
      ) : null}

      {note.rawTranscript ? (
        <details className="text-sm">
          <summary className="cursor-pointer text-muted-foreground">Расшифровка</summary>
          <p className="mt-1 whitespace-pre-line text-xs text-muted-foreground">{note.rawTranscript}</p>
        </details>
      ) : null}

      {canWrite ? (
        <div className="flex flex-wrap gap-2 pt-1">
          {isDraft ? (
            <Button type="button" size="sm" disabled={pending} onClick={approve}>
              {pending ? 'Утверждаю…' : 'Утвердить'}
            </Button>
          ) : null}
          <Link
            href={`/app/schedule/lessons/${note.lessonId}/complete`}
            className={buttonVariants({ variant: 'ghost', size: 'sm' })}
          >
            Открыть занятие
          </Link>
        </div>
      ) : null}

      <FormNotice message={result.notice} />
      <FormError message={result.message} />
    </div>
  )
}

export function NotesPanel({
  studentId,
  notes,
  canWrite,
}: {
  studentId: string
  notes: NoteEntry[]
  canWrite: boolean
}) {
  if (notes.length === 0) {
    return <p className="text-sm text-muted-foreground">Заметок по занятиям пока нет.</p>
  }

  const drafts = notes.filter((n) => n.status !== 'approved')
  const approved = notes.filter((n) => n.status === 'approved')

  return (
    <div className="space-y-4">
      {drafts.length > 0 ? (
        <div className="space-y-3">
          {drafts.map((note) => (
            <NoteCard key={note.id} studentId={studentId} note={note} canWrite={canWrite} />
          ))}
        </div>
      ) : null}

      {approved.length > 0 ? (
        drafts.length > 0 ? (
          <details className="text-sm" open={approved.length <= 3}>
            <summary className="cursor-pointer text-muted-foreground">Утверждённые ({approved.length})</summary>
            <div className="mt-2 space-y-3">
              {approved.map((note) => (
                <NoteCard key={note.id} studentId={studentId} note={note} canWrite={canWrite} />
              ))}
            </div>
          </details>
        ) : (
          <div className="space-y-3">
            {approved.map((note) => (
              <NoteCard key={note.id} studentId={studentId} note={note} canWrite={canWrite} />
            ))}
          </div>
        )
      ) : null}
    </div>
  )
}
