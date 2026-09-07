import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { LoginForm } from './login-form'

export const metadata = { title: 'Вход — LogoCRM' }

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string }>
}) {
  const { next } = await searchParams

  return (
    <main className="flex min-h-screen items-center justify-center bg-muted/40 p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle>Вход в LogoCRM</CardTitle>
          <CardDescription>CRM для логопедических центров</CardDescription>
        </CardHeader>
        <CardContent>
          <LoginForm next={next ?? '/app'} />
        </CardContent>
      </Card>
    </main>
  )
}
