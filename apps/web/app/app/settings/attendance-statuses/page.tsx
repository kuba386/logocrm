import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { CatalogForm } from '@/components/ui/catalog-form'
import { cn } from '@/lib/utils'
import { ATTENDANCE_COLORS, attendanceStatusClasses } from '@/lib/attendance'
import { saveAttendanceStatus } from './actions'

export const metadata = { title: 'Статусы посещения — LogoCRM' }

type StatusRow = {
  id: string
  code: string
  name: string
  color: string
  deducts_lesson: boolean
  pays_teacher: boolean
  counts_absence: boolean
  notify_parent: boolean
  is_default: boolean
  sort: number
}

const FLAGS: { name: string; key: keyof StatusRow; label: string; hint: string }[] = [
  { name: 'deductsLesson', key: 'deducts_lesson', label: 'Списывает занятие', hint: 'с абонемента уходит одно занятие' },
  { name: 'paysTeacher', key: 'pays_teacher', label: 'Оплачивается специалисту', hint: 'понадобится расчёту зарплат' },
  { name: 'countsAbsence', key: 'counts_absence', label: 'Считается пропуском', hint: 'два подряд — родителю уходит сообщение' },
  { name: 'notifyParent', key: 'notify_parent', label: 'Уведомлять родителя', hint: 'сразу после отметки' },
]

function StatusFields({ status, idSuffix }: { status?: StatusRow; idSuffix: string }) {
  return (
    <div className="grid gap-3 sm:grid-cols-6">
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor={`name-${idSuffix}`}>Название</Label>
        <Input id={`name-${idSuffix}`} name="name" defaultValue={status?.name ?? ''} placeholder="Пришёл" required />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`code-${idSuffix}`}>Код</Label>
        <Input
          id={`code-${idSuffix}`}
          name="code"
          defaultValue={status?.code ?? ''}
          placeholder="present"
          pattern="[a-z][a-z0-9_]{1,31}"
          title="Латиница, цифры и подчёркивание"
          required
        />
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor={`color-${idSuffix}`}>Цвет</Label>
        <Select id={`color-${idSuffix}`} name="color" defaultValue={status?.color ?? 'slate'}>
          {ATTENDANCE_COLORS.map((c) => (
            <option key={c.value} value={c.value}>
              {c.label}
            </option>
          ))}
        </Select>
      </div>
      <div className="space-y-1">
        <Label htmlFor={`sort-${idSuffix}`}>Порядок</Label>
        <Input id={`sort-${idSuffix}`} name="sort" type="number" defaultValue={status?.sort ?? 100} />
      </div>

      <div className="grid gap-2 sm:col-span-6 sm:grid-cols-2">
        {FLAGS.map((f) => (
          <label key={f.name} className="flex items-start gap-2 text-sm">
            <input type="checkbox" name={f.name} defaultChecked={status ? Boolean(status[f.key]) : f.name === 'deductsLesson' || f.name === 'paysTeacher'} className="mt-0.5" />
            <span>
              {f.label}
              <span className="block text-xs text-muted-foreground">{f.hint}</span>
            </span>
          </label>
        ))}
        <label className="flex items-start gap-2 text-sm font-medium sm:col-span-2">
          <input type="checkbox" name="isDefault" defaultChecked={status?.is_default ?? false} className="mt-0.5" />
          <span>
            По умолчанию
            <span className="block text-xs font-normal text-muted-foreground">
              его ставит «Все пришли»; в центре ровно один такой
            </span>
          </span>
        </label>
      </div>
    </div>
  )
}

export default async function AttendanceStatusesPage() {
  const supabase = await createClient()

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const { data: statuses } = await supabase
    .from('attendance_statuses')
    .select('id, code, name, color, deducts_lesson, pays_teacher, counts_absence, notify_parent, is_default, sort')
    .is('deleted_at', null)
    .order('sort')

  const rows = (statuses ?? []) as StatusRow[]

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Статусы посещения</h1>
        <p className="text-sm text-muted-foreground">
          Кнопки в панели отметки — отсюда. Галочки решают, что происходит с абонементом и уведомлениями;
          уже поставленные отметки они не пересчитывают.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Добавить статус</CardTitle>
        </CardHeader>
        <CardContent>
          <CatalogForm action={saveAttendanceStatus} label="Добавить">
            <StatusFields idSuffix="new" />
          </CatalogForm>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Список</CardTitle>
          <CardDescription>Всего: {rows.length}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {rows.map((status) => (
            <div key={status.id} className="space-y-3 rounded-md border border-border p-3">
              <div className="flex flex-wrap items-center gap-2">
                <span className={cn('rounded px-2 py-0.5 text-xs font-medium', attendanceStatusClasses(status.color).badge)}>
                  {status.name}
                </span>
                <span className="text-xs text-muted-foreground">{status.code}</span>
                {status.is_default ? <span className="text-xs text-muted-foreground">· по умолчанию</span> : null}
              </div>
              <CatalogForm action={saveAttendanceStatus}>
                <input type="hidden" name="id" value={status.id} />
                <StatusFields status={status} idSuffix={status.id} />
              </CatalogForm>
            </div>
          ))}
          {rows.length === 0 ? <p className="text-sm text-muted-foreground">Статусов пока нет.</p> : null}
        </CardContent>
      </Card>
    </div>
  )
}
