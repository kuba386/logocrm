'use client'

import { useState } from 'react'
import { Button } from './button'
import { t } from '@/lib/messages'

/**
 * Разворачивает список строк, отрисованных на сервере, за один клик —
 * без второго похода на сервер: данные уже пришли целиком, обрезана только
 * отрисовка. Родитель не должен упираться в жёсткий предел без возможности
 * посмотреть дальше (Backlog.md, 23.09.2026 — дашборд родителя резал
 * платежи и взносы рассрочки до 10 записей насовсем).
 *
 * Текст кнопки берёт сам, через t(): функцию-проп с сервера в клиентский
 * компонент не передать (RSC-граница), а t() — чистая функция над
 * messages/ru.json, ей серверность не нужна.
 */
export function ShowMore({
  items,
  initialCount = 10,
}: {
  items: React.ReactNode[]
  initialCount?: number
}) {
  const [expanded, setExpanded] = useState(false)
  const visible = expanded ? items : items.slice(0, initialCount)
  const hidden = items.length - visible.length

  return (
    <>
      {visible}
      {hidden > 0 ? (
        <Button type="button" variant="ghost" size="sm" className="w-full" onClick={() => setExpanded(true)}>
          {t('dashboard', 'showMore', { count: hidden })}
        </Button>
      ) : null}
    </>
  )
}
