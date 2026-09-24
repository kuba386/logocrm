'use client'

import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { Search } from 'lucide-react'
import { formatKgPhone } from '@logocrm/core'
import { Input } from '@/components/ui/input'
import { dayInZone, timeInZone } from '@/lib/timezone'
import { statusLabel } from '@/lib/students'
import { cn } from '@/lib/utils'
import { globalSearch, type SearchKind, type SearchRow } from './search-actions'

const KIND_LABELS: Record<SearchKind, string> = {
  student: 'Ученики',
  payer: 'Плательщики',
  lesson: 'Ближайшие занятия',
  group: 'Группы',
}
const KIND_ORDER: SearchKind[] = ['student', 'payer', 'lesson', 'group']

function hrefFor(row: SearchRow): string {
  switch (row.kind) {
    case 'student':
      return `/app/students/${row.id}`
    case 'payer':
      return `/app/payers/${row.id}`
    case 'lesson':
      // Неделю посчитала база в поясе центра (0062 Р6); подсветки занятия у
      // расписания нет — открывается неделя.
      return row.weekStart ? `/app/schedule?week=${row.weekStart}` : '/app/schedule'
    case 'group':
      return '/app/groups'
  }
}

function describe(row: SearchRow, timeZone: string): string {
  switch (row.kind) {
    case 'student':
      return [row.subtitle, row.extra ? `${row.extra} лет` : null, row.status === 'archived' ? statusLabel(row.status) : null]
        .filter(Boolean)
        .join(' · ')
    case 'payer':
      return [row.subtitle ? formatKgPhone(row.subtitle) : null, row.extra ? `дети: ${row.extra}` : 'детей нет'].filter(Boolean).join(' · ')
    case 'lesson':
      return [row.startsAt ? `${dayInZone(row.startsAt, timeZone)}, ${timeInZone(row.startsAt, timeZone)}` : null, row.subtitle]
        .filter(Boolean)
        .join(' · ')
    case 'group':
      return row.subtitle ?? ''
  }
}

/**
 * Одно поле для стойки на звонке: имя или телефон → ребёнок, родитель,
 * ближайшее занятие, группа. Показывается только ответ на ПОСЛЕДНИЙ запрос
 * (порядковый номер): ответ на «Айж» не должен перекрыть ответ на «Айжан»
 * — оператор позвонил бы не тому родителю. Оптимистичного состояния нет.
 */
export function GlobalSearch({ canSeeContacts, timeZone, compact }: { canSeeContacts: boolean; timeZone: string; compact?: boolean }) {
  const router = useRouter()
  const [query, setQuery] = useState('')
  const [rows, setRows] = useState<SearchRow[]>([])
  const [error, setError] = useState<string | undefined>(undefined)
  const [pending, setPending] = useState(false)
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(-1)
  const requestId = useRef(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const rootRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const q = query.trim()
    if (q.length < 2) {
      requestId.current += 1
      setRows([])
      setError(undefined)
      setPending(false)
      return
    }
    const id = ++requestId.current
    setPending(true)
    const timer = setTimeout(async () => {
      const result = await globalSearch(q)
      if (id !== requestId.current) return
      setRows(result.rows)
      setError(result.error)
      setPending(false)
      setActive(-1)
    }, 250)
    return () => clearTimeout(timer)
  }, [query])

  // «/» фокусирует поле, как в почте; Escape — закрывает.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const target = e.target as HTMLElement | null
      const typing = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)
      if (e.key === '/' && !typing) {
        e.preventDefault()
        inputRef.current?.focus()
      }
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])

  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onClick)
    return () => document.removeEventListener('mousedown', onClick)
  }, [])

  const ordered = KIND_ORDER.flatMap((kind) => rows.filter((r) => r.kind === kind).sort((a, b) => a.rank - b.rank))
  const groups = KIND_ORDER.map((kind) => ({ kind, rows: ordered.filter((r) => r.kind === kind) })).filter((g) => g.rows.length)
  const showPanel = open && query.trim().length >= 2

  function onKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setActive((i) => Math.min(i + 1, ordered.length - 1))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActive((i) => Math.max(i - 1, -1))
    } else if (e.key === 'Enter' && active >= 0 && ordered[active]) {
      e.preventDefault()
      setOpen(false)
      router.push(hrefFor(ordered[active]))
    } else if (e.key === 'Escape') {
      setOpen(false)
      inputRef.current?.blur()
    }
  }

  return (
    <div ref={rootRef} className={cn('relative', compact ? 'px-4 py-2' : 'p-3')}>
      <div className="relative">
        <Search className="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          ref={inputRef}
          value={query}
          onChange={(e) => {
            setQuery(e.target.value)
            setOpen(true)
          }}
          onFocus={() => setOpen(true)}
          onKeyDown={onKeyDown}
          placeholder={canSeeContacts ? 'ФИО или телефон' : 'ФИО ученика'}
          aria-label="Поиск"
          aria-expanded={showPanel}
          aria-controls="global-search-results"
          role="combobox"
          autoComplete="off"
          className="h-9 pl-8"
        />
      </div>

      {showPanel ? (
        <div
          id="global-search-results"
          role="listbox"
          className="absolute left-3 right-3 z-30 mt-1 max-h-96 overflow-y-auto rounded-md border border-border bg-card p-1 text-sm shadow-md"
        >
          {error ? <p className="px-2 py-1.5 text-destructive">{error}</p> : null}
          {!error && pending && ordered.length === 0 ? <p className="px-2 py-1.5 text-muted-foreground">Ищем…</p> : null}
          {!error && !pending && ordered.length === 0 ? <p className="px-2 py-1.5 text-muted-foreground">Ничего не найдено</p> : null}
          {groups.map((group) => (
            <div key={group.kind} className="py-1">
              <p className="px-2 pb-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">{KIND_LABELS[group.kind]}</p>
              {group.rows.map((row) => {
                const index = ordered.indexOf(row)
                return (
                  <Link
                    key={`${row.kind}-${row.id}`}
                    href={hrefFor(row)}
                    role="option"
                    aria-selected={index === active}
                    onClick={() => setOpen(false)}
                    onMouseEnter={() => setActive(index)}
                    className={cn(
                      'block rounded px-2 py-1.5',
                      index === active ? 'bg-secondary text-secondary-foreground' : 'hover:bg-accent',
                    )}
                  >
                    <span className="block truncate font-medium">{row.title}</span>
                    <span className="block truncate text-xs text-muted-foreground">{describe(row, timeZone)}</span>
                  </Link>
                )
              })}
            </div>
          ))}
        </div>
      ) : null}
    </div>
  )
}
