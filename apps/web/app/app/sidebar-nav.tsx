'use client'

import Link from 'next/link'
import { LinkPending } from './link-pending'
import { usePathname } from 'next/navigation'
import { cn } from '@/lib/utils'
import { NAV_ICONS } from './nav-icons'

export type NavLink = { href: string; label: string }
export type NavGroup = { label?: string; links: NavLink[] }

export function isActiveLink(pathname: string, href: string): boolean {
  // /app — префикс всех разделов, поэтому только точное совпадение.
  if (href === '/app') return pathname === href
  // Настройки: пункт ведёт на первый доступный раздел, а активен во всех.
  if (href.startsWith('/app/settings/')) return pathname.startsWith('/app/settings/')
  return pathname === href || pathname.startsWith(`${href}/`)
}

export function NavGroups({ groups, onNavigate }: { groups: NavGroup[]; onNavigate?: () => void }) {
  const pathname = usePathname()

  return (
    <>
      {groups.map((group, i) => (
        <div key={group.label ?? i} className="flex flex-col gap-0.5">
          {group.label ? (
            <p className="px-3 pb-1 pt-4 text-xs font-medium text-muted-foreground">{group.label}</p>
          ) : null}
          {group.links.map((link) => {
            const Icon = NAV_ICONS[link.href]
            const active = isActiveLink(pathname, link.href)
            return (
              <Link
                key={link.href}
                href={link.href}
                onClick={onNavigate}
                aria-current={active ? 'page' : undefined}
                className={cn(
                  'flex min-h-10 items-center gap-3 rounded-md px-3 text-sm font-medium transition-colors',
                  active
                    ? 'bg-secondary text-secondary-foreground'
                    : 'text-muted-foreground hover:bg-accent hover:text-foreground',
                )}
              >
                {Icon ? <Icon className="size-4 shrink-0" /> : null}
                {link.label}
                <LinkPending className="ml-auto" />
              </Link>
            )
          })}
        </div>
      ))}
    </>
  )
}

export function SidebarNav({ groups }: { groups: NavGroup[] }) {
  return (
    <nav aria-label="Разделы" className="flex flex-1 flex-col overflow-y-auto px-3 pb-3">
      <NavGroups groups={groups} />
    </nav>
  )
}
