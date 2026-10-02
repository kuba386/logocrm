'use client'

import { useEffect, useState, type ReactNode } from 'react'
import { cn } from '@/lib/utils'

export type CardTab = {
  key: string
  label: string
  /** id разделов внутри вкладки — по ним ссылка вида #subscriptions открывает нужную вкладку. */
  sectionIds: string[]
  content: ReactNode
}

/**
 * Вкладки карточки ученика вместо одной длинной ленты. Все вкладки в DOM,
 * неактивные — hidden: переключение мгновенное, без похода на сервер, и формы
 * внутри не теряют введённое при переходе туда-обратно.
 *
 * Якоря живы: /app/students/<id>#subscriptions (ссылки из «Долгов» и
 * «Плательщиков») открывает вкладку, где лежит этот раздел, и прокручивает к нему.
 */
export function CardTabs({ tabs, initial }: { tabs: CardTab[]; initial: string }) {
  const [active, setActive] = useState(initial)

  useEffect(() => {
    function openFromHash() {
      const hash = decodeURIComponent(window.location.hash.slice(1))
      if (!hash) return
      const tab = tabs.find((t) => t.key === hash || t.sectionIds.includes(hash))
      if (!tab) return
      setActive(tab.key)
      requestAnimationFrame(() => document.getElementById(hash)?.scrollIntoView({ block: 'start' }))
    }
    openFromHash()
    window.addEventListener('hashchange', openFromHash)
    return () => window.removeEventListener('hashchange', openFromHash)
    // tabs — серверные данные, меняются только с новой страницей.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <div className="space-y-6">
      <div
        role="tablist"
        aria-label="Разделы карточки"
        className="-mx-6 flex gap-1 overflow-x-auto border-b border-border bg-background/95 px-6 backdrop-blur sm:sticky sm:top-0 sm:z-10 sm:mx-0 sm:px-0"
      >
        {tabs.map((tab) => {
          const selected = tab.key === active
          return (
            <button
              key={tab.key}
              type="button"
              role="tab"
              id={`tab-${tab.key}`}
              aria-selected={selected}
              aria-controls={`panel-${tab.key}`}
              onClick={() => setActive(tab.key)}
              className={cn(
                'shrink-0 whitespace-nowrap border-b-2 px-3 pb-2 pt-1 text-sm font-medium transition-colors',
                selected ? 'border-primary text-foreground' : 'border-transparent text-muted-foreground hover:text-foreground',
              )}
            >
              {tab.label}
            </button>
          )
        })}
      </div>

      {tabs.map((tab) => (
        <div
          key={tab.key}
          role="tabpanel"
          id={`panel-${tab.key}`}
          aria-labelledby={`tab-${tab.key}`}
          hidden={tab.key !== active}
          className="space-y-6"
        >
          {tab.content}
        </div>
      ))}
    </div>
  )
}
