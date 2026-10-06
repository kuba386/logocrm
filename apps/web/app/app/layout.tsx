import Link from 'next/link'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { signOut } from '@/app/login/actions'
import { Button, buttonVariants } from '@/components/ui/button'
import { canPayments, isFinance, isFrontDesk, roleLabel } from '@/lib/roles'
import { noCenterRedirectPath } from '@/lib/access'
import { cn } from '@/lib/utils'
import { MobileNav } from '@/app/app/mobile-nav'
import { SidebarNav, type NavGroup } from '@/app/app/sidebar-nav'
import { BottomTabs } from '@/app/app/bottom-tabs'
import { PlanBanner } from '@/app/app/plan-banner'
import { GlobalSearch } from '@/app/app/global-search'
import { parseCenterLimits } from '@/lib/plan'
import { centerTimeZone } from '@/lib/timezone'

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
    supabase.from('centers').select('name, plan, settings').eq('id', centerId).maybeSingle(),
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
  // Поиск (0062): бухгалтеру не показывается — под RLS у роли нет строк
  // students/payers (0031), её списки рисуют definer-RPC; плейсхолдер про
  // телефон — только тем, кому payers читаемы (зеркало SQL, не гейт).
  const canSearch = role !== 'finance'
  const canSeeContacts = isAdmin || role === 'registrar'
  const timeZone = centerTimeZone(center?.settings)

  // Пункт показан только тем, кого страница пускает (редиректы в page.tsx):
  // мёртвый пункт хуже отсутствующего. Отказ всё равно приходит из базы.
  const settingsHref = isAdmin ? '/app/settings/staff' : finance ? '/app/settings/teacher-rates' : null
  const groups: NavGroup[] = [
    {
      links: [
        { href: '/app', label: 'Дашборд', show: true },
        { href: '/app/schedule', label: 'Расписание', show: role !== 'finance' },
        { href: '/app/students', label: 'Ученики', show: true },
        { href: '/app/groups', label: 'Группы', show: isAdmin },
        { href: '/app/bookings', label: 'Заявки', show: frontDesk },
        { href: '/app/library', label: 'Библиотека', show: role === 'teacher' || isAdmin },
      ],
    },
    {
      label: 'Деньги',
      links: [
        { href: '/app/payers', label: 'Плательщики', show: isAdmin },
        { href: '/app/debts', label: 'Долги', show: payments },
        { href: '/app/finance', label: 'Финансы', show: payments },
        { href: '/app/salary', label: 'Зарплата', show: finance },
        { href: '/app/my-salary', label: 'Моя зарплата', show: role === 'teacher' },
        // Выгрузки — тем же, кому положены деньги (can_finance, 0058); регистратор
        // видит /app/finance, но файлы не выносит — решение владельца 24.09.2026.
        { href: '/app/reports', label: 'Отчёты', show: finance },
      ],
    },
    {
      label: 'Центр',
      links: [
        // Ассистент (0064) — всем сотрудникам (В3); гейт по роли — assistant_begin.
        { href: '/app/assistant', label: 'Ассистент', show: role !== 'parent' },
        { href: '/app/notifications', label: 'Журнал отправок', show: isAdmin },
        { href: '/app/funnel', label: 'Воронка', show: isAdmin },
        // Telegram привязывает каждый себе сам — в том числе родитель и
        // специалист, которым настройки центра не показываются.
        { href: '/app/telegram', label: 'Telegram', show: true },
        { href: settingsHref ?? '', label: 'Настройки', show: settingsHref !== null },
        { href: '/admin', label: 'Платформа', show: Boolean(isPlatformAdmin) },
      ],
    },
  ]
    .map((group) => ({ ...group, links: group.links.filter((link) => link.show) }))
    .filter((group) => group.links.length > 0)

  // Нижние вкладки (Stitch: specialist-day-mobile.png, parent-cabinet-mobile.png)
  // только там, где разделов мало; остальное — в меню.
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

  const planLabel = limits ? limits.planName : center?.plan ? `тариф ${center.plan}` : null
  const centerHeader = (
    <Link href="/app" className="flex min-h-11 min-w-0 flex-col justify-center leading-tight">
      <span className="block truncate font-display text-sm font-medium">{center?.name ?? 'LogoCRM'}</span>
      <span className="block truncate text-xs text-muted-foreground">
        {roleLabel(role)}
        {planLabel ? `, ${planLabel}` : ''}
      </span>
    </Link>
  )
  const accountActions = (
    <>
      {(centersCount ?? 0) > 1 ? (
        <Link href="/select-center" className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
          Сменить центр
        </Link>
      ) : null}
      <form action={signOut}>
        <Button type="submit" variant="outline" size="sm" className="w-full">
          Выйти
        </Button>
      </form>
    </>
  )

  return (
    <div className="flex min-h-screen">
      {/* Первый элемент страницы: с клавиатуры не проходить поиск и до 17
          пунктов меню перед каждым экраном (UX-аудит, пакет 7, UX45). */}
      <a
        href="#main"
        className="sr-only z-50 rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground focus:not-sr-only focus:fixed focus:left-4 focus:top-4 print:hidden"
      >
        Перейти к содержимому
      </a>
      {/* Десктоп: постоянный сайдбар, sidebar-width из DESIGN.md (240px = w-60). */}
      <aside className="sticky top-0 hidden h-screen w-60 shrink-0 flex-col border-r border-border bg-card sm:flex print:hidden">
        <div className="border-b border-border p-4">{centerHeader}</div>

        {canSearch ? <GlobalSearch canSeeContacts={canSeeContacts} timeZone={timeZone} /> : null}

        <SidebarNav groups={groups} />

        <div className="flex flex-col gap-2 border-t border-border p-3">{accountActions}</div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-30 border-b border-border bg-card sm:hidden print:hidden">
          <div className="container flex h-14 items-center gap-2">
            <MobileNav groups={groups} header={centerHeader} footer={accountActions} />
            {centerHeader}
          </div>
          {/* Поиск — второй строкой той же шапки: в первой места нет. */}
          {canSearch ? <GlobalSearch canSeeContacts={canSeeContacts} timeZone={timeZone} compact /> : null}
        </header>

        <div className="print:hidden">
          <PlanBanner limits={limits} />
        </div>

        <main
          id="main"
          tabIndex={-1}
          className={cn('container flex-1 py-6 outline-none sm:py-8 print:max-w-none print:p-0', bottomTabs ? 'pb-20 sm:pb-8' : '')}
        >
          {children}
        </main>

        {bottomTabs ? (
          <div className="print:hidden">
            <BottomTabs links={bottomTabs} />
          </div>
        ) : null}
      </div>
    </div>
  )
}
