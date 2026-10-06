import type { Metadata } from 'next'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { LoginForm } from './login-form'

export async function generateMetadata({
  searchParams,
}: {
  searchParams: Promise<{ mode?: string }>
}): Promise<Metadata> {
  const { mode } = await searchParams
  return { title: mode === 'signup' ? 'Регистрация центра — LogoCRM' : 'Вход — LogoCRM' }
}

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string; mode?: string }>
}) {
  const { next, mode } = await searchParams
  // «Попробовать бесплатно» с лендинга ведёт сюда с ?mode=signup: новый клиент
  // видит «Регистрация центра», а не «Вход» с регистрацией второй кнопкой.
  const signup = mode === 'signup'

  return (
    <main className="flex min-h-screen items-center justify-center bg-muted/40 p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle as="h1">{signup ? 'Регистрация центра' : 'Вход в LogoCRM'}</CardTitle>
          <CardDescription>
            {signup ? '14 дней бесплатно, без карты. Тариф выберете потом.' : 'CRM для логопедических центров'}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <LoginForm next={next ?? '/app'} signup={signup} />
        </CardContent>
      </Card>
    </main>
  )
}
