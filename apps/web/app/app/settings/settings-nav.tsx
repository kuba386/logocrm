'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { cn } from '@/lib/utils'

export type SettingsSection = { href: string; label: string }

export function SettingsNav({ sections }: { sections: SettingsSection[] }) {
  const pathname = usePathname()

  if (sections.length < 2) return null

  return (
    <nav
      aria-label="Разделы настроек"
      className="-mx-6 flex gap-1 overflow-x-auto border-b border-border px-6 sm:mx-0 sm:flex-wrap sm:px-0"
    >
      {sections.map((section) => {
        const active = pathname.startsWith(section.href)
        return (
          <Link
            key={section.href}
            href={section.href}
            aria-current={active ? 'page' : undefined}
            className={cn(
              'inline-flex min-h-11 shrink-0 items-end whitespace-nowrap border-b-2 px-3 pb-2 text-sm font-medium transition-colors sm:min-h-0',
              active
                ? 'border-primary text-foreground'
                : 'border-transparent text-muted-foreground hover:text-foreground',
            )}
          >
            {section.label}
          </Link>
        )
      })}
    </nav>
  )
}
