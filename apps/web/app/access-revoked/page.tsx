import Link from 'next/link'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { signOut } from '@/app/login/actions'
import { Button } from '@/components/ui/button'

export const metadata = { title: 'Доступ отозван — LogoCRM' }

/**
 * Отдельный экран для отключённого сотрудника. Без него человек попадал на
 * «Создайте свой центр» — сразу после того, как его уволили.
 */
export default async function AccessRevokedPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) {
    redirect('/login')
  }

  // Если доступ вернули, пока человек сидел на этой странице — пропускаем внутрь.
  const { data: memberships } = await supabase.from('memberships').select('center_id').limit(1)
  if (memberships && memberships.length > 0) {
    redirect('/app')
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-muted/40 p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle>Доступ к центру отозван</CardTitle>
          <CardDescription>
            Ваш доступ закрыт администратором центра. Если это ошибка — свяжитесь с ним напрямую.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <p className="text-sm text-muted-foreground">
            Аккаунт остался: как только вас пригласят снова, вход заработает по тому же адресу{' '}
            <span className="font-medium text-foreground">{user.email}</span>.
          </p>

          <div className="flex flex-wrap gap-2">
            <form action={signOut}>
              <Button type="submit" variant="outline">
                Выйти
              </Button>
            </form>
            <Link href="/onboarding" className={buttonVariants({ variant: 'link' })}>
              Открыть собственный центр
            </Link>
          </div>
        </CardContent>
      </Card>
    </main>
  )
}
