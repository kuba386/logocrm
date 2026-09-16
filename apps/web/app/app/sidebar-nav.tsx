'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { cn } from '@/lib/utils'
import { NAV_ICONS } from './nav-icons'

export function SidebarNav({ links }: { links: { href: string; label: string }[] }) {
  const pathname = usePathname()

  return (
    <nav className="flex flex-1 flex-col gap-1 overflow-y-auto p-3">
      {links.map((link) => {
        const Icon = NAV_ICONS[link.href]
        const active = pathname === link.href || pathname.startsWith(`${link.href}/`)
        return (
          <Link
            key={link.href}
            href={link.href}
            aria-current={active ? 'page' : undefined}
            className={cn(
              'flex min-h-11 items-center gap-3 rounded-md px-3 text-sm font-medium transition-colors',
              active
                ? 'bg-secondary text-secondary-foreground'
                : 'text-muted-foreground hover:bg-accent hover:text-foreground',
            )}
          >
            {Icon ? <Icon className="size-4 shrink-0" /> : null}
            {link.label}
          </Link>
        )
      })}
    </nav>
  )
}
