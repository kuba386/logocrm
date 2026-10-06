import Link from 'next/link'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { buttonVariants } from '@/components/ui/button'
import { cn } from '@/lib/utils'

/** Переключатель периода (неделя, месяц): стрелки по краям подписи и «Сегодня». */
export function PeriodNav({
  label,
  prev,
  next,
  today,
  prevLabel,
  nextLabel,
}: {
  label: string
  prev: string
  next: string
  today?: { href: string; label: string; current: boolean }
  prevLabel: string
  nextLabel: string
}) {
  return (
    <div className="flex items-center gap-1">
      <Link href={prev} aria-label={prevLabel} className={buttonVariants({ variant: 'outline', size: 'sm', className: 'w-11 px-0 sm:w-auto sm:px-2' })}>
        <ChevronLeft className="size-4" />
      </Link>
      <span className="min-w-[10rem] px-2 text-center text-sm font-medium tabular-nums">{label}</span>
      <Link href={next} aria-label={nextLabel} className={buttonVariants({ variant: 'outline', size: 'sm', className: 'w-11 px-0 sm:w-auto sm:px-2' })}>
        <ChevronRight className="size-4" />
      </Link>
      {today && !today.current ? (
        <Link href={today.href} className={cn(buttonVariants({ variant: 'ghost', size: 'sm' }), 'ml-1')}>
          {today.label}
        </Link>
      ) : null}
    </div>
  )
}
