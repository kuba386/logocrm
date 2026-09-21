'use client'

import { useActionState, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'
import { GOAL_TREND_CLASSES, GOAL_TREND_LABELS, type GoalTrend } from '@/lib/goal-trend'
import { cn } from '@/lib/utils'
import { archiveGoal, createGoal, setGoalStatus, type ClinicalState } from './clinical-actions'

export type GoalStageOption = { id: string; title: string }

export type GoalProgressEntry = { id: string; date: string; score: number; note: string | null }

export type GoalEntry = {
  id: string
  title: string
  area: string | null
  sound: string | null
  stageTitle: string | null
  status: string
  targetDate: string | null
  progress: GoalProgressEntry[]
  trend: GoalTrend | null
}

const initial: ClinicalState = { message: '' }

function GoalCard({
  studentId,
  goal,
  canWrite,
}: {
  studentId: string
  goal: GoalEntry
  canWrite: boolean
}) {
  const router = useRouter()
  const [pending, startTransition] = useTransition()
  const [result, setResult] = useState<ClinicalState>(initial)
  const last = goal.progress[0]

  // router.refresh() — эти действия не форма с useActionState, Next не
  // перечитывает серверные данные страницы сам по себе после plain-вызова.
  function run(action: () => Promise<ClinicalState>) {
    startTransition(async () => {
      const outcome = await action()
      setResult(outcome)
      if (outcome.notice) router.refresh()
    })
  }

  return (
    <div className="space-y-2 rounded-md border border-border p-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <p className="font-medium">{goal.title}</p>
          <p className="text-xs text-muted-foreground">
            {[goal.stageTitle, goal.sound ? `звук «${goal.sound}»` : goal.area].filter(Boolean).join(' · ')}
            {goal.targetDate ? ` · срок ${new Date(goal.targetDate).toLocaleDateString('ru-RU')}` : ''}
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {goal.trend ? (
            <span
              className={cn('rounded-full px-2 py-0.5 text-xs font-medium', GOAL_TREND_CLASSES[goal.trend])}
            >
              {GOAL_TREND_LABELS[goal.trend]}
            </span>
          ) : null}
          {last ? <span className="rounded bg-muted px-2 py-0.5 text-sm">{last.score}/100</span> : null}
        </div>
      </div>

      {goal.progress.length > 0 ? (
        <details className="text-xs text-muted-foreground">
          <summary className="cursor-pointer">Динамика ({goal.progress.length})</summary>
          <ul className="mt-1 space-y-0.5">
            {goal.progress.map((p) => (
              <li key={p.id}>
                {new Date(p.date).toLocaleDateString('ru-RU')} — {p.score}
                {p.note ? ` (${p.note})` : ''}
              </li>
            ))}
          </ul>
        </details>
      ) : null}

      {canWrite ? (
        <div className="flex flex-wrap gap-2 pt-1">
          {goal.status !== 'achieved' ? (
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={pending}
              onClick={() => run(() => setGoalStatus(studentId, goal.id, 'achieved'))}
            >
              Достигнута
            </Button>
          ) : (
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={pending}
              onClick={() => run(() => setGoalStatus(studentId, goal.id, 'active'))}
            >
              Возобновить
            </Button>
          )}
          {goal.status === 'active' ? (
            <Button
              type="button"
              size="sm"
              variant="ghost"
              disabled={pending}
              onClick={() => run(() => setGoalStatus(studentId, goal.id, 'paused'))}
            >
              Пауза
            </Button>
          ) : null}
          <Button
            type="button"
            size="sm"
            variant="ghost"
            disabled={pending}
            onClick={() => run(() => archiveGoal(studentId, goal.id))}
          >
            Убрать
          </Button>
        </div>
      ) : null}

      <FormNotice message={result.notice} />
      <FormError message={result.message} />
    </div>
  )
}

export function GoalsPanel({
  studentId,
  goals,
  stages,
  canWrite,
}: {
  studentId: string
  goals: GoalEntry[]
  stages: GoalStageOption[]
  canWrite: boolean
}) {
  const [formOpen, setFormOpen] = useState(false)
  const [state, action] = useActionState(createGoal, initial)

  const active = goals.filter((g) => g.status !== 'achieved')
  const achieved = goals.filter((g) => g.status === 'achieved')

  return (
    <div className="space-y-4">
      {active.length > 0 ? (
        <div className="space-y-3">
          {active.map((goal) => (
            <GoalCard key={goal.id} studentId={studentId} goal={goal} canWrite={canWrite} />
          ))}
        </div>
      ) : (
        <p className="text-sm text-muted-foreground">Активных целей пока нет.</p>
      )}

      {achieved.length > 0 ? (
        <details className="text-sm">
          <summary className="cursor-pointer text-muted-foreground">Достигнутые ({achieved.length})</summary>
          <div className="mt-2 space-y-3">
            {achieved.map((goal) => (
              <GoalCard key={goal.id} studentId={studentId} goal={goal} canWrite={canWrite} />
            ))}
          </div>
        </details>
      ) : null}

      {canWrite ? (
        formOpen ? (
          <form action={action} className="space-y-3 border-t border-border pt-4">
            <input type="hidden" name="studentId" value={studentId} />
            <div className="space-y-1">
              <Label htmlFor="goalTitle">Формулировка</Label>
              <Input id="goalTitle" name="title" required placeholder="Автоматизация [р] в слогах" />
            </div>
            <div className="grid grid-cols-2 gap-2">
              <div className="space-y-1">
                <Label htmlFor="stageId">Этап</Label>
                <Select id="stageId" name="stageId" required defaultValue="">
                  <option value="">Выберите этап</option>
                  {stages.map((stage) => (
                    <option key={stage.id} value={stage.id}>
                      {stage.title}
                    </option>
                  ))}
                </Select>
              </div>
              <div className="space-y-1">
                <Label htmlFor="sound">Звук</Label>
                <Input id="sound" name="sound" placeholder="р" />
              </div>
            </div>
            <div className="grid grid-cols-2 gap-2">
              <div className="space-y-1">
                <Label htmlFor="area">Область</Label>
                <Input id="area" name="area" placeholder="звукопроизношение" />
              </div>
              <div className="space-y-1">
                <Label htmlFor="targetDate">Срок</Label>
                <Input id="targetDate" name="targetDate" type="date" />
              </div>
            </div>
            <FormError message={state.message} />
            <FormNotice message={state.notice} />
            <div className="flex gap-2">
              <Button type="submit" size="sm">
                Завести
              </Button>
              <Button type="button" size="sm" variant="outline" onClick={() => setFormOpen(false)}>
                Отмена
              </Button>
            </div>
          </form>
        ) : (
          <Button type="button" size="sm" onClick={() => setFormOpen(true)}>
            Новая цель
          </Button>
        )
      ) : null}
    </div>
  )
}
