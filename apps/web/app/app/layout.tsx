import Link from 'next/link'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { signOut } from '@/app/login/actions'
import { Button, buttonVariants } from '@/components/ui/button'
import { canPayments, isFinance, isFrontDesk, roleLabel } from '@/lib/roles'
import { noCenterRedirectPath } from '@/lib/access'

/**
 * Оболочка приложения. Server component: здесь и только здесь решается,
 * есть ли у пользователя активный центр и какая у него роль.
 */
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) {
    redirect('/login')
  }

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? null

  if (!centerId) {
    const { data: memberships } = await supabase.from('memberships').select('center_id').limit(1)
    redirect(
      memberships && memberships.length > 0
        ? '/select-center'
        : await noCenterRedirectPath(supabase),
    )
  }

  // Роль читаем из БД, а не из JWT: членство могли отозвать, пока токен жив.
  const { data: role } = await supabase.rpc('my_role')

  if (!role) {
    redirect('/select-center')
  }

  const [{ data: center }, { count: centersCount }] = await Promise.all([
    supabase.from('centers').select('name, plan').eq('id', centerId).maybeSingle(),
    // Только свои членства: владельцу по RLS видны и чужие строки его центра,
    // из-за чего счётчик показывал «Сменить центр» при единственном центре.
    supabase
      .from('memberships')
      .select('center_id', { count: 'exact', head: true })
      .eq('user_id', user.id),
  ])

  // Меню — по матрице прав (docs/FEATURE_MATRIX.md); это косметика, отказ
  // приходит из базы: registrar/finance режут политики 0028, не эти флаги.
  const isAdmin = role === 'owner' || role === 'admin'
  const frontDesk = isFrontDesk(role)
  const finance = isFinance(role)
  const payments = canPayments(role)

  return (
    <div className="flex min-h-screen flex-col">
      <header className="border-b border-border bg-card">
        <div className="container flex h-16 items-center justify-between gap-4">
          <div className="flex items-center gap-6">
            <Link href="/app" className="leading-tight">
              <span className="block font-semibold">{center?.name ?? 'LogoCRM'}</span>
              <span className="block text-xs text-muted-foreground">
                {roleLabel(role)}
                {center?.plan ? ` · тариф ${center.plan}` : ''}
              </span>
            </Link>

            <nav className="hidden gap-1 sm:flex">
              <Link href="/app/schedule" className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
                Расписание
              </Link>
              <Link href="/app/students" className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
                Ученики
              </Link>
              {payments ? (
                <Link href="/app/payers" className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
                  Плательщики
                </Link>
              ) : null}
              {frontDesk ? (
                <Link href="/app/groups" className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
                  Группы
                </Link>
              ) : null}
              {payments ? (
                <Link href="/app/debts" className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
                  Долги
                </Link>
              ) : null}
              {payments ? (
                <Link href="/app/finance" className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
                  Финансы
                </Link>
              ) : null}
              {finance ? (
                <Link href="/app/salary" className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
                  Зарплата
                </Link>
              ) : null}
              {isAdmin || finance ? (
                <Link
                  href="/app/settings/staff"
                  className={buttonVariants({ variant: 'ghost', size: 'sm' })}
                >
                  Настройки
                </Link>
              ) : null}
            </nav>
          </div>

          <div className="flex items-center gap-2">
            {(centersCount ?? 0) > 1 ? (
              <Link
                href="/select-center"
                className={buttonVariants({ variant: 'ghost', size: 'sm' })}
              >
                Сменить центр
              </Link>
            ) : null}

            <form action={signOut}>
              <Button type="submit" variant="outline" size="sm">
                Выйти
              </Button>
            </form>
          </div>
        </div>
      </header>

      <main className="container flex-1 py-8">{children}</main>
    </div>
  )
}
