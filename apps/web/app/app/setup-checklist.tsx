import Link from 'next/link'
import { cookies } from 'next/headers'
import { CheckCircle2, Circle } from 'lucide-react'
import { createClient } from '@/lib/supabase/server'
import { t } from '@/lib/messages'
import { SETUP_STEPS, setupHiddenCookie, setupProgress, type SetupStepKey } from '@/lib/setup-checklist'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { cn } from '@/lib/utils'
import { hideSetupChecklist } from './setup-actions'

/**
 * Плашка «Настройка центра» над дашбордом owner/admin: что ещё сделать,
 * чтобы центр заработал. Готовность шага — факт из базы (есть ли хоть одна
 * живая строка), а не галочка, которую ставит человек: удалил последний
 * кабинет — шаг снова не готов.
 *
 * Считает под RLS вызывающего: owner/admin видят все строки своего центра,
 * поэтому head-count здесь честный. Другим ролям плашка не рендерится.
 */
export async function SetupChecklist({ centerId }: { centerId: string }) {
  const store = await cookies()
  if (store.get(setupHiddenCookie(centerId))) return null

  const supabase = await createClient()
  const exists = { count: 'exact', head: true } as const

  const [rooms, services, subscriptionTypes, teachers, students, lessons, telegram, center] = await Promise.all([
    supabase.from('rooms').select('id', exists).is('deleted_at', null).eq('is_active', true),
    supabase.from('services').select('id', exists).is('deleted_at', null).eq('is_active', true),
    supabase.from('subscription_types').select('id', exists).is('deleted_at', null).eq('is_active', true),
    supabase.from('teachers').select('id', exists).is('deleted_at', null).eq('is_active', true),
    supabase.from('students').select('id', exists).is('deleted_at', null),
    supabase.from('lessons').select('id', exists).is('deleted_at', null),
    // Своя привязка: бот пишет тому, кто привязал, — как на /app/telegram.
    supabase.from('telegram_accounts').select('id', exists).is('unlinked_at', null),
    supabase.from('centers').select('settings').eq('id', centerId).maybeSingle(),
  ])

  // Ошибка запроса — не «шаг не сделан»: лучше не показать плашку вовсе,
  // чем позвать владельца добавлять кабинет, который у него есть.
  const counts = [rooms, services, subscriptionTypes, teachers, students, lessons, telegram]
  if (counts.some((r) => r.error) || center.error) return null

  const state: Record<SetupStepKey, boolean> = {
    rooms: (rooms.count ?? 0) > 0,
    services: (services.count ?? 0) > 0,
    subscriptionTypes: (subscriptionTypes.count ?? 0) > 0,
    teachers: (teachers.count ?? 0) > 0,
    students: (students.count ?? 0) > 0,
    lessons: (lessons.count ?? 0) > 0,
    telegram: (telegram.count ?? 0) > 0,
    booking: Boolean((center.data?.settings as Record<string, unknown> | null)?.booking_enabled),
  }
  const progress = setupProgress(state)
  if (progress.complete) return null

  const percent = Math.round((progress.done / progress.total) * 100)

  return (
    <Card className="border-primary/30">
      <CardHeader className="flex-row items-start justify-between gap-3 space-y-0">
        <div className="space-y-1.5">
          <CardTitle>{t('setup', 'title')}</CardTitle>
          <CardDescription>{t('setup', 'progress', { done: progress.done, total: progress.total })}</CardDescription>
        </div>
        <form action={hideSetupChecklist} className="-mr-3 -mt-1.5 shrink-0">
          <Button type="submit" variant="ghost" size="sm">
            {t('setup', 'hide')}
          </Button>
        </form>
      </CardHeader>
      <CardContent className="space-y-4">
        <div
          role="progressbar"
          aria-label={t('setup', 'title')}
          aria-valuemin={0}
          aria-valuemax={progress.total}
          aria-valuenow={progress.done}
          className="h-2 overflow-hidden rounded-full bg-muted"
        >
          <div className="h-full rounded-full bg-primary transition-all" style={{ width: `${percent}%` }} />
        </div>
        <ol className="divide-y divide-border">
          {SETUP_STEPS.map((step) => {
            const done = state[step.key]
            return (
              <li key={step.key} className="flex items-start gap-3 py-3 first:pt-0 last:pb-0">
                {done ? (
                  <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden />
                ) : (
                  <Circle className="mt-0.5 h-5 w-5 shrink-0 text-muted-foreground" aria-hidden />
                )}
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium">
                    <span className={cn(done && 'text-muted-foreground line-through')}>{t('setup', step.title)}</span>
                    {step.optional ? (
                      <span className="ml-2 text-xs font-normal text-muted-foreground">{t('setup', 'optional')}</span>
                    ) : null}
                    {done ? <span className="sr-only"> — {t('setup', 'doneSr')}</span> : null}
                  </p>
                  {done ? null : <p className="text-sm text-muted-foreground">{t('setup', step.hint)}</p>}
                </div>
                {done ? null : (
                  <Link href={step.href} className="shrink-0 text-sm font-medium text-primary hover:underline">
                    {t('setup', 'go')}
                  </Link>
                )}
              </li>
            )
          })}
        </ol>
      </CardContent>
    </Card>
  )
}
