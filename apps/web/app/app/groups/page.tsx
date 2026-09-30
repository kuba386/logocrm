import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { CatalogForm } from '@/components/ui/catalog-form'
import { DialogButton } from '@/components/ui/dialog-button'
import { Disclosure } from '@/components/ui/disclosure'
import { EmptyState } from '@/components/ui/empty-state'
import { PageHeader } from '@/components/ui/page-header'
import { StatusBadge } from '@/components/ui/status-badge'
import { addStudentToGroup, removeStudentFromGroup, saveGroup } from '../settings/services/actions'

export const metadata = { title: 'Группы — LogoCRM' }

type Option = { id: string; name: string }
type GroupRow = {
  id: string
  name: string
  service_id: string | null
  teacher_id: string | null
  room_id: string | null
  max_students: number | null
  is_active: boolean
}

function GroupFields({
  group,
  idSuffix,
  services,
  teachers,
  rooms,
}: {
  group?: GroupRow
  idSuffix: string
  services: Option[]
  teachers: Option[]
  rooms: Option[]
}) {
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      {group ? <input type="hidden" name="id" value={group.id} /> : null}
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor={`name-${idSuffix}`}>Название</Label>
        <Input
          id={`name-${idSuffix}`}
          name="name"
          placeholder="Подготовка к школе"
          defaultValue={group?.name}
          required
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`serviceId-${idSuffix}`}>Услуга</Label>
        <Select id={`serviceId-${idSuffix}`} name="serviceId" defaultValue={group?.service_id ?? ''}>
          <option value="">Не выбрана</option>
          {services.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </Select>
      </div>
      <div className="space-y-1">
        <Label htmlFor={`teacherId-${idSuffix}`}>Специалист</Label>
        <Select id={`teacherId-${idSuffix}`} name="teacherId" defaultValue={group?.teacher_id ?? ''}>
          <option value="">Не назначен</option>
          {teachers.map((t) => (
            <option key={t.id} value={t.id}>
              {t.name}
            </option>
          ))}
        </Select>
      </div>
      <div className="space-y-1">
        <Label htmlFor={`roomId-${idSuffix}`}>Кабинет</Label>
        <Select id={`roomId-${idSuffix}`} name="roomId" defaultValue={group?.room_id ?? ''}>
          <option value="">Без кабинета</option>
          {rooms.map((r) => (
            <option key={r.id} value={r.id}>
              {r.name}
            </option>
          ))}
        </Select>
      </div>
      <div className="space-y-1">
        <Label htmlFor={`maxStudents-${idSuffix}`}>Максимум детей</Label>
        <Input
          id={`maxStudents-${idSuffix}`}
          name="maxStudents"
          type="number"
          min={1}
          defaultValue={group?.max_students ?? undefined}
        />
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" name="isActive" defaultChecked={group ? group.is_active : true} />
        Активна
      </label>
    </div>
  )
}

export default async function GroupsPage() {
  const supabase = await createClient()

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const [{ data: groups }, { data: services }, { data: teachers }, { data: rooms }, { data: students }] =
    await Promise.all([
      supabase.from('groups').select('id, name, service_id, teacher_id, room_id, max_students, is_active').is('deleted_at', null).order('name'),
      supabase.from('services').select('id, name').is('deleted_at', null).order('name'),
      supabase.from('teachers').select('id, full_name').is('deleted_at', null).eq('is_active', true).order('full_name'),
      supabase.from('rooms').select('id, name').is('deleted_at', null).order('name'),
      supabase.from('students').select('id, full_name').is('deleted_at', null).order('full_name'),
    ])

  const { data: membership } = await supabase
    .from('group_students')
    .select('id, group_id, student_id, joined_at, left_at')
    .is('deleted_at', null)
    .is('left_at', null)

  const serviceOptions = (services ?? []).map((s) => ({ id: s.id, name: s.name }))
  const teacherOptions = (teachers ?? []).map((t) => ({ id: t.id, name: t.full_name }))
  const roomOptions = (rooms ?? []).map((r) => ({ id: r.id, name: r.name }))
  const serviceName = new Map(serviceOptions.map((s) => [s.id, s.name]))
  const teacherName = new Map(teacherOptions.map((t) => [t.id, t.name]))
  const roomName = new Map(roomOptions.map((r) => [r.id, r.name]))

  const studentNames = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const byGroup = new Map<string, { id: string; studentId: string }[]>()
  for (const row of membership ?? []) {
    const list = byGroup.get(row.group_id) ?? []
    list.push({ id: row.id, studentId: row.student_id })
    byGroup.set(row.group_id, list)
  }

  const fields = { services: serviceOptions, teachers: teacherOptions, rooms: roomOptions }

  return (
    <div className="space-y-6">
      <PageHeader
        title="Группы"
        description="Добавить ребёнка в группу, где у него уже есть занятие в то же время, база не даст."
        actions={
          <DialogButton label="Новая группа" title="Новая группа">
            <CatalogForm action={saveGroup} label="Создать группу">
              <GroupFields idSuffix="new" {...fields} />
            </CatalogForm>
          </DialogButton>
        }
      />

      {(groups ?? []).length === 0 ? (
        <EmptyState
          title="Групп пока нет"
          description="Группа — это состав детей, специалист и кабинет для групповых занятий."
        />
      ) : null}

      <div className="grid gap-4 lg:grid-cols-2">
        {(groups ?? []).map((group) => {
          const members = byGroup.get(group.id) ?? []
          const memberIds = new Set(members.map((m) => m.studentId))
          const details = [
            group.teacher_id ? teacherName.get(group.teacher_id) : null,
            group.room_id ? roomName.get(group.room_id) : null,
            group.service_id ? serviceName.get(group.service_id) : null,
          ].filter(Boolean)
          return (
            <Card key={group.id}>
              <CardHeader>
                <div className="flex flex-wrap items-center gap-2">
                  <CardTitle>{group.name}</CardTitle>
                  {group.is_active ? null : <StatusBadge>Не набирает</StatusBadge>}
                </div>
                <CardDescription>
                  Детей: {members.length}
                  {group.max_students ? ` из ${group.max_students}` : ''}
                  {details.length > 0 ? `. ${details.join(', ')}` : ''}
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                {members.length > 0 ? (
                  <ul className="divide-y divide-border rounded-md border border-border">
                    {members.map((member) => {
                      const name = studentNames.get(member.studentId) ?? '—'
                      return (
                        <li key={member.id} className="flex items-center justify-between gap-3 px-3 py-1.5 text-sm">
                          <span className="truncate">{name}</span>
                          <CatalogForm
                            action={removeStudentFromGroup}
                            label="Вывести"
                            variant="ghost"
                            confirm={`Вывести ${name} из группы «${group.name}»?`}
                          >
                            <input type="hidden" name="membershipId" value={member.id} />
                          </CatalogForm>
                        </li>
                      )
                    })}
                  </ul>
                ) : (
                  <p className="text-sm text-muted-foreground">В группе пока никого.</p>
                )}

                <CatalogForm action={addStudentToGroup} label="Добавить в группу" variant="outline">
                  <input type="hidden" name="groupId" value={group.id} />
                  <div className="space-y-1">
                    <Label htmlFor={`add-${group.id}`}>Ученик</Label>
                    <Select id={`add-${group.id}`} name="studentId" defaultValue="" required>
                      <option value="">Выберите ученика</option>
                      {(students ?? [])
                        .filter((s) => !memberIds.has(s.id))
                        .map((s) => (
                          <option key={s.id} value={s.id}>
                            {s.full_name}
                          </option>
                        ))}
                    </Select>
                  </div>
                </CatalogForm>

                <div className="border-t border-border pt-2">
                  <Disclosure label="Изменить группу">
                    <CatalogForm action={saveGroup}>
                      <GroupFields group={group} idSuffix={group.id} {...fields} />
                    </CatalogForm>
                  </Disclosure>
                </div>
              </CardContent>
            </Card>
          )
        })}
      </div>
    </div>
  )
}
