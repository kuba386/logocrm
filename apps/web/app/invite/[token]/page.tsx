import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { roleLabel } from '@/lib/roles'
import { InviteForm } from './invite-form'

export const metadata = { title: 'Приглашение — LogoCRM' }

export default async function InvitePage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params
  const supabase = await createClient()

  // invitation_preview доступна анониму и отдаёт только название центра,
  // роль и признак валидности — ничего больше.
  const { data } = await supabase.rpc('invitation_preview', { p_token: token })
  const preview = data?.[0]

  if (!preview?.valid) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-muted/40 p-6">
        <Card className="w-full max-w-md">
          <CardHeader>
            <CardTitle>Ссылка недействительна</CardTitle>
            <CardDescription>
              {preview?.center_name
                ? 'Срок действия приглашения истёк или им уже воспользовались. Попросите администратора прислать новую ссылку.'
                : 'Такого приглашения не существует. Проверьте, что ссылка скопирована целиком.'}
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Link href="/login" className={buttonVariants({ variant: 'outline' })}>
              Перейти ко входу
            </Link>
          </CardContent>
        </Card>
      </main>
    )
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-muted/40 p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle>
            «{preview.center_name}» приглашает вас как {roleLabel(preview.role).toLowerCase()}
          </CardTitle>
          <CardDescription>
            Создайте аккаунт или войдите — доступ откроется сразу после этого.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <InviteForm token={token} />
        </CardContent>
      </Card>
    </main>
  )
}
