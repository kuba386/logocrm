import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { isFinance } from '@/lib/roles'
import { loadErrorMessage } from '@/lib/errors'
import { MoneyCatalog, type MoneyCatalogRow } from '../money-catalog'
import { archiveDiscountReason, restoreDiscountReason, saveDiscountReason } from '../money-catalog-actions'

export const metadata = { title: 'Причины скидок — LogoCRM' }

/**
 * Второй ребёнок, многодетная семья, акция… — без причины база не проведёт
 * продажу дешевле цены типа, а «Отчёты» складывают скидки по причинам (0101).
 * Пишут owner/admin/finance; стойка выбирает причину в форме продажи.
 */
export default async function DiscountReasonsPage() {
  const supabase = await createClient()
  const { data: role } = await supabase.rpc('my_role')
  if (!isFinance(role)) redirect('/app')

  // Живые строки — tenant_admin/finance write, архивные — discount_reasons_read_archived (0101).
  const { data, error } = await supabase
    .from('discount_reasons')
    .select('id, name, is_active, sort, deleted_at')
    .order('sort')
    .order('name')

  return (
    <MoneyCatalog
      title="Причины скидок"
      description="Продажа дешевле цены типа проводится только с причиной — по ним «Отчёты» показывают, сколько и почему недополучено. Архивная причина пропадает из формы продажи, но остаётся в истории."
      addTitle="Добавить причину"
      placeholder="Сотрудник центра, рекомендация…"
      inactiveLabel="Скрыта из формы"
      archivedHint="Скрыты из формы продажи. Проданные абонементы показывают прежнее название."
      rows={(data ?? []) as MoneyCatalogRow[]}
      loadError={error ? loadErrorMessage(error, 'Не удалось загрузить причины скидок. Обновите страницу.') : null}
      save={saveDiscountReason}
      archive={archiveDiscountReason}
      restore={restoreDiscountReason}
    />
  )
}
