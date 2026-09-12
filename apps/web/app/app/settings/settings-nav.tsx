'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { cn } from '@/lib/utils'

/**
 * Разделы настроек. До этого из шапки вела одна ссылка — на сотрудников,
 * а кабинеты и услуги существовали только по прямому адресу.
 */
const SECTIONS = [
  { href: '/app/settings/staff', label: 'Сотрудники' },
  { href: '/app/settings/rooms', label: 'Кабинеты' },
  { href: '/app/settings/services', label: 'Услуги' },
  { href: '/app/settings/attendance-statuses', label: 'Статусы посещения' },
  { href: '/app/settings/subscription-types', label: 'Типы абонементов' },
  { href: '/app/settings/teacher-rates', label: 'Ставки' },
]

export function SettingsNav() {
  const pathname = usePathname()

  return (
    <nav className="flex flex-wrap gap-1 border-b border-border">
      {SECTIONS.map((section) => (
        <Link
          key={section.href}
          href={section.href}
          className={cn(
            'border-b-2 px-3 pb-2 text-sm font-medium transition-colors',
            pathname.startsWith(section.href)
              ? 'border-primary text-foreground'
              : 'border-transparent text-muted-foreground hover:text-foreground',
          )}
        >
          {section.label}
        </Link>
      ))}
    </nav>
  )
}
