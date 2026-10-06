import Link from 'next/link'
import type { LucideIcon } from 'lucide-react'
import { cn } from '@/lib/utils'
import type { StatusTone } from '@/components/ui/status-badge'

const TONES: Record<StatusTone, { tile: string; icon: string }> = {
  success: { tile: 'bg-success-bg', icon: 'bg-success text-white' },
  warning: { tile: 'bg-warning-bg', icon: 'bg-warning text-white' },
  danger: { tile: 'bg-danger-bg', icon: 'bg-danger text-white' },
  info: { tile: 'bg-info-bg', icon: 'bg-info text-white' },
  neutral: { tile: 'border border-border bg-card', icon: 'bg-status-neutral text-white' },
  primary: { tile: 'bg-secondary', icon: 'bg-primary text-primary-foreground' },
}

/**
 * Плитка показателя: цветной фон, иконка, крупная цифра, подпись. Цвета —
 * те же тона, что у StatusBadge, чтобы «красное» значило одно и то же на
 * плитке и в бейдже. С href вся плитка — ссылка: цифра ведёт к списку.
 */
export function StatTile({
  icon: Icon,
  value,
  label,
  hint,
  tone = 'neutral',
  href,
}: {
  icon: LucideIcon
  value: string | number
  label: string
  hint?: string
  tone?: StatusTone
  href?: string
}) {
  const colors = TONES[tone]
  const body = (
    <>
      <span className={cn('flex h-9 w-9 items-center justify-center rounded-full', colors.icon)}>
        <Icon className="h-5 w-5" aria-hidden />
      </span>
      <span className="mt-3 block break-words font-display text-xl font-medium leading-tight tracking-tight sm:text-2xl">{value}</span>
      <span className="mt-1 block text-sm font-medium">{label}</span>
      {hint ? <span className="mt-0.5 block text-xs text-muted-foreground">{hint}</span> : null}
    </>
  )
  const className = cn('block min-w-0 rounded-xl p-4 text-foreground', colors.tile)

  return href ? (
    <Link href={href} className={cn(className, 'transition-shadow hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring')}>
      {body}
    </Link>
  ) : (
    <div className={className}>{body}</div>
  )
}
