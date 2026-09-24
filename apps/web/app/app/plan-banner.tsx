import Link from 'next/link'
import { t } from '@/lib/messages'
import { PLAN_WARNING_DAYS, type CenterLimits } from '@/lib/plan'
import { cn } from '@/lib/utils'

/**
 * Состояния из center_limits() (0050 Р11, 0056 Р7): удалён — заявка на
 * удаление подана; истёк — только чтение; заканчивается через ≤ 3 дня —
 * предупреждение; иначе ничего. «Удалён» и «истёк» — разные тексты:
 * после «Удалить центр» требование «оплатите» читалось бы как издёвка.
 * Дни считает SQL в поясе центра, здесь — только текст и ссылка.
 */
export function PlanBanner({ limits }: { limits: CenterLimits | null }) {
  if (!limits) return null

  let text: string | null = null
  let tone: 'destructive' | 'accent' = 'accent'

  if (limits.state === 'deleted') {
    text = t('plan', 'bannerDeleted')
    tone = 'destructive'
  } else if (!limits.writable) {
    text = limits.isTrial ? t('plan', 'bannerTrialExpired') : t('plan', 'bannerExpired')
    tone = 'destructive'
  } else if (limits.daysLeft !== null && limits.daysLeft <= PLAN_WARNING_DAYS) {
    text = limits.isTrial
      ? t('plan', 'bannerTrialEnding', { days: limits.daysLeft })
      : t('plan', 'bannerPaidEnding', { days: limits.daysLeft })
  }

  if (!text) return null

  return (
    <div
      role={tone === 'destructive' ? 'alert' : 'status'}
      className={cn(
        'border-b px-4 py-2 text-sm',
        tone === 'destructive'
          ? 'border-destructive/30 bg-destructive/10 text-destructive'
          : 'border-border bg-accent text-accent-foreground',
      )}
    >
      <div className="container flex flex-wrap items-center justify-between gap-2 px-0">
        <span>{text}</span>
        <Link href="/app/settings/plan" className="font-medium underline underline-offset-4">
          {t('plan', 'bannerLink')}
        </Link>
      </div>
    </div>
  )
}
