import { createClient } from '@/lib/supabase/server'
import { isFinance } from '@/lib/roles'
import { SettingsNav, type SettingsSection } from './settings-nav'

const ADMIN_SECTIONS: SettingsSection[] = [
  { href: '/app/settings/staff', label: 'Сотрудники' },
  { href: '/app/settings/rooms', label: 'Кабинеты' },
  { href: '/app/settings/services', label: 'Услуги' },
  { href: '/app/settings/attendance-statuses', label: 'Статусы посещения' },
  { href: '/app/settings/subscription-types', label: 'Типы абонементов' },
  { href: '/app/settings/payment-sources', label: 'Способы оплаты' },
  { href: '/app/settings/expense-categories', label: 'Статьи расходов' },
  { href: '/app/settings/discount-reasons', label: 'Причины скидок' },
  { href: '/app/settings/teacher-rates', label: 'Ставки' },
  { href: '/app/settings/notifications', label: 'Уведомления' },
  { href: '/app/settings/plan', label: 'Тариф' },
]

const FINANCE_SECTIONS = new Set([
  '/app/settings/payment-sources',
  '/app/settings/expense-categories',
  '/app/settings/discount-reasons',
  '/app/settings/teacher-rates',
])

/**
 * Роль проверяет каждая страница сама (redirect на /app) — здесь только
 * подменю: показываем те разделы, куда роль пустят, как и главное меню.
 */
export default async function SettingsLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient()
  const { data: role } = await supabase.rpc('my_role')
  const isAdmin = role === 'owner' || role === 'admin'
  // Бухгалтеру — справочники денег и ставки (can_finance): способы оплаты,
  // статьи расходов (0027/0028) и ставки специалистов.
  const sections = isAdmin
    ? ADMIN_SECTIONS
    : ADMIN_SECTIONS.filter((section) => FINANCE_SECTIONS.has(section.href) && isFinance(role))

  return (
    <div className="space-y-6">
      <SettingsNav sections={sections} />
      {children}
    </div>
  )
}
