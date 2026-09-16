'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { cn } from '@/lib/utils'
import { NAV_ICONS } from './nav-icons'

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
    <nav className="fixed inset-x-0 bottom-0 z-20 flex border-t border-border bg-card sm:hidden">
      {links.map((link) => {
        const Icon = NAV_ICONS[link.href]
        const active = link.href === '/app' ? pathname === link.href : pathname === link.href || pathname.startsWith(`${link.href}/`)
        return (
          <Link
            key={link.href}
            href={link.href}
            aria-current={active ? 'page' : undefined}
            className={cn(
              'flex min-h-[56px] flex-1 flex-col items-center justify-center gap-0.5 text-xs',
              active ? 'font-medium text-primary' : 'text-muted-foreground',
            )}
          >
            {Icon ? <Icon className="size-5" /> : null}
            {link.label}
          </Link>
        )
      })}
    </nav>
  )
}
