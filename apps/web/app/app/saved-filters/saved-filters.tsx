'use client'

import { useActionState, useEffect, useState } from 'react'
import Link from 'next/link'
import { X } from 'lucide-react'
import { sameSavedFilterParams, type SavedFilterPage, type SavedFilterParams } from '@logocrm/core'
import { Button, buttonVariants } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'
import { SubmitButton } from '@/components/ui/submit-button'
import { useKeepValuesOnError } from '@/lib/use-keep-values'
import { t } from '@/lib/messages'
import { cn } from '@/lib/utils'
import { archiveSavedFilter, saveFilter, type SavedFilterState } from './actions'
import type { SavedFilterItem, SavedFiltersData } from './load'

const initial: SavedFilterState = {}

function hrefFor(basePath: string, params: SavedFilterParams, keep: Record<string, string>) {
  const search = new URLSearchParams({ ...keep, ...params }).toString()
  return search ? `${basePath}?${search}` : basePath
}

/**
 * «Мои фильтры» над списком (0094): сохранённые наборы — ссылками, текущий
 * набор можно сохранить под именем. Набор — личный: видит только автор.
 * keep — параметры адреса, которые набор не хранит, но сохраняет при переходе
 * (неделя расписания: набор применяется к той неделе, что открыта).
 */
export function SavedFilters({
  page,
  basePath,
  current,
  keep = {},
  data,
}: {
  page: SavedFilterPage
  basePath: string
  current: SavedFilterParams
  keep?: Record<string, string>
  data: SavedFiltersData
}) {
  const [open, setOpen] = useState(false)
  const [state, formAction] = useActionState(saveFilter, initial)
  const keepValues = useKeepValuesOnError(state, Boolean(state.message))
  const hasCurrent = Object.keys(current).length > 0

  // Сохранилось — форма закрывается, новый набор приходит с сервера (revalidatePath).
  useEffect(() => {
    if (state.notice) setOpen(false)
  }, [state])

  if (data.error) return <FormError message={data.error} />
  if (!data.allowed || (data.items.length === 0 && !hasCurrent)) return null

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="text-muted-foreground">{t('savedFilters', 'title')}:</span>
        {data.items.map((item) => (
          <SavedFilterChip
            key={item.id}
            item={item}
            page={page}
            href={hrefFor(basePath, item.params, keep)}
            active={sameSavedFilterParams(item.params, current)}
          />
        ))}
        {hasCurrent && !open ? (
          <Button type="button" variant="ghost" size="sm" onClick={() => setOpen(true)}>
            {t('savedFilters', 'save')}
          </Button>
        ) : null}
      </div>

      {open ? (
        <form action={formAction} className="flex flex-wrap items-end gap-2" {...keepValues}>
          <input type="hidden" name="page" value={page} />
          <input type="hidden" name="params" value={JSON.stringify(current)} />
          <div className="min-w-[200px] flex-1 space-y-1 sm:max-w-xs">
            <Label htmlFor={`saved-filter-name-${page}`}>{t('savedFilters', 'nameLabel')}</Label>
            <Input
              id={`saved-filter-name-${page}`}
              name="name"
              required
              maxLength={60}
              autoComplete="off"
              placeholder={t('savedFilters', 'namePlaceholder')}
            />
          </div>
          <SubmitButton size="sm" pendingLabel={t('common', 'pending')}>
            {t('savedFilters', 'submit')}
          </SubmitButton>
          <Button type="button" variant="ghost" size="sm" onClick={() => setOpen(false)}>
            {t('common', 'cancel')}
          </Button>
          <p className="w-full text-xs text-muted-foreground">{t('savedFilters', 'hint')}</p>
        </form>
      ) : null}

      <FormError message={state.message} />
      {!open ? <FormNotice message={state.notice} /> : null}
    </div>
  )
}

function SavedFilterChip({
  item,
  page,
  href,
  active,
}: {
  item: SavedFilterItem
  page: SavedFilterPage
  href: string
  active: boolean
}) {
  const [state, formAction] = useActionState(archiveSavedFilter, initial)

  return (
    <span className="inline-flex items-center">
      <Link
        href={href}
        aria-current={active ? 'true' : undefined}
        className={cn(buttonVariants({ variant: active ? 'default' : 'outline', size: 'sm' }), 'rounded-r-none')}
      >
        {item.name}
      </Link>
      <form action={formAction}>
        <input type="hidden" name="page" value={page} />
        <input type="hidden" name="id" value={item.id} />
        <SubmitButton
          variant={active ? 'default' : 'outline'}
          size="sm"
          className="rounded-l-none border-l-0 px-2"
          aria-label={t('savedFilters', 'remove', { name: item.name })}
          title={t('savedFilters', 'remove', { name: item.name })}
        >
          <X className="size-3.5" aria-hidden="true" />
        </SubmitButton>
      </form>
      {state.message ? (
        <span role="alert" className="ml-2 text-xs text-destructive">
          {state.message}
        </span>
      ) : null}
    </span>
  )
}
