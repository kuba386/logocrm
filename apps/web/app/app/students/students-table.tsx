'use client'

import Link from 'next/link'
import { useMemo, useState } from 'react'
import { Input } from '@/components/ui/input'
import { Select } from '@/components/ui/select'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { EmptyState } from '@/components/ui/empty-state'
import { StatusBadge } from '@/components/ui/status-badge'
import { STUDENT_STATUS_TONES, statusLabel, studentAge } from '@/lib/students'
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
  /** Последнее заключение из student_conclusions() (0059); бухгалтеру не приходит. */
  conclusionCode?: string | null
  conclusionName?: string | null
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
  const [conclusion, setConclusion] = useState('')

  // Варианты фильтра — только те заключения, что реально есть в списке.
  const conclusionOptions = useMemo(() => {
    const seen = new Map<string, string>()
    for (const s of students) {
      if (s.conclusionCode && s.conclusionName) seen.set(s.conclusionCode, s.conclusionName)
    }
    return [...seen.entries()].map(([code, name]) => ({ code, name }))
  }, [students])

  const filtered = useMemo(() => {
    const trimmed = query.trim().toLowerCase()
    const asPhone = canSeeContacts ? normalizeKgPhone(trimmed) : null

    return students.filter((student) => {
      if (status && student.status !== status) return false
      if (teacherId && student.teacherId !== teacherId) return false
      if (conclusion && student.conclusionCode !== conclusion) return false
      if (!trimmed) return true

      if (student.fullName.toLowerCase().includes(trimmed)) return true
      if (student.payerName?.toLowerCase().includes(trimmed)) return true

      // Поиск по телефону доступен только тем, кто телефон вообще видит.
      if (asPhone && student.payerPhone && normalizeKgPhone(student.payerPhone) === asPhone) {
        return true
      }

      return false
    })
  }, [students, query, status, teacherId, conclusion, canSeeContacts])

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
        {conclusionOptions.length > 0 ? (
          <Select
            value={conclusion}
            onChange={(event) => setConclusion(event.target.value)}
            className="max-w-[260px]"
          >
            <option value="">Все заключения</option>
            {conclusionOptions.map((c) => (
              <option key={c.code} value={c.code}>
                {c.name}
              </option>
            ))}
          </Select>
        ) : null}
      </div>

      {filtered.length === 0 ? (
        <EmptyState
          title={students.length === 0 ? 'Учеников пока нет' : 'Никто не подошёл под фильтры'}
          description={students.length === 0 ? undefined : 'Сбросьте фильтры или поищите по-другому.'}
        />
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>ФИО</TableHead>
              <TableHead className="hidden md:table-cell">Возраст</TableHead>
              <TableHead className="hidden sm:table-cell">Специалист</TableHead>
              <TableHead className="hidden lg:table-cell">Плательщик</TableHead>
              <TableHead>Статус</TableHead>
              {conclusionOptions.length > 0 ? <TableHead className="hidden xl:table-cell">Заключение</TableHead> : null}
            </TableRow>
          </TableHeader>
          <TableBody>
            {filtered.map((student) => (
              <TableRow key={student.id}>
                <TableCell>
                  <Link href={`/app/students/${student.id}`} className="font-medium hover:underline">
                    {student.fullName}
                  </Link>
                  {/* На узком экране колонки скрыты — главное из них под именем. */}
                  <span className="block text-xs text-muted-foreground md:hidden">
                    {studentAge(student.birthDate)}
                    <span className="sm:hidden">{student.teacherName ? `, ${student.teacherName}` : ''}</span>
                  </span>
                </TableCell>
                <TableCell className="hidden text-muted-foreground md:table-cell">{studentAge(student.birthDate)}</TableCell>
                <TableCell className="hidden sm:table-cell">{student.teacherName ?? '—'}</TableCell>
                <TableCell className="hidden lg:table-cell">
                  <span>{student.payerName ?? '—'}</span>
                  {canSeeContacts && student.payerPhone ? (
                    <span className="block text-xs text-muted-foreground">
                      {formatKgPhone(student.payerPhone)}
                    </span>
                  ) : null}
                </TableCell>
                <TableCell>
                  <StatusBadge tone={STUDENT_STATUS_TONES[student.status] ?? 'neutral'}>
                    {statusLabel(student.status)}
                  </StatusBadge>
                </TableCell>
                {conclusionOptions.length > 0 ? (
                  <TableCell className="hidden text-sm text-muted-foreground xl:table-cell">
                    {student.conclusionName ?? '—'}
                  </TableCell>
                ) : null}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  )
}
