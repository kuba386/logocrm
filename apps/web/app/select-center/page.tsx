import Link from 'next/link'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { noCenterRedirectPath } from '@/lib/access'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { CenterList, type CenterOption } from './center-list'

export const metadata = { title: 'Выбор центра — LogoCRM' }

export default async function SelectCenterPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) {
    redirect('/login')
  }

  const currentCenterId = (user.app_metadata as { center_id?: string })?.center_id ?? null

  // my_memberships() (0056 Р15), не .from('memberships').select('centers(...)'):
  // тот join фильтруется RLS на centers и прячет центр, помеченный на
  // удаление, от его же владельца — окно отсрочки было бы нечем открыть.
  const { data: memberships } = await supabase.rpc('my_memberships')

  const centers: CenterOption[] = (memberships ?? []).map((membership) => ({
    centerId: membership.center_id,
    name: membership.center_name,
    role: membership.role,
    isCurrent: membership.center_id === currentCenterId,
    deleted: membership.deleted,
  }))

  if (centers.length === 0) {
    redirect(await noCenterRedirectPath(supabase))
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-muted/40 p-6">
      <Card className="w-full max-w-lg">
        <CardHeader>
          <CardTitle>Выберите центр</CardTitle>
          <CardDescription>
            {centers.length > 1
              ? 'Вы состоите в нескольких центрах.'
              : 'Продолжите работу или создайте ещё один центр.'}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <CenterList centers={centers} />
          <Link href="/onboarding" className={buttonVariants({ variant: 'link' })}>
            Создать новый центр
          </Link>
        </CardContent>
      </Card>
    </main>
  )
}
