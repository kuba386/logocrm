'use client'

import { useEffect, useState, type ReactNode } from 'react'
import { usePathname } from 'next/navigation'
import { Menu, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { NavGroups, type NavGroup } from './sidebar-nav'

/**
 * Мобильное меню — панель слева поверх страницы. Закрывается кнопкой,
 * нажатием на затемнение, Escape и переходом по ссылке.
 */
export function MobileNav({
  groups,
  header,
  footer,
}: {
  groups: NavGroup[]
  header: ReactNode
  footer: ReactNode
}) {
  const [open, setOpen] = useState(false)
  const pathname = usePathname()

  useEffect(() => {
    setOpen(false)
  }, [pathname])

  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false)
    }
    const overflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    document.addEventListener('keydown', onKey)
    return () => {
      document.body.style.overflow = overflow
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  return (
    <>
      <Button
        type="button"
        variant="ghost"
        size="sm"
        className="-ml-2"
        aria-expanded={open}
        aria-label="Открыть меню"
        onClick={() => setOpen(true)}
      >
        <Menu className="size-5" />
      </Button>

      {open ? (
        <div className="fixed inset-0 z-40 sm:hidden" role="dialog" aria-modal="true" aria-label="Меню">
          <button
            type="button"
            aria-label="Закрыть меню"
            className="absolute inset-0 bg-foreground/30"
            onClick={() => setOpen(false)}
          />
          <div className="absolute inset-y-0 left-0 flex w-[85%] max-w-xs flex-col bg-card shadow-xl animate-in slide-in-from-left duration-200">
            <div className="flex items-start justify-between gap-2 border-b border-border p-4">
              {header}
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="-mr-2 -mt-1"
                aria-label="Закрыть меню"
                onClick={() => setOpen(false)}
              >
                <X className="size-5" />
              </Button>
            </div>
            <nav aria-label="Разделы" className="flex-1 overflow-y-auto px-3 pb-3">
              <NavGroups groups={groups} onNavigate={() => setOpen(false)} />
            </nav>
            <div className="flex flex-col gap-2 border-t border-border p-3">{footer}</div>
          </div>
        </div>
      ) : null}
    </>
  )
}
