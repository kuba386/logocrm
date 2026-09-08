import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { CatalogForm } from '@/components/ui/catalog-form'
import { addStudentToGroup, removeStudentFromGroup, saveGroup } from '../settings/services/actions'
import { Button } from '@/components/ui/button'

export const metadata = { title: 'Группы — LogoCRM' }

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

  const studentNames = new Map((students ?? []).map((s) => [s.id, s.full_name]))
  const byGroup = new Map<string, { id: string; studentId: string }[]>()
  for (const row of membership ?? []) {
    const list = byGroup.get(row.group_id) ?? []
    list.push({ id: row.id, studentId: row.student_id })
    byGroup.set(row.group_id, list)
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Группы</h1>
        <p className="text-sm text-muted-foreground">
          Состав группы влияет на занятость детей: добавить ребёнка в группу, где у него уже есть
          занятие, база не даст.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Новая группа</CardTitle>
        </CardHeader>
        <CardContent>
          <CatalogForm action={saveGroup} label="Создать">
            <div className="grid gap-3 sm:grid-cols-3">
              <div className="space-y-1">
                <Label htmlFor="name">Название</Label>
                <Input id="name" name="name" placeholder="Подготовка к школе" required />
              </div>
              <div className="space-y-1">
                <Label htmlFor="serviceId">Услуга</Label>
                <Select id="serviceId" name="serviceId" defaultValue="">
                  <option value="">Не выбрана</option>
                  {(services ?? []).map((s) => (
                    <option key={s.id} value={s.id}>{s.name}</option>
                  ))}
                </Select>
              </div>
              <div className="space-y-1">
                <Label htmlFor="teacherId">Специалист</Label>
                <Select id="teacherId" name="teacherId" defaultValue="">
                  <option value="">Не назначен</option>
                  {(teachers ?? []).map((t) => (
                    <option key={t.id} value={t.id}>{t.full_name}</option>
                  ))}
                </Select>
              </div>
              <div className="space-y-1">
                <Label htmlFor="roomId">Кабинет</Label>
                <Select id="roomId" name="roomId" defaultValue="">
                  <option value="">Без кабинета</option>
                  {(rooms ?? []).map((r) => (
                    <option key={r.id} value={r.id}>{r.name}</option>
                  ))}
                </Select>
              </div>
              <div className="space-y-1">
                <Label htmlFor="maxStudents">Максимум детей</Label>
                <Input id="maxStudents" name="maxStudents" type="number" min={1} />
              </div>
              <label className="flex items-center gap-2 self-end text-sm">
                <input type="checkbox" name="isActive" defaultChecked />
                Активна
              </label>
            </div>
          </CatalogForm>
        </CardContent>
      </Card>

      {(groups ?? []).map((group) => {
        const members = byGroup.get(group.id) ?? []
        return (
          <Card key={group.id}>
            <CardHeader>
              <CardTitle>{group.name}</CardTitle>
              <CardDescription>
                Детей в группе: {members.length}
                {group.max_students ? ` из ${group.max_students}` : ''}
                {group.is_active ? '' : ' · неактивна'}
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              {members.length > 0 ? (
                <ul className="space-y-2">
                  {members.map((member) => (
                    <li
                      key={member.id}
                      className="flex items-center justify-between gap-3 rounded-md border border-border px-3 py-2 text-sm"
                    >
                      <span>{studentNames.get(member.studentId) ?? '—'}</span>
                      <CatalogForm action={removeStudentFromGroup} label="Вывести">
                        <input type="hidden" name="membershipId" value={member.id} />
                      </CatalogForm>
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="text-sm text-muted-foreground">В группе пока никого.</p>
              )}

              <div className="border-t border-border pt-3">
                <CatalogForm action={addStudentToGroup} label="Добавить в группу">
                  <input type="hidden" name="groupId" value={group.id} />
                  <div className="space-y-1">
                    <Label htmlFor={`add-${group.id}`}>Ученик</Label>
                    <Select id={`add-${group.id}`} name="studentId" defaultValue="" required>
                      <option value="">Выберите ученика</option>
                      {(students ?? []).map((s) => (
                        <option key={s.id} value={s.id}>{s.full_name}</option>
                      ))}
                    </Select>
                  </div>
                </CatalogForm>
              </div>
            </CardContent>
          </Card>
        )
      })}

      {(groups ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">Групп пока нет.</p>
      ) : null}
    </div>
  )
}
