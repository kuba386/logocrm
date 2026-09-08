'use client'

import { useRouter } from 'next/navigation'
import { Select } from '@/components/ui/select'

export function ScheduleFilters({
  week,
  teachers,
  rooms,
  selectedTeacher,
  selectedRoom,
  showTeacherFilter,
}: {
  week: string
  teachers: { id: string; fullName: string }[]
  rooms: { id: string; name: string }[]
  selectedTeacher: string
  selectedRoom: string
  showTeacherFilter: boolean
}) {
  const router = useRouter()

  function go(next: { teacher?: string; room?: string }) {
    const params = new URLSearchParams({ week })
    const teacher = next.teacher ?? selectedTeacher
    const room = next.room ?? selectedRoom
    if (teacher) params.set('teacher', teacher)
    if (room) params.set('room', room)
    router.push(`/app/schedule?${params.toString()}`)
  }

  return (
    <div className="flex flex-wrap gap-2">
      {showTeacherFilter ? (
        <Select
          value={selectedTeacher}
          onChange={(event) => go({ teacher: event.target.value })}
          className="h-9 max-w-[220px]"
        >
          <option value="">Все специалисты</option>
          {teachers.map((teacher) => (
            <option key={teacher.id} value={teacher.id}>
              {teacher.fullName}
            </option>
          ))}
        </Select>
      ) : null}

      <Select
        value={selectedRoom}
        onChange={(event) => go({ room: event.target.value })}
        className="h-9 max-w-[200px]"
      >
        <option value="">Все кабинеты</option>
        {/* Кабинет необязателен, поэтому нужен явный пункт: иначе занятия
            без кабинета молча пропадут из вида. */}
        <option value="none">Без кабинета</option>
        {rooms.map((room) => (
          <option key={room.id} value={room.id}>
            {room.name}
          </option>
        ))}
      </Select>
    </div>
  )
}
