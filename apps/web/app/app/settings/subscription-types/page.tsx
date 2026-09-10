import { redirect } from 'next/navigation'
import { toSom } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { CatalogForm } from '@/components/ui/catalog-form'
import { CatalogAction } from '@/components/ui/catalog-action'
import { saveSubscriptionType, archiveSubscriptionType, restoreSubscriptionType } from './actions'

export const metadata = { title: 'Типы абонементов — LogoCRM' }

type TypeRow = {
  id: string
  name: string
  service_id: string | null
  kind: string
  lessons_count: number | null
  period_days: number | null
  price_tiyin: number
  is_active: boolean
  deleted_at: string | null
}

type ServiceOption = { id: string; name: string }

const KIND_LABELS: Record<string, string> = {
  lessons: 'Пакет занятий',
  period: 'На период',
  unlimited: 'Безлимит',
}

function TypeFields({
  type,
  services,
  idSuffix,
}: {
  type?: TypeRow
  services: ServiceOption[]
  idSuffix: string
}) {
  return (
    <div className="grid gap-3 sm:grid-cols-6">
      <div className="space-y-1 sm:col-span-3">
        <Label htmlFor={`name-${idSuffix}`}>Название</Label>
        <Input id={`name-${idSuffix}`} name="name" defaultValue={type?.name ?? ''} placeholder="Стандарт 8" required />
      </div>
      <div className="space-y-1 sm:col-span-3">
        <Label htmlFor={`service-${idSuffix}`}>Услуга</Label>
        <Select id={`service-${idSuffix}`} name="serviceId" defaultValue={type?.service_id ?? ''}>
          <option value="">Любая услуга</option>
          {services.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </Select>
      </div>

      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor={`kind-${idSuffix}`}>Вид</Label>
        <Select id={`kind-${idSuffix}`} name="kind" defaultValue={type?.kind ?? 'lessons'}>
          {Object.entries(KIND_LABELS).map(([value, label]) => (
            <option key={value} value={value}>
              {label}
            </option>
          ))}
        </Select>
      </div>
      <div className="space-y-1">
        <Label htmlFor={`lessons-${idSuffix}`}>Занятий</Label>
        <Input
          id={`lessons-${idSuffix}`}
          name="lessonsCount"
          type="number"
          min={1}
          defaultValue={type?.lessons_count ?? ''}
          placeholder="8"
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`days-${idSuffix}`}>Дней</Label>
        <Input
          id={`days-${idSuffix}`}
          name="periodDays"
          type="number"
          min={1}
          defaultValue={type?.period_days ?? ''}
          placeholder="30"
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`price-${idSuffix}`}>Цена, сом</Label>
        <Input
          id={`price-${idSuffix}`}
          name="priceSom"
          type="number"
          step="0.01"
          min="0"
          defaultValue={type ? toSom(type.price_tiyin) : ''}
          required
        />
      </div>
      <label className="flex items-center gap-2 self-end text-sm">
        <input type="checkbox" name="isActive" defaultChecked={type?.is_active ?? true} />
        Активен
      </label>
      <p className="text-xs text-muted-foreground sm:col-span-6">
        «Занятий» нужно пакету, «Дней» — периодному; лишнее поле сохраняется пустым. Цена занятия внутри
        пакета считается при продаже и дальше не меняется.
      </p>
    </div>
  )
}

export default async function SubscriptionTypesPage() {
  const supabase = await createClient()

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const [{ data: types }, { data: services }] = await Promise.all([
    supabase
      .from('subscription_types')
      .select('id, name, service_id, kind, lessons_count, period_days, price_tiyin, is_active, deleted_at')
      .order('name'),
    supabase.from('services').select('id, name').is('deleted_at', null).eq('is_active', true).order('name'),
  ])

  const allRows = (types ?? []) as TypeRow[]
  const rows = allRows.filter((t) => !t.deleted_at)
  const archived = allRows.filter((t) => t.deleted_at)
  const serviceOptions: ServiceOption[] = (services ?? []).map((s) => ({ id: s.id, name: s.name }))

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Типы абонементов</h1>
        <p className="text-sm text-muted-foreground">
          Что администратор продаёт на карточке ученика. Цена — в сомах, в базе хранится в тыйынах.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Добавить тип</CardTitle>
        </CardHeader>
        <CardContent>
          <CatalogForm action={saveSubscriptionType} label="Добавить">
            <TypeFields services={serviceOptions} idSuffix="new" />
          </CatalogForm>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Список</CardTitle>
          <CardDescription>Всего: {rows.length}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {rows.map((type) => (
            <div key={type.id} className="space-y-3 rounded-md border border-border p-3">
              <p className="text-xs text-muted-foreground">
                {KIND_LABELS[type.kind] ?? type.kind}
                {type.kind === 'lessons' && type.lessons_count ? ` · ${type.lessons_count} занятий` : ''}
                {type.kind === 'period' && type.period_days ? ` · ${type.period_days} дней` : ''}
                {!type.is_active ? ' · неактивен' : ''}
              </p>
              <CatalogForm action={saveSubscriptionType}>
                <input type="hidden" name="id" value={type.id} />
                <TypeFields type={type} services={serviceOptions} idSuffix={type.id} />
              </CatalogForm>
              <div className="flex justify-end border-t border-border pt-3">
                <CatalogAction id={type.id} action={archiveSubscriptionType} label="В архив" />
              </div>
            </div>
          ))}
          {rows.length === 0 ? <p className="text-sm text-muted-foreground">Типов пока нет.</p> : null}
        </CardContent>
      </Card>

      {archived.length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>В архиве</CardTitle>
            <CardDescription>
              Скрыты из формы продажи. Уже проданные по ним абонементы продолжают показывать название.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            {archived.map((type) => (
              <div
                key={type.id}
                className="flex flex-wrap items-center justify-between gap-3 rounded-md border border-border p-3"
              >
                <div className="text-sm">
                  <p className="font-medium">{type.name}</p>
                  <p className="text-xs text-muted-foreground">
                    {KIND_LABELS[type.kind] ?? type.kind}
                    {type.kind === 'lessons' && type.lessons_count ? ` · ${type.lessons_count} занятий` : ''}
                    {type.kind === 'period' && type.period_days ? ` · ${type.period_days} дней` : ''}
                  </p>
                </div>
                <CatalogAction id={type.id} action={restoreSubscriptionType} label="Восстановить" />
              </div>
            ))}
          </CardContent>
        </Card>
      ) : null}
    </div>
  )
}
