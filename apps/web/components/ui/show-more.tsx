'use client'

import { useState } from 'react'
import { Button } from './button'

/**
 * Разворачивает список строк, отрисованных на сервере, за один клик —
 * без второго похода на сервер: данные уже пришли целиком, обрезана только
 * отрисовка. Родитель не должен упираться в жёсткий предел без возможности
 * посмотреть дальше (Backlog.md, 23.09.2026 — дашборд родителя резал
 * платежи и взносы рассрочки до 10 записей насовсем).
 */
export function ShowMore({
  items,
  initialCount = 10,
  moreLabel,
}: {
  items: React.ReactNode[]
  initialCount?: number
  /** Текст кнопки — из messages/ru.json на стороне вызывающего, не здесь. */
  moreLabel: (hidden: number) => string
}) {
  const [expanded, setExpanded] = useState(false)
  const visible = expanded ? items : items.slice(0, initialCount)
  const hidden = items.length - visible.length

  return (
    <>
      {visible}
      {hidden > 0 ? (
        <Button type="button" variant="ghost" size="sm" className="w-full" onClick={() => setExpanded(true)}>
          {moreLabel(hidden)}
        </Button>
      ) : null}
    </>
  )
}
