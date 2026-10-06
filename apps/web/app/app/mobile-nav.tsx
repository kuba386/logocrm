'use client'

import { useEffect, useRef, useState, type ReactNode } from 'react'
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
  const triggerRef = useRef<HTMLButtonElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)
  const wasOpen = useRef(false)

  useEffect(() => {
    setOpen(false)
  }, [pathname])

  // Фокус: при открытии — в меню, Tab не уходит под затемнение, при закрытии —
  // обратно на «Открыть меню». Раньше фокус оставался на кнопке под
  // затемнением, и с клавиатуры или VoiceOver меню было не пройти (UX41/UX100).
  useEffect(() => {
    if (open) {
      closeRef.current?.focus()
    } else if (wasOpen.current) {
      triggerRef.current?.focus()
    }
    wasOpen.current = open
  }, [open])

  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false)
      if (event.key !== 'Tab' || !panelRef.current) return
      const focusable = [...panelRef.current.querySelectorAll<HTMLElement>('a[href], button:not([disabled]), input, select, textarea')]
      if (focusable.length === 0) return
      const first = focusable[0]!
      const last = focusable[focusable.length - 1]!
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
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
        ref={triggerRef}
        type="button"
        variant="ghost"
        size="sm"
        className="-ml-2"
        aria-expanded={open}
        aria-label="Открыть меню"
        onClick={() => setOpen(true)}
      >
        <Menu className="size-5" aria-hidden="true" />
      </Button>

      {open ? (
        <div className="fixed inset-0 z-40 sm:hidden" role="dialog" aria-modal="true" aria-label="Меню">
          <button
            type="button"
            aria-label="Закрыть меню"
            tabIndex={-1}
            className="absolute inset-0 bg-foreground/30"
            onClick={() => setOpen(false)}
          />
          <div
            ref={panelRef}
            className="absolute inset-y-0 left-0 flex w-[85%] max-w-xs flex-col bg-card shadow-xl animate-in slide-in-from-left duration-200 motion-reduce:animate-none"
          >
            <div className="flex items-start justify-between gap-2 border-b border-border p-4">
              {header}
              <Button
                ref={closeRef}
                type="button"
                variant="ghost"
                size="sm"
                className="-mr-2 -mt-1"
                aria-label="Закрыть меню"
                onClick={() => setOpen(false)}
              >
                <X className="size-5" aria-hidden="true" />
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
