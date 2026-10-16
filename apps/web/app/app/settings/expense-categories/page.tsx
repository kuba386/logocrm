import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { isFinance } from '@/lib/roles'
import { loadErrorMessage } from '@/lib/errors'
import { MoneyCatalog, type MoneyCatalogRow } from '../money-catalog'
import { archiveExpenseCategory, restoreExpenseCategory, saveExpenseCategory } from '../money-catalog-actions'

export const metadata = { title: 'Статьи расходов — LogoCRM' }

/** Аренда, зарплата, материалы… — разрез расходов в «Отчётах» (0016). Пишут owner/admin/finance. */
export default async function ExpenseCategoriesPage() {
  const supabase = await createClient()
  const { data: role } = await supabase.rpc('my_role')
  if (!isFinance(role)) redirect('/app')

  // Живые строки — tenant_admin/finance write, архивные — expense_categories_read_archived (0028).
  const { data, error } = await supabase
    .from('expense_categories')
    .select('id, name, is_active, sort, deleted_at')
    .order('sort')
    .order('name')

  return (
    <MoneyCatalog
      title="Статьи расходов"
      description="Аренда, зарплата, материалы — по ним расходы раскладываются в «Отчётах». Архивная статья пропадает из формы, но остаётся в истории."
      addTitle="Добавить статью"
      placeholder="Логопедические пособия, обучение…"
      inactiveLabel="Скрыта из формы"
      archivedHint="Скрыты из формы расхода. Прошлые расходы показывают прежнее название."
      rows={(data ?? []) as MoneyCatalogRow[]}
      loadError={error ? loadErrorMessage(error, 'Не удалось загрузить статьи расходов. Обновите страницу.') : null}
      save={saveExpenseCategory}
      archive={archiveExpenseCategory}
      restore={restoreExpenseCategory}
    />
  )
}
