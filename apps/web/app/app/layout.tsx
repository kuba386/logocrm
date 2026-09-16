import Link from 'next/link'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { signOut } from '@/app/login/actions'
import { Button, buttonVariants } from '@/components/ui/button'
import { canPayments, isFinance, isFrontDesk, roleLabel } from '@/lib/roles'
import { noCenterRedirectPath } from '@/lib/access'
import { cn } from '@/lib/utils'
import { MobileNav } from '@/app/app/mobile-nav'
import { SidebarNav } from '@/app/app/sidebar-nav'
import { BottomTabs } from '@/app/app/bottom-tabs'

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

  const navLinks = [
    { href: '/app/schedule', label: 'Расписание', show: true },
    { href: '/app/students', label: 'Ученики', show: true },
    { href: '/app/payers', label: 'Плательщики', show: payments },
    { href: '/app/groups', label: 'Группы', show: frontDesk },
    { href: '/app/debts', label: 'Долги', show: payments },
    { href: '/app/finance', label: 'Финансы', show: payments },
    { href: '/app/salary', label: 'Зарплата', show: finance },
    { href: '/app/my-salary', label: 'Моя зарплата', show: role === 'teacher' },
    { href: '/app/settings/staff', label: 'Настройки', show: isAdmin || finance },
  ].filter((link) => link.show)

  // Нижние вкладки (Stitch: specialist-day-mobile.png, parent-cabinet-mobile.png)
  // только там, где разделов мало — у admin/finance/registrar их 5-7,
  // в таб-бар не влезут, им гамбургер. «Отметки»/«Задания» из макетов
  // не заведены: у отметки посещения нет отдельного роута (она в
  // расписании, docs/Roadmap/stages.md этап 4), а «Задания» — этап 7,
  // ещё не реализован. Дашборд ролей — уже отдельная страница с своим
  // содержимым (dashboard-teacher.tsx/dashboard-parent.tsx), не дубль
  // расписания, поэтому явная вкладка на него, хотя в макете её нет.
  const bottomTabs =
    role === 'teacher'
      ? [
          { href: '/app', label: 'Дашборд' },
          { href: '/app/schedule', label: 'Расписание' },
          { href: '/app/students', label: 'Ученики' },
          { href: '/app/my-salary', label: 'Зарплата' },
        ]
      : role === 'parent'
        ? [
            { href: '/app', label: 'Дашборд' },
            { href: '/app/schedule', label: 'Расписание' },
            { href: '/app/students', label: 'Ученики' },
          ]
        : null

  return (
    <div className="flex min-h-screen">
      {/* Десктоп: постоянный сайдбар, sidebar-width из DESIGN.md (240px = w-60). */}
      <aside className="hidden w-60 shrink-0 flex-col border-r border-border bg-card sm:flex">
        <Link href="/app" className="block border-b border-border p-4 leading-tight">
          <span className="block font-semibold">{center?.name ?? 'LogoCRM'}</span>
          <span className="block text-xs text-muted-foreground">
            {roleLabel(role)}
            {center?.plan ? ` · тариф ${center.plan}` : ''}
          </span>
        </Link>

        <SidebarNav links={navLinks} />

        <div className="flex flex-col gap-2 border-t border-border p-3">
          {(centersCount ?? 0) > 1 ? (
            <Link
              href="/select-center"
              className={buttonVariants({ variant: 'ghost', size: 'sm' })}
            >
              Сменить центр
            </Link>
          ) : null}

          <form action={signOut}>
            <Button type="submit" variant="outline" size="sm" className="w-full">
              Выйти
            </Button>
          </form>
        </div>
      </aside>

      <div className="flex min-h-screen min-w-0 flex-1 flex-col">
        {/* Мобильный/планшетный хедер: сайдбар выше скрыт, здесь гамбургер. */}
        <header className="relative border-b border-border bg-card sm:hidden">
          <div className="container flex h-16 items-center justify-between gap-4">
            <Link href="/app" className="leading-tight">
              <span className="block font-semibold">{center?.name ?? 'LogoCRM'}</span>
              <span className="block text-xs text-muted-foreground">
                {roleLabel(role)}
                {center?.plan ? ` · тариф ${center.plan}` : ''}
              </span>
            </Link>

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

              {bottomTabs ? null : <MobileNav links={navLinks} />}
            </div>
          </div>
        </header>

        <main className={cn('container flex-1 py-8', bottomTabs ? 'pb-20 sm:pb-8' : '')}>
          {children}
        </main>

        {bottomTabs ? <BottomTabs links={bottomTabs} /> : null}
      </div>
    </div>
  )
}
