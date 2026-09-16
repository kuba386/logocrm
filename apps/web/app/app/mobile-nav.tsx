'use client'

import { useState } from 'react'
import Link from 'next/link'
import { Menu, X } from 'lucide-react'
import { Button } from '@/components/ui/button'

export function MobileNav({ links }: { links: { href: string; label: string }[] }) {
  const [open, setOpen] = useState(false)

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
          {links.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              onClick={() => setOpen(false)}
              className="flex min-h-11 items-center rounded-md px-3 text-sm font-medium hover:bg-accent"
            >
              {link.label}
            </Link>
          ))}
        </nav>
      ) : null}
    </div>
  )
}
