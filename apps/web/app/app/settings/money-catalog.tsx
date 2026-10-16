import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { CatalogForm } from '@/components/ui/catalog-form'
import { CatalogRow } from '@/components/ui/catalog-row'
import { CatalogAction } from '@/components/ui/catalog-action'
import { EmptyState } from '@/components/ui/empty-state'
import { StatusBadge } from '@/components/ui/status-badge'
import { FormError } from '@/components/ui/alert'
import type { CatalogState } from './services/actions'

export type MoneyCatalogRow = { id: string; name: string; is_active: boolean; sort: number; deleted_at: string | null }

type Action = (state: CatalogState, formData: FormData) => Promise<CatalogState>

function Fields({ row, idSuffix, placeholder }: { row?: MoneyCatalogRow; idSuffix: string; placeholder: string }) {
  return (
    <div className="grid gap-3 sm:grid-cols-6">
      <div className="space-y-1 sm:col-span-4">
        <Label htmlFor={`name-${idSuffix}`}>Название</Label>
        <Input id={`name-${idSuffix}`} name="name" defaultValue={row?.name ?? ''} placeholder={placeholder} maxLength={60} required />
      </div>
      <div className="space-y-1">
        <Label htmlFor={`sort-${idSuffix}`}>Порядок</Label>
        <Input id={`sort-${idSuffix}`} name="sort" type="number" min={0} max={10000} step={1} defaultValue={row?.sort ?? ''} placeholder="100" />
      </div>
      <label className="flex items-center gap-2 self-end pb-2 text-sm">
        <input type="checkbox" name="isActive" defaultChecked={row?.is_active ?? true} className="size-4" />
        В формах
      </label>
    </div>
  )
}

/**
 * Справочник денег: способы оплаты или статьи расходов. Одна разметка на оба —
 * отличаются только подписями и действиями. Архивная строка остаётся в
 * истории платежей и расходов с прежним названием.
 */
export function MoneyCatalog({
  title,
  description,
  addTitle,
  placeholder,
  inactiveLabel,
  archivedHint,
  rows,
  loadError,
  save,
  archive,
  restore,
}: {
  title: string
  description: string
  addTitle: string
  placeholder: string
  inactiveLabel: string
  archivedHint: string
  rows: MoneyCatalogRow[]
  loadError: string | null
  save: Action
  archive: Action
  restore: Action
}) {
  const live = rows.filter((r) => !r.deleted_at)
  const archived = rows.filter((r) => r.deleted_at)

  return (
    <div className="space-y-6">
      <div>
        <h1 className="page-title">{title}</h1>
        <p className="text-sm text-muted-foreground">{description}</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{addTitle}</CardTitle>
        </CardHeader>
        <CardContent>
          <CatalogForm action={save} label="Добавить">
            <Fields idSuffix="new" placeholder={placeholder} />
          </CatalogForm>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Список</CardTitle>
          {loadError ? null : <CardDescription>Всего: {live.length}. В формах — по порядку, меньше число — выше.</CardDescription>}
        </CardHeader>
        <CardContent>
          {loadError ? (
            <FormError message={loadError} />
          ) : live.length === 0 ? (
            <EmptyState title="Пока пусто" description="Добавьте первый — форма выше." />
          ) : (
            <ul className="divide-y divide-border">
              {live.map((row) => (
                <CatalogRow
                  key={row.id}
                  title={row.name}
                  meta={`Порядок ${row.sort}`}
                  badge={row.is_active ? null : <StatusBadge>{inactiveLabel}</StatusBadge>}
                >
                  <div className="space-y-3">
                    <CatalogForm action={save}>
                      <input type="hidden" name="id" value={row.id} />
                      <Fields row={row} idSuffix={row.id} placeholder={placeholder} />
                    </CatalogForm>
                    <div className="flex justify-end border-t border-border pt-3">
                      <CatalogAction id={row.id} action={archive} label="В архив" />
                    </div>
                  </div>
                </CatalogRow>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      {archived.length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>В архиве</CardTitle>
            <CardDescription>{archivedHint}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            {archived.map((row) => (
              <div key={row.id} className="flex flex-wrap items-center justify-between gap-3 rounded-md border border-border p-3">
                <p className="text-sm font-medium">{row.name}</p>
                <CatalogAction id={row.id} action={restore} label="Восстановить" />
              </div>
            ))}
          </CardContent>
        </Card>
      ) : null}
    </div>
  )
}
