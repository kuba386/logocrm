import {
  BookOpen,
  CalendarDays,
  Contact,
  GraduationCap,
  Landmark,
  LayoutDashboard,
  Receipt,
  Settings,
  Users,
  Wallet,
  type LucideIcon,
} from 'lucide-react'

/**
 * По href, не по label: разные роли видят разный набор пунктов, но иконка
 * пункта не зависит от того, кто на него смотрит.
 */
export const NAV_ICONS: Record<string, LucideIcon> = {
  '/app': LayoutDashboard,
  '/app/schedule': CalendarDays,
  '/app/students': GraduationCap,
  '/app/library': BookOpen,
  '/app/payers': Contact,
  '/app/groups': Users,
  '/app/debts': Receipt,
  '/app/finance': Landmark,
  '/app/salary': Wallet,
  '/app/my-salary': Wallet,
  '/app/settings/staff': Settings,
}
