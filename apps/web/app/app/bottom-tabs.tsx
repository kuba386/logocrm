'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { cn } from '@/lib/utils'
import { NAV_ICONS } from './nav-icons'
import { isActiveLink } from './sidebar-nav'

/**
 * Только для teacher/parent (layout.tsx решает, кому показывать) — у них
 * мало разделов, и в макетах Stitch (specialist-day-mobile.png,
 * parent-cabinet-mobile.png) это нижние вкладки, а не гамбургер.
 * У admin/finance/registrar пунктов меню на порядок больше — им остаётся
 * MobileNav.
 */
export function BottomTabs({ links }: { links: { href: string; label: string }[] }) {
  const pathname = usePathname()

  return (
    <nav aria-label="Разделы" className="fixed inset-x-0 bottom-0 z-20 flex border-t border-border bg-card sm:hidden">
      {links.map((link) => {
        const Icon = NAV_ICONS[link.href]
        const active = isActiveLink(pathname, link.href)
        return (
          <Link
            key={link.href}
            href={link.href}
            aria-current={active ? 'page' : undefined}
            className={cn(
              'flex min-h-[56px] min-w-0 flex-1 flex-col items-center justify-center gap-0.5 px-0.5 text-[11px] leading-tight focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring',
              active ? 'font-medium text-primary' : 'text-muted-foreground',
            )}
          >
            {/* Активная вкладка — пилюлей за иконкой, а не только оттенком (UX3/UX37). */}
            <span className={cn('flex h-7 w-12 items-center justify-center rounded-full', active && 'bg-secondary')}>
              {Icon ? <Icon className="size-5" aria-hidden="true" /> : null}
            </span>
            <span className="max-w-full truncate">{link.label}</span>
          </Link>
        )
      })}
    </nav>
  )
}
