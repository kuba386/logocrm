import { redirect } from 'next/navigation'
import { toSom } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { CatalogForm } from '@/components/ui/catalog-form'
import { CatalogRow } from '@/components/ui/catalog-row'
import { EmptyState } from '@/components/ui/empty-state'
import { StatusBadge } from '@/components/ui/status-badge'
import { CatalogAction } from '@/components/ui/catalog-action'
import { saveSubscriptionType, archiveSubscriptionType, restoreSubscriptionType } from './actions'
import { loadErrorMessage } from '@/lib/errors'
import { FormError } from '@/components/ui/alert'

export const metadata = { title: 'Типы абонементов — LogoCRM' }

type TypeRow = {
  id: string
  name: string
  service_id: string | null
  /** 0106: основная + дополнительные — набор галочек. */
  serviceIds: string[]
  kind: string
  lessons_count: number | null
  period_days: number | null
  price_tiyin: number
  is_active: boolean
  deleted_at: string | null
}

type ServiceOption = { id: string; name: string; live: boolean }

/** Живые услуги + услуги этого типа, даже архивные. */
function servicesFor(services: ServiceOption[], type?: TypeRow): ServiceOption[] {
  return services.filter((s) => s.live || (type?.serviceIds.includes(s.id) ?? false))
}

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
      <fieldset className="space-y-1 sm:col-span-3" aria-describedby={type ? undefined : `service-hint-${idSuffix}`}>
        <legend className="text-sm font-medium">Услуги</legend>
        <div className="flex flex-wrap gap-x-4 gap-y-1">
          {/* Услуги типа показываем и архивные — иначе сохранение молча сняло бы их. */}
          {servicesFor(services, type).map((s) => (
            <label key={s.id} className="flex min-h-9 items-center gap-2 text-sm">
              <input
                type="checkbox"
                name="serviceIds"
                value={s.id}
                defaultChecked={type?.serviceIds.includes(s.id) ?? false}
                className="size-4"
              />
              {s.name}
            </label>
          ))}
        </div>
        {/* Подсказка — только в форме нового типа: в списке она повторялась бы у каждой строки. */}
        {type ? null : (
          <p id={`service-hint-${idSuffix}`} className="text-xs text-muted-foreground">
            Абонемент списывается только с занятий отмеченных услуг — можно отметить несколько, например логопеда и СМК.
            Ничего не отмечено — с занятий любой услуги. После первой продажи набор услуг не меняется.
          </p>
        )}
      </fieldset>

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

  const [{ data: types, error: loadError }, { data: services }, { data: extras }] = await Promise.all([
    supabase
      .from('subscription_types')
      .select('id, name, service_id, kind, lessons_count, period_days, price_tiyin, is_active, deleted_at')
      .order('name'),
    supabase.from('services').select('id, name, deleted_at, is_active').order('name'),
    supabase.from('subscription_type_extra_services').select('type_id, service_id').is('deleted_at', null),
  ])

  const extrasByType = new Map<string, string[]>()
  for (const row of extras ?? []) {
    extrasByType.set(row.type_id, [...(extrasByType.get(row.type_id) ?? []), row.service_id])
  }
  const allRows: TypeRow[] = (types ?? []).map((t) => ({
    ...t,
    serviceIds: t.service_id ? [t.service_id, ...(extrasByType.get(t.id) ?? [])] : [],
  }))
  const rows = allRows.filter((t) => !t.deleted_at)
  const archived = allRows.filter((t) => t.deleted_at)
  const serviceOptions: ServiceOption[] = (services ?? []).map((s) => ({
    id: s.id,
    name: s.name,
    live: !s.deleted_at && s.is_active,
  }))
  const serviceName = new Map(serviceOptions.map((s) => [s.id, s.name]))

  return (
    <div className="space-y-6">
      <div>
        <h1 className="page-title">Типы абонементов</h1>
        <p className="text-sm text-muted-foreground">
          Что администратор продаёт на карточке ученика. Цена — в сомах.
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
        <CardContent>
          <ul className="divide-y divide-border">
            {rows.map((type) => (
              <CatalogRow
                key={type.id}
                title={type.name}
                meta={[
                  KIND_LABELS[type.kind] ?? type.kind,
                  type.serviceIds.length > 0
                    ? type.serviceIds.map((sid) => serviceName.get(sid) ?? 'услуга').join(' + ')
                    : 'любая услуга',
                  type.kind === 'lessons' && type.lessons_count ? `${type.lessons_count} занятий` : null,
                  type.kind === 'period' && type.period_days ? `${type.period_days} дней` : null,
                ]
                  .filter(Boolean)
                  .join(', ')}
                badge={type.is_active ? null : <StatusBadge>Не продаётся</StatusBadge>}
              >
                <div className="space-y-3">
                  <CatalogForm action={saveSubscriptionType}>
                    <input type="hidden" name="id" value={type.id} />
                    <TypeFields type={type} services={serviceOptions} idSuffix={type.id} />
                  </CatalogForm>
                  <div className="flex justify-end border-t border-border pt-3">
                    <CatalogAction id={type.id} action={archiveSubscriptionType} label="В архив" />
                  </div>
                </div>
              </CatalogRow>
            ))}
          </ul>
          {loadError ? (
            <FormError message={loadErrorMessage(loadError, 'Не удалось загрузить типы абонементов. Обновите страницу.')} />
          ) : rows.length === 0 ? (
            <EmptyState title="Типов пока нет" description="Добавьте первый — форма выше." />
          ) : null}
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
                    {type.kind === 'lessons' && type.lessons_count ? `, ${type.lessons_count} занятий` : ''}
                    {type.kind === 'period' && type.period_days ? `, ${type.period_days} дней` : ''}
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
