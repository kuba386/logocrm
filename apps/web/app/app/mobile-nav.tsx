'use client'

import { useState } from 'react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { Menu, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { NAV_ICONS } from './nav-icons'

export function MobileNav({ links }: { links: { href: string; label: string }[] }) {
  const [open, setOpen] = useState(false)
  const pathname = usePathname()

  return (
    <div className="sm:hidden">
      <Button
        type="button"
        variant="ghost"
        size="sm"
        aria-expanded={open}
        aria-label={open ? 'Закрыть меню' : 'Открыть меню'}
        onClick={() => setOpen((v) => !v)}
      >
        {open ? <X className="size-5" /> : <Menu className="size-5" />}
      </Button>

      {open ? (
        <nav className="absolute inset-x-0 top-16 z-20 flex flex-col gap-1 border-b border-border bg-card p-2 shadow-sm">
          {links.map((link) => {
            const Icon = NAV_ICONS[link.href]
            const active = pathname === link.href || pathname.startsWith(`${link.href}/`)
            return (
              <Link
                key={link.href}
                href={link.href}
                onClick={() => setOpen(false)}
                aria-current={active ? 'page' : undefined}
                className={cn(
                  'flex min-h-11 items-center gap-3 rounded-md px-3 text-sm font-medium',
                  active ? 'bg-secondary text-secondary-foreground' : 'hover:bg-accent',
                )}
              >
                {Icon ? <Icon className="size-4 shrink-0" /> : null}
                {link.label}
              </Link>
            )
          })}
        </nav>
      ) : null}
    </div>
  )
}
