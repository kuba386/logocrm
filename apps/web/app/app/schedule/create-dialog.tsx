'use client'

import { useActionState, useState, useTransition } from 'react'
import { useFormStatus } from 'react-dom'
import { createSeries, previewSeries, type ScheduleState, type SeriesPreviewRow } from './actions'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormNotice } from '@/components/ui/alert'
import { ConflictList } from './conflict-list'
import { conflictLabel } from '@/lib/errors'
import { WEEKDAY_LABELS } from '@/lib/schedule'

const initial: ScheduleState = { message: '' }

export type TeacherOption = { id: string; fullName: string }
export type RoomOption = { id: string; name: string }
export type ServiceOption = { id: string; name: string; durationMin: number; kind: string }
export type StudentOption = { id: string; fullName: string }
export type GroupOption = { id: string; name: string }

function SubmitButton({ disabled }: { disabled: boolean }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" disabled={pending || disabled}>
      {pending ? 'Создаём…' : 'Создать'}
    </Button>
  )
}

export function CreateLessonDialog({
  teachers,
  rooms,
  services,
  students,
  groups,
}: {
  teachers: TeacherOption[]
  rooms: RoomOption[]
  services: ServiceOption[]
  students: StudentOption[]
  groups: GroupOption[]
}) {
  const [open, setOpen] = useState(false)
  const [state, formAction] = useActionState(createSeries, initial)
  const [target, setTarget] = useState<'student' | 'group'>('student')
  const [preview, setPreview] = useState<SeriesPreviewRow[] | null>(null)
  const [previewError, setPreviewError] = useState<string | null>(null)
  const [pending, startTransition] = useTransition()

  const [form, setForm] = useState({
    serviceId: services[0]?.id ?? '',
    teacherId: teachers[0]?.id ?? '',
    roomId: '',
    studentId: '',
    groupId: '',
    firstDate: '',
    until: '',
    time: '10:00',
    weekdays: [] as number[],
  })

  function set<K extends keyof typeof form>(key: K, value: (typeof form)[K]) {
    setForm((current) => ({ ...current, [key]: value }))
    setPreview(null)
  }

  function toggleWeekday(day: number) {
    setForm((current) => ({
      ...current,
      weekdays: current.weekdays.includes(day)
        ? current.weekdays.filter((value) => value !== day)
        : [...current.weekdays, day].sort(),
    }))
    setPreview(null)
  }

  // Занятость считает только база. В браузере её не повторяем.
  function refreshPreview() {
    if (!form.teacherId || !form.firstDate || !form.time || form.weekdays.length === 0) {
      setPreviewError('Заполните специалиста, дату, время и дни недели')
      return
    }

    setPreviewError(null)
    startTransition(async () => {
      const result = await previewSeries({
        service_id: form.serviceId || undefined,
        teacher_id: form.teacherId,
        room_id: form.roomId || undefined,
        student_id: target === 'student' ? form.studentId || undefined : undefined,
        group_id: target === 'group' ? form.groupId || undefined : undefined,
        first_date: form.firstDate,
        until: form.until || form.firstDate,
        time: form.time,
        weekdays: form.weekdays,
      })

      if (result.rows) setPreview(result.rows)
      else setPreviewError(result.message ?? 'Не удалось построить предпросмотр')
    })
  }

  const busyDays = preview?.filter((row) => row.conflicts.length > 0) ?? []

  return (
    <>
      <Button onClick={() => setOpen(true)}>Добавить занятие</Button>

      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title="Новое занятие"
        description="Одно занятие или серия по дням недели. Предпросмотр покажет, какие слоты заняты."
      >
        <form action={formAction} className="space-y-4">
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label htmlFor="serviceId">Услуга</Label>
              <Select
                id="serviceId"
                name="serviceId"
                value={form.serviceId}
                onChange={(e) => set('serviceId', e.target.value)}
              >
                {services.map((service) => (
                  <option key={service.id} value={service.id}>
                    {service.name} · {service.durationMin} мин
                  </option>
                ))}
              </Select>
            </div>

            <div className="space-y-1">
              <Label htmlFor="teacherId">Специалист</Label>
              <Select
                id="teacherId"
                name="teacherId"
                value={form.teacherId}
                onChange={(e) => set('teacherId', e.target.value)}
                required
              >
                {teachers.map((teacher) => (
                  <option key={teacher.id} value={teacher.id}>
                    {teacher.fullName}
                  </option>
                ))}
              </Select>
            </div>
          </div>

          <div className="space-y-2">
            <Label>Для кого</Label>
            <div className="flex gap-2">
              <Button
                type="button"
                size="sm"
                variant={target === 'student' ? 'default' : 'outline'}
                onClick={() => {
                  setTarget('student')
                  setPreview(null)
                }}
              >
                Ученик
              </Button>
              <Button
                type="button"
                size="sm"
                variant={target === 'group' ? 'default' : 'outline'}
                onClick={() => {
                  setTarget('group')
                  setPreview(null)
                }}
              >
                Группа
              </Button>
            </div>

            {target === 'student' ? (
              <Select
                name="studentId"
                value={form.studentId}
                onChange={(e) => set('studentId', e.target.value)}
                required
              >
                <option value="">Выберите ученика</option>
                {students.map((student) => (
                  <option key={student.id} value={student.id}>
                    {student.fullName}
                  </option>
                ))}
              </Select>
            ) : (
              <Select
                name="groupId"
                value={form.groupId}
                onChange={(e) => set('groupId', e.target.value)}
                required
              >
                <option value="">Выберите группу</option>
                {groups.map((group) => (
                  <option key={group.id} value={group.id}>
                    {group.name}
                  </option>
                ))}
              </Select>
            )}
          </div>

          <div className="space-y-1">
            <Label htmlFor="roomId">Кабинет</Label>
            <Select
              id="roomId"
              name="roomId"
              value={form.roomId}
              onChange={(e) => set('roomId', e.target.value)}
            >
              <option value="">Без кабинета</option>
              {rooms.map((room) => (
                <option key={room.id} value={room.id}>
                  {room.name}
                </option>
              ))}
            </Select>
          </div>

          <div className="grid gap-3 sm:grid-cols-3">
            <div className="space-y-1">
              <Label htmlFor="firstDate">Первый день</Label>
              <Input
                id="firstDate"
                name="firstDate"
                type="date"
                value={form.firstDate}
                onChange={(e) => set('firstDate', e.target.value)}
                required
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="until">Повторять до</Label>
              <Input
                id="until"
                name="until"
                type="date"
                value={form.until}
                onChange={(e) => set('until', e.target.value)}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="time">Время</Label>
              <Input
                id="time"
                name="time"
                type="time"
                value={form.time}
                onChange={(e) => set('time', e.target.value)}
                required
              />
            </div>
          </div>

          <div className="space-y-2">
            <Label>Дни недели</Label>
            <div className="flex flex-wrap gap-1">
              {WEEKDAY_LABELS.map((label, index) => {
                const day = index + 1
                const active = form.weekdays.includes(day)
                return (
                  <Button
                    key={day}
                    type="button"
                    size="sm"
                    variant={active ? 'default' : 'outline'}
                    onClick={() => toggleWeekday(day)}
                  >
                    {label}
                  </Button>
                )
              })}
            </div>
            {form.weekdays.map((day) => (
              <input key={day} type="hidden" name="weekdays" value={day} />
            ))}
          </div>

          <div className="space-y-2 border-t border-border pt-3">
            <Button type="button" variant="outline" size="sm" onClick={refreshPreview} disabled={pending}>
              {pending ? 'Считаем…' : 'Проверить занятость'}
            </Button>

            {previewError ? (
              <p className="text-sm text-destructive">{previewError}</p>
            ) : null}

            {preview ? (
              <div className="rounded-md border border-border p-3 text-sm">
                <p className="font-medium">
                  Занятий в серии: {preview.length}
                  {busyDays.length > 0 ? `, из них заняты: ${busyDays.length}` : ' — все слоты свободны'}
                </p>
                {busyDays.length > 0 ? (
                  <ul className="mt-2 space-y-1 text-xs text-destructive">
                    {busyDays.map((row) => (
                      <li key={row.day}>
                        {new Date(row.startsAt).toLocaleDateString('ru-RU')}:{' '}
                        {row.conflicts.map((conflict) => conflictLabel(conflict)).join('; ')}
                      </li>
                    ))}
                  </ul>
                ) : null}
              </div>
            ) : null}
          </div>

          <ConflictList error={state} />
          <FormNotice message={state.notice} />

          <div className="flex gap-2">
            <SubmitButton disabled={busyDays.length > 0} />
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>
              Отмена
            </Button>
          </div>
        </form>
      </Dialog>
    </>
  )
}
