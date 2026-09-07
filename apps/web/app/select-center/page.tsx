import Link from 'next/link'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
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

  const { data: memberships } = await supabase
    .from('memberships')
    .select('center_id, role, centers(id, name)')
    .eq('user_id', user.id)

  const centers: CenterOption[] = (memberships ?? [])
    .map((membership) => {
      const center = membership.centers as unknown as { id: string; name: string } | null
      if (!center) return null
      return {
        centerId: center.id,
        name: center.name,
        role: membership.role,
        isCurrent: center.id === currentCenterId,
      }
    })
    .filter((center): center is CenterOption => center !== null)

  if (centers.length === 0) {
    redirect('/onboarding')
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
