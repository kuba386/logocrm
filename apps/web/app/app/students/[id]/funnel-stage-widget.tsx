'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { cn } from '@/lib/utils'
import { allowedFunnelTransitions, funnelStageLabel, FUNNEL_STAGE_CLASSES, type FunnelStage } from '@/lib/students'
import { moveFunnelStage, type FunnelState } from './funnel-actions'

const initial: FunnelState = {}

function MoveButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant="outline" disabled={pending}>
      {children}
    </Button>
  )
}

/** Одна кнопка — один переход, своей формой: нельзя вложить <button> в <button>. */
function MoveForm({
  studentId,
  toStage,
  action,
}: {
  studentId: string
  toStage: FunnelStage
  action: (formData: FormData) => void
}) {
  return (
    <form action={action} className="inline">
      <input type="hidden" name="studentId" value={studentId} />
      <input type="hidden" name="toStage" value={toStage} />
      <MoveButton>→ {funnelStageLabel(toStage)}</MoveButton>
    </form>
  )
}

/**
 * Бейдж этапа воронки + кнопки разрешённых переходов (0055 Р3/Р4). Кнопки —
 * подсказка из allowedFunnelTransitions (зеркало графа в SQL); отказ базы
 * (например архивный ученик) приходит текстом set_funnel_stage, компонент
 * его не парсит.
 */
export function FunnelStageWidget({ studentId, stage }: { studentId: string; stage: FunnelStage }) {
  const [state, action] = useActionState(moveFunnelStage, initial)
  const options = allowedFunnelTransitions(stage)

  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-wrap items-center gap-2">
        <span
          className={cn('rounded-full px-2 py-0.5 text-xs', FUNNEL_STAGE_CLASSES[stage] ?? 'bg-muted text-muted-foreground')}
        >
          Воронка: {funnelStageLabel(stage)}
        </span>
        {options.map((to) => (
          <MoveForm key={to} studentId={studentId} toStage={to} action={action} />
        ))}
      </div>
      <FormError message={state.error} />
      <FormNotice message={state.notice} />
    </div>
  )
}
