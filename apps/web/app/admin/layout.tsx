import Link from 'next/link'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { signOut } from '@/app/login/actions'
import { Button, buttonVariants } from '@/components/ui/button'
import { t } from '@/lib/messages'

/**
 * Оболочка платформы. Отдельная от /app: у администратора платформы может не
 * быть ни одного центра, а выбор центра здесь не нужен. Право — только из
 * базы: is_platform_admin() (0049) смотрит подтверждённый email в
 * platform_admins; RPC платформы проверяют его же сами, экран лишь скрывает.
 */
export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: isPlatformAdmin } = await supabase.rpc('is_platform_admin')
  if (!isPlatformAdmin) redirect('/app')

  return (
    <div className="flex min-h-screen flex-col">
      <header className="border-b border-border bg-card">
        <div className="container flex h-16 items-center justify-between gap-4">
          <Link href="/admin" className="leading-tight">
            <span className="block font-semibold">{t('admin', 'brand')}</span>
            <span className="block text-xs text-muted-foreground">{user.email}</span>
          </Link>
          <div className="flex items-center gap-2">
            <Link href="/app" className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
              {t('admin', 'toApp')}
            </Link>
            <form action={signOut}>
              <Button type="submit" variant="outline" size="sm">
                {t('admin', 'signOut')}
              </Button>
            </form>
          </div>
        </div>
      </header>
      <main className="container flex-1 py-8">{children}</main>
    </div>
  )
}
