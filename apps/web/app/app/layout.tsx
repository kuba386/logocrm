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
import { PlanBanner } from '@/app/app/plan-banner'
import { parseCenterLimits } from '@/lib/plan'

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

  // Администратор платформы — роль вне memberships (0049): у него может не
  // быть ни одного центра, тогда его место — /admin, а не «создайте центр».
  const { data: isPlatformAdmin } = await supabase.rpc('is_platform_admin')

  if (!centerId) {
    const { data: memberships } = await supabase.from('memberships').select('center_id').limit(1)
    redirect(
      memberships && memberships.length > 0
        ? '/select-center'
        : isPlatformAdmin
          ? '/admin'
          : await noCenterRedirectPath(supabase),
    )
  }

  // Роль читаем из БД, а не из JWT: членство могли отозвать, пока токен жив.
  const { data: role } = await supabase.rpc('my_role')

  if (!role) {
    redirect('/select-center')
  }

  // Меню — по матрице прав (docs/FEATURE_MATRIX.md); это косметика, отказ
  // приходит из базы: registrar/finance режут политики 0028, не эти флаги.
  const isAdmin = role === 'owner' || role === 'admin'

  const [{ data: center }, { count: centersCount }, { data: limitsJson }] = await Promise.all([
    supabase.from('centers').select('name, plan').eq('id', centerId).maybeSingle(),
    // Только свои членства: владельцу по RLS видны и чужие строки его центра,
    // из-за чего счётчик показывал «Сменить центр» при единственном центре.
    supabase
      .from('memberships')
      .select('center_id', { count: 'exact', head: true })
      .eq('user_id', user.id),
    // Баннер тарифа — только тем, кто может оплатить: center_limits() закрыт
    // для parent, а специалисту «оплатите» читать не нужно (0050 Р9).
    isAdmin ? supabase.rpc('center_limits') : Promise.resolve({ data: null }),
  ])
  const limits = isAdmin ? parseCenterLimits(limitsJson) : null
  const frontDesk = isFrontDesk(role)
  const finance = isFinance(role)
  const payments = canPayments(role)

  const navLinks = [
    { href: '/app/schedule', label: 'Расписание', show: role !== 'finance' },
    { href: '/app/students', label: 'Ученики', show: true },
    { href: '/app/library', label: 'Библиотека', show: role === 'teacher' || isAdmin },
    { href: '/app/payers', label: 'Плательщики', show: payments },
    { href: '/app/groups', label: 'Группы', show: frontDesk },
    { href: '/app/debts', label: 'Долги', show: payments },
    { href: '/app/finance', label: 'Финансы', show: payments },
    { href: '/app/salary', label: 'Зарплата', show: finance },
    { href: '/app/my-salary', label: 'Моя зарплата', show: role === 'teacher' },
    { href: '/app/notifications', label: 'Уведомления', show: isAdmin },
    { href: '/app/funnel', label: 'Воронка', show: isAdmin },
    { href: '/app/bookings', label: 'Заявки', show: frontDesk },
    // Telegram привязывает каждый себе сам — в том числе родитель и
    // специалист, которым настройки центра не показываются.
    { href: '/app/telegram', label: 'Telegram', show: true },
    { href: '/app/settings/staff', label: 'Настройки', show: isAdmin || finance },
    { href: '/admin', label: 'Платформа', show: Boolean(isPlatformAdmin) },
  ].filter((link) => link.show)

  // Нижние вкладки (Stitch: specialist-day-mobile.png, parent-cabinet-mobile.png)
  // только там, где разделов мало — у admin/finance/registrar их 5-7,
  // в таб-бар не влезут, им гамбургер. «Отметки» из макетов не заведена:
  // у отметки посещения нет отдельного роута (она в расписании,
  // docs/Roadmap/stages.md этап 4). «Задания» — теперь /app/library
  // (этап 7a). Дашборд ролей — уже отдельная страница с своим
  // содержимым (dashboard-teacher.tsx/dashboard-parent.tsx), не дубль
  // расписания, поэтому явная вкладка на него, хотя в макете её нет.
  const bottomTabs =
    role === 'teacher'
      ? [
          { href: '/app', label: 'Дашборд' },
          { href: '/app/schedule', label: 'Расписание' },
          { href: '/app/students', label: 'Ученики' },
          { href: '/app/library', label: 'Библиотека' },
          { href: '/app/my-salary', label: 'Зарплата' },
        ]
      : role === 'parent'
        ? [
            { href: '/app', label: 'Дашборд' },
            { href: '/app/schedule', label: 'Расписание' },
            { href: '/app/students', label: 'Ученики' },
          ]
        : null

  const menuLinks = bottomTabs
    ? navLinks.filter((link) => !bottomTabs.some((tab) => tab.href === link.href))
    : navLinks

  return (
    <div className="flex min-h-screen">
      {/* Десктоп: постоянный сайдбар, sidebar-width из DESIGN.md (240px = w-60). */}
      <aside className="hidden w-60 shrink-0 flex-col border-r border-border bg-card sm:flex">
        <Link href="/app" className="block border-b border-border p-4 leading-tight">
          <span className="block font-semibold">{center?.name ?? 'LogoCRM'}</span>
          <span className="block text-xs text-muted-foreground">
            {roleLabel(role)}
            {limits ? ` · ${limits.planName}` : center?.plan ? ` · тариф ${center.plan}` : ''}
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

      <div className="flex min-w-0 flex-1 flex-col">
        {/* Мобильный/планшетный хедер: сайдбар выше скрыт, здесь гамбургер. */}
        <header className="relative border-b border-border bg-card sm:hidden">
          <div className="container flex h-16 items-center justify-between gap-4">
            <Link href="/app" className="leading-tight">
              <span className="block font-semibold">{center?.name ?? 'LogoCRM'}</span>
              <span className="block text-xs text-muted-foreground">
                {roleLabel(role)}
                {limits ? ` · ${limits.planName}` : center?.plan ? ` · тариф ${center.plan}` : ''}
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

              {/* Вкладки внизу не заменяют меню целиком: разделы, которых в
                  них нет (Telegram у родителя и специалиста, Библиотека у
                  родителя), остаются в гамбургере — иначе привязать бота с
                  телефона неоткуда. */}
              {menuLinks.length > 0 ? <MobileNav links={menuLinks} /> : null}
            </div>
          </div>
        </header>

        <PlanBanner limits={limits} />

        <main className={cn('container flex-1 py-8', bottomTabs ? 'pb-20 sm:pb-8' : '')}>
          {children}
        </main>

        {bottomTabs ? <BottomTabs links={bottomTabs} /> : null}
      </div>
    </div>
  )
}
