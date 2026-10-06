'use client'

import { useEffect, useMemo, useState } from 'react'
import { onTablistKeyDown } from '@/lib/tablist-keys'
import { cn } from '@/lib/utils'
import { timeInZone } from '@/lib/timezone'
import {
  DAY_END_HOUR,
  DAY_START_HOUR,
  HOUR_HEIGHT,
  blockGeometry,
  lessonStatusLabel,
  overlapLanes,
} from '@/lib/schedule'
import { EmptyState } from '@/components/ui/empty-state'
import { StatusBadge } from '@/components/ui/status-badge'
import { LessonPanel, type LessonView } from './lesson-panel'
import type { TeacherOption } from './create-dialog'

export type DayColumn = { day: string; label: string; weekdayLabel: string; isToday: boolean }

const DESKTOP_QUERY = '(min-width: 640px)'

/**
 * Сетка недели на широком экране, список одного дня — на телефоне: семь
 * колонок по 50px нечитаемы, а горизонтальная прокрутка прячет половину недели.
 * Вид выбирается после монтирования, а не CSS-ом: две разметки сразу дали
 * бы в DOM каждое занятие дважды.
 */
export function WeekGrid(props: {
  days: DayColumn[]
  lessons: LessonView[]
  timeZone: string
  canManage: boolean
  teachers: TeacherOption[]
}) {
  const [selected, setSelected] = useState<LessonView | null>(null)
  const [desktop, setDesktop] = useState(true)

  useEffect(() => {
    const query = window.matchMedia(DESKTOP_QUERY)
    const update = () => setDesktop(query.matches)
    update()
    query.addEventListener('change', update)
    return () => query.removeEventListener('change', update)
  }, [])

  return (
    <>
      {desktop ? <WeekColumns {...props} onSelect={setSelected} /> : <DayList {...props} onSelect={setSelected} />}

      <LessonPanel
        lesson={selected}
        timeZone={props.timeZone}
        canManage={props.canManage}
        teachers={props.teachers}
        onClose={() => setSelected(null)}
      />
    </>
  )
}

function lessonTone(status: string) {
  if (status === 'cancelled') return 'neutral' as const
  if (status === 'done') return 'success' as const
  return 'primary' as const
}

function WeekColumns({
  days,
  lessons,
  timeZone,
  onSelect,
}: {
  days: DayColumn[]
  lessons: LessonView[]
  timeZone: string
  onSelect: (lesson: LessonView) => void
}) {
  const hours: number[] = []
  for (let hour = DAY_START_HOUR; hour < DAY_END_HOUR; hour += 1) hours.push(hour)

  const gridHeight = (DAY_END_HOUR - DAY_START_HOUR) * HOUR_HEIGHT

  return (
    // Сетка шире телефона: в пустую неделю внутри нет кнопок, и без tabIndex
    // её нельзя прокрутить с клавиатуры (axe: scrollable-region-focusable).
    <div
      tabIndex={0}
      role="region"
      aria-label="Сетка недели"
      className="overflow-x-auto rounded-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
    >
      <div className="flex min-w-[860px]">
        <div className="w-14 shrink-0 pt-8">
          {hours.map((hour) => (
            <div key={hour} className="relative text-xs text-muted-foreground" style={{ height: HOUR_HEIGHT }}>
              <span className="absolute -top-2 right-2 tabular-nums">{String(hour).padStart(2, '0')}:00</span>
            </div>
          ))}
        </div>

        {days.map((column) => {
          const dayLessons = lessons.filter((lesson) => lesson.day === column.day)
          const lanes = overlapLanes(dayLessons)

          return (
            <div key={column.day} className={cn('flex-1 border-l border-border', column.isToday && 'bg-secondary/25')}>
              <div
                className={cn(
                  'h-8 border-b border-border px-2 pt-1.5 text-xs',
                  column.isToday ? 'font-semibold text-primary' : 'text-muted-foreground',
                )}
              >
                {column.weekdayLabel} {column.label}
              </div>

              <div className="relative" style={{ height: gridHeight }}>
                {hours.map((hour) => (
                  <div key={hour}>
                    <div
                      className="absolute left-0 right-0 border-t border-border/70"
                      style={{ top: (hour - DAY_START_HOUR) * HOUR_HEIGHT }}
                    />
                    <div
                      className="absolute left-0 right-0 border-t border-dashed border-border/40"
                      style={{ top: (hour - DAY_START_HOUR) * HOUR_HEIGHT + HOUR_HEIGHT / 2 }}
                    />
                  </div>
                ))}

                {dayLessons.map((lesson) => {
                  const { top, height } = blockGeometry(lesson.startsAt, lesson.endsAt, timeZone)
                  const { lane, lanes: laneCount } = lanes.get(lesson.id) ?? { lane: 0, lanes: 1 }
                  const width = 100 / laneCount
                  return (
                    <button
                      key={lesson.id}
                      type="button"
                      onClick={() => onSelect(lesson)}
                      title={`${timeInZone(lesson.startsAt, timeZone)} ${lesson.title}, ${lesson.teacherName}`}
                      className={cn(
                        'absolute overflow-hidden rounded-md border-l-[3px] px-1.5 py-1 text-left text-xs shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
                        lesson.status === 'cancelled'
                          ? 'border-l-status-neutral bg-muted text-muted-foreground line-through'
                          : lesson.status === 'done'
                            ? 'border-l-success bg-success-bg text-foreground'
                            : 'border-l-primary bg-card text-foreground hover:bg-accent',
                      )}
                      style={{
                        top,
                        height,
                        left: `calc(${lane * width}% + 2px)`,
                        width: `calc(${width}% - 4px)`,
                      }}
                    >
                      <span className="block truncate font-medium">
                        {timeInZone(lesson.startsAt, timeZone)} {lesson.title}
                      </span>
                      <span className="block truncate text-muted-foreground">
                        {lesson.teacherName}
                        {lesson.roomName ? `, ${lesson.roomName}` : ''}
                      </span>
                    </button>
                  )
                })}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function DayList({
  days,
  lessons,
  timeZone,
  onSelect,
}: {
  days: DayColumn[]
  lessons: LessonView[]
  timeZone: string
  onSelect: (lesson: LessonView) => void
}) {
  const initialDay = useMemo(
    () =>
      days.find((d) => d.isToday)?.day ??
      days.find((d) => lessons.some((l) => l.day === d.day))?.day ??
      days[0]?.day,
    [days, lessons],
  )
  const [day, setDay] = useState(initialDay)

  const dayLessons = lessons
    .filter((lesson) => lesson.day === day)
    .sort((a, b) => a.startsAt.localeCompare(b.startsAt))

  return (
    <div className="space-y-4">
      <div
        role="tablist"
        aria-label="День недели"
        className="grid grid-cols-7 gap-1"
        onKeyDown={(e) => onTablistKeyDown(e, days.map((c) => c.day), day, setDay)}
      >
        {days.map((column) => {
          const count = lessons.filter((l) => l.day === column.day && l.status !== 'cancelled').length
          const active = column.day === day
          return (
            <button
              key={column.day}
              type="button"
              role="tab"
              aria-selected={active}
              tabIndex={active ? 0 : -1}
              onClick={() => setDay(column.day)}
              className={cn(
                'flex flex-col items-center rounded-md py-1.5 text-xs transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1',
                active
                  ? 'bg-primary text-primary-foreground'
                  : column.isToday
                    ? 'bg-secondary text-secondary-foreground'
                    : 'text-muted-foreground hover:bg-accent',
              )}
            >
              <span>{column.weekdayLabel}</span>
              <span className="text-sm font-medium tabular-nums">{column.label.split(' ')[0]}</span>
              <span className={cn('mt-0.5 size-1.5 rounded-full', count > 0 ? (active ? 'bg-primary-foreground' : 'bg-primary') : 'bg-transparent')} />
            </button>
          )
        })}
      </div>

      {dayLessons.length === 0 ? (
        <EmptyState title="В этот день занятий нет" />
      ) : (
        <ul className="divide-y divide-border rounded-lg border border-border bg-card">
          {dayLessons.map((lesson) => (
            <li key={lesson.id}>
              <button
                type="button"
                onClick={() => onSelect(lesson)}
                className="flex w-full items-start gap-3 px-4 py-3 text-left hover:bg-accent focus-visible:bg-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
              >
                <span className="w-12 shrink-0 pt-0.5 text-sm font-medium tabular-nums">
                  {timeInZone(lesson.startsAt, timeZone)}
                </span>
                <span className="min-w-0 flex-1">
                  <span
                    className={cn(
                      'block truncate text-sm font-medium',
                      lesson.status === 'cancelled' && 'text-muted-foreground line-through',
                    )}
                  >
                    {lesson.title}
                  </span>
                  <span className="block truncate text-xs text-muted-foreground">
                    до {timeInZone(lesson.endsAt, timeZone)}, {lesson.teacherName}
                    {lesson.roomName ? `, ${lesson.roomName}` : ''}
                  </span>
                </span>
                <StatusBadge tone={lessonTone(lesson.status)}>{lessonStatusLabel(lesson.status)}</StatusBadge>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
