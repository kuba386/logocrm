import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { CatalogForm } from '@/components/ui/catalog-form'
import { toSom } from '@logocrm/core'
import { saveService } from './actions'

export const metadata = { title: 'Услуги — LogoCRM' }

export default async function ServicesPage() {
  const supabase = await createClient()

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const { data: services } = await supabase
    .from('services')
    .select('id, name, duration_min, default_price_tiyin, kind, is_active')
    .is('deleted_at', null)
    .order('name')

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Услуги</h1>
        <p className="text-sm text-muted-foreground">
          Длительность отсюда подставляется в расписание. Цена — в сомах, в базе хранится в тыйынах.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Добавить услугу</CardTitle>
        </CardHeader>
        <CardContent>
          <CatalogForm action={saveService} label="Добавить">
            <div className="grid gap-3 sm:grid-cols-4">
              <div className="space-y-1 sm:col-span-2">
                <Label htmlFor="name">Название</Label>
                <Input id="name" name="name" placeholder="Индивидуальное занятие" required />
              </div>
              <div className="space-y-1">
                <Label htmlFor="durationMin">Минут</Label>
                <Input id="durationMin" name="durationMin" type="number" defaultValue={45} min={5} required />
              </div>
              <div className="space-y-1">
                <Label htmlFor="priceSom">Цена, сом</Label>
                <Input id="priceSom" name="priceSom" type="number" step="0.01" min="0" />
              </div>
              <div className="space-y-1 sm:col-span-2">
                <Label htmlFor="kind">Тип</Label>
                <Select id="kind" name="kind" defaultValue="individual">
                  <option value="individual">Индивидуальное</option>
                  <option value="group">Групповое</option>
                </Select>
              </div>
              <label className="flex items-center gap-2 self-end text-sm">
                <input type="checkbox" name="isActive" defaultChecked />
                Активна
              </label>
            </div>
          </CatalogForm>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Список</CardTitle>
          <CardDescription>Всего: {services?.length ?? 0}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {(services ?? []).map((service) => (
            <div key={service.id} className="rounded-md border border-border p-3">
              <CatalogForm action={saveService}>
                <input type="hidden" name="id" value={service.id} />
                <div className="grid gap-3 sm:grid-cols-4">
                  <div className="space-y-1 sm:col-span-2">
                    <Label htmlFor={`name-${service.id}`}>Название</Label>
                    <Input id={`name-${service.id}`} name="name" defaultValue={service.name} required />
                  </div>
                  <div className="space-y-1">
                    <Label htmlFor={`duration-${service.id}`}>Минут</Label>
                    <Input
                      id={`duration-${service.id}`}
                      name="durationMin"
                      type="number"
                      defaultValue={service.duration_min}
                      min={5}
                      required
                    />
                  </div>
                  <div className="space-y-1">
                    <Label htmlFor={`price-${service.id}`}>Цена, сом</Label>
                    <Input
                      id={`price-${service.id}`}
                      name="priceSom"
                      type="number"
                      step="0.01"
                      min="0"
                      defaultValue={
                        service.default_price_tiyin === null ? '' : toSom(service.default_price_tiyin)
                      }
                    />
                  </div>
                  <div className="space-y-1 sm:col-span-2">
                    <Label htmlFor={`kind-${service.id}`}>Тип</Label>
                    <Select id={`kind-${service.id}`} name="kind" defaultValue={service.kind}>
                      <option value="individual">Индивидуальное</option>
                      <option value="group">Групповое</option>
                    </Select>
                  </div>
                  <label className="flex items-center gap-2 self-end text-sm">
                    <input type="checkbox" name="isActive" defaultChecked={service.is_active} />
                    Активна
                  </label>
                </div>
              </CatalogForm>
            </div>
          ))}
          {(services ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">Услуг пока нет.</p>
          ) : null}
        </CardContent>
      </Card>
    </div>
  )
}
