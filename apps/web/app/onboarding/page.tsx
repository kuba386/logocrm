import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { OnboardingForm } from './onboarding-form'

export const metadata = { title: 'Создание центра — LogoCRM' }

export default async function OnboardingPage({ searchParams }: { searchParams: Promise<{ own?: string }> }) {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) {
    redirect('/login')
  }

  // Если центры уже есть — выбирать, а не создавать ещё один.
  const { data: memberships } = await supabase.from('memberships').select('center_id')
  if (memberships && memberships.length > 0) {
    redirect('/select-center')
  }

  // Отключённого сотрудника не встречаем предложением завести свой центр —
  // если только он сам не нажал «Открыть собственный центр» (?own=1): без этой
  // оговорки ссылка со страницы /access-revoked вела обратно на неё же.
  const { own } = await searchParams
  if (own !== '1') {
    const { data: revoked } = await supabase.rpc('was_access_revoked')
    if (revoked) {
      redirect('/access-revoked')
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-muted/40 p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle as="h1">Создайте свой центр</CardTitle>
          <CardDescription>
            Первые 14 дней — бесплатный пробный период. Тариф можно сменить позже.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <OnboardingForm />
        </CardContent>
      </Card>
    </main>
  )
}
