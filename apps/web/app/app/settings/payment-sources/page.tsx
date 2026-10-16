import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { isFinance } from '@/lib/roles'
import { loadErrorMessage } from '@/lib/errors'
import { MoneyCatalog, type MoneyCatalogRow } from '../money-catalog'
import { archivePaymentSource, restorePaymentSource, savePaymentSource } from '../money-catalog-actions'

export const metadata = { title: 'Способы оплаты — LogoCRM' }

/** Наличные, Mbank, перевод… — по ним касса делится на источники (0013). Пишут owner/admin/finance. */
export default async function PaymentSourcesPage() {
  const supabase = await createClient()
  const { data: role } = await supabase.rpc('my_role')
  if (!isFinance(role)) redirect('/app')

  // Политика payment_sources_read_all отдаёт и архивные строки (название
  // нужно истории платежей) — делим на живые и архив здесь.
  const { data, error } = await supabase
    .from('payment_sources')
    .select('id, name, is_active, sort, deleted_at')
    .order('sort')
    .order('name')

  return (
    <MoneyCatalog
      title="Способы оплаты"
      description="Наличные, Mbank, перевод — по ним касса делится на источники. Архивный способ пропадает из форм, но остаётся в истории платежей."
      addTitle="Добавить способ"
      placeholder="Optima, Элсом, MegaPay…"
      inactiveLabel="Скрыт из форм"
      archivedHint="Скрыты из форм оплаты. Прошлые платежи показывают прежнее название."
      rows={(data ?? []) as MoneyCatalogRow[]}
      loadError={error ? loadErrorMessage(error, 'Не удалось загрузить способы оплаты. Обновите страницу.') : null}
      save={savePaymentSource}
      archive={archivePaymentSource}
      restore={restorePaymentSource}
    />
  )
}
