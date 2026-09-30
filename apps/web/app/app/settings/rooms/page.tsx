import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { CatalogForm } from '@/components/ui/catalog-form'
import { CatalogRow } from '@/components/ui/catalog-row'
import { EmptyState } from '@/components/ui/empty-state'
import { StatusBadge } from '@/components/ui/status-badge'
import { saveRoom } from '../services/actions'

export const metadata = { title: 'Кабинеты — LogoCRM' }

export default async function RoomsPage() {
  const supabase = await createClient()

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const { data: rooms } = await supabase
    .from('rooms')
    .select('id, name, capacity, is_active')
    .is('deleted_at', null)
    .order('name')

  return (
    <div className="space-y-6">
      <div>
        <h1 className="page-title">Кабинеты</h1>
        <p className="text-sm text-muted-foreground">
          Два занятия в одном кабинете одновременно поставить нельзя — проверяет база.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Добавить кабинет</CardTitle>
        </CardHeader>
        <CardContent>
          <CatalogForm action={saveRoom} label="Добавить">
            <div className="grid gap-3 sm:grid-cols-3">
              <div className="space-y-1 sm:col-span-2">
                <Label htmlFor="name">Название</Label>
                <Input id="name" name="name" placeholder="Кабинет 1" required />
              </div>
              <div className="space-y-1">
                <Label htmlFor="capacity">Мест</Label>
                <Input id="capacity" name="capacity" type="number" defaultValue={1} min={1} />
              </div>
              <label className="flex items-center gap-2 text-sm">
                <input type="checkbox" name="isActive" defaultChecked />
                Активен
              </label>
            </div>
          </CatalogForm>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Список</CardTitle>
          <CardDescription>Всего: {rooms?.length ?? 0}</CardDescription>
        </CardHeader>
        <CardContent>
          <ul className="divide-y divide-border">
            {(rooms ?? []).map((room) => (
              <CatalogRow
                key={room.id}
                title={room.name}
                meta={`Мест: ${room.capacity}`}
                badge={room.is_active ? null : <StatusBadge>Не используется</StatusBadge>}
              >
              <CatalogForm action={saveRoom}>
                <input type="hidden" name="id" value={room.id} />
                <div className="grid gap-3 sm:grid-cols-3">
                  <div className="space-y-1 sm:col-span-2">
                    <Label htmlFor={`name-${room.id}`}>Название</Label>
                    <Input id={`name-${room.id}`} name="name" defaultValue={room.name} required />
                  </div>
                  <div className="space-y-1">
                    <Label htmlFor={`capacity-${room.id}`}>Мест</Label>
                    <Input
                      id={`capacity-${room.id}`}
                      name="capacity"
                      type="number"
                      defaultValue={room.capacity}
                      min={1}
                    />
                  </div>
                  <label className="flex items-center gap-2 text-sm">
                    <input type="checkbox" name="isActive" defaultChecked={room.is_active} />
                    Активен
                  </label>
                </div>
              </CatalogForm>
            </CatalogRow>
          ))}
          </ul>
          {(rooms ?? []).length === 0 ? <EmptyState title="Кабинетов пока нет" description="Добавьте первый — форма выше." /> : null}
        </CardContent>
      </Card>
    </div>
  )
}
