'use client'

import Link from 'next/link'
import { useMemo, useState } from 'react'
import { Input } from '@/components/ui/input'
import { Select } from '@/components/ui/select'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { cn } from '@/lib/utils'
import { STUDENT_STATUS_CLASSES, statusLabel, studentAge } from '@/lib/students'
import { formatKgPhone, normalizeKgPhone } from '@logocrm/core'

export type StudentRowView = {
  id: string
  fullName: string
  birthDate: string | null
  status: string
  teacherName: string | null
  teacherId: string | null
  payerName: string | null
  /** Только для владельца и администратора: специалисту телефон не приходит с сервера. */
  payerPhone: string | null
}

export function StudentsTable({
  students,
  teachers,
  canSeeContacts,
}: {
  students: StudentRowView[]
  teachers: { id: string; fullName: string }[]
  canSeeContacts: boolean
}) {
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState('')
  const [teacherId, setTeacherId] = useState('')

  const filtered = useMemo(() => {
    const trimmed = query.trim().toLowerCase()
    const asPhone = canSeeContacts ? normalizeKgPhone(trimmed) : null

    return students.filter((student) => {
      if (status && student.status !== status) return false
      if (teacherId && student.teacherId !== teacherId) return false
      if (!trimmed) return true

      if (student.fullName.toLowerCase().includes(trimmed)) return true
      if (student.payerName?.toLowerCase().includes(trimmed)) return true

      // Поиск по телефону доступен только тем, кто телефон вообще видит.
      if (asPhone && student.payerPhone && normalizeKgPhone(student.payerPhone) === asPhone) {
        return true
      }

      return false
    })
  }, [students, query, status, teacherId, canSeeContacts])

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-3">
        <Input
          placeholder={canSeeContacts ? 'Поиск по ФИО или телефону' : 'Поиск по ФИО'}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          className="max-w-xs"
        />
        <Select value={status} onChange={(event) => setStatus(event.target.value)} className="max-w-[190px]">
          <option value="">Все статусы</option>
          <option value="lead">Заявка</option>
          <option value="active">Занимается</option>
          <option value="paused">Пауза</option>
          <option value="archived">В архиве</option>
        </Select>
        {teachers.length > 0 ? (
          <Select
            value={teacherId}
            onChange={(event) => setTeacherId(event.target.value)}
            className="max-w-[220px]"
          >
            <option value="">Все специалисты</option>
            {teachers.map((teacher) => (
              <option key={teacher.id} value={teacher.id}>
                {teacher.fullName}
              </option>
            ))}
          </Select>
        ) : null}
      </div>

      {filtered.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {students.length === 0 ? 'Учеников пока нет.' : 'Никто не подошёл под фильтры.'}
        </p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>ФИО</TableHead>
              <TableHead>Возраст</TableHead>
              <TableHead>Специалист</TableHead>
              <TableHead>Плательщик</TableHead>
              <TableHead>Статус</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {filtered.map((student) => (
              <TableRow key={student.id}>
                <TableCell className="font-medium">
                  <Link href={`/app/students/${student.id}`} className="hover:underline">
                    {student.fullName}
                  </Link>
                </TableCell>
                <TableCell className="text-muted-foreground">{studentAge(student.birthDate)}</TableCell>
                <TableCell>{student.teacherName ?? '—'}</TableCell>
                <TableCell>
                  <span>{student.payerName ?? '—'}</span>
                  {canSeeContacts && student.payerPhone ? (
                    <span className="block text-xs text-muted-foreground">
                      {formatKgPhone(student.payerPhone)}
                    </span>
                  ) : null}
                </TableCell>
                <TableCell>
                  <span
                    className={cn(
                      'inline-block rounded-full px-2 py-0.5 text-xs',
                      STUDENT_STATUS_CLASSES[student.status] ?? 'bg-muted text-muted-foreground',
                    )}
                  >
                    {statusLabel(student.status)}
                  </span>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  )
}
