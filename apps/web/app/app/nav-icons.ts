import {
  Bell,
  BookOpen,
  CalendarDays,
  Contact,
  Download,
  GraduationCap,
  Inbox,
  Landmark,
  LayoutDashboard,
  Receipt,
  Send,
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
  '/app/reports': Download,
  '/app/my-salary': Wallet,
  '/app/notifications': Bell,
  '/app/bookings': Inbox,
  '/app/telegram': Send,
  '/app/settings/staff': Settings,
}
