'use client'

import { useState } from 'react'
import { cn } from '@/lib/utils'
import { timeInZone } from '@/lib/timezone'
import { DAY_END_HOUR, DAY_START_HOUR, HOUR_HEIGHT, blockGeometry } from '@/lib/schedule'
import { LessonPanel, type LessonView } from './lesson-panel'
import type { TeacherOption } from './create-dialog'

export type DayColumn = { day: string; label: string; weekdayLabel: string; isToday: boolean }

/**
 * Сетка недели. Часы рисуются полосами по 30 минут, но блоки занятий
 * позиционируются абсолютно по минутам от начала дня: занятия по 45 минут
 * в получасовые строки не укладываются.
 */
export function WeekGrid({
  days,
  lessons,
  timeZone,
  canManage,
  teachers,
}: {
  days: DayColumn[]
  lessons: LessonView[]
  timeZone: string
  canManage: boolean
  teachers: TeacherOption[]
}) {
  const [selected, setSelected] = useState<LessonView | null>(null)

  const hours: number[] = []
  for (let hour = DAY_START_HOUR; hour < DAY_END_HOUR; hour += 1) hours.push(hour)

  const gridHeight = (DAY_END_HOUR - DAY_START_HOUR) * HOUR_HEIGHT

  return (
    <>
      <div className="overflow-x-auto">
        <div className="flex min-w-[860px]">
          {/* Шкала часов */}
          <div className="w-14 shrink-0 pt-8">
            {hours.map((hour) => (
              <div
                key={hour}
                className="relative text-xs text-muted-foreground"
                style={{ height: HOUR_HEIGHT }}
              >
                <span className="absolute -top-2 right-2">{String(hour).padStart(2, '0')}:00</span>
              </div>
            ))}
          </div>

          {days.map((column) => {
            const dayLessons = lessons.filter((lesson) => lesson.day === column.day)

            return (
              <div key={column.day} className="flex-1 border-l border-border">
                <div
                  className={cn(
                    'h-8 border-b border-border px-2 text-xs',
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
                    return (
                      <button
                        key={lesson.id}
                        type="button"
                        onClick={() => setSelected(lesson)}
                        className={cn(
                          'absolute left-1 right-1 overflow-hidden rounded-md border px-2 py-1 text-left text-xs',
                          lesson.status === 'cancelled'
                            ? 'border-border bg-muted text-muted-foreground line-through'
                            : lesson.status === 'done'
                              ? 'border-primary/30 bg-primary/10 text-foreground'
                              : 'border-primary/40 bg-card text-foreground hover:bg-accent',
                        )}
                        style={{ top, height }}
                      >
                        <span className="block font-medium">
                          {timeInZone(lesson.startsAt, timeZone)} {lesson.title}
                        </span>
                        <span className="block truncate text-muted-foreground">
                          {lesson.teacherName}
                          {lesson.roomName ? ` · ${lesson.roomName}` : ''}
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

      <LessonPanel
        lesson={selected}
        timeZone={timeZone}
        canManage={canManage}
        teachers={teachers}
        onClose={() => setSelected(null)}
      />
    </>
  )
}
