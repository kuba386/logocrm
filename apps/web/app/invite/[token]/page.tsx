import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { roleLabel } from '@/lib/roles'
import { FormError } from '@/components/ui/alert'
import { AcceptSignedInForm, InviteForm } from './invite-form'

export const metadata = { title: 'Приглашение — LogoCRM', robots: { index: false, follow: false } }

export default async function InvitePage({
  params,
  searchParams,
}: {
  params: Promise<{ token: string }>
  searchParams: Promise<{ error?: string }>
}) {
  const { token } = await params
  // Причина неудачного принятия из /auth/callback — текст базы, выводится как текст.
  const { error: acceptError } = await searchParams
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
            <CardTitle as="h1">Ссылка недействительна</CardTitle>
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

  const {
    data: { user },
  } = await supabase.auth.getUser()

  return (
    <main className="flex min-h-screen items-center justify-center bg-muted/40 p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle as="h1">
            «{preview.center_name}» приглашает вас как {roleLabel(preview.role).toLowerCase()}
          </CardTitle>
          <CardDescription>
            {user
              ? `Вы вошли как ${user.email}. Примите приглашение — доступ откроется сразу. Если вы руководитель и открыли ссылку проверить её — не принимайте, а перешлите сотруднику.`
              : 'Создайте аккаунт или войдите — доступ откроется сразу после этого.'}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <FormError message={acceptError} />
          {user ? <AcceptSignedInForm token={token} /> : <InviteForm token={token} />}
        </CardContent>
      </Card>
    </main>
  )
}
