'use client'

import { useEffect, useMemo, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { FormError, FormNotice } from '@/components/ui/alert'
import { GOAL_TREND_CLASSES, GOAL_TREND_LABELS, type GoalTrend } from '@/lib/goal-trend'
import { cn } from '@/lib/utils'
import { completeLesson, requestVoiceNote, type CompleteLessonState } from './actions'

export type StudentEntry = {
  id: string
  fullName: string
  age: string
  goals: {
    id: string
    title: string
    sound: string | null
    stageTitle: string | null
    lastScore: number | null
    trend: GoalTrend | null
  }[]
  previousNote: { parentSummary: string | null; soapPlan: string | null } | null
  attendanceStatusCode: string | null
  attendanceComment: string
}

export type ExerciseOption = {
  id: string
  title: string
  instructions: string | null
  sound: string | null
  stageCode: string | null
}

type Draft = Record<
  string,
  {
    attendanceStatusCode: string
    attendanceComment: string
    progress: Record<string, { score: string; note: string }>
    noteText: string
    homeworkFreeText: string
    homeworkExerciseIds: string[]
    homeworkDueInDays: string
  }
>

function draftKey(lessonId: string) {
  return `complete-lesson:${lessonId}`
}

function buildInitialDraft(students: StudentEntry[]): Draft {
  const draft: Draft = {}
  for (const student of students) {
    draft[student.id] = {
      attendanceStatusCode: student.attendanceStatusCode ?? '',
      attendanceComment: student.attendanceComment,
      progress: {},
      noteText: '',
      homeworkFreeText: '',
      homeworkExerciseIds: [],
      homeworkDueInDays: '',
    }
  }
  return draft
}

const initial: CompleteLessonState = { message: '' }

export function CompleteLessonForm({
  lessonId,
  students,
  attendanceStatuses,
  exercises,
  botName,
}: {
  lessonId: string
  students: StudentEntry[]
  attendanceStatuses: { code: string; name: string }[]
  exercises: ExerciseOption[]
  /** Без имени бота deep-link не собрать — кнопка просто не рисуется. */
  botName: string | null
}) {
  const router = useRouter()
  const [voiceBusy, setVoiceBusy] = useState<string | null>(null)
  const [voiceNotice, setVoiceNotice] = useState<{ studentId: string; text: string; href?: string } | null>(
    null,
  )

  async function startVoice(studentId: string, fullName: string) {
    setVoiceBusy(studentId)
    setVoiceNotice(null)
    const result = await requestVoiceNote(lessonId, studentId)
    setVoiceBusy(null)

    if ('message' in result) {
      setVoiceNotice({ studentId, text: result.message })
      return
    }

    // Не window.open: после await клика для мобильных Safari/Chrome уже
    // не «доверенный», всплывающее окно тихо блокируется — специалист
    // видит уведомление, но бот не открывается. Ссылку тем же приёмом,
    // что привязка аккаунта (telegram-panel.tsx) — открывает сам.
    setVoiceNotice({
      studentId,
      text: `Отправьте туда голосовое про ${fullName} — черновик придёт в переписку.`,
      href: `https://t.me/${botName}?start=voice_${result.token}`,
    })
  }
  const [draft, setDraft] = useState<Draft>(() => buildInitialDraft(students))
  const [loadedFromStorage, setLoadedFromStorage] = useState(false)
  const [result, setResult] = useState<CompleteLessonState>(initial)
  const [pending, startTransition] = useTransition()
  const [exerciseFilter, setExerciseFilter] = useState('')

  // Черновик — по lesson_id, переживает уход со страницы (docs/Roadmap:
  // «Частично заполненный экран переживает уход со страницы»). Читаем один
  // раз при монтировании — до этого момента localStorage недоступен на
  // сервере, поэтому не в useState-инициализаторе.
  useEffect(() => {
    try {
      const raw = window.localStorage.getItem(draftKey(lessonId))
      if (raw) setDraft(JSON.parse(raw) as Draft)
    } catch {
      // Приватный режим или испорченный черновик — начинаем с чистого листа.
    }
    setLoadedFromStorage(true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lessonId])

  useEffect(() => {
    if (!loadedFromStorage) return
    try {
      window.localStorage.setItem(draftKey(lessonId), JSON.stringify(draft))
    } catch {
      // Место кончилось или приватный режим — черновик просто не переживёт уход.
    }
  }, [draft, lessonId, loadedFromStorage])

  // Запись в Draft гарантированно есть на каждого участника — заведена в
  // buildInitialDraft и не удаляется; ! оправдан этим инвариантом, а не
  // просто заглушен.
  function entryOf(source: Draft, studentId: string): Draft[string] {
    return source[studentId]!
  }

  function update(studentId: string, patch: Partial<Draft[string]>) {
    setDraft((current) => ({ ...current, [studentId]: { ...entryOf(current, studentId), ...patch } }))
  }

  function updateProgress(studentId: string, goalId: string, patch: Partial<{ score: string; note: string }>) {
    setDraft((current) => {
      const entry = entryOf(current, studentId)
      return {
        ...current,
        [studentId]: {
          ...entry,
          progress: {
            ...entry.progress,
            [goalId]: { score: '', note: '', ...entry.progress[goalId], ...patch },
          },
        },
      }
    })
  }

  function toggleExercise(studentId: string, exerciseId: string) {
    setDraft((current) => {
      const entry = entryOf(current, studentId)
      const next = entry.homeworkExerciseIds.includes(exerciseId)
        ? entry.homeworkExerciseIds.filter((x) => x !== exerciseId)
        : [...entry.homeworkExerciseIds, exerciseId]
      return { ...current, [studentId]: { ...entry, homeworkExerciseIds: next } }
    })
  }

  const filteredExercises = useMemo(() => {
    const q = exerciseFilter.trim().toLowerCase()
    if (!q) return exercises
    return exercises.filter(
      (e) =>
        e.title.toLowerCase().includes(q) ||
        (e.sound ?? '').toLowerCase().includes(q) ||
        (e.stageCode ?? '').toLowerCase().includes(q),
    )
  }, [exercises, exerciseFilter])

  function submit() {
    const entries = students.map((s) => [s, entryOf(draft, s.id)] as const)

    const payload: Record<string, unknown> = {
      attendance: entries.map(([s, e]) => ({
        student_id: s.id,
        status_code: e.attendanceStatusCode || undefined,
        comment: e.attendanceComment.trim() || undefined,
      })),
      progress: entries.flatMap(([, e]) =>
        Object.entries(e.progress)
          .filter(([, v]) => v.score.trim() !== '')
          .map(([goalId, v]) => ({
            goal_id: goalId,
            score: Number(v.score),
            note: v.note.trim() || undefined,
          })),
      ),
      notes: entries
        .filter(([, e]) => e.noteText.trim() !== '')
        .map(([s, e]) => ({ student_id: s.id, parent_summary: e.noteText.trim() })),
      homework: entries
        .filter(([, e]) => e.homeworkFreeText.trim() !== '' || e.homeworkExerciseIds.length > 0)
        .map(([s, e]) => ({
          student_id: s.id,
          free_text: e.homeworkFreeText.trim() || undefined,
          exercise_ids: e.homeworkExerciseIds,
          due_in_days: e.homeworkDueInDays.trim() ? Number(e.homeworkDueInDays) : undefined,
        })),
    }

    startTransition(async () => {
      const outcome = await completeLesson(lessonId, payload)
      setResult(outcome)
      if (outcome.notice) {
        try {
          window.localStorage.removeItem(draftKey(lessonId))
        } catch {
          // Не критично — при следующем открытии черновик просто перезапишется.
        }
      }
    })
  }

  if (result.notice) {
    return (
      <Card>
        <CardContent className="space-y-4 pt-6">
          <FormNotice message={result.notice} />
          <Button size="sm" onClick={() => router.push('/app/schedule')}>
            К расписанию
          </Button>
        </CardContent>
      </Card>
    )
  }

  return (
    <div className="space-y-6">
      {students.map((student) => {
        const d = draft[student.id]
        if (!d) return null
        return (
          <Card key={student.id}>
            <CardHeader>
              <CardTitle className="text-lg">
                {student.fullName}
                {student.age ? <span className="ml-2 text-sm font-normal text-muted-foreground">{student.age}</span> : null}
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-5">
              {/* 1. Посещение --------------------------------------------------- */}
              <div className="space-y-1">
                <Label htmlFor={`attendance-${student.id}`}>Посещение</Label>
                <Select
                  id={`attendance-${student.id}`}
                  value={d.attendanceStatusCode}
                  onChange={(e) => update(student.id, { attendanceStatusCode: e.target.value })}
                >
                  {attendanceStatuses.map((s) => (
                    <option key={s.code} value={s.code}>
                      {s.name}
                    </option>
                  ))}
                </Select>
              </div>

              {/* 2. Цели --------------------------------------------------------- */}
              {student.goals.length > 0 ? (
                <div className="space-y-3">
                  <Label>Цели</Label>
                  {student.goals.map((goal) => (
                    <div key={goal.id} className="flex flex-wrap items-end gap-2 rounded-md border border-border p-3">
                      <div className="min-w-[10rem] flex-1 text-sm">
                        <div className="flex items-center gap-2">
                          <span>{goal.title}</span>
                          {goal.trend ? (
                            <span
                              className={cn(
                                'rounded-full px-2 py-0.5 text-xs font-medium',
                                GOAL_TREND_CLASSES[goal.trend],
                              )}
                            >
                              {GOAL_TREND_LABELS[goal.trend]}
                            </span>
                          ) : null}
                        </div>
                        <div className="text-xs text-muted-foreground">
                          {[goal.stageTitle, goal.sound ? `звук «${goal.sound}»` : null].filter(Boolean).join(' · ')}
                          {goal.lastScore != null ? ` · было ${goal.lastScore}` : ''}
                        </div>
                      </div>
                      <div className="w-24">
                        <Label htmlFor={`score-${goal.id}`} className="sr-only">
                          Оценка
                        </Label>
                        <Input
                          id={`score-${goal.id}`}
                          type="number"
                          min={0}
                          max={100}
                          placeholder="0–100"
                          value={d.progress[goal.id]?.score ?? ''}
                          onChange={(e) => updateProgress(student.id, goal.id, { score: e.target.value })}
                        />
                      </div>
                      <div className="w-40">
                        <Input
                          placeholder="Пометка"
                          value={d.progress[goal.id]?.note ?? ''}
                          onChange={(e) => updateProgress(student.id, goal.id, { note: e.target.value })}
                        />
                      </div>
                    </div>
                  ))}
                </div>
              ) : null}

              {/* 3. Прошлое занятие ---------------------------------------------- */}
              {student.previousNote ? (
                <details className="rounded-md border border-border p-3 text-sm">
                  <summary className="cursor-pointer text-muted-foreground">Прошлое занятие</summary>
                  <div className="mt-2 space-y-1 whitespace-pre-line">
                    {student.previousNote.soapPlan ? <p>План: {student.previousNote.soapPlan}</p> : null}
                    {student.previousNote.parentSummary ? <p>{student.previousNote.parentSummary}</p> : null}
                  </div>
                </details>
              ) : null}

              {/* 4. Заметка -------------------------------------------------------- */}
              <div className="space-y-1">
                <div className="flex items-center justify-between gap-2">
                  <Label htmlFor={`note-${student.id}`}>Заметка занятия</Label>
                  {botName ? (
                    <button
                      type="button"
                      className="text-sm underline underline-offset-2 disabled:opacity-50"
                      disabled={voiceBusy === student.id}
                      onClick={() => void startVoice(student.id, student.fullName)}
                    >
                      {voiceBusy === student.id ? 'Готовлю…' : 'Записать голосом'}
                    </button>
                  ) : null}
                </div>
                <Textarea
                  id={`note-${student.id}`}
                  placeholder="Что делали, как прошло — родителю"
                  value={d.noteText}
                  onChange={(e) => update(student.id, { noteText: e.target.value })}
                />
                {voiceNotice && voiceNotice.studentId === student.id ? (
                  <p className="text-sm text-muted-foreground">
                    {voiceNotice.href ? (
                      <a
                        href={voiceNotice.href}
                        target="_blank"
                        rel="noreferrer"
                        className="font-medium text-primary underline underline-offset-2"
                      >
                        Открыть бота
                      </a>
                    ) : null}
                    {voiceNotice.href ? ' — ' : null}
                    {voiceNotice.text}
                  </p>
                ) : null}
              </div>

              {/* 5. ДЗ -------------------------------------------------------------- */}
              <div className="space-y-2">
                <Label>Домашнее задание</Label>
                <Textarea
                  placeholder="Свободный текст"
                  value={d.homeworkFreeText}
                  onChange={(e) => update(student.id, { homeworkFreeText: e.target.value })}
                />
                <div className="flex items-center gap-2">
                  <Label htmlFor={`due-${student.id}`} className="whitespace-nowrap text-xs">
                    Срок, дней от сегодня
                  </Label>
                  <Input
                    id={`due-${student.id}`}
                    type="number"
                    min={1}
                    className="w-20"
                    value={d.homeworkDueInDays}
                    onChange={(e) => update(student.id, { homeworkDueInDays: e.target.value })}
                  />
                </div>
                <Input
                  placeholder="Поиск упражнения — по звуку, этапу, названию"
                  value={exerciseFilter}
                  onChange={(e) => setExerciseFilter(e.target.value)}
                />
                <div className="max-h-40 space-y-1 overflow-y-auto rounded-md border border-border p-2">
                  {filteredExercises.map((exercise) => (
                    <label key={exercise.id} className="flex items-start gap-2 text-sm">
                      <input
                        type="checkbox"
                        className="mt-1"
                        checked={d.homeworkExerciseIds.includes(exercise.id)}
                        onChange={() => toggleExercise(student.id, exercise.id)}
                      />
                      <span>
                        {exercise.title}
                        {exercise.sound ? ` · «${exercise.sound}»` : ''}
                      </span>
                    </label>
                  ))}
                  {filteredExercises.length === 0 ? (
                    <p className="text-xs text-muted-foreground">Ничего не найдено</p>
                  ) : null}
                </div>
              </div>
            </CardContent>
          </Card>
        )
      })}

      <FormError message={result.message} />

      {/* 6. Завершить — одна кнопка, один вызов (Р1–Р12, 0039). */}
      <Button onClick={submit} disabled={pending} size="lg">
        {pending ? 'Проводим…' : 'Завершить'}
      </Button>
    </div>
  )
}
